// Real files from other CAD systems through the CADNext readers (CADNEXT_SAMPLES_DIR; what each file
// is and where it comes from: SOURCES.txt there). Skipped with code 77 without it, never passed.
//
// Each file has an expected outcome: read in full, built into an exact solid, or refused with a
// stated reason. The refusals are today's limits, listed so that a change in them — better or worse —
// is seen and the table updated on purpose.
//
// Criteria, fixed before the run:
//   - A decoder that reaches the terminator with every link valid has read the file: a wrong field in a
//     node layout derails the stream long before that (the helical forms showed it twice).
//   - A NIST SOLIDWORKS part and a NIST STEP of the same model agree in volume to 1e-9 relative: both
//     are exact, and OCCT integrates the same faces. Which STEP is the same model is not assumed; the
//     pairs checked here agreed to 1e-11 when first compared, which no two revisions do. Pairs that
//     do not agree are printed with their gap and stay unexplained, not passed.
//   - Rolling-ball blends (XT BLENDED_EDGE) have no closed form; CADNext builds them as rational
//     B-splines within 1e-6 m of their definition (the bound chosen for the approximation). Checked
//     twice: the kernel's own measure, and independently here — a point P of a blend face with unit
//     normal n puts the ball's centre at P ± r·n, which must be r from both neighbouring faces'
//     surfaces (OCCT normals and projections, radius from the XT) — or, for a blend of XT type 'E', r
//     from one surface and from a sharp edge nearby (a line, circle or ellipse: a curve from the file,
//     never one the blend construction made). The same check on the NIST STEP is
//     printed, not checked: SOLIDWORKS writes blends to STEP within about 1e-5 m of the definition
//     (measured), so the STEP is no reference for them at 1e-6 — nor are its volumes: the same STEP
//     reads to volumes 1.6 % apart in two OCCT readers (ctc_02), and ftc_07/ftc_10 differ from their
//     SLDPRT away from the blends (hole positions, pocket corners).
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/gui/AssemblyStepExchange.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeDwgImport.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeKompasGeometry.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/kernel/OcctKernel.hpp"


#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QSet>
#include <QTemporaryDir>

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepBndLib.hxx>
#include <BRepGProp.hxx>
#include <Bnd_Box.hxx>
#include <Extrema_ExtPC.hxx>
#include <GProp_GProps.hxx>
#include <BRepClass_FaceClassifier.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <GeomAPI_ProjectPointOnSurf.hxx>
#include <Geom_Surface.hxx>
#include <ShapeAnalysis_Surface.hxx>
#include <Standard_Failure.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_ListIteratorOfListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Pnt2d.hxx>

#include <algorithm>
#include <cmath>
#include <limits>
#include <cstdio>
#include <functional>
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

std::string text(const QString& s) { return s.toStdString(); }

// The partition of a SOLIDWORKS part decoded to its terminator.
bool partitionDecodes(const QString& path, QString& error) {
    std::vector<SolidWorksBodyStream> streams;
    if (!readSolidWorksPartBodyStreams(path, streams, error)) return false;
    for (const auto& stream : streams) {
        if (stream.kind != QLatin1String("partition")) continue;
        ParasolidXtTopology topology;
        return readParasolidXtTopology(stream.parasolid, topology, error);
    }
    error = QStringLiteral("нет раздела partition");
    return false;
}

