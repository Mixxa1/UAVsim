// The Thread feature: standards' tables, the recipe's round trip, and the recipe on a face found by the
// FaceAnalyzer against the kernel's cut called directly.
//
// Criteria, fixed before the first run:
//   - Tables against the standards' published values (ISO 261, ASME B1.1, ISO 228-1, ISO 7-1, ASME
//     B1.20.1). NPT's diameters are computed from the pipe's OD by the standard's formula; its table gives
//     E0 to 1e-5 inch, so they must agree to 3e-4 mm.
//   - Every field of the recipe survives saving and loading unchanged.
//   - The recipe on a face the analyzer found cuts exactly what the kernel cuts when told directly where
//     (axis, start, major diameter at the start, the face's diameter, run-outs): the same removed volume
//     to 1e-12 m3 (two runs of one deterministic construction). Free ends run out, a shoulder does not.
//   - A taper thread off a cone of its taper, and a parallel one off a cylinder, are refused with a reason.
#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/Thread.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <gp_Ax2.hxx>

#include <cmath>
#include <cstdio>
#include <string>

using namespace cadnext;

namespace {

int failures = 0;

void check(bool condition, const std::string& what) {
    std::printf("%s %s\n", condition ? "PASS" : "FAIL", what.c_str());
    if (!condition) ++failures;
}

const ThreadSize* findSize(ThreadStandard standard, const std::string& designation) {
    for (const ThreadSize& size : threadSizes(standard))
        if (size.designation == designation) return &size;
    return nullptr;
}

void tables() {
    const ThreadSize* m8 = findSize(ThreadStandard::MetricCoarse, "M8");
    check(m8 && m8->majorDiameterMm == 8 && m8->pitchMm == 1.25, "M8: крупный шаг 1,25");
    const ThreadSize* m24 = findSize(ThreadStandard::MetricCoarse, "M24");
    check(m24 && m24->pitchMm == 3, "M24: крупный шаг 3");
    check(findSize(ThreadStandard::MetricFine, "M8×1") && findSize(ThreadStandard::MetricFine, "M12×1,25"),
          "мелкие шаги: M8×1, M12×1,25");
    const ThreadSize* unc = findSize(ThreadStandard::Unc, "1/4-20 UNC");
    check(unc && std::fabs(unc->majorDiameterMm - 6.35) < 1e-12 && std::fabs(unc->pitchMm - 1.27) < 1e-12, "1/4-20 UNC: 6,35 мм, шаг 1,27");
    const ThreadSize* unf = findSize(ThreadStandard::Unf, "#10-32 UNF");
    check(unf && std::fabs(unf->majorDiameterMm - 4.826) < 1e-12, "#10-32 UNF: 0,190 дюйма");
    const ThreadSize* g = findSize(ThreadStandard::PipeG, "G1/2");
    check(g && g->majorDiameterMm == 20.955 && std::fabs(g->pitchMm - 25.4 / 14) < 1e-12, "G1/2: 20,955 мм, 14 ниток на дюйм");
    const ThreadSize* r = findSize(ThreadStandard::PipeR, "R1/2");
    check(r && r->majorDiameterMm == 20.955 && r->gaugeLengthMm == 8.2, "R1/2: 20,955 мм в основной плоскости, 8,2 мм от торца");
    const ThreadSize* npt = findSize(ThreadStandard::Npt, "1/2-14 NPT");
    const double pitchIn = 1.0 / 14;
    check(npt && std::fabs(npt->majorDiameterMm - npt->gaugeLengthMm / 16 - (0.75843 + 0.8 * pitchIn) * 25.4) < 3e-4 &&
              std::fabs(npt->majorDiameterMm - (0.77843 + 0.8 * pitchIn) * 25.4) < 3e-4,
          "1/2 NPT: E0 = 0,75843, E1 = 0,77843 дюйма по таблице ASME B1.20.1");
    const int nearest = nearestThreadSize(ThreadStandard::MetricCoarse, 8.0, false);
    check(nearest >= 0 && threadSizes(ThreadStandard::MetricCoarse)[nearest].designation == "M8", "вал Ø8 — M8");
    const int hole = nearestThreadSize(ThreadStandard::MetricCoarse, 6.8, true);
    check(hole >= 0 && threadSizes(ThreadStandard::MetricCoarse)[hole].designation == "M8", "отверстие Ø6,8 — M8");
    ThreadParameters marking;
    marking.standard = ThreadStandard::MetricFine;
    marking.designation = "M8×1";
    marking.rightHanded = false;
    check(threadMarking(marking) == "M8×1LH", "обозначение M8×1LH");
    marking.standard = ThreadStandard::PipeR;
    marking.designation = "R1/2";
    marking.internal = true;
    marking.rightHanded = true;
    check(threadMarking(marking) == "Rc1/2", "внутренняя коническая — Rc1/2");
    marking.standard = ThreadStandard::Unc;
    marking.designation = "1/4-20 UNC";
    marking.rightHanded = false;
    check(threadMarking(marking) == "1/4-20 UNC-LH", "обозначение 1/4-20 UNC-LH");
}

void roundTrip() {
    Document document;
    Feature feature;
    feature.id = "feature-7";
    feature.name = "Резьба 1";
    feature.type = FeatureType::Thread;
    feature.targetObjectId = feature.modifiedBodyId = "body-1";
    ThreadParameters& t = feature.thread;
    t.targetBodyId = "body-1";
    t.faceId = "face-2-a-b-c";
    t.surface.axisOrigin = {0.001, -0.002, 0.25};
    t.surface.axisDirection = {0, 0.6, 0.8};
    t.surface.radius = 0.0104801234567891;
    t.surface.slope = 1.0 / 32;
    t.surface.axialStart = -0.0031;
    t.surface.axialEnd = 0.0179;
    t.surface.holeWall = true;
    t.standard = ThreadStandard::Npt;
    t.designation = "1/2-14 NPT";
    t.majorDiameterMm = 21.2236123;
    t.pitchMm = 25.4 / 14;
    t.gaugeLengthMm = 8.128;
    t.lengthMm = 13.5;
    t.fromFarEnd = true;
    t.internal = true;
    t.rightHanded = false;
    document.addFeature(feature);
    const auto loaded = DocumentSerializer::fromJson(DocumentSerializer::toJson(document));
    check(loaded.isOk() && loaded.value().features().size() == 1, "документ с резьбой читается");
    if (!loaded.isOk() || loaded.value().features().empty()) return;
    const Feature& f = loaded.value().features().front();
    const ThreadParameters& u = f.thread;
    const auto same = [](const Vector3& a, const Vector3& b) { return a.x == b.x && a.y == b.y && a.z == b.z; };
    check(f.type == FeatureType::Thread && f.modifiedBodyId == "body-1" && u.targetBodyId == t.targetBodyId &&
              u.faceId == t.faceId && same(u.surface.axisOrigin, t.surface.axisOrigin) &&
              same(u.surface.axisDirection, t.surface.axisDirection) && u.surface.radius == t.surface.radius &&
              u.surface.slope == t.surface.slope && u.surface.axialStart == t.surface.axialStart &&
              u.surface.axialEnd == t.surface.axialEnd && u.surface.holeWall && u.standard == t.standard &&
              u.designation == t.designation && u.majorDiameterMm == t.majorDiameterMm && u.pitchMm == t.pitchMm &&
              u.gaugeLengthMm == t.gaugeLengthMm && u.lengthMm == t.lengthMm && u.fromFarEnd && u.internal && !u.rightHanded,
          "все поля резьбы сохраняются без изменений");
}

// The one face of `kind` the analyzer finds on the body; nullptr if not exactly one.
const kernel::FaceReference* onlyFace(const std::vector<kernel::FaceReference>& faces, kernel::FaceKind kind) {
    const kernel::FaceReference* found = nullptr;
    for (const kernel::FaceReference& face : faces) {
        if (face.kind != kind) continue;
        if (found) return nullptr;
        found = &face;
    }
    return found;
}

ThreadSurface surfaceOf(const kernel::FaceReference& face) {
    ThreadSurface s;
    s.axisOrigin = face.axisOrigin;
    s.axisDirection = face.axisDirection;
    s.radius = face.radius;
    s.slope = face.radiusSlope;
    s.axialStart = face.axialStart;
    s.axialEnd = face.axialEnd;
    s.holeWall = face.holeWall;
    return s;
}

double volume(kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape) {
    const auto props = kernel.volumeProperties(shape);
    return props.isOk() ? props.value().volumeM3 : -1.0;
}

// The recipe on the analyzer's face against the kernel told directly.
void againstKernel(const std::string& name, const TopoDS_Shape& solid, kernel::FaceKind kind, ThreadParameters t,
                   const kernel::ThreadCutParameters& direct, double trimmed) {
    kernel::OcctKernel kernel;
    const kernel::ShapeHandle body = kernel.adoptShape(solid, "body");
    kernel::FaceAnalyzer analyzer(kernel);
    const auto faces = analyzer.planarFacesForBody("body", body);
    const kernel::FaceReference* face = onlyFace(faces, kind);
    check(face != nullptr, name + ": грань найдена");
    if (!face) return;
    t.targetBodyId = "body";
    t.faceId = face->faceId;
    t.surface = surfaceOf(*face);
    t.internal = face->holeWall;
    check(t.internal == direct.internal, name + (direct.internal ? ": грань — стенка отверстия" : ": грань — вал"));
    kernel::GeometryEvaluator evaluator(kernel);
    kernel::ThreadCutReport report;
    const auto evaluated = evaluator.evaluateThread(body, t, &report);
    check(evaluated.isOk() && evaluated.value().isValid && !evaluated.value().previewMesh.isEmpty(),
          name + ": резьба по рецепту построена" + (evaluated.isOk() ? "" : " — " + evaluated.error().message));
    if (!evaluated.isOk()) return;
    kernel::ThreadCutReport directReport;
    const auto cut = kernel.cutThread(body, direct, &directReport);
    check(cut.isOk(), name + ": ядро напрямую режет" + (cut.isOk() ? "" : " — " + cut.error().message));
    if (!cut.isOk()) return;
    const double byRecipe = volume(kernel, body) - volume(kernel, evaluated.value().shape);
    const double byKernel = volume(kernel, body) - volume(kernel, cut.value());
    std::printf("  %s: снято по рецепту %.12g, напрямую %.12g м3; проточено %.3g м\n", name.c_str(), byRecipe, byKernel, report.trimmed);
    check(std::fabs(byRecipe - byKernel) <= 1e-12, name + ": рецепт режет то же, что ядро напрямую");
    check(std::fabs(report.trimmed - trimmed) <= 1e-12, name + ": проточка как ожидалось");
}

} // namespace

