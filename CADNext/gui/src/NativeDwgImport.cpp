#include "cadnext/gui/NativeDwgImport.hpp"

#include <QFile>

#include <algorithm>
#include <cstring>
#include <limits>
#include <map>
#include <set>

namespace cadnext::gui {
namespace {

constexpr quint64 kMaxFileSize = 512ull * 1024 * 1024;
constexpr quint64 kMaxSectionSize = 512ull * 1024 * 1024;

bool inBounds(const QByteArray& data, quint64 offset, quint64 length) {
    const auto size = static_cast<quint64>(data.size());
    return offset <= size && length <= size - offset;
}

quint32 u32(const QByteArray& data, quint64 offset) {
    const auto* p = reinterpret_cast<const uchar*>(data.constData()) + offset;
    return quint32(p[0]) | (quint32(p[1]) << 8) |
           (quint32(p[2]) << 16) | (quint32(p[3]) << 24);
}

quint64 u64(const QByteArray& data, quint64 offset) {
    return quint64(u32(data, offset)) | (quint64(u32(data, offset + 4)) << 32);
}

quint32 checksum(quint32 seed, const char* bytes, quint64 length) {
    quint32 sum1 = seed & 0xffff;
    quint32 sum2 = seed >> 16;
    while (length) {
        const quint64 chunk = std::min<quint64>(length, 0x15b0);
        for (quint64 i = 0; i < chunk; ++i) {
            sum1 += static_cast<uchar>(bytes[i]);
            sum2 += sum1;
        }
        sum1 %= 0xfff1;
        sum2 %= 0xfff1;
        bytes += chunk;
        length -= chunk;
    }
    return (sum2 << 16) | sum1;
}

bool readFile(const QString& path, QByteArray& bytes, QString& error) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        error = QStringLiteral("Cannot open DWG file: %1").arg(file.errorString());
        return false;
    }
    if (file.size() < 0x100 || quint64(file.size()) > kMaxFileSize) {
        error = QStringLiteral("DWG file size is outside the supported container limit");
        return false;
    }
    bytes = file.readAll();
    if (bytes.size() != file.size()) {
        error = QStringLiteral("Could not read the complete DWG file");
        return false;
    }
    return true;
}

class LzReader {
public:
    LzReader(const char* source, quint64 sourceLength, quint64 outputLimit)
        : source_(reinterpret_cast<const uchar*>(source)), sourceLength_(sourceLength),
          outputLimit_(outputLimit) {}

    bool decode(QByteArray& output, QString& error) {
        output.clear();
        quint64 count = 0;
        if (!literalLength(count) || !copyLiteral(output, count))
            return fail(error, "invalid initial DWG LZ77 literal");

        while (position_ < sourceLength_) {
            quint8 opcode = 0;
            if (!read(opcode))
                return fail(error, "truncated DWG LZ77 opcode");
            if (opcode == 0x11) {
                if (quint64(output.size()) != outputLimit_)
                    return fail(error, "DWG LZ77 output length mismatch");
                // ODA streams may have up to two alignment bytes after the terminator.
                for (; position_ < sourceLength_; ++position_) {
                    if (source_[position_] != 0)
                        return fail(error, "unexpected DWG LZ77 trailing data");
                }
                return true;
            }

            quint64 matchLength = 0;
            quint64 distance = 0;
            quint64 literalCount = 0;
            if (opcode == 0x10) {
                if (!longLength(matchLength) || !twoByteOffset(distance, literalCount))
                    return fail(error, "truncated DWG LZ77 long match");
                matchLength += 9;
                distance += 0x3fff;
            } else if (opcode >= 0x12 && opcode <= 0x1f) {
                matchLength = (opcode & 0x0f) + 2;
                if (!twoByteOffset(distance, literalCount))
                    return fail(error, "truncated DWG LZ77 distant match");
                distance += 0x3fff;
            } else if (opcode == 0x20) {
                if (!longLength(matchLength) || !twoByteOffset(distance, literalCount))
                    return fail(error, "truncated DWG LZ77 extended match");
                matchLength += 0x21;
            } else if (opcode >= 0x21 && opcode <= 0x3f) {
                matchLength = opcode - 0x1e;
                if (!twoByteOffset(distance, literalCount))
                    return fail(error, "truncated DWG LZ77 match offset");
            } else if (opcode >= 0x40) {
                quint8 next = 0;
                if (!read(next))
                    return fail(error, "truncated DWG LZ77 short match");
                matchLength = (opcode >> 4) - 1;
                distance = (quint64(next) << 2) | ((opcode & 0x0c) >> 2);
                literalCount = opcode & 3;
            } else {
                return fail(error, "invalid DWG LZ77 opcode");
            }
            ++distance; // Encoded distance is zero based.
            if (!distance || distance > quint64(output.size()) ||
                matchLength > outputLimit_ - quint64(output.size()))
                return fail(error, "DWG LZ77 match is out of bounds");
            for (quint64 i = 0; i < matchLength; ++i)
                output.append(output.at(output.size() - qsizetype(distance)));
            if (!literalCount && !literalLength(literalCount))
                return fail(error, "truncated DWG LZ77 literal length");
            if (!copyLiteral(output, literalCount))
                return fail(error, "DWG LZ77 literal is out of bounds");
        }
        return fail(error, "DWG LZ77 stream has no terminator");
    }

private:
    bool read(quint8& value) {
        if (position_ >= sourceLength_)
            return false;
        value = source_[position_++];
        return true;
    }

