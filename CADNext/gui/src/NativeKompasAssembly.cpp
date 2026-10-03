#include "cadnext/gui/NativeKompasAssembly.hpp"

#include <QObject>

#include <cmath>
#include <cstring>
#include <stdexcept>

namespace cadnext::gui {
namespace {

constexpr double kPi = 3.14159265358979323846;

struct Writer {
    QByteArray bytes;
    void number(quint64 value, int width) {
        for (int i = 0; i < width; ++i) bytes.append(char((value >> (8 * i)) & 0xff));
    }
    void zeros(int count) { bytes.append(count, '\0'); }
    void real(double value) {
        quint64 bits;
        std::memcpy(&bits, &value, sizeof bits);
        number(bits, 8);
    }
    void string(const QString& value) {
        number(quint64(value.size()), 4);
        for (const auto c : value) number(c.unicode(), 2);
    }
};

struct Reader {
    const QByteArray& bytes;
    qsizetype at = 0;
    quint64 number(int width) {
        if (width > bytes.size() - at) throw std::runtime_error("truncated");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value) throw std::runtime_error("layout");
    }
    void zeros(int count) {
        for (int i = 0; i < count; ++i) expect(0, 1);
    }
    double real() {
        const quint64 bits = number(8);
        double value;
        std::memcpy(&value, &bits, sizeof value);
        if (!std::isfinite(value)) throw std::runtime_error("real");
        return value;
    }
    QString string() {
        const auto count = number(4);
        if (count > 65536 || count * 2 > quint64(bytes.size() - at)) throw std::runtime_error("string");
        QString value;
        for (quint64 i = 0; i < count; ++i) value.append(QChar(ushort(number(2))));
        return value;
    }
    void end() const {
        if (at != bytes.size()) throw std::runtime_error("trailing");
    }
};

const QString kExclude = QStringLiteral("Исключить из расчета ");
const QString kFix = QStringLiteral("Фиксировать компонент");

// The component's data around its variables, as every sample has it. `field` writes or checks.
template <typename Field>
void runA(Field&& field) {
    field(0, 9);
    field(1, 1), field(1, 1), field(1, 1);
    field(0, 7);
    field(2, 1), field(0, 1), field(0x0440, 2); // an object of native class 0x0440: the component's variables
    field(0, 4);
    field(0xff, 1);
    field(0, 15);
}
template <typename Field>
void runC(Field&& field) {
    // A designation's separators ('-', '.', ' ') as /#204 has them, the default colour and material, then
    // flags and two null references.
    field(0, 4), field('-', 2), field(0, 4), field('.', 2), field(0, 4), field(' ', 2), field(0, 4);
    field(0x00909090, 4);
    for (const quint64 v : {50, 60, 80, 80, 100, 50}) field(v, 1);
    field(1, 4), field(1, 1), field(1, 1), field(0, 4), field(1, 4);
    field(0, 11);
    field(0xffffffffu, 4), field(0, 4), field(0xffffffffu, 4);
    field(0, 8);
    field(1, 1), field(4, 4);
}
template <typename Field>
void runD(Field&& field) {
    field(0, 4), field(0, 1), field(0xffffffffu, 4), field(0, 1), field(1, 1);
    field(0, 34);
}

} // namespace