void solidWorksAssembly(const QString& root) {
    const QDir folder(QDir(root).filePath("nist/NIST-MTC-Assembly/SolidWorks"));
    const QString assembly = folder.filePath("nist_mtc_crada_assembly_rev-D.SLDASM");
    std::vector<SolidWorksAssemblyComponent> components;
    QString error;
    const bool read = readSolidWorksAssemblyComponents(assembly, components, error);
    QSet<QString> parts;
    bool present = true, rigid = true;
    for (auto component : components) {
        component.sourcePath.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString name = QFileInfo(component.sourcePath).fileName();
        parts.insert(name);
        present = present && QFileInfo::exists(folder.filePath(name));
        rigid = rigid && !component.virtualComponent && component.transform[15] == 1.0;
    }
    check(read && components.size() == 36 && parts.size() == 8 && present && rigid,
          "MTC (SOLIDWORKS 2017): 36 компонентов на 8 деталей, все детали рядом, матрицы жёсткие");

    // Opened as a CADNext assembly: one .cadnext per distinct part, one occurrence per component, each
    // placed where the SLDASM matrix puts it — the origin and the unit axes carried to 1e-12 m (matrix
    // to quaternion to .cadasm text and back is rounding only, ~1e-16; a wrong axis or sign is mm).
    {
        QTemporaryDir folder;
        AssemblyExchangeReport report;
        const auto top = importSolidWorksAsAssembly(assembly.toStdString(), QDir(folder.path()).filePath("MTC").toStdString(), report);
        const auto loaded = top.isOk() ? assembly::AssemblySerializer::loadFromFile(top.value())
                                       : cadnext::Result<assembly::AssemblyDocument>::fail({ErrorCode::SerializationFailed, "no import"});
        std::set<std::string> files;
        double worst = 0.0;
        if (loaded.isOk() && loaded.value().components().size() == components.size()) {
            for (std::size_t i = 0; i < components.size(); ++i) {
                const auto& placed = loaded.value().components()[i];
                files.insert(placed.source.filePath);
                const auto& m = components[i].transform;
                for (const Vector3 p : {Vector3{0, 0, 0}, Vector3{1, 0, 0}, Vector3{0, 1, 0}, Vector3{0, 0, 1}}) {
                    const Vector3 q = placed.placement.apply(p);
                    const Vector3 expected{m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12], m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                                           m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14]};
                    worst = std::max(worst, std::hypot(q.x - expected.x, q.y - expected.y, q.z - expected.z));
                }
            }
        }
        std::printf("  MTC как сборка CADNext: %d деталей, %d вхождений, положения до %.3g м%s\n", report.parts, report.occurrences, worst,
                    top.isOk() ? "" : (" — " + top.error().message).c_str());
        check(loaded.isOk() && report.parts == 8 && report.occurrences == 36 && files.size() == 8 && worst <= 1e-12,
              "MTC (SOLIDWORKS 2017) открывается как сборка CADNext: 8 деталей, 36 вхождений, положения по матрицам SLDASM");
    }
    // One SLDPRT, as «Вставить деталь» takes it: one part, placed exactly where it is (so the part
    // itself goes in, not an assembly around it).
    {
        QTemporaryDir folder;
        AssemblyExchangeReport report;
        const QString plate = QFileInfo(assembly).dir().filePath("nist_mtc_crada_plate_rev-A.SLDPRT");
        const auto top = importSolidWorksAsAssembly(plate.toStdString(), QDir(folder.path()).filePath("plate").toStdString(), report);
        const auto loaded = top.isOk() ? assembly::AssemblySerializer::loadFromFile(top.value())
                                       : cadnext::Result<assembly::AssemblyDocument>::fail({ErrorCode::SerializationFailed, "no import"});
        bool identity = false;
        if (loaded.isOk() && loaded.value().components().size() == 1) {
            const auto& at = loaded.value().components().front().placement;
            identity = at.translation.x == 0.0 && at.translation.y == 0.0 && at.translation.z == 0.0 && at.rotation.w == 1.0 &&
                       at.rotation.x == 0.0 && at.rotation.y == 0.0 && at.rotation.z == 0.0;
        }
        check(top.isOk() && report.parts == 1 && report.occurrences == 1 && identity,
              "одна деталь SLDPRT переводится в файлы CADNext: одна деталь, одно вхождение на своём месте" +
                  (top.isOk() ? std::string() : " — " + top.error().message));
    }

    // Every part decodes in full; what the builder makes of each is the table below.
    struct Expectation {
        const char* file;
        bool builds;
        const char* reason;
    };
    const Expectation expected[] = {
        {"nist_mtc_crada_polycarb-window.SLDPRT", true, ""},
        {"nist_mtc_crada_box_rev-D.SLDPRT", true, ""},              // 'E' blends, tolerant SP-curve edges
        {"nist_mtc_crada_cover_rev-B.SLDPRT", true, ""},            // 52 swept faces, 4 apple tori
        {"nist_mtc_crada_plate_rev-A.SLDPRT", true, ""},            // 120 swept faces
        // Threads: intersections with helical B-spline surfaces built from their XT charts (OCCT's
        // intersection misses the vertices), root faces winding round a cylinder held one per turn.
        {"90591A141_ZINC PLATED STEEL HEX NUT.SLDPRT", true, ""},
        {"91274A118_COATED ALLOY STEEL SOCKET HEAD CAP SCREW.SLDPRT", true, ""},
        {"91274A141_COATED ALLOY STEEL SOCKET HEAD CAP SCREW.SLDPRT", true, ""},
        {"91304A112_BLUE FLAT-HEAD SOCKET CAP SCREW.SLDPRT", true, ""},
    };
    for (const Expectation& e : expected) {
        const QString path = folder.filePath(e.file);
        QString decodeError;
        check(partitionDecodes(path, decodeError), std::string(e.file) + ": граф XT прочитан до терминатора" +
                                                        (decodeError.isEmpty() ? "" : " — " + text(decodeError)));
        kernel::OcctKernel kernel;
        kernel::ShapeHandle shape;
        QString buildError;
        const bool built = readSolidWorksAnalyticPart(path, kernel, shape, buildError);
        if (built) std::printf("  %s: V %.12g m3\n", e.file, kernel.volumeProperties(shape).value().volumeM3);
        else std::printf("  %s: %s\n", e.file, qPrintable(buildError));
        check(built == e.builds && (built ? kernel.isShapeValid(shape) : buildError.contains(QString::fromUtf8(e.reason))),
              std::string(e.file) + (e.builds ? ": точное тело" : ": отказ построителя с причиной"));
    }
}

// The same MTC design as NX parts: the Parasolid partition NX keeps in each .prt (after its
// **END_OF_HEADER, zlib-compressed), extracted to xt-nx/ (SOURCES.txt). A different writer, a later
// remodel (2021): volumes are compared, not required equal.
void nxParts(const QString& root) {
    struct Expectation {
        const char* file;
        bool builds;
        const char* reason;
    };
    const Expectation expected[] = {
        {"NIST mtc crada polycarb.x_b", true, ""},
        {"NIST mtc crada cover.x_b", true, ""},
        {"NIST mtc crada plate.x_b", true, ""},
        {"NIST mtc crada box.x_b", true, ""},                       // tolerant SP-curve edges
        {"90591A141 HEX NUT.x_b", true, ""},                        // threads, as the SLDPRT's
        {"91274A118 SHCS.x_b", true, ""},
        {"91274A141 SHCS.x_b", true, ""},
        {"91304A112 FHSCS.x_b", true, ""},
    };
    for (const Expectation& e : expected) {
        const QString path = QDir(QDir(root).filePath("xt-nx")).filePath(e.file);
        QFile file(path);
        ParasolidXtTopology topology;
        QString error;
        const bool decoded = file.open(QIODevice::ReadOnly) && readParasolidXtFile(file.readAll(), topology, error);
        check(decoded, std::string("NX ") + e.file + ": граф XT (Parasolid 33, NX) прочитан до терминатора");
        kernel::OcctKernel kernel;
        const auto product = readParasolidXtProduct(kernel, path.toStdString());
        if (product.isOk())
            std::printf("  NX %s: V %.12g m3\n", e.file, kernel.volumeProperties(product.value().parts[0].shape).value().volumeM3);
        else
            std::printf("  NX %s: %s\n", e.file, product.error().message.c_str());
        check(product.isOk() == e.builds && (e.builds || product.error().message.find(e.reason) != std::string::npos),
              std::string("NX ") + e.file + (e.builds ? ": точное тело" : ": отказ построителя с причиной"));
    }
}

