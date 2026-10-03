#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeCompoundFile.hpp"
#include "cadnext/gui/NativeDwgImport.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksConfiguration.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMap>
#include <QSaveFile>
#include <QSet>
#include <QStringList>
#include <QXmlStreamReader>
#include <QXmlStreamWriter>

#include <zlib.h>

#include <cmath>
#include <iterator>

namespace cadnext::gui {
namespace {

constexpr quint64 kMaxArchiveBytes = 512ull * 1024 * 1024;
constexpr quint64 kMaxEntryBytes = 256ull * 1024 * 1024;
constexpr quint32 kMaxAssemblyManifestBytes = 16 * 1024 * 1024;
constexpr quint32 kMaxParasolidStreamBytes = 256 * 1024 * 1024;

quint16 u16(const QByteArray& data, qsizetype at) {
    const auto* p = reinterpret_cast<const unsigned char*>(data.constData() + at);
    return quint16(p[0]) | quint16(p[1]) << 8;
}

quint32 u32(const QByteArray& data, qsizetype at) {
    return quint32(u16(data, at)) | quint32(u16(data, at + 2)) << 16;
}

quint16 be16(const QByteArray& data, qsizetype at) {
    const auto* p = reinterpret_cast<const unsigned char*>(data.constData() + at);
    return quint16(p[0]) << 8 | quint16(p[1]);
}

quint32 be32(const QByteArray& data, qsizetype at) {
    return quint32(be16(data, at)) << 16 | be16(data, at + 2);
}

void append16(QByteArray& data, quint16 value) {
    data.append(char(value & 0xff));
    data.append(char(value >> 8));
}

void append32(QByteArray& data, quint32 value) {
    append16(data, quint16(value & 0xffff));
    append16(data, quint16(value >> 16));
}

struct StoredZipMember {
    QByteArray name;
    QByteArray data;
};

bool writeStoredZip(const QString& path, const std::vector<StoredZipMember>& members,
                    QString& error) {
    if (members.empty() || members.size() > 65535) {
        error = QObject::tr("Недопустимое число файлов в документе FreeCAD.");
        return false;
    }
    QByteArray archive;
    QByteArray directory;
    quint64 total = 0;
    for (const StoredZipMember& member : members) {
        total += quint64(member.data.size()) + quint64(member.name.size()) * 2 + 76;
        if (member.name.isEmpty() || member.name.size() > 65535 ||
            member.data.size() > qsizetype(kMaxEntryBytes) ||
            total > kMaxArchiveBytes) {
            error = QObject::tr("Файл FreeCAD слишком велик для записи.");
            return false;
        }
        const quint32 offset = quint32(archive.size());
        const quint32 size = quint32(member.data.size());
        const quint32 checksum = crc32(0,
            reinterpret_cast<const Bytef*>(member.data.constData()), size);
        append32(archive, 0x04034b50);
        append16(archive, 20); // ZIP version needed
        append16(archive, 1u << 11); // UTF-8 filenames
        append16(archive, 0); // Stored entry
        append16(archive, 0); append16(archive, 0); // Time and date
        append32(archive, checksum);
        append32(archive, size); append32(archive, size);
        append16(archive, quint16(member.name.size())); append16(archive, 0);
        archive.append(member.name);
        archive.append(member.data);

        append32(directory, 0x02014b50);
        append16(directory, 20); append16(directory, 20);
        append16(directory, 1u << 11); append16(directory, 0);
        append16(directory, 0); append16(directory, 0);
        append32(directory, checksum);
        append32(directory, size); append32(directory, size);
        append16(directory, quint16(member.name.size())); append16(directory, 0);
        append16(directory, 0); append16(directory, 0);
        append16(directory, 0); append32(directory, 0);
        append32(directory, offset);
        directory.append(member.name);
    }
    const quint32 directoryOffset = quint32(archive.size());
    const quint32 directorySize = quint32(directory.size());
    archive.append(directory);
    append32(archive, 0x06054b50);
    append16(archive, 0); append16(archive, 0);
    append16(archive, quint16(members.size()));
    append16(archive, quint16(members.size()));
    append32(archive, directorySize); append32(archive, directoryOffset);
    append16(archive, 0);

    QSaveFile output(path);
    if (!output.open(QIODevice::WriteOnly) ||
        output.write(archive) != archive.size() || !output.commit()) {
        error = QObject::tr("Не удалось сохранить документ FreeCAD: %1")
                    .arg(output.errorString());
        return false;
    }
    return true;
}

struct ZipEntry {
    quint16 method = 0;
    quint32 size = 0;
    quint32 packedSize = 0;
    quint32 crc = 0;
    quint32 localOffset = 0;
};

bool zipEntries(const QByteArray& bytes, QMap<QString, ZipEntry>& entries, QString& error) {
    if (bytes.size() < 22) {
        error = QObject::tr("Файл FreeCAD не является ZIP-архивом.");
        return false;
    }
    const qsizetype first = qMax<qsizetype>(0, bytes.size() - 65557);
    qsizetype end = -1;
    for (qsizetype at = bytes.size() - 22; at >= first; --at) {
        if (u32(bytes, at) == 0x06054b50) { end = at; break; }
    }
    if (end < 0 || end + 22 > bytes.size()) {
        error = QObject::tr("Файл FreeCAD не содержит корректного ZIP-каталога.");
        return false;
    }
    const quint32 directorySize = u32(bytes, end + 12);
    const quint32 directoryOffset = u32(bytes, end + 16);
    const quint16 count = u16(bytes, end + 10);
    if (count == 0xffff || directorySize == 0xffffffff ||
        directoryOffset == 0xffffffff ||
        quint64(directoryOffset) + directorySize > quint64(bytes.size())) {
        error = QObject::tr("ZIP64 или повреждённый архив FreeCAD не поддерживается.");
        return false;
    }
    qsizetype at = directoryOffset;
    quint64 expandedTotal = 0;
    for (quint16 i = 0; i < count; ++i) {
        if (quint64(at) + 46 > quint64(directoryOffset) + directorySize ||
            u32(bytes, at) != 0x02014b50) {
            error = QObject::tr("Повреждён каталог файла FreeCAD.");
            return false;
        }
        const quint16 flags = u16(bytes, at + 8);
        const quint16 method = u16(bytes, at + 10);
        const quint32 crc = u32(bytes, at + 16);
        const quint32 packed = u32(bytes, at + 20);
        const quint32 size = u32(bytes, at + 24);
        const quint16 nameLength = u16(bytes, at + 28);
        const quint16 extraLength = u16(bytes, at + 30);
        const quint16 commentLength = u16(bytes, at + 32);
        const quint32 localOffset = u32(bytes, at + 42);
        const quint64 next = quint64(at) + 46 + nameLength + extraLength + commentLength;
        expandedTotal += size;
        if (next > quint64(directoryOffset) + directorySize ||
            expandedTotal > kMaxArchiveBytes || size > kMaxEntryBytes ||
            packed > kMaxEntryBytes || (flags & 1) || (method != 0 && method != 8)) {
            error = QObject::tr("Архив FreeCAD содержит неподдерживаемую ZIP-запись.");
            return false;
        }
        const QString name = QString::fromUtf8(bytes.constData() + at + 46, nameLength);
        if (name.startsWith(QLatin1Char('/')) || name.contains(QStringLiteral("..")) ||
            entries.contains(name)) {
            error = QObject::tr("Недопустимое имя ZIP-записи в файле FreeCAD.");
            return false;
        }
        entries.insert(name, {method, size, packed, crc, localOffset});
        at = qsizetype(next);
    }
    return true;
}

bool extract(const QByteArray& archive, const QMap<QString, ZipEntry>& entries,
             const QString& name, QByteArray& data, QString& error) {
    const auto found = entries.constFind(name);
    if (found == entries.cend()) {
        error = QObject::tr("В файле FreeCAD отсутствует %1.").arg(name);
        return false;
    }
    const ZipEntry& entry = found.value();
    const qsizetype at = entry.localOffset;
    if (at + 30 > archive.size() || u32(archive, at) != 0x04034b50) {
        error = QObject::tr("Повреждённая ZIP-запись: %1.").arg(name);
        return false;
    }
    const quint64 start = quint64(at) + 30 + u16(archive, at + 26) + u16(archive, at + 28);
    if (start + entry.packedSize > quint64(archive.size())) {
        error = QObject::tr("Неполная ZIP-запись: %1.").arg(name);
        return false;
    }
    const char* source = archive.constData() + start;
    if (entry.method == 0) {
        if (entry.packedSize != entry.size) {
            error = QObject::tr("Повреждён размер ZIP-записи %1.").arg(name);
            return false;
        }
        data = QByteArray(source, entry.size);
    } else {
        data.resize(entry.size);
        z_stream stream{};
        stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(source));
        stream.avail_in = entry.packedSize;
        stream.next_out = reinterpret_cast<Bytef*>(data.data());
        stream.avail_out = entry.size;
        if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
            error = QObject::tr("Не удалось начать распаковку %1.").arg(name);
            return false;
        }
        const int status = inflate(&stream, Z_FINISH);
        inflateEnd(&stream);
        if (status != Z_STREAM_END || stream.total_out != entry.size) {
            error = QObject::tr("Не удалось распаковать %1.").arg(name);
            return false;
        }
    }
    const auto checksum = crc32(0, reinterpret_cast<const Bytef*>(data.constData()),
                                static_cast<uInt>(data.size()));
    if (checksum != entry.crc) {
        error = QObject::tr("Ошибка контрольной суммы %1.").arg(name);
        return false;
    }
    return true;
}

