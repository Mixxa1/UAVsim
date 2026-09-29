// DWG objects of AutoCAD 2013–2018 (AC1032) and the plane geometry of DWG models as a sketch
// (NativeDwgObjects), against what the files say of themselves and against geometry worked by hand.
//
// Criteria, fixed before the first run of this test:
//   - The AC1032 sample (AutoCAD 2025, every kind of object): for every class the file lists, as many
//     objects decoded of that class as its class table says it holds (the table and the objects are
//     separate parts of the file). Corrected after the first run: the table counts the objects of a class
//     created in the drawing's history, so where some were erased (two table classes: 5 created, 2 in
//     the file — its handles run to 0xE63 for 842 objects) the file holds fewer, never more; and objects
//     with a fixed type (LAYOUT, PLACEHOLDER) are counted by their name, not by the class number.
//   - Plane entities (LINE, CIRCLE, ARC, ELLIPSE, LWPOLYLINE), inserts and block headers: each one's data
//     ends exactly where the file says (the string stream's start, AC1032; the handles', R2000) — in the
//     AC1032 sample and in the 11 R2000 drawings. None misread.
//   - Every entity inside a block names a block header as its owner, and each block header's own count
//     of entities is the number that name it (block and end-of-block markers aside). Corrected after the
//     first run: attributes, vertices and sequence ends belong to their INSERT or POLYLINE, and the
//     model's and the active layout's entities say their space by mode (2, 1) instead of naming one.
//   - The header: INSUNITS 1 (inches — AutoCAD's imperial limits 12 × 9 in the same file); every sketch
//     entity inside the model extents it records (EXTMIN/EXTMAX), 1e-9 of their size aside.
//   - Placement by hand: MyBlock (two diagonals ±40 and a circle of radius 30 about its base) inserted in
//     model space scaled — its lines and circle in the sketch where insertion + scale·(p − base) puts
//     them, in metres, to 1e-12 m.
//   - A polyline's segments chain: each ends where the next begins, bulge arcs included, to 1e-12 m.
//   - Solids of AC1032 (binary ACIS, SAB, in the data store by their handles): walked here tag by tag,
//     independently of the reader, each record ends with End-of-…-data exactly at the length the store
//     gives it. The two 3DSOLIDs build (the REGION is refused as a sheet): valid, as many faces as their
//     SAB "face" records, every SAB point — moved by its body's transform — on the solid's boundary
//     within 10 · resabs, the solid's box that of those points (their faces are planes: the extreme
//     points are vertices) to 1e-9 of its size; the first, of 6 faces, a box: its volume that of its box.
//   - Conversion worked by hand (a model of one entity, no file): an arc 0–90° of radius 1 stays so; the
//     same mirrored x → −x, or in the object frame of extrusion (0, 0, −1), becomes 90–180°; turned 90°
//     by an insert, 90–180°; a circle scaled (2, 1) is left out as an ellipse; a polyline edge of bulge 1
//     is a half circle about the edge's middle.
#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepGProp.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <TopExp_Explorer.hxx>
#include <gp_Pnt.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>

using namespace cadnext;
using namespace cadnext::gui;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

constexpr double kInch = 25.4e-3;

// A model of one plane entity under `placement`, in a millimetre a unit, as sketch entities.
std::vector<SketchEntity> convert(const DwgPlanar& entity, const std::array<double, 16>& placement, std::map<QString, int>& left) {
    DwgModel model;
    model.planar.push_back({entity, 1.0, placement});
    std::vector<SketchEntity> out;
    dwgSketchEntities(model, out, left);
    return out;
}

bool near(double a, double b, double tolerance) { return std::fabs(a - b) <= tolerance; }

// A SAB walked tag by tag: whether it ends with its End-of-…-data marker at its last byte, its face
// records, its points and its body's transform (rows, translation, scale).
struct Sab {
    bool ends = false;
    int faces = 0;
    double millimetres = 0, resabs = 0;
    std::vector<std::array<double, 3>> points;
    std::array<double, 13> transform{1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1};
};