    bool literalLength(quint64& length) {
        quint8 value = 0;
        if (!read(value))
            return false;
        if (value >= 0x10) {
            --position_; // This byte is the next match opcode.
            length = 0;
            return true;
        }
        if (value) {
            length = quint64(value) + 3;
            return true;
        }
        length = 0x0f;
        do {
            if (!read(value) || length > outputLimit_)
                return false;
            length += value ? value : 0xff;
        } while (!value);
        length += 3;
        return true;
    }

    bool longLength(quint64& length) {
        quint8 value = 0;
        if (!read(value))
            return false;
        if (value) {
            length = value;
            return true;
        }
        length = 0xff;
        do {
            if (!read(value) || length > outputLimit_)
                return false;
            length += value ? value : 0xff;
        } while (!value);
        return true;
    }

    bool twoByteOffset(quint64& offset, quint64& literalCount) {
        quint8 low = 0, high = 0;
        if (!read(low) || !read(high))
            return false;
        offset = (low >> 2) | (quint64(high) << 6);
        literalCount = low & 3;
        return true;
    }

    bool copyLiteral(QByteArray& output, quint64 count) {
        if (count > sourceLength_ - position_ ||
            count > outputLimit_ - quint64(output.size()))
            return false;
        output.append(reinterpret_cast<const char*>(source_ + position_), qsizetype(count));
        position_ += count;
        return true;
    }

    static bool fail(QString& error, const char* message) {
        error = QString::fromLatin1(message);
        return false;
    }

    const uchar* source_ = nullptr;
    quint64 sourceLength_ = 0;
    quint64 outputLimit_ = 0;
    quint64 position_ = 0;
};

bool readSystemPage(const QByteArray& file, quint64 offset, quint32 expectedType,
                    QByteArray& uncompressed, QString& error) {
    if (!inBounds(file, offset, 20)) {
        error = QStringLiteral("DWG system page header lies outside file");
        return false;
    }
    const quint32 type = u32(file, offset);
    const quint32 logicalSize = u32(file, offset + 4);
    const quint32 dataSize = u32(file, offset + 8);
    const quint32 compression = u32(file, offset + 12);
    const quint32 storedChecksum = u32(file, offset + 16);
    if (type != expectedType || compression != 2 || logicalSize > kMaxSectionSize ||
        !inBounds(file, offset + 20, dataSize)) {
        error = QStringLiteral("Invalid DWG system page header");
        return false;
    }
    char header[20];
    std::memcpy(header, file.constData() + offset, 20);
    std::memset(header + 16, 0, 4);
    const quint32 calculated = checksum(checksum(0, header, 20),
                                        file.constData() + offset + 20, dataSize);
    if (storedChecksum != calculated) {
        error = QStringLiteral("DWG system page checksum mismatch");
        return false;
    }
    return LzReader(file.constData() + offset + 20, dataSize, logicalSize)
        .decode(uncompressed, error);
}