void nistAgainstStep(const QString& root, const QString& sldprtDirectory) {
    const QDir steps(QDir(root).filePath("nist/NIST-PMI-STEP-Files"));
    struct Pair {
        const char* part;
        const char* step;
        bool same; // agreed to 1e-11 when first compared
    };
    const Pair pairs[] = {
        {"nist_ftc_06_asme1_rd_sw1802.SLDPRT", "AP203 geometry only/nist_ftc_06_asme1_rd.stp", true},
        {"nist_ftc_08_asme1_rc_sw1802.SLDPRT", "nist_ftc_08_asme1_ap242-e2.stp", true},
        {"nist_ftc_09_asme1_rd_sw1802.SLDPRT", "AP203 geometry only/nist_ftc_09_asme1_rd.stp", true},
        {"nist_ctc_01_asme1_rd_sw1802.SLDPRT", "AP203 geometry only/nist_ctc_01_asme1_rd.stp", false},
        {"nist_ctc_03_asme1_rc_sw1802.SLDPRT", "AP203 geometry only/nist_ctc_03_asme1_rc.stp", false},
        {"nist_ctc_04_asme1_rd_sw1802.SLDPRT", "AP203 geometry only/nist_ctc_04_asme1_rd.stp", false},
        {"nist_ftc_11_asme1_rb_sw1802.SLDPRT", "AP203 geometry only/nist_ftc_11_asme1_rb.stp", false},
    };
    for (const Pair& p : pairs) {
        kernel::OcctKernel kernel;
        kernel::ShapeHandle part;
        QString error;
        if (!readSolidWorksAnalyticPart(QDir(sldprtDirectory).filePath(p.part), kernel, part, error)) {
            check(false, std::string(p.part) + ": построена — " + text(error));
            continue;
        }
        const auto step = kernel.importExchangeFile(steps.filePath(p.step).toStdString());
        if (!step.isOk()) {
            check(false, std::string(p.step) + ": прочитан");
            continue;
        }
        const double a = kernel.volumeProperties(part).value().volumeM3;
        const double b = kernel.volumeProperties(step.value()).value().volumeM3;
        const double gap = std::fabs(a - b) / b;
        std::printf("  %s против %s: %.12g и %.12g м3, расхождение %.2g\n", p.part, p.step, a, b, gap);
        if (p.same) check(gap <= 1e-9, std::string(p.part) + ": объём совпадает с эталоном NIST до 1e-9");
        else std::printf("  (не объяснено: другая ревизия или дефект построителя — не проверено)\n");
    }
}

// The independent check of blend faces (see the header): every B-spline face of `shape` that behaves as a
// rolling-ball blend of one of `radii` between two of its neighbours — or between a neighbour and a
// sharp edge next to it — and how far its samples are from behaving exactly so.
struct BallCheck {
    int faces = 0;
    int alongEdges = 0; // of them, balls touching an edge
    double worst = 0.0;
};

double distanceToSurface(const gp_Pnt& p, const Handle(Geom_Surface)& surface) {
    double best = std::numeric_limits<double>::infinity();
    try {
        const GeomAPI_ProjectPointOnSurf projection(p, surface);
        if (projection.NbPoints()) best = projection.LowerDistance();
        // Both searches return true points of the surface; the nearer is kept (OCCT's projection alone
        // has returned a domain bound, see OcctKernel's trimming).
        ShapeAnalysis_Surface analysis(surface);
        const gp_Pnt2d uv = analysis.ValueOfUV(p, 1e-10);
        best = std::min(best, surface->Value(uv.X(), uv.Y()).Distance(p));
    } catch (const Standard_Failure&) {
    }
    return best;
}

// Distance to an edge's curve within its range, its ends included.
double distanceToEdge(const gp_Pnt& p, const TopoDS_Edge& edge) {
    double best = std::numeric_limits<double>::infinity();
    try {
        const BRepAdaptor_Curve curve(edge);
        best = std::min(p.Distance(curve.Value(curve.FirstParameter())), p.Distance(curve.Value(curve.LastParameter())));
        const Extrema_ExtPC extrema(p, curve);
        if (extrema.IsDone())
            for (int i = 1; i <= extrema.NbExt(); ++i) best = std::min(best, std::sqrt(extrema.SquareDistance(i)));
    } catch (const Standard_Failure&) {
    }
    return best;
}