struct ShapeInfo {
    QString type;
    QString label;
    QString file;
    QStringList group;
};

bool parseDocument(const QByteArray& xml, QMap<QString, ShapeInfo>& infos, QString& error) {
    QXmlStreamReader reader(xml);
    bool objects = false;
    bool objectData = false;
    QString currentObject;
    QString currentProperty;
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.isStartElement()) {
            const auto tag = reader.name();
            const auto attrs = reader.attributes();
            if (tag == QLatin1String("Objects")) objects = true;
            else if (tag == QLatin1String("ObjectData")) objectData = true;
            else if (tag == QLatin1String("Object") && objects) {
                infos[attrs.value(QLatin1String("name")).toString()].type =
                    attrs.value(QLatin1String("type")).toString();
            } else if (tag == QLatin1String("Object") && objectData) {
                currentObject = attrs.value(QLatin1String("name")).toString();
            } else if (!currentObject.isEmpty() && tag == QLatin1String("Property")) {
                currentProperty = attrs.value(QLatin1String("name")).toString();
            } else if (!currentObject.isEmpty() && currentProperty == QLatin1String("Shape") &&
                       tag == QLatin1String("Part")) {
                infos[currentObject].file = attrs.value(QLatin1String("file")).toString();
            } else if (!currentObject.isEmpty() && currentProperty == QLatin1String("Label") &&
                       tag == QLatin1String("String")) {
                infos[currentObject].label = attrs.value(QLatin1String("value")).toString();
            } else if (!currentObject.isEmpty() &&
                       (currentProperty == QLatin1String("Group") ||
                        currentProperty == QLatin1String("Model")) &&
                       tag == QLatin1String("Link")) {
                infos[currentObject].group.push_back(attrs.value(QLatin1String("value")).toString());
            }
        } else if (reader.isEndElement()) {
            const auto tag = reader.name();
            if (tag == QLatin1String("Objects")) objects = false;
            else if (tag == QLatin1String("ObjectData")) objectData = false;
            else if (tag == QLatin1String("Property")) currentProperty.clear();
            else if (tag == QLatin1String("Object") && objectData) currentObject.clear();
        }
    }
    if (reader.hasError() || infos.empty()) {
        error = QObject::tr("Не удалось прочитать Document.xml файла FreeCAD: %1")
                    .arg(reader.errorString());
        return false;
    }
    return true;
}

bool inflateExact(const char* source, quint32 packedSize, quint32 unpackedSize,
                  int windowBits, QByteArray& output) {
    if (unpackedSize > kMaxParasolidStreamBytes) return false;
    output.resize(unpackedSize);
    z_stream stream{};
    stream.next_in = reinterpret_cast<Bytef*>(const_cast<char*>(source));
    stream.avail_in = packedSize;
    stream.next_out = reinterpret_cast<Bytef*>(output.data());
    stream.avail_out = unpackedSize;
    if (inflateInit2(&stream, windowBits) != Z_OK) return false;
    const int status = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    return status == Z_STREAM_END && stream.total_in == packedSize &&
           stream.total_out == unpackedSize;
}

// Legacy CFB storage or SOLIDWORKS 2015+ archive entries.
bool solidWorksEntry(const QByteArray& bytes, const QByteArray& wanted,
                    QByteArray& payload, bool& found) {
    found = false;
    payload.clear();
    if (bytes.size() < 8) return false;
    if (bytes.startsWith(QByteArray::fromHex("d0cf11e0a1b11ae1"))) {
        CompoundFile file; QString error;
        if (!decodeCompoundFile(bytes, file, error)) return false;
        for (const auto& entry : file.entries)
            if (entry.kind == CompoundFileEntry::Kind::Stream && entry.path == QString::fromUtf8(wanted)) {
                found = true; payload = entry.data; break;
            }
        return true;
    }
    const unsigned shift = uchar(bytes[7]) & 7u;
    const QByteArray marker = QByteArray::fromHex("140006000800");
    qsizetype search = 8;
    while (true) {
        const qsizetype at = bytes.indexOf(marker, search);
        if (at < 0) return true;
        search = at + marker.size();
        if (at + 26 > bytes.size()) continue;
        const quint32 length = u32(bytes, at + 22);
        if (length == 0 || length > 512 || quint64(at) + 26 + length > quint64(bytes.size())) continue;
        QByteArray name = bytes.mid(at + 26, length);
        for (char& c : name) {
            const unsigned value = uchar(c);
            c = char(shift == 0 ? value : ((value << shift) | (value >> (8 - shift))) & 0xffu);
        }
        if (name != wanted) continue;
        found = true;
        const quint32 packed = u32(bytes, at + 14), unpacked = u32(bytes, at + 18);
        if (packed == 0 || unpacked == 0 || packed > kMaxEntryBytes || unpacked > kMaxEntryBytes ||
            quint64(at) + 26 + length + packed > quint64(bytes.size()) ||
            !inflateExact(bytes.constData() + at + 26 + length, packed, unpacked, -MAX_WBITS, payload)) return false;
        return crc32(0, reinterpret_cast<const Bytef*>(payload.constData()), uInt(payload.size())) == u32(bytes, at + 10);
    }
}

// The shared native codec consumes the manager footer and both stamp layouts;
// names are mapped by storage id, including inactive and derived configurations.
bool solidWorksConfigurationNames(const QByteArray& data, QMap<QString, QString>& names) {
    names.clear();
    SolidWorksConfigurationHeader header;
    QString error;
    if (!decodeSolidWorksConfigurationHeader(data, header, error)) return false;
    for (const auto& entry : header.entries) names.insert(QString::number(entry.id), entry.name);
    return true;
}

