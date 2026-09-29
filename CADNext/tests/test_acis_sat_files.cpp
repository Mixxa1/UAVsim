// ACIS SAT read into exact solids (NativeAcisSat), against references independent of the reader.
//
// Criteria, fixed before the first run of this test:
//   - Files with a sound STEP twin of the same model (NIST engineering-design-models, Allied-Signal: STEP
//     written from the same ACIS model; read here by OCCT, its MANIFOLD_SOLID_BREP transferred directly —
//     the 1995 files carry no product structure): the same volume, within the files' own precision,
//     resabs (1e-6 model units) × the solid's area. "Sound": OCCT reads the twin into one valid solid
//     with the reader's face count (part04, team, team2 twins read with volume 0; part05, part07,
//     sbrooks1, sbrooks2 twins crash OCCT's STEP reader — none of those are read here).
//   - part01: its twin lost a hole's crescent where the hole leaves through a chamfer (its hole wall is
//     a full band there, 8.0263e-5; ACIS's loops are an arc of 282° and an ellipse above z = 0). The
//     hole wall's area is checked instead against its closed form: 2πrh less the crescent,
//     r·(2r sin φ − 2eφ) with cos φ = e/r, to 1e-9 relative.
//   - The NIST MTC cover, SAT written by SOLIDWORKS 2016: the same volume as the SLDPRT of the same
//     part built by the Parasolid reader, within 1e-8 m × area (that reader's own build target).
//   - Every other file: a valid closed solid with as many faces as the ACIS body (none is split per
//     turn), and the samples' duplicates (spinner3 = edge-92, spinner4 = center, part07 = sbrooks2)
//     read alike.
//   - part02: 427 valid faces, including the original 15 nm sliver. The wall of an internally
//     tangent cross-hole is checked by integrating the two cylinders' equations independently.
//     Its STEP twin crashes OCCT while transferring its BRep, so it is not used as a reference.
//   - A SAT of save version 7.0 built here as that format's reference describes it (the entity id after
//     the attribute pointer, logicals as words, three header lines, 25.4 mm a unit): a 1 × 2 × 3 inch
//     block, its volume 6 in³ exactly, its units honoured.
#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepAdaptor_Surface.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <GProp_GProps.hxx>
#include <Interface_InterfaceModel.hxx>
#include <STEPControl_Reader.hxx>
#include <StepShape_ManifoldSolidBrep.hxx>
#include <TopExp_Explorer.hxx>
#include <TopoDS.hxx>
#include <XSControl_WorkSession.hxx>
#include <gp_Lin.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>

#include <cmath>
#include <cstdio>
#include <map>
#include <string>

using namespace cadnext;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

constexpr double kPi = 3.14159265358979323846;

double volumeOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::VolumeProperties(s, p, 1e-10, true);
    return p.Mass();
}

double areaOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::SurfaceProperties(s, p, 1e-10);
    return p.Mass();
}

int facesOf(const TopoDS_Shape& s) {
    int n = 0;
    for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) ++n;
    return n;
}

// Faces the SAT body records: "face" records.
int acisFaces(const QString& path) {
    QFile file(path);
    file.open(QIODevice::ReadOnly);
    const QString text = QString::fromLatin1(file.readAll());
    return int(text.count(QRegularExpression(QStringLiteral("(^|\\s)face\\s"))));
}

struct Read {
    bool ok = false;
    QString error;
    TopoDS_Shape shape; // in the file's units (the reader's metres back through its millimetres)
    gui::AcisSatResult result;
};

Read readSat(kernel::OcctKernel& kernel, const QString& path, double toFileUnits) {
    Read r;
    r.ok = gui::readAcisSatFile(path, kernel, r.result, r.error);
    if (!r.ok || r.result.solids.size() != 1) return r.ok = false, r;
    const TopoDS_Shape& solid = *kernel.findShape(r.result.solids.front().shape);
    gp_Trsf scale;
    scale.SetScale(gp::Origin(), toFileUnits);
    r.shape = BRepBuilderAPI_Transform(solid, scale, true).Shape();
    return r;
}