BallCheck ballCheck(const TopoDS_Shape& shape, const std::vector<double>& radii) {
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    BallCheck result;
    for (TopExp_Explorer it(shape, TopAbs_FACE); it.More(); it.Next()) {
        const TopoDS_Face face = TopoDS::Face(it.Current());
        const BRepAdaptor_Surface surface(face);
        if (surface.GetType() != GeomAbs_BSplineSurface) continue;
        std::vector<Handle(Geom_Surface)> neighbours;
        // For a ball rolling along a sharp edge (XT type 'E'): the edges of this face and of its
        // neighbours, one of which is that edge. Lines, circles and ellipses only — curves taken from the
        // file; the blend construction makes B-spline edges, which would be no independent support.
        std::vector<TopoDS_Edge> edges;
        const auto addEdges = [&](const TopoDS_Shape& of) {
            for (TopExp_Explorer e(of, TopAbs_EDGE); e.More(); e.Next()) {
                const TopoDS_Edge edge = TopoDS::Edge(e.Current());
                if (BRep_Tool::Degenerated(edge) ||
                    std::any_of(edges.begin(), edges.end(), [&](const TopoDS_Edge& known) { return known.IsSame(edge); }))
                    continue;
                const GeomAbs_CurveType type = BRepAdaptor_Curve(edge).GetType();
                if (type == GeomAbs_Line || type == GeomAbs_Circle || type == GeomAbs_Ellipse) edges.push_back(edge);
            }
        };
        addEdges(face);
        for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next())
            for (TopTools_ListIteratorOfListOfShape f(edgeFaces.FindFromKey(e.Current())); f.More(); f.Next()) {
                if (f.Value().IsSame(face)) continue;
                addEdges(f.Value());
                const Handle(Geom_Surface) g = BRep_Tool::Surface(TopoDS::Face(f.Value()));
                if (std::none_of(neighbours.begin(), neighbours.end(), [&](const auto& n) { return n == g; }))
                    neighbours.push_back(g);
            }
        double u0, u1, v0, v1;
        BRepTools::UVBounds(face, u0, u1, v0, v1);
        std::vector<std::pair<gp_Pnt, gp_Vec>> samples;
        for (int i = 0; i <= 24; ++i)
            for (int j = 0; j <= 12; ++j) {
                const double u = u0 + (u1 - u0) * (0.02 + 0.96 * i / 24.0), v = v0 + (v1 - v0) * (0.02 + 0.96 * j / 12.0);
                if (BRepClass_FaceClassifier(face, gp_Pnt2d(u, v), 1e-9).State() != TopAbs_IN) continue;
                gp_Pnt p;
                gp_Vec du, dv;
                surface.D1(u, v, p, du, dv);
                const gp_Vec n = du.Crossed(dv);
                if (n.Magnitude() > 1e-300) samples.push_back({p, n.Normalized()});
            }
        if (samples.empty() || neighbours.empty()) continue;
        // A support by index: a neighbouring surface, then an edge.
        const auto distance = [&](std::size_t support, const gp_Pnt& c) {
            return support < neighbours.size() ? distanceToSurface(c, neighbours[support])
                                               : distanceToEdge(c, edges[support - neighbours.size()]);
        };
        const auto error = [&](const std::pair<gp_Pnt, gp_Vec>& s, double r, int side, std::size_t a, std::size_t b) {
            const gp_Pnt c = s.first.Translated(s.second * (side * r));
            return std::max(std::fabs(distance(a, c) - r), std::fabs(distance(b, c) - r));
        };
        // Radius, side and pair of supports (a surface, and a surface or an edge): those that fit five
        // probes spread over the face best, by their worst probe. One probe is not enough: among dozens
        // of edges one fits a single point of almost any face, and near an edge a ball touching it may
        // also come within 2e-5 m of the surface the edge bounds (NX box). The middle probe filters.
        const std::size_t supports = neighbours.size() + edges.size();
        const std::size_t probes[] = {samples.size() / 2, 0, samples.size() / 4, 3 * samples.size() / 4, samples.size() - 1};
        double fit = std::numeric_limits<double>::infinity(), r = 0;
        int side = 1;
        std::size_t a = 0, b = 1;
        for (double radius : radii)
            for (int s = -1; s <= 1; s += 2) {
                // Distances from each probe's centre to each support, computed when first needed.
                std::vector<double> known(std::size(probes) * supports, std::numeric_limits<double>::quiet_NaN());
                const auto gapOf = [&](std::size_t probe, std::size_t support) {
                    double& d = known[probe * supports + support];
                    if (std::isnan(d)) {
                        const auto& sample = samples[probes[probe]];
                        d = std::fabs(distance(support, sample.first.Translated(sample.second * (s * radius))) - radius);
                    }
                    return d;
                };
                for (std::size_t i = 0; i < neighbours.size(); ++i)
                    for (std::size_t j = i + 1; j < supports; ++j) {
                        double e = std::max(gapOf(0, i), gapOf(0, j));
                        if (!(e < 1e-4)) continue;
                        for (std::size_t probe = 1; probe < std::size(probes) && e < fit; ++probe)
                            e = std::max({e, gapOf(probe, i), gapOf(probe, j)});
                        if (e < fit) {
                            fit = e;
                            r = radius;
                            side = s;
                            a = i;
                            b = j;
                        }
                    }
            }
        if (!(fit < 1e-4)) continue; // a B-spline face that is no blend of these radii
        ++result.faces;
        result.alongEdges += b >= neighbours.size();
        for (const auto& s : samples) result.worst = std::max(result.worst, error(s, r, side, a, b));
    }
    return result;
}

