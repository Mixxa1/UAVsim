#include "cadnext/gui/NativeDxfImport.hpp"
#include "cadnext/Units.hpp"

#include <QFile>
#include <QList>
#include <QObject>
#include <QSet>
#include <QSaveFile>
#include <QStringList>

#include <cmath>
#include <bit>
#include <limits>

namespace cadnext::gui {
namespace {

constexpr qint64 kMaxDxfBytes = 256ll * 1024 * 1024; // exact procedural 3DSOLID exports exceed 64 MiB

struct Group {
    int code = 0;
    QByteArray value;
};

enum class BinaryType { String, Double, Int16, Int32, Int64, Boolean, Chunk, Unknown };

BinaryType binaryType(int code) {
    if (code == 1004 || (code >= 310 && code <= 319)) return BinaryType::Chunk;
    if ((code >= 0 && code <= 9) || (code >= 100 && code <= 105) ||
        (code >= 300 && code <= 309) || (code >= 320 && code <= 369) ||
        (code >= 390 && code <= 399) || (code >= 410 && code <= 419) ||
        (code >= 430 && code <= 439) || (code >= 470 && code <= 481) ||
        code == 999 || (code >= 1000 && code <= 1009)) return BinaryType::String;
    if ((code >= 10 && code <= 59) || (code >= 110 && code <= 149) ||
        (code >= 210 && code <= 239) || (code >= 460 && code <= 469) ||
        (code >= 1010 && code <= 1059)) return BinaryType::Double;
    if ((code >= 60 && code <= 79) || (code >= 170 && code <= 179) ||
        (code >= 270 && code <= 289) || (code >= 370 && code <= 389) ||
        (code >= 400 && code <= 409) || (code >= 1060 && code <= 1070))
        return BinaryType::Int16;
    if ((code >= 90 && code <= 99) || (code >= 420 && code <= 429) ||
        (code >= 440 && code <= 459) || code == 1071) return BinaryType::Int32;
    if (code >= 160 && code <= 169) return BinaryType::Int64;
    if (code >= 290 && code <= 299) return BinaryType::Boolean;
    return BinaryType::Unknown;
}

bool readBinaryGroups(const QByteArray& bytes, std::vector<Group>& groups,
                      QString& error) {
    constexpr qsizetype sentinelSize = 22;
    if (bytes.size() < sentinelSize ||
        bytes.left(sentinelSize) != QByteArray("AutoCAD Binary DXF\r\n\x1a\0", 22)) {
        error = QObject::tr("Некорректный заголовок бинарного DXF.");
        return false;
    }
    qsizetype at = sentinelSize;
    const auto integer = [&](int size, quint64& value) -> bool {
        if (size > bytes.size() - at) return false;
        value = 0;
        for (int i = 0; i < size; ++i)
            value |= quint64(static_cast<unsigned char>(bytes[at + i])) << (8 * i);
        at += size;
        return true;
    };
    while (at < bytes.size()) {
        quint64 rawCode = 0;
        if (!integer(2, rawCode) || rawCode > 1071) {
            error = QObject::tr("Некорректный групповой код бинарного DXF.");
            return false;
        }
        const int code = int(rawCode);
        const BinaryType type = binaryType(code);
        QByteArray value;
        if (type == BinaryType::String) {
            const qsizetype end = bytes.indexOf('\0', at);
            if (end < at || end - at > 2049) {
                error = QObject::tr("Некорректная строка бинарного DXF.");
                return false;
            }
            value = bytes.mid(at, end - at);
            at = end + 1;
        } else if (type == BinaryType::Chunk) {
            quint64 size = 0;
            if (!integer(1, size) || size > quint64(bytes.size() - at)) {
                error = QObject::tr("Повреждён двоичный блок DXF.");
                return false;
            }
            value = bytes.mid(at, qsizetype(size)).toHex();
            at += qsizetype(size);
        } else if (type == BinaryType::Unknown) {
            error = QObject::tr("Неизвестный групповой код бинарного DXF %1.").arg(code);
            return false;
        } else {
            const int width = type == BinaryType::Boolean ? 1 :
                type == BinaryType::Int16 ? 2 : type == BinaryType::Int32 ? 4 : 8;
            quint64 raw = 0;
            if (!integer(width, raw)) {
                error = QObject::tr("Обрезано числовое поле бинарного DXF %1.").arg(code);
                return false;
            }
            if (type == BinaryType::Double) {
                const double number = std::bit_cast<double>(raw);
                if (!std::isfinite(number)) {
                    error = QObject::tr("Неконечное число в бинарном DXF %1.").arg(code);
                    return false;
                }
                value = QByteArray::number(number, 'g', 17);
            } else if (type == BinaryType::Int16) {
                value = QByteArray::number(std::bit_cast<qint16>(quint16(raw)));
            } else if (type == BinaryType::Int32) {
                value = QByteArray::number(std::bit_cast<qint32>(quint32(raw)));
            } else if (type == BinaryType::Int64) {
                value = QByteArray::number(std::bit_cast<qint64>(raw));
            } else {
                value = QByteArray::number(raw);
            }
        }
        groups.push_back({code, std::move(value)});
    }
    return true;
}

bool encodeBinaryGroups(const QByteArray& ascii, QByteArray& binary,
                        QString& error) {
    binary = QByteArray("AutoCAD Binary DXF\r\n\x1a\0", 22);
    QList<QByteArray> lines = ascii.split('\n');
    if (!lines.empty() && lines.back().isEmpty()) lines.removeLast();
    if (lines.size() % 2 != 0) return false;
    const auto appendInteger = [&](quint64 value, int width) {
        for (int i = 0; i < width; ++i)
            binary.append(char((value >> (8 * i)) & 255));
    };
    for (qsizetype i = 0; i < lines.size(); i += 2) {
        bool ok = false;
        const int code = lines[i].toInt(&ok);
        if (!ok || code < 0 || code > 1071) return false;
        appendInteger(quint16(code), 2);
        const BinaryType type = binaryType(code);
        const QByteArray& value = lines[i + 1];
        if (type == BinaryType::String) {
            binary.append(value);
            binary.append('\0');
        } else if (type == BinaryType::Double) {
            const double number = value.toDouble(&ok);
            if (!ok || !std::isfinite(number)) return false;
            appendInteger(std::bit_cast<quint64>(number), 8);
        } else if (type == BinaryType::Int16 || type == BinaryType::Int32 ||
                   type == BinaryType::Int64 || type == BinaryType::Boolean) {
            const qint64 number = value.toLongLong(&ok);
            if (!ok) return false;
            appendInteger(quint64(number), type == BinaryType::Boolean ? 1 :
                          type == BinaryType::Int16 ? 2 :
                          type == BinaryType::Int32 ? 4 : 8);
        } else {
            error = QObject::tr("Невозможно записать групповой код бинарного DXF %1.")
                        .arg(code);
            return false;
        }
    }
    return true;
}

bool parseNumber(const QByteArray& raw, double& value) {
    bool ok = false;
    value = QString::fromLatin1(raw.trimmed()).toDouble(&ok);
    return ok && std::isfinite(value);
}

bool fieldNumber(const std::vector<Group>& fields, int code, double& value,
                 bool required, QString& error) {
    bool found = false;
    for (const Group& field : fields) {
        if (field.code != code) continue;
        if (!parseNumber(field.value, value)) {
            error = QObject::tr("Некорректное числовое поле DXF %1.").arg(code);
            return false;
        }
        found = true;
    }
    if (required && !found) {
        error = QObject::tr("Отсутствует поле DXF %1.").arg(code);
        return false;
    }
    return true;
}

bool integerField(const std::vector<Group>& fields, int code, int& value,
                  QString& error) {
    for (const Group& field : fields) {
        if (field.code != code) continue;
        bool ok = false;
        value = QString::fromLatin1(field.value.trimmed()).toInt(&ok);
        if (!ok) {
            error = QObject::tr("Некорректное целое поле DXF %1.").arg(code);
            return false;
        }
    }
    return true;
}

bool planarEntity(const std::vector<Group>& fields, bool line, QString& error) {
    double z = 0.0;
    if (!fieldNumber(fields, 30, z, false, error) || std::fabs(z) > 1e-9) {
        if (error.isEmpty()) error = QObject::tr("DXF содержит геометрию вне плоскости XY.");
        return false;
    }
    if (line && (!fieldNumber(fields, 31, z, false, error) || std::fabs(z) > 1e-9)) {
        if (error.isEmpty()) error = QObject::tr("DXF содержит геометрию вне плоскости XY.");
        return false;
    }
    double thickness = 0.0;
    if (!fieldNumber(fields, 39, thickness, false, error) ||
        std::fabs(thickness) > 1e-9) {
        if (error.isEmpty()) error = QObject::tr("Толстые объекты DXF пока не поддерживаются.");
        return false;
    }
    double nx = 0.0, ny = 0.0, nz = 1.0;
    if (!fieldNumber(fields, 210, nx, false, error) ||
        !fieldNumber(fields, 220, ny, false, error) ||
        !fieldNumber(fields, 230, nz, false, error)) return false;
    if (std::fabs(nx) > 1e-9 || std::fabs(ny) > 1e-9 ||
        std::fabs(nz - 1.0) > 1e-9) {
        error = QObject::tr("Объект DXF использует наклонную систему координат.");
        return false;
    }
    int paperSpace = 0;
    if (!integerField(fields, 67, paperSpace, error)) return false;
    if (paperSpace != 0) {
        error = QObject::tr("Объект DXF расположен в пространстве листа.");
        return false;
    }
    return true;
}

bool parseLine(const std::vector<Group>& fields, DxfSketchData& data, QString& error) {
    if (!planarEntity(fields, true, error)) return false;
    SketchEntity entity;
    entity.type = SketchEntityType::Line;
    if (!fieldNumber(fields, 10, entity.line.start.u, true, error) ||
        !fieldNumber(fields, 20, entity.line.start.v, true, error) ||
        !fieldNumber(fields, 11, entity.line.end.u, true, error) ||
        !fieldNumber(fields, 21, entity.line.end.v, true, error)) return false;
    if (std::hypot(entity.line.end.u - entity.line.start.u,
                   entity.line.end.v - entity.line.start.v) <= 1e-12) {
        error = QObject::tr("DXF содержит отрезок нулевой длины.");
        return false;
    }
    data.entities.push_back(std::move(entity));
    return true;
}

bool parseCircle(const std::vector<Group>& fields, DxfSketchData& data, QString& error) {
    if (!planarEntity(fields, false, error)) return false;
    SketchEntity entity;
    entity.type = SketchEntityType::Circle;
    if (!fieldNumber(fields, 10, entity.circle.center.u, true, error) ||
        !fieldNumber(fields, 20, entity.circle.center.v, true, error) ||
        !fieldNumber(fields, 40, entity.circle.radius, true, error)) return false;
    if (entity.circle.radius <= 0.0) {
        error = QObject::tr("DXF содержит окружность с неположительным радиусом.");
        return false;
    }
    data.entities.push_back(std::move(entity));
    return true;
}

double normalizedDegrees(double angle) {
    angle = std::fmod(angle, 360.0);
    return angle < 0.0 ? angle + 360.0 : angle;
}

bool parseArc(const std::vector<Group>& fields, DxfSketchData& data, QString& error) {
    if (!planarEntity(fields, false, error)) return false;
    SketchEntity entity;
    entity.type = SketchEntityType::Arc;
    double endAngle = 0.0;
    if (!fieldNumber(fields, 10, entity.arc.center.u, true, error) ||
        !fieldNumber(fields, 20, entity.arc.center.v, true, error) ||
        !fieldNumber(fields, 40, entity.arc.radius, true, error) ||
        !fieldNumber(fields, 50, entity.arc.startAngleDegrees, true, error) ||
        !fieldNumber(fields, 51, endAngle, true, error)) return false;
    const double sweep = normalizedDegrees(endAngle - entity.arc.startAngleDegrees);
    if (entity.arc.radius <= 0.0 || !std::isfinite(sweep) ||
        sweep <= 0.0 || sweep >= 360.0) {
        error = QObject::tr("DXF содержит дугу с некорректным радиусом или углами.");
        return false;
    }
    entity.arc.startAngleDegrees = normalizedDegrees(entity.arc.startAngleDegrees);
    entity.arc.sweepDegrees = sweep;
    data.entities.push_back(std::move(entity));
    return true;
}

bool arcFromBulge(SketchPoint2D a, SketchPoint2D b, double bulge,
                  SketchArc& arc) {
    constexpr double degreesPerRadian = 180.0 / 3.14159265358979323846;
    const double dx = b.u - a.u, dy = b.v - a.v;
    const double chord = std::hypot(dx, dy);
    const double sweep = std::fabs(4.0 * std::atan(bulge)) * degreesPerRadian;
    const double offset = chord * (1.0 - bulge * bulge) / (4.0 * bulge);
    arc.center = {(a.u + b.u) / 2.0 - dy / chord * offset,
                  (a.v + b.v) / 2.0 + dx / chord * offset};
    arc.radius = chord * (1.0 + bulge * bulge) / (4.0 * std::fabs(bulge));
    const SketchPoint2D start = bulge > 0.0 ? a : b;
    arc.startAngleDegrees = normalizedDegrees(
        std::atan2(start.v - arc.center.v, start.u - arc.center.u) *
        degreesPerRadian);
    arc.sweepDegrees = sweep;
    return std::isfinite(arc.center.u) && std::isfinite(arc.center.v) &&
           std::isfinite(arc.radius) && arc.radius > 0.0 &&
           std::isfinite(sweep) && sweep > 0.0 && sweep < 360.0;
}

bool parsePolyline(const std::vector<Group>& fields, DxfSketchData& data,
                   QString& error) {
    if (!planarEntity(fields, false, error)) return false;
    double elevation = 0.0;
    if (!fieldNumber(fields, 38, elevation, false, error) ||
        std::fabs(elevation) > 1e-9) {
        if (error.isEmpty()) error = QObject::tr("Полилиния DXF находится вне плоскости XY.");
        return false;
    }
    // A wide polyline is a filled shape; importing its centreline would
    // silently change the geometry.
    for (const Group& field : fields) {
        if (field.code != 40 && field.code != 41 && field.code != 43) continue;
        double width = 0.0;
        if (!parseNumber(field.value, width)) {
            error = QObject::tr("Некорректная ширина полилинии DXF.");
            return false;
        }
        if (width != 0.0) {
            error = QObject::tr("Полилиния DXF имеет ширину; точный импорт ширины пока не реализован.");
            return false;
        }
    }
    struct Vertex {
        double x = std::numeric_limits<double>::quiet_NaN();
        double y = std::numeric_limits<double>::quiet_NaN();
        double bulge = 0.0;
    };
    std::vector<Vertex> vertices;
    for (const Group& field : fields) {
        if (field.code == 10) {
            Vertex vertex;
            if (!parseNumber(field.value, vertex.x)) {
                error = QObject::tr("Некорректная вершина полилинии DXF.");
                return false;
            }
            vertices.push_back(vertex);
        } else if (field.code == 20 || field.code == 42) {
            if (vertices.empty()) {
                error = QObject::tr("Нарушен порядок вершин полилинии DXF.");
                return false;
            }
            double number = 0.0;
            if (!parseNumber(field.value, number)) {
                error = QObject::tr("Некорректная вершина полилинии DXF.");
                return false;
            }
            if (field.code == 20) vertices.back().y = number;
            else vertices.back().bulge = number;
        }
    }
    int declaredCount = -1, flags = 0;
    if (!integerField(fields, 90, declaredCount, error) ||
        !integerField(fields, 70, flags, error)) return false;
    if (vertices.size() < 2 ||
        (declaredCount >= 0 && declaredCount != static_cast<int>(vertices.size()))) {
        error = QObject::tr("Некорректное число вершин полилинии DXF.");
        return false;
    }
    for (const Vertex& vertex : vertices) {
        if (!std::isfinite(vertex.y)) {
            error = QObject::tr("У вершины полилинии DXF отсутствует координата Y.");
            return false;
        }
    }
    const std::size_t segmentCount = vertices.size() - 1 + ((flags & 1) ? 1 : 0);
    for (std::size_t i = 0; i < segmentCount; ++i) {
        const Vertex& a = vertices[i];
        const Vertex& b = vertices[(i + 1) % vertices.size()];
        if (std::hypot(b.x - a.x, b.y - a.y) <= 1e-12) {
            error = QObject::tr("Полилиния DXF содержит отрезок нулевой длины.");
            return false;
        }
        SketchEntity entity;
        if (a.bulge == 0.0) {
            entity.type = SketchEntityType::Line;
            entity.line.start = {a.x, a.y};
            entity.line.end = {b.x, b.y};
        } else {
            entity.type = SketchEntityType::Arc;
            if (!arcFromBulge({a.x, a.y}, {b.x, b.y}, a.bulge, entity.arc)) {
                error = QObject::tr("Полилиния DXF содержит некорректную дугу.");
                return false;
            }
        }
        data.entities.push_back(std::move(entity));
    }
    return true;
}

double millimetersPerUnit(int code) {
    switch (code) {
    case 0: case 4: return 1.0;
    case 1: return 25.4;
    case 2: return 304.8;
    case 3: return 1609344.0;
    case 5: return 10.0;
    case 6: return 1000.0;
    case 7: return 1000000.0;
    case 8: return 0.0000254;
    case 9: return 0.0254;
    case 10: return 914.4;
    case 11: return 0.0000001;
    case 12: return 0.000001;
    case 13: return 0.001;
    case 14: return 100.0;
    case 15: return 10000.0;
    case 16: return 100000.0;
    case 17: return 1.0e12;
    case 18: return 149597870700000.0; // IAU astronomical unit.
    case 19: return 9.4607304725808e18; // Julian light year.
    case 20: return 3.085677581491367e19; // One arcsecond at one AU.
    case 21: return 1200000.0 / 3937.0; // US survey foot.
    case 22: return 100000.0 / 3937.0;
    case 23: return 3600000.0 / 3937.0;
    case 24: return 6336000000.0 / 3937.0;
    default: return 0.0;
    }
}

} // namespace

bool readDxfGroups(const QString& path, std::vector<DxfGroup>& groups, QString& error) {
    groups.clear();
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || file.size() > kMaxDxfBytes) {
        error = QObject::tr("Не удалось открыть DXF или файл слишком велик.");
        return false;
    }
    QByteArray bytes = file.readAll();
    if (bytes.startsWith("AutoCAD Binary DXF")) {
        std::vector<Group> binary;
        if (!readBinaryGroups(bytes, binary, error)) return false;
        groups.reserve(binary.size());
        for (Group& group : binary) groups.push_back({group.code, std::move(group.value)});
        return true;
    }
    if (bytes.startsWith(QByteArray::fromHex("efbbbf"))) bytes.remove(0, 3);
    QList<QByteArray> lines = bytes.split('\n');
    if (!lines.empty() && lines.back().trimmed().isEmpty()) lines.removeLast();
    if (lines.size() < 4 || lines.size() % 2 != 0) {
        error = QObject::tr("Нарушена структура пар код/значение в DXF.");
        return false;
    }
    groups.reserve(lines.size() / 2);
    for (qsizetype i = 0; i < lines.size(); i += 2) {
        bool ok = false;
        const int code = QString::fromLatin1(lines[i].trimmed()).toInt(&ok);
        if (!ok || code < 0 || code > 1071) {
            error = QObject::tr("Некорректный групповой код DXF в строке %1.").arg(i + 1);
            return false;
        }
        QByteArray value = lines[i + 1];
        if (value.endsWith('\r')) value.chop(1);
        groups.push_back({code, std::move(value)});
    }
    return true;
}

