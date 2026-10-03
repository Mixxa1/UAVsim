#include "cadnext/gui/NativeKompasModel.hpp"

#include <QObject>

#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace cadnext::gui {
namespace {

struct Reader {
    const QByteArray& bytes;
    qsizetype at;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("Truncated model envelope");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("Unsupported model envelope layout");
    }
    bool boolean() {
        const auto value = number(1);
        if (value > 1) throw std::runtime_error("Invalid model state flag");
        return value != 0;
    }
    double real() {
        const quint64 bits = number(8);
        double value;
        std::memcpy(&value, &bits, sizeof(value));
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite model field");
        return value;
    }
    QString string() {
        const auto count = number(4);
        if (count > 65536 || count * 2 > quint64(bytes.size() - at))
            throw std::runtime_error("Invalid model property string extent");
        QString value;
        value.reserve(qsizetype(count));
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
};

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void real(double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof(bits));
        number(bits, 8);
    }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
};

void validate(const KompasModelHeader& header) {
    for (const auto value : header.transform)
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite model transform");
    for (const auto& box : header.boxes) {
        for (const auto value : box)
            if (!std::isfinite(value)) throw std::runtime_error("Non-finite model box");
        const std::array<double, 6> empty{1e300, 1e300, 1e300, -1e300, -1e300, -1e300};
        if (box != empty)
            for (int axis = 0; axis < 3; ++axis)
                if (box[axis] > box[axis + 3]) throw std::runtime_error("Inverted model box");
    }
    // The supported controller/math registry uses 16-bit IDs. Check the
    // vector count without allocating any controller objects in this codec.
    if (header.controllerCount > 65536) throw std::runtime_error("Oversized model controller vector");
}

quint32 total(const KompasModelFooter& footer) {
    quint64 result = 0;
    for (const auto value : footer.nativeCounters) {
        if (value > std::numeric_limits<quint32>::max() - result)
            throw std::runtime_error("Overflowing model registry counters");
        result += value;
    }
    return quint32(result);
}

void validate(const KompasModelFooter& footer, const std::map<quint16, quint16>& registry) {
    const auto found = registry.find(footer.originId);
    if (found == registry.end() || found->second != 0x4170)
        throw std::runtime_error("Invalid model origin reference");
    if (!footer.nextMainName || footer.nextMainName >= 0xfffffffbu)
        throw std::runtime_error("Invalid model main-name counter");
    total(footer);
}

void validate(const KompasModelProperties& properties) {
    if (properties.name.size() > 65536 || properties.materialName.size() > 65536)
        throw std::runtime_error("Oversized model property string");
    if (properties.color > 0xffffff) throw std::runtime_error("Invalid model property color");
    for (const auto value : properties.material)
        if (value > 100) throw std::runtime_error("Invalid model material field");
    if (!std::isfinite(properties.nativeDensity) || properties.nativeDensity < 0)
        throw std::runtime_error("Invalid model material density");
}

void readPropertyScalars(Reader& r) {
    r.expect(0, 8); r.expect(0, 8); r.expect(0, 2);
    // Two native IEEE float display scalars, 3 and 45, in the supported
    // default profile. Reject other profiles until their semantics are known.
    r.expect(0x40400000, 4); r.expect(0x42340000, 4);
    r.expect(0, 8); r.expect(0, 8); r.expect(0, 4); r.expect(0, 2);
    r.expect(0, 1); r.expect(0xff, 1); r.expect(1, 1);
    r.expect(0, 8); r.expect(0, 8); r.expect(0, 1);
}

void writePropertyScalars(Writer& w) {
    w.number(0, 8); w.number(0, 8); w.number(0, 2);
    w.number(0x40400000, 4); w.number(0x42340000, 4);
    w.number(0, 8); w.number(0, 8); w.number(0, 4); w.number(0, 2);
    w.number(0, 1); w.number(0xff, 1); w.number(1, 1);
    w.number(0, 8); w.number(0, 8); w.number(0, 1);
}

void validate(const KompasDeferredMassProperties& properties) {
    if (!std::isfinite(properties.nativeDensity) || properties.nativeDensity<0)
        throw std::runtime_error("Invalid mass-cache density");
}

void validate(const KompasBodyProperties& body) {
    validate(body.properties); validate(body.massCache);
    if (body.nativeFlags!=0 && body.nativeFlags!=3)
        throw std::runtime_error("Unsupported body property flags");
    const double density=body.properties.nativeDensity/1000;
    if (std::fabs(density-body.massCache.nativeDensity)>1e-12*std::max(density,body.massCache.nativeDensity))
        throw std::runtime_error("Body material and mass-cache densities disagree");
}