void blends(const QString& root, const QString& sldprtDirectory) {
    const QDir steps(QDir(root).filePath("nist/NIST-PMI-STEP-Files/AP203 geometry only"));
    const char* parts[][2] = {
        {"nist_ftc_10_asme1_rb_sw1802.SLDPRT", "nist_ftc_10_asme1_rb.stp"},
        {"nist_ctc_05_asme1_rd_sw1802.SLDPRT", "nist_ctc_05_asme1_rd.stp"},
        {"nist_ctc_02_asme1_rc_sw1802.SLDPRT", "nist_ctc_02_asme1_rc.stp"},
        {"nist_ftc_07_asme1_rd_sw1802.SLDPRT", "nist_ftc_07_asme1_rd.stp"},
    };
    for (const auto& pair : parts) {
        const QString path = QDir(sldprtDirectory).filePath(pair[0]);
        // The blend radii, from the part's own XT.
        std::vector<SolidWorksBodyStream> streams;
        QString error;
        std::set<double> radii;
        if (readSolidWorksPartBodyStreams(path, streams, error))
            for (const auto& stream : streams) {
                ParasolidXtTopology topology;
                if (stream.kind != QLatin1String("partition") || !readParasolidXtTopology(stream.parasolid, topology, error))
                    continue;
                for (const auto& g : topology.analyticGeometry)
                    if (g.type == 56 && g.realArrays.value("range").size() == 2)
                        radii.insert(std::fabs(g.realArrays.value("range")[0]));
            }
        kernel::OcctKernel kernel;
        kernel::ShapeHandle shape;
        ParasolidXtBuildReport report;
        const bool built = readSolidWorksAnalyticPart(path, kernel, shape, error, &report);
        check(built && kernel.isShapeValid(shape) && !report.approximated.empty(),
              std::string(pair[0]) + ": тело со скруглениями построено" + (built ? "" : " — " + text(error)));
        if (!built) continue;
        double deviation = 0, gap = 0;
        for (const auto& face : report.approximated) {
            deviation = std::max(deviation, face.deviation);
            gap = std::max(gap, face.contactGap);
        }
        const std::vector<double> r(radii.begin(), radii.end());
        const BallCheck ours = ballCheck(*kernel.findShape(shape), r);
        std::printf("  %s: %zu скруглений, ядро: отклонение ≤ %.3g м, зазор касания в файле ≤ %.3g м; "
                    "проверка шаром: %d граней, ≤ %.3g м\n",
                    pair[0], report.approximated.size(), deviation, gap, ours.faces, ours.worst);
        check(deviation <= 1e-6, std::string(pair[0]) + ": ядро держит скругления в 1e-6 м от определения");
        check(ours.faces == int(report.approximated.size()) && ours.worst <= 1e-6,
              std::string(pair[0]) + ": независимая проверка шаром — все скругления в 1e-6 м от определения");
        const auto step = kernel.importExchangeFile(steps.filePath(pair[1]).toStdString());
        if (step.isOk()) {
            const BallCheck theirs = ballCheck(*kernel.findShape(step.value()), r);
            std::printf("  %s (STEP SOLIDWORKS): %d граней скруглений, проверка шаром ≤ %.3g м (не проверяется)\n", pair[1],
                        theirs.faces, theirs.worst);
        }
    }
}

// Blends of XT type 'E': a ball rolling on a face and along a sharp edge (its other support a blend of
// zero range whose spine is that edge). The MTC box from both writers and Bell_Crank.x_b, by the same two
// checks and the same bound as the blends above; the independent one finds the edge among the blend
// face's and its neighbours' edges.
void edgeBlends(const QString& root) {
    const QString parts[] = {
        QDir(QDir(root).filePath("nist/NIST-MTC-Assembly/SolidWorks")).filePath("nist_mtc_crada_box_rev-D.SLDPRT"),
        QDir(QDir(root).filePath("xt-nx")).filePath("NIST mtc crada box.x_b"),
        QDir(QDir(root).filePath("xt")).filePath("Bell_Crank.x_b"),
    };
    for (const QString& path : parts) {
        const std::string name = QFileInfo(path).fileName().toStdString();
        const bool sldprt = path.endsWith(QLatin1String(".SLDPRT"), Qt::CaseInsensitive);
        std::vector<ParasolidXtTopology> topologies;
        QString error;
        if (sldprt) {
            std::vector<SolidWorksBodyStream> streams;
            if (readSolidWorksPartBodyStreams(path, streams, error))
                for (const auto& stream : streams) {
                    ParasolidXtTopology topology;
                    if (stream.kind == QLatin1String("partition") && readParasolidXtTopology(stream.parasolid, topology, error))
                        topologies.push_back(std::move(topology));
                }
        } else {
            QFile file(path);
            ParasolidXtTopology topology;
            if (file.open(QIODevice::ReadOnly) && readParasolidXtFile(file.readAll(), topology, error))
                topologies.push_back(std::move(topology));
        }
        // The radii, and how many blends of type 'E' the file has.
        std::set<double> radii;
        int typeE = 0;
        for (const auto& topology : topologies)
            for (const auto& g : topology.analyticGeometry) {
                if (g.type != 56 || g.realArrays.value("range").size() != 2) continue;
                if (const double radius = std::fabs(g.realArrays.value("range")[0]); radius > 0) radii.insert(radius);
                typeE += g.bytes.value("blend_type") == 'E';
            }
        kernel::OcctKernel kernel;
        kernel::ShapeHandle shape;
        ParasolidXtBuildReport report;
        const bool built = sldprt ? readSolidWorksAnalyticPart(path, kernel, shape, error, &report)
                                  : readParasolidXtAnalyticFile(path, kernel, shape, error, &report);
        check(built && kernel.isShapeValid(shape) && typeE > 0 && !report.approximated.empty(),
              name + ": тело со скруглениями типа «E» построено" + (built ? "" : " — " + text(error)));
        if (!built) continue;
        double deviation = 0;
        for (const auto& face : report.approximated) deviation = std::max(deviation, face.deviation);
        const BallCheck ours = ballCheck(*kernel.findShape(shape), std::vector<double>(radii.begin(), radii.end()));
        std::printf("  %s: %d скруглений типа «E» в файле, %zu граней приближено, ядро: отклонение ≤ %.3g м; "
                    "проверка шаром: %d граней (из них у ребра %d), ≤ %.3g м\n",
                    name.c_str(), typeE, report.approximated.size(), deviation, ours.faces, ours.alongEdges, ours.worst);
        check(deviation <= 1e-6, name + ": ядро держит скругления в 1e-6 м от определения");
        check(ours.faces == int(report.approximated.size()) && ours.alongEdges > 0 && ours.worst <= 1e-6,
              name + ": независимая проверка шаром (шар касается грани и ребра) — все скругления в 1e-6 м от определения");
    }
}

