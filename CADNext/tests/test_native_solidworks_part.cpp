// The blueprint of a SOLIDWORKS part with an imported body (NativeSolidWorksPart) against the samples
// (CADNEXT_TEST_SAMPLES, ~/cadnext-samples by default; sw-imported: parts SOLIDWORKS 2020–2023 made
// from STEP files), then our own part read back.
//
// A stream "matches" when it differs from the blueprint in its slots only, every text slot reading
// the same wherever the document repeats it. The seven fischertechnik parts are of the blueprint's
// version; some of their streams have one list entry more or less (an external reference, a note)
// and so another structure — those are counted, not required. Required: every blueprint stream
// matches in at least three of the seven parts, and each double read agrees with its formula of the
// body's box to 1e-12 m.

#include "cadnext/gui/NativeSolidWorksPart.hpp"
#include "cadnext/gui/NativeSolidWorksConfiguration.hpp"
#include "cadnext/gui/NativeSolidWorksDocument.hpp"
#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/gui/NativeSolidWorksPackage.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"

#include <BRepAdaptor_Curve.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <GProp_PrincipalProps.hxx>
#include <algorithm>
#include <GProp_GProps.hxx>
#include <BRepTools.hxx>
#include <BRepBuilderAPI_MakeVertex.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRep_Builder.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Vertex.hxx>
#include <limits>
#include <BRepTopAdaptor_FClass2d.hxx>
#include <BRep_Tool.hxx>
#include <Geom_SurfaceOfRevolution.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Face.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QTemporaryDir>

#include <cmath>
#include <cstdio>
#include <map>
#include <string>

using namespace cadnext;
using namespace cadnext::gui;