bool parseParasolidHeader(const QByteArray& data, SolidWorksBodyStream& body) {
    if (data.size() < 18 || !data.startsWith(QByteArray("PS\0\0", 4))) return false;
    const quint16 modelLength = be16(data, 4);
    if (modelLength == 0 || modelLength > 256 ||
        quint64(6) + modelLength + 4 > quint64(data.size())) return false;
    const QByteArray model = data.mid(6, modelLength);
    if (!model.startsWith(": TRANSMIT FILE")) return false;
    qsizetype at = 6 + modelLength;
    const quint32 schemaLength = be32(data, at);
    at += 4;
    if (schemaLength == 0 || schemaLength > 128 ||
        quint64(at) + schemaLength + 6 > quint64(data.size())) return false;
    const QByteArray schema = data.mid(at, schemaLength);
    const QList<QByteArray> fields = schema.split('_');
    if ((fields.size() != 3 && fields.size() != 4) || fields[0] != "SCH") return false;
    for (qsizetype i = 1; i < fields.size(); ++i) {
        if (fields[i].isEmpty()) return false;
        for (char value : fields[i]) {
            if (value < '0' || value > '9') return false;
        }
    }
    body.schemaKey = QString::fromLatin1(schema);
    body.kind = model.contains("(partition)") ? QStringLiteral("partition") :
                model.contains("(deltas)") ? QStringLiteral("deltas") :
                                             QStringLiteral("unknown");
    at += schemaLength;
    if (fields.size() == 4) {
        body.maxNodeType = be16(data, at);
        if (body.maxNodeType == 0) return false;
        at += 2;
    }
    body.userFieldSize = be32(data, at);
    at += 4;
    if (quint64(at) + 2 > quint64(data.size())) return false;
    body.nodeDataOffset = at;
    body.rootNodeType = be16(data, at);
    return body.rootNodeType != 0 &&
           (body.maxNodeType == 0 || body.rootNodeType <= body.maxNodeType);
}

struct XtField {
    QByteArray name;
    char type;
};

bool readXtIndex(const QByteArray& data, qsizetype& at, quint32& value) {
    if (at + 2 > data.size()) return false;
    const quint16 first = be16(data, at);
    at += 2;
    if (first == 0) return false;
    if ((first & 0x8000u) == 0) {
        value = first - 1;
        return true;
    }
    if (first == 0x8000u || at + 2 > data.size()) return false;
    const quint16 quotient = be16(data, at);
    at += 2;
    if (quotient == 0) return false;
    const quint64 expanded = quint64(quotient) * 32767u + (0x10000u - first) - 1u;
    if (expanded > 0xffffffffu) return false;
    value = quint32(expanded);
    return true;
}

bool readXtFieldDefinition(const QByteArray& data, qsizetype& at, XtField& field) {
    if (at >= data.size()) return false;
    const auto nameSize = static_cast<unsigned char>(data[at++]);
    if (nameSize == 0 || at + nameSize + 4 > data.size()) return false;
    field.name = data.mid(at, nameSize);
    at += nameSize;
    const quint16 pointerClass = be16(data, at);
    const quint16 count = be16(data, at + 2);
    at += 4;
    // The WORLD and BODY fields handled here are scalar. Variable-length
    // arrays in other node types require separate decoding.
    if (count != 1) return false;
    if (pointerClass != 0) {
        field.type = 'p';
        return true;
    }
    if (at + 2 > data.size() || static_cast<unsigned char>(data[at]) != 1) {
        return false;
    }
    field.type = data[at + 1];
    at += 2;
    return field.type == 'd' || field.type == 'l' || field.type == 'p' ||
           field.type == 'u' || field.type == 'c' || field.type == 'f';
}

template<std::size_t N>
bool readXtSchemaEdits(const QByteArray& data, qsizetype& at,
                       const std::array<XtField, N>& base,
                       std::vector<XtField>& fields) {
    if (at >= data.size()) return false;
    const auto expectedCount = static_cast<unsigned char>(data[at++]);
    if (expectedCount == 0xffu) {
        fields.assign(base.begin(), base.end());
        return true;
    }
    qsizetype baseAt = 0;
    bool terminated = false;
    for (int instruction = 0; instruction < 128 && at < data.size(); ++instruction) {
        const char code = data[at++];
        if (code == 'Z') { terminated = true; break; }
        if (code == 'C') {
            if (baseAt >= qsizetype(base.size())) return false;
            fields.push_back(base[baseAt++]);
        } else if (code == 'D') {
            if (baseAt >= qsizetype(base.size())) return false;
            ++baseAt;
        } else if (code == 'I' || code == 'A') {
            XtField field;
            if (!readXtFieldDefinition(data, at, field)) return false;
            fields.push_back(std::move(field));
        } else {
            return false;
        }
        if (fields.size() > 64) return false;
    }
    return terminated && baseAt == qsizetype(base.size()) &&
           fields.size() == expectedCount;
}

bool parseParasolidWorld(const QByteArray& data, SolidWorksBodyStream& body) {
    if (body.rootNodeType != 101 ||
        !body.schemaKey.endsWith(QStringLiteral("_13006")) ||
        body.nodeDataOffset + 3 > data.size()) return false;
    // Base schema 13006 WORLD fields from Siemens JT Annex E. Later fields
    // arrive as embedded C/D/I/A edits in the SolidWorks partition stream.
    const std::array<XtField, 11> base{{
        {"assembly", 'p'}, {"attribute", 'p'}, {"body", 'p'},
        {"transform", 'p'}, {"surface", 'p'}, {"curve", 'p'},
        {"point", 'p'}, {"alive", 'l'}, {"attrib_def", 'p'},
        {"highest_id", 'd'}, {"current_id", 'd'}
    }};
    qsizetype at = body.nodeDataOffset + 2;
    std::vector<XtField> fields;
    if (!readXtSchemaEdits(data, at, base, fields)) return false;
    quint32 rootIndex = 0;
    if (!readXtIndex(data, at, rootIndex) || rootIndex != 1) return false;
    quint32 bodyIndex = 0;
    for (const XtField& field : fields) {
        if (field.type == 'p') {
            quint32 pointer = 0;
            if (!readXtIndex(data, at, pointer)) return false;
            if (field.name == "body") bodyIndex = pointer;
        } else if (field.type == 'd') {
            if (at + 4 > data.size()) return false;
            at += 4;
        } else if (field.type == 'l') {
            if (at >= data.size() || (data[at] != '\0' && data[at] != '\1')) return false;
            ++at;
        } else {
            return false;
        }
    }
    if (at + 2 > data.size()) return false;
    body.rootNodeIndex = rootIndex;
    body.firstBodyNodeIndex = bodyIndex;
    body.nextNodeType = be16(data, at);
    body.firstBodyNodeOffset = at;
    return true;
}

bool parseParasolidFirstBody(const QByteArray& data, SolidWorksBodyStream& body) {
    if (body.firstBodyNodeIndex == 0 || body.nextNodeType != 12 ||
        body.firstBodyNodeOffset + 3 > data.size()) return false;
    // BODY's transmitted fields in base schema 13006. SolidWorks adds mesh,
    // polyline, index maps and child links through the embedded edit list.
    const std::array<XtField, 23> base{{
        {"highest_node_id", 'd'}, {"attributes_groups", 'p'},
        {"attribute_chains", 'p'}, {"surface", 'p'}, {"curve", 'p'},
        {"point", 'p'}, {"key", 'p'}, {"res_size", 'f'},
        {"res_linear", 'f'}, {"ref_instance", 'p'}, {"next", 'p'},
        {"previous", 'p'}, {"state", 'u'}, {"owner", 'p'},
        {"body_type", 'u'}, {"nom_geom_state", 'u'}, {"shell", 'p'},
        {"boundary_surface", 'p'}, {"boundary_curve", 'p'},
        {"boundary_point", 'p'}, {"region", 'p'}, {"edge", 'p'},
        {"vertex", 'p'}
    }};
    qsizetype at = body.firstBodyNodeOffset + 2;
    std::vector<XtField> fields;
    if (!readXtSchemaEdits(data, at, base, fields)) return false;
    quint32 index = 0;
    if (!readXtIndex(data, at, index) || index != body.firstBodyNodeIndex) return false;
    quint32 shell = 0;
    quint32 region = 0;
    quint8 bodyKind = 0;
    for (const XtField& field : fields) {
        if (field.type == 'p') {
            quint32 pointer = 0;
            if (!readXtIndex(data, at, pointer)) return false;
            if (field.name == "shell") shell = pointer;
            else if (field.name == "region") region = pointer;
        } else if (field.type == 'd') {
            if (at + 4 > data.size()) return false;
            at += 4;
        } else if (field.type == 'f') {
            if (at + 8 > data.size()) return false;
            at += 8;
        } else if (field.type == 'u' || field.type == 'c' || field.type == 'l') {
            if (at >= data.size()) return false;
            if (field.name == "body_type") bodyKind = static_cast<quint8>(data[at]);
            ++at;
        } else {
            return false;
        }
    }
    if (bodyKind != 1 && bodyKind != 2 && bodyKind != 3 && bodyKind != 6) return false;
    body.firstBodyKind = bodyKind;
    body.firstShellNodeIndex = shell;
    body.firstRegionNodeIndex = region;
    return true;
}

