// KOMPAS-3D parts (.m3d) read from the C3D kernel's own serialisation into exact solids
// (NativeKompasC3d), against their STEP twins read by OCCT's STEP reader, independently of the reader
// under test. The twins of sfh551 and sfh756 were written by KOMPAS itself (ASCON STEP Converter); those
// of e2b1766…, Nema Motor 17 and WYSE by SolidWorks (2013, 2013, 2020) — the models the KOMPAS parts
// were made from, not KOMPAS's own export.
//
// Criteria, fixed before the first run of this test:
//   - The five parts of the samples (e2b1766…, Nema Motor 17, WYSE, sfh551, sfh756): read; as many
//     bodies as the twin has solids (Nema Motor 17: 3, the others 1); each body a valid solid with as
//     many faces as its C3D shell (no face lost, none split per turn); no face approximated.
//   - Against the twin, body by body in order of volume: the volume within 1e-9 relative; all bodies
//     together: the area within 1e-9 relative, the centre of mass within 1e-9 of the twin's box
//     diagonal. Face counts are not compared with the twin: its writer cuts some closed faces in two
//     (WYSE 155 faces against its 147, e2b1766… 22 against 20).
//   - WYSE, face by face on the surfaces C3D writes: 95 planes, 28 cylinders, 14 B-spline surfaces,
//     8 spheres, 2 tori — each built on a surface of that kind, none replaced by an approximation. One
//     body: the file holds the same shell twice (two records, the same faces and vertices bit for
//     bit), the copy skipped and said so. Corrected 2026-09-27 with the parts of the assemblies (22 more
//     files): the part's bodies are listed in records of their own and the other shells are the history of
//     its making — WYSE's first shell is history, its one listed body the second; checked: one body, no
//     copy to skip.
//   - The five assemblies (.a3d): refused, no shell in them — their parts are separate .m3d files
//     (named inside them, not among the samples).
// Assemblies, criteria fixed before the first run of these checks (2026-09-27):
//   - The five assemblies read as assemblies (readKompasAssembly): as many components as their STEP twin
//     has occurrences (5, 3, 4, 5, 3), 17 part files named in all; each component's frame that of a
//     distinct occurrence of the twin — its origin within 1e-9 of the twin's box diagonal, its axes
//     within 1e-9. The twins are SolidWorks's; the equality says the KOMPAS parts keep their frames.
//   - Imported without their parts next to them: refused, the error naming every missing part file.
//   - With all their parts next to them: as many bodies as the twin has solids, each solid of the twin
//     where it places it matched by a distinct body — volume within 1e-9 relative, centre of mass within
//     1e-9 of the diagonal; nothing missing or failed.
//     Replaced 2026-09-27, agreed with the user after the first run with the parts (2e2d passed; the others
//     failed on parts the builder does not make whole and on twins of other models), before this form
//     was run: component by component, each at the twin's occurrence its frame matched above. A component
//     whose part is built whole: as many bodies as that occurrence has solids, each matched by a distinct
//     body placed by the component's frame — volume within 1e-9 relative, centre of mass within 1e-9 of
//     the twin's diagonal. A component whose part is not built whole: named in the import's notes (its
//     file name), not compared. Left out by name, with the reason: all of T30 (its «Опора» edited after the
//     assembly was saved — 13.5 mm high against the 10 mm the assembly recorded and the twin has — and its
//     «Винт» with a body the twin lacks); in 9f86 (1) both hinges (the twin's hinges have 4 cones and 4
//     tori, the parts 2 and 3: another model). Each assembly not left out compares at least one component.
//     Amended 2026-09-27, agreed with the user, before this form was run: a part with edges taken as C3D
//     holds them (a curve in a surface's parameters, KompasC3dResult::curveEdges) is compared within
//     max(1e-9, Σ d²·L / V) of the volume and of the diagonal — d an edge's two curves apart at most, L its
//     length (an edge moved by d between two faces cuts a sliver of section under d²).
//     Corrected after that run (its derivation missed a factor, disclosed to the user): such an edge lies
//     on one surface and within d of the other, so where they meet at an angle θ it may be d / sin θ from
//     their intersection along the first — the sliver's section is under d² / sin θ: Σ d²·L / sin θ, θ the
//     smallest angle along the edge. (Measured before: the «Основание» thread surfaces are the twin's,
//     within 4e-7 mm on average and 2e-5 mm at most; its planes and cylinders have the twin's areas.)
//     «Основание» of SNSS then left out by name, agreed with the user, for what was measured after that
//     run: its thread edges within 3.2e-5 mm of the twin's (a sliver of 1e-7 mm³), its volume 1.3e-4 mm³
//     apart — its thread faces' 280 mm² times the 4e-7 mm the twin's thread surface lies off ours: another
//     surface, not our edges. 6-3, built whole once the builder was mended, left out the same way: the twin's
//     thread surfaces up to 5.4e-4 mm off ours (one of them the same to 1e-13, so ours are read right), its
//     faces cut otherwise (our r 2 cylinder 5.35 mm² smaller). Left out by name,
//     for what was measured of them: 6-2 (the twin's cross-hole edges 2.9e-4 mm off their exact cylinders,
//     ours within 1.1e-5), 6-4 (the twin's thread another model: 29 faces against 9), «Крышка» of SNSS (the
//     twin's cylinder and plane intersection edges up to 9.4e-4 mm off them, ours within 3.3e-6).
// Corrected after the first run: the reader's bodies are in metres and OCCT reads STEP in millimetres —
// the comparison is made in millimetres (the first run compared across units: every twin check failed).
#include "cadnext/gui/BackgroundCadImport.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepAdaptor_Surface.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepGProp.hxx>
#include <Bnd_Box.hxx>
#include <GProp_GProps.hxx>
#include <STEPControl_Reader.hxx>
#include <TopExp_Explorer.hxx>
#include <STEPCAFControl_Reader.hxx>
#include <TDF_LabelSequence.hxx>
#include <TDocStd_Document.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <XCAFApp_Application.hxx>
#include <XCAFDoc_DocumentTool.hxx>
#include <XCAFDoc_ShapeTool.hxx>
#include <gp_Trsf.hxx>

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <set>
#include <string>
#include <vector>

