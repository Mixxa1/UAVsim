#pragma once

#include <QByteArray>
#include <QString>
#include <QtGlobal>

#include <vector>

namespace cadnext::gui {

// Physical C3D clusters hold at most 4096 bytes. An independently compressed
// record can occupy several clusters; object catalog references use cluster
// numbers, not record ordinals or offsets into the decoded geometry.
struct KompasRecordLocation {
    qsizetype offset = 0; // including the two-byte KF tag
    qsizetype compressedSize = 0;
    quint64 firstCluster = 0;
    quint64 clusterCount = 0;
};

struct KompasStoragePrefix {
    QByteArray contents; // KF followed by complete zlib members, no catalog yet
    std::vector<KompasRecordLocation> records;
};

struct KompasStorageImage {
    QByteArray contents;
    QByteArray sysInfo;
};

struct KompasStorageArchiveMember {
    QByteArray name;
    QByteArray data;
};

struct KompasStorageIndex {
    quint32 version = 0;
    quint64 clusterCount = 0;
    quint64 firstCatalogCluster = 0;
    quint64 catalogClusterCount = 0;
    qsizetype catalogOffset = 0;
    std::vector<KompasRecordLocation> records;
};

// Separating these steps lets a document writer build its catalog using the
// actual cluster numbers AFTER compression. There is no source-file template.
// Writing uses the observed v17 (0x11001001) storage version; the caller must
// author document objects for that version. All outputs are cleared on failure.
// Storage is NOT a complete M3D/A3D: the document objects and their catalog
// still have to be authored correctly.
bool prepareKompasStorageRecords(const std::vector<QByteArray>& records,
                                KompasStoragePrefix& prefix, QString& error);
bool finishKompasStorage(const KompasStoragePrefix& prefix,
                         const QByteArray& catalog,
                         KompasStorageImage& image, QString& error);

// Writes the independently validated storage image as a modern stored ZIP
// container with the two physical members used by C3D: Contents and SysInfo.
// The output is atomic. This is a complete container for the supplied storage
// image; it does not invent MetaInfo or the application/model object graph.
bool writeKompasStorageArchive(const QString& path,
                               const KompasStorageImage& image,
                               QString& error);
bool writeKompasStorageArchive(const QString& path,
                               const KompasStorageImage& image,
                               const std::vector<KompasStorageArchiveMember>& extras,
                               QString& error);

// Independently checks every cluster length, address, record checksum, total
// size and catalog reference in the observed 64-bit ZIP storage layout.
// It does not infer that opaque document objects form a valid model.
bool decodeKompasStorageIndex(const QByteArray& contents, const QByteArray& sysInfo,
                              KompasStorageIndex& index, QString& error);

} // namespace cadnext::gui
