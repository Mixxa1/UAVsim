// Stress concentration at a circular hole in a finite-width plate under tension — the case of
// every bolt hole, lightening hole and cable pass-through in a UAV frame.
//
// Reference: gross-section Kt for d/W = 0.2 is 3.14 (Howland, Phil. Trans. R. Soc. A 229
// (1930); Heywood's fit Kt,net = 2 + (1 − d/W)³ gives the same 3.14; Peterson's Stress
// Concentration Factors, chart 4.1).
//
// Model: quarter plate, symmetry on both axes, loaded far from the hole (half-length 4× the
// half-width, so the end effect has decayed), thin enough (t = R/20) for plane stress; mid-
// plane held in z. Two mapped blocks with a conforming interface; radial grading towards the
// hole kept geometrically similar across refinements so the three meshes form one family.
//
// Tolerance 1.5 %, fixed before the first run: the reference is quoted to three figures
// (±0.2 %), the through-thickness 3D effect at t/R = 0.05 is below 0.5 %, the finite plate
// length a few tenths — the rest is left for discretisation.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kRadius = 0.01;
constexpr double kHalfWidth = 0.05;
constexpr double kHalfLength = 0.20;
constexpr double kThickness = kRadius / 20.0;
constexpr double kStress = 1.0e6;

double run(int radialCells, int angularCells, int stripCells) {
    // Grading functions are fixed continuous maps, identical at every refinement level.
    const Distribution radialGrading = geometricGrading(4, 1.6);
    const Distribution stripGrading = geometricGrading(4, 1.4);

    MappedBlockSpec hole;
    hole.cellsU = radialCells;
    hole.cellsV = angularCells; // even: θ = 45° is a grid line, where the outer square has its corner
    hole.cellsW = 1;
    hole.distributeU = radialGrading;
    hole.mapping = [](double u, double v, double w) {
        const double theta = v * M_PI / 2.0;
        const Vec3 inner{kRadius * std::cos(theta), kRadius * std::sin(theta), 0.0};
        const Vec3 outer = theta <= M_PI / 4.0 ? Vec3{kHalfWidth, kHalfWidth * std::tan(theta), 0.0}
                                                : Vec3{kHalfWidth / std::tan(theta), kHalfWidth, 0.0};
        Vec3 p = inner + (outer - inner) * u;
        p.z = w * kThickness;
        return p;
    };
    hole.faceNames = {"hole", "", "sym_y0", "sym_x0", "", ""};

    MappedBlockSpec strip;
    strip.cellsU = angularCells / 2;
    strip.cellsV = stripCells;
    strip.cellsW = 1;
    strip.distributeV = stripGrading;
    // x follows the hole block's upper edge node for node: θ = 45° + u·45°, x = c / tan θ.
    strip.mapping = [](double u, double v, double w) {
        const double theta = M_PI / 4.0 + u * M_PI / 4.0;
        return Vec3{kHalfWidth / std::tan(theta), kHalfWidth + v * (kHalfLength - kHalfWidth), w * kThickness};
    };
    strip.faceNames = {"", "sym_x0", "", "load", "", ""};

    const TetMesh mesh = mergeMeshes({generateMappedBlock(hole), generateMappedBlock(strip)}, 1e-9);

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = *findMaterial("al_7075_t6");
    problem.constraints.push_back({mesh.nodesOnGroup("sym_x0"), {0.0, std::nullopt, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("sym_y0"), {std::nullopt, 0.0, std::nullopt}});
    problem.constraints.push_back({mesh.nodesWhere([](const Vec3& p) { return std::fabs(p.z - kThickness / 2) < 1e-12; }),
                                   {std::nullopt, std::nullopt, 0.0}});
    problem.tractions.push_back({"load", {0.0, kStress, 0.0}});
    const auto solution = fea_test::solveOrDie(problem);

    checkRelative(solution.appliedForceN.y, kStress * kHalfWidth * kThickness, 1e-10,
                  "end load integrates to σ·c·t (" + std::to_string(mesh.elements.size()) + " elements)");
    check(solution.freeResidualRelative < 1e-9, "merged two-block mesh solves cleanly");
    return solution.nodalStress[mesh.nearestNode({kRadius, 0.0, kThickness / 2})][1] / kStress;
}

} // namespace

int main() {
    const double d = 2.0 * kRadius;
    const double W = 2.0 * kHalfWidth;
    const double heywood = (2.0 + std::pow(1.0 - d / W, 3.0)) / (1.0 - d / W);
    std::printf("Plate with hole d/W = %.2f: Kt,gross (Heywood) = %.4f, Howland 3.14\n", d / W, heywood);

    const double coarse = run(4, 8, 4);
    const double medium = run(8, 16, 8);
    const double fine = run(16, 32, 16);
    const auto study = estimateConvergence(fine, medium, coarse, 2.0);
    fea_test::printConvergence("Kt,gross", coarse, medium, fine, study);
    check(study.isUsable(), "stress concentration converges");
    checkRelative(study.extrapolated, 3.14, 0.015, "Kt vs Howland (d/W = 0.2)");

    return fea_test::finish("test_fea_benchmark_plate_with_hole");
}
