#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <optional>
#include <vector>

namespace cadnext::gui {

// The four strings retain their MFC narrow/Unicode encoding for lossless
// section round trips. Names and storage ids identify configurations, not
// positions in the manager's list.
struct SolidWorksConfigurationHeaderEntry {
    bool mostRecent = false;
    QString name;
    quint32 id = 0;
    quint32 modifiedStamp = 0;
    QString displayName;
    quint32 parentId = 0xffffffff;
    quint32 parentField = 0;
    QString description;
    QString alternatePartName;
    std::array<bool, 4> unicodeStrings{true, true, true, true};
    quint32 nativeFlags = 0;
    quint32 nativeField = 0;
    std::array<quint32, 2> nativeStamps{};
};

struct SolidWorksConfigurationHeader {
    std::vector<SolidWorksConfigurationHeaderEntry> entries;
    bool managerFooter = true;
    bool extendedStamps = true;
    quint32 savedAt = 0;
    // Both observed record layouts end with the manager's format word 2.
    // Some sections also retain a trailing word; its semantics are unknown.
    std::optional<quint32> trailingField;
};

// Own codec for the complete CMgrHdr2 MFC archive, schema 1. Supports both
// per-configuration stamp layouts, inactive/derived configurations, and the
// manager footer. Also preserves the older layout without that footer, where
// nativeField is the entry's saved timestamp. Does not create Config-N, CMgr
// or a complete CAD document.
// Output is cleared on failure. Limits: 4096 entries/UTF-16 units per string,
// 64 MiB per section. Duplicate ids/names, dangling/cyclic parents, malformed
// class references, strings and footer are rejected.
bool decodeSolidWorksConfigurationHeader(const QByteArray& bytes,
    SolidWorksConfigurationHeader& header, QString& error);
bool encodeSolidWorksConfigurationHeader(const SolidWorksConfigurationHeader& header,
    QByteArray& bytes, QString& error);

} // namespace cadnext::gui
