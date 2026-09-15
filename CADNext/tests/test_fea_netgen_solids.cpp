// CAD solid → Netgen volume mesh → structural solve: the path a real part takes.
//
// Parts are built with the CADNext kernel's own modelling operations (extrude, boolean cut),
// meshed with Netgen, and solved. Checked:
//  - every CAD face gets its triangles, grouped under the kernel's own face id, and the nodes of
//    each group lie on that face's geometry (plane or cylinder) as FaceAnalyzer reports it;
//  - the curved quadratic mesh reproduces the CAD volume; straight TET4 loses the curvature;
//  - meshing is reproducible;
//  - two exact references on unstructured meshes with Richardson/GCI on variable refinement
//    ratios, r = (N_fine / N_coarse)^(1/3) (Celik et al. 2008).
//
// Tolerances, fixed before the first run, and why they are wider than on mapped meshes:
//  - cantilever tip deflection 1 % (Timoshenko; clamped root face; tip value is the mean over
//    the tip face nodes of an unstructured mesh, not one centre node);
//  - cantilever bending stress 1 % (mean ratio to Mc/I over top-face nodes near mid-span);
//  - Lamé hoop stress 1 % (mean over all bore-surface nodes: nodal stresses on an unstructured
//    boundary average over irregular element patches);
//  - quadratic mesh volume 1e-4 relative, TET4 expected to miss by more than that.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/SolidMesher.hpp"
#include "cadnext/kernel/FaceAnalyzer.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

using namespace cadnext::fea;
using cadnext::kernel::OcctKernel;
using cadnext::kernel::ShapeHandle;
using fea_test::check;
using fea_test::checkRelative;

namespace {

SolidMesh meshOrDie(const OcctKernel& kernel, const ShapeHandle& shape, double maxh,
                    ElementOrder order = ElementOrder::Quadratic) {
    SolidMeshingSettings settings;
    settings.maximumElementSizeM = maxh;
    settings.order = order;
    const auto result = meshSolid(kernel, shape, settings);
    if (!result.isOk()) {
        std::printf("  FAIL  meshing: %s\n", result.error().message.c_str());
        ++fea_test::failures();
        std::exit(fea_test::finish("test_fea_netgen_solids"));
    }
    return result.value();
}

// The face group whose every node satisfies the predicate.
std::string groupWhere(const TetMesh& mesh, const std::function<bool(const Vec3&)>& onFace) {
    for (const auto& [name, faces] : mesh.faceGroups) {
        const auto nodes = mesh.nodesOnGroup(name);
        if (!nodes.empty() && std::all_of(nodes.begin(), nodes.end(), [&](int n) { return onFace(mesh.nodes[n]); })) {
            return name;
        }
    }
    return "";
}

double hoopStress(const Voigt& s, const Vec3& p) {
    const double r = std::hypot(p.x, p.y);
    const double c = p.x / r, sn = p.y / r;
    return s[0] * sn * sn + s[1] * c * c - 2.0 * s[5] * sn * c;
}

void faceGroupsFollowKernelFaces(OcctKernel& kernel, const ShapeHandle& shape, const SolidMesh& solid, const char* label) {
    cadnext::kernel::FaceAnalyzer analyzer(kernel);
    const auto faces = analyzer.planarFacesForBody("part", shape);
    check(static_cast<int>(faces.size()) == solid.cadFaceCount && static_cast<int>(solid.mesh.faceGroups.size()) == solid.cadFaceCount,
          std::string(label) + ": one face group per CAD face (" + std::to_string(solid.mesh.faceGroups.size()) + " of "
              + std::to_string(faces.size()) + ")");
    double worst = 0.0;
    for (std::size_t k = 0; k < faces.size(); ++k) {
        const auto& face = faces[k];
        const std::string group = solidFaceGroup(static_cast<int>(k));
        check(face.faceId.rfind(group + "-", 0) == 0, std::string(label) + ": group " + group + " is the kernel's " + face.faceId);
        for (int node : solid.mesh.nodesOnGroup(group)) {
            const Vec3 p = solid.mesh.nodes[node];
            double distance = 0.0;
            if (face.kind == cadnext::kernel::FaceKind::Planar) {
                distance = std::fabs(dot(p - Vec3{face.origin.x, face.origin.y, face.origin.z},
                                         {face.normal.x, face.normal.y, face.normal.z}));
            } else if (face.kind == cadnext::kernel::FaceKind::Cylindrical) {
                const Vec3 axis{face.axisDirection.x, face.axisDirection.y, face.axisDirection.z};
                const Vec3 d = p - Vec3{face.axisOrigin.x, face.axisOrigin.y, face.axisOrigin.z};
                distance = std::fabs(length(d - axis * dot(d, axis)) - face.radius);
            }
            worst = std::max(worst, distance);
        }
    }
    check(worst < 1e-9, std::string(label) + ": every face-group node, midsides included, lies on its CAD face (worst "
                            + std::to_string(worst) + " m)");
}

// --- Cantilever ------------------------------------------------------------------------

constexpr double kLength = 1.0;
constexpr double kWidth = 0.05;
constexpr double kHeight = 0.05;
constexpr double kLoad = 1000.0;

struct CantileverResult {
    double tipDeflection = 0.0;
    double stressRatio = 0.0;
    std::size_t elements = 0;
};

CantileverResult solveCantilever(const OcctKernel& kernel, const ShapeHandle& bar, double maxh) {
    const SolidMesh solid = meshOrDie(kernel, bar, maxh);
    const TetMesh& mesh = solid.mesh;
    const std::string root = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.x) < 1e-9; });
    const std::string tip = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.x - kLength) < 1e-9; });
    const std::string top = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.z - kHeight) < 1e-9; });

    const auto material = *findMaterial("steel_4130");
    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.constraints.push_back({mesh.nodesOnGroup(root), {0.0, 0.0, 0.0}});
    problem.tractions.push_back({tip, {0.0, 0.0, -kLoad / (kWidth * kHeight)}});
    const auto solution = fea_test::solveOrDie(problem);

    CantileverResult result;
    result.elements = mesh.elements.size();
    const auto tipNodes = mesh.nodesOnGroup(tip);
    for (int n : tipNodes) result.tipDeflection -= solution.displacement[n].z;
    result.tipDeflection /= static_cast<double>(tipNodes.size());

    const double I = kWidth * kHeight * kHeight * kHeight / 12.0;
    int counted = 0;
    for (int n : mesh.nodesOnGroup(top)) {
        const Vec3 p = mesh.nodes[n];
        if (std::fabs(p.x - kLength / 2) > kHeight) continue;
        const double exact = kLoad * (kLength - p.x) * (kHeight / 2) / I;
        result.stressRatio += solution.nodalStress[n][0] / exact;
        ++counted;
    }
    result.stressRatio /= std::max(counted, 1);
    std::printf("  maxh %.4f m: %zu TET10, %d DOFs, tip %.6g m, σxx/(Mc/I) %.5f over %d nodes\n", maxh, result.elements,
                solution.totalDofs, result.tipDeflection, result.stressRatio, counted);
    return result;
}

