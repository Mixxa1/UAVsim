#include "cadnext/gui/NativeKompasBodyApplication.hpp"

#include <QObject>

#include <stdexcept>
#include <utility>

namespace cadnext::gui {
namespace {

constexpr quint64 kLimit = 64 * 1024 * 1024;

struct Reader {
    const QByteArray& bytes;
    qsizetype at;
    quint64 number(int width) {
        if (width > bytes.size() - at)
            throw std::runtime_error("Truncated body application state");
        quint64 value = 0;
        for (int i = 0; i < width; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int width) {
        if (number(width) != value)
            throw std::runtime_error("Unsupported body application state layout");
    }
};

void validate(const KompasBodyApplicationState& state) {
    // Zero and the C3D reserved main-name interval cannot name a new body.
    if (!state.nativeName || state.nativeName >= 0xfffffffbu)
        throw std::runtime_error("Invalid native body name");
    const auto flags = [](const auto& values) {
        for (const auto value : values)
            if (value > 1) throw std::runtime_error("Invalid body application flag");
    };
    flags(state.nativeFlags);
    flags(state.nativeFooterFlags0);
    flags(state.nativeFooterFlags1);
}

// Inline class 0x0f47, with the supported fixed native attribute fields. These
// are format fields, not a copied document header. The variable body name is
// authored in the document's namespace. More attribute classes/payload layouts
// require their own parsers before they can be accepted here.
constexpr std::array<quint8, 10> kAttributeFields{2, 3, 2, 3, 3, 3, 3, 1, 0, 1};

QString failure(const std::exception& error) {
    return QObject::tr("Служебная запись тела КОМПАС: %1")
        .arg(QString::fromUtf8(error.what()));
}

} // namespace

bool decodeKompasBodyApplication(const QByteArray& bytes, qsizetype offset,
                                 const std::map<quint16, quint16>& registry,
                                 KompasBodyApplication& application,
                                 qsizetype& consumed, QString& error) {
    application = {}; consumed = 0; error.clear();
    if (offset < 0 || offset > bytes.size()) {
        error = QObject::tr("Недопустимое смещение служебной записи тела КОМПАС.");
        return false;
    }
    KompasBodyApplication staged;
    Reader r{bytes, offset};
    try {
        for (auto& value : staged.state.nativeFlags) value = quint8(r.number(1));
        r.expect(1, 8); // one inline attribute
        r.expect(0x0f470002, 4);
        for (const auto value : kAttributeFields) r.expect(value, 1);
        r.expect(0, 8);
        staged.state.nativeName = quint32(r.number(4));
        r.expect(3, 4);
        r.expect(0, 4);
        qsizetype tablesSize = 0;
        if (!decodeKompasTopologyTables(bytes, r.at, registry, staged.topology, tablesSize, error))
            return false;
        r.at += tablesSize;
        r.expect(0, 4);
        for (auto& value : staged.state.nativeFooterFlags0) value = quint8(r.number(1));
        r.expect(0, 4);
        for (auto& value : staged.state.nativeFooterFlags1) value = quint8(r.number(1));
        if (quint64(r.at - offset) > kLimit)
            throw std::runtime_error("Oversized body application state");
        validate(staged.state);
    } catch (const std::exception& e) { error = failure(e); return false; }
    consumed = r.at - offset;
    application = std::move(staged);
    return true;
}

bool encodeKompasBodyApplication(const KompasBodyApplication& application,
                                 const std::map<quint16, quint16>& registry,
                                 QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear();
    QByteArray staged;
    const auto number = [&](quint64 value, int width) {
        for (int i = 0; i < width; ++i) staged.append(char((value >> (8 * i)) & 0xff));
    };
    try {
        validate(application.state);
        QByteArray tables;
        if (!encodeKompasTopologyTables(application.topology, registry, tables, error)) return false;
        if (quint64(tables.size()) + 61 > kLimit)
            throw std::runtime_error("Oversized body application state");
        for (const auto value : application.state.nativeFlags) number(value, 1);
        number(1, 8); number(0x0f470002, 4);
        for (const auto value : kAttributeFields) number(value, 1);
        number(0, 8); number(application.state.nativeName, 4); number(3, 4); number(0, 4);
        staged += tables;
        number(0, 4);
        for (const auto value : application.state.nativeFooterFlags0) number(value, 1);
        number(0, 4);
        for (const auto value : application.state.nativeFooterFlags1) number(value, 1);
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(staged);
    return true;
}

bool decodeKompasBodyApplicationLink(const QByteArray& bytes, quint32& nativeName,
                                     QString& error) {
    nativeName = 0; error.clear();
    Reader r{bytes, 0};
    try {
        if (bytes.size() != 16)
            throw std::runtime_error("Unsupported body application link extent");
        r.expect(1, 8); r.expect(1, 4);
        KompasBodyApplicationState state;
        state.nativeName = quint32(r.number(4));
        validate(state);
        nativeName = state.nativeName;
    } catch (const std::exception& e) { error = failure(e); return false; }
    return true;
}

bool encodeKompasBodyApplicationLink(quint32 nativeName, QByteArray& bytes,
                                     QString& error) {
    bytes.clear(); error.clear();
    try {
        KompasBodyApplicationState state;
        state.nativeName = nativeName;
        validate(state);
    } catch (const std::exception& e) { error = failure(e); return false; }
    QByteArray staged;
    const auto number = [&](quint64 value, int width) {
        for (int i = 0; i < width; ++i) staged.append(char((value >> (8 * i)) & 0xff));
    };
    number(1, 8); number(1, 4); number(nativeName, 4);
    bytes = std::move(staged);
    return true;
}

} // namespace cadnext::gui
