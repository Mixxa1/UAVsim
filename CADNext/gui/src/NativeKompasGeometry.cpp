#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeCadImport.hpp"

#include <QObject>
#include <QHash>
#include <QtEndian>

#include <array>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>

#include <zlib.h>

#ifdef CADNEXT_WITH_OCCT
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <gp_Ax3.hxx>
#include <gp_Cylinder.hxx>
#include <gp_Dir.hxx>
#include <gp_Pnt.hxx>
#include <Standard_Failure.hxx>
#include <TopoDS_Face.hxx>
#endif

namespace cadnext::gui {
namespace {

constexpr qsizetype kMaxContentsBytes = 256 * 1024 * 1024;
constexpr quint64 kMaxDecodedBytes = 512ull * 1024 * 1024;
constexpr quint64 kMaxRecordBytes = 64ull * 1024 * 1024;
constexpr std::size_t kMaxRecords = 8192;

struct C3dNode {
    quint16 type = 0;
    quint16 id = 0;
    QByteArray bytes;
};

quint16 littleU16(const QByteArray& bytes, qsizetype at) {
    return quint16(quint8(bytes[at])) |
           (quint16(quint8(bytes[at + 1])) << 8);
}

double littleDouble(const QByteArray& bytes, qsizetype at) {
    static_assert(sizeof(double) == sizeof(quint64));
    const quint64 bits = qFromLittleEndian<quint64>(
        reinterpret_cast<const uchar*>(bytes.constData() + at));
    double value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool near(double a, double b, double tolerance = 1e-7) {
    return std::isfinite(a) && std::isfinite(b) &&
           std::fabs(a - b) <= tolerance * (1.0 + std::fabs(b));
}

bool nearPoint(const std::array<double, 3>& a,
               const std::array<double, 3>& b) {
    return near(a[0], b[0]) && near(a[1], b[1]) && near(a[2], b[2]);
}

std::array<double, 3> readPoint(const QByteArray& bytes, qsizetype at) {
    return {littleDouble(bytes, at), littleDouble(bytes, at + 8),
            littleDouble(bytes, at + 16)};
}

bool isNodeMarker(const QByteArray& bytes, qsizetype at) {
    return at + 7 <= bytes.size() &&
           quint8(bytes[at]) == 0x02 && quint8(bytes[at + 1]) == 0x80 &&
           quint8(bytes[at + 4]) == 0x01;
}

QHash<quint16, C3dNode> readNodeGraph(const KompasContentsRecords& contents) {
    QHash<quint16, C3dNode> nodes;
    for (const auto& record : contents.records) {
        const QByteArray& bytes = record.decoded;
        if (bytes.size() < 1000) continue;
        // In the v17.1 sample, two consecutive zlib members contain node
        // IDs 0x49b..0x512 and 0x513..0x6dc. Each node begins with
        // 02 80 <type:u16> 01 <id:u16>. Requiring an uninterrupted ID
        // sequence keeps incidental marker bytes in payloads out of the map.
        std::vector<qsizetype> positions;
        for (qsizetype at = 0; at + 7 <= bytes.size(); ++at) {
            if (isNodeMarker(bytes, at)) positions.push_back(at);
        }
        if (positions.size() < 20 || positions.size() > 65535) continue;
        const quint16 firstId = littleU16(bytes, positions.front() + 5);
        bool ordered = true;
        for (std::size_t i = 1; i < positions.size(); ++i) {
            if (quint32(firstId) + i > 65535 ||
                littleU16(bytes, positions[i] + 5) != firstId + i) {
                ordered = false;
                break;
            }
        }
        if (!ordered) continue;
        for (std::size_t i = 0; i < positions.size(); ++i) {
            const qsizetype end = i + 1 < positions.size()
                ? positions[i + 1] : bytes.size();
            const quint16 id = firstId + quint16(i);
            if (nodes.contains(id)) return {};
            nodes.insert(id, {littleU16(bytes, positions[i] + 2), id,
                              bytes.mid(positions[i], end - positions[i])});
        }
    }
    return nodes;
}

bool containsNodeReference(const QByteArray& bytes, quint16 id,
                           qsizetype begin) {
    for (qsizetype at = begin; at + 3 <= bytes.size(); ++at) {
        if (quint8(bytes[at]) == 1 && littleU16(bytes, at + 1) == id)
            return true;
    }
    return false;
}

bool hasEndpointPoints(const QHash<quint16, C3dNode>& nodes,
                       const std::array<double, 3>& start,
                       const std::array<double, 3>& end) {
    bool hasStart = false;
    bool hasEnd = false;
    for (const C3dNode& node : nodes) {
        if (node.type != 0x0b04 || node.bytes.size() < 51) continue;
        const auto point = readPoint(node.bytes, 27);
        hasStart |= nearPoint(point, start);
        hasEnd |= nearPoint(point, end);
        if (hasStart && hasEnd) return true;
    }
    return false;
}

bool isZlibHeader(const QByteArray& bytes, qsizetype at) {
    if (at < 0 || at + 2 > bytes.size()) return false;
    const auto cmf = static_cast<unsigned char>(bytes[at]);
    const auto flg = static_cast<unsigned char>(bytes[at + 1]);
    return (cmf & 0x0f) == Z_DEFLATED && (cmf >> 4) <= 7 &&
           ((unsigned(cmf) << 8) | flg) % 31 == 0 && (flg & 0x20) == 0;
}

bool inflateRecord(const QByteArray& contents, qsizetype at,
                   quint64 decodedSoFar, KompasContentsRecord& record,
                   QString& error) {
    z_stream stream{};
    stream.next_in = reinterpret_cast<Bytef*>(
        const_cast<char*>(contents.constData() + at));
    stream.avail_in = static_cast<uInt>(contents.size() - at);
    if (inflateInit(&stream) != Z_OK) {
        error = QObject::tr("Не удалось инициализировать распаковку записи Contents.");
        return false;
    }

    QByteArray decoded;
    std::array<char, 64 * 1024> buffer{};
    int status = Z_OK;
    do {
        const uLong previousIn = stream.total_in;
        const uLong previousOut = stream.total_out;
        stream.next_out = reinterpret_cast<Bytef*>(buffer.data());
        stream.avail_out = static_cast<uInt>(buffer.size());
        status = inflate(&stream, Z_NO_FLUSH);
        const quint64 produced = stream.total_out - previousOut;
        if (produced > kMaxRecordBytes - quint64(decoded.size()) ||
            produced > kMaxDecodedBytes - decodedSoFar - quint64(decoded.size())) {
            inflateEnd(&stream);
            error = QObject::tr("Распакованная запись Contents превышает допустимый размер.");
            return false;
        }
        decoded.append(buffer.data(), qsizetype(produced));
        if (status == Z_STREAM_END) break;
        if (status != Z_OK || (previousIn == stream.total_in && produced == 0)) {
            inflateEnd(&stream);
            error = QObject::tr("Повреждена или обрезана сжатая запись Contents.");
            return false;
        }
    } while (true);

    const quint64 consumed = stream.total_in;
    inflateEnd(&stream);
    if (consumed == 0 || consumed > quint64(std::numeric_limits<qsizetype>::max())) {
        error = QObject::tr("Некорректная длина сжатой записи Contents.");
        return false;
    }
    record.offset = at;
    record.compressedSize = qsizetype(consumed);
    record.decoded = std::move(decoded);
    return true;
}

} // namespace

bool decodeKompasContentsRecords(const QByteArray& contents,
                                 KompasContentsRecords& result,
                                 QString& error) {
    result = {};
    error.clear();
    if (contents.size() > kMaxContentsBytes) {
        error = QObject::tr("Раздел Contents модели КОМПАС-3D слишком велик.");
        return false;
    }
    if (!contents.startsWith("KF")) {
        error = QObject::tr("Раздел Contents модели КОМПАС-3D не имеет заголовка KF.");
        return false;
    }

    qsizetype at = 2;
    while (isZlibHeader(contents, at)) {
        if (result.records.size() == kMaxRecords) {
            error = QObject::tr("Слишком много записей в разделе Contents.");
            result = {};
            return false;
        }
        KompasContentsRecord record;
        if (!inflateRecord(contents, at, result.decodedBytes, record, error)) {
            result = {};
            return false;
        }
        at += record.compressedSize;
        result.decodedBytes += quint64(record.decoded.size());
        result.records.push_back(std::move(record));
    }
    if (result.records.empty()) {
        error = QObject::tr("В разделе Contents отсутствуют сжатые записи.");
        result = {};
        return false;
    }
    result.tailOffset = at;
    result.tail = contents.mid(at);
    return true;
}

bool readKompasCylindricalFaces(const KompasContentsRecords& contents,
                               std::vector<KompasCylindricalFace>& faces,
                               QString& error) {
    faces.clear();
    error.clear();
    const auto nodes = readNodeGraph(contents);
    constexpr double turn = 6.28318530717958647692;
    for (const C3dNode& surface : nodes) {
        // 0x145d stores the cylinder's bounding box, frame, radius and
        // axial length. 0x666e references that surface; 0x110f references
        // the corresponding native face. 0x0b04 stores endpoint points.
        if (surface.type != 0x145d || surface.bytes.size() != 324) continue;
        const QByteArray& bytes = surface.bytes;
        const auto minimum = readPoint(bytes, 7);
        const auto maximum = readPoint(bytes, 31);
        const auto origin = readPoint(bytes, 55);
        const auto radial = readPoint(bytes, 79);
        const auto tangent = readPoint(bytes, 103);
        const auto axis = readPoint(bytes, 127);
        const double radius = littleDouble(bytes, 151);
        const double length = littleDouble(bytes, 159);
        if (!std::isfinite(radius) || !std::isfinite(length) ||
            radius <= 0 || length <= 0 ||
            !near(littleDouble(bytes, 167), 0) ||
            !near(littleDouble(bytes, 175), turn) ||
            !near(littleDouble(bytes, 183), 0) ||
            !near(littleDouble(bytes, 191), 1)) continue;

        // This format variant serializes a right-handed cylinder frame and
        // two endpoint planes. Limit construction to the unambiguous +X
        // full-cylinder case found in the supplied KOMPAS sample.
        if (!nearPoint(axis, {1, 0, 0}) ||
            !nearPoint(radial, {0, 1, 0}) ||
            !nearPoint(tangent, {0, 0, 1}) ||
            !nearPoint(minimum, {origin[0], origin[1] - radius,
                                 origin[2] - radius}) ||
            !nearPoint(maximum, {origin[0] + length,
                                 origin[1] + radius,
                                 origin[2] + radius})) continue;

        const std::array<double, 3> start{
            origin[0], origin[1] + radius, origin[2]};
        const std::array<double, 3> end{
            origin[0] + length, origin[1] + radius, origin[2]};
        if (!hasEndpointPoints(nodes, start, end)) continue;

        quint16 wrapperId = 0;
        for (const C3dNode& wrapper : nodes) {
            if (wrapper.type != 0x666e ||
                !containsNodeReference(wrapper.bytes, surface.id, 23)) continue;
            if (wrapperId != 0) { wrapperId = 0; break; }
            wrapperId = wrapper.id;
        }
        if (wrapperId == 0) continue;
        quint16 faceId = 0;
        for (const C3dNode& face : nodes) {
            if (face.type != 0x110f || face.bytes.size() < 26 ||
                quint8(face.bytes[23]) != 1 ||
                littleU16(face.bytes, 24) != wrapperId) continue;
            if (faceId != 0) { faceId = 0; break; }
            faceId = face.id;
        }
        if (faceId == 0) continue;
        faces.push_back({surface.id, faceId, origin, axis, radial,
                         radius, length});
    }
    std::sort(faces.begin(), faces.end(),
              [](const auto& a, const auto& b) {
                  return a.surfaceNodeId < b.surfaceNodeId;
              });
    if (faces.empty()) {
        error = QObject::tr("В Contents не найдены цилиндрические грани с "
                            "проверенными граничными точками и ссылками.");
        return false;
    }
    return true;
}

bool readKompasCylindricalFacesFromFile(
    const QString& path, std::vector<KompasCylindricalFace>& faces, QString& error) {
    faces.clear();
    QByteArray contents;
    if (!readKompasContents(path, contents, error)) return false;
    KompasContentsRecords records;
    if (!decodeKompasContentsRecords(contents, records, error)) return false;
    return readKompasCylindricalFaces(records, faces, error);
}

#ifdef CADNEXT_WITH_OCCT
bool makeKompasCylindricalFaces(const std::vector<KompasCylindricalFace>& faces,
                               kernel::OcctKernel& kernel,
                               std::vector<kernel::ShapeHandle>& shapes,
                               QString& error) {
    shapes.clear();
    error.clear();
    if (faces.empty()) {
        error = QObject::tr("Нет проверенных цилиндрических граней КОМПАС-3D.");
        return false;
    }
    try {
        for (const auto& face : faces) {
            const gp_Ax3 frame(
                gp_Pnt(face.origin[0], face.origin[1], face.origin[2]),
                gp_Dir(face.axis[0], face.axis[1], face.axis[2]),
                gp_Dir(face.radialDirection[0], face.radialDirection[1],
                       face.radialDirection[2]));
            const gp_Cylinder cylinder(frame, face.radius);
            BRepBuilderAPI_MakeFace maker(cylinder, 0,
                6.28318530717958647692, 0, face.length);
            if (!maker.IsDone() || maker.Face().IsNull() ||
                !BRepCheck_Analyzer(maker.Face()).IsValid()) {
                error = QObject::tr("Не удалось собрать цилиндрическую грань %1.")
                            .arg(face.faceNodeId);
                shapes.clear();
                return false;
            }
            shapes.push_back(kernel.adoptShape(maker.Face(), "kompas-cylinder-face"));
        }
    } catch (const Standard_Failure& failure) {
        error = QObject::tr("Ошибка OCCT при сборке граней КОМПАС-3D: %1")
                    .arg(QString::fromUtf8(failure.GetMessageString()));
        shapes.clear();
        return false;
    }
    return true;
}
#endif

} // namespace cadnext::gui