TopoDS_Shape stepTwin(const QString& path) {
    STEPControl_Reader reader;
    if (reader.ReadFile(path.toUtf8().constData()) != IFSelect_RetDone) return {};
    const Handle(Interface_InterfaceModel) model = reader.WS()->Model();
    for (int n = 1; n <= model->NbEntities(); ++n)
        if (model->Value(n)->IsKind(STANDARD_TYPE(StepShape_ManifoldSolidBrep))) reader.TransferOne(n);
    return reader.OneShape();
}

// A 1 × 2 × 3 block in ACIS 7.0's layout: "type $attrib id <class data> #", a unit 25.4 mm.
QByteArray block700(double X = 1, double Y = 2, double Z = 3) {
    const double p[8][3] = {{0, 0, 0}, {X, 0, 0}, {X, Y, 0}, {0, Y, 0}, {0, 0, Z}, {X, 0, Z}, {X, Y, Z}, {0, Y, Z}};
    // Faces as vertex quads, counter-clockwise seen from outside, with their outward normals.
    const int quads[6][4] = {{0, 3, 2, 1}, {4, 5, 6, 7}, {0, 1, 5, 4}, {2, 3, 7, 6}, {1, 2, 6, 5}, {3, 0, 4, 7}};
    const double normals[6][3] = {{0, 0, -1}, {0, 0, 1}, {0, -1, 0}, {0, 1, 0}, {1, 0, 0}, {-1, 0, 0}};
    // Records: 0 body, 1 lump, 2 shell, 3..8 faces, 9..14 loops, 15..20 planes, 21..44 coedges,
    // 45..56 edges, 57..68 straight curves, 69..76 vertices, 77..84 points.
    std::map<std::pair<int, int>, int> edgeOf; // (low vertex, high vertex) -> edge number 0..11
    std::vector<std::pair<int, int>> edges;
    for (const auto& q : quads)
        for (int i = 0; i < 4; ++i) {
            const int a = q[i], b = q[(i + 1) % 4];
            const auto key = std::make_pair(std::min(a, b), std::max(a, b));
            if (!edgeOf.count(key)) {
                edgeOf[key] = int(edges.size());
                edges.push_back(key);
            }
        }
    const auto face = [](int f) { return 3 + f; };
    const auto loop = [](int f) { return 9 + f; };
    const auto plane = [](int f) { return 15 + f; };
    const auto coedge = [](int f, int i) { return 21 + 4 * f + i; };
    const auto edge = [](int e) { return 45 + e; };
    const auto curve = [](int e) { return 57 + e; };
    const auto vertex = [](int v) { return 69 + v; };
    const auto point = [](int v) { return 77 + v; };
    QByteArray t;
    t += "700 0 1 0\n@7 CADNext @8 ACIS 7.0 @24 Sat Sep 26 12:00:00 2026\n25.4 9.9999999999999995e-007 1e-010\n";
    const auto rec = [&](int n, const std::string& body) { t += QByteArray::fromStdString("-" + std::to_string(n) + " " + body + " #\n"); };
    const auto ptr = [](int n) { return "$" + std::to_string(n); };
    const auto num = [](double v) { char b[32]; std::snprintf(b, sizeof b, "%.17g", v); return std::string(b); };
    rec(0, "body $-1 -1 $1 $-1 $-1");
    rec(1, "lump $-1 -1 $-1 $2 $0");
    rec(2, "shell $-1 -1 $-1 $-1 $3 $-1 $1");
    for (int f = 0; f < 6; ++f) {
        rec(face(f), "face $-1 -1 " + (f < 5 ? ptr(face(f + 1)) : std::string("$-1")) + " " + ptr(loop(f)) + " $2 $-1 " + ptr(plane(f)) + " forward single");
    }
    for (int f = 0; f < 6; ++f) rec(loop(f), "loop $-1 -1 $-1 " + ptr(coedge(f, 0)) + " " + ptr(face(f)));
    for (int f = 0; f < 6; ++f) {
        const auto& q = quads[f];
        const double* n = normals[f];
        // u direction along the quad's first side
        const double* a = p[q[0]];
        const double* b = p[q[1]];
        rec(plane(f), "plane-surface $-1 -1 " + num(a[0]) + " " + num(a[1]) + " " + num(a[2]) + " " + num(n[0]) + " " + num(n[1]) + " " +
                          num(n[2]) + " " + num(b[0] - a[0]) + " " + num(b[1] - a[1]) + " " + num(b[2] - a[2]) + " forward_v I I I I");
    }
    // Coedges: next, previous, partner, edge, sense, loop, pcurve.
    std::map<int, std::vector<std::pair<int, int>>> uses; // edge -> (face, index)
    for (int f = 0; f < 6; ++f)
        for (int i = 0; i < 4; ++i) {
            const int a = quads[f][i], b = quads[f][(i + 1) % 4];
            uses[edgeOf[{std::min(a, b), std::max(a, b)}]].push_back({f, i});
        }
    for (int f = 0; f < 6; ++f)
        for (int i = 0; i < 4; ++i) {
            const int a = quads[f][i], b = quads[f][(i + 1) % 4];
            const int e = edgeOf[{std::min(a, b), std::max(a, b)}];
            const auto& pair = uses[e];
            const auto other = pair[0] == std::make_pair(f, i) ? pair[1] : pair[0];
            const bool reversed = a > b; // the edge runs from its lower vertex
            rec(coedge(f, i), "coedge $-1 -1 " + ptr(coedge(f, (i + 1) % 4)) + " " + ptr(coedge(f, (i + 3) % 4)) + " " +
                                  ptr(coedge(other.first, other.second)) + " " + ptr(edge(e)) + (reversed ? " reversed " : " forward ") +
                                  ptr(loop(f)) + " $-1");
        }
    for (int e = 0; e < 12; ++e) {
        const auto [a, b] = edges[std::size_t(e)];
        const auto first = uses[e][0];
        const double length = std::hypot(p[b][0] - p[a][0], p[b][1] - p[a][1], p[b][2] - p[a][2]);
        rec(edge(e), "edge $-1 -1 " + ptr(vertex(a)) + " 0 " + ptr(vertex(b)) + " " + num(length) + " " +
                         ptr(coedge(first.first, first.second)) + " " + ptr(curve(e)) + " forward @7 unknown");
        rec(curve(e), "straight-curve $-1 -1 " + num(p[a][0]) + " " + num(p[a][1]) + " " + num(p[a][2]) + " " + num((p[b][0] - p[a][0]) / length) +
                          " " + num((p[b][1] - p[a][1]) / length) + " " + num((p[b][2] - p[a][2]) / length) + " I I");
    }
    for (int v = 0; v < 8; ++v) {
        int anEdge = 0;
        for (int e = 0; e < 12; ++e)
            if (edges[std::size_t(e)].first == v || edges[std::size_t(e)].second == v) anEdge = e;
        rec(vertex(v), "vertex $-1 -1 " + ptr(edge(anEdge)) + " " + ptr(point(v)));
        rec(point(v), "point $-1 -1 " + num(p[v][0]) + " " + num(p[v][1]) + " " + num(p[v][2]));
    }
    t += "End-of-ACIS-data\n";
    return t;
}

