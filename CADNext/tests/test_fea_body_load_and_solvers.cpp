// A bar hanging under its own weight — an exact 3D elasticity solution with a linear stress
// field, which quadratic tetrahedra reproduce — and the independent cross-check of the two
// linear solvers on it.
//
// Exact solution (Timoshenko & Goodier, Theory of Elasticity, §97), bar 0 ≤ z ≤ L hanging from
// z = L under gravity −g:
//   σzz = ρ g z,  σxx = σyy = τ = 0
//   uz(0,0,z) = −ρ g (L² − z²) / (2E)   (with uz = 0 on the axis at the support)
// The support here holds the whole top face at uz = 0, which differs from the exact solution
// by ρ g ν (x² + y²) / (2E) at that face — a relative effect of ν a²/L² ≈ 1e-3 on the tip
// displacement for the proportions below. That, not the discretisation, sets the tolerance.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"

#include <algorithm>
#include <cmath>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

int main() {
    const double L = 1.0;
    const double a = 0.04; // quarter section a × a (full bar 2a × 2a)
    const double g = 9.80665;
    const auto material = *findMaterial("steel_4130");

    MappedBlockSpec spec;
    spec.cellsU = 2;
    spec.cellsV = 2;
    spec.cellsW = 20;
    spec.mapping = [&](double u, double v, double w) { return Vec3{u * a, v * a, w * L}; };
    spec.faceNames = {"sym_x0", "", "sym_y0", "", "", "top"};
    const TetMesh mesh = generateMappedBlock(spec);

    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.bodyAcceleration = {0.0, 0.0, -g};
    problem.constraints.push_back({mesh.nodesOnGroup("sym_x0"), {0.0, std::nullopt, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("sym_y0"), {std::nullopt, 0.0, std::nullopt}});
    problem.constraints.push_back({mesh.nodesOnGroup("top"), {std::nullopt, std::nullopt, 0.0}});

    std::printf("Hanging bar under self-weight, %zu nodes, %zu TET10\n", mesh.nodes.size(), mesh.elements.size());
    const auto direct = fea_test::solveOrDie(problem);

    const double weight = material.densityKgPerM3 * g * a * a * L;
    checkRelative(-direct.appliedForceN.z, weight, 1e-12, "consistent body load sums to the weight");
    checkRelative(direct.reactionForceN.z, weight, 1e-9, "support reaction balances the weight");
    check(direct.freeResidualRelative < 1e-10,
          "direct solve leaves no residual (" + std::to_string(direct.freeResidualRelative) + ")");

    const double tipExact = -material.densityKgPerM3 * g * L * L / (2.0 * material.youngsModulusPa);
    const int tip = mesh.nearestNode({0.0, 0.0, 0.0});
    checkRelative(direct.displacement[tip].z, tipExact, 2e-3, "tip displacement ρgL²/2E");

    const int mid = mesh.nearestNode({a * 0.5, a * 0.5, 0.5 * L});
    checkRelative(direct.nodalStress[mid][2], material.densityKgPerM3 * g * 0.5 * L, 2e-3, "mid-height σzz = ρg·L/2");
    double worstTransverse = 0.0;
    for (int n = 0; n < static_cast<int>(mesh.nodes.size()); ++n) {
        if (mesh.nodes[n].z < 0.2 * L) { // away from the support's local disturbance
            worstTransverse = std::max({worstTransverse, std::fabs(direct.nodalStress[n][0]), std::fabs(direct.nodalStress[n][1])});
        }
    }
    check(worstTransverse < 1e-2 * material.densityKgPerM3 * g * L,
          "transverse stress vanishes away from the support (worst " + std::to_string(worstTransverse) + " Pa)");

    // Independent solver on the same system.
    LinearStaticSettings iterative;
    iterative.solver = LinearSolverKind::JacobiConjugateGradient;
    const auto cg = fea_test::solveOrDie(problem, iterative);
    double worstDifference = 0.0;
    for (std::size_t n = 0; n < mesh.nodes.size(); ++n) {
        worstDifference = std::max(worstDifference, length(cg.displacement[n] - direct.displacement[n]));
    }
    check(worstDifference < 1e-8 * direct.maxDisplacementM,
          "Accelerate Cholesky and Jacobi-CG agree (worst relative " + std::to_string(worstDifference / direct.maxDisplacementM)
              + ", CG iterations " + std::to_string(cg.solverIterations) + ")");

    return fea_test::finish("test_fea_body_load_and_solvers");
}
