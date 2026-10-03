#include "cadnext/gui/NativeKompasOperation.hpp"

#include <QObject>

#include <cmath>
#include <cstring>
#include <set>
#include <stdexcept>
#include <utility>

namespace cadnext::gui {
namespace {

constexpr qsizetype kMaxString = 65536;
constexpr qsizetype kMaxEnvelope = 1024 * 1024;
constexpr std::array<quint8, 10> kAttributeFields{2, 3, 2, 3, 3, 3, 3, 1, 0, 1};

struct Reader {
    const QByteArray& bytes;
    qsizetype at;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("Truncated operation envelope");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("Unsupported operation envelope layout");
    }
    QString string() {
        const quint64 size = number(4);
        if (size > quint64(kMaxString) || size * 2 > quint64(bytes.size() - at))
            throw std::runtime_error("Invalid operation string extent");
        QString value;
        value.reserve(qsizetype(size));
        for (quint64 i = 0; i < size; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
    double real() {
        const quint64 bits = number(8);
        double value;
        std::memcpy(&value, &bits, 8);
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite operation placement");
        return value;
    }
};

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void string(const QString& value) {
        if (value.size() > kMaxString) throw std::runtime_error("Oversized operation string");
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
    void real(double value) {
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite operation placement");
        quint64 bits;
        std::memcpy(&bits, &value, 8);
        number(bits, 8);
    }
};

void name(quint32 value) {
    if (!value || value >= 0xfffffffbu) throw std::runtime_error("Invalid operation name");
}

void color(quint32 value) {
    if (value > 0xffffff) throw std::runtime_error("Invalid operation color");
}

void validatePlacement(const std::array<double, 12>& placement) {
    for (const auto value : placement)
        if (!std::isfinite(value)) throw std::runtime_error("Non-finite operation placement");
    // The supported imported operation carries a rigid, right-handed frame.
    const auto dot = [&](int a, int b) {
        double value = 0;
        for (int k = 0; k < 3; ++k) value += placement[a + k] * placement[b + k];
        return value;
    };
    for (const int a : {3, 6, 9})
        for (const int b : {3, 6, 9})
            if (std::fabs(dot(a, b) - (a == b ? 1.0 : 0.0)) > 1e-10)
                throw std::runtime_error("Non-rigid operation placement");
    const auto& p = placement;
    const double determinant = p[3] * (p[7] * p[11] - p[8] * p[10]) -
        p[4] * (p[6] * p[11] - p[8] * p[9]) + p[5] * (p[6] * p[10] - p[7] * p[9]);
    if (determinant < 0) throw std::runtime_error("Reflected operation placement");
}

void validate(const KompasImportedOperationPrefix& prefix) {
    if (prefix.nativeType != 9 && prefix.nativeType != 25)
        throw std::runtime_error("Unsupported operation native type");
    name(prefix.mainName); name(prefix.applicationName); name(prefix.frameName);
    if (!prefix.bodyNumber || prefix.shellCount != 1)
        throw std::runtime_error("Invalid operation body or shell count");
    color(prefix.color);
    for (const auto field : prefix.material)
        if (field > 100) throw std::runtime_error("Invalid operation material field");
    for (const auto* value : {&prefix.title, &prefix.variableName, &prefix.exclusionPrompt})
        if (value->size() > kMaxString) throw std::runtime_error("Oversized operation string");
    validatePlacement(prefix.placement);
}

quint16 datumClass(KompasDatum::Kind kind) {
    switch (kind) {
    case KompasDatum::Plane: return 0x507a;
    case KompasDatum::Axis: return 0x2c70;
    case KompasDatum::Origin: return 0x4170;
    default: throw std::runtime_error("Unsupported datum kind");
    }
}

void validate(const KompasDatum& datum, const std::map<quint16, quint16>& registry) {
    datumClass(datum.kind);
    if (registry.count(datum.objectId)) throw std::runtime_error("Duplicate datum registry ID");
    if (datum.nativeType != 9 && datum.nativeType != 25)
        throw std::runtime_error("Unsupported datum native type");
    name(datum.mainName); name(datum.nativeName); color(datum.color);
    for (const auto* value : {&datum.title, &datum.variableName, &datum.exclusionPrompt})
        if (value->size() > kMaxString) throw std::runtime_error("Oversized datum string");
    if (datum.kind == KompasDatum::Axis) {
        double norm = 0;
        for (int i = 0; i < 6; ++i) {
            if (!std::isfinite(datum.placement[i])) throw std::runtime_error("Non-finite datum axis");
            if (i >= 3) norm += datum.placement[i] * datum.placement[i];
        }
        if (std::fabs(norm - 1) > 1e-10) throw std::runtime_error("Non-unit datum axis");
    } else validatePlacement(datum.placement);
    if (datum.kind == KompasDatum::Plane) {
        for (const auto value : datum.planeBox)
            if (!std::isfinite(value)) throw std::runtime_error("Non-finite datum plane box");
        for (const auto value : datum.planeBounds)
            if (!std::isfinite(value)) throw std::runtime_error("Non-finite datum plane bounds");
        if (!(datum.planeBounds[1] > datum.planeBounds[0]) || !(datum.planeBounds[3] > datum.planeBounds[2]))
            throw std::runtime_error("Empty datum plane bounds");
    }
    if (datum.kind != KompasDatum::Origin) {
        if (!datum.datumIds.empty()) throw std::runtime_error("Unexpected datum references");
    } else {
        if (datum.datumIds.size() != 6) throw std::runtime_error("Origin requires three planes and three axes");
        std::set<quint16> ids;
        for (std::size_t i = 0; i < datum.datumIds.size(); ++i) {
            const quint16 id = datum.datumIds[i];
            const auto found = registry.find(id);
            if (!ids.insert(id).second || found == registry.end() || found->second != (i < 3 ? 0x507a : 0x2c70))
                throw std::runtime_error("Invalid origin datum reference");
        }
    }
}

void validate(const KompasImportedOperationSuffix& suffix) {
    if (!suffix.bodyNumber || suffix.attributes.size() > 64)
        throw std::runtime_error("Invalid operation body or attribute count");
    for (const auto flag : suffix.nativeFlags)
        if (flag > 1) throw std::runtime_error("Invalid operation state flag");
    std::set<KompasOperationAttribute::Kind> kinds;
    for (const auto& attribute : suffix.attributes) {
        if (!kinds.insert(attribute.kind).second) throw std::runtime_error("Duplicate operation attribute");
        switch (attribute.kind) {
        case KompasOperationAttribute::Color: color(attribute.color); break;
        case KompasOperationAttribute::Boolean: break;
        case KompasOperationAttribute::Strings:
            for (const auto& value : attribute.strings)
                if (value.size() > kMaxString) throw std::runtime_error("Oversized operation attribute string");
            break;
        default: throw std::runtime_error("Unsupported operation attribute");
        }
    }
}

// The two native owner lists use u64 counts and u32 body numbers. The empty
// lists, scalar flags and reserved fields are decoded individually. A layout
// with additional lists/properties requires a parser before it can be written.
void readOwnerList(Reader& r, quint32& bodyNumber, bool first) {
    r.expect(1, 8);
    const quint32 number = quint32(r.number(4));
    if (first) bodyNumber = number;
    else if (number != bodyNumber) throw std::runtime_error("Mismatched operation body owners");
    r.expect(0, 8);
    if (first) { r.expect(1, 1); r.expect(0, 8); r.expect(0, 1); r.expect(0, 1); r.expect(0, 1); }
    else { r.expect(0, 8); r.expect(0, 4); r.expect(1, 1); r.expect(1, 1); r.expect(0, 1); r.expect(0, 2); r.expect(0, 4); }
}

void writeOwnerList(Writer& w, quint32 bodyNumber, bool first) {
    w.number(1, 8); w.number(bodyNumber, 4); w.number(0, 8);
    if (first) { w.number(1, 1); w.number(0, 8); w.number(0, 1); w.number(0, 1); w.number(0, 1); }
    else { w.number(0, 8); w.number(0, 4); w.number(1, 1); w.number(1, 1); w.number(0, 1); w.number(0, 2); w.number(0, 4); }
}

QString failure(const std::exception& error) {
    return QObject::tr("Запись импортированной операции КОМПАС: %1").arg(QString::fromUtf8(error.what()));
}

bool offsetValid(const QByteArray& bytes, qsizetype offset, QString& error) {
    if (offset >= 0 && offset <= bytes.size()) return true;
    error = QObject::tr("Недопустимое смещение импортированной операции КОМПАС.");
    return false;
}

} // namespace

bool decodeKompasImportedOperationPrefix(const QByteArray& bytes, qsizetype offset,
                                        KompasImportedOperationPrefix& prefix,
                                        qsizetype& consumed, QString& error) {
    prefix = {}; consumed = 0; error.clear();
    if (!offsetValid(bytes, offset, error)) return false;
    KompasImportedOperationPrefix staged;
    Reader r{bytes, offset};
    try {
        r.expect(2, 1); r.expect(0x80, 1); r.expect(0x2801, 2); r.expect(1, 1);
        staged.objectId = quint16(r.number(2));
        staged.nativeType = quint8(r.number(1)); r.expect(1, 1);
        staged.mainName = quint32(r.number(4));
        r.expect(0, 1); r.expect(1, 1); r.expect(0, 1);
        staged.title = r.string();
        r.expect(0, 1); r.expect(0, 2);
        staged.variableName = r.string(); staged.exclusionPrompt = r.string();
        r.expect(0, 4);
        staged.applicationName = quint32(r.number(4));
        r.expect(2, 8); r.expect(0x11001001, 4); r.expect(0x11001011, 4);
        r.expect(1, 1); r.expect(1, 1); r.expect(0, 8);
        r.expect(0, 1); r.expect(0, 1); r.expect(0, 1); r.expect(0, 4);
        readOwnerList(r, staged.bodyNumber, true);
        staged.color = quint32(r.number(4));
        for (auto& field : staged.material) field = quint8(r.number(1));
        r.expect(0, 1); r.expect(1, 1); r.expect(1, 1);
        r.expect(0, 8); r.expect(0, 1); r.expect(0, 2); r.expect(0, 4);
        readOwnerList(r, staged.bodyNumber, false);
        // Unregistered native frame object and its supported scalar fields.
        r.expect(2, 1); r.expect(0, 1); r.expect(0x0440, 2); r.expect(1, 1);
        staged.frameName = quint32(r.number(4));
        r.expect(0, 1); r.expect(1, 1); r.expect(0, 1); r.expect(50, 4); r.expect(0, 8);
        for (auto& value : staged.placement) value = r.real();
        r.expect(1, 1); r.expect(2, 4);
        staged.shellCount = r.number(8);
        if (r.at - offset > kMaxEnvelope) throw std::runtime_error("Oversized operation envelope");
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    prefix = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasImportedOperationPrefix(const KompasImportedOperationPrefix& prefix,
                                        QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(prefix);
        w.number(2, 1); w.number(0x80, 1); w.number(0x2801, 2); w.number(1, 1);
        w.number(prefix.objectId, 2); w.number(prefix.nativeType, 1); w.number(1, 1);
        w.number(prefix.mainName, 4); w.number(0, 1); w.number(1, 1); w.number(0, 1);
        w.string(prefix.title); w.number(0, 1); w.number(0, 2);
        w.string(prefix.variableName); w.string(prefix.exclusionPrompt);
        w.number(0, 4); w.number(prefix.applicationName, 4);
        w.number(2, 8); w.number(0x11001001, 4); w.number(0x11001011, 4);
        w.number(1, 1); w.number(1, 1); w.number(0, 8);
        w.number(0, 1); w.number(0, 1); w.number(0, 1); w.number(0, 4);
        writeOwnerList(w, prefix.bodyNumber, true);
        w.number(prefix.color, 4);
        for (const auto field : prefix.material) w.number(field, 1);
        w.number(0, 1); w.number(1, 1); w.number(1, 1);
        w.number(0, 8); w.number(0, 1); w.number(0, 2); w.number(0, 4);
        writeOwnerList(w, prefix.bodyNumber, false);
        w.number(2, 1); w.number(0, 1); w.number(0x0440, 2); w.number(1, 1);
        w.number(prefix.frameName, 4);
        w.number(0, 1); w.number(1, 1); w.number(0, 1); w.number(50, 4); w.number(0, 8);
        for (const auto value : prefix.placement) w.real(value);
        w.number(1, 1); w.number(2, 4); w.number(prefix.shellCount, 8);
        if (w.bytes.size() > kMaxEnvelope) throw std::runtime_error("Oversized operation envelope");
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasImportedOperationSuffix(const QByteArray& bytes, qsizetype offset,
                                        KompasImportedOperationSuffix& suffix,
                                        qsizetype& consumed, QString& error) {
    suffix = {}; consumed = 0; error.clear();
    if (!offsetValid(bytes, offset, error)) return false;
    KompasImportedOperationSuffix staged; Reader r{bytes, offset};
    try {
        for (auto& field : staged.nativeFlags) field = quint8(r.number(1));
        const quint64 count = r.number(8);
        if (count > 64) throw std::runtime_error("Oversized operation attribute list");
        for (quint64 i = 0; i < count; ++i) {
            r.expect(2, 1); r.expect(0, 1);
            const quint16 cls = quint16(r.number(2));
            for (const auto field : kAttributeFields) r.expect(field, 1);
            r.expect(0, 8);
            KompasOperationAttribute attribute;
            switch (cls) {
            case 0x6217: attribute.kind = KompasOperationAttribute::Color;
                attribute.color = quint32(r.number(4)); break;
            case 0x0165: attribute.kind = KompasOperationAttribute::Boolean;
                { const auto value = r.number(1);
                  if (value > 1) throw std::runtime_error("Invalid native boolean attribute");
                  attribute.boolean = value != 0; }
                break;
            case 0x387f: attribute.kind = KompasOperationAttribute::Strings;
                for (auto& value : attribute.strings) value = r.string(); break;
            default: throw std::runtime_error("Unsupported operation attribute class");
            }
            staged.attributes.push_back(std::move(attribute));
        }
        r.expect(0xffffffff, 4);
        staged.bodyNumber = quint32(r.number(4));
        if (r.at - offset > kMaxEnvelope) throw std::runtime_error("Oversized operation envelope");
        validate(staged);
    } catch (const std::exception& e) { error = failure(e); return false; }
    suffix = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasImportedOperationSuffix(const KompasImportedOperationSuffix& suffix,
                                        QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(suffix);
        for (const auto field : suffix.nativeFlags) w.number(field, 1);
        w.number(suffix.attributes.size(), 8);
        for (const auto& attribute : suffix.attributes) {
            const quint16 cls = attribute.kind == KompasOperationAttribute::Color ? 0x6217 :
                attribute.kind == KompasOperationAttribute::Boolean ? 0x0165 : 0x387f;
            w.number(2, 1); w.number(0, 1); w.number(cls, 2);
            for (const auto field : kAttributeFields) w.number(field, 1);
            w.number(0, 8);
            switch (attribute.kind) {
            case KompasOperationAttribute::Color: w.number(attribute.color, 4); break;
            case KompasOperationAttribute::Boolean: w.number(attribute.boolean, 1); break;
            case KompasOperationAttribute::Strings:
                for (const auto& value : attribute.strings) w.string(value); break;
            }
        }
        w.number(0xffffffff, 4); w.number(suffix.bodyNumber, 4);
        if (w.bytes.size() > kMaxEnvelope) throw std::runtime_error("Oversized operation envelope");
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDatum(const QByteArray& bytes, qsizetype offset,
                       const std::map<quint16, quint16>& registry,
                       KompasDatum& datum, qsizetype& consumed, QString& error) {
    datum = {}; consumed = 0; error.clear();
    if (!offsetValid(bytes, offset, error)) return false;
    KompasDatum staged; Reader r{bytes, offset};
    try {
        r.expect(2, 1); r.expect(0x80, 1);
        switch (r.number(2)) {
        case 0x507a: staged.kind = KompasDatum::Plane; break;
        case 0x2c70: staged.kind = KompasDatum::Axis; break;
        case 0x4170: staged.kind = KompasDatum::Origin; break;
        default: throw std::runtime_error("Unsupported datum class");
        }
        r.expect(1, 1); staged.objectId = quint16(r.number(2));
        staged.nativeType = quint8(r.number(1)); r.expect(1, 1);
        staged.mainName = quint32(r.number(4));
        r.expect(0, 1); r.expect(1, 1); r.expect(0, 1);
        staged.title = r.string(); r.expect(0, 1); r.expect(0, 2);
        staged.variableName = r.string(); staged.exclusionPrompt = r.string();
        r.expect(0, 4); staged.nativeName = quint32(r.number(4));
        r.expect(2, 8); r.expect(0x11001001, 4); r.expect(0x11001011, 4);
        r.expect(1, 1); r.expect(0, 1); r.expect(0, 8);
        r.expect(0, 1); r.expect(0, 1); r.expect(0, 1); r.expect(3, 4); r.expect(0, 8);
        staged.color = quint32(r.number(4));
        for (int i = 0; i < 6; ++i) r.expect(0, 1); // supported default material
        r.expect(0, 1); r.expect(0, 1); r.expect(0, 1); r.expect(0, 8); r.expect(0, 4);
        r.expect(1, 1); r.expect(0, 1); r.expect(1, 1); r.expect(1, 1); r.expect(0, 4);
        if (staged.kind == KompasDatum::Plane) {
            r.expect(0, 1); r.expect(0x601e, 2); // plane serialized by value
            for (auto& value : staged.planeBox) value = r.real();
            for (auto& value : staged.placement) value = r.real();
            for (auto& value : staged.planeBounds) value = r.real();
        } else if (staged.kind == KompasDatum::Axis) {
            for (int i = 0; i < 6; ++i) staged.placement[i] = r.real();
        } else {
            for (auto& value : staged.placement) value = r.real();
            r.expect(1, 1); r.expect(0, 1); r.expect(6, 8);
            for (int i = 0; i < 6; ++i) { r.expect(1, 1); staged.datumIds.push_back(quint16(r.number(2))); }
        }
        if (r.at - offset > kMaxEnvelope) throw std::runtime_error("Oversized datum envelope");
        validate(staged, registry);
    } catch (const std::exception& e) { error = failure(e); return false; }
    datum = std::move(staged); consumed = r.at - offset;
    return true;
}

bool encodeKompasDatum(const KompasDatum& datum,
                       const std::map<quint16, quint16>& registry,
                       QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear(); Writer w;
    try {
        validate(datum, registry);
        w.number(2, 1); w.number(0x80, 1); w.number(datumClass(datum.kind), 2);
        w.number(1, 1); w.number(datum.objectId, 2); w.number(datum.nativeType, 1); w.number(1, 1);
        w.number(datum.mainName, 4); w.number(0, 1); w.number(1, 1); w.number(0, 1);
        w.string(datum.title); w.number(0, 1); w.number(0, 2);
        w.string(datum.variableName); w.string(datum.exclusionPrompt);
        w.number(0, 4); w.number(datum.nativeName, 4);
        w.number(2, 8); w.number(0x11001001, 4); w.number(0x11001011, 4);
        w.number(1, 1); w.number(0, 1); w.number(0, 8);
        w.number(0, 1); w.number(0, 1); w.number(0, 1); w.number(3, 4); w.number(0, 8);
        w.number(datum.color, 4);
        for (int i = 0; i < 6; ++i) w.number(0, 1);
        w.number(0, 1); w.number(0, 1); w.number(0, 1); w.number(0, 8); w.number(0, 4);
        w.number(1, 1); w.number(0, 1); w.number(1, 1); w.number(1, 1); w.number(0, 4);
        if (datum.kind == KompasDatum::Plane) {
            w.number(0, 1); w.number(0x601e, 2);
            for (const auto value : datum.planeBox) w.real(value);
            for (const auto value : datum.placement) w.real(value);
            for (const auto value : datum.planeBounds) w.real(value);
        } else if (datum.kind == KompasDatum::Axis) {
            for (int i = 0; i < 6; ++i) w.real(datum.placement[i]);
        } else {
            for (const auto value : datum.placement) w.real(value);
            w.number(1, 1); w.number(0, 1); w.number(6, 8);
            for (const auto id : datum.datumIds) { w.number(1, 1); w.number(id, 2); }
        }
        if (w.bytes.size() > kMaxEnvelope) throw std::runtime_error("Oversized datum envelope");
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(w.bytes);
    return true;
}

} // namespace cadnext::gui
