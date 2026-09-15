// Thick-walled cylinder under internal pressure, plane strain — Lamé's exact solution:
//   σθ(r) = p a²/(b²−a²) · (1 + b²/r²),  σr(r) = p a²/(b²−a²) · (1 − b²/r²)
//   u_r(r) = (1+ν) p a² / (E (b²−a²)) · ((1−2ν) r + b²/r)
// Curved geometry, pressure following the surface normal, symmetry planes.
//
// Tolerances, fixed before the first run: exact solution, so only discretisation remains —
// 0.5 % on the peak hoop stress, 0.2 % on displacement (converges one order faster).
// The pressure resultant over the quarter bore is p·a·t *exactly* for any discretisation
// whose boundary nodes sit on the arc ends (∫n dA depends on the boundary curve only), which
// makes it a round-off test of the surface-load assembly and its normals.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kInner = 0.10;
constexpr double kOuter = 0.20;
constexpr double kThickness = 0.02;
constexpr double kPressure = 10.0e6;

struct Measurement {
    double innerHoop = 0.0;
    double outerHoop = 0.0;
    double innerRadial = 0.0;
};

Measurement run(int radialCells, int angularCells, const IsotropicMaterial& material) {
    MappedBlockSpec spec;
    spec.cellsU = radialCells;
    spec.cellsV = angularCells;
    spec.cellsW = 1;
    spec.mapping = [](double u, double v, double w) {
        const double r = kInner + (kOuter - kInner) * u;
        const double theta = v * M_PI / 2.0;
        return Vec3{r * std::cos(theta), r * std::sin(theta), w * kThickness};
    };
    spec.faceNames = {"bore", "outer", "sym_y0", "sym_x0", "end0", "end1"};
    const TetMesh mesh = generateMappedBlock(spec);

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.constraints.push_back({mesh.nodesOnGroup("sym_y0"), {std::nullopt, 0.0, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("sym_x0"), {0.0, std::nullopt, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("end0"), {std::nullopt, std::nullopt, 0.0}});
    problem.constraints.push_back({mesh.nodesOnGroup("end1"), {std::nullopt, std::nullopt, 0.0}});
    problem.pressures.push_back({"bore", kPressure});
    const auto solution = fea_test::solveOrDie(problem);

    const double resultant = kPressure * kInner * kThickness;
    check(std::fabs(solution.appliedForceN.x - resultant) < 1e-9 * resultant
              && std::fabs(solution.appliedForceN.y - resultant) < 1e-9 * resultant
              && std::fabs(solution.appliedForceN.z) < 1e-9 * resultant,
          "pressure resultant is p·a·t exactly (" + std::to_string(radialCells) + "×" + std::to_string(angularCells) + ")");

    Measurement m;
    const int bore = mesh.nearestNode({kInner, 0.0, kThickness / 2});
    const int rim = mesh.nearestNode({kOuter, 0.0, kThickness / 2});
    m.innerHoop = solution.nodalStress[bore][1];
    m.outerHoop = solution.nodalStress[rim][1];
    m.innerRadial = solution.displacement[bore].x;
    return m;
}

} // namespace

int main() {
    const auto material = *findMaterial("steel_4130");
    const double E = material.youngsModulusPa;
    const double nu = material.poissonRatio;
    const double factor = kPressure * kInner * kInner / (kOuter * kOuter - kInner * kInner);
    const double hoopInner = factor * (1.0 + kOuter * kOuter / (kInner * kInner));
    const double hoopOuter = factor * 2.0;
    const double radialInner = (1.0 + nu) * factor / E * ((1.0 - 2.0 * nu) * kInner + kOuter * kOuter / kInner);
    std::printf("Lamé cylinder b/a = 2: σθ(a) = %.6g Pa, σθ(b) = %.6g Pa, u(a) = %.6g m\n", hoopInner, hoopOuter, radialInner);

    const Measurement coarse = run(2, 4, material);
    const Measurement medium = run(4, 8, material);
    const Measurement fine = run(8, 16, material);

    const auto hoop = estimateConvergence(fine.innerHoop, medium.innerHoop, coarse.innerHoop, 2.0);
    fea_test::printConvergence("σθ at the bore [Pa]", coarse.innerHoop, medium.innerHoop, fine.innerHoop, hoop);
    check(hoop.isUsable(), "bore hoop stress converges");
    checkRelative(hoop.extrapolated, hoopInner, 0.005, "peak hoop stress vs Lamé");

    const auto rim = estimateConvergence(fine.outerHoop, medium.outerHoop, coarse.outerHoop, 2.0);
    fea_test::printConvergence("σθ at the rim [Pa]", coarse.outerHoop, medium.outerHoop, fine.outerHoop, rim);
    checkRelative(rim.isUsable() ? rim.extrapolated : fine.outerHoop, hoopOuter, 0.005, "rim hoop stress vs Lamé");

    const auto radial = estimateConvergence(fine.innerRadial, medium.innerRadial, coarse.innerRadial, 2.0);
    fea_test::printConvergence("u_r at the bore [m]", coarse.innerRadial, medium.innerRadial, fine.innerRadial, radial);
    checkRelative(radial.isUsable() ? radial.extrapolated : fine.innerRadial, radialInner, 0.002, "bore displacement vs Lamé");

    return fea_test::finish("test_fea_benchmark_lame_cylinder");
}