bool parseParasolidSections(const QByteArray& payload, const QString& configuration,
                            std::vector<SolidWorksBodyStream>& streams) {
    qsizetype sectionAt = 0;
    QByteArray magic;
    while (sectionAt < payload.size()) {
        if (payload.size() - sectionAt < 24) return false;
        const quint32 chainSize = u32(payload, sectionAt);
        const quint64 sectionEnd = quint64(sectionAt) + 4 + chainSize;
        if (chainSize < 28 || sectionEnd > quint64(payload.size())) return false;
        const QByteArray currentMagic = payload.mid(sectionAt + 4, 16);
        if (magic.isEmpty()) magic = currentMagic;
        if (currentMagic != magic) return false;
        qsizetype frameAt = sectionAt + 20;
        QByteArray parasolid;
        bool hasFrame = false;
        while (quint64(frameAt) + 8 <= sectionEnd) {
            const quint32 unpackedSize = u32(payload, frameAt);
            const quint32 packedSize = u32(payload, frameAt + 4);
            if (unpackedSize == 0 && packedSize == 0) break;
            if (unpackedSize == 0 || packedSize == 0 ||
                quint64(frameAt) + 8 + packedSize > sectionEnd ||
                quint64(parasolid.size()) + unpackedSize > kMaxParasolidStreamBytes) {
                return false;
            }
            QByteArray frame;
            if (!inflateExact(payload.constData() + frameAt + 8, packedSize,
                              unpackedSize, MAX_WBITS, frame)) return false;
            parasolid.append(frame);
            frameAt += 8 + packedSize;
            hasFrame = true;
        }
        if (!hasFrame) return false;
        for (qsizetype at = frameAt; quint64(at) < sectionEnd; ++at) {
            if (payload[at] != '\0') return false;
        }
        SolidWorksBodyStream body;
        body.configuration = configuration;
        if (!parseParasolidHeader(parasolid, body)) return false;
        if (parseParasolidWorld(parasolid, body)) parseParasolidFirstBody(parasolid, body);
        body.parasolid = std::move(parasolid);
        streams.push_back(std::move(body));
        sectionAt = qsizetype(sectionEnd);
    }
    return !streams.empty();
}

bool inspectKompasContents(const QByteArray& contents, KompasModelInfo& info) {
    if (!contents.startsWith("KF")) {
        info.undecodedContentBytes = contents.size();
        return true;
    }
    qsizetype at = 2;
    while (at + 2 <= contents.size()) {
        const unsigned cmf = static_cast<unsigned char>(contents[at]);
        const unsigned flg = static_cast<unsigned char>(contents[at + 1]);
        if ((cmf & 15u) != 8u || (cmf >> 4) > 7u ||
            ((cmf << 8) + flg) % 31u != 0u) break;
        if (info.compressedRecords >= 65535u) return false;
        z_stream stream{};
        stream.next_in = reinterpret_cast<Bytef*>(
            const_cast<char*>(contents.constData() + at));
        stream.avail_in = static_cast<uInt>(contents.size() - at);
        if (inflateInit(&stream) != Z_OK) return false;
        std::array<char, 65536> output{};
        int result = Z_OK;
        while (result == Z_OK) {
            stream.next_out = reinterpret_cast<Bytef*>(output.data());
            stream.avail_out = output.size();
            result = inflate(&stream, Z_NO_FLUSH);
            if (info.decodedRecordBytes + stream.total_out > kMaxArchiveBytes) break;
        }
        const quint64 consumed = stream.total_in;
        const quint64 produced = stream.total_out;
        inflateEnd(&stream);
        if (result != Z_STREAM_END || consumed == 0 ||
            info.decodedRecordBytes + produced > kMaxArchiveBytes) return false;
        at += qsizetype(consumed);
        info.decodedRecordBytes += produced;
        ++info.compressedRecords;
    }
    info.undecodedContentBytes = contents.size() - at;
    return true;
}

} // namespace

bool readFreeCadShapes(const QString& path, std::vector<FreeCadShape>& shapes,
                       QString& error) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть файл FreeCAD или файл слишком велик.");
        return false;
    }
    const QByteArray archive = file.readAll();
    QMap<QString, ZipEntry> entries;
    if (!zipEntries(archive, entries, error)) return false;
    QByteArray xml;
    if (!extract(archive, entries, QStringLiteral("Document.xml"), xml, error)) return false;
    QMap<QString, ShapeInfo> infos;
    if (!parseDocument(xml, infos, error)) return false;
    QSet<QString> bodyChildren;
    for (auto it = infos.cbegin(); it != infos.cend(); ++it) {
        if (it->type == QLatin1String("PartDesign::Body")) {
            for (const QString& child : it->group) bodyChildren.insert(child);
        }
    }
    for (auto it = infos.cbegin(); it != infos.cend(); ++it) {
        const ShapeInfo& info = it.value();
        if (info.file.isEmpty() || bodyChildren.contains(it.key()) ||
            (!info.type.startsWith(QLatin1String("Part::")) &&
             !info.type.startsWith(QLatin1String("PartDesign::")))) continue;
        QByteArray brep;
        if (!extract(archive, entries, info.file, brep, error)) return false;
        if (!brep.isEmpty()) shapes.push_back({info.label.isEmpty() ? it.key() : info.label,
                                               std::move(brep),
                                               info.file.endsWith(QLatin1String(".bin"),
                                                                  Qt::CaseInsensitive)});
    }
    if (shapes.empty()) {
        error = QObject::tr("В файле FreeCAD не найдены готовые BRep-тела.");
        return false;
    }
    return true;
}