// Threads checked against another writer: the flat-head screw 91304A112 from SOLIDWORKS and from NX
// is one model in one frame (the same bounding box), apart from its hex socket, turned 30 degrees
// (measured: the whole difference lies within 0.2 mm of the head's top). Below 1 mm under the top —
// all of the thread — the two built solids must agree: their difference there at most 1e-12 m3
// (1e-3 mm3). Boolean noise on coincident exact faces is about 1e-20 m3 (the MTC box); one turn of a
// root or flank face wrongly chosen is of the order of 1e-9 m3.
void threadsAgainstNx(const QString& root) {
    const QString sw = QDir(QDir(root).filePath("nist/NIST-MTC-Assembly/SolidWorks"))
                           .filePath("91304A112_BLUE FLAT-HEAD SOCKET CAP SCREW.SLDPRT");
    const QString nx = QDir(QDir(root).filePath("xt-nx")).filePath("91304A112 FHSCS.x_b");
    kernel::OcctKernel kernel;
    kernel::ShapeHandle ours;
    QString error;
    const auto theirs = readParasolidXtProduct(kernel, nx.toStdString());
    if (!readSolidWorksAnalyticPart(sw, kernel, ours, error) || !theirs.isOk() || theirs.value().parts.empty()) {
        check(false, "91304A112: оба тела построены (SOLIDWORKS и NX)");
        return;
    }
    const TopoDS_Shape a = *kernel.findShape(ours), b = *kernel.findShape(theirs.value().parts[0].shape);
    Bnd_Box box;
    BRepBndLib::Add(a, box);
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    const double top = z1 - box.GetGap();
    double below = 0, above = 0;
    for (const TopoDS_Shape& difference : {BRepAlgoAPI_Cut(a, b).Shape(), BRepAlgoAPI_Cut(b, a).Shape()})
        for (TopExp_Explorer it(difference, TopAbs_SOLID); it.More(); it.Next()) {
            GProp_GProps properties;
            BRepGProp::VolumeProperties(it.Current(), properties);
            Bnd_Box pieceBox;
            BRepBndLib::Add(it.Current(), pieceBox);
            double p0, q0, r0, p1, q1, r1;
            pieceBox.Get(p0, q0, r0, p1, q1, r1);
            (r1 < top - 1e-3 ? below : above) += std::fabs(properties.Mass());
        }
    std::printf("  91304A112 SOLIDWORKS против NX: разность у головки %.3g м3, ниже 1 мм от торца (резьба) %.3g м3\n",
                above, below);
    check(below <= 1e-12, "91304A112: резьба из SOLIDWORKS и из NX совпадает (разность ниже головки ≤ 1e-12 м3)");
}

void parasolid(const QString& root) {
    const QDir xt(QDir(root).filePath("xt"));
    {
        QFile file(xt.filePath("Maslow Frame.x_t"));
        file.open(QIODevice::ReadOnly);
        ParasolidXtTopology topology;
        QString error;
        const bool decoded = readParasolidXtFile(file.readAll(), topology, error);
        std::printf("  Maslow Frame: %zu сборок, %zu экземпляров, %zu тел\n", topology.assemblies.size(), topology.instances.size(),
                    topology.bodies.size());
        check(decoded && !topology.assemblies.empty() && topology.instances.size() > 1,
              "Maslow Frame (Onshape, Parasolid 29): сборка прочитана до терминатора");
        kernel::OcctKernel kernel;
        const auto product = readParasolidXtProduct(kernel, file.fileName().toStdString());
        std::printf("  Maslow Frame: %s\n", product.isOk() ? "тела построены" : product.error().message.c_str());
        // Its intersection edges OCCT's intersection did not follow are built from their charts.
        bool valid = product.isOk() && !product.value().parts.empty();
        for (const auto& part : valid ? product.value().parts : std::vector<kernel::ProductPart>{}) {
            valid = valid && kernel.isShapeValid(part.shape);
            std::printf("  Maslow Frame, %s: V %.12g m3\n", part.name.c_str(), kernel.volumeProperties(part.shape).value().volumeM3);
        }
        check(valid, "Maslow Frame: точные тела");
    }
    {
        kernel::OcctKernel kernel;
        const auto product = readParasolidXtProduct(kernel, xt.filePath("cylinder-sw2024.x_t").toStdString());
        check(product.isOk() && product.value().parts.size() == 1 && kernel.isShapeValid(product.value().parts[0].shape),
              "cylinder.x_t (SOLIDWORKS 2024, Parasolid 35): точное тело");
    }
    for (const QFileInfo& file : QDir(QDir(root).filePath("xt-bentley")).entryInfoList({"*.x_t"}, QDir::Files, QDir::Name)) {
        kernel::OcctKernel kernel;
        const auto product = readParasolidXtProduct(kernel, file.absoluteFilePath().toStdString());
        check(!product.isOk() && product.error().message.find("до V14") != std::string::npos,
              "MicroStation " + text(file.fileName()) + " (Parasolid 9): отказ — схема до V14 не описана в файле");
    }
}

