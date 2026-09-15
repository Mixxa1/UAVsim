// Cantilever under an end shear load — the case every UAV spar, boom and arm is.
//
// Reference: Timoshenko beam, δ = PL³/(3EI) + PL/(κGA), κ = 10(1+ν)/(12+11ν) for a rectangle
// (Cowper, J. Appl. Mech. 33 (1966)); bending stress σxx = M·c/I, which is exact in 3D
// elasticity away from the ends (Saint-Venant flexure).
//
// Tolerances, fixed before the first run and why:
//  - tip deflection 1.0 %: the model clamps the whole root face, which the beam theory does
//    not; for L/h = 20 that root restraint is a few tenths of a percent.
//  - mid-span bending stress 0.5 %: exact solution, only discretisation remains.
//
// The same geometry with 4-node tetrahedra shows why the production element is TET10:
// constant-strain tetrahedra lock in bending. The 20 % threshold below is not a tolerance
// but the claim being demonstrated ("unusable at practical meshes").

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kLength = 1.0;
constexpr double kWidth = 0.05;
constexpr double kHeight = 0.05;
constexpr double kLoad = 1000.0;

struct Measurement {
    double tipDeflection = 0.0;
    double midSpanStress = 0.0;
    std::size_t dofs = 0;
};

Measurement run(ElementOrder order, int lengthCells, int sectionCells) {
    MappedBlockSpec spec;
    spec.cellsU = lengthCells;
    spec.cellsV = sectionCells;
    spec.cellsW = sectionCells;
    spec.order = order;
    spec.mapping = [](double u, double v, double w) { return Vec3{u * kLength, v * kWidth, w * kHeight}; };
    spec.faceNames = {"root", "tip", "", "", "", ""};
    const TetMesh mesh = generateMappedBlock(spec);

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = *findMaterial("steel_4130");
    problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
    problem.tractions.push_back({"tip", {0.0, 0.0, -kLoad / (kWidth * kHeight)}});
    const auto solution = fea_test::solveOrDie(problem);

    checkRelative(-solution.appliedForceN.z, kLoad, 1e-12,
                  "tip traction integrates to the load (" + std::to_string(mesh.elements.size()) + " elements)");
    Measurement m;
    m.tipDeflection = -solution.displacement[mesh.nearestNode({kLength, kWidth / 2, kHeight / 2})].z;
    m.midSpanStress = solution.nodalStress[mesh.nearestNode({kLength / 2, kWidth / 2, kHeight})][0];
    m.dofs = static_cast<std::size_t>(solution.totalDofs);
    return m;
}

} // namespace

int main() {
    const auto material = *findMaterial("steel_4130");
    const double E = material.youngsModulusPa;
    const double nu = material.poissonRatio;
    const double G = E / (2.0 * (1.0 + nu));
    const double I = kWidth * kHeight * kHeight * kHeight / 12.0;
    const double area = kWidth * kHeight;
    const double kappa = 10.0 * (1.0 + nu) / (12.0 + 11.0 * nu);
    const double bending = kLoad * kLength * kLength * kLength / (3.0 * E * I);
    const double shear = kLoad * kLength / (kappa * G * area);
    const double deflection = bending + shear;
    const double stress = kLoad * (kLength / 2.0) * (kHeight / 2.0) / I;
    std::printf("Cantilever L/h = %.0f: Timoshenko δ = %.6g m (shear part %.2f%%), σ(L/2) = %.6g Pa\n",
                kLength / kHeight, deflection, 100.0 * shear / deflection, stress);

    const Measurement coarse = run(ElementOrder::Quadratic, 20, 1);
    const Measurement medium = run(ElementOrder::Quadratic, 40, 2);
    const Measurement fine = run(ElementOrder::Quadratic, 80, 4);
    std::printf("  TET10 DOFs: %zu / %zu / %zu\n", coarse.dofs, medium.dofs, fine.dofs);

    const auto deflectionStudy = estimateConvergence(fine.tipDeflection, medium.tipDeflection, coarse.tipDeflection, 2.0);
    fea_test::printConvergence("tip deflection [m]", coarse.tipDeflection, medium.tipDeflection, fine.tipDeflection, deflectionStudy);
    check(deflectionStudy.isUsable(), "tip deflection converges");
    checkRelative(deflectionStudy.extrapolated, deflection, 0.010, "TET10 tip deflection vs Timoshenko");

    const auto stressStudy = estimateConvergence(fine.midSpanStress, medium.midSpanStress, coarse.midSpanStress, 2.0);
    fea_test::printConvergence("mid-span σxx [Pa]", coarse.midSpanStress, medium.midSpanStress, fine.midSpanStress, stressStudy);
    check(stressStudy.isUsable(), "bending stress converges");
    checkRelative(stressStudy.extrapolated, stress, 0.005, "TET10 bending stress vs Mc/I");
    check(std::fabs(stressStudy.extrapolated - stress) <= std::max(stressStudy.uncertaintyAbsolute, 0.005 * stress),
          "the reported uncertainty band is honest for the stress");

    // Locking demonstration.
    const Measurement linear = run(ElementOrder::Linear, 40, 2);
    const double linearError = std::fabs(linear.tipDeflection - deflection) / deflection;
    const double quadraticError = std::fabs(medium.tipDeflection - deflection) / deflection;
    std::printf("  same 40×2×2 mesh: TET4 error %.1f%%, TET10 error %.2f%%\n", linearError * 100.0, quadraticError * 100.0);
    check(linearError > 0.20, "TET4 locks in bending (error > 20 %)");
    check(quadraticError < 0.02, "TET10 on the same mesh is within 2 %");

    return fea_test::finish("test_fea_benchmark_cantilever");
}