Sab walkSab(const QByteArray& b) {
    Sab sab;
    const auto* d = reinterpret_cast<const uchar*>(b.constData());
    const std::size_t n = std::size_t(b.size());
    std::size_t p = 15 + 16; // signature, then version, records, entities, flags
    const auto le = [&](std::size_t k) {
        quint64 v = 0;
        for (std::size_t i = 0; i < k && p + i < n; ++i) v |= quint64(d[p + i]) << (8 * i);
        p += k;
        return v;
    };
    const auto dbl = [&]() {
        double v = 0;
        if (p + 8 <= n) std::memcpy(&v, d + p, 8);
        p += 8;
        return v;
    };
    std::string type, part;
    std::vector<double> numbers, headerDoubles;
    bool record = false, begun = false;
    while (p < n) {
        const uchar tag = d[p++];
        if (tag == 13 || tag == 14) {
            const std::size_t length = le(1);
            const std::string s(reinterpret_cast<const char*>(d + p), std::min(length, n - std::min(n, p)));
            p += length;
            if (tag == 14) {
                part += s + "-";
                continue;
            }
            const std::string name = part + s;
            part.clear();
            if (record) continue; // a word inside a record
            if (name.rfind("End-of-", 0) == 0) {
                sab.ends = p == n;
                break;
            }
            type = name;
            record = begun = true;
            numbers.clear();
        } else if (tag == 17) {
            if (type == "face") ++sab.faces;
            if (type == "point" && numbers.size() >= 3)
                sab.points.push_back({numbers[numbers.size() - 3], numbers[numbers.size() - 2], numbers.back()});
            if (type == "transform" && numbers.size() >= 13)
                for (std::size_t i = 0; i < 13; ++i) sab.transform[i] = numbers[numbers.size() - 13 + i];
            record = false;
        } else if (tag == 6 || tag == 23) {
            const double v = dbl();
            if (record) numbers.push_back(v);
            else if (!begun) headerDoubles.push_back(v);
        } else if (tag == 19 || tag == 20) {
            for (int i = 0; i < 3; ++i) {
                const double v = dbl();
                if (record) numbers.push_back(v);
            }
        } else if (tag == 22) {
            p += 16;
        } else if (tag == 4) {
            const double v = double(qint32(quint32(le(4))));
            if (record) numbers.push_back(v);
        } else if (tag == 12 || tag == 21 || tag == 5) {
            p += 4;
        } else if (tag == 7 || tag == 8 || tag == 9 || tag == 18) {
            p += le(tag == 7 ? 1 : tag == 8 ? 2 : 4);
        } else if (tag == 2) {
            p += 1;
        } else if (tag == 3) {
            p += 2;
        } else if (tag != 10 && tag != 11 && tag != 15 && tag != 16) {
            break; // a tag not known: not a walk to the end
        }
    }
    if (headerDoubles.size() >= 2) sab.millimetres = headerDoubles[0], sab.resabs = headerDoubles[1];
    return sab;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    QString sample = qEnvironmentVariable("CADNEXT_TEST_DWG_FILE");
    if (sample.isEmpty())
        sample = QFileInfo(QString::fromLocal8Bit(__FILE__)).dir().absoluteFilePath(QStringLiteral("../build-gui-occt/format-audit/sample_AC1032.dwg"));
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples");

    // Conversion by hand first: it needs no file.
    {
        const std::array<double, 16> identity{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        const std::array<double, 16> mirror{-1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        const std::array<double, 16> turn{0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        const std::array<double, 16> stretch{2, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
        DwgPlanar arc;
        arc.kind = DwgPlanar::Kind::Arc;
        arc.radius = 1000.0; // a metre, at a millimetre a unit
        arc.startAngle = 0.0;
        arc.endAngle = 3.14159265358979323846 / 2;
        const auto arcIs = [&](const std::vector<SketchEntity>& out, double start, double sweep) {
            return out.size() == 1 && out[0].type == SketchEntityType::Arc && near(out[0].arc.radius, 1.0, 1e-12) &&
                   near(out[0].arc.startAngleDegrees, start, 1e-9) && near(out[0].arc.sweepDegrees, sweep, 1e-9) &&
                   near(out[0].arc.center.u, 0.0, 1e-12) && near(out[0].arc.center.v, 0.0, 1e-12);
        };
        std::map<QString, int> left;
        check(arcIs(convert(arc, identity, left), 0, 90), "дуга 0–90° радиуса 1 остаётся такой");
        check(arcIs(convert(arc, mirror, left), 90, 90), "та же, отражённая x → −x: 90–180°");
        DwgPlanar below = arc;
        below.extrusion[2] = -1.0;
        check(arcIs(convert(below, identity, left), 90, 90), "та же в системе объекта оси (0, 0, −1): 90–180°");
        check(arcIs(convert(arc, turn, left), 90, 90), "та же, повёрнутая вставкой на 90°: 90–180°");
        DwgPlanar circle;
        circle.kind = DwgPlanar::Kind::Circle;
        circle.radius = 1000.0;
        left.clear();
        check(convert(circle, stretch, left).empty() && left.size() == 1, "окружность, растянутая (2, 1), пропущена как эллипс");
        DwgPlanar square;
        square.kind = DwgPlanar::Kind::Polyline;
        square.points = {{0, 0}, {1000, 0}, {1000, 1000}, {0, 1000}};
        square.bulges = {0, 1, 0, 0};
        square.closed = true;
        const auto out = convert(square, identity, left);
        bool half = out.size() == 4 && out[1].type == SketchEntityType::Arc && near(out[1].arc.center.u, 1.0, 1e-12) &&
                    near(out[1].arc.center.v, 0.5, 1e-12) && near(out[1].arc.radius, 0.5, 1e-12) &&
                    near(out[1].arc.sweepDegrees, 180, 1e-9) && near(out[1].arc.startAngleDegrees, 270, 1e-9);
        check(half, "ребро полилинии с выпуклостью 1 — полуокружность вокруг середины ребра");
    }

    if (!QFileInfo::exists(sample)) {
        std::printf("SKIP образец AC1032 не найден (%s)\n", sample.toUtf8().constData());
    } else {
        DwgFile file;
        QString error;
        const bool read = readDwgFile(sample, file, error);
        check(read && file.version == QLatin1String("AC1032"), "AC1032 прочитан" + (read ? std::string() : " — " + error.toStdString()));
        if (read) {
            std::map<QString, int> decoded;
            for (const DwgObject& object : file.objects) ++decoded[dwgTypeName(file, object.type)];
            int agree = 0, fewer = 0, listed = 0, more = 0;
            for (const DwgClass& c : file.classes) {
                if (c.objects < 0) continue;
                ++listed;
                const int n = decoded[c.dxfName];
                if (n == c.objects) ++agree;
                else if (n < c.objects) ++fewer, std::printf("  класс %s: создано %d, в файле %d\n", c.dxfName.toUtf8().constData(), c.objects, n);
                else ++more, std::printf("  класс %s: в таблице %d, прочитано БОЛЬШЕ: %d\n", c.dxfName.toUtf8().constData(), c.objects, n);
            }
            check(listed > 0 && more == 0 && agree + fewer == listed,
                  "объектов каждого класса столько, сколько в таблице классов: " + std::to_string(agree) + " из " + std::to_string(listed) +
                      " точно, " + std::to_string(fewer) + " меньше (удалённые), больше — ни одного");
            check(file.misread == 0 && !file.planar.empty() && !file.blocks.empty() && !file.inserts.empty(),
                  "плоских сущностей " + std::to_string(file.planar.size()) + ", вставок " + std::to_string(file.inserts.size()) +
                      ", заголовков блоков " + std::to_string(file.blocks.size()) + " — все кончаются там, где указывает файл");
            std::map<quint64, int> owners;
            std::set<quint64> headers;
            for (const DwgBlock& b : file.blocks) headers.insert(b.handle);
            std::map<quint64, int> types;
            for (const DwgObject& object : file.objects) types[object.handle] = object.type;
            int inBlocks = 0, owned = 0, modelSpace = 0, layout = 0;
            for (const DwgObject& object : file.objects) {
                if (!object.entity) continue;
                const bool marker = object.type == 4 || object.type == 5;
                if (object.entityMode == 2 && !marker) ++modelSpace;
                if (object.entityMode == 1 && !marker) ++layout;
                if (object.entityMode != 0) continue;
                ++inBlocks;
                // Attributes and sequence ends to their INSERT or POLYLINE; vertices to their POLYLINE.
                const int parent = types[object.owner];
                const bool part = (object.type == 2 || object.type == 6 || (object.type >= 10 && object.type <= 14)) &&
                                  (parent == 7 || parent == 8 || (parent >= 15 && parent <= 16) || parent == 29 || parent == 30);
                if (headers.count(object.owner) || part) ++owned;
                if (headers.count(object.owner) && !marker) ++owners[object.owner];
            }
            int counted = 0;
            for (const DwgBlock& b : file.blocks) {
                int n = owners[b.handle];
                if (n == 0 && b.name == QLatin1String("*Model_Space")) n = modelSpace;
                if (n == 0 && b.name == QLatin1String("*Paper_Space")) n = layout;
                counted += b.owned == n ? 1 : 0;
            }
            check(inBlocks > 0 && owned == inBlocks && counted == int(file.blocks.size()),
                  "владелец каждой сущности блока — заголовок блока (" + std::to_string(owned) + "/" + std::to_string(inBlocks) +
                      "), число сущностей сходится у " + std::to_string(counted) + "/" + std::to_string(file.blocks.size()) + " блоков");
            check(file.header.read && file.header.insunits == 1, "заголовок до INSUNITS: дюймы");

            DwgModel model;
            std::vector<SketchEntity> sketch;
            std::map<QString, int> left;
            if (readDwgModel(sample, model, error)) dwgSketchEntities(model, sketch, left);
            double lo[2] = {1e300, 1e300}, hi[2] = {-1e300, -1e300};
            const auto box = [&](double x, double y) {
                lo[0] = std::min(lo[0], x), lo[1] = std::min(lo[1], y);
                hi[0] = std::max(hi[0], x), hi[1] = std::max(hi[1], y);
            };
            for (const SketchEntity& e : sketch) {
                if (e.type == SketchEntityType::Line) box(e.line.start.u, e.line.start.v), box(e.line.end.u, e.line.end.v);
                if (e.type == SketchEntityType::Circle)
                    box(e.circle.center.u - e.circle.radius, e.circle.center.v - e.circle.radius),
                        box(e.circle.center.u + e.circle.radius, e.circle.center.v + e.circle.radius);
                if (e.type == SketchEntityType::Arc) box(e.arc.center.u, e.arc.center.v);
            }
            const double* xl = file.header.extentsMin;
            const double* xh = file.header.extentsMax;
            const double size = std::max(xh[0] - xl[0], xh[1] - xl[1]) * kInch;
            char line[320];
            std::snprintf(line, sizeof line, "эскиз модели: %zu объектов, габарит %.6g..%.6g × %.6g..%.6g in внутри EXTMIN/EXTMAX %.6g..%.6g × %.6g..%.6g",
                          sketch.size(), lo[0] / kInch, hi[0] / kInch, lo[1] / kInch, hi[1] / kInch, xl[0], xh[0], xl[1], xh[1]);
            check(!sketch.empty() && lo[0] >= xl[0] * kInch - 1e-9 * size && hi[0] <= xh[0] * kInch + 1e-9 * size &&
                      lo[1] >= xl[1] * kInch - 1e-9 * size && hi[1] <= xh[1] * kInch + 1e-9 * size,
                  line);

            // MyBlock by hand.
            const DwgBlock* my = nullptr;
            for (const DwgBlock& b : file.blocks)
                if (b.name == QLatin1String("MyBlock")) my = &b;
            const DwgInsert* insert = nullptr;
            for (const DwgInsert& i : file.inserts)
                if (my && i.block == my->handle && i.entityMode == 2) insert = &i;
            int found = 0, expected = 0;
            if (my && insert && insert->rotation == 0.0 && insert->extrusion[2] == 1.0) {
                const auto at = [&](double x, double y, int k) {
                    const double p[2] = {x, y};
                    return (insert->point[k] + insert->scale[k] * (p[k] - my->base[k])) * kInch;
                };
                for (const DwgPlanar& e : file.planar) {
                    if (e.entityMode != 0 || e.owner != my->handle) continue;
                    ++expected;
                    for (const SketchEntity& s : sketch) {
                        if (e.kind == DwgPlanar::Kind::Line && s.type == SketchEntityType::Line &&
                            near(s.line.start.u, at(e.start[0], e.start[1], 0), 1e-12) && near(s.line.start.v, at(e.start[0], e.start[1], 1), 1e-12) &&
                            near(s.line.end.u, at(e.end[0], e.end[1], 0), 1e-12) && near(s.line.end.v, at(e.end[0], e.end[1], 1), 1e-12)) {
                            ++found;
                            break;
                        }
                        if (e.kind == DwgPlanar::Kind::Circle && s.type == SketchEntityType::Circle &&
                            near(s.circle.center.u, at(e.center[0], e.center[1], 0), 1e-12) &&
                            near(s.circle.center.v, at(e.center[0], e.center[1], 1), 1e-12) &&
                            near(s.circle.radius, e.radius * insert->scale[0] * kInch, 1e-12)) {
                            ++found;
                            break;
                        }
                    }
                }
            }
            check(expected == 3 && found == 3, "MyBlock во вставке: " + std::to_string(found) + " из " + std::to_string(expected) +
                                                   " объектов там, куда их ставит вставка (рассчитано вручную)");

            // Polylines chain.
            int polylines = 0, chained = 0;
            for (const DwgModelPlanar& item : model.planar) {
                if (item.entity.kind != DwgPlanar::Kind::Polyline || item.entity.widths) continue;
                DwgModel one;
                one.planar.push_back(item);
                std::vector<SketchEntity> out;
                std::map<QString, int> ignored;
                dwgSketchEntities(one, out, ignored);
                ++polylines;
                const auto ends = [](const SketchEntity& s, bool last) {
                    if (s.type == SketchEntityType::Line) return last ? s.line.end : s.line.start;
                    const double a = (s.arc.startAngleDegrees + (last ? s.arc.sweepDegrees : 0.0)) * 3.14159265358979323846 / 180.0;
                    return SketchPoint2D{s.arc.center.u + s.arc.radius * std::cos(a), s.arc.center.v + s.arc.radius * std::sin(a)};
                };
                bool chain = !out.empty();
                for (std::size_t i = 0; i + 1 < out.size() && chain; ++i) {
                    // An arc may run either way along its polyline: its ends as a set.
                    const SketchPoint2D a0 = ends(out[i], false), a1 = ends(out[i], true);
                    const SketchPoint2D b0 = ends(out[i + 1], false), b1 = ends(out[i + 1], true);
                    const auto same = [](SketchPoint2D p, SketchPoint2D q) { return std::hypot(p.u - q.u, p.v - q.v) <= 1e-12; };
                    chain = same(a0, b0) || same(a0, b1) || same(a1, b0) || same(a1, b1);
                }
                chained += chain ? 1 : 0;
            }
            check(polylines > 0 && chained == polylines, "полилинии модели: " + std::to_string(chained) + " из " + std::to_string(polylines) +
                                                            " — отрезки и дуги идут цепью");
        }
    }

    // AC1032 solids (SAB).
    if (QFileInfo::exists(sample)) {
        DwgFile file;
        QString error;
        readDwgFile(sample, file, error);
        int records = 0, ending = 0, built = 0, sheets = 0;
        for (const DwgObject& object : file.objects) {
            if (object.type != 37 && object.type != 38 && object.type != 39) continue;
            ++records;
            const Sab sab = walkSab(object.acis);
            ending += sab.ends ? 1 : 0;
            kernel::OcctKernel kernel;
            AcisSatResult result;
            QString why;
            const bool ok = readAcisSat(object.acis, kernel, result, why, nullptr, "sab");
            if (object.type == 37) {
                sheets += !ok && why.contains(QStringLiteral("лист")) ? 1 : 0;
                continue;
            }
            if (!ok || result.solids.size() != 1) {
                check(false, "тело SAB " + std::to_string(object.handle) + ": " + why.toStdString());
                continue;
            }
            ++built;
            const TopoDS_Shape& solid = *kernel.findShape(result.solids.front().shape);
            int faces = 0;
            for (TopExp_Explorer e(solid, TopAbs_FACE); e.More(); e.Next()) ++faces;
            // SAB points (units) moved by the transform (p · A · s + t), in metres.
            const double unit = sab.millimetres * 1e-3;
            const auto& m = sab.transform;
            double worst = 0.0;
            Bnd_Box points;
            TopExp_Explorer shell(solid, TopAbs_SHELL);
            for (const auto& q : sab.points) {
                gp_Pnt w;
                for (int k = 0; k < 3; ++k)
                    w.SetCoord(k + 1, ((q[0] * m[std::size_t(k)] + q[1] * m[std::size_t(3 + k)] + q[2] * m[std::size_t(6 + k)]) * m[12] +
                                       m[std::size_t(9 + k)]) * unit);
                points.Add(w);
                BRepExtrema_DistShapeShape distance(BRepBuilderAPI_MakeVertex(w).Vertex(), shell.Current());
                worst = std::max(worst, distance.IsDone() ? distance.Value() : 1.0);
            }
            Bnd_Box box;
            BRepBndLib::AddOptimal(solid, box, false, false);
            double a[6], c[6];
            box.Get(a[0], a[1], a[2], a[3], a[4], a[5]);
            points.Get(c[0], c[1], c[2], c[3], c[4], c[5]);
            double gap = 0.0;
            for (int k = 0; k < 6; ++k) gap = std::max(gap, std::fabs(a[k] - c[k]));
            const double size = std::max({a[3] - a[0], a[4] - a[1], a[5] - a[2]});
            GProp_GProps props;
            BRepGProp::VolumeProperties(solid, props);
            const double boxVolume = (a[3] - a[0]) * (a[4] - a[1]) * (a[5] - a[2]);
            const bool isBox = faces == 6;
            char line[320];
            std::snprintf(line, sizeof line,
                          "тело SAB %llx: верно, граней %d (записей face %d), %zu точек на границе (худшая %.2g м при 10·resabs %.2g), "
                          "габарит как у точек (%.2g м)%s",
                          (unsigned long long)object.handle, faces, sab.faces, sab.points.size(), worst, 10 * sab.resabs * unit, gap,
                          isBox ? (", объём как у габарита: " + std::to_string(props.Mass() / boxVolume)).c_str() : "");
            check(BRepCheck_Analyzer(solid).IsValid() && faces == sab.faces && !sab.points.empty() && worst <= 10 * sab.resabs * unit &&
                      gap <= 1e-9 * size && (!isBox || std::fabs(props.Mass() - boxVolume) <= 1e-9 * boxVolume),
                  line);
        }
        check(records == 3 && ending == 3 && built == 2 && sheets == 1,
              "AC1032: записей ACIS в хранилище " + std::to_string(records) + ", кончаются своим маркером ровно на длине " +
                  std::to_string(ending) + ", тел построено " + std::to_string(built) + ", область отклонена как лист " + std::to_string(sheets));
    }

    // R2000: none misread.
    {
        const QString dir = root + "/dwg/blowdryer";
        int files = 0, misread = 0, planar = 0, inserts = 0;
        for (const QFileInfo& info : QDir(dir).entryInfoList({"*.dwg", "*.DWG"}, QDir::Files, QDir::Name)) {
            DwgFile file;
            QString error;
            if (!readDwgFile(info.absoluteFilePath(), file, error)) continue;
            ++files;
            misread += file.misread;
            planar += int(file.planar.size());
            inserts += int(file.inserts.size());
        }
        if (files == 0) std::printf("SKIP чертежи R2000 не найдены (%s)\n", dir.toUtf8().constData());
        else
            check(files == 11 && misread == 0 && planar > 0, "R2000: 11 чертежей, плоских сущностей " + std::to_string(planar) + ", вставок " +
                                                               std::to_string(inserts) + " — ни одна не прочитана мимо");
    }

    std::printf("%s: %d провалов\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