bool readDataPage(const QByteArray& file, const DwgPageInfo& page,
                  const DwgSectionInfo& section, const DwgSectionPageInfo& local,
                  QByteArray* decoded, QString& error) {
    const quint64 offset = page.fileOffset;
    if (!inBounds(file, offset, 32)) {
        error = QStringLiteral("DWG data page header lies outside file");
        return false;
    }
    const quint32 mask = 0x4164536bu ^ quint32(offset);
    QByteArray header(32, '\0');
    for (int i = 0; i < 8; ++i) {
        const quint32 word = u32(file, offset + quint64(i) * 4) ^ mask;
        for (int j = 0; j < 4; ++j)
            header[i * 4 + j] = char((word >> (j * 8)) & 0xff);
    }
    const quint32 type = u32(header, 0);
    const quint32 sectionId = u32(header, 4);
    const quint32 dataSize = u32(header, 8);
    const quint32 pageSize = u32(header, 12);
    const quint64 sectionOffset = u64(header, 16);
    const quint32 storedHeaderChecksum = u32(header, 24);
    const quint32 storedDataChecksum = u32(header, 28);
    if (type != 0x4163043b || sectionId != section.id ||
        dataSize != local.storedDataSize || pageSize != page.size ||
        sectionOffset != local.sectionOffset || dataSize > page.size - 32 ||
        !inBounds(file, offset + 32, dataSize)) {
        error = QStringLiteral("DWG data page metadata mismatch in %1").arg(section.name);
        return false;
    }
    const char* payload = file.constData() + offset + 32;
    const quint32 dataChecksum = checksum(0, payload, dataSize);
    header[24] = header[25] = header[26] = header[27] = '\0';
    const quint32 headerChecksum = checksum(storedDataChecksum, header.constData(), 32);
    if (storedDataChecksum != dataChecksum || storedHeaderChecksum != headerChecksum) {
        error = QStringLiteral("DWG data page checksum mismatch in %1").arg(section.name);
        return false;
    }
    if (!decoded)
        return true;
    if (section.encryption != 0) {
        error = QStringLiteral("Encrypted DWG section is unsupported: %1").arg(section.name);
        return false;
    }
    const quint64 remaining = section.logicalSize - local.sectionOffset;
    const quint64 wanted = std::min<quint64>(remaining, section.maxPageSize);
    if (section.compression == 1) {
        if (dataSize < wanted) {
            error = QStringLiteral("DWG data page is shorter than its logical span");
            return false;
        }
        *decoded = QByteArray(payload, qsizetype(wanted));
        return true;
    }
    if (section.compression != 2) {
        error = QStringLiteral("Unsupported DWG section compression mode");
        return false;
    }
    // A compressed final page may expand to either its logical remainder or a
    // complete padded page. Try the logical size first and accept padding only
    // after validating the full decompression.
    if (LzReader(payload, dataSize, wanted).decode(*decoded, error))
        return true;
    if (wanted < section.maxPageSize) {
        QByteArray padded;
        QString paddedError;
        if (LzReader(payload, dataSize, section.maxPageSize).decode(padded, paddedError)) {
            *decoded = padded.left(qsizetype(wanted));
            error.clear();
            return true;
        }
    }
    error = QStringLiteral("Cannot decompress DWG section %1 page %2: %3")
                .arg(section.name).arg(page.number).arg(error);
    return false;
}

} // namespace