void kompas(const QString& root) {
    // The five parts with a STEP twin (checked against it in cadnext_test_kompas_c3d), the parts of the five
    // assemblies (downloaded 2026-09-27, no twin of their own) and the assemblies.
    static const QStringList twinned{"e2b1766ddb7c4ed6a9d65030b639251d.m3d", "Nema Motor 17.m3d", "WYSE.m3d", "sfh551.m3d", "sfh756.m3d"};
    // The six assemblies of KOMPAS-3D v24 (dolganin_SO_SPIDAR300, downloaded 2026-10-02 without their
    // parts): the document's name, and how many distinct component names and files MetaProductInfo holds.
    struct Product { const char* file; const char* name; int names; int externalFiles; };
    // (Seven more assemblies of the same repository, downloaded 2026-10-03, are in its folder more/.)
    static const Product products[] = {{"dolganin_SO_SPIDAR300/Antdroid.a3d", "Antdroid", 5, 5}, {"dolganin_SO_SPIDAR300/Arduino.a3d", "Arduino", 2, 2},
                                       {"dolganin_SO_SPIDAR300/Cuerpo.a3d", "Cuerpo", 8, 8}, {"dolganin_SO_SPIDAR300/Pata.a3d", "Pata", 11, 11},
                                       {"dolganin_SO_SPIDAR300/RaspberryPi_B.a3d", "RaspberryPi_B", 9, 9},
                                       {"dolganin_SO_SPIDAR300/Raspberry_B1.a3d", "Raspberry_B1", 3, 3}};
    int files = 0, metadata = 0, parts = 0, whole = 0, partial = 0, twinnedWhole = 0, assembliesWithout = 0, productsRead = 0;
    QDirIterator it(QDir(root).filePath("kompas"), {"*.m3d", "*.a3d"}, QDir::Files, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString path = it.next();
        ++files;
        KompasModelInfo info;
        QString error;
        const bool described = readKompasModelInfo(path, info, error);
        metadata += described ? 1 : 0;
        for (const Product& product : products)
            if (described && path.endsWith(QLatin1String("/kompas/") + QLatin1String(product.file)))
                productsRead += info.name == QLatin1String(product.name) && info.objects.size() == product.names &&
                                info.externalFiles.size() == product.externalFiles ? 1 : 0;
        kernel::OcctKernel kernel;
        KompasC3dResult solids;
        const bool built = readKompasC3dSolids(path, kernel, solids, error);
        const bool complete = built && !solids.notes.join(' ').contains(QStringLiteral("не построено"));
        if (path.endsWith(".m3d", Qt::CaseInsensitive)) {
            ++parts;
            whole += complete ? 1 : 0;
            partial += built && !complete ? 1 : 0;
            twinnedWhole += complete && twinned.contains(QFileInfo(path).fileName()) ? 1 : 0;
        } else {
            assembliesWithout += built ? 0 : 1;
        }
    }
    std::printf("  КОМПАС: %d файлов, метаданные у %d; деталей %d: целиком %d, частично %d, не построено %d; сборок без своей геометрии %d\n",
                files, metadata, parts, whole, partial, parts - whole - partial, assembliesWithout);
    check(files > 0 && metadata == files, "КОМПАС-3D: контейнер и метаданные всех моделей читаются");
    check(twinnedWhole == 5, "КОМПАС-3D: 5 деталей со STEP-двойником строятся целиком (сверка — cadnext_test_kompas_c3d)");
    check(productsRead == 6, "КОМПАС-3D v24: состав шести сборок читается из MetaProductInfo (имя, компоненты, файлы): " +
                             std::to_string(productsRead) + " из 6");
    check(assembliesWithout == 18, "КОМПАС-3D: в 18 сборках своей геометрии нет — детали во внешних .m3d");
}

