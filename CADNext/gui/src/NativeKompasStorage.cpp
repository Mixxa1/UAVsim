#include "cadnext/gui/NativeKompasStorage.hpp"

#include "cadnext/gui/NativeKompasGeometry.hpp"

#include <QObject>
#include <QSaveFile>
#include <QtEndian>

#include <algorithm>
#include <limits>
#include <set>
#include <utility>

#include <zlib.h>

namespace cadnext::gui {
namespace {

constexpr quint64 kClusterSize = 4096;
constexpr quint64 kMaxContents = 256ull * 1024 * 1024;
constexpr quint64 kMaxRecord = 64ull * 1024 * 1024;
constexpr quint64 kMaxDecoded = 512ull * 1024 * 1024;
constexpr std::size_t kMaxRecords = 8192;
constexpr quint32 kWriteVersion = 0x11001001;

template <typename T> void append(QByteArray& data, T value) {
    const T little = qToLittleEndian(value);
    data.append(reinterpret_cast<const char*>(&little), sizeof(little));
}
template <typename T> T value(const QByteArray& data, qsizetype at) {
    return qFromLittleEndian<T>(reinterpret_cast<const uchar*>(data.constData() + at));
}

quint64 clusters(qsizetype bytes) {
    return (quint64(bytes) + kClusterSize - 1) / kClusterSize;
}

std::vector<KompasRecordLocation> locations(const KompasContentsRecords& contents) {
    std::vector<KompasRecordLocation> out;
    quint64 first = 0;
    for (const auto& record : contents.records) {
        const quint64 count = clusters(record.compressedSize);
        out.push_back({record.offset, record.compressedSize, first, count});
        first += count;
    }
    return out;
}

bool sameLocations(const std::vector<KompasRecordLocation>& a,
                   const std::vector<KompasRecordLocation>& b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i)
        if (a[i].offset != b[i].offset || a[i].compressedSize != b[i].compressedSize ||
            a[i].firstCluster != b[i].firstCluster || a[i].clusterCount != b[i].clusterCount)
            return false;
    return true;
}

// Stored positions exclude KF and point to the end of each physical cluster.
// A record boundary starts a fresh cluster even if the previous one was short.
template <typename F> bool visitClusters(qsizetype offset, qsizetype bytes, F&& visit) {
    for (qsizetype at = 0; at < bytes;) {
        const quint16 used = quint16(std::min(quint64(bytes - at), kClusterSize));
        at += used;
        if (!visit(used, quint64(offset - 2 + at))) return false;
    }
    return true;
}

bool failure(QString& error) {
    error = QObject::tr("Каталог SysInfo КОМПАС-3D не согласован с кластерной структурой Contents.");
    return false;
}

void appendZip16(QByteArray& bytes, quint16 value) {
    bytes.append(char(value & 0xff));
    bytes.append(char(value >> 8));
}

void appendZip32(QByteArray& bytes, quint32 value) {
    appendZip16(bytes, quint16(value & 0xffff));
    appendZip16(bytes, quint16(value >> 16));
}

struct StoredMember {
    QByteArray name;
    const QByteArray* data = nullptr;
};

bool appendStoredMember(const StoredMember& member, QByteArray& archive,
                        QByteArray& directory, QString& error) {
    if (!member.data || member.name.isEmpty() || member.name.size() > 65535 ||
        member.name.contains(char('\0')) || member.name.startsWith('/') ||
        member.name.contains("..") ||
        member.data->size() > qsizetype(kMaxContents)) {
        error = QObject::tr("Недопустимый размер записи ZIP КОМПАС-3D.");
        return false;
    }
    const quint64 offset = quint64(archive.size());
    const quint64 size = quint64(member.data->size());
    if (offset > std::numeric_limits<quint32>::max() ||
        size > std::numeric_limits<quint32>::max()) {
        error = QObject::tr("Раздел ZIP КОМПАС-3D превышает формат ZIP32.");
        return false;
    }
    const quint32 crc = crc32(0,
        reinterpret_cast<const Bytef*>(member.data->constData()),
        static_cast<uInt>(member.data->size()));
    // Local file header; entries are deliberately stored so the exact C3D
    // byte stream is preserved and can be checked without a second codec.
    appendZip32(archive, 0x04034b50);
    appendZip16(archive, 20);
    appendZip16(archive, 1u << 11); // UTF-8 name flag
    appendZip16(archive, 0);         // stored method
    appendZip16(archive, 0); appendZip16(archive, 0); // DOS time/date
    appendZip32(archive, crc);
    appendZip32(archive, quint32(size)); appendZip32(archive, quint32(size));
    appendZip16(archive, quint16(member.name.size())); appendZip16(archive, 0);
    archive += member.name;
    archive += *member.data;

    // Central directory entry.
    appendZip32(directory, 0x02014b50);
    appendZip16(directory, 20); appendZip16(directory, 20);
    appendZip16(directory, 1u << 11); appendZip16(directory, 0);
    appendZip16(directory, 0); appendZip16(directory, 0);
    appendZip32(directory, crc);
    appendZip32(directory, quint32(size)); appendZip32(directory, quint32(size));
    appendZip16(directory, quint16(member.name.size()));
    appendZip16(directory, 0); appendZip16(directory, 0);
    appendZip16(directory, 0); appendZip16(directory, 0); appendZip32(directory, 0);
    appendZip32(directory, quint32(offset));
    directory += member.name;
    return true;
}

bool writeStoredArchive(const QString& path, const std::vector<StoredMember>& members,
                        QString& error) {
    if (members.empty() || members.size() > 65535) {
        error = QObject::tr("Недопустимое число записей ZIP КОМПАС-3D.");
        return false;
    }
    std::set<QByteArray> names;
    quint64 estimated = 22;
    for (const auto& member : members) {
        if (!member.data || member.name.isEmpty() || member.name.size() > 65535 ||
            member.name.contains(char('\0')) || member.name.startsWith('/') ||
            member.name.contains("..") || member.data->size() > qsizetype(kMaxContents) ||
            !names.insert(member.name).second) {
            error = QObject::tr("Недопустимая или повторная запись ZIP КОМПАС-3D.");
            return false;
        }
        const quint64 size = quint64(member.data->size());
        const quint64 name = quint64(member.name.size());
        if (estimated > 512ull * 1024 * 1024 - size - name * 2 - 76) {
            error = QObject::tr("Архив КОМПАС-3D превышает 512 МиБ.");
            return false;
        }
        estimated += size + name * 2 + 76;
    }
    QByteArray archive;
    QByteArray directory;
    archive.reserve(qsizetype(estimated));
    directory.reserve(qsizetype(members.size() * 64));
    for (const auto& member : members)
        if (!appendStoredMember(member, archive, directory, error)) return false;
    const quint64 directoryOffset = quint64(archive.size());
    const quint64 directorySize = quint64(directory.size());
    if (directoryOffset > std::numeric_limits<quint32>::max() ||
        directorySize > std::numeric_limits<quint32>::max()) {
        error = QObject::tr("Каталог ZIP КОМПАС-3D превышает формат ZIP32.");
        return false;
    }
    archive += directory;
    appendZip32(archive, 0x06054b50);
    appendZip16(archive, 0); appendZip16(archive, 0);
    appendZip16(archive, quint16(members.size()));
    appendZip16(archive, quint16(members.size()));
    appendZip32(archive, quint32(directorySize));
    appendZip32(archive, quint32(directoryOffset));
    appendZip16(archive, 0);
    if (quint64(archive.size()) > 512ull * 1024 * 1024) {
        error = QObject::tr("Архив КОМПАС-3D превышает 512 МиБ.");
        return false;
    }
    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) ||
        output.write(archive) != archive.size() || !output.commit()) {
        error = QObject::tr("Не удалось сохранить архив КОМПАС-3D: %1")
                    .arg(output.errorString());
        return false;
    }
    return true;
}

} // namespace