bool readDwgStructure(const QString& path, DwgStructure& structure, QString& error) {
    structure = {};
    error.clear();
    QByteArray file;
    if (!readFile(path, file, error))
        return false;

    const QByteArray version = file.left(6);
    if (version != "AC1018" && version != "AC1024" && version != "AC1027" &&
        version != "AC1032") {
        error = QStringLiteral("Unsupported DWG container version: %1")
                    .arg(QString::fromLatin1(version));
        return false;
    }
    if (u32(file, 0x28) != 0x80) {
        error = QStringLiteral("DWG header marker is invalid");
        return false;
    }

    QByteArray header = file.mid(0x80, 0x6c);
    quint32 random = 1;
    for (int i = 0; i < header.size(); ++i) {
        random = random * 0x343fd + 0x269ec3;
        header[i] = char(quint8(header[i]) ^ quint8(random >> 16));
    }
    if (header.left(12) != QByteArray("AcFssFcAJMB\0", 12) ||
        u32(header, 0x10) != 0x6c || u32(header, 0x14) != 4 ||
        u32(header, 0x44) != 0x20 || u32(header, 0x48) != 0x80 ||
        u32(header, 0x4c) != 0x40) {
        error = QStringLiteral("DWG encrypted file header is invalid");
        return false;
    }
    structure.version = QString::fromLatin1(version);
    structure.fileSize = quint64(file.size());
    structure.securityFlags = u32(file, 0x18);
    structure.pageMapPageId = u32(header, 0x50);
    structure.sectionMapPageId = u32(header, 0x5c);
    const quint64 pageMapOffset = u64(header, 0x54) + 0x100;
    const quint32 expectedPageCount = u32(header, 0x40);
    if (expectedPageCount == 0 || expectedPageCount > 100000 ||
        structure.pageMapPageId == 0 || structure.sectionMapPageId == 0) {
        error = QStringLiteral("DWG header page counts are invalid");
        return false;
    }

    QByteArray pageMap;
    if (!readSystemPage(file, pageMapOffset, 0x41630e3b, pageMap, error))
        return false;
    quint64 cursor = 0x100;
    std::map<quint32, DwgPageInfo> pages;
    for (quint64 i = 0; i < quint64(pageMap.size());) {
        if (!inBounds(pageMap, i, 8)) {
            error = QStringLiteral("DWG page map has a partial record");
            return false;
        }
        const qint32 signedNumber = qint32(u32(pageMap, i));
        const quint32 size = u32(pageMap, i + 4);
        i += 8;
        if (size < 32 || (size & 31) || cursor > std::numeric_limits<quint64>::max() - size) {
            error = QStringLiteral("DWG page map has an invalid page extent");
            return false;
        }
        if (signedNumber < 0) {
            if (!inBounds(pageMap, i, 16)) {
                error = QStringLiteral("DWG page map has a partial gap record");
                return false;
            }
            i += 16;
        } else if (signedNumber == 0 ||
                   !pages.emplace(quint32(signedNumber),
                                  DwgPageInfo{quint32(signedNumber), size, cursor}).second) {
            error = QStringLiteral("DWG page map contains a duplicate or zero page id");
            return false;
        }
        cursor += size;
    }
    if (pages.size() != expectedPageCount ||
        !pages.contains(structure.pageMapPageId) ||
        !pages.contains(structure.sectionMapPageId) ||
        pages.at(structure.pageMapPageId).fileOffset != pageMapOffset) {
        error = QStringLiteral("DWG page map conflicts with file header");
        return false;
    }
    for (const auto& [id, page] : pages)
        structure.pages.push_back(page);

    QByteArray sectionMap;
    const quint64 sectionMapOffset = pages.at(structure.sectionMapPageId).fileOffset;
    if (!readSystemPage(file, sectionMapOffset, 0x4163003b, sectionMap, error))
        return false;
    if (!inBounds(sectionMap, 0, 20)) {
        error = QStringLiteral("DWG section map is too short");
        return false;
    }
    const quint32 descriptions = u32(sectionMap, 0);
    if (!descriptions || descriptions > 4096 ||
        u32(sectionMap, 4) != 2 || u32(sectionMap, 8) != 0x7400) {
        error = QStringLiteral("DWG section map preamble is invalid");
        return false;
    }
    quint64 position = 20;
    std::set<QString> names;
    for (quint32 index = 0; index < descriptions; ++index) {
        if (!inBounds(sectionMap, position, 96)) {
            error = QStringLiteral("DWG section map has a partial description");
            return false;
        }
        DwgSectionInfo section;
        section.logicalSize = u64(sectionMap, position);
        const quint32 count = u32(sectionMap, position + 8);
        section.maxPageSize = u32(sectionMap, position + 12);
        section.compression = u32(sectionMap, position + 20);
        section.id = u32(sectionMap, position + 24);
        section.encryption = u32(sectionMap, position + 28);
        const QByteArray rawName = sectionMap.mid(qsizetype(position + 32), 64);
        const int end = rawName.indexOf('\0');
        if (end < 0) {
            error = QStringLiteral("DWG section name is not terminated");
            return false;
        }
        section.name = QString::fromLatin1(rawName.constData(), end);
        position += 96;
        if (section.logicalSize > kMaxSectionSize || count > pages.size() ||
            section.maxPageSize == 0 || (section.compression != 1 && section.compression != 2) ||
            !names.insert(section.name).second || !inBounds(sectionMap, position, quint64(count) * 16)) {
            error = QStringLiteral("DWG section description is invalid: %1").arg(section.name);
            return false;
        }
        quint64 previousEnd = 0;
        for (quint32 j = 0; j < count; ++j) {
            DwgSectionPageInfo local;
            local.pageNumber = u32(sectionMap, position);
            local.storedDataSize = u32(sectionMap, position + 4);
            local.sectionOffset = u64(sectionMap, position + 8);
            position += 16;
            const auto found = pages.find(local.pageNumber);
            if (found == pages.end() || local.sectionOffset < previousEnd ||
                local.sectionOffset >= section.logicalSize ||
                local.sectionOffset % section.maxPageSize != 0 ||
                !readDataPage(file, found->second, section, local, nullptr, error)) {
                if (error.isEmpty())
                    error = QStringLiteral("DWG section page map is invalid: %1").arg(section.name);
                return false;
            }
            previousEnd = local.sectionOffset +
                          std::min<quint64>(section.maxPageSize,
                                            section.logicalSize - local.sectionOffset);
            section.pages.push_back(local);
        }
        structure.sections.push_back(std::move(section));
    }
    if (position != quint64(sectionMap.size())) {
        error = QStringLiteral("DWG section map has trailing records");
        return false;
    }
    return true;
}