KompasDeferredMassProperties readDeferredMass(Reader& r) {
    KompasDeferredMassProperties result;
    r.expect(0,1); // no calculated quantities
    result.nativeDensity=r.real(); r.expect(1,4); r.expect(1,1);
    for (int i=0;i<2;++i) { r.expect(0,8);r.expect(0,4); } // mass, volume and unit tags
    for (int i=0;i<3;++i)
        if (r.real()!=-1e138) throw std::runtime_error("Invalid deferred centre-of-mass sentinel");
    r.expect(0,4);
    // Area and six tensor components, each with a unit tag.
    for (int i=0;i<7;++i) { r.expect(0,8);r.expect(0,4); }
    // Cache's registry snapshot: aggregate, u32/u32/u64/u64 counters.
    r.expect(0,4);r.expect(0,4);r.expect(0,4);r.expect(0,8);r.expect(0,8);
    r.expect(0,8);r.expect(0,4);
    // Static moments, two tensors, principal moments and principal axes.
    for (int i=0;i<33;++i) r.expect(0,8);
    r.expect(0,4);
    if (r.real()!=-1e137) throw std::runtime_error("Invalid deferred mass-cache sentinel");
    validate(result);
    return result;
}

void writeDeferredMass(Writer& w,const KompasDeferredMassProperties& properties) {
    validate(properties);
    w.number(0,1);w.real(properties.nativeDensity);w.number(1,4);w.number(1,1);
    for (int i=0;i<2;++i) { w.real(0);w.number(0,4); }
    for (int i=0;i<3;++i) w.real(-1e138);
    w.number(0,4);
    for (int i=0;i<7;++i) { w.real(0);w.number(0,4); }
    w.number(0,4);w.number(0,4);w.number(0,4);w.number(0,8);w.number(0,8);
    w.number(0,8);w.number(0,4);
    for (int i=0;i<33;++i) w.real(0);
    w.number(0,4);w.real(-1e137);
}

// The extended scalar state is fully checked, rather than retained as a
// borrowed 31-byte payload. Other extension versions need a separate codec.
void readExtension(Reader& r) {
    r.expect(0, 1); r.expect(0, 1); r.expect(1, 1); r.expect(0, 4);
    r.expect(0, 1); r.expect(1, 8); r.expect(0, 8); r.expect(0, 4);
    r.expect(0, 1); r.expect(0, 1); r.expect(0, 1);
}

void writeExtension(Writer& w) {
    w.number(0, 1); w.number(0, 1); w.number(1, 1); w.number(0, 4);
    w.number(0, 1); w.number(1, 8); w.number(0, 8); w.number(0, 4);
    w.number(0, 1); w.number(0, 1); w.number(0, 1);
}

QString failure(const std::exception& error) {
    return QObject::tr("Запись корня модели КОМПАС: %1").arg(QString::fromUtf8(error.what()));
}

bool validOffset(const QByteArray& bytes, qsizetype offset, QString& error) {
    if (offset >= 0 && offset <= bytes.size()) return true;
    error = QObject::tr("Недопустимое смещение корня модели КОМПАС.");
    return false;
}

} // namespace

