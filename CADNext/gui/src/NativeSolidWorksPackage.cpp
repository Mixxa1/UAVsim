#include "cadnext/gui/NativeSolidWorksPackage.hpp"

#include <QObject>

#include <zlib.h>

#include <cstring>

namespace cadnext::gui {
namespace {

constexpr qint64 kMaxFile = 512ll * 1024 * 1024;
constexpr quint32 kMaxEntry = 256u * 1024 * 1024;
constexpr int kShift = 4;
const char kVersionFlagsMethod[6] = {0x14, 0x00, 0x06, 0x00, 0x08, 0x00};

quint32 le32(const QByteArray& b, qint64 at) {
    return quint32(uchar(b[at])) | quint32(uchar(b[at + 1])) << 8 | quint32(uchar(b[at + 2])) << 16 | quint32(uchar(b[at + 3])) << 24;
}
quint16 le16(const QByteArray& b, qint64 at) { return quint16(uchar(b[at]) | uchar(b[at + 1]) << 8); }
void put16(QByteArray& b, quint16 v) { b.append(char(v & 0xFF)); b.append(char(v >> 8)); }
void put32(QByteArray& b, quint32 v) { put16(b, quint16(v & 0xFFFF)); put16(b, quint16(v >> 16)); }

// A name as stored: each byte rotated right by the shift (read back rotated left).
QByteArray rotated(const QByteArray& name, int shift, bool store) {
    QByteArray out = name;
    for (char& c : out) {
        const unsigned v = uchar(c);
        c = char(store ? ((v >> shift) | (v << (8 - shift))) & 0xFF : ((v << shift) | (v >> (8 - shift))) & 0xFF);
    }
    return out;
}

bool deflateRaw(const QByteArray& data, QByteArray& packed, bool& text) {
    z_stream stream{};
    if (deflateInit2(&stream, 1, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) return false;
    packed.resize(qsizetype(deflateBound(&stream, uLong(data.size()))));
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(data.constData()));
    stream.avail_in = uInt(data.size());
    stream.next_out = reinterpret_cast<Bytef*>(packed.data());
    stream.avail_out = uInt(packed.size());
    const int status = deflate(&stream, Z_FINISH);
    text = stream.data_type == Z_TEXT;
    packed.resize(qsizetype(stream.total_out));
    deflateEnd(&stream);
    return status == Z_STREAM_END;
}

bool inflateRaw(const char* source, quint32 packedSize, quint32 unpackedSize, QByteArray& output) {
    output.resize(unpackedSize);
    z_stream stream{};
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(source));
    stream.avail_in = packedSize;
    stream.next_out = reinterpret_cast<Bytef*>(output.data());
    stream.avail_out = unpackedSize;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return false;
    const int status = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    return status == Z_STREAM_END && stream.total_in == packedSize && stream.total_out == unpackedSize;
}

QByteArray signature(const std::array<quint8, 4>& s) { return QByteArray(reinterpret_cast<const char*>(s.data()), 4); }

struct Packed {
    QByteArray data;
    quint32 crc = 0;
    bool text = false;
};

bool pack(const SolidWorksPackageEntry& entry, Packed& packed) {
    if (!deflateRaw(entry.data, packed.data, packed.text)) return false;
    packed.crc = quint32(crc32(0, reinterpret_cast<const Bytef*>(entry.data.constData()), uInt(entry.data.size())));
    return true;
}

QByteArray record(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry, const Packed& packed) {
    QByteArray out = signature(package.localSignature);
    out.append(kVersionFlagsMethod, 6);
    put32(out, entry.stamp);
    put32(out, packed.crc);
    put32(out, quint32(packed.data.size()));
    put32(out, quint32(entry.data.size()));
    put32(out, quint32(entry.name.size()));
    out += rotated(entry.name, kShift, true);
    out += packed.data;
    return out;
}

QByteArray directoryEntry(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry, const Packed& packed,
                          quint32 offset) {
    QByteArray out = signature(package.directorySignature);
    put16(out, 0);
    out.append(kVersionFlagsMethod, 6);
    put32(out, entry.stamp);
    put32(out, packed.crc);
    put32(out, quint32(packed.data.size()));
    put32(out, quint32(entry.data.size()));
    put16(out, quint16(entry.name.size()));
    put16(out, 0);
    put16(out, 0);
    put16(out, 0);
    put16(out, entry.text ? 1 : 0);
    put32(out, 0);
    put32(out, offset);
    out += rotated(entry.name, kShift, true);
    return out;
}

} // namespace

QByteArray encodeSolidWorksPackageRecord(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry, bool* text) {
    Packed packed;
    if (!pack(entry, packed)) return {};
    if (text) *text = packed.text;
    return record(package, entry, packed);
}

QByteArray encodeSolidWorksPackageDirectoryEntry(const SolidWorksPackage& package, const SolidWorksPackageEntry& entry,
                                                 quint32 offset) {
    Packed packed;
    if (!pack(entry, packed)) return {};
    return directoryEntry(package, entry, packed, offset);
}