bool readDwgSection(const QString& path, const DwgStructure& structure,
                    const QString& sectionName, QByteArray& bytes, QString& error) {
    bytes.clear();
    error.clear();
    const auto found = std::find_if(structure.sections.begin(), structure.sections.end(),
                                    [&](const DwgSectionInfo& section) {
                                        return section.name == sectionName;
                                    });
    if (found == structure.sections.end()) {
        error = QStringLiteral("DWG section not found: %1").arg(sectionName);
        return false;
    }
    if (found->logicalSize > kMaxSectionSize) {
        error = QStringLiteral("DWG section exceeds size limit");
        return false;
    }
    QByteArray file;
    if (!readFile(path, file, error))
        return false;
    if (quint64(file.size()) != structure.fileSize ||
        QString::fromLatin1(file.constData(), 6) != structure.version) {
        error = QStringLiteral("DWG file changed after its structure was read");
        return false;
    }
    bytes = QByteArray(qsizetype(found->logicalSize), '\0');
    for (const DwgSectionPageInfo& local : found->pages) {
        const auto page = std::find_if(structure.pages.begin(), structure.pages.end(),
                                       [&](const DwgPageInfo& value) {
                                           return value.number == local.pageNumber;
                                       });
        if (page == structure.pages.end() || local.sectionOffset >= found->logicalSize) {
            error = QStringLiteral("DWG section references an invalid page");
            bytes.clear();
            return false;
        }
        QByteArray chunk;
        if (!readDataPage(file, *page, *found, local, &chunk, error)) {
            bytes.clear();
            return false;
        }
        std::memcpy(bytes.data() + local.sectionOffset, chunk.constData(), size_t(chunk.size()));
    }
    return true;
}

} // namespace cadnext::gui