bool writeFreeCadShapes(const QString& path, const std::vector<FreeCadShape>& shapes,
                        QString& error) {
    if (shapes.empty() || shapes.size() > 65533) {
        error = QObject::tr("Для экспорта FreeCAD нужно выбрать хотя бы одно тело.");
        return false;
    }
    QByteArray documentXml;
    QXmlStreamWriter document(&documentXml);
    document.setAutoFormatting(true);
    document.writeStartDocument();
    document.writeStartElement(QStringLiteral("Document"));
    document.writeAttribute(QStringLiteral("SchemaVersion"), QStringLiteral("4"));
    document.writeAttribute(QStringLiteral("FileVersion"), QStringLiteral("1"));
    document.writeEmptyElement(QStringLiteral("Properties"));
    document.writeAttribute(QStringLiteral("Count"), QStringLiteral("0"));
    document.writeStartElement(QStringLiteral("Objects"));
    document.writeAttribute(QStringLiteral("Count"), QString::number(shapes.size()));
    for (std::size_t i = 0; i < shapes.size(); ++i) {
        document.writeEmptyElement(QStringLiteral("Object"));
        document.writeAttribute(QStringLiteral("type"), QStringLiteral("Part::Feature"));
        document.writeAttribute(QStringLiteral("name"), QStringLiteral("CADNextPart%1").arg(i + 1));
    }
    document.writeEndElement();
    document.writeStartElement(QStringLiteral("ObjectData"));
    document.writeAttribute(QStringLiteral("Count"), QString::number(shapes.size()));
    std::vector<StoredZipMember> members;
    members.reserve(shapes.size() + 2);
    for (std::size_t i = 0; i < shapes.size(); ++i) {
        const FreeCadShape& shape = shapes[i];
        if (shape.brep.isEmpty() || shape.binary) {
            error = QObject::tr("Не удалось записать точную BRep-геометрию тела %1.")
                        .arg(shape.name);
            return false;
        }
        const QString objectName = QStringLiteral("CADNextPart%1").arg(i + 1);
        const QString brepName = objectName + QStringLiteral(".brp");
        document.writeStartElement(QStringLiteral("Object"));
        document.writeAttribute(QStringLiteral("name"), objectName);
        document.writeStartElement(QStringLiteral("Properties"));
        document.writeAttribute(QStringLiteral("Count"), QStringLiteral("2"));
        document.writeStartElement(QStringLiteral("Property"));
        document.writeAttribute(QStringLiteral("name"), QStringLiteral("Label"));
        document.writeAttribute(QStringLiteral("type"), QStringLiteral("App::PropertyString"));
        document.writeEmptyElement(QStringLiteral("String"));
        document.writeAttribute(QStringLiteral("value"),
                                shape.name.isEmpty() ? objectName : shape.name);
        document.writeEndElement();
        document.writeStartElement(QStringLiteral("Property"));
        document.writeAttribute(QStringLiteral("name"), QStringLiteral("Shape"));
        document.writeAttribute(QStringLiteral("type"), QStringLiteral("Part::PropertyPartShape"));
        document.writeEmptyElement(QStringLiteral("Part"));
        document.writeAttribute(QStringLiteral("file"), brepName);
        document.writeEndElement();
        document.writeEndElement();
        document.writeEndElement();
        members.push_back({brepName.toUtf8(), shape.brep});
    }
    document.writeEndElement();
    document.writeEndElement();
    document.writeEndDocument();
    if (document.hasError()) {
        error = QObject::tr("Не удалось записать Document.xml файла FreeCAD.");
        return false;
    }

    QByteArray guiXml;
    QXmlStreamWriter gui(&guiXml);
    gui.setAutoFormatting(true);
    gui.writeStartDocument();
    gui.writeStartElement(QStringLiteral("Document"));
    gui.writeAttribute(QStringLiteral("SchemaVersion"), QStringLiteral("1"));
    gui.writeStartElement(QStringLiteral("ViewProviderData"));
    gui.writeAttribute(QStringLiteral("Count"), QString::number(shapes.size()));
    for (std::size_t i = 0; i < shapes.size(); ++i) {
        gui.writeStartElement(QStringLiteral("ViewProvider"));
        gui.writeAttribute(QStringLiteral("name"), QStringLiteral("CADNextPart%1").arg(i + 1));
        gui.writeAttribute(QStringLiteral("expanded"), QStringLiteral("1"));
        gui.writeStartElement(QStringLiteral("Properties"));
        gui.writeAttribute(QStringLiteral("Count"), QStringLiteral("1"));
        gui.writeStartElement(QStringLiteral("Property"));
        gui.writeAttribute(QStringLiteral("name"), QStringLiteral("Visibility"));
        gui.writeAttribute(QStringLiteral("type"), QStringLiteral("App::PropertyBool"));
        gui.writeEmptyElement(QStringLiteral("Bool"));
        gui.writeAttribute(QStringLiteral("value"), QStringLiteral("true"));
        gui.writeEndElement();
        gui.writeEndElement();
        gui.writeEndElement();
    }
    gui.writeEndElement();
    gui.writeEndElement();
    gui.writeEndDocument();
    if (gui.hasError()) {
        error = QObject::tr("Не удалось записать GuiDocument.xml файла FreeCAD.");
        return false;
    }
    members.insert(members.begin(), {"GuiDocument.xml", guiXml});
    members.insert(members.begin(), {"Document.xml", documentXml});
    return writeStoredZip(path, members, error);
}

namespace {

// KOMPAS-3D v24 keeps the product in MetaProductInfo (its MetaInfo is an XML declaration alone):
// an infObject of type "embodiment" is the document in one of its variants, one of type
// "component" a component, its file in <document><property id="fullFileName">. Properties are
// named, not numbered, and nest (a material's name is not the object's): only an infObject's own
// "name" counts. The document's name is that of the embodiment <product><document curEmbKey> names.
bool readKompasProductInfo(const QByteArray& xml, KompasModelInfo& info, QString& error) {
    QXmlStreamReader reader(xml);
    QStringList open;
    QString objectType, objectId, currentEmbodiment, firstEmbodiment;
    QMap<QString, QString> embodimentNames;
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.isStartElement()) {
            const QString element = reader.name().toString();
            const auto attributes = reader.attributes();
            const QString parent = open.isEmpty() ? QString() : open.back();
            if (element == QLatin1String("infObject")) {
                objectType = attributes.value(QLatin1String("type")).toString();
                objectId = attributes.value(QLatin1String("id")).toString();
                if (objectType == QLatin1String("embodiment") && firstEmbodiment.isEmpty()) firstEmbodiment = objectId;
            } else if (element == QLatin1String("document") && parent == QLatin1String("product")) {
                currentEmbodiment = attributes.value(QLatin1String("curEmbKey")).toString();
            } else if (element == QLatin1String("property") && !objectType.isEmpty()) {
                const QString id = attributes.value(QLatin1String("id")).toString();
                const QString value = attributes.value(QLatin1String("value")).toString();
                if (value.isEmpty()) {
                } else if (parent == QLatin1String("infObject") && id == QLatin1String("name")) {
                    if (objectType == QLatin1String("embodiment")) embodimentNames.insert(objectId, value);
                    else if (objectType == QLatin1String("component") && !info.objects.contains(value)) info.objects.push_back(value);
                } else if (parent == QLatin1String("document") && id == QLatin1String("fullFileName") &&
                           objectType == QLatin1String("component") && !info.externalFiles.contains(value)) {
                    info.externalFiles.push_back(value);
                }
            }
            open.push_back(element);
        } else if (reader.isEndElement()) {
            if (reader.name() == QLatin1String("infObject")) objectType.clear();
            if (!open.isEmpty()) open.pop_back();
        }
    }
    if (reader.hasError() || !open.isEmpty()) {
        error = QObject::tr("Повреждён MetaProductInfo модели КОМПАС-3D: %1").arg(reader.errorString());
        return false;
    }
    info.name = embodimentNames.value(embodimentNames.contains(currentEmbodiment) ? currentEmbodiment : firstEmbodiment);
    return true;
}

} // namespace