bool prepareKompasStorageRecords(const std::vector<QByteArray>& records,
                                KompasStoragePrefix& prefix, QString& error) {
    prefix = {}; error.clear();
    if (records.empty() || records.size() > kMaxRecords) {
        error = QObject::tr("Для Contents требуется от 1 до 8192 записей.");
        return false;
    }
    quint64 decoded = 0;
    for (const auto& record : records) {
        if (quint64(record.size()) > kMaxRecord ||
            quint64(record.size()) > kMaxDecoded - decoded) {
            error = QObject::tr("Превышен предел размера записей Contents.");
            return false;
        }
        decoded += quint64(record.size());
    }
    KompasStoragePrefix staged;
    staged.contents = QByteArray("KF", 2);
    quint64 nextCluster = 0;
    for (const auto& record : records) {
        uLongf size = compressBound(uLong(record.size()));
        QByteArray packed(qsizetype(size), Qt::Uninitialized);
        if (compress2(reinterpret_cast<Bytef*>(packed.data()), &size,
                      reinterpret_cast<const Bytef*>(record.constData()),
                      uLong(record.size()), Z_DEFAULT_COMPRESSION) != Z_OK) {
            error = QObject::tr("Не удалось сжать запись Contents.");
            return false;
        }
        packed.resize(qsizetype(size));
        if (quint64(packed.size()) > kMaxContents - quint64(staged.contents.size())) {
            error = QObject::tr("Раздел Contents превышает 256 МиБ.");
            return false;
        }
        const quint64 count = clusters(packed.size());
        staged.records.push_back({staged.contents.size(), packed.size(), nextCluster, count});
        nextCluster += count;
        staged.contents += packed;
    }
    prefix = std::move(staged);
    return true;
}