bool decodeKompasModelHeader(const QByteArray& bytes, qsizetype offset,
                             KompasModelHeader& header, qsizetype& consumed,
                             QString& error) {
    header = {}; consumed = 0; error.clear();
    if (!validOffset(bytes, offset, error)) return false;
    KompasModelHeader staged;
    Reader r{bytes, offset};
    try {
        for (auto& value : staged.transform) value = r.real();
        r.expect(0, 1);
        for (auto& box : staged.boxes)
            for (auto& value : box) value = r.real();
        r.expect(0, 1); r.expect(1, 1);
        staged.controllerCount = r.number(8);
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    header = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasModelHeader(const KompasModelHeader& header,
                             QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(header);
        for (const auto value : header.transform) w.real(value);
        w.number(0, 1);
        for (const auto& box : header.boxes)
            for (const auto value : box) w.real(value);
        w.number(0, 1); w.number(1, 1); w.number(header.controllerCount, 8);
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasModelFooter(const QByteArray& bytes, qsizetype offset,
                             const std::map<quint16, quint16>& registry,
                             KompasModelFooter& footer, qsizetype& consumed,
                             QString& error) {
    footer = {}; consumed = 0; error.clear();
    if (!validOffset(bytes, offset, error)) return false;
    KompasModelFooter staged;
    Reader r{bytes, offset};
    try {
        r.expect(1, 1); staged.originId = quint16(r.number(2));
        const auto aggregate = r.number(4);
        for (int i = 0; i < 4; ++i) staged.nativeCounters[i] = r.number(i < 2 ? 4 : 8);
        if (aggregate != total(staged)) throw std::runtime_error("Mismatched model registry total");
        r.expect(0, 4); staged.extendedState = r.boolean();
        if (staged.extendedState) readExtension(r);
        r.expect(12, 4); r.expect(0, 1); r.expect(1, 8); r.expect(0, 4);
        r.expect(0, 1); r.expect(0, 1); r.expect(0, 1);
        staged.nextMainName = quint32(r.number(4)); r.expect(0, 1);
        validate(staged, registry);
    } catch (const std::exception& e) { error = failure(e); return false; }
    footer = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasModelFooter(const KompasModelFooter& footer,
                             const std::map<quint16, quint16>& registry,
                             QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(footer, registry);
        w.number(1, 1); w.number(footer.originId, 2); w.number(total(footer), 4);
        for (int i = 0; i < 4; ++i) w.number(footer.nativeCounters[i], i < 2 ? 4 : 8);
        w.number(0, 4); w.number(footer.extendedState, 1);
        if (footer.extendedState) writeExtension(w);
        w.number(12, 4); w.number(0, 1); w.number(1, 8); w.number(0, 4);
        w.number(0, 1); w.number(0, 1); w.number(0, 1);
        w.number(footer.nextMainName, 4); w.number(0, 1);
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasModelProperties(const QByteArray& bytes, qsizetype offset,
                                 KompasModelProperties& properties,
                                 qsizetype& consumed, QString& error) {
    properties = {}; consumed = 0; error.clear();
    if (!validOffset(bytes, offset, error)) return false;
    KompasModelProperties staged;
    Reader r{bytes, offset};
    try {
        r.expect(0, 4); staged.name = r.string();
        for (const auto symbol : {quint16('-'), quint16('.'), quint16(' ')}) {
            r.expect(symbol, 2); r.expect(0, 4);
        }
        staged.color = quint32(r.number(4));
        for (auto& value : staged.material) value = quint8(r.number(1));
        staged.materialName = r.string(); staged.nativeDensity = r.real();
        readPropertyScalars(r);
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    properties = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasModelProperties(const KompasModelProperties& properties,
                                 QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(properties);
        w.number(0, 4); w.string(properties.name);
        for (const auto symbol : {quint16('-'), quint16('.'), quint16(' ')}) {
            w.number(symbol, 2); w.number(0, 4);
        }
        w.number(properties.color, 4);
        for (const auto value : properties.material) w.number(value, 1);
        w.string(properties.materialName); w.real(properties.nativeDensity);
        writePropertyScalars(w);
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDeferredMassProperties(const QByteArray& bytes,qsizetype offset,
                                       KompasDeferredMassProperties& properties,
                                       qsizetype& consumed,QString& error) {
    properties={};consumed=0;error.clear();
    if (!validOffset(bytes,offset,error)) return false;
    Reader r{bytes,offset};KompasDeferredMassProperties staged;
    try { staged=readDeferredMass(r); }
    catch (const std::exception& e) { error=failure(e);return false; }
    properties=staged;consumed=r.at-offset;return true;
}

bool encodeKompasDeferredMassProperties(const KompasDeferredMassProperties& properties,
                                       QByteArray& bytes,QString& error) {
    bytes.clear();error.clear();Writer w;
    try { writeDeferredMass(w,properties); }
    catch (const std::exception& e) { error=failure(e);return false; }
    bytes=std::move(w.bytes);return true;
}

bool decodeKompasBodyProperties(const QByteArray& bytes,qsizetype offset,
                               KompasBodyProperties& properties,
                               qsizetype& consumed,QString& error) {
    properties={};consumed=0;error.clear();
    if (!validOffset(bytes,offset,error)) return false;
    Reader r{bytes,offset};KompasBodyProperties staged;
    try {
        r.expect(1,1);staged.nativeFlags=quint32(r.number(4));
        auto& p=staged.properties;p.name=r.string();p.color=quint32(r.number(4));
        for (auto& value:p.material) value=quint8(r.number(1));
        r.expect(1,1);r.expect(0,1);r.expect(0x5932,2); // inline native mass property object
        staged.massCache=readDeferredMass(r);
        p.materialName=r.string();p.nativeDensity=r.real();readPropertyScalars(r);
        for (const auto symbol:{quint16('-'),quint16('.'),quint16(' ')}) {
            r.expect(symbol,2);r.expect(0,4);
        }
        validate(staged);
    } catch (const std::exception& e) { error=failure(e);return false; }
    properties=std::move(staged);consumed=r.at-offset;return true;
}

bool encodeKompasBodyProperties(const KompasBodyProperties& properties,
                               QByteArray& bytes,QString& error) {
    bytes.clear();error.clear();Writer w;
    try {
        validate(properties);
        const auto& p=properties.properties;
        w.number(1,1);w.number(properties.nativeFlags,4);w.string(p.name);w.number(p.color,4);
        for (const auto value:p.material) w.number(value,1);
        w.number(1,1);w.number(0,1);w.number(0x5932,2);writeDeferredMass(w,properties.massCache);
        w.string(p.materialName);w.real(p.nativeDensity);writePropertyScalars(w);
        for (const auto symbol:{quint16('-'),quint16('.'),quint16(' ')}) {
            w.number(symbol,2);w.number(0,4);
        }
    } catch (const std::exception& e) { error=failure(e);return false; }
    bytes=std::move(w.bytes);return true;
}

} // namespace cadnext::gui