bool readKompasModelInfo(const QString& path, KompasModelInfo& info, QString& error) {
    info = {};
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть модель КОМПАС-3D или файл слишком велик.");
        return false;
    }
    const QByteArray archive = file.readAll();
    if (archive.startsWith("KF")) {
        error = QObject::tr("Старый бинарный контейнер KF КОМПАС-3D пока не поддерживается.");
        return false;
    }
    QMap<QString, ZipEntry> entries;
    QString zipError;
    if (!zipEntries(archive, entries, zipError)) {
        error = QObject::tr("Неподдерживаемый контейнер КОМПАС-3D: %1").arg(zipError);
        return false;
    }
    if (!entries.contains(QStringLiteral("Contents")) ||
        !entries.contains(QStringLiteral("MetaInfo"))) {
        error = QObject::tr("В модели КОМПАС-3D отсутствует Contents или MetaInfo.");
        return false;
    }
    if (entries.value(QStringLiteral("MetaInfo")).size > kMaxAssemblyManifestBytes) {
        error = QObject::tr("Метаданные КОМПАС-3D слишком велики.");
        return false;
    }
    QByteArray xml;
    if (!extract(archive, entries, QStringLiteral("MetaInfo"), xml, zipError)) {
        error = QObject::tr("Не удалось прочитать метаданные КОМПАС-3D: %1").arg(zipError);
        return false;
    }
    QByteArray contents;
    if (!extract(archive, entries, QStringLiteral("Contents"), contents, zipError) ||
        !inspectKompasContents(contents, info)) {
        error = QObject::tr("Не удалось распаковать раздел Contents модели КОМПАС-3D.");
        info = {};
        return false;
    }
    QXmlStreamReader reader(xml);
    int objectDepth = 0;
    bool rooted = false;
    // An embodiment object is the document itself (its values repeat the document's), not one of its objects.
    std::vector<bool> embodiment;
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.isStartElement()) {
            rooted = true;
            if (reader.name() == QLatin1String("object")) {
                ++objectDepth;
                embodiment.push_back(reader.attributes().value(QLatin1String("type")) == QLatin1String("embodiment"));
            } else if (reader.name() == QLatin1String("property")) {
                const auto attributes = reader.attributes();
                const QString id = attributes.value(QLatin1String("id")).toString();
                const QString value = attributes.value(QLatin1String("value")).toString();
                if (id == QLatin1String("5") && !value.isEmpty()) {
                    if (objectDepth == 0) info.name = value;
                    else if (!embodiment.empty() && embodiment.back()) continue;
                    else if (!info.objects.contains(value)) info.objects.push_back(value);
                } else if (id == QLatin1String("16") && !value.isEmpty() &&
                           !info.externalFiles.contains(value)) {
                    info.externalFiles.push_back(value);
                }
            }
        } else if (reader.isEndElement() && reader.name() == QLatin1String("object")) {
            --objectDepth;
            if (!embodiment.empty()) embodiment.pop_back();
            if (objectDepth < 0) break;
        }
    }
    if (!rooted && entries.contains(QStringLiteral("MetaProductInfo"))) {
        // A MetaInfo without a root element: the product is in MetaProductInfo.
        QByteArray product;
        if (entries.value(QStringLiteral("MetaProductInfo")).size > kMaxAssemblyManifestBytes ||
            !extract(archive, entries, QStringLiteral("MetaProductInfo"), product, zipError)) {
            error = QObject::tr("Не удалось прочитать метаданные КОМПАС-3D: %1").arg(zipError);
            info = {};
            return false;
        }
        if (!readKompasProductInfo(product, info, error)) {
            info = {};
            return false;
        }
        return true;
    }
    if (reader.hasError() || objectDepth != 0) {
        error = QObject::tr("Повреждён MetaInfo модели КОМПАС-3D: %1")
                    .arg(reader.errorString());
        info = {};
        return false;
    }
    return true;
}

bool readKompasArchiveMember(const QString& path, const QString& member, QByteArray& bytes, QString& error) {
    bytes.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть модель КОМПАС-3D или файл слишком велик.");
        return false;
    }
    const QByteArray archive = file.readAll();
    QMap<QString, ZipEntry> entries;
    QString zipError;
    if (archive.startsWith("KF") || !zipEntries(archive, entries, zipError)) {
        error = QObject::tr("Неподдерживаемый контейнер КОМПАС-3D: %1").arg(zipError);
        return false;
    }
    if (!entries.contains(member)) {
        error = QObject::tr("В модели КОМПАС-3D отсутствует %1.").arg(member);
        return false;
    }
    if (!extract(archive, entries, member, bytes, zipError)) {
        error = QObject::tr("Не удалось прочитать %1 модели КОМПАС-3D: %2").arg(member, zipError);
        bytes.clear();
        return false;
    }
    return true;
}

bool readKompasContents(const QString& path, QByteArray& contents, QString& error) {
    contents.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть модель КОМПАС-3D или файл слишком велик.");
        return false;
    }
    const QByteArray archive = file.readAll();
    if (archive.startsWith("KF")) {
        error = QObject::tr("Старый бинарный контейнер KF КОМПАС-3D пока не поддерживается.");
        return false;
    }
    QMap<QString, ZipEntry> entries;
    QString zipError;
    if (!zipEntries(archive, entries, zipError)) {
        error = QObject::tr("Неподдерживаемый контейнер КОМПАС-3D: %1").arg(zipError);
        return false;
    }
    if (!entries.contains(QStringLiteral("Contents"))) {
        error = QObject::tr("В модели КОМПАС-3D отсутствует Contents.");
        return false;
    }
    if (!extract(archive, entries, QStringLiteral("Contents"), contents, zipError)) {
        error = QObject::tr("Не удалось прочитать Contents модели КОМПАС-3D: %1")
                    .arg(zipError);
        contents.clear();
        return false;
    }
    return true;
}

bool readKompasStorageImage(const QString& path, KompasStorageImage& image,
                            QString& error) {
    image = {};
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть модель КОМПАС-3D или файл слишком велик.");
        return false;
    }
    const QByteArray archive = file.readAll();
    if (archive.startsWith("KF")) {
        error = QObject::tr("Старый бинарный контейнер KF КОМПАС-3D пока не поддерживается.");
        return false;
    }
    QMap<QString, ZipEntry> entries;
    QString zipError;
    if (!zipEntries(archive, entries, zipError) ||
        !entries.contains(QStringLiteral("Contents")) ||
        !entries.contains(QStringLiteral("SysInfo"))) {
        error = QObject::tr("В модели КОМПАС-3D отсутствует поддерживаемое Contents или SysInfo: %1")
                    .arg(zipError);
        return false;
    }
    QByteArray contents, sysInfo;
    if (!extract(archive, entries, QStringLiteral("Contents"), contents, zipError) ||
        !extract(archive, entries, QStringLiteral("SysInfo"), sysInfo, zipError)) {
        error = QObject::tr("Не удалось прочитать хранилище КОМПАС-3D: %1").arg(zipError);
        return false;
    }
    KompasStorageIndex index;
    if (!decodeKompasStorageIndex(contents, sysInfo, index, error)) return false;
    image = {std::move(contents), std::move(sysInfo)};
    return true;
}

bool readKompasFileInfo(const QString& path, KompasFileInfo& info, QString& error) {
    info = {}; error.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть модель КОМПАС-3D или файл слишком велик.");
        return false;
    }
    QMap<QString, ZipEntry> entries;
    const QByteArray archive = file.readAll();
    if (!zipEntries(archive, entries, error) ||
        !entries.contains(QStringLiteral("FileInfo"))) {
        if (error.isEmpty()) error = QObject::tr("В модели КОМПАС-3D отсутствует FileInfo.");
        return false;
    }
    if (entries.value(QStringLiteral("FileInfo")).size > 128 * 1024) {
        error = QObject::tr("FileInfo модели КОМПАС-3D превышает 128 КиБ.");
        return false;
    }
    QByteArray bytes;
    return extract(archive, entries, QStringLiteral("FileInfo"), bytes, error) &&
           decodeKompasFileInfo(bytes, info, error);
}