std::vector<KompasDatum> kompasDefaultDatums(quint8 nativeType, quint16 firstObjectId, quint32 firstMainName) {
    const double c = std::cos(kPi / 2); // KOMPAS's own: cos 90°, not an exact zero
    struct Spec {
        KompasDatum::Kind kind;
        const char* title;
        quint32 color;
        quint32 nativeName;
        std::array<double, 12> placement;
    };
    const Spec specs[7] = {
        {KompasDatum::Plane, "Плоскость XY", 0xff9600, 1, {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}},
        {KompasDatum::Plane, "Плоскость ZX", 0x00ff80, 1, {0, 0, 0, 1, 0, 0, 0, c, -1, 0, 1, c}},
        {KompasDatum::Plane, "Плоскость ZY", 0x8080ff, 2, {0, 0, 0, c, 0, 1, 0, 1, 0, -1, 0, c}},
        {KompasDatum::Axis, "Ось X", 0x8080ff, 3, {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}},
        {KompasDatum::Axis, "Ось Y", 0x00ff80, 4, {0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1}},
        {KompasDatum::Axis, "Ось Z", 0xff9600, 5, {0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 1}},
        {KompasDatum::Origin, "Начало координат", 0x909090, 6, {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1}},
    };
    std::vector<KompasDatum> out;
    for (int i = 0; i < 7; ++i) {
        KompasDatum d;
        d.kind = specs[i].kind;
        d.objectId = quint16(firstObjectId + i);
        d.nativeType = nativeType;
        d.mainName = firstMainName + quint32(i);
        d.nativeName = specs[i].nativeName;
        d.title = QString::fromUtf8(specs[i].title);
        d.variableName = QStringLiteral("v%1").arg(i + 1);
        d.exclusionPrompt = kExclude;
        d.color = specs[i].color;
        d.placement = specs[i].placement;
        if (d.kind == KompasDatum::Origin)
            for (int k = 0; k < 6; ++k) d.datumIds.push_back(quint16(firstObjectId + k));
        out.push_back(std::move(d));
    }
    return out;
}

