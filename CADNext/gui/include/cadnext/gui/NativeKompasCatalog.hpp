#pragma once

#include "cadnext/gui/NativeKompasStorage.hpp"

#include <optional>

namespace cadnext::gui {

// A named stream or directory in the native archive. Numeric names and text
// names are distinct: numeric 100 is not the text "100". A stream references
// one complete compressed record in the supplied storage prefix.
struct KompasCatalogEntry {
    std::optional<quint16> numericName;
    QString textName;
    bool directory = false;
    bool enabled = true;
    std::vector<KompasCatalogEntry> children;
    std::size_t recordIndex = 0;
    quint16 position = 0;
};

struct KompasCatalog {
    quint32 version = 0x11001001;
    std::vector<quint32> versions{0x11001001, 0x11001011};
    // Archive settings are retained exactly; their six-byte application flags
    // are separate from the physical cluster size in SysInfo.
    QByteArray archiveSettings = QByteArray::fromHex("000000040001");
    std::vector<KompasCatalogEntry> entries;
    quint32 lastObjectId = 0;
};

// These functions author/validate the record catalog, not application model
// objects. A valid catalog alone does not make a complete M3D/A3D document.
// Output is cleared on every failure. Every physical record must have exactly
// one named owner, and references must cover its complete consecutive clusters.
bool encodeKompasCatalog(const KompasCatalog& catalog,
                         const KompasStoragePrefix& prefix,
                         QByteArray& bytes, QString& error);
bool decodeKompasCatalog(const QByteArray& bytes,
                         const std::vector<KompasRecordLocation>& records,
                         KompasCatalog& catalog, QString& error);

} // namespace cadnext::gui