bool readSolidWorksAssemblyManifest(const QString& path, QByteArray& manifest, QString& error) {
    manifest.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть сборку SOLIDWORKS или файл слишком велик.");
        return false;
    }
    const QByteArray bytes = file.readAll();
    if (bytes.size() < 30) {
        error = QObject::tr("Файл сборки SOLIDWORKS слишком короткий.");
        return false;
    }
    const QByteArray marker = QByteArray::fromHex("140006000800");
    const unsigned shift = static_cast<unsigned char>(bytes[7]) & 7u;
    qsizetype searchAt = 0;
    while (true) {
        const qsizetype markerAt = bytes.indexOf(marker, searchAt);
        if (markerAt < 0) break;
        searchAt = markerAt + marker.size();
        if (markerAt < 4) continue;
        const qsizetype start = markerAt - 4;
        if (start + 30 > bytes.size()) continue;
        const quint32 nameSize = u32(bytes, start + 26);
        const quint32 packedSize = u32(bytes, start + 18);
        const quint32 unpackedSize = u32(bytes, start + 22);
        const quint32 checksum = u32(bytes, start + 14);
        if (nameSize == 0 || nameSize > 512 ||
            quint64(start) + 30 + nameSize > quint64(bytes.size())) continue;
        QByteArray name = bytes.mid(start + 30, nameSize);
        for (char& value : name) {
            const auto byte = static_cast<unsigned char>(value);
            value = static_cast<char>(shift == 0 ? byte :
                                      ((byte << shift) | (byte >> (8 - shift))) & 0xffu);
        }
        if (name != "swXmlContents/COMPINSTANCETREE" ||
            packedSize == 0 || unpackedSize == 0) continue;
        const quint64 payloadAt = quint64(start) + 30 + nameSize;
        if (unpackedSize > kMaxAssemblyManifestBytes ||
            payloadAt + packedSize > quint64(bytes.size())) {
            error = QObject::tr("Список компонентов сборки повреждён или слишком велик.");
            return false;
        }
        if (!inflateExact(bytes.constData() + payloadAt, packedSize,
                          unpackedSize, -MAX_WBITS, manifest)) {
            error = QObject::tr("Список компонентов сборки повреждён.");
            return false;
        }
        if (crc32(0, reinterpret_cast<const Bytef*>(manifest.constData()),
                  static_cast<uInt>(manifest.size())) != checksum) {
            error = QObject::tr("Контрольная сумма списка компонентов сборки неверна.");
            return false;
        }
        break;
    }
    if (manifest.isEmpty()) {
        error = QObject::tr("Не найден список компонентов сборки SOLIDWORKS 2015+.");
        return false;
    }
    return true;
}

bool readSolidWorksAssemblyComponents(const QString& path,
                                      std::vector<SolidWorksAssemblyComponent>& components,
                                      QString& error) {
    components.clear();
    QByteArray manifest;
    if (!readSolidWorksAssemblyManifest(path, manifest, error)) return false;

    QMap<QString, QString> files;
    QMap<QString, QString> modelFiles;
    struct PendingComponent {
        QString modelId;
        SolidWorksAssemblyComponent component;
    };
    std::vector<PendingComponent> pending;
    QXmlStreamReader reader(manifest);
    while (!reader.atEnd()) {
        reader.readNext();
        if (!reader.isStartElement()) continue;
        const auto attrs = reader.attributes();
        if (reader.name() == QLatin1String("swFile")) {
            files.insert(attrs.value(QLatin1String("id")).toString(),
                         attrs.value(QLatin1String("swPath")).toString());
        } else if (reader.name() == QLatin1String("swModel")) {
            modelFiles.insert(attrs.value(QLatin1String("id")).toString(),
                              attrs.value(QLatin1String("swFileRef")).toString());
        } else if (reader.name() == QLatin1String("swReference")) {
            PendingComponent item;
            item.modelId = attrs.value(QLatin1String("swModelRef")).toString();
            item.component.name = attrs.value(QLatin1String("swName")).toString();
            item.component.configuration =
                attrs.value(QLatin1String("swConfigurationName")).toString();
            item.component.virtualComponent =
                attrs.value(QLatin1String("swIsVirtualComponent")) == QLatin1String("YES");
            const QStringList values = attrs.value(QLatin1String("swTransform"))
                                           .toString().simplified().split(QLatin1Char(' '),
                                                                          Qt::SkipEmptyParts);
            if (values.size() != 16) {
                error = QObject::tr("У компонента %1 нет корректной матрицы положения.")
                            .arg(item.component.name);
                return false;
            }
            for (qsizetype i = 0; i < 16; ++i) {
                bool valid = false;
                const double value = values[i].toDouble(&valid);
                if (!valid || !std::isfinite(value)) {
                    error = QObject::tr("Некорректная матрица положения компонента %1.")
                                .arg(item.component.name);
                    return false;
                }
                item.component.transform[static_cast<std::size_t>(i)] = value;
            }
            pending.push_back(std::move(item));
        }
    }
    if (reader.hasError()) {
        error = QObject::tr("Некорректный список компонентов сборки: %1")
                    .arg(reader.errorString());
        return false;
    }
    for (PendingComponent& item : pending) {
        item.component.sourcePath = files.value(modelFiles.value(item.modelId));
        if (!item.component.virtualComponent && item.component.sourcePath.isEmpty()) {
            error = QObject::tr("Не найдена ссылка на файл компонента %1.")
                        .arg(item.component.name);
            return false;
        }
        components.push_back(std::move(item.component));
    }
    return true;
}

bool readSolidWorksAssemblyReferences(const QString& path, QStringList& paths,
                                      QString& error) {
    paths.clear();
    std::vector<SolidWorksAssemblyComponent> components;
    if (!readSolidWorksAssemblyComponents(path, components, error)) return false;
    QSet<QString> seen;
    for (const SolidWorksAssemblyComponent& component : components) {
        if (!component.virtualComponent && !seen.contains(component.sourcePath)) {
            paths.push_back(component.sourcePath);
            seen.insert(component.sourcePath);
        }
    }
    return true;
}

bool readSolidWorksPartBodyStreams(const QString& path,
                                   std::vector<SolidWorksBodyStream>& streams,
                                   QString& error) {
    streams.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || quint64(file.size()) > kMaxArchiveBytes) {
        error = QObject::tr("Не удалось открыть деталь SOLIDWORKS или файл слишком велик.");
        return false;
    }
    const QByteArray bytes = file.readAll();
    const bool compound = bytes.startsWith(QByteArray::fromHex("d0cf11e0a1b11ae1"));
    if (!compound && (bytes.size() < 8 || static_cast<unsigned char>(bytes[4]) != 0 ||
        static_cast<unsigned char>(bytes[5]) != 0 ||
        static_cast<unsigned char>(bytes[6]) != 0 ||
        static_cast<unsigned char>(bytes[7]) != 4)) {
        error = QObject::tr("Неподдерживаемая версия контейнера детали SOLIDWORKS.");
        return false;
    }
    bool sawPartition = false;
    if (compound) {
        CompoundFile storage;
        if (!decodeCompoundFile(bytes, storage, error)) return false;
        for (const auto& entry : storage.entries) {
            if (entry.kind != CompoundFileEntry::Kind::Stream ||
                !entry.path.startsWith("Contents/Config-") || !entry.path.endsWith("-Partition")) continue;
            const auto config = entry.path.mid(16, entry.path.size() - 16 - 10);
            if (config.isEmpty()) continue;
            sawPartition = true;
            std::vector<SolidWorksBodyStream> parsed;
            if (!parseParasolidSections(entry.data, config, parsed)) {
                streams.clear();
                error = QObject::tr("Раздел точной геометрии SOLIDWORKS %1 повреждён или имеет неизвестную структуру.").arg(entry.path);
                return false;
            }
            streams.insert(streams.end(), std::make_move_iterator(parsed.begin()), std::make_move_iterator(parsed.end()));
        }
    } else {
        const QByteArray marker = QByteArray::fromHex("140006000800");
        const unsigned shift = static_cast<unsigned char>(bytes[7]) & 7u;
        qsizetype searchAt = 8;
        while (true) {
            const qsizetype at = bytes.indexOf(marker, searchAt);
            if (at < 0) break;
            searchAt = at + marker.size();
            if (quint64(at) + 26 > quint64(bytes.size())) continue;
            const quint32 crc = u32(bytes, at + 10);
            const quint32 packedSize = u32(bytes, at + 14);
            const quint32 unpackedSize = u32(bytes, at + 18);
            const quint32 nameSize = u32(bytes, at + 22);
            if (nameSize == 0 || nameSize > 512 ||
                quint64(at) + 26 + nameSize > quint64(bytes.size())) continue;
            QByteArray name = bytes.mid(at + 26, nameSize);
            for (char& value : name) {
                const auto byte = static_cast<unsigned char>(value);
                value = static_cast<char>(shift == 0 ? byte :
                                          ((byte << shift) | (byte >> (8 - shift))) & 0xffu);
            }
            if (!name.startsWith("Contents/Config-") || !name.endsWith("-Partition")) continue;
            const QByteArray config = name.mid(16, name.size() - 16 - 10);
            if (config.isEmpty()) continue;
            sawPartition = true;
            const quint64 payloadAt = quint64(at) + 26 + nameSize;
            if (packedSize == 0 || unpackedSize == 0 ||
                packedSize > kMaxEntryBytes || unpackedSize > kMaxEntryBytes ||
                payloadAt + packedSize > quint64(bytes.size())) continue;
            QByteArray payload;
            if (!inflateExact(bytes.constData() + payloadAt, packedSize, unpackedSize,
                              -MAX_WBITS, payload)) continue;
            if (crc32(0, reinterpret_cast<const Bytef*>(payload.constData()),
                      static_cast<uInt>(payload.size())) != crc) continue;
            std::vector<SolidWorksBodyStream> parsed;
            if (!parseParasolidSections(payload, QString::fromLatin1(config), parsed)) continue;
            streams.insert(streams.end(), std::make_move_iterator(parsed.begin()),
                           std::make_move_iterator(parsed.end()));
            searchAt = qsizetype(payloadAt + packedSize);
        }
    }
    if (streams.empty()) {
        error = sawPartition
                    ? QObject::tr("Раздел точной геометрии SOLIDWORKS повреждён или имеет неизвестную структуру.")
                    : QObject::tr("В детали SOLIDWORKS не найден раздел точной геометрии.");
        return false;
    }
    QByteArray header;
    bool hasNames = false;
    QMap<QString, QString> names;
    if (!solidWorksEntry(bytes, "Contents/CMgrHdr2", header, hasNames) ||
        (hasNames && !solidWorksConfigurationNames(header, names))) {
        streams.clear();
        error = QObject::tr("Список конфигураций SOLIDWORKS повреждён или имеет неподдерживаемую схему.");
        return false;
    }
    for (auto& stream : streams) stream.configurationName = names.value(stream.configuration);
    error.clear();
    return true;
}