bool readDxfSketch(const QString& path, DxfSketchData& data, QString& error) {
    data = {};
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly) || file.size() > kMaxDxfBytes) {
        error = QObject::tr("Не удалось открыть DXF или файл слишком велик.");
        return false;
    }
    QByteArray bytes = file.readAll();
    std::vector<Group> groups;
    if (bytes.startsWith("AutoCAD Binary DXF")) {
        if (!readBinaryGroups(bytes, groups, error)) return false;
    } else {
        if (bytes.startsWith(QByteArray::fromHex("efbbbf"))) bytes.remove(0, 3);
        QList<QByteArray> lines = bytes.split('\n');
        if (!lines.empty() && lines.back().trimmed().isEmpty()) lines.removeLast();
        if (lines.size() < 4 || lines.size() % 2 != 0) {
            error = QObject::tr("Нарушена структура пар код/значение в DXF.");
            return false;
        }
        groups.reserve(lines.size() / 2);
        for (qsizetype i = 0; i < lines.size(); i += 2) {
            bool ok = false;
            const int code = QString::fromLatin1(lines[i].trimmed()).toInt(&ok);
            if (!ok || code < 0 || code > 1071) {
                error = QObject::tr("Некорректный групповой код DXF в строке %1.").arg(i + 1);
                return false;
            }
            groups.push_back({code, lines[i + 1].trimmed()});
        }
    }
    QString section;
    QSet<QString> unsupported;
    bool eof = false;
    for (std::size_t i = 0; i < groups.size();) {
        const Group& group = groups[i];
        if (group.code == 0 && group.value == "SECTION") {
            if (i + 1 >= groups.size() || groups[i + 1].code != 2) {
                error = QObject::tr("В DXF отсутствует имя секции.");
                return false;
            }
            section = QString::fromLatin1(groups[i + 1].value);
            i += 2;
        } else if (group.code == 0 && group.value == "ENDSEC") {
            section.clear();
            ++i;
        } else if (group.code == 0 && group.value == "EOF") {
            eof = true;
            break;
        } else if (section == QLatin1String("HEADER") && group.code == 9 &&
                   group.value == "$INSUNITS") {
            ++i;
            while (i < groups.size() && groups[i].code != 9 && groups[i].code != 0) {
                if (groups[i].code == 70) {
                    bool ok = false;
                    data.drawingUnits = QString::fromLatin1(groups[i].value).toInt(&ok);
                    if (!ok) {
                        error = QObject::tr("Некорректные единицы измерения DXF.");
                        return false;
                    }
                }
                ++i;
            }
        } else if (section == QLatin1String("ENTITIES") && group.code == 0) {
            const QString type = QString::fromLatin1(group.value);
            std::vector<Group> fields;
            ++i;
            while (i < groups.size() && groups[i].code != 0) fields.push_back(groups[i++]);
            bool accepted = true;
            if (type == QLatin1String("LINE")) accepted = parseLine(fields, data, error);
            else if (type == QLatin1String("CIRCLE")) accepted = parseCircle(fields, data, error);
            else if (type == QLatin1String("ARC")) accepted = parseArc(fields, data, error);
            else if (type == QLatin1String("LWPOLYLINE")) {
                accepted = parsePolyline(fields, data, error);
            } else {
                unsupported.insert(type);
            }
            if (!accepted) return false;
        } else {
            ++i;
        }
    }
    if (!unsupported.empty()) {
        QStringList types = unsupported.values();
        types.sort();
        error = QObject::tr("DXF содержит пока неподдерживаемые объекты: %1.")
                    .arg(types.join(QStringLiteral(", ")));
        return false;
    }
    if (!eof || data.entities.empty()) {
        error = QObject::tr("В DXF не найдена готовая геометрия эскиза или нет маркера EOF.");
        return false;
    }
    const double millimeters = millimetersPerUnit(data.drawingUnits);
    if (millimeters == 0.0) {
        error = QObject::tr("Единицы измерения DXF %1 пока не поддерживаются.")
                    .arg(data.drawingUnits);
        return false;
    }
    const double factor = millimeters / kMillimetersPerModelUnit;
    data.assumedMillimeters = data.drawingUnits == 0;
    const auto finitePoint = [](const SketchPoint2D& point) {
        return std::isfinite(point.u) && std::isfinite(point.v);
    };
    for (SketchEntity& entity : data.entities) {
        if (entity.type == SketchEntityType::Line) {
            entity.line.start.u *= factor;
            entity.line.start.v *= factor;
            entity.line.end.u *= factor;
            entity.line.end.v *= factor;
            if (!finitePoint(entity.line.start) || !finitePoint(entity.line.end)) {
                error = QObject::tr("Масштаб DXF переполняет диапазон координат.");
                return false;
            }
        } else if (entity.type == SketchEntityType::Circle) {
            entity.circle.center.u *= factor;
            entity.circle.center.v *= factor;
            entity.circle.radius *= factor;
            if (!finitePoint(entity.circle.center) ||
                !std::isfinite(entity.circle.radius)) {
                error = QObject::tr("Масштаб DXF переполняет диапазон координат.");
                return false;
            }
        } else if (entity.type == SketchEntityType::Arc) {
            entity.arc.center.u *= factor;
            entity.arc.center.v *= factor;
            entity.arc.radius *= factor;
            if (!finitePoint(entity.arc.center) || !std::isfinite(entity.arc.radius)) {
                error = QObject::tr("Масштаб DXF переполняет диапазон координат.");
                return false;
            }
        }
    }
    return true;
}