bool encodeSolidWorksPackage(const SolidWorksPackage& package, QByteArray& file, QString& error) {
    file.clear();
    error.clear();
    if (package.entries.empty() || package.entries.size() > 65535) {
        error = QObject::tr("Пакету SOLIDWORKS нужно от 1 до 65535 потоков.");
        return false;
    }
    QByteArray out = signature(package.key);
    out.append(QByteArray::fromHex("000000"));
    out.append(char(kShift));
    QByteArray directory;
    for (const auto& entry : package.entries) {
        if (entry.name.isEmpty() || entry.name.size() > 512 || quint64(entry.data.size()) > kMaxEntry) {
            error = QObject::tr("Поток пакета SOLIDWORKS «%1»: имя от 1 до 512 байт, данные до 256 МиБ.").arg(QString::fromLatin1(entry.name));
            return false;
        }
        Packed packed;
        if (!pack(entry, packed)) {
            error = QObject::tr("Не удалось сжать поток пакета SOLIDWORKS «%1».").arg(QString::fromLatin1(entry.name));
            return false;
        }
        directory += directoryEntry(package, entry, packed, quint32(out.size() - 8));
        out += record(package, entry, packed);
        if (out.size() + directory.size() > kMaxFile) {
            error = QObject::tr("Пакет SOLIDWORKS превышает 512 МиБ.");
            return false;
        }
    }
    const quint32 directoryOffset = quint32(out.size() - 8);
    out += directory;
    out += signature(package.endSignature);
    put32(out, 0);
    put16(out, quint16(package.entries.size()));
    put16(out, quint16(package.entries.size()));
    put32(out, quint32(directory.size()));
    put32(out, directoryOffset);
    put16(out, 0);
    file = std::move(out);
    return true;
}

bool decodeSolidWorksPackage(const QByteArray& file, SolidWorksPackage& package, QString& error,
                             SolidWorksPackageLayout* layout) {
    package = {};
    package.entries.clear();
    error.clear();
    if (layout) *layout = {};
    if (file.size() < 8 + 22 || file.size() > kMaxFile || file[4] != 0 || file[5] != 0 || file[6] != 0 || uchar(file[7]) != kShift) {
        error = QObject::tr("Это не пакет SOLIDWORKS 2015 и новее (нет заголовка с шагом 4).");
        return false;
    }
    // The end record: the one whose directory ends where the record starts and parses to its count.
    for (qint64 p = file.size() - 22; p >= 8; --p) {
        if (le32(file, p + 4) != 0 || le16(file, p + 20) != 0) continue;
        const quint16 count = le16(file, p + 8);
        const quint32 size = le32(file, p + 12), offset = le32(file, p + 16);
        if (count == 0 || count != le16(file, p + 10) || qint64(offset) + 8 + size != p || size < 46u * count) continue;
        SolidWorksPackage candidate;
        SolidWorksPackageLayout where;
        where.directory = qint64(offset) + 8;
        where.endRecord = p;
        std::memcpy(candidate.key.data(), file.constData(), 4);
        std::memcpy(candidate.endSignature.data(), file.constData() + p, 4);
        std::memcpy(candidate.directorySignature.data(), file.constData() + where.directory, 4);
        qint64 q = where.directory;
        bool good = true;
        for (quint16 i = 0; good && i < count; ++i) {
            if (q + 46 > p || std::memcmp(file.constData() + q, candidate.directorySignature.data(), 4) != 0 || le16(file, q + 4) != 0 ||
                std::memcmp(file.constData() + q + 6, kVersionFlagsMethod, 6) != 0) { good = false; break; }
            SolidWorksPackageEntry entry;
            entry.stamp = le32(file, q + 12);
            const quint32 crc = le32(file, q + 16), packedSize = le32(file, q + 20), unpackedSize = le32(file, q + 24);
            const quint16 nameSize = le16(file, q + 28);
            const quint16 internal = le16(file, q + 36);
            const quint32 recordOffset = le32(file, q + 42);
            if (le16(file, q + 30) != 0 || le16(file, q + 32) != 0 || le16(file, q + 34) != 0 || internal > 1 || le32(file, q + 38) != 0 ||
                nameSize == 0 || nameSize > 512 || q + 46 + nameSize > p || packedSize > kMaxEntry || unpackedSize > kMaxEntry) { good = false; break; }
            entry.text = internal == 1;
            entry.name = rotated(file.mid(q + 46, nameSize), kShift, false);
            // Its record.
            const qint64 a = qint64(recordOffset) + 8;
            if (a + 30 + nameSize + qint64(packedSize) > where.directory || std::memcmp(file.constData() + a + 4, kVersionFlagsMethod, 6) != 0 ||
                le32(file, a + 10) != entry.stamp || le32(file, a + 14) != crc || le32(file, a + 18) != packedSize ||
                le32(file, a + 22) != unpackedSize || le32(file, a + 26) != nameSize ||
                file.mid(a + 30, nameSize) != file.mid(q + 46, nameSize)) { good = false; break; }
            if (i == 0) std::memcpy(candidate.localSignature.data(), file.constData() + a, 4);
            else if (std::memcmp(file.constData() + a, candidate.localSignature.data(), 4) != 0) { good = false; break; }
            if (!inflateRaw(file.constData() + a + 30 + nameSize, packedSize, unpackedSize, entry.data) ||
                quint32(crc32(0, reinterpret_cast<const Bytef*>(entry.data.constData()), uInt(entry.data.size()))) != crc) { good = false; break; }
            where.records.push_back(a);
            candidate.entries.push_back(std::move(entry));
            q += 46 + nameSize;
        }
        if (!good) continue;
        where.directoryEnd = q;
        package = std::move(candidate);
        if (layout) *layout = std::move(where);
        return true;
    }
    error = QObject::tr("В пакете SOLIDWORKS не найдена завершающая запись с согласованным каталогом.");
    return false;
}

} // namespace cadnext::gui