using namespace cadnext;

namespace {

int failures = 0;

void check(bool ok, const std::string& what) {
    std::printf("%s %s\n", ok ? "PASS" : "FAIL", what.c_str());
    if (!ok) ++failures;
}

std::string text(const QString& s) { return s.toStdString(); }

int facesOf(const TopoDS_Shape& s) {
    int n = 0;
    for (TopExp_Explorer e(s, TopAbs_FACE); e.More(); e.Next()) ++n;
    return n;
}

GProp_GProps volumeOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::VolumeProperties(s, p, 1e-10, true);
    return p;
}

double areaOf(const TopoDS_Shape& s) {
    GProp_GProps p;
    BRepGProp::SurfaceProperties(s, p, 1e-10, true);
    return p.Mass();
}

std::vector<TopoDS_Shape> stepSolids(const QString& path) {
    STEPControl_Reader reader;
    std::vector<TopoDS_Shape> solids;
    if (reader.ReadFile(path.toUtf8().constData()) != IFSelect_RetDone) return solids;
    reader.TransferRoots();
    for (TopExp_Explorer e(reader.OneShape(), TopAbs_SOLID); e.More(); e.Next()) solids.push_back(e.Current());
    return solids;
}

QString twinOf(const QString& part) {
    const QFileInfo f(part);
    for (const char* extension : {".STEP", ".step", ".stp", ".STP"}) {
        const QString candidate = f.path() + "/" + f.completeBaseName() + extension;
        if (QFileInfo::exists(candidate)) return candidate;
    }
    return {};
}

// Each occurrence of a part in a STEP assembly: where it is placed (millimetres) and its solids placed there.
struct Occurrence {
    gp_Trsf placement;
    std::vector<TopoDS_Shape> solids;
};

void occurrencesIn(const Handle(XCAFDoc_ShapeTool)& tool, const TDF_Label& label, const gp_Trsf& parent, std::vector<Occurrence>& out) {
    TDF_LabelSequence components;
    tool->GetComponents(label, components);
    for (int i = 1; i <= components.Length(); ++i) {
        const TDF_Label component = components.Value(i);
        const gp_Trsf placement = parent * tool->GetLocation(component).Transformation();
        TDF_Label referred;
        tool->GetReferredShape(component, referred);
        if (tool->IsAssembly(referred)) {
            occurrencesIn(tool, referred, placement, out);
            continue;
        }
        Occurrence o;
        o.placement = placement;
        for (TopExp_Explorer e(tool->GetShape(referred), TopAbs_SOLID); e.More(); e.Next())
            o.solids.push_back(e.Current().Moved(TopLoc_Location(placement)));
        out.push_back(o);
    }
}

