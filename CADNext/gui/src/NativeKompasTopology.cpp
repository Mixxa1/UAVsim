#include "cadnext/gui/NativeKompasTopology.hpp"

#include <QObject>

#include <set>
#include <stdexcept>

namespace cadnext::gui {
namespace {

constexpr std::array<quint16, 3> kProxyClasses{0x7c69, 0x1408, 0x110f};
constexpr std::array<quint16, 3> kMathClasses{0x0b04, 0x4313, 0x666e};
constexpr quint64 kLimit = 65535;
constexpr qsizetype kByteLimit = 64 * 1024 * 1024;

struct Reader {
    const QByteArray& bytes;
    qsizetype at, start;
    quint64 number(int size) {
        if (size > bytes.size() - at || size > kByteLimit - (at - start))
            throw std::runtime_error("Truncated or oversized topology tables");
        quint64 value = 0;
        for (int i = 0; i < size; ++i) value |= quint64(uchar(bytes[at++])) << (8 * i);
        return value;
    }
    void expect(quint64 value, int size) {
        if (number(size) != value) throw std::runtime_error("Unsupported topology table framing");
    }
    quint64 count() {
        const auto result = number(8);
        if (result > kLimit) throw std::runtime_error("Too many topology table items");
        return result;
    }
};

void validateProxy(const KompasTopologyProxy& p, quint32 mainName, std::size_t kind,
                   const std::map<quint16, quint16>& registry, std::set<quint16>& ids) {
    if (!p.id || registry.count(p.id) || !ids.insert(p.id).second)
        throw std::runtime_error("Duplicate or invalid topology proxy ID");
    if (p.name.words.empty() || p.name.words.size() > 16 || p.name.words.front() != mainName)
        throw std::runtime_error("Invalid grouped topology name");
    if (!p.bodyNumber || p.bodyNumber > 4096)
        throw std::runtime_error("Invalid topology body number");
    if (p.mathId) {
        const auto found = registry.find(*p.mathId);
        if (found == registry.end() || found->second != kMathClasses[kind])
            throw std::runtime_error("Topology math reference has the wrong object class");
    }
    if (p.faceStyle.has_value() != (kind == 2))
        throw std::runtime_error("Face style does not match topology kind");
}

QString failure(const std::exception& e) {
    return QObject::tr("Таблицы топологии КОМПАС: %1").arg(QString::fromUtf8(e.what()));
}

} // namespace

bool decodeKompasTopologyTables(const QByteArray& bytes, qsizetype offset,
                                const std::map<quint16, quint16>& registry,
                                KompasTopologyTables& tables, qsizetype& consumed,
                                QString& error) {
    tables = {}; consumed = 0; error.clear();
    if (offset < 0 || offset > bytes.size()) {
        error = QObject::tr("Недопустимое смещение таблиц топологии КОМПАС.");
        return false;
    }
    KompasTopologyTables staged;
    Reader r{bytes, offset, offset};
    std::set<quint16> ids;
    quint64 totalGroups = 0, totalProxies = 0;
    try {
        for (std::size_t kind = 0; kind < 3; ++kind) {
            r.expect(1, 1);
            const auto count = r.count();
            if ((totalGroups += count) > kLimit) throw std::runtime_error("Too many topology groups");
            for (quint64 i = 0; i < count; ++i) {
                r.expect(0x0c7a0002, 4);
                KompasTopologyGroup group;
                group.mainName = quint32(r.number(4));
                const auto size = r.count();
                if ((totalProxies += size) > kLimit) throw std::runtime_error("Too many topology proxies");
                for (quint64 j = 0; j < size; ++j) {
                    r.expect(0x8002, 2); r.expect(kProxyClasses[kind], 2); r.expect(1, 1);
                    KompasTopologyProxy p;
                    p.id = quint16(r.number(2));
                    const auto words = r.number(1);
                    if (!words || words > 16) throw std::runtime_error("Invalid topology name length");
                    for (quint64 k = 0; k < words; ++k) p.name.words.push_back(quint32(r.number(4)));
                    for (auto& flag : p.name.flags) flag = quint8(r.number(1));
                    p.bodyNumber = quint32(r.number(4));
                    const auto tag = r.number(1);
                    if (tag == 1) p.mathId = quint16(r.number(2));
                    else if (tag != 0) throw std::runtime_error("Unsupported topology math pointer");
                    if (kind == 2) {
                        KompasFaceStyle style;
                        style.color = quint32(r.number(4));
                        for (auto& item : style.material) item = quint8(r.number(1));
                        style.field0 = quint32(r.number(4)); style.field1 = quint32(r.number(4));
                        p.faceStyle = style;
                    }
                    validateProxy(p, group.mainName, kind, registry, ids);
                    group.proxies.push_back(std::move(p));
                }
                staged.groups[kind].push_back(std::move(group));
            }
        }
    } catch (const std::exception& e) { error = failure(e); return false; }
    consumed = r.at - offset;
    tables = std::move(staged);
    return true;
}

bool encodeKompasTopologyTables(const KompasTopologyTables& tables,
                                const std::map<quint16, quint16>& registry,
                                QByteArray& bytes, QString& error) {
    bytes.clear(); error.clear();
    QByteArray staged;
    const auto number = [&](quint64 value, int size) {
        if (size > kByteLimit - staged.size()) throw std::runtime_error("Oversized topology tables");
        for (int i = 0; i < size; ++i) staged.append(char((value >> (8 * i)) & 0xff));
    };
    std::set<quint16> ids;
    quint64 totalGroups = 0, totalProxies = 0;
    try {
        for (std::size_t kind = 0; kind < 3; ++kind) {
            const auto& groups = tables.groups[kind];
            if ((totalGroups += groups.size()) > kLimit) throw std::runtime_error("Too many topology groups");
            number(1, 1); number(groups.size(), 8);
            for (const auto& group : groups) {
                if ((totalProxies += group.proxies.size()) > kLimit) throw std::runtime_error("Too many topology proxies");
                number(0x0c7a0002, 4); number(group.mainName, 4); number(group.proxies.size(), 8);
                for (const auto& p : group.proxies) {
                    validateProxy(p, group.mainName, kind, registry, ids);
                    number(0x8002, 2); number(kProxyClasses[kind], 2); number(1, 1); number(p.id, 2);
                    number(p.name.words.size(), 1);
                    for (const auto word : p.name.words) number(word, 4);
                    for (const auto flag : p.name.flags) number(flag, 1);
                    number(p.bodyNumber, 4); number(p.mathId ? 1 : 0, 1);
                    if (p.mathId) number(*p.mathId, 2);
                    if (p.faceStyle) {
                        number(p.faceStyle->color, 4);
                        for (const auto item : p.faceStyle->material) number(item, 1);
                        number(p.faceStyle->field0, 4); number(p.faceStyle->field1, 4);
                    }
                }
            }
        }
    } catch (const std::exception& e) { error = failure(e); return false; }
    bytes = std::move(staged);
    return true;
}

} // namespace cadnext::gui