int main() {
    tables();
    roundTrip();
    constexpr double kInch = 25.4e-3;

    // M8 on a shaft Ø8 × 30, 12 mm from its end at z = 0: that end free (run out), the thread ending
    // mid-shaft (not).
    {
        ThreadParameters t;
        t.standard = ThreadStandard::MetricCoarse;
        t.designation = "M8";
        t.majorDiameterMm = 8;
        t.pitchMm = 1.25;
        t.lengthMm = 12;
        kernel::ThreadCutParameters direct;
        direct.axisOrigin = {0, 0, 0};
        direct.axisDirection = {0, 0, 1};
        direct.start = 0;
        direct.length = 12e-3;
        direct.majorDiameter = 8e-3;
        direct.pitch = 1.25e-3;
        direct.surfaceDiameter = 8e-3;
        direct.runOutAtStart = true;
        againstKernel("M8 на валу от торца", BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), 4e-3, 30e-3).Shape(),
                      kernel::FaceKind::Cylindrical, t, direct, 0.0);
        // From the far end: that end free, run out there.
        t.fromFarEnd = true;
        direct.axisDirection = {0, 0, -1};
        direct.start = -30e-3;
        againstKernel("M8 на валу от дальнего торца", BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), 4e-3, 30e-3).Shape(),
                      kernel::FaceKind::Cylindrical, t, direct, 0.0);
    }
    // M8 in a blind hole Ø6.8 × 15 of a block, 12 mm from the mouth: the mouth free (run out), the thread's
    // end inside the wall (not).
    {
        const TopoDS_Shape block = BRepPrimAPI_MakeBox(gp_Pnt(-10e-3, -10e-3, 0), 20e-3, 20e-3, 20e-3).Shape();
        const TopoDS_Shape hole = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, 5e-3), gp::DZ()), 3.4e-3, 16e-3).Shape();
        const TopoDS_Shape part = BRepAlgoAPI_Cut(block, hole).Shape();
        ThreadParameters t;
        t.standard = ThreadStandard::MetricCoarse;
        t.designation = "M8";
        t.majorDiameterMm = 8;
        t.pitchMm = 1.25;
        t.lengthMm = 12;
        t.fromFarEnd = true; // from the mouth at z = 20 mm
        kernel::ThreadCutParameters direct;
        direct.axisOrigin = {0, 0, 5e-3};
        direct.axisDirection = {0, 0, -1};
        direct.start = -15e-3;
        direct.length = 12e-3;
        direct.majorDiameter = 8e-3;
        direct.pitch = 1.25e-3;
        direct.internal = true;
        direct.surfaceDiameter = 6.8e-3;
        direct.runOutAtStart = true;
        againstKernel("M8 в глухом отверстии от устья", part, kernel::FaceKind::Cylindrical, t, direct, 0.0);
    }
    // R1/2 on a pipe end: a cone of 1:16 from the pipe's end at z = 0, 16 mm long, exactly at the thread's
    // major cone; the crest kept 1 µm under the face (turned by that).
    {
        const double rMajor = 20.955e-3 - 8.2e-3 / 16, k = 1.0 / 32, length = 16e-3;
        const TopoDS_Shape cone = BRepPrimAPI_MakeCone(gp_Ax2(gp::Origin(), gp::DZ()), rMajor / 2, rMajor / 2 + k * length, length).Shape();
        ThreadParameters t;
        t.standard = ThreadStandard::PipeR;
        t.designation = "R1/2";
        t.majorDiameterMm = 20.955;
        t.pitchMm = 25.4 / 14;
        t.gaugeLengthMm = 8.2;
        t.lengthMm = 14;
        kernel::ThreadCutParameters direct;
        direct.axisOrigin = {0, 0, 0};
        direct.axisDirection = {0, 0, 1};
        direct.start = 0;
        direct.length = 14e-3;
        direct.majorDiameter = rMajor;
        direct.pitch = kInch / 14;
        direct.profile = kernel::ThreadProfileKind::Whitworth55;
        direct.taper = 1.0 / 16;
        direct.surfaceDiameter = rMajor;
        direct.runOutAtStart = true;
        againstKernel("R1/2 на конце трубы", cone, kernel::FaceKind::Conical, t, direct, 1e-6);

        // The same cone with an M8 recipe, and R1/2 on a cylinder: refused, with the reason.
        kernel::OcctKernel kernel;
        const kernel::ShapeHandle body = kernel.adoptShape(cone, "cone");
        kernel::FaceAnalyzer analyzer(kernel);
        const auto faces = analyzer.planarFacesForBody("cone", body);
        const kernel::FaceReference* face = onlyFace(faces, kernel::FaceKind::Conical);
        check(face && std::fabs(face->radiusSlope - k) < 1e-12 && std::fabs(face->axialEnd - face->axialStart - length) < 1e-12,
              "конус: наклон 1/32 и длина 16 мм найдены");
        if (face) {
            ThreadParameters metric;
            metric.targetBodyId = "cone";
            metric.surface = surfaceOf(*face);
            metric.majorDiameterMm = 20;
            metric.pitchMm = 1.5;
            metric.lengthMm = 10;
            const auto refused = kernel::threadCutFor(metric);
            check(!refused.isOk(), "метрическая на конусе — отказ" + (refused.isOk() ? "" : ": " + refused.error().message));
        }
        ThreadParameters onCylinder = t;
        onCylinder.targetBodyId = "shaft";
        onCylinder.surface.axisDirection = {0, 0, 1};
        onCylinder.surface.radius = 10.4775e-3;
        onCylinder.surface.axialEnd = 20e-3;
        const auto refused = kernel::threadCutFor(onCylinder);
        check(!refused.isOk(), "R1/2 на цилиндре — отказ" + (refused.isOk() ? "" : ": " + refused.error().message));
    }
    // A shaft with a shoulder: M8 on the Ø8 part up to the Ø12 shoulder, from the shoulder — it must not run
    // out into the shoulder, and run out at the free end.
    {
        const TopoDS_Shape shaft = BRepPrimAPI_MakeCylinder(gp_Ax2(gp::Origin(), gp::DZ()), 4e-3, 20e-3).Shape();
        const TopoDS_Shape shoulder = BRepPrimAPI_MakeCylinder(gp_Ax2(gp_Pnt(0, 0, 20e-3), gp::DZ()), 6e-3, 10e-3).Shape();
        const TopoDS_Shape part = BRepAlgoAPI_Fuse(shaft, shoulder).Shape();
        kernel::OcctKernel probe;
        const auto faces = kernel::FaceAnalyzer(probe).planarFacesForBody("p", probe.adoptShape(part, "p"));
        // The Ø8 face.
        kernel::FaceKind kind = kernel::FaceKind::Cylindrical;
        int small = 0;
        for (const auto& face : faces)
            if (face.kind == kind && std::fabs(face.radius - 4e-3) < 1e-12) ++small;
        check(small == 1, "вал с буртом: грань Ø8 одна");
        ThreadParameters t;
        t.standard = ThreadStandard::MetricCoarse;
        t.designation = "M8";
        t.majorDiameterMm = 8;
        t.pitchMm = 1.25;
        t.lengthMm = 20;
        // Which end of the found face is the shoulder depends on its axis; the recipe is made below for
        // the end at z = 20 mm, and the direct cut is the same thread: from the shoulder toward the free end,
        // running out there only.
        kernel::OcctKernel kernel;
        const kernel::ShapeHandle body = kernel.adoptShape(part, "body");
        const auto found = kernel::FaceAnalyzer(kernel).planarFacesForBody("body", body);
        const kernel::FaceReference* face = nullptr;
        for (const auto& candidate : found)
            if (candidate.kind == kind && std::fabs(candidate.radius - 4e-3) < 1e-12) face = &candidate;
        if (face) {
            t.targetBodyId = "body";
            t.faceId = face->faceId;
            t.surface = surfaceOf(*face);
            const double dz = face->axisDirection.z;
            const double zStart = face->axisOrigin.z + dz * face->axialStart, zEnd = face->axisOrigin.z + dz * face->axialEnd;
            t.fromFarEnd = zEnd > zStart; // start from the end at z = 20
            kernel::ThreadCutReport report;
            const auto byRecipe = kernel::GeometryEvaluator(kernel).evaluateThread(body, t, &report);
            kernel::ThreadCutParameters direct;
            direct.axisOrigin = {0, 0, 0};
            direct.axisDirection = {0, 0, -1};
            direct.start = -20e-3;
            direct.length = 20e-3;
            direct.majorDiameter = 8e-3;
            direct.pitch = 1.25e-3;
            direct.surfaceDiameter = 8e-3;
            direct.runOutAtEnd = true;
            const auto cut = kernel.cutThread(body, direct);
            const bool ok = byRecipe.isOk() && cut.isOk();
            const double a = ok ? volume(kernel, body) - volume(kernel, byRecipe.value().shape) : 0;
            const double b = ok ? volume(kernel, body) - volume(kernel, cut.value()) : 1;
            std::printf("  от бурта: снято по рецепту %.12g, напрямую %.12g м3\n", a, b);
            check(ok && std::fabs(a - b) <= 1e-12, "M8 от бурта: у бурта без выхода, у свободного торца с выходом" +
                                                       (byRecipe.isOk() ? "" : " — " + byRecipe.error().message));
        }
    }
    std::printf("%s: %d failures\n", failures ? "FAILED" : "OK", failures);
    return failures ? 1 : 0;
}
