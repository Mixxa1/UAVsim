// NAFEMS LE1 — elliptic membrane (NAFEMS, "The Standard NAFEMS Benchmarks", TNSB rev. 3,
// 1990). Quarter elliptic ring, inner ellipse (x/2)² + y² = 1, outer (x/3.25)² + (y/2.75)² = 1,
// thickness 0.1 m, E = 210 GPa, ν = 0.3, outward pressure 10 MPa on the outer edge, ux = 0 on
// x = 0, uy = 0 on y = 0, plane stress. Target: σyy at D (2, 0) = 92.7 MPa.
//
// Solved as a thin 3D slab with its mid-plane held in z, which is plane stress.
// Tolerance 1 %, fixed before the first run: the target is published to three figures.
//
// ⚠️ The first run used the 2×4 / 4×8 / 8×16 family and failed: 71.1 → 82.7 → 88.9 MPa,
// observed order 0.92 — pre-asymptotic, the stress gradient at D (curvature radius 0.5 m) not
// yet resolved. The tolerance was not touched. Refining further (16×32: 91.50, 32×64: 92.47,
// σxx at the free edge → 0.25 MPa) showed the solver converging to the target, so the gate
// uses 8×16 / 16×32 / 32×64. The coarse family is kept below for a different claim: its GCI
// band (≈ ±9.7 %) did contain the true value, i.e. the uncertainty estimate was honest even
// where the mesh was not good enough.

#include "fea_test_support.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kThickness = 0.1;

double run(int radialCells, int angularCells) {
    MappedBlockSpec spec;
    spec.cellsU = radialCells;
    spec.cellsV = angularCells;
    spec.cellsW = 1;
    spec.mapping = [](double u, double v, double w) {
        const double t = v * M_PI / 2.0;
        const Vec3 inner{2.0 * std::cos(t), 1.0 * std::sin(t), 0.0};
        const Vec3 outer{3.25 * std::cos(t), 2.75 * std::sin(t), 0.0};
        Vec3 p = inner + (outer - inner) * u;
        p.z = w * kThickness;
        return p;
    };
    spec.faceNames = {"inner", "outer", "edge_cd", "edge_ab", "", ""};
    const TetMesh mesh = generateMappedBlock(spec);

    IsotropicMaterial material;
    material.id = "nafems_le1";
    material.densityKgPerM3 = 7800.0;
    material.youngsModulusPa = 210.0e9;
    material.poissonRatio = 0.3;
    material.ultimateStrengthPa = 1.0e9;

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.constraints.push_back({mesh.nodesOnGroup("edge_ab"), {0.0, std::nullopt, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("edge_cd"), {std::nullopt, 0.0, std::nullopt}});
    problem.constraints.push_back({mesh.nodesWhere([](const Vec3& p) { return std::fabs(p.z - kThickness / 2) < 1e-12; }),
                                   {std::nullopt, std::nullopt, 0.0}});
    problem.pressures.push_back({"outer", -10.0e6}); // outward: negative pressure pulls
    const auto solution = fea_test::solveOrDie(problem);

    // Resultant of an outward pull over the quarter outer ellipse: (p·3.25·t... projected)
    // x: p · (2.75) · t, y: p · (3.25) · t.
    check(std::fabs(solution.appliedForceN.x - 10.0e6 * 2.75 * kThickness) < 1e-6 * 10.0e6 * 2.75 * kThickness
              && std::fabs(solution.appliedForceN.y - 10.0e6 * 3.25 * kThickness) < 1e-6 * 10.0e6 * 3.25 * kThickness,
          "outer pressure resultant matches the projected edge (" + std::to_string(radialCells) + "×"
              + std::to_string(angularCells) + ")");
    return solution.nodalStress[mesh.nearestNode({2.0, 0.0, kThickness / 2})][1];
}

} // namespace

int main() {
    std::printf("NAFEMS LE1 elliptic membrane: target σyy(D) = 92.7 MPa\n");
    const double level2 = run(2, 4);
    const double level4 = run(4, 8);
    const double level8 = run(8, 16);
    const double level16 = run(16, 32);
    const double level32 = run(32, 64);

    const auto coarseFamily = estimateConvergence(level8, level4, level2, 2.0);
    fea_test::printConvergence("σyy at D, coarse family", level2, level4, level8, coarseFamily);
    check(std::fabs(level8 - 92.7e6) <= coarseFamily.uncertaintyAbsolute,
          "coarse family: the GCI band contains the target although the value misses it");

    const auto study = estimateConvergence(level32, level16, level8, 2.0);
    fea_test::printConvergence("σyy at D [Pa]", level8, level16, level32, study);
    check(study.isUsable(), "σyy at D converges");
    checkRelative(study.extrapolated, 92.7e6, 0.01, "NAFEMS LE1 σyy(D)");
    checkRelative(level32, 92.7e6, 0.02, "NAFEMS LE1 σyy(D), finest mesh alone");

    return fea_test::finish("test_fea_benchmark_nafems_le1");
}
