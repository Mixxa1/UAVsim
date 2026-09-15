// Element-level verification of the tetrahedra: shape-function identities, rigid-body modes,
// the patch test (Irons; MacNeal & Harder, Finite Elem. Anal. Des. 1 (1985)) on a distorted
// curved mesh, and the solver's refusal to answer ill-posed problems.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/TetElement.hpp"

#include <algorithm>
#include <cmath>
#include <set>

using namespace cadnext::fea;
using fea_test::check;

namespace {

TetMesh distortedCube(ElementOrder order, int cells) {
    MappedBlockSpec spec;
    spec.cellsU = spec.cellsV = spec.cellsW = cells;
    spec.order = order;
    // Curved, non-affine interior and boundary: midside nodes leave the straight edges.
    spec.mapping = [](double u, double v, double w) {
        return Vec3{u + 0.08 * std::sin(M_PI * v) * std::sin(M_PI * w),
                    v + 0.06 * std::sin(M_PI * u) * w,
                    w + 0.05 * u * v};
    };
    spec.faceNames = {"u0", "u1", "v0", "v1", "w0", "w1"};
    return generateMappedBlock(spec);
}

IsotropicMaterial testMaterial() {
    return *findMaterial("al_7075_t6");
}

void shapeFunctionIdentities(ElementOrder order, const char* label) {
    const int count = order == ElementOrder::Quadratic ? 10 : 4;
    double worstSum = 0.0;
    double worstGradient = 0.0;
    const Vec3 samples[] = {{0.1, 0.2, 0.3}, {0.25, 0.25, 0.25}, {0.7, 0.1, 0.05}, {0.0, 0.0, 1.0}};
    for (const auto& xi : samples) {
        double N[10];
        Vec3 dN[10];
        tetShapeFunctions(order, xi, N, dN);
        double sum = 0.0;
        Vec3 gradient;
        for (int n = 0; n < count; ++n) {
            sum += N[n];
            gradient += dN[n];
        }
        worstSum = std::max(worstSum, std::fabs(sum - 1.0));
        worstGradient = std::max(worstGradient, length(gradient));
    }
    check(worstSum < 1e-14, std::string(label) + ": shape functions sum to one");
    check(worstGradient < 1e-13, std::string(label) + ": reference gradients sum to zero");

    // Kronecker property at the nodes.
    const Vec3 nodeXi[10] = {{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {0.5, 0, 0},
                             {0.5, 0.5, 0}, {0, 0.5, 0}, {0, 0, 0.5}, {0.5, 0, 0.5}, {0, 0.5, 0.5}};
    double worstKronecker = 0.0;
    for (int m = 0; m < count; ++m) {
        double N[10];
        Vec3 dN[10];
        tetShapeFunctions(order, nodeXi[m], N, dN);
        for (int n = 0; n < count; ++n) worstKronecker = std::max(worstKronecker, std::fabs(N[n] - (m == n ? 1.0 : 0.0)));
    }
    check(worstKronecker < 1e-14, std::string(label) + ": N_i(x_j) = δ_ij");
}

void rigidBodyModes(ElementOrder order, const char* label) {
    const TetMesh mesh = distortedCube(order, 1);
    const auto D = isotropicElasticity(70e9, 0.33);
    const int count = mesh.nodesPerElement();
    double worst = 0.0;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        std::vector<double> K;
        tetStiffness(mesh, e, D, K);
        const int size = 3 * count;
        double norm = 0.0;
        for (double k : K) norm = std::max(norm, std::fabs(k));
        for (int mode = 0; mode < 6; ++mode) {
            std::vector<double> u(size);
            for (int n = 0; n < count; ++n) {
                const Vec3 x = mesh.nodes[mesh.elements[e][n]];
                Vec3 d;
                if (mode < 3) {
                    d[mode] = 1.0;
                } else {
                    Vec3 axis;
                    axis[mode - 3] = 1.0;
                    d = cross(axis, x);
                }
                for (int c = 0; c < 3; ++c) u[3 * n + c] = d[c];
            }
            for (int i = 0; i < size; ++i) {
                double f = 0.0;
                for (int j = 0; j < size; ++j) f += K[static_cast<std::size_t>(i) * size + j] * u[j];
                worst = std::max(worst, std::fabs(f) / norm);
            }
        }
    }
    check(worst < 1e-12, std::string(label) + ": rigid-body modes carry no force (worst " + std::to_string(worst) + ")");
}

void patchTest(ElementOrder order, const char* label) {
    const TetMesh mesh = distortedCube(order, 3);
    const auto material = testMaterial();
    // Arbitrary linear field: every element must reproduce it exactly.
    const double A[3][3] = {{1.2e-3, -0.4e-3, 0.7e-3}, {0.3e-3, -0.9e-3, 0.2e-3}, {-0.5e-3, 0.6e-3, 0.4e-3}};
    const Vec3 offset{1e-4, -2e-4, 3e-4};
    auto exact = [&](const Vec3& x) {
        Vec3 u = offset;
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j) u[i] += A[i][j] * x[j];
        return u;
    };
    std::set<int> boundary;
    for (const auto& [name, faces] : mesh.faceGroups) {
        const auto nodes = mesh.nodesOnGroup(name);
        boundary.insert(nodes.begin(), nodes.end());
    }
    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    for (int node : boundary) {
        const Vec3 u = exact(mesh.nodes[node]);
        problem.constraints.push_back({{node}, {u.x, u.y, u.z}});
    }
    const auto solution = fea_test::solveOrDie(problem);