bool decodeKompasStorageIndex(const QByteArray& contents, const QByteArray& sysInfo,
                              KompasStorageIndex& index, QString& error) {
    index = {}; error.clear();
    if (sysInfo.size() < 46 || !sysInfo.startsWith("KF")) return failure(error);
    const quint32 version = value<quint32>(sysInfo, 2);
    if (version != kWriteVersion && version != 0x13000005) {
        error = QObject::tr("Не поддерживается версия кластерного каталога КОМПАС-3D: %1.")
                    .arg(version, 8, 16, QChar(u'0'));
        return false;
    }
    if (value<quint16>(sysInfo, 14) != kClusterSize ||
        value<quint32>(sysInfo, 32) != 0 || contents.size() < 2 ||
        value<quint64>(sysInfo, 24) != quint64(contents.size() - 2)) return failure(error);
    KompasContentsRecords decoded;
    if (!decodeKompasContentsRecords(contents, decoded, error)) return false;
    if (decoded.tail.isEmpty()) return failure(error);
    auto records = locations(decoded);
    const quint64 firstCatalog = records.back().firstCluster + records.back().clusterCount;
    const quint64 catalogCount = clusters(decoded.tail.size());
    const quint64 count = firstCatalog + catalogCount;
    // Bounds are derived from the already limited Contents, before any loop or
    // allocation controlled by an untrusted u64 in SysInfo.
    if (value<quint64>(sysInfo, 6) != count || value<quint64>(sysInfo, 16) != catalogCount ||
        quint64(sysInfo.size()) != 36 + 10 * (count - 1) + 2 + 8 * catalogCount)
        return failure(error);
    qsizetype at = 36;
    const auto check = [&](quint16 used, quint64 end) {
        if (value<quint16>(sysInfo, at) != used || value<quint64>(sysInfo, at + 2) != end)
            return false;
        at += 10;
        return true;
    };
    for (const auto& record : records)
        if (!visitClusters(record.offset, record.compressedSize, check)) return failure(error);
    const qsizetype fullCatalog = qsizetype((catalogCount - 1) * kClusterSize);
    if (!visitClusters(decoded.tailOffset, fullCatalog, check)) return failure(error);
    if (value<quint16>(sysInfo, at) != quint64(decoded.tail.size()) - quint64(fullCatalog))
        return failure(error);
    at += 2;
    for (quint64 i = 0; i < catalogCount; ++i, at += 8)
        if (value<quint64>(sysInfo, at) != firstCatalog + i) return failure(error);
    index = {version, count, firstCatalog, catalogCount, decoded.tailOffset, std::move(records)};
    return true;
}