// --- Lamé quarter pipe ----------------------------------------------------------------

constexpr double kInner = 0.10;
constexpr double kOuter = 0.20;
constexpr double kThickness = 0.02;
constexpr double kPressure = 10.0e6;

struct PipeResult {
    double meanBoreHoop = 0.0;
    std::size_t elements = 0;
};

PipeResult solvePipe(const OcctKernel& kernel, const ShapeHandle& pipe, double maxh) {
    const SolidMesh solid = meshOrDie(kernel, pipe, maxh);
    const TetMesh& mesh = solid.mesh;
    auto radius = [](const Vec3& p) { return std::hypot(p.x, p.y); };
    const std::string bore = groupWhere(mesh, [&](const Vec3& p) { return std::fabs(radius(p) - kInner) < 1e-9; });
    const std::string symX = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.x) < 1e-9; });
    const std::string symY = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.y) < 1e-9; });
    const std::string end0 = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.z) < 1e-9; });
    const std::string end1 = groupWhere(mesh, [](const Vec3& p) { return std::fabs(p.z - kThickness) < 1e-9; });
    check(!bore.empty() && !symX.empty() && !symY.empty() && !end0.empty() && !end1.empty(),
          "quarter pipe: bore, both symmetry planes and both ends found among the CAD faces");

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = *findMaterial("steel_4130");
    problem.constraints.push_back({mesh.nodesOnGroup(symX), {0.0, std::nullopt, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup(symY), {std::nullopt, 0.0, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup(end0), {std::nullopt, std::nullopt, 0.0}});
    problem.constraints.push_back({mesh.nodesOnGroup(end1), {std::nullopt, std::nullopt, 0.0}});
    problem.pressures.push_back({bore, kPressure});
    const auto solution = fea_test::solveOrDie(problem);

    const double resultant = kPressure * kInner * kThickness;
    check(std::fabs(solution.appliedForceN.x - resultant) < 1e-9 * resultant
              && std::fabs(solution.appliedForceN.y - resultant) < 1e-9 * resultant,
          "quarter pipe: pressure resultant on the meshed CAD bore is p·a·t");

    PipeResult result;
    result.elements = mesh.elements.size();
    const auto boreNodes = mesh.nodesOnGroup(bore);
    for (int n : boreNodes) result.meanBoreHoop += hoopStress(solution.nodalStress[n], mesh.nodes[n]);
    result.meanBoreHoop /= static_cast<double>(boreNodes.size());
    std::printf("  maxh %.4f m: %zu TET10, %d DOFs, mean bore σθ %.6g Pa over %zu nodes\n", maxh, result.elements,
                solution.totalDofs, result.meanBoreHoop, boreNodes.size());
    return result;
}

double ratio(std::size_t finerElements, std::size_t coarserElements) {
    return std::cbrt(static_cast<double>(finerElements) / static_cast<double>(coarserElements));
}

} // namespace

