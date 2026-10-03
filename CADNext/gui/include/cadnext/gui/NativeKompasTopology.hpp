#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <map>
#include <optional>
#include <vector>

namespace cadnext::gui {

struct KompasTopologyName {
    std::vector<quint32> words;
    std::array<quint8, 3> flags{};
};

struct KompasFaceStyle {
    quint32 color = 0x00909090;
    std::array<quint8, 6> material{50, 60, 80, 80, 100, 50};
    // Preserve the native fields without assigning unverified meanings.
    quint32 field0 = 0;
    quint32 field1 = 0;
};

struct KompasTopologyProxy {
    quint16 id = 0;
    KompasTopologyName name;
    quint32 bodyNumber = 0;
    // A removed item in the operation history may have a null math pointer.
    std::optional<quint16> mathId;
    std::optional<KompasFaceStyle> faceStyle;
};

struct KompasTopologyGroup {
    quint32 mainName = 0;
    std::vector<KompasTopologyProxy> proxies;
};

// Native application ownership tables, ordered vertices / edges / faces.
// These are a component of the body record, not a complete M3D document.
struct KompasTopologyTables {
    std::array<std::vector<KompasTopologyGroup>, 3> groups;
};

// The supplied registry contains all previously serialized object IDs and
// their native classes. Math references must resolve to the matching topology
// kind; proxy IDs must not collide with any existing or newly written object.
// Outputs are cleared on failure. Decoding stops after the three tables and
// reports their size, so a caller can parse the remaining body fields.
bool decodeKompasTopologyTables(const QByteArray& bytes, qsizetype offset,
                                const std::map<quint16, quint16>& registry,
                                KompasTopologyTables& tables, qsizetype& consumed,
                                QString& error);
bool encodeKompasTopologyTables(const KompasTopologyTables& tables,
                                const std::map<quint16, quint16>& registry,
                                QByteArray& bytes, QString& error);

} // namespace cadnext::gui