bool readSolidWorksPartConfigurations(const QString& path,
                                     std::vector<SolidWorksConfiguration>& configurations,
                                     QString& error) {
    configurations.clear();
    std::vector<SolidWorksBodyStream> streams;
    if (!readSolidWorksPartBodyStreams(path, streams, error)) return false;
    QSet<QString> seen;
    for (const auto& stream : streams) {
        if (stream.kind != QLatin1String("partition") || seen.contains(stream.configuration)) continue;
        configurations.push_back({stream.configuration, stream.configurationName});
        seen.insert(stream.configuration);
    }
    if (configurations.empty()) {
        error = QObject::tr("В детали нет сохранённой текущей геометрии конфигураций.");
        return false;
    }
    error.clear();
    return true;
}

QString nativeCadImportDiagnostic(const QString& sourcePath) {
    QString diagnostic = QObject::tr("Собственный конвертер CADNext пока не читает "
                                     "точную геометрию этого родного формата.");
    if (QFileInfo(sourcePath).suffix().compare(QLatin1String("sldprt"),
                                               Qt::CaseInsensitive) == 0) {
        std::vector<SolidWorksBodyStream> streams;
        QString inspectError;
        if (readSolidWorksPartBodyStreams(sourcePath, streams, inspectError)) {
            for (const SolidWorksBodyStream& stream : streams) {
                if (stream.kind != QStringLiteral("partition")) continue;
                ParasolidXtTopology topology;
                if (readParasolidXtTopology(stream.parasolid, topology, inspectError)) {
                    const auto planarFaces = parasolidXtPlanarFaces(topology);
                    return QObject::tr("Прочитан граф точной геометрии Parasolid: "
                                       "%1 узлов, %2 оболочек, %3 граней, %4 рёбер, "
                                       "%5 вершин. Восстановлено %6 плоских граней. "
                                       "Точное тело собирается из поддержанных аналитических "
                                       "граней после проверки их исходных рёбер и замкнутости; "
                                       "аналитические и B-сплайн поверхности поддерживаются. "
                                       "Deltas содержат историю отката и не изменяют текущий снимок partition.")
                        .arg(topology.nodeCount).arg(topology.shellCount)
                        .arg(topology.faces.size()).arg(topology.edges.size())
                        .arg(topology.vertices.size()).arg(planarFaces.size());
                }
            }
            return QObject::tr("В детали найдены %1 потоков точной геометрии Parasolid. "
                               "Для открытия тела в CADNext ещё нужен декодер поверхностей и топологии.")
                .arg(streams.size());
        }
        return diagnostic + QLatin1Char('\n') + inspectError;
    }
    const QString suffix = QFileInfo(sourcePath).suffix().toLower();
    if (suffix == QStringLiteral("m3d") || suffix == QStringLiteral("a3d")) {
        KompasModelInfo info;
        QString inspectError;
        if (!readKompasModelInfo(sourcePath, info, inspectError)) {
            return diagnostic + QLatin1Char('\n') + inspectError;
        }
        const QString name = info.name.isEmpty() ? QFileInfo(sourcePath).completeBaseName()
                                                 : info.name;
        std::vector<KompasCylindricalFace> faces;
        QString geometryError;
        if (readKompasCylindricalFacesFromFile(sourcePath, faces, geometryError)) {
            return QObject::tr("Метаданные КОМПАС-3D прочитаны: %1; объектов: %2; "
                               "сжатых записей Contents: %3. Восстановлено %4 "
                               "проверенных цилиндрических граней; полная топология ещё "
                               "не восстановлена.")
                .arg(name).arg(info.objects.size()).arg(info.compressedRecords)
                .arg(faces.size());
        }
        return diagnostic + QObject::tr("\nМетаданные КОМПАС-3D прочитаны: %1; объектов: %2; "
                                        "сжатых записей Contents: %3. Цилиндрические "
                                        "грани не извлечены: %4")
                                .arg(name).arg(info.objects.size())
                                .arg(info.compressedRecords).arg(geometryError);
    }
    if (suffix == QStringLiteral("dwg")) {
        DwgStructure structure;
        QString inspectError;
        if (readDwgStructure(sourcePath, structure, inspectError)) {
            return QObject::tr("Контейнер DWG %1 прочитан: %2 страниц, %3 разделов. "
                               "Объектная геометрия пока требует декодирования "
                               "AcDb bit-stream.")
                .arg(structure.version).arg(structure.pages.size())
                .arg(structure.sections.size());
        }
        return diagnostic + QLatin1Char('\n') + inspectError;
    }
    if (QFileInfo(sourcePath).suffix().compare(QLatin1String("sldasm"),
                                               Qt::CaseInsensitive) != 0) {
        return diagnostic;
    }
    QStringList references;
    QString inspectError;
    if (!readSolidWorksAssemblyReferences(sourcePath, references, inspectError)) {
        return diagnostic + QLatin1Char('\n') + inspectError;
    }
    QStringList missing;
    const QDir assemblyDir = QFileInfo(sourcePath).dir();
    for (const QString& path : references) {
        QString normalized = path;
        normalized.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString name = normalized.section(QLatin1Char('/'), -1);
        if (!assemblyDir.exists(name)) missing.push_back(name);
    }
    if (!missing.isEmpty()) {
        diagnostic += QObject::tr("\nВ каталоге сборки отсутствуют детали: %1. "
                                  "Без них точные тела получить нельзя.")
                          .arg(missing.join(QStringLiteral(", ")));
    }
    return diagnostic;
}

} // namespace cadnext::gui