namespace {
int failures = 0;
void check(bool ok, const std::string& what) {
    std::printf("%s: %s\n", ok ? "PASS" : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

bool readPackage(const QString& path, SolidWorksPackage& package) {
    QFile f(path);
    QString error;
    return f.open(QIODevice::ReadOnly) && decodeSolidWorksPackage(f.readAll(), package, error);
}

// The bytes a blueprint stream stands for in a package.
bool streamOf(const SolidWorksPackage& package, const QByteArray& name, QByteArray& bytes) {
    const qsizetype part = name.indexOf('#');
    const QByteArray entry = part < 0 ? name : name.left(part);
    for (const auto& e : package.entries) {
        if (e.name != entry) continue;
        if (part < 0) { bytes = e.data; return true; }
        std::vector<QByteArray> transmits;
        const int index = name.mid(part + 1).toInt();
        if (!decodeSolidWorksPartitionStream(e.data, transmits) || index >= int(transmits.size())) return false;
        bytes = transmits[std::size_t(index)];
        return true;
    }
    return false;
}

bool contains(const QByteArray& data, const QString& text) {
    const QByteArray wide(reinterpret_cast<const char*>(text.utf16()), text.size() * 2);
    return data.contains(text.toUtf8()) || data.contains(wide);
}
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/sw-imported";
    const QList<QByteArray> streams = solidWorksPartBlueprintStreams();
    const QByteArray information = "docProps/ISolidWorksInformation.xml";

    const QFileInfoList parts = QDir(root + "/fischertechnik").entryInfoList({"*.SLDPRT"}, QDir::Files, QDir::Name);
    if (parts.isEmpty()) {
        std::printf("SKIP образцов: нет %s\n", qPrintable(root));
    } else {
        std::map<QByteArray, int> matched;
        int whole = 0, formulas = 0, formulasHeld = 0, bodies = 0, bodiesSame = 0, longBodies = 0, headersSame = 0;
        for (const QFileInfo& part : parts) {
            SolidWorksPackage package;
            if (!readPackage(part.absoluteFilePath(), package)) continue;
            SolidWorksPartValues values;
            int here = 0;
            for (const QByteArray& name : streams) {
                if (name == information) continue; // the blueprint's is an English document's, see below
                QByteArray bytes;
                QString error;
                SolidWorksPartValues bound = values;
                if (streamOf(package, name, bytes) && matchSolidWorksPartStream(name, bytes, bound, error)) {
                    values = bound;
                    ++matched[name];
                    ++here;
                } else if (qEnvironmentVariableIsSet("CADNEXT_TEST_VERBOSE")) {
                    std::printf("    %s %s: %s\n", qPrintable(part.fileName()), name.constData(), qPrintable(error));
                }
            }
            whole += here == streams.size() - 1 ? 1 : 0;
            for (auto it = values.real.constBegin(); it != values.real.constEnd(); ++it) {
                double want = 0;
                ++formulas;
                formulasHeld += solidWorksPartFormula(it.key(), values.boxMin, values.boxMax, want) && std::fabs(want - it.value()) <= 1e-12 ? 1 : 0;
            }
            // The model header is Header2 again; the body's section encodes back to its own bytes.
            QByteArray header, modelHeader, local;
            headersSame += streamOf(package, "Header2", header) && streamOf(package, "Contents/Config-0-ModelHeader", modelHeader) && header == modelHeader ? 1 : 0;
            std::vector<SolidWorksFeatureBodies> features;
            SolidWorksFeatureBodyLayout layout{};
            QString error;
            if (streamOf(package, "Config-0-FeatureBodies/LocalBodies", local) && decodeSolidWorksFeatureBodies(local, features, error, &layout)) {
                QByteArray again;
                ++bodies;
                bodiesSame += encodeSolidWorksFeatureBodies(features, again, error, layout) && again == local ? 1 : 0;
                for (const auto& feature : features)
                    for (const auto& body : feature.bodies) longBodies += body.parasolid.size() > 0x100000 ? 1 : 0;
            }
        }
        int required = 0;
        for (const QByteArray& name : streams) {
            if (name == information) continue;
            std::printf("  %-42s в %d из %d\n", name.constData(), matched[name], int(parts.size()));
            required += matched[name] >= 3 ? 1 : 0;
        }
        check(required == streams.size() - 1, "каждый поток чертежа совпадает с образцами вне слотов не меньше чем в трёх деталях: " +
                                              std::to_string(required) + " из " + std::to_string(streams.size() - 1) + " потоков");
        check(whole >= 3, "деталей, у которых совпали все потоки: " + std::to_string(whole) + " из " + std::to_string(parts.size()));
        check(formulas > 0 && formulasHeld == formulas, "числа габарита и плоскостей следуют из габарита тела (до 1e-12 м): " +
                                                        std::to_string(formulasHeld) + " из " + std::to_string(formulas));
        check(headersSame == parts.size(), "Config-0-ModelHeader повторяет Header2: " + std::to_string(headersSame) + " из " + std::to_string(parts.size()));
        check(bodies == int(parts.size()) && bodiesSame == bodies, "LocalBodies каждой детали читается и кодируется обратно байт в байт: " +
                                                              std::to_string(bodiesSame) + " из " + std::to_string(parts.size()));
        check(longBodies == 1, "среди них тело длиннее 1 МиБ, записанное SOLIDWORKS по частям: " + std::to_string(longBodies));
    }
    // The reader on the ten parts with an imported body: all build, each checked against its own
    // file's body: a valid closed solid with the file's faces, and the file's vertices. A vertex the
    // file has where the body has none must lie on a body edge, and the other way round only on a
    // full circle or a seam: where such an edge starts is OCCT's choice, not geometry.
    {
        struct Imported { const char* file; bool builds; };
        static const Imported imported[] = {
            {"fischertechnik/2022_10_06_17_02_43_0612.stp.SLDPRT", true}, // a 1.2 MiB body; SP-curves met at the edge's very end, triangles at a pole, a split latitude band
            {"fischertechnik/2022_10_06_17_02_43_0644.stp.SLDPRT", true}, // three lemon tori
            {"fischertechnik/2022_10_06_17_04_49_0630.stp.SLDPRT", true},
            {"fischertechnik/2022_10_06_17_04_49_0662.stp.SLDPRT", true},
            {"fischertechnik/2022_10_06_17_04_49_0693.stp.SLDPRT", true},
            {"fischertechnik/2022_10_06_17_04_49_0724.stp.SLDPRT", true},
            {"fischertechnik/2022_10_06_17_04_49_0755.stp.SLDPRT", true},
            {"gem4/RetainingRing.step.SLDPRT", true},
            {"gem4/Shaft.step.SLDPRT", true},                             // a cylinder's loop running down its seam and back
            {"walrus/c-t4132412041-000-a-3d.stp.SLDPRT", true}};          // SOLIDWORKS 2020; a thread's face on two turns of its helix
        int present = 0, asExpected = 0, built = 0, faithful = 0;
        for (const Imported& part : imported) {
            const QString path = root + "/" + part.file;
            if (!QFileInfo::exists(path)) continue;
            ++present;
            kernel::OcctKernel reader;
            kernel::ShapeHandle shape;
            QString error;
            const bool ok = readSolidWorksAnalyticPart(path, reader, shape, error);
            built += ok ? 1 : 0;
            asExpected += ok == part.builds ? 1 : 0;
            if (ok != part.builds) std::printf("  %s: %s\n", part.file, ok ? "построена" : qPrintable(error));
            if (ok) {
                // The file's body: LocalBodies, or (SOLIDWORKS 2020) the record inside ResolvedFeatures.
                SolidWorksPackage package;
                QByteArray transmit;
                if (readPackage(path, package))
                    for (const auto& entry : package.entries) {
                        std::vector<SolidWorksFeatureBodies> stored;
                        QString ignored;
                        if (entry.name.endsWith("/LocalBodies") && decodeSolidWorksFeatureBodies(entry.data, stored, ignored) &&
                            stored.size() == 1 && stored[0].bodies.size() == 1)
                            transmit = stored[0].bodies[0].parasolid;
                        else if (transmit.isEmpty() && entry.name.endsWith("-ResolvedFeatures"))
                            for (const auto& body : findSolidWorksStoredBodies(entry.data)) transmit = body.parasolid;
                    }
                ParasolidXtTopology file;
                QString ignored;
                const TopoDS_Shape* solid = reader.findShape(shape);
                bool same = solid && readParasolidXtTransmitStream(transmit, file, ignored) && BRepCheck_Analyzer(*solid).IsValid();
                int faces = 0;
                TopTools_IndexedDataMapOfShapeListOfShape edgeFaces, vertexEdges;
                if (same) {
                    for (TopExp_Explorer f(*solid, TopAbs_FACE); f.More(); f.Next()) ++faces;
                    TopExp::MapShapesAndAncestors(*solid, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
                    TopExp::MapShapesAndAncestors(*solid, TopAbs_VERTEX, TopAbs_EDGE, vertexEdges);
                    for (int k = 1; same && k <= edgeFaces.Extent(); ++k)
                        same = BRep_Tool::Degenerated(TopoDS::Edge(edgeFaces.FindKey(k))) || edgeFaces(k).Extent() == 2;
                    same = same && faces == int(file.faces.size());
                }
                TopoDS_Compound edges;
                BRep_Builder compound;
                compound.MakeCompound(edges);
                for (int k = 1; same && k <= edgeFaces.Extent(); ++k) compound.Add(edges, edgeFaces.FindKey(k));
                const auto tolerance = [](double t) { return std::max(1e-7, std::isnan(t) ? 0.0 : t); };
                for (std::size_t v = 0; same && v < file.vertices.size(); ++v) {
                    const gp_Pnt at(file.vertices[v].position[0], file.vertices[v].position[1], file.vertices[v].position[2]);
                    double nearest = std::numeric_limits<double>::infinity();
                    for (int k = 1; k <= vertexEdges.Extent(); ++k) nearest = std::min(nearest, at.Distance(BRep_Tool::Pnt(TopoDS::Vertex(vertexEdges.FindKey(k)))));
                    if (nearest > tolerance(file.vertices[v].tolerance))
                        same = BRepExtrema_DistShapeShape(BRepBuilderAPI_MakeVertex(at).Vertex(), edges).Value() <= tolerance(file.vertices[v].tolerance);
                }
                for (int k = 1; same && k <= vertexEdges.Extent(); ++k) {
                    const gp_Pnt at = BRep_Tool::Pnt(TopoDS::Vertex(vertexEdges.FindKey(k)));
                    double nearest = std::numeric_limits<double>::infinity(), allowed = 1e-7;
                    for (const auto& vertex : file.vertices) {
                        const double d = at.Distance(gp_Pnt(vertex.position[0], vertex.position[1], vertex.position[2]));
                        if (d < nearest) { nearest = d; allowed = tolerance(vertex.tolerance); }
                    }
                    if (nearest <= allowed) continue;
                    for (const auto& e : vertexEdges(k)) {
                        const TopoDS_Edge edge = TopoDS::Edge(e);
                        bool seam = false;
                        for (const auto& f : edgeFaces.FindFromKey(edge)) seam = seam || BRep_Tool::IsClosed(edge, TopoDS::Face(f));
                        same = same && (BRep_Tool::IsClosed(edge) || BRep_Tool::Degenerated(edge) || seam);
                    }
                }
                faithful += same ? 1 : 0;
                if (!same) std::printf("  %s: тело не совпадает с телом файла (граней %d из %zu)\n", part.file, faces, file.faces.size());
            }
            if (!ok || !QString::fromLatin1(part.file).contains("0644")) continue;
            // The lemon tori (XT: major radius a < 0, |a| < minor b) as the file defines them, and the
            // faces built on them: every point of such a face, its edges and its inside, on
            // (ρ − a)² + z² = b² about the file's axis, with ρ >= 0 on the inner part.
            struct Lemon { std::array<double, 3> centre, axis; double major, minor; };
            std::vector<Lemon> lemons;
            SolidWorksPackage package;
            QByteArray local;
            std::vector<SolidWorksFeatureBodies> features;
            ParasolidXtTopology topology;
            if (readPackage(path, package) && streamOf(package, "Config-0-FeatureBodies/LocalBodies", local) &&
                decodeSolidWorksFeatureBodies(local, features, error) && features.size() == 1 && features[0].bodies.size() == 1 &&
                readParasolidXtTransmitStream(features[0].bodies[0].parasolid, topology, error))
                for (const auto& g : topology.analyticGeometry)
                    if (g.reals.contains("major_radius") && g.reals.value("major_radius") < 0)
                        lemons.push_back({g.vectors.value("centre"), g.vectors.value("axis"), g.reals.value("major_radius"), g.reals.value("minor_radius")});
            const TopoDS_Shape* solid = reader.findShape(shape);
            int faces = 0, lemonFaces = 0, samples = 0;
            double worst = 0;
            const auto residual = [&](const gp_Pnt& p) {
                double best = 1e300;
                for (const Lemon& l : lemons) {
                    const double d[3] = {p.X() - l.centre[0], p.Y() - l.centre[1], p.Z() - l.centre[2]};
                    const double z = d[0] * l.axis[0] + d[1] * l.axis[1] + d[2] * l.axis[2];
                    const double rho = std::sqrt(std::max(0.0, d[0] * d[0] + d[1] * d[1] + d[2] * d[2] - z * z));
                    best = std::min(best, std::fabs(std::hypot(rho - l.major, z) - l.minor));
                }
                return best;
            };
            for (TopExp_Explorer f(*solid, TopAbs_FACE); solid && f.More(); f.Next()) {
                ++faces;
                const TopoDS_Face face = TopoDS::Face(f.Current());
                const Handle(Geom_Surface) surface = BRep_Tool::Surface(face);
                if (Handle(Geom_SurfaceOfRevolution)::DownCast(surface).IsNull()) continue;
                ++lemonFaces;
                for (TopExp_Explorer e(face, TopAbs_EDGE); e.More(); e.Next()) {
                    const BRepAdaptor_Curve curve(TopoDS::Edge(e.Current()));
                    for (int k = 0; k <= 16; ++k, ++samples)
                        worst = std::max(worst, residual(curve.Value(curve.FirstParameter() + (curve.LastParameter() - curve.FirstParameter()) * k / 16.0)));
                }
                double u1, u2, v1, v2;
                BRepTools::UVBounds(face, u1, u2, v1, v2);
                BRepTopAdaptor_FClass2d inside(face, 1e-9);
                for (int i = 1; i < 16; ++i)
                    for (int j = 1; j < 16; ++j) {
                        const gp_Pnt2d uv(u1 + (u2 - u1) * i / 16.0, v1 + (v2 - v1) * j / 16.0);
                        if (inside.Perform(uv) != TopAbs_IN) continue;
                        ++samples;
                        worst = std::max(worst, residual(surface->Value(uv.X(), uv.Y())));
                    }
            }
            // A closed, checked solid: every edge between exactly two faces.
            bool closed = solid && BRepCheck_Analyzer(*solid).IsValid();
            if (solid) {
                TopTools_IndexedDataMapOfShapeListOfShape owners;
                TopExp::MapShapesAndAncestors(*solid, TopAbs_EDGE, TopAbs_FACE, owners);
                for (int k = 1; closed && k <= owners.Extent(); ++k)
                    closed = BRep_Tool::Degenerated(TopoDS::Edge(owners.FindKey(k))) || owners(k).Extent() == 2;
            }
            check(lemons.size() == 3 && lemonFaces == 3 && samples > 300 && worst <= 1e-9,
                  "лимонный тор (большой радиус < 0): 3 поверхности в файле, 3 грани построены, " + std::to_string(samples) +
                      " точек граней на поверхности из файла, худшая в " + std::to_string(worst * 1e12) + " пм");
            check(closed && faces == int(topology.faces.size()), "деталь с лимонными торами: замкнутое проверенное тело, граней " +
                                                                 std::to_string(faces) + " из " + std::to_string(topology.faces.size()));
            // Written as a part of ours and read back: the lemon faces go out as exact rational
            // B-splines. The volumes by converged adaptive integration (the default integrator is
            // 3e-4 off on that B-spline form) agree within the round trip's 1e-8.
            QTemporaryDir scratch;
            kernel::OcctKernel second;
            kernel::ShapeHandle again;
            QString e;
            const QString copy = scratch.filePath("lemon.SLDPRT");
            const bool back = solid && writeSolidWorksImportedPart(reader, shape, copy, e) && readSolidWorksAnalyticPart(copy, second, again, e);
            const auto volume = [](const TopoDS_Shape& body) {
                GProp_GProps properties;
                BRepGProp::VolumeProperties(body, properties, 1e-12, true);
                return properties.Mass();
            };
            const double before = solid ? volume(*solid) : 0, after = back ? volume(*second.findShape(again)) : 0;
            check(back && before > 0 && std::fabs(after / before - 1) <= 1e-8,
                  "деталь с лимонными торами записана и прочитана: объём расходится на " + std::to_string(before > 0 ? std::fabs(after / before - 1) * 1e9 : 0) +
                      " × 1e-9" + (back ? std::string() : " — " + e.toStdString()));
        }
        if (present) {
            check(present == 10 && asExpected == present, "детали с импортированным телом читаются как записано в таблице: построено " +
                                                              std::to_string(built) + " из " + std::to_string(present));
            check(faithful == built, "каждая построенная — годное замкнутое тело с гранями и вершинами своего файла: " +
                                         std::to_string(faithful) + " из " + std::to_string(built));
        }
        // Against the STEP files the fischertechnik parts were imported from (sw-imported/fischertechnik-step):
        // each solid there is named as its part. Volume and principal moments by converged integration,
        // centre of mass in the same frame. 0612 is the one SOLIDWORKS changed on import (its edges carry
        // tolerances up to 4.7 µm; two sphere faces lost an edge the STEP has): surfaces moved by at most
        // the largest edge tolerance t change the volume by at most A·t, so within A·t/V of the STEP and
        // the centre within t; the other six within 1e-8 and 1e-9 m.
        const QString steps = root + "/fischertechnik-step";
        if (QFileInfo::exists(steps + "/LIFTING_WHEEL_D80.stp") && QFileInfo::exists(steps + "/Bracket_45_45_with_fastening_set.stp")) {
            struct Measure { double volume = 0; gp_Pnt centre; std::array<double, 3> moments{}; };
            const auto measure = [](const TopoDS_Shape& body) {
                GProp_GProps properties;
                BRepGProp::VolumeProperties(body, properties, 1e-12, true);
                Measure m;
                m.volume = properties.Mass();
                m.centre = properties.CentreOfMass();
                properties.PrincipalProperties().Moments(m.moments[0], m.moments[1], m.moments[2]);
                std::sort(m.moments.begin(), m.moments.end());
                return m;
            };
            int compared = 0, held = 0;
            double worst0612 = 0, bound0612 = 0;
            for (const char* step : {"LIFTING_WHEEL_D80.stp", "Bracket_45_45_with_fastening_set.stp"}) {
                kernel::OcctKernel stepKernel;
                const auto bodies = stepKernel.importStepAssembly((steps + "/" + step).toStdString());
                if (!bodies.isOk()) continue;
                for (const auto& body : bodies.value()) {
                    const QString part = root + "/fischertechnik/" + QString::fromStdString(body.name) + ".stp.SLDPRT";
                    kernel::OcctKernel reader;
                    kernel::ShapeHandle shape;
                    QString error;
                    ParasolidXtBuildReport report;
                    if (!QFileInfo::exists(part) || !readSolidWorksAnalyticPart(part, reader, shape, error, &report)) continue;
                    ++compared;
                    const Measure ours = measure(*reader.findShape(shape)), theirs = measure(*stepKernel.findShape(body.shape));
                    double deviation = std::fabs(ours.volume / theirs.volume - 1);
                    for (int k = 0; k < 3; ++k) deviation = std::max(deviation, std::fabs(ours.moments[k] / theirs.moments[k] - 1));
                    double relative = 1e-8, shift = 1e-9;
                    if (body.name == "2022_10_06_17_02_43_0612") {
                        GProp_GProps surface;
                        BRepGProp::SurfaceProperties(*reader.findShape(shape), surface, 1e-10);
                        relative = bound0612 = surface.Mass() * report.largestEdgeTolerance / ours.volume;
                        shift = report.largestEdgeTolerance;
                        worst0612 = deviation;
                    }
                    held += report.largestEdgeTolerance >= 0 && deviation <= relative && ours.centre.Distance(theirs.centre) <= shift ? 1 : 0;
                }
            }
            check(compared == 7 && held == 7, "детали fischertechnik совпадают с телами исходных STEP: " + std::to_string(held) + " из " +
                                                  std::to_string(compared) + " (0612 — на " + std::to_string(worst0612 * 1e6) + " × 1e-6 при границе A·t/V = " +
                                                  std::to_string(bound0612 * 1e6) + " × 1e-6: правка импорта SOLIDWORKS)");
        } else {
            std::printf("SKIP сверки со STEP: нет %s\n", qPrintable(steps));
        }
    }
    // Assemblies down through their sub-assemblies (readSolidWorksAssemblyParts). A made-up tree
    // first: the top places sub-assembly S (a quarter turn about z, then 10 mm along x) and part A;
    // S places part B 2 mm along y. B lands at R·(0, 2, 0) + (10, 0, 0) = (8, 0, 0) mm, turned.
    {
        const QByteArray xml =
            "<swSolidWorks><swHeader><swFile id=\"1\" swPath=\"Top.SLDASM\"/><swFile id=\"2\" swPath=\"S.SLDASM\"/>"
            "<swFile id=\"3\" swPath=\"A.SLDPRT\"/><swFile id=\"4\" swPath=\"B.SLDPRT\"/></swHeader><swModelList>"
            "<swModel id=\"13\" swFileRef=\"3\"/><swModel id=\"14\" swFileRef=\"4\"/>"
            "<swModel id=\"12\" swFileRef=\"2\"><swReference id=\"22\" swName=\"B\" swModelRef=\"14\" "
            "swTransform=\"1 0 0 0 0 1 0 0 0 0 1 0 0 0.002 0 1\"/></swModel>"
            "<swModel id=\"11\" swFileRef=\"1\"><swReference id=\"21\" swName=\"S\" swModelRef=\"12\" "
            "swTransform=\"0 1 0 0 -1 0 0 0 0 0 1 0 0.01 0 0 1\"/><swReference id=\"23\" swName=\"A\" swModelRef=\"13\" "
            "swTransform=\"1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1\"/></swModel></swModelList>"
            "<swConfigurationList><swConfiguration id=\"5\" swName=\"Default\" swModelRef=\"11\"/></swConfigurationList></swSolidWorks>";
        SolidWorksPackage package;
        package.entries.push_back({"swXmlContents/COMPINSTANCETREE", xml});
        QByteArray file;
        QString e;
        QTemporaryDir scratch;
        const QString made = scratch.filePath("Top.SLDASM");
        QFile out(made);
        const bool written = encodeSolidWorksPackage(package, file, e) && out.open(QIODevice::WriteOnly) && out.write(file) == file.size();
        out.close();
        std::vector<SolidWorksAssemblyComponent> parts;
        const bool read = written && readSolidWorksAssemblyParts(made, parts, e);
        const auto near = [](double a, double b) { return std::fabs(a - b) <= 1e-15; };
        bool placed = read && parts.size() == 2 && parts[0].name == "S/B" && parts[0].sourcePath == "B.SLDPRT" &&
                      parts[1].name == "A" && parts[1].sourcePath == "A.SLDPRT";
        if (placed) {
            const auto& m = parts[0].transform;
            placed = near(m[0], 0) && near(m[1], 1) && near(m[4], -1) && near(m[5], 0) && near(m[10], 1) &&
                     near(m[12], 0.008) && near(m[13], 0) && near(m[14], 0) && near(m[15], 1);
        }
        check(placed, "подсборка в сборке: детали с путём имён и произведением матриц сверху вниз" +
                          (read ? std::string() : " — " + e.toStdString()));
    }
    {
        const QString assemblies = QDir::homePath() + "/cadnext-samples/sw-assemblies/fischertechnik";
        if (QFileInfo::exists(assemblies + "/Halbtischv2.SLDASM")) {
            // The table assemblies hold their STEP-made components inside (ImportedComp/), three of them
            // sub-assemblies (a wheel of 2 parts, a bracket set of 5, a connector of 7); their own parts
            // (Frontplatte…) are separate files, not among the samples.
            struct Expected { const char* file; std::size_t parts; };
            int counted = 0;
            for (const Expected& expected : {Expected{"Halbtischv2.SLDASM", 63}, Expected{"Tischv1.SLDASM", 546},
                                             Expected{"Vierteltischv1.SLDASM", 128}, Expected{"Vierteltischv2.SLDASM", 128}}) {
                std::vector<SolidWorksAssemblyComponent> parts;
                QString e;
                counted += readSolidWorksAssemblyParts(assemblies + "/" + expected.file, parts, e) && parts.size() == expected.parts ? 1 : 0;
            }
            check(counted == 4, "сборки fischertechnik: экземпляры деталей через подсборки — 63, 546, 128, 128");
            kernel::OcctKernel reader;
            std::vector<SolidWorksImportedBody> bodies;
            QString e;
            check(!readSolidWorksAnalyticAssembly(assemblies + "/Halbtischv2.SLDASM", reader, bodies, e) && bodies.empty() &&
                      e.contains("Frontplatte.SLDPRT"),
                  "сборка без отдельного файла детали отклоняется с его именем, вложенные детали найдены");
            // The wheels placed through their sub-assembly: each wheel's housing (part 0612) rests on its
            // screw-on plate, a part of the top assembly — the product of the matrices puts it there.
            std::vector<SolidWorksAssemblyComponent> parts;
            SolidWorksPackage package;
            QTemporaryDir scratch;
            QStringList housings, plates;
            std::vector<TopoDS_Shape> housingShapes, plateShapes;
            kernel::OcctKernel placer;
            if (readSolidWorksAssemblyParts(assemblies + "/Halbtischv2.SLDASM", parts, e) && readPackage(assemblies + "/Halbtischv2.SLDASM", package)) {
                QHash<QString, kernel::ShapeHandle> built;
                for (const auto& part : parts) {
                    const bool housing = part.name.endsWith("2022_10_06_17_02_43_0612.stp"), plate = part.name.startsWith("SCREW_ON_PLATE");
                    if (!housing && !plate) continue;
                    const QString file = QString(part.sourcePath).replace('\\', '/').section('/', -1);
                    if (!built.contains(file))
                        for (const auto& entry : package.entries)
                            if (QString::fromLatin1(entry.name).compare("ImportedComp/" + file, Qt::CaseInsensitive) == 0) {
                                QFile copy(scratch.filePath(file));
                                kernel::ShapeHandle shape;
                                QString ignored;
                                if (copy.open(QIODevice::WriteOnly) && copy.write(entry.data) == entry.data.size()) {
                                    copy.close();
                                    if (readSolidWorksAnalyticPart(scratch.filePath(file), placer, shape, ignored)) built.insert(file, shape);
                                }
                            }
                    if (!built.contains(file)) continue;
                    const auto instance = placer.transformShape(built.value(file), part.transform);
                    if (!instance.isOk()) continue;
                    (housing ? housingShapes : plateShapes).push_back(*placer.findShape(instance.value()));
                }
            }
            int resting = 0;
            for (const auto& housing : housingShapes) {
                double nearest = std::numeric_limits<double>::infinity();
                for (const auto& plate : plateShapes) {
                    BRepExtrema_DistShapeShape distance(housing, plate);
                    if (distance.IsDone()) nearest = std::min(nearest, distance.Value());
                }
                resting += nearest <= 1e-6 ? 1 : 0;
            }
            check(housingShapes.size() == 2 && plateShapes.size() == 2 && resting == 2,
                  "колёса через подсборку: корпус каждого лежит на своей пластине (до 1 мкм), " + std::to_string(resting) + " из 2");
        } else {
            std::printf("SKIP сборок fischertechnik: нет %s\n", qPrintable(assemblies));
        }
    }
    // The information properties: the blueprint's are an English SOLIDWORKS 2020 document's.
    {
        SolidWorksPackage package;
        QByteArray bytes;
        QString error;
        SolidWorksPartValues values;
        if (readPackage(root + "/walrus/c-t4132412041-000-a-3d.stp.SLDPRT", package))
            check(streamOf(package, information, bytes) && matchSolidWorksPartStream(information, bytes, values, error),
                  "ISolidWorksInformation.xml английского документа совпадает с чертежом вне слотов" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));
    }

    // Our own part.
    kernel::OcctKernel kernel;
    const auto box = kernel.makeBox({0.04, 0.03, 0.02});
    QTemporaryDir dir;
    const QString path = dir.filePath("Bracket.SLDPRT");
    QString error;
    SolidWorksPartWriteOptions options;
    options.saved = QDateTime(QDate(2026, 10, 3), QTime(12, 0, 0), QTimeZone::UTC);
    const bool written = box.isOk() && writeSolidWorksImportedPart(kernel, box.value(), path, error, options);
    check(written, "деталь SOLIDWORKS записана" + (error.isEmpty() ? std::string() : " — " + error.toStdString()));
    if (written) {
        SolidWorksPackage package;
        bool read = readPackage(path, package);
        // The same streams as a sample part, less the 3DEXPERIENCE database; each ours matches the blueprint.
        int ours = 0;
        SolidWorksPartValues values;
        for (const QByteArray& name : streams) {
            QByteArray bytes;
            ours += streamOf(package, name, bytes) && matchSolidWorksPartStream(name, bytes, values, error) ? 1 : 0;
        }
        check(read && ours == streams.size(), "наша деталь: все " + std::to_string(streams.size()) + " потоков чертежа на месте и читаются (" + std::to_string(ours) + ")" +
                                              (ours == streams.size() ? std::string() : " — " + error.toStdString()));
        if (!parts.isEmpty()) {
            SolidWorksPackage sample;
            readPackage(parts.at(3).absoluteFilePath(), sample);
            QStringList theirs, mine;
            for (const auto& e : sample.entries) if (e.name != "Contents/3DExperienceExchange2") theirs << QString::fromLatin1(e.name);
            for (const auto& e : package.entries) mine << QString::fromLatin1(e.name);
            check(mine == theirs, "наша деталь: те же потоки в том же порядке, что у детали SOLIDWORKS 2022 (без 3DExperienceExchange2): " + std::to_string(mine.size()));
        }
        check(values.text.value("title") == "Bracket" && values.text.value("configuration") == "Default" && values.text.value("ui.FrontPlane") == "Front Plane" &&
              std::fabs(values.boxMax[0] - values.boxMin[0] - 0.04) < 1e-12 && values.number.value("import.faces") == 6,
              "наша деталь: имя, конфигурация Default, английские названия дерева, габарит 40 мм, 6 граней");
        // The existing codecs of single streams read ours.
        QByteArray header, configurations;
        SolidWorksDocumentHeader documentHeader;
        SolidWorksConfigurationHeader configurationHeader;
        const bool headerRead = streamOf(package, "Header2", header) && decodeSolidWorksDocumentHeader(header, documentHeader, error);
        check(headerRead, "наша деталь: Header2 читается кодеком заголовка документа" + (headerRead ? std::string() : " — " + error.toStdString()));
        const bool configurationsRead = streamOf(package, "Contents/CMgrHdr2", configurations) &&
                                        decodeSolidWorksConfigurationHeader(configurations, configurationHeader, error) &&
                                        configurationHeader.entries.size() == 1 && configurationHeader.entries.front().name == "Default";
        check(configurationsRead, "наша деталь: CMgrHdr2 читается кодеком конфигураций, одна конфигурация Default" + (configurationsRead ? std::string() : " — " + error.toStdString()));
        // Nothing of the samples' authors in it.
        bool clean = true;
        for (const auto& e : package.entries)
            for (const QString& word : {QStringLiteral("Tobias"), QStringLiteral("TOBIAS"), QStringLiteral("Kontsruktion"), QStringLiteral("Bracket_45"), QStringLiteral("2022_10_06"), QStringLiteral("sande")})
                clean = clean && !contains(e.data, word);
        check(clean, "наша деталь: нет имён, путей и названий из образцов");
        // The body back, exactly.
        kernel::OcctKernel reader;
        kernel::ShapeHandle shape;
        const bool built = readSolidWorksAnalyticPart(path, reader, shape, error);
        double volume = 0;
        if (built) { const auto v = reader.volumeProperties(shape); if (v.isOk()) volume = v.value().volumeM3; }
        check(built && std::fabs(volume - 0.04 * 0.03 * 0.02) < 1e-15, "наша деталь читается читателем CADNext: объём " + std::to_string(volume * 1e9) + " мм3 из 24000" +
                                                                       (built ? std::string() : " — " + error.toStdString()));
    }

    // Curved bodies: a cylinder and a sphere, each written and read back.
    {
        const double pi = 3.14159265358979323846;
        const auto cylinder = kernel.makeCylinder({0.01, 0.05});
        const auto sphere = kernel.makeSphere({0.015});
        struct Case { const char* name; kernel::ShapeHandle shape; bool made; double volume; };
        const Case cases[] = {{"Cylinder", cylinder.isOk() ? cylinder.value() : kernel::ShapeHandle{}, cylinder.isOk(), pi * 0.01 * 0.01 * 0.05},
                              {"Sphere", sphere.isOk() ? sphere.value() : kernel::ShapeHandle{}, sphere.isOk(), 4.0 / 3.0 * pi * 0.015 * 0.015 * 0.015}};
        for (const Case& c : cases) {
            const QString file = dir.filePath(QString::fromLatin1(c.name) + ".SLDPRT");
            QString e;
            kernel::OcctKernel reader;
            kernel::ShapeHandle shape;
            double volume = 0;
            const bool back = c.made && writeSolidWorksImportedPart(kernel, c.shape, file, e, options) && readSolidWorksAnalyticPart(file, reader, shape, e);
            if (back) { const auto v = reader.volumeProperties(shape); if (v.isOk()) volume = v.value().volumeM3; }
            check(back && std::fabs(volume - c.volume) <= 1e-9 * c.volume, std::string(c.name) + ": записан и прочитан, объём сходится до 1e-9" +
                                                                         (back ? std::string() : " — " + e.toStdString()));
        }
        // A transmit longer than 1 MiB goes in pieces: 1 MiB, then 4096 bytes each, then the closing words.
        {
            SolidWorksFeatureBodies feature;
            feature.featureName = "Long<1>";
            feature.bodies.resize(1);
            QByteArray& transmit = feature.bodies[0].parasolid;
            transmit = QByteArray("PS\0\0", 4);
            quint32 state = 1;
            while (transmit.size() < 0x100000 + 3 * 4096 + 17) {
                state = state * 1664525u + 1013904223u;
                transmit += char(state >> 24);
            }
            QByteArray section;
            QString e;
            const bool encoded = encodeSolidWorksFeatureBodies({feature}, section, e);
            // The pieces as written: after the name, the group's two words, the body's 14 bytes and the marker.
            std::vector<quint32> pieces;
            const auto word = [&section](qsizetype at) {
                return quint32(uchar(section[at])) | quint32(uchar(section[at + 1])) << 8 | quint32(uchar(section[at + 2])) << 16 | quint32(uchar(section[at + 3])) << 24;
            };
            qsizetype at = 4 + 4 + 2 * feature.featureName.size() + 8 + 14 + 16;
            bool walked = encoded;
            while (walked && at + 8 <= section.size()) {
                const quint32 unpacked = word(at), packed = word(at + 4);
                at += 8;
                if (!unpacked && !packed) break;
                pieces.push_back(unpacked);
                at += packed;
            }
            walked = walked && at == section.size() && pieces.size() == 5 && pieces[0] == 0x100000 && pieces[1] == 4096 &&
                     pieces[2] == 4096 && pieces[3] == 4096 && pieces[4] == 17;
            std::vector<SolidWorksFeatureBodies> back;
            const bool decoded = encoded && decodeSolidWorksFeatureBodies(section, back, e) && back.size() == 1 && back[0].bodies.size() == 1 &&
                                 back[0].bodies[0].parasolid == transmit;
            check(walked && decoded, "тело длиннее 1 МиБ: части 1 МиБ, 4096, 4096, 4096 и остаток, читается обратно без потерь");
            QByteArray cut = section.left(section.size() - 9);
            check(!decodeSolidWorksFeatureBodies(cut, back, e) && back.empty(), "оборванная цепочка частей отвергается");
        }
        // A failed export leaves the destination as it was.
        const QString kept = dir.filePath("kept.SLDPRT");
        QFile existing(kept);
        existing.open(QIODevice::WriteOnly);
        existing.write("keep");
        existing.close();
        QString e;
        const bool refused = !writeSolidWorksImportedPart(kernel, kernel::ShapeHandle{}, kept, e) && !e.isEmpty();
        existing.open(QIODevice::ReadOnly);
        check(refused && existing.readAll() == "keep", "неудачная запись не трогает существующий файл");
    }

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