bool finishKompasStorage(const KompasStoragePrefix& prefix, const QByteArray& catalog,
                         KompasStorageImage& image, QString& error) {
    image = {}; error.clear();
    if (catalog.isEmpty() || quint64(catalog.size()) > kMaxContents ||
        quint64(prefix.contents.size()) > kMaxContents - quint64(catalog.size())) {
        error = QObject::tr("Каталог объектов пуст или Contents превышает 256 МиБ.");
        return false;
    }
    KompasContentsRecords decoded;
    if (!decodeKompasContentsRecords(prefix.contents, decoded, error)) return false;
    const auto records = locations(decoded);
    if (!decoded.tail.isEmpty() || !sameLocations(records, prefix.records)) return failure(error);
    KompasStorageImage staged;
    staged.contents = prefix.contents + catalog;
    const quint64 firstCatalog = records.back().firstCluster + records.back().clusterCount;
    const quint64 catalogCount = clusters(catalog.size());
    staged.sysInfo = QByteArray("KF", 2);
    append(staged.sysInfo, kWriteVersion);
    append(staged.sysInfo, firstCatalog + catalogCount);
    append(staged.sysInfo, quint16(kClusterSize));
    append(staged.sysInfo, catalogCount);
    append(staged.sysInfo, quint64(staged.contents.size() - 2));
    append(staged.sysInfo, quint32(0));
    const auto write = [&](quint16 used, quint64 end) {
        append(staged.sysInfo, used); append(staged.sysInfo, end); return true;
    };
    for (const auto& record : records) visitClusters(record.offset, record.compressedSize, write);
    const qsizetype fullCatalog = qsizetype((catalogCount - 1) * kClusterSize);
    visitClusters(prefix.contents.size(), fullCatalog, write);
    append(staged.sysInfo, quint16(catalog.size() - fullCatalog));
    for (quint64 i = 0; i < catalogCount; ++i) append(staged.sysInfo, firstCatalog + i);
    // Besides detecting an ambiguous zlib-looking catalog start, this also
    // protects callers from publishing malformed lengths or edited prefixes.
    KompasStorageIndex checked;
    if (!decodeKompasStorageIndex(staged.contents, staged.sysInfo, checked, error)) return false;
    image = std::move(staged);
    return true;
}

bool writeKompasStorageArchive(const QString& path,
                               const KompasStorageImage& image,
                               QString& error) {
    return writeKompasStorageArchive(path, image, {}, error);
}

bool writeKompasStorageArchive(
    const QString& path, const KompasStorageImage& image,
    const std::vector<KompasStorageArchiveMember>& extras, QString& error) {
    error.clear();
    if (image.contents.isEmpty() || image.sysInfo.isEmpty() ||
        quint64(image.contents.size()) > kMaxContents ||
        quint64(image.sysInfo.size()) > kMaxContents) {
        error = QObject::tr("Хранилище КОМПАС-3D пусто или превышает 256 МиБ.");
        return false;
    }
    KompasStorageIndex checked;
    if (!decodeKompasStorageIndex(image.contents, image.sysInfo, checked, error))
        return false;

    std::vector<StoredMember> members;
    members.reserve(2 + extras.size());
    members.push_back({QByteArrayLiteral("Contents"), &image.contents});
    members.push_back({QByteArrayLiteral("SysInfo"), &image.sysInfo});
    for (const auto& extra : extras)
        members.push_back({extra.name, &extra.data});
    return writeStoredArchive(path, members, error);
}

} // namespace cadnext::gui
