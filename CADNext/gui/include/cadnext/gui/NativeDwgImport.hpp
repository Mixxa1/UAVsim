#pragma once

#include <QByteArray>
#include <QString>
#include <QtGlobal>

#include <vector>

namespace cadnext::gui {

// Physical DWG page. Offsets and sizes refer to the original file.
struct DwgPageInfo {
    quint32 number = 0;
    quint32 size = 0;
    quint64 fileOffset = 0;
};

struct DwgSectionPageInfo {
    quint32 pageNumber = 0;
    quint32 storedDataSize = 0;
    quint64 sectionOffset = 0;
};

struct DwgSectionInfo {
    QString name;
    quint32 id = 0;
    quint64 logicalSize = 0;
    quint32 maxPageSize = 0;
    quint32 compression = 0;
    quint32 encryption = 0;
    std::vector<DwgSectionPageInfo> pages;
};

struct DwgStructure {
    QString version;
    quint64 fileSize = 0;
    quint32 securityFlags = 0;
    quint32 sectionMapPageId = 0;
    quint32 pageMapPageId = 0;
    std::vector<DwgPageInfo> pages;
    std::vector<DwgSectionInfo> sections;
};

// Reads and validates the AC1018/AC1024/AC1027/AC1032 container header,
// page map, section map and section-page metadata. This does not interpret
// AcDb object bit streams or imply that geometry was imported.
bool readDwgStructure(const QString& path, DwgStructure& structure, QString& error);

// Extracts one named DWG section as its exact logical byte stream. Masked
// page headers, page checksums, bounds, gaps and LZ77 data are checked.
bool readDwgSection(const QString& path, const DwgStructure& structure,
                    const QString& sectionName, QByteArray& bytes, QString& error);

} // namespace cadnext::gui