int main() {
    OcctKernel kernel;
    check(kernel.isAvailable(), "OCCT kernel available");

    // --- Cantilever solid: a rectangle in the YZ plane extruded along X.
    const auto bar = kernel.makeExtrudedPolygon(
        {{{0.0, 0.0, 0.0}, {0.0, kWidth, 0.0}, {0.0, kWidth, kHeight}, {0.0, 0.0, kHeight}}, {kLength, 0.0, 0.0}});
    check(bar.isOk(), "kernel extrudes the cantilever");
    {
        const SolidMesh solid = meshOrDie(kernel, bar.value(), 0.025);
        faceGroupsFollowKernelFaces(kernel, bar.value(), solid, "bar");
        checkRelative(solid.meshVolumeM3, solid.cadVolumeM3, 1e-10, "bar: mesh volume equals CAD volume (straight faces)");
        const SolidMesh again = meshOrDie(kernel, bar.value(), 0.025);
        bool identical = again.mesh.nodes.size() == solid.mesh.nodes.size()
                         && again.mesh.elements.size() == solid.mesh.elements.size();
        for (std::size_t n = 0; identical && n < solid.mesh.nodes.size(); ++n) {
            identical = length(again.mesh.nodes[n] - solid.mesh.nodes[n]) == 0.0;
        }
        check(identical, "meshing the same part twice gives the identical mesh");
        const auto unset = meshSolid(kernel, bar.value(), SolidMeshingSettings{});
        check(!unset.isOk(), "an unset element size is refused rather than guessed");
    }

    const auto material = *findMaterial("steel_4130");
    const double G = material.youngsModulusPa / (2.0 * (1.0 + material.poissonRatio));
    const double I = kWidth * kHeight * kHeight * kHeight / 12.0;
    const double kappa = 10.0 * (1.0 + material.poissonRatio) / (12.0 + 11.0 * material.poissonRatio);
    const double deflection = kLoad * kLength * kLength * kLength / (3.0 * material.youngsModulusPa * I)
                              + kLoad * kLength / (kappa * G * kWidth * kHeight);
    std::printf("Cantilever from CAD, Timoshenko δ = %.6g m\n", deflection);
    const auto c1 = solveCantilever(kernel, bar.value(), 0.025);
    const auto c2 = solveCantilever(kernel, bar.value(), 0.015);
    const auto c3 = solveCantilever(kernel, bar.value(), 0.009);
    const double r21 = ratio(c3.elements, c2.elements);
    const double r32 = ratio(c2.elements, c1.elements);
    const auto tip = estimateConvergence(c3.tipDeflection, c2.tipDeflection, c1.tipDeflection, r21, r32, 1.25,
                                         kTet10DisplacementOrder);
    fea_test::printConvergence("tip deflection [m]", c1.tipDeflection, c2.tipDeflection, c3.tipDeflection, tip);
    checkRelative(tip.isUsable() ? tip.extrapolated : c3.tipDeflection, deflection, 0.01, "CAD cantilever tip deflection vs Timoshenko");
    const auto bending = estimateConvergence(c3.stressRatio, c2.stressRatio, c1.stressRatio, r21, r32, 1.25, kTet10StressOrder);
    fea_test::printConvergence("σxx / (Mc/I)", c1.stressRatio, c2.stressRatio, c3.stressRatio, bending);
    checkRelative(bending.isUsable() ? bending.extrapolated : c3.stressRatio, 1.0, 0.01, "CAD cantilever bending stress vs Mc/I");

    // --- Quarter pipe: two extruded circles, cut, then common with an extruded square.
    const auto outer = kernel.makeExtrudedCircle({{0, 0, 0}, {0, 0, 1}, kOuter, {0, 0, kThickness}});
    const auto inner = kernel.makeExtrudedCircle({{0, 0, 0}, {0, 0, 1}, kInner, {0, 0, kThickness}});
    check(outer.isOk() && inner.isOk(), "kernel builds the pipe primitives");
    const auto ring = kernel.booleanCut(outer.value(), inner.value());
    check(ring.isOk(), "kernel cuts the bore");
    // booleanCommon is not implemented in the kernel; two cuts remove the other quadrants.
    const auto negativeX = kernel.makeExtrudedPolygon(
        {{{-0.3, -0.3, -0.01}, {0.0, -0.3, -0.01}, {0.0, 0.3, -0.01}, {-0.3, 0.3, -0.01}}, {0, 0, kThickness + 0.02}});
    const auto negativeY = kernel.makeExtrudedPolygon(
        {{{0.0, -0.3, -0.01}, {0.3, -0.3, -0.01}, {0.3, 0.0, -0.01}, {0.0, 0.0, -0.01}}, {0, 0, kThickness + 0.02}});
    check(negativeX.isOk() && negativeY.isOk(), "kernel builds the quadrant cutters");
    const auto half = kernel.booleanCut(ring.value(), negativeX.value());
    const auto quarter = half.isOk() ? kernel.booleanCut(half.value(), negativeY.value()) : half;
    check(quarter.isOk(), "kernel cuts the ring down to one quadrant");
    if (!quarter.isOk()) return fea_test::finish("test_fea_netgen_solids");
    {
        const SolidMesh curved = meshOrDie(kernel, quarter.value(), 0.02);
        faceGroupsFollowKernelFaces(kernel, quarter.value(), curved, "quarter pipe");
        const double exactVolume = M_PI / 4.0 * (kOuter * kOuter - kInner * kInner) * kThickness;
        checkRelative(curved.cadVolumeM3, exactVolume, 1e-9, "quarter pipe: CAD volume is exact");
        checkRelative(curved.meshVolumeM3, curved.cadVolumeM3, 1e-4, "quarter pipe: curved TET10 mesh volume");
    }
    {
        // Straight versus curved elements on a convex solid. (Not on the pipe: there the chords of
        // the bore add material and those of the rim remove it, and the two errors cancel — the
        // first version of this check did exactly that and "found" no difference.)
        const auto cylinder = kernel.makeCylinder({0.1, 0.05});
        check(cylinder.isOk(), "kernel builds a cylinder");
        const SolidMesh curved = meshOrDie(kernel, cylinder.value(), 0.02);
        const SolidMesh straight = meshOrDie(kernel, cylinder.value(), 0.02, ElementOrder::Linear);
        const double exactVolume = M_PI * 0.1 * 0.1 * 0.05;
        const double straightError = std::fabs(straight.mesh.volume() - exactVolume) / exactVolume;
        const double curvedError = std::fabs(curved.meshVolumeM3 - exactVolume) / exactVolume;
        std::printf("  cylinder volume error: TET4 %.2e, TET10 %.2e\n", straightError, curvedError);
        check(straightError > 10.0 * curvedError, "straight elements lose the curvature that quadratic ones keep");
    }

    const double hoopExact = kPressure * (kOuter * kOuter + kInner * kInner) / (kOuter * kOuter - kInner * kInner);
    std::printf("Quarter pipe from CAD, Lamé σθ(a) = %.6g Pa\n", hoopExact);
    const auto p1 = solvePipe(kernel, quarter.value(), 0.03);
    const auto p2 = solvePipe(kernel, quarter.value(), 0.018);
    const auto p3 = solvePipe(kernel, quarter.value(), 0.011);
    const auto hoop = estimateConvergence(p3.meanBoreHoop, p2.meanBoreHoop, p1.meanBoreHoop, ratio(p3.elements, p2.elements),
                                          ratio(p2.elements, p1.elements), 1.25, kTet10StressOrder);
    fea_test::printConvergence("mean bore σθ [Pa]", p1.meanBoreHoop, p2.meanBoreHoop, p3.meanBoreHoop, hoop);
    checkRelative(hoop.isUsable() ? hoop.extrapolated : p3.meanBoreHoop, hoopExact, 0.01, "CAD pipe bore hoop stress vs Lamé");

    return fea_test::finish("test_fea_netgen_solids");
}