bool encodeKompasComponentRecord(const KompasComponentRecord& r, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (!r.index || r.index > 100000 || !r.bodies || r.bodies > 4096 || !r.instance || r.instance > 100000 || r.version < 3 ||
        r.version > 4 || r.instanceName.size() > 65536 || r.display.size() > 65536) {
        error = QObject::tr("Недопустимый компонент сборки КОМПАС.");
        return false;
    }
    for (const double v : r.box)
        if (!std::isfinite(v)) return error = QObject::tr("Недопустимый габарит компонента КОМПАС."), false;
    for (const double v : r.frame)
        if (!std::isfinite(v)) return error = QObject::tr("Недопустимое положение компонента КОМПАС."), false;
    Writer w;
    const auto field = [&](quint64 value, int width) {
        if (width > 8) w.zeros(width);
        else w.number(value, width);
    };
    w.number(r.version, 4);
    w.number(2, 1), w.number(0, 1), w.number(0x0416, 2); // an object of native class 0x0416: the component
    w.number(r.index, 4);
    w.number(0, 1);
    for (int copy = 0; copy < 3; ++copy)
        for (const double v : r.box) w.real(v);
    w.zeros(9);
    for (int i = 0; i < 4; ++i) w.number(1, 1);
    w.zeros(19);
    for (const double v : r.frame) w.real(v);
    w.number(1, 1), w.number(r.link, 2); // a reference to the file link
    const quint32 b = r.bodies, i = r.instance;
    for (const quint32 v : {14 + 3 * b + 2 * (i - 1), 7 + b, b, 2 + i, 0u, 4 + b + (i - 1)}) w.number(v, 4);
    runA(field);
    w.string(QStringLiteral("v%1").arg(6 + 2 * r.index));
    w.string(kExclude);
    w.number(0, 4);
    w.string(r.instanceName);
    runC(field);
    w.string(QStringLiteral("v%1").arg(7 + 2 * r.index));
    w.string(kFix);
    runD(field);
    w.string(r.display);
    w.number(0, 4);
    for (int row = 0; row < 4; ++row)
        for (int col = 0; col < 4; ++col) w.real(row == col ? 1.0 : 0.0); // an identity matrix
    w.zeros(5);
    w.number(7, 4);
    w.zeros(5);
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasComponentRecord(const QByteArray& bytes, KompasComponentRecord& r, QString& error) {
    r = {};
    error.clear();
    try {
        Reader rd{bytes};
        const auto field = [&](quint64 value, int width) {
            if (width > 8) rd.zeros(width);
            else rd.expect(value, width);
        };
        r.version = quint32(rd.number(4));
        if (r.version < 3 || r.version > 4) throw std::runtime_error("version");
        rd.expect(2, 1), rd.expect(0, 1), rd.expect(0x0416, 2);
        r.index = quint32(rd.number(4));
        if (!r.index) throw std::runtime_error("index");
        rd.expect(0, 1);
        for (double& v : r.box) v = rd.real();
        for (int copy = 1; copy < 3; ++copy)
            for (const double v : r.box)
                if (rd.real() != v) throw std::runtime_error("box");
        rd.zeros(9);
        for (int i = 0; i < 4; ++i) rd.expect(1, 1);
        rd.zeros(19);
        for (double& v : r.frame) v = rd.real();
        rd.expect(1, 1);
        r.link = quint16(rd.number(2));
        quint32 c[6];
        for (quint32& v : c) v = quint32(rd.number(4));
        r.bodies = c[2];
        r.instance = c[3] >= 3 ? c[3] - 2 : 0;
        const quint32 b = r.bodies, i = r.instance;
        if (!b || !i || c[0] != 14 + 3 * b + 2 * (i - 1) || c[1] != 7 + b || c[4] != 0 || c[5] != 4 + b + (i - 1))
            throw std::runtime_error("counters");
        runA(field);
        if (rd.string() != QStringLiteral("v%1").arg(6 + 2 * r.index) || rd.string() != kExclude) throw std::runtime_error("variable");
        rd.expect(0, 4);
        r.instanceName = rd.string();
        runC(field);
        if (rd.string() != QStringLiteral("v%1").arg(7 + 2 * r.index) || rd.string() != kFix) throw std::runtime_error("variable");
        runD(field);
        r.display = rd.string();
        rd.expect(0, 4);
        for (int row = 0; row < 4; ++row)
            for (int col = 0; col < 4; ++col)
                if (rd.real() != (row == col ? 1.0 : 0.0)) throw std::runtime_error("matrix");
        rd.zeros(5);
        rd.expect(7, 4);
        rd.zeros(5);
        rd.end();
        return true;
    } catch (const std::exception& failure) {
        r = {};
        error = QObject::tr("Компонент сборки КОМПАС вне поддержанного профиля v17 (%1).").arg(QString::fromUtf8(failure.what()));
        return false;
    }
}

namespace {
// The keys of components 1 to 21, as stored. A key belongs to the order in which the document's
// components were made, not to their place in its list: an assembly from which nothing was deleted
// holds exactly the first n keys of one sequence. 1–5 and their order: every v17 assembly of the
// samples. 6–21: the v24 assemblies (dolganin_SO_SPIDAR300) with 16, 20 and 21 components hold
// keys 1–16, 1–20 and 1–21 of this table, so these sets are certain; the order inside 6–16 and
// 17–20 is not established. A new assembly's k-th component is its k-th made, and takes the k-th
// key. (11 further keys are known as a set — a 32-component assembly, all of them also in a
// 97-component one — but not their order, and are left out.)
const std::array<std::array<quint8, 4>, kKompasAssemblyLinkKeys> kLinkKeys{{
    {0xac, 0x40, 0xf0, 0xb2}, {0xc4, 0x07, 0xad, 0x75}, {0xf1, 0x7d, 0xd7, 0x34}, {0x49, 0x40, 0xec, 0x19}, {0x90, 0x70, 0x0d, 0x89},
    {0x6e, 0x19, 0x57, 0x9f}, {0x4c, 0xfd, 0x18, 0x19}, {0xae, 0x09, 0x38, 0x25}, {0x42, 0xe6, 0xe7, 0x11}, {0x22, 0xb5, 0x43, 0x33},
    {0xe5, 0xaa, 0x8c, 0x88}, {0x11, 0x24, 0x79, 0x50}, {0x7f, 0x34, 0x94, 0xfa}, {0x67, 0xcd, 0x6d, 0x18}, {0x6f, 0x09, 0x15, 0x9b},
    {0x52, 0x9a, 0x80, 0xa2}, {0xec, 0xbd, 0xf1, 0x9a}, {0xd1, 0x0a, 0x4a, 0xc0}, {0x5b, 0xf1, 0x3b, 0x7e}, {0x72, 0x35, 0x48, 0xd5},
    {0xc4, 0x84, 0x87, 0xf7}}};

// The embodiment's entry, as in a part (encodeKompasMetaInfoLinks).
template <typename Field>
void linksHead(Field&& field) {
    field(0, 5);
    field(0x0a3c, 2);
    field(0, 12);
    field(1, 1);
}
} // namespace

bool encodeKompasAssemblyMetaInfoLinks(std::size_t components, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (!components || components > kKompasAssemblyLinkKeys) {
        error = QObject::tr("Связи MetaInfo сборки КОМПАС известны для 1–%1 компонентов.").arg(kKompasAssemblyLinkKeys);
        return false;
    }
    Writer w;
    w.number(components + 1, 4);
    linksHead([&](quint64 v, int n) { n > 8 ? w.zeros(n) : w.number(v, n); });
    for (std::size_t k = 0; k < components; ++k) {
        w.number(0, 1);
        w.number(0x0a3c, 2);
        for (const quint8 b : kLinkKeys[k]) w.number(b, 1);
        w.zeros(9);
    }
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasAssemblyMetaInfoLinks(const QByteArray& bytes, std::size_t& components, QString& error) {
    components = 0;
    error.clear();
    try {
        Reader r{bytes};
        const auto count = r.number(4);
        if (count < 2 || count > kKompasAssemblyLinkKeys + 1) throw std::runtime_error("count");
        linksHead([&](quint64 v, int n) { n > 8 ? r.zeros(n) : r.expect(v, n); });
        for (quint64 k = 0; k + 1 < count; ++k) {
            r.expect(0, 1);
            r.expect(0x0a3c, 2);
            for (const quint8 b : kLinkKeys[k]) r.expect(b, 1);
            r.zeros(9);
        }
        r.end();
        components = std::size_t(count - 1);
        return true;
    } catch (const std::exception&) {
        error = QObject::tr("Связи MetaInfo сборки КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

bool encodeKompasAssemblyModelCounter(quint32 lastObjectId, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    if (!lastObjectId || lastObjectId > 65535) return error = QObject::tr("Недопустимый счётчик сборки КОМПАС."), false;
    Writer w;
    w.number(lastObjectId, 4);
    w.number(0, 8);
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasAssemblyModelCounter(const QByteArray& bytes, quint32& lastObjectId, QString& error) {
    lastObjectId = 0;
    error.clear();
    try {
        Reader r{bytes};
        lastObjectId = quint32(r.number(4));
        r.expect(0, 8);
        r.end();
        return lastObjectId != 0 || (error = QObject::tr("Счётчик сборки КОМПАС пуст."), false);
    } catch (const std::exception&) {
        error = QObject::tr("Счётчик сборки КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

bool encodeKompasDocumentCounter(quint32 value, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    Writer w;
    w.number(0, 4);
    w.number(value, 4);
    bytes = std::move(w.bytes);
    return true;
}

bool decodeKompasDocumentCounter(const QByteArray& bytes, quint32& value, QString& error) {
    value = 0;
    error.clear();
    try {
        Reader r{bytes};
        r.expect(0, 4);
        value = quint32(r.number(4));
        r.end();
        return true;
    } catch (const std::exception&) {
        error = QObject::tr("Счётчик документа КОМПАС вне поддержанного профиля v17.");
        return false;
    }
}

} // namespace cadnext::gui