// What stands between each real part and an exact solid: its faces on surfaces, and edges on
// curves, of kinds the builder does not construct yet. Printed, not checked — the plan for the builder.
void survey(const QString& root, const QString& nistDirectory) {
    static const QSet<quint16> surfaces{50, 51, 52, 53, 54, 56, 60, 67, 124};
    static const QSet<quint16> curves{30, 31, 32, 38, 133, 134};
    std::map<quint16, int> facesBlocked, edgesBlocked, filesNeeding;
    std::printf("== Чего не хватает построителю\n");
    const auto account = [&](const QString& label, const ParasolidXtTopology& t) {
        std::map<quint16, int> faces, edges;
        for (const auto& f : t.faces) {
            const quint16 type = t.nodeTypes.value(f.surfaceIndex);
            if (!surfaces.contains(type)) ++faces[type];
        }
        for (const auto& e : t.edges) {
            const quint16 type = t.nodeTypes.value(e.curveIndex);
            if (e.curveIndex && !curves.contains(type)) ++edges[type];
        }
        std::string line;
        std::set<quint16> needed;
        for (const auto& [type, n] : faces) {
            line += " поверхность " + std::to_string(type) + "×" + std::to_string(n);
            facesBlocked[type] += n;
            needed.insert(type);
        }
        for (const auto& [type, n] : edges) {
            line += " кривая " + std::to_string(type) + "×" + std::to_string(n);
            edgesBlocked[type] += n;
            needed.insert(type);
        }
        for (quint16 type : needed) ++filesNeeding[type];
        std::printf("  %-58s граней %4zu:%s\n", qPrintable(label.left(58)), t.faces.size(), line.empty() ? " всё поддержано" : line.c_str());
    };
    QStringList parts;
    for (const QFileInfo& f : QDir(nistDirectory).entryInfoList({"*.SLDPRT"}, QDir::Files, QDir::Name)) parts << f.absoluteFilePath();
    for (const QFileInfo& f : QDir(QDir(root).filePath("nist/NIST-MTC-Assembly/SolidWorks")).entryInfoList({"*.SLDPRT"}, QDir::Files, QDir::Name))
        parts << f.absoluteFilePath();
    for (const QString& part : parts) {
        std::vector<SolidWorksBodyStream> streams;
        QString error;
        if (!readSolidWorksPartBodyStreams(part, streams, error)) continue;
        for (const auto& stream : streams) {
            ParasolidXtTopology t;
            if (stream.kind == QLatin1String("partition") && readParasolidXtTopology(stream.parasolid, t, error))
                account(QFileInfo(part).fileName(), t);
        }
    }
    for (const QFileInfo& f : QDir(QDir(root).filePath("xt")).entryInfoList({"*.x_t", "*.x_b"}, QDir::Files, QDir::Name)) {
        QFile file(f.absoluteFilePath());
        file.open(QIODevice::ReadOnly);
        ParasolidXtTopology t;
        QString error;
        if (readParasolidXtFile(file.readAll(), t, error)) account(f.fileName(), t);
    }
    std::printf("  итого по типам (граней / рёбер / деталей, которым тип нужен):\n");
    std::set<quint16> all;
    for (const auto& [type, n] : facesBlocked) all.insert(type);
    for (const auto& [type, n] : edgesBlocked) all.insert(type);
    for (quint16 type : all)
        std::printf("    тип %3u: %4d / %4d / %d\n", type, facesBlocked[type], edgesBlocked[type], filesNeeding[type]);
}

void autocad(const QString& root) {
    // The container reader of AC1032 (AutoCAD 2018) still refuses AC1015 by its version; the objects of
    // R13–R2000 are read by NativeDwgObjects, whose solids are ACIS (cadnext_test_dwg_r2000_files checks
    // them in full). What builds today, the rest with its reason.
    int refused = 0, files = 0, bodies = 0, built = 0;
    std::map<QString, int> reasons;
    for (const QFileInfo& file : QDir(QDir(root).filePath("dwg/blowdryer")).entryInfoList({"*.dwg"}, QDir::Files, QDir::Name)) {
        ++files;
        DwgStructure structure;
        QString error;
        refused += !readDwgStructure(file.absoluteFilePath(), structure, error) && error.contains(QStringLiteral("AC1015")) ? 1 : 0;
        DwgModel model;
        if (!readDwgModel(file.absoluteFilePath(), model, error)) continue;
        for (const DwgModelBody& body : model.bodies) {
            ++bodies;
            kernel::OcctKernel kernel;
            AcisSatResult sat;
            if (readAcisSat(body.acis, kernel, sat, error, nullptr, body.name, body.millimetresPerUnit)) {
                ++built;
            } else {
                const qsizetype quote = error.indexOf(QStringLiteral("«"));
                ++reasons[quote < 0 ? error : error.mid(quote, error.indexOf(QStringLiteral("»"), quote) - quote + 1)];
            }
        }
    }
    check(files == 11 && refused == 11, "DWG AutoCAD 2000 (AC1015): контейнер AC1032 их отклоняет по версии (ожидаемо)");
    check(bodies == 32 && built == 32, "DWG AutoCAD 2000: тел ACIS в моделях " + std::to_string(bodies) + ", построено " + std::to_string(built) +
                                           " (ожидается 32 из 32)");
    for (const auto& [reason, n] : reasons) std::printf("  не построено: %d — %s\n", n, reason.toUtf8().constData());
    int satFiles = 0, satBuilt = 0;
    for (const QFileInfo& file : QDir(QDir(root).filePath("acis/allied-signal")).entryInfoList({"*.sat"}, QDir::Files, QDir::Name)) {
        ++satFiles;
        kernel::OcctKernel kernel;
        AcisSatResult sat;
        QString error;
        satBuilt += readAcisSatFile(file.absoluteFilePath(), kernel, sat, error) ? 1 : 0;
    }
    check(satFiles == 24 && satBuilt == 24, "ACIS SAT (Allied-Signal): построено " + std::to_string(satBuilt) + " из " + std::to_string(satFiles));
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_SAMPLES_DIR");
    if (root.isEmpty()) {
        std::printf("SKIP: CADNEXT_SAMPLES_DIR не задан\n");
        return 77;
    }
    solidWorksAssembly(root);
    nxParts(root);
    edgeBlends(root);
    threadsAgainstNx(root);
    if (const QString nist = qEnvironmentVariable("CADNEXT_TEST_NIST_DIR"); !nist.isEmpty()) {
        nistAgainstStep(root, nist);
        blends(root, nist);
        survey(root, nist);
    } else {
        std::printf("SKIP NIST SLDPRT: CADNEXT_TEST_NIST_DIR не задан\n");
    }
    parasolid(root);
    kompas(root);
    autocad(root);
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
