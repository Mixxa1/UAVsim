#pragma once

#include <QByteArray>
#include <QString>

#include <array>
#include <vector>

namespace cadnext::gui {

struct CompoundFileEntry {
    enum class Kind { Storage, Stream };
    // Paths are virtual storage paths. Each UTF-16 name has at most 31 units.
    // Parent storages must be supplied explicitly, including empty storages.
    QString path;
    Kind kind = Kind::Stream;
    QByteArray data;
    std::array<quint8, 16> classId{};
    quint32 stateBits = 0;
    quint64 createdAt = 0;
    quint64 modifiedAt = 0;
};

struct CompoundFile {
    std::array<quint8, 16> rootClassId{};
    quint32 rootStateBits = 0;
    quint64 rootModifiedAt = 0;
    std::vector<CompoundFileEntry> entries;
};

// Own MS-CFB container codec, including FAT, MiniFAT, DIFAT and directory trees.
// Reads versions 3 and 4; writes version 3 with 512-byte sectors. Does not write
// to disk or extract virtual paths onto the filesystem. Outputs reset on error.
// Limits: 512 MiB container/total data, 256 MiB per stream, 65536 entries and
// 64 storage levels. Application-specific document graphs remain separate.
bool decodeCompoundFile(const QByteArray& bytes, CompoundFile& file, QString& error);
bool encodeCompoundFile(const CompoundFile& file, QByteArray& bytes, QString& error);

} // namespace cadnext::gui