QByteArray wholePeriodic700(const QByteArray& surface) {
    return "700 5 1 0\n7 CADNext 8 ACIS 7.0 4 date\n1000 1e-9 1e-10\n"
        "-0 body $-1 -1 $-1 $1 $-1 $-1 #\n"
        "-1 lump $-1 -1 $-1 $-1 $2 $0 #\n"
        "-2 shell $-1 -1 $-1 $-1 $-1 $3 $-1 $1 #\n"
        "-3 face $-1 -1 $-1 $-1 $-1 $2 $-1 $4 forward single #\n"
        "-4 " + surface + " $-1 -1 $-1 " +
        (surface == "sphere-surface" ? QByteArray("0 0 0 0.01 1 0 0 0 0 1 forward_v I I I I")
                                     : QByteArray("0 0 0 0 0 1 0.015 0.003 1 0 0 forward_v I I I I")) +
        " #\nEnd-of-ACIS-data\n";
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    // The samples outside the repository (their SOURCES.txt says where each comes from).
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples");
    const QString samples = root + "/acis/allied-signal";
    const QString mtc = root + "/nist/NIST-MTC-Assembly/SolidWorks";

    for (const QByteArray surface : {QByteArray("sphere-surface"), QByteArray("torus-surface")}) {
        kernel::OcctKernel kernel;
        gui::AcisSatResult result;
        QString error;
        const bool ok = gui::readAcisSat(wholePeriodic700(surface), kernel, result, error);
        const TopoDS_Shape shape = ok && result.solids.size() == 1 ? *kernel.findShape(result.solids.front().shape) : TopoDS_Shape{};
        const double expected = surface == "sphere-surface" ? 4.0 / 3 * kPi * std::pow(0.01, 3)
                                                          : 2 * kPi * kPi * 0.015 * 0.003 * 0.003;
        check(!shape.IsNull() && facesOf(shape) == 1 && BRepCheck_Analyzer(shape).IsValid() &&
                  std::fabs(volumeOf(shape) - expected) <= 1e-10 * expected,
              surface.toStdString() + ": полная периодическая поверхность без исходных контуров — точный объём" +
                  (ok ? "" : " — " + error.toStdString()));
    }

    // A synthetic ACIS 7.0 block.
    {
        kernel::OcctKernel kernel;
        gui::AcisSatResult result;
        QString error;
        const bool ok = gui::readAcisSat(block700(), kernel, result, error, nullptr, "block");
        const double inch = 25.4e-3;
        const double volume = ok && result.solids.size() == 1 ? volumeOf(*kernel.findShape(result.solids.front().shape)) : 0;
        check(ok && result.version == 700 && result.millimetresPerUnit == 25.4 && std::fabs(volume - 6 * inch * inch * inch) <= 1e-12 * 6 * inch * inch * inch,
              "ACIS 7.0 (синтетический брусок 1×2×3 дюйма): объём 6 куб. дюймов, единицы из заголовка" +
                  (ok ? "" : " — " + error.toStdString()));
    }
    {
        kernel::OcctKernel kernel;
        gui::AcisSatResult result;
        QString error;
        QByteArray sat = block700(1e-8, 0.02, 0.03);
        sat.replace("25.4 9.9999999999999995e-007", "1000 9.9999999999999995e-007");
        const bool ok = gui::readAcisSat(sat, kernel, result, error);
        const TopoDS_Shape shape = ok && result.solids.size() == 1 ? *kernel.findShape(result.solids.front().shape) : TopoDS_Shape{};
        const double expected = 1e-8 * 0.02 * 0.03;
        check(!shape.IsNull() && BRepCheck_Analyzer(shape).IsValid() && facesOf(shape) == 6 &&
                  std::fabs(volumeOf(shape) - expected) <= 1e-8 * expected,
              "ACIS: 10 нм толщины — масштаб построения сохраняет шесть граней и объём" +
                  (ok ? "" : " — " + error.toStdString()));
    }

    if (!QFileInfo(samples + "/part01.sat").exists()) {
        std::printf("SKIP образцы ACIS не найдены (%s)\n", samples.toUtf8().constData());
    } else {
        // Twins: each read in its own file units (the reader's mm are the file's units: x1000 back from m).
        for (const char* name : {"center", "part03", "part06", "part08", "part09", "part10", "part13", "switcharm"}) {
            kernel::OcctKernel kernel;
            const Read r = readSat(kernel, samples + "/" + name + ".sat", 1000.0);
            const TopoDS_Shape twin = stepTwin(samples + "/" + name + ".step");
            const bool sound = !twin.IsNull() && BRepCheck_Analyzer(twin).IsValid() && r.ok && facesOf(twin) == facesOf(r.shape);
            if (!r.ok || !sound) {
                check(false, std::string(name) + ": прочитан, близнец STEP исправен" + (r.ok ? "" : " — " + r.error.toStdString()));
                continue;
            }
            const double v = volumeOf(r.shape), vt = volumeOf(twin), bound = 1e-6 * areaOf(r.shape);
            std::printf("  %s: V %.12g, STEP %.12g, разница %.3g (граница %.3g)\n", name, v, vt, v - vt, bound);
            check(std::fabs(v - vt) <= bound, std::string(name) + ": объём как у близнеца STEP в пределах resabs × площадь");
        }
        // part01's hole through the chamfer.
        {
            kernel::OcctKernel kernel;
            const Read r = readSat(kernel, samples + "/part01.sat", 1000.0);
            double area = -1;
            if (r.ok)
                for (TopExp_Explorer e(r.shape, TopAbs_FACE); e.More(); e.Next()) {
                    const BRepAdaptor_Surface s(TopoDS::Face(e.Current()));
                    if (s.GetType() != GeomAbs_Cylinder || std::fabs(s.Cylinder().Radius() - 0.0025146) > 1e-12) continue;
                    if (s.Cylinder().Location().Distance(gp_Pnt(0.0318262, 0.00508, s.Cylinder().Location().Z())) > 1e-9) continue;
                    GProp_GProps p;
                    BRepGProp::SurfaceProperties(e.Current(), p, 1e-12);
                    area = p.Mass();
                }
            // The chamfer z = x - 0.033782 cuts the wall where x - xc > e = 0.033782 - 0.0318262.
            const double radius = 0.0025146, height = 0.00508, e = 0.033782 - 0.0318262, phi = std::acos(e / radius);
            const double expected = 2 * kPi * radius * height - radius * (2 * radius * std::sin(phi) - 2 * e * phi);
            std::printf("  part01: стенка отверстия у фаски %.12g, по формуле %.12g\n", area, expected);
            check(r.ok && std::fabs(area - expected) <= 1e-9 * expected, "part01: стенка отверстия, выходящего на фаску, — полоса без серпа (формула)");
        }
        // Everything else: valid, the ACIS face count.
        std::map<std::string, double> volumes;
        for (const char* name : {"edge-92", "part04", "part05", "part07", "part11", "part12", "sbrooks1", "sbrooks2", "spinner", "spinner2",
                                 "spinner3", "spinner4", "team", "team2", "center"}) {
            kernel::OcctKernel kernel;
            const QString path = samples + "/" + name + ".sat";
            const Read r = readSat(kernel, path, 1000.0);
            const bool ok = r.ok && BRepCheck_Analyzer(r.shape).IsValid() && volumeOf(r.shape) > 0;
            if (ok) volumes[name] = volumeOf(r.shape);
            check(ok && facesOf(r.shape) == acisFaces(path),
                  std::string(name) + ": тело верно, граней как в ACIS (" + std::to_string(ok ? facesOf(r.shape) : 0) + " из " +
                      std::to_string(acisFaces(path)) + ")" + (r.ok ? "" : " — " + r.error.toStdString()));
        }
        for (const auto& [a, b] : {std::pair{"spinner3", "edge-92"}, std::pair{"spinner4", "center"}, std::pair{"part07", "sbrooks2"}})
            check(volumes.count(a) && volumes.count(b) && volumes[a] == volumes[b], std::string(a) + " и " + b + " — одна модель, один объём");
        // A cross-hole tangent to the larger bore: the chart in SAT stops at the
        // tangent point and misses the other vertex by millimetres. Its area is
        // r * integral(cap position - cylinder intersection position) du.
        {
            kernel::OcctKernel kernel;
            const Read r = readSat(kernel, samples + "/part02.sat", 1000.0);
            check(r.ok && BRepCheck_Analyzer(r.shape).IsValid() && facesOf(r.shape) == 427 && volumeOf(r.shape) > 0,
                  "part02: проверенное тело, все 427 исходных граней, включая узкую полоску" +
                      (r.ok ? "" : " — " + r.error.toStdString()));
            const gp_Pnt small(0.041931375907754, 0.070150235562843, 0.024638);
            const gp_Pnt large(0.029199837959202, 0.073808943144898, 0.051562);
            const gp_Pnt cap(0.047608633151435, 0.061733355565155, 0.024638);
            const gp_Vec axis(0.55919290347074613, -0.82903757255504218, 0);
            const gp_Vec radial(0.82903757255504218, 0.55919290347074613, 0);
            const double axial = gp_Vec(large, small).Dot(axis);
            const double offset = gp_Vec(large, small).Dot(radial);
            const double finish = gp_Vec(small, cap).Dot(axis);
            constexpr double radius = 0.00127, bore = 0.009779;
            constexpr int intervals = 32768;
            double integral = 0;
            for (int i = 0; i <= intervals; ++i) {
                const double u = -kPi / 2 + (kPi / 2) * i / intervals;
                const double q = offset + radius * std::cos(u);
                const double start = -axial + std::sqrt(std::max(0.0, (bore - q) * (bore + q)));
                integral += (i == 0 || i == intervals ? 1 : i % 2 ? 4 : 2) * (finish - start);
            }
            const double expected = radius * integral * (kPi / 2) / intervals / 3;
            double area = 0;
            int walls = 0;
            if (r.ok) for (TopExp_Explorer f(r.shape, TopAbs_FACE); f.More(); f.Next()) {
                const BRepAdaptor_Surface surface(TopoDS::Face(f.Current()));
                if (surface.GetType() != GeomAbs_Cylinder ||
                    std::fabs(surface.Cylinder().Radius() - radius) > 1e-12 ||
                    gp_Lin(surface.Cylinder().Axis()).Distance(small) > 1e-10) continue;
                area += areaOf(f.Current());
                ++walls;
            }
            std::printf("  part02: стенка %.12g, по уравнениям цилиндров %.12g\n", area, expected);
            check(walls == 1 && std::fabs(area - expected) <= 1e-8 * expected,
                  "part02: площадь стенки у внутреннего касания по независимой формуле");
        }
    }

    // The NIST MTC cover: SAT against its SLDPRT through the Parasolid reader.
    if (!QFileInfo(mtc + "/nist_mtc_crada_cover_rev-B.SAT").exists()) {
        std::printf("SKIP крышка NIST MTC не найдена (%s)\n", mtc.toUtf8().constData());
    } else {
        kernel::OcctKernel kernel;
        gui::AcisSatResult result;
        QString error;
        const bool ok = gui::readAcisSatFile(mtc + "/nist_mtc_crada_cover_rev-B.SAT", kernel, result, error);
        kernel::ShapeHandle part;
        QString partError;
        const bool built = gui::readSolidWorksAnalyticPart(mtc + "/nist_mtc_crada_cover_rev-B.SLDPRT", kernel, part, partError);
        if (!ok || !built) {
            check(false, "крышка MTC: SAT и SLDPRT прочитаны — " + error.toStdString() + " " + partError.toStdString());
        } else {
            const TopoDS_Shape& a = *kernel.findShape(result.solids.front().shape);
            const TopoDS_Shape& b = *kernel.findShape(part);
            const double bound = 1e-8 * areaOf(a);
            std::printf("  крышка MTC: SAT %.12g, SLDPRT %.12g м3, разница %.3g (граница %.3g)\n", volumeOf(a), volumeOf(b), volumeOf(a) - volumeOf(b), bound);
            check(result.millimetresPerUnit == 1.0 && std::fabs(volumeOf(a) - volumeOf(b)) <= bound,
                  "крышка MTC (SOLIDWORKS, ACIS 22): объём как у SLDPRT в пределах 1e-8 м × площадь, единицы — мм");
        }
    }
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