std::vector<Occurrence> stepOccurrences(const QString& path) {
    std::vector<Occurrence> out;
    Handle(TDocStd_Document) document;
    XCAFApp_Application::GetApplication()->NewDocument("MDTV-XCAF", document);
    STEPCAFControl_Reader reader;
    if (reader.ReadFile(path.toUtf8().constData()) != IFSelect_RetDone || !reader.Transfer(document)) return out;
    const Handle(XCAFDoc_ShapeTool) tool = XCAFDoc_DocumentTool::ShapeTool(document->Main());
    TDF_LabelSequence roots;
    tool->GetFreeShapes(roots);
    for (int i = 1; i <= roots.Length(); ++i) occurrencesIn(tool, roots.Value(i), gp_Trsf(), out);
    return out;
}

} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    const QString root = qEnvironmentVariable("CADNEXT_TEST_SAMPLES", QDir::homePath() + "/cadnext-samples") + "/kompas";
    const QString parts[] = {root + "/samkola51_ARSA-BOX/e2b1766ddb7c4ed6a9d65030b639251d.m3d",
                             root + "/KrisMoro_Kompas_Projects/Nema Motor 17.m3d", root + "/KrisMoro_Kompas_Projects/WYSE.m3d",
                             root + "/kovachyakov_optical-fiber-models-and-lib/sfh551.m3d",
                             root + "/kovachyakov_optical-fiber-models-and-lib/sfh756.m3d"};
    if (!QFileInfo::exists(parts[0])) {
        std::printf("SKIP образцы КОМПАС-3D не найдены (%s)\n", text(root).c_str());
        return 77;
    }

    for (const QString& part : parts) {
        const std::string name = text(QFileInfo(part).fileName());
        kernel::OcctKernel kernel;
        gui::KompasC3dResult result;
        gui::ParasolidXtBuildReport report;
        QString error;
        const bool ok = gui::readKompasC3dSolids(part, kernel, result, error, &report);
        const std::vector<TopoDS_Shape> twin = stepSolids(twinOf(part));
        check(ok && !twin.empty() && result.solids.size() == twin.size(),
              name + ": прочитан, тел " + std::to_string(result.solids.size()) + " — у близнеца STEP " + std::to_string(twin.size()) +
                  (ok ? "" : " — " + text(error)));
        if (!ok || result.solids.size() != twin.size()) continue;

        // The reader's bodies are in metres, OCCT reads STEP in millimetres: compared in millimetres.
        gp_Trsf toMillimetres;
        toMillimetres.SetScale(gp::Origin(), 1000.0);
        std::vector<TopoDS_Shape> bodies;
        bool sound = true;
        std::string faces;
        for (const auto& solid : result.solids) {
            const TopoDS_Shape& shape = *kernel.findShape(solid.shape);
            bodies.push_back(BRepBuilderAPI_Transform(shape, toMillimetres, true).Shape());
            const bool valid = BRepCheck_Analyzer(shape).IsValid() && shape.ShapeType() == TopAbs_SOLID;
            sound = sound && valid && facesOf(shape) == solid.faces;
            faces += " " + std::to_string(facesOf(shape)) + "/" + std::to_string(solid.faces);
        }
        check(sound && report.approximated.empty(),
              name + ": каждое тело — исправное тело, граней столько же, сколько в оболочке C3D (" + faces.substr(1) +
                  "), приближённых граней нет");

        // Body by body in order of volume.
        const auto byVolume = [](std::vector<TopoDS_Shape> shapes) {
            std::vector<double> v;
            for (const auto& s : shapes) v.push_back(volumeOf(s).Mass());
            std::sort(v.begin(), v.end());
            return v;
        };
        const std::vector<double> ours = byVolume(bodies), theirs = byVolume(twin);
        double worst = 0.0;
        for (std::size_t i = 0; i < ours.size(); ++i) worst = std::max(worst, std::fabs(ours[i] - theirs[i]) / theirs[i]);
        char line[256];
        std::snprintf(line, sizeof line, "%s: объём каждого тела как у близнеца STEP (худшее отклонение %.2e, допуск 1e-9)", name.c_str(),
                      worst);
        check(worst <= 1e-9, line);

        double areaOurs = 0, areaTheirs = 0;
        GProp_GProps massOurs, massTheirs;
        Bnd_Box box;
        for (const auto& s : bodies) areaOurs += areaOf(s), massOurs.Add(volumeOf(s));
        for (const auto& s : twin) areaTheirs += areaOf(s), massTheirs.Add(volumeOf(s)), BRepBndLib::Add(s, box);
        const double areaGap = std::fabs(areaOurs - areaTheirs) / areaTheirs;
        const double diagonal = std::sqrt(box.SquareExtent());
        const double centreGap = massOurs.CentreOfMass().Distance(massTheirs.CentreOfMass()) / diagonal;
        std::snprintf(line, sizeof line, "%s: площадь (%.2e) и центр масс (%.2e диагонали) как у близнеца, допуск 1e-9", name.c_str(),
                      areaGap, centreGap);
        check(areaGap <= 1e-9 && centreGap <= 1e-9, line);

        if (name == "WYSE.m3d") {
            std::map<GeomAbs_SurfaceType, int> kinds;
            for (TopExp_Explorer e(bodies.front(), TopAbs_FACE); e.More(); e.Next())
                ++kinds[BRepAdaptor_Surface(TopoDS::Face(e.Current())).GetType()];
            std::snprintf(line, sizeof line,
                          "WYSE: поверхности граней как в C3D — плоскостей %d (95), цилиндров %d (28), B-сплайнов %d (14), сфер %d (8), торов %d (2)",
                          kinds[GeomAbs_Plane], kinds[GeomAbs_Cylinder], kinds[GeomAbs_BSplineSurface], kinds[GeomAbs_Sphere],
                          kinds[GeomAbs_Torus]);
            check(kinds[GeomAbs_Plane] == 95 && kinds[GeomAbs_Cylinder] == 28 && kinds[GeomAbs_BSplineSurface] == 14 &&
                      kinds[GeomAbs_Sphere] == 8 && kinds[GeomAbs_Torus] == 2 && kinds.size() == 5,
                  line);
            check(result.solids.size() == 1 && !result.notes.join(' ').contains(QStringLiteral("Повторных")),
                  "WYSE: одно тело — из списка тел файла; та же оболочка в истории построения телом не считается");
        }
    }

    // Assemblies: parts in separate files.
    int assemblies = 0, refused = 0;
    for (const QFileInfo& f : QDir(root + "/samkola51_ARSA-BOX").entryInfoList({"*.a3d"}, QDir::Files, QDir::Name)) {
        ++assemblies;
        kernel::OcctKernel kernel;
        gui::KompasC3dResult result;
        QString error;
        if (!gui::readKompasC3dSolids(f.absoluteFilePath(), kernel, result, error) &&
            error.contains(QStringLiteral("не прочитано ни одного тела")))
            ++refused;
    }
    check(assemblies == 5 && refused == 5,
          "сборки .a3d (" + std::to_string(assemblies) + "): отказ у " + std::to_string(refused) + " — оболочек в них нет, детали во внешних .m3d");

    // Assemblies read as assemblies: components against the twin's occurrences.
    std::set<QString> partFiles;
    for (const QFileInfo& f : QDir(root + "/samkola51_ARSA-BOX").entryInfoList({"*.a3d"}, QDir::Files, QDir::Name)) {
        const std::string name = text(f.fileName());
        gui::KompasAssembly assembly;
        QString error;
        const bool read = gui::readKompasAssembly(f.absoluteFilePath(), assembly, error);
        const std::vector<Occurrence> twin = stepOccurrences(twinOf(f.absoluteFilePath()));
        Bnd_Box box;
        for (const Occurrence& o : twin)
            for (const TopoDS_Shape& s : o.solids) BRepBndLib::Add(s, box);
        const double diagonal = box.IsVoid() ? 0.0 : std::sqrt(box.SquareExtent());
        std::vector<bool> taken(twin.size(), false);
        std::vector<int> occurrenceOf;
        double worstOrigin = 0.0, worstAxis = 0.0;
        int matched = 0;
        for (const gui::KompasComponent& c : assembly.components) {
            occurrenceOf.push_back(-1);
            QString written = c.relativePath;
            written.replace('\\', '/');
            partFiles.insert(written.section('/', -1));
            int best = -1;
            double bestOrigin = 1e300, bestAxis = 1e300;
            for (std::size_t k = 0; k < twin.size(); ++k) {
                if (taken[k]) continue;
                const gp_XYZ t = twin[k].placement.TranslationPart();
                const gp_Mat m = twin[k].placement.VectorialPart();
                const double origin = std::sqrt(std::pow(t.X() - c.origin[0], 2) + std::pow(t.Y() - c.origin[1], 2) + std::pow(t.Z() - c.origin[2], 2));
                double axis = 0.0;
                for (int j = 0; j < 3; ++j)
                    for (int i = 0; i < 3; ++i) axis = std::max(axis, std::fabs(m(i + 1, j + 1) - c.axes[std::size_t(3 * j + i)]));
                if (origin + axis < bestOrigin + bestAxis) best = int(k), bestOrigin = origin, bestAxis = axis;
            }
            if (best < 0) continue;
            taken[std::size_t(best)] = true;
            occurrenceOf.back() = best;
            worstOrigin = std::max(worstOrigin, bestOrigin / diagonal);
            worstAxis = std::max(worstAxis, bestAxis);
            ++matched;
        }
        char line[320];
        std::snprintf(line, sizeof line,
                      "%s: компонентов %zu — вхождений у близнеца %zu; размещения совпали у %d (начало %.1e диагонали, оси %.1e; допуск 1e-9)",
                      name.c_str(), assembly.components.size(), twin.size(), matched, worstOrigin, worstAxis);
        check(read && !twin.empty() && assembly.components.size() == twin.size() && matched == int(twin.size()) && worstOrigin <= 1e-9 &&
                  worstAxis <= 1e-9,
              line + (read ? std::string() : " — " + text(error)));

        // Imported: without its parts next to it, a refusal naming them; with them, component by component
        // against the twin's occurrence that component's frame matched.
        static const std::map<QString, std::string> assemblyLeftOut{
            {"T30-Opora-reguliruemaya-F19-M6kh40.a3d",
             "«Опора» изменена после сохранения сборки (13.5 мм против записанных 10), у «Винта» тело, которого нет у двойника"}};
        static const std::map<QString, std::string> partLeftOut{
            {"SNSD.30.50.96. Петля дверная алюминевая 3045(B47)E07H47_00.m3d", "у двойника другая модель петли (4 конуса и 4 тора против 2 и 3)"},
            {"SNSD.30.50.96. Петля дверная алюминевая малая(B47)E07H47_00.m3d", "у двойника другая модель петли (4 конуса и 4 тора против 2 и 3)"},
            {"6-2.m3d", "рёбра поперечного отверстия у двойника на 2.9e-4 мм от своих цилиндров (у нас до 1.1e-5)"},
            {"6-4.m3d", "резьба у двойника другой моделью (29 граней против 9)"},
            {"6-3.m3d",
             "поверхности резьбы у двойника до 5.4e-4 мм от наших (одна совпадает до 1e-13), грани разбиты иначе (цилиндр r2 на 5.35 мм2)"},
            {"SNSS.30.70.34 Крышка(T39)_00.m3d", "рёбра пересечения у двойника до 9.4e-4 мм от своих поверхностей (у нас до 3.3e-6)"},
            {"SNSS.30.70.34  Основание(T39)_00.m3d",
             "поверхность резьбы у двойника в среднем на 4e-7 мм другая (объём 1.3e-4 мм3 на 280 мм2 граней резьбы), наши рёбра резьбы до 3.2e-5 мм от его"}};
        bool allParts = read;
        QStringList absent;
        for (const gui::KompasComponent& c : assembly.components) {
            if (!gui::kompasComponentFile(f.absoluteFilePath(), c).isEmpty()) continue;
            allParts = false;
            QString written = c.relativePath;
            written.replace('\\', '/');
            absent << written.section('/', -1);
        }
        const gui::BodyImportResult imported = gui::importBodiesFromFile(f.absoluteFilePath());
        if (!allParts) {
            absent.removeDuplicates();
            bool named = !imported.error.isEmpty();
            for (const QString& part : absent) named = named && imported.error.contains(part);
            check(named, name + ": без деталей рядом — отказ, названы все " + std::to_string(absent.size()) +
                             " отсутствующих файла");
            continue;
        }
        if (const auto out = assemblyLeftOut.find(f.fileName()); out != assemblyLeftOut.end()) {
            std::printf("SKIP %s: с деталями не сверяется — %s\n", name.c_str(), out->second.c_str());
            continue;
        }
        const QString notes = imported.notes.join('\n') + '\n' + imported.error;
        gp_Trsf toMillimetres;
        toMillimetres.SetScale(gp::Origin(), 1000.0);
        int compared = 0, bodiesCompared = 0;
        double worstVolume = 0.0, worstCentre = 0.0, worstExcess = 0.0; // excess: deviation over its allowance
        std::string allowances;
        bool sound = true;
        QStringList notWhole, leftOut;
        for (std::size_t i = 0; i < assembly.components.size(); ++i) {
            const gui::KompasComponent& c = assembly.components[i];
            const QString file = gui::kompasComponentFile(f.absoluteFilePath(), c);
            const QString part = QFileInfo(file).fileName();
            if (partLeftOut.count(part)) {
                leftOut << part;
                continue;
            }
            kernel::OcctKernel kernel;
            gui::KompasC3dResult solids;
            QString why;
            const bool built = gui::readKompasC3dSolids(file, kernel, solids, why);
            if (!built || solids.notes.join(' ').contains(QStringLiteral("не построено"))) {
                notWhole << part;
                sound = sound && notes.contains(part); // the import says which part it could not make whole
                continue;
            }
            if (occurrenceOf[i] < 0) {
                sound = false;
                continue;
            }
            const Occurrence& theirs = twin[std::size_t(occurrenceOf[i])];
            std::vector<TopoDS_Shape> bodies;
            for (const gui::KompasSolid& solid : solids.solids) {
                const auto placed = kernel.transformShape(solid.shape, kernel::placementMatrix(gui::kompasComponentPlacement(c)));
                if (placed.isOk()) bodies.push_back(BRepBuilderAPI_Transform(*kernel.findShape(placed.value()), toMillimetres, true).Shape());
            }
            ++compared;
            sound = sound && bodies.size() == theirs.solids.size() && bodies.size() == solids.solids.size();
            // The part's allowance: 1e-9, or what its edges taken as C3D curves may move its volume by.
            double partVolume = 0.0;
            for (const TopoDS_Shape& body : bodies) partVolume += volumeOf(body).Mass();
            const double allowance = std::max(1e-9, solids.curveEdgeSliver / partVolume);
            if (allowance > 1e-9) {
                char note[160];
                std::snprintf(note, sizeof note, "; %s: %d рёбер по кривым C3D, наименьший sin θ %.2g, допуск %.1e", text(part).c_str(),
                              solids.curveEdges, solids.curveEdgeSine, allowance);
                allowances += note;
            }
            std::vector<bool> used(bodies.size(), false);
            for (const TopoDS_Shape& solid : theirs.solids) {
                const GProp_GProps reference = volumeOf(solid);
                int best = -1;
                double bestScore = 1e300, bestVolume = 0, bestCentre = 0;
                for (std::size_t k = 0; k < bodies.size(); ++k) {
                    if (used[k]) continue;
                    const GProp_GProps ours = volumeOf(bodies[k]);
                    const double volume = std::fabs(ours.Mass() - reference.Mass()) / reference.Mass();
                    const double centre = ours.CentreOfMass().Distance(reference.CentreOfMass()) / diagonal;
                    if (volume + centre < bestScore) best = int(k), bestScore = volume + centre, bestVolume = volume, bestCentre = centre;
                }
                if (best < 0) {
                    sound = false;
                    continue;
                }
                used[std::size_t(best)] = true;
                ++bodiesCompared;
                worstVolume = std::max(worstVolume, bestVolume);
                worstCentre = std::max(worstCentre, bestCentre);
                worstExcess = std::max(worstExcess, std::max(bestVolume, bestCentre) / allowance);
            }
        }
        notWhole.removeDuplicates();
        leftOut.removeDuplicates();
        std::snprintf(line, sizeof line, "%s: сверено компонентов %d (тел %d): объём %.1e, центр масс %.1e диагонали (допуск 1e-9)", name.c_str(),
                      compared, bodiesCompared, worstVolume, worstCentre);
        std::string tail = allowances;
        if (!notWhole.isEmpty()) tail += "; не строятся целиком, названы импортом: " + text(notWhole.join(", "));
        if (!leftOut.isEmpty()) {
            tail += "; исключены:";
            for (const QString& part : leftOut) tail += " " + text(part) + " (" + partLeftOut.at(part) + ")";
        }
        check(sound && compared > 0 && worstExcess <= 1.0, line + tail);
    }
    check(partFiles.size() == 17, "сборки называют " + std::to_string(partFiles.size()) + " файлов деталей (17)");

    std::printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