bool writeDxfSketch(const QString& path, const Sketch& sketch, QString& error,
                    bool binary) {
    if (sketch.entities.empty()) {
        error = QObject::tr("Эскиз не содержит объектов для экспорта DXF.");
        return false;
    }
    QByteArray bytes("0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\nAC1015\n"
                     "9\n$INSUNITS\n70\n4\n0\nENDSEC\n"
                     "0\nSECTION\n2\nENTITIES\n");
    const auto number = [](double value) { return QByteArray::number(value, 'g', 17); };
    const auto length = [&number](double value) {
        return number(value * kMillimetersPerModelUnit);
    };
    const auto line = [&bytes, &length](SketchPoint2D a, SketchPoint2D b) {
        bytes += "0\nLINE\n8\n0\n10\n" + length(a.u) + "\n20\n" + length(a.v) +
                 "\n30\n0\n11\n" + length(b.u) + "\n21\n" + length(b.v) +
                 "\n31\n0\n";
    };
    for (const SketchEntity& entity : sketch.entities) {
        if (entity.type == SketchEntityType::Line) {
            const auto& a = entity.line.start;
            const auto& b = entity.line.end;
            if (!std::isfinite(a.u) || !std::isfinite(a.v) ||
                !std::isfinite(b.u) || !std::isfinite(b.v)) {
                error = QObject::tr("Эскиз содержит некорректные координаты отрезка.");
                return false;
            }
            line(a, b);
        } else if (entity.type == SketchEntityType::Rectangle) {
            const auto& r = entity.rectangle;
            if (!std::isfinite(r.origin.u) || !std::isfinite(r.origin.v) ||
                !std::isfinite(r.width) || !std::isfinite(r.height) ||
                r.width <= 0.0 || r.height <= 0.0) {
                error = QObject::tr("Эскиз содержит некорректный прямоугольник.");
                return false;
            }
            const SketchPoint2D a = r.origin;
            const SketchPoint2D b{a.u + r.width, a.v};
            const SketchPoint2D c{a.u + r.width, a.v + r.height};
            const SketchPoint2D d{a.u, a.v + r.height};
            line(a, b); line(b, c); line(c, d); line(d, a);
        } else if (entity.type == SketchEntityType::Circle) {
            const auto& c = entity.circle;
            if (!std::isfinite(c.center.u) || !std::isfinite(c.center.v) ||
                !std::isfinite(c.radius) || c.radius <= 0.0) {
                error = QObject::tr("Эскиз содержит некорректную окружность.");
                return false;
            }
            bytes += "0\nCIRCLE\n8\n0\n10\n" + length(c.center.u) +
                     "\n20\n" + length(c.center.v) + "\n30\n0\n40\n" +
                     length(c.radius) + "\n";
        } else if (entity.type == SketchEntityType::Arc) {
            const auto& a = entity.arc;
            if (!std::isfinite(a.center.u) || !std::isfinite(a.center.v) ||
                !std::isfinite(a.radius) || a.radius <= 0.0 ||
                !std::isfinite(a.startAngleDegrees) ||
                !std::isfinite(a.sweepDegrees) || a.sweepDegrees <= 0.0 ||
                a.sweepDegrees >= 360.0) {
                error = QObject::tr("Эскиз содержит некорректную дугу.");
                return false;
            }
            bytes += "0\nARC\n8\n0\n10\n" + length(a.center.u) +
                     "\n20\n" + length(a.center.v) + "\n30\n0\n40\n" +
                     length(a.radius) + "\n50\n" +
                     number(normalizedDegrees(a.startAngleDegrees)) +
                     "\n51\n" + number(normalizedDegrees(a.startAngleDegrees +
                                                        a.sweepDegrees)) + "\n";
        } else {
            error = QObject::tr("Эскиз содержит неподдерживаемый тип объекта.");
            return false;
        }
    }
    bytes += "0\nENDSEC\n0\nEOF\n";
    if (binary) {
        QByteArray encoded;
        if (!encodeBinaryGroups(bytes, encoded, error)) {
            if (error.isEmpty())
                error = QObject::tr("Не удалось закодировать бинарный DXF.");
            return false;
        }
        bytes = std::move(encoded);
    }
    QSaveFile file(path);
    if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() ||
        !file.commit()) {
        error = QObject::tr("Не удалось записать файл DXF.");
        return false;
    }
    return true;
}

} // namespace cadnext::gui