    double worstDisplacement = 0.0;
    int interior = 0;
    for (int n = 0; n < static_cast<int>(mesh.nodes.size()); ++n) {
        if (boundary.count(n)) continue;
        ++interior;
        worstDisplacement = std::max(worstDisplacement, length(solution.displacement[n] - exact(mesh.nodes[n])));
    }
    const Voigt strain = {A[0][0], A[1][1], A[2][2], A[1][2] + A[2][1], A[0][2] + A[2][0], A[0][1] + A[1][0]};
    const auto D = isotropicElasticity(material.youngsModulusPa, material.poissonRatio);
    Voigt stress{};
    for (int r = 0; r < 6; ++r)
        for (int k = 0; k < 6; ++k) stress[r] += D[r][k] * strain[k];
    double stressScale = 0.0;
    for (double s : stress) stressScale = std::max(stressScale, std::fabs(s));
    double worstStress = 0.0;
    for (const auto& s : solution.nodalStress)
        for (int c = 0; c < 6; ++c) worstStress = std::max(worstStress, std::fabs(s[c] - stress[c]) / stressScale);

    check(interior > 0, std::string(label) + ": patch has interior nodes (" + std::to_string(interior) + ")");
    check(worstDisplacement < 1e-12,
          std::string(label) + ": patch test — interior displacements exact (worst " + std::to_string(worstDisplacement) + " m)");
    check(worstStress < 1e-8,
          std::string(label) + ": patch test — constant stress exact everywhere (worst relative " + std::to_string(worstStress) + ")");
}

} // namespace

// ∫ ξ^a η^b ζ^c over the reference tetrahedron = a! b! c! / (a + b + c + 3)!
void quadratureExactness(const std::vector<QuadraturePoint>& rule, int degree, const char* label) {
    auto factorial = [](int n) { double f = 1.0; for (int i = 2; i <= n; ++i) f *= i; return f; };
    double worst = 0.0;
    for (int a = 0; a <= degree; ++a)
        for (int b = 0; a + b <= degree; ++b)
            for (int c = 0; a + b + c <= degree; ++c) {
                double sum = 0.0;
                for (const auto& q : rule) sum += q.weight * std::pow(q.xi.x, a) * std::pow(q.xi.y, b) * std::pow(q.xi.z, c);
                const double exact = factorial(a) * factorial(b) * factorial(c) / factorial(a + b + c + 3);
                worst = std::max(worst, std::fabs(sum - exact) / exact);
            }
    check(worst < 1e-12, std::string(label) + ": integrates every monomial up to degree " + std::to_string(degree)
                             + " exactly (worst " + std::to_string(worst) + ")");
}

int main() {
    quadratureExactness(tetQuadratureDegree2(), 2, "4-point tetrahedron rule");
    quadratureExactness(tetQuadratureDegree5(), 5, "14-point tetrahedron rule");
    shapeFunctionIdentities(ElementOrder::Linear, "TET4");
    shapeFunctionIdentities(ElementOrder::Quadratic, "TET10");

    double weights = 0.0;
    for (const auto& q : tetQuadratureDegree2()) weights += q.weight;
    check(std::fabs(weights - 1.0 / 6.0) < 1e-15, "tetrahedron rule weights sum to the reference volume");
    double triangleWeights = 0.0;
    for (const auto& q : triangleQuadratureDegree4()) triangleWeights += q.weight;
    check(std::fabs(triangleWeights - 0.5) < 1e-14, "triangle rule weights sum to the reference area");

    rigidBodyModes(ElementOrder::Linear, "TET4");
    rigidBodyModes(ElementOrder::Quadratic, "TET10");
    patchTest(ElementOrder::Linear, "TET4");
    patchTest(ElementOrder::Quadratic, "TET10 (curved)");

    // Ill-posed problems are refused with a reason, never answered.
    {
        const TetMesh mesh = distortedCube(ElementOrder::Quadratic, 2);
        LinearStaticProblem problem;
        problem.mesh = &mesh;
        problem.material = testMaterial();
        problem.tractions.push_back({"u1", {1e6, 0, 0}});
        const auto free = solveLinearStatic(problem);
        check(!free.isOk() && free.error().message.find("не закреплена") != std::string::npos,
              "unsupported body is refused", free.isOk() ? "solved" : free.error().message);

        problem.constraints.push_back({mesh.nodesOnGroup("u0"), {0.0, std::nullopt, std::nullopt}});
        const auto sliding = solveLinearStatic(problem);
        check(!sliding.isOk() && sliding.error().message.find("не закреплена") != std::string::npos,
              "a face held only normal to itself is refused (it can slide and spin)",
              sliding.isOk() ? "solved" : sliding.error().message);

        problem.constraints = {{mesh.nodesOnGroup("u0"), {0.0, 0.0, 0.0}}};
        // Mirrored consistently: corners 1↔2 with their midsides (0,1)↔(0,2), (1,3)↔(2,3).
        TetMesh inverted = mesh;
        auto& mirrored = inverted.elements[5];
        std::swap(mirrored[1], mirrored[2]);
        std::swap(mirrored[4], mirrored[6]);
        std::swap(mirrored[8], mirrored[9]);
        problem.mesh = &inverted;
        const auto bad = solveLinearStatic(problem);
        check(!bad.isOk() && bad.error().code == cadnext::ErrorCode::ShapeInvalid,
              "an inverted element is refused", bad.isOk() ? "solved" : bad.error().message);

        // Corners swapped but midsides left behind: a folded element, positive at some
        // quadrature points and negative elsewhere.
        TetMesh folded = mesh;
        std::swap(folded.elements[5][1], folded.elements[5][2]);
        problem.mesh = &folded;
        const auto foldedResult = solveLinearStatic(problem);
        check(!foldedResult.isOk() && foldedResult.error().code == cadnext::ErrorCode::ShapeInvalid,
              "a folded element is refused", foldedResult.isOk() ? "solved" : foldedResult.error().message);
    }

    return fea_test::finish("test_fea_element");
}
