#include "cadnext/fea/LinearStatic.hpp"

#include "cadnext/fea/TetElement.hpp"

#include "SystemAssembly.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>

namespace cadnext::fea {

namespace {

Result<LinearStaticSolution> failure(ErrorCode code, const std::string& message) {
    return Result<LinearStaticSolution>::fail({code, message});
}

} // namespace

Result<LinearStaticSolution> solveLinearStatic(const LinearStaticProblem& problem,
                                               const LinearStaticSettings& settings) {
    using namespace detail;
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) {
        return failure(ErrorCode::InvalidArgument, "пустая сетка");
    }
    if (!problem.material.isValid()) {
        return failure(ErrorCode::InvalidArgument, "некорректный материал: " + problem.material.id);
    }
    const TetMesh& mesh = *problem.mesh;
    const int nodeCount = static_cast<int>(mesh.nodes.size());
    const int perElement = mesh.nodesPerElement();
    const int dofs = 3 * nodeCount;
    if (const auto problemWithNodes = checkElementNodes(mesh)) return failure(ErrorCode::InvalidArgument, *problemWithNodes);

    DofMap map;
    if (const auto problemWithConstraints = buildDofMap(mesh, problem.constraints, map)) {
        return failure(ErrorCode::InvalidArgument, *problemWithConstraints);
    }
    if (const auto motion = freeRigidBodyMotion(mesh, map)) {
        return failure(ErrorCode::InvalidArgument, "конструкция не закреплена: свободное смещение как целого (" + *motion + ")");
    }
    const auto& prescribed = map.prescribed;
    const auto& reduced = map.reduced;
    const int freeCount = map.freeCount;
    SymmetricCsc K = reducedSparsity(mesh, map);

    // --- External forces.
    std::vector<double> external(dofs, 0.0);
    for (const auto& nodal : problem.nodalForces) {
        if (nodal.node < 0 || nodal.node >= nodeCount) {
            return failure(ErrorCode::InvalidArgument, "сосредоточенная сила в несуществующем узле");
        }
        for (int c = 0; c < 3; ++c) external[3 * nodal.node + c] += nodal.forceN[c];
    }
    auto integrateFaces = [&](const std::string& group, const Vec3* traction, const double* pressure) {
        const auto found = mesh.faceGroups.find(group);
        if (found == mesh.faceGroups.end()) return false;
        const int faceNodeCount = mesh.order == ElementOrder::Quadratic ? 6 : 3;
        for (const auto& face : found->second) {
            const auto nodes = mesh.faceNodes(face);
            for (const auto& q : triangleQuadratureDegree4()) {
                double N[6], dS[6], dT[6];
                triangleShapeFunctions(mesh.order, q.s, q.t, N, dS, dT);
                Vec3 xs, xt;
                for (int n = 0; n < faceNodeCount; ++n) {
                    xs += mesh.nodes[nodes[n]] * dS[n];
                    xt += mesh.nodes[nodes[n]] * dT[n];
                }
                const Vec3 areaNormal = cross(xs, xt); // outward, |·| = dA / (ds dt)
                const Vec3 load = traction ? (*traction) * length(areaNormal) : areaNormal * (-*pressure);
                for (int n = 0; n < faceNodeCount; ++n) {
                    for (int c = 0; c < 3; ++c) external[3 * nodes[n] + c] += N[n] * load[c] * q.weight;
                }
            }
        }
        return true;
    };
    for (const auto& traction : problem.tractions) {
        if (!integrateFaces(traction.faceGroup, &traction.tractionPa, nullptr)) {
            return failure(ErrorCode::NotFound, "нет группы граней: " + traction.faceGroup);
        }
    }
    for (const auto& pressure : problem.pressures) {
        if (!integrateFaces(pressure.faceGroup, nullptr, &pressure.pressurePa)) {
            return failure(ErrorCode::NotFound, "нет группы граней: " + pressure.faceGroup);
        }
    }
    const Vec3 bodyForce = problem.bodyAcceleration * problem.material.densityKgPerM3;
    const bool hasBodyForce = length(bodyForce) > 0.0;

    // --- Assembly.
    if (const auto invalid = firstInvalidElement(mesh)) {
        std::ostringstream message;
        message << "вырожденный, вывернутый или сложенный элемент " << invalid->first << " (min det J = " << invalid->second << ")";
        return failure(ErrorCode::ShapeInvalid, message.str());
    }
    const auto D = isotropicElasticity(problem.material.youngsModulusPa, problem.material.poissonRatio);
    std::vector<double> rhs(freeCount, 0.0);
    assembleStiffness(mesh, D, map, K, &rhs);
    std::vector<double> Ke;
    std::vector<double> fe;
    const int elementDofs = 3 * perElement;
    if (hasBodyForce) {
        for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
            tetBodyForce(mesh, e, bodyForce, fe);
            const auto& element = mesh.elements[e];
            for (int a = 0; a < elementDofs; ++a) external[3 * element[a / 3] + a % 3] += fe[a];
        }
    }
    for (int g = 0; g < dofs; ++g) {
        if (reduced[g] >= 0) rhs[reduced[g]] += external[g];
    }

    // --- Solve.
    std::vector<double> x(freeCount, 0.0);
    LinearStaticSolution solution;
    if (freeCount > 0) {
        if (settings.solver == LinearSolverKind::AccelerateCholesky) {
            SparseCholesky cholesky;
            if (!cholesky.factor(K)) {
                return failure(ErrorCode::KernelOperationFailed,
                               "матрица жёсткости не положительно определена (закрепления или материал)");
            }
            cholesky.solve(rhs, x);
        } else {
            std::vector<double> diagonal(freeCount, 0.0);
            for (int column = 0; column < freeCount; ++column) diagonal[column] = K.at(column, column);
            std::vector<double> r = rhs, z(freeCount), p(freeCount), Ap(freeCount);
            double bNorm = 0.0;
            for (double value : rhs) bNorm += value * value;
            bNorm = std::sqrt(bNorm);
            for (int i = 0; i < freeCount; ++i) z[i] = r[i] / diagonal[i];
            p = z;
            double rz = 0.0;
            for (int i = 0; i < freeCount; ++i) rz += r[i] * z[i];
            int iteration = 0;
            double rNorm = bNorm;
            while (iteration < settings.maximumIterations && rNorm > settings.relativeTolerance * bNorm) {
                K.multiply(p, Ap);
                double pAp = 0.0;
                for (int i = 0; i < freeCount; ++i) pAp += p[i] * Ap[i];
                const double alpha = rz / pAp;
                rNorm = 0.0;
                for (int i = 0; i < freeCount; ++i) {
                    x[i] += alpha * p[i];
                    r[i] -= alpha * Ap[i];
                    rNorm += r[i] * r[i];
                }
                rNorm = std::sqrt(rNorm);
                double rzNext = 0.0;
                for (int i = 0; i < freeCount; ++i) {
                    z[i] = r[i] / diagonal[i];
                    rzNext += r[i] * z[i];
                }
                const double beta = rzNext / rz;
                rz = rzNext;
                for (int i = 0; i < freeCount; ++i) p[i] = z[i] + beta * p[i];
                ++iteration;
            }
            solution.solverIterations = iteration;
            if (rNorm > settings.relativeTolerance * bNorm) {
                return failure(ErrorCode::KernelOperationFailed, "CG не сошёлся за отведённое число итераций");
            }
        }
    }

    solution.totalDofs = dofs;
    solution.freeDofs = freeCount;
    solution.displacement.assign(nodeCount, {});
    for (int g = 0; g < dofs; ++g) {
        solution.displacement[g / 3][g % 3] = reduced[g] >= 0 ? x[reduced[g]] : *prescribed[g];
    }

    // --- Internal forces, reactions, energy; stresses.
    std::vector<double> internal(dofs, 0.0);
    std::vector<Voigt> stressSum(nodeCount, Voigt{});
    std::vector<int> stressCount(nodeCount, 0);
    const double a = 0.5854101966249685;
    const double b = 0.1381966011250105;
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        tetStiffness(mesh, e, D, Ke);
        const auto& element = mesh.elements[e];
        for (int i = 0; i < elementDofs; ++i) {
            double sum = 0.0;
            for (int j = 0; j < elementDofs; ++j) {
                sum += Ke[static_cast<std::size_t>(i) * elementDofs + j] * solution.displacement[element[j / 3]][j % 3];
            }
            internal[3 * element[i / 3] + i % 3] += sum;
        }

        const auto quadrature = tetQuadratureStress(mesh, e, D, solution.displacement);
        std::array<Voigt, 4> corner{};
        for (int c = 0; c < 6; ++c) {
            double total = 0.0;
            for (int q = 0; q < 4; ++q) total += quadrature[q][c];
            for (int q = 0; q < 4; ++q) corner[q][c] = (quadrature[q][c] - b * total) / (a - b);
        }
        for (int q = 0; q < 4; ++q) {
            const double vm = vonMises(quadrature[q]);
            if (vm > solution.maxQuadratureVonMisesPa) {
                solution.maxQuadratureVonMisesPa = vm;
                solution.maxQuadratureVonMisesElement = e;
            }
        }
        for (int n = 0; n < perElement; ++n) {
            Voigt value{};
            if (n < 4) {
                value = corner[n];
            } else {
                const auto& edge = kTetEdges[n - 4];
                for (int c = 0; c < 6; ++c) value[c] = 0.5 * (corner[edge[0]][c] + corner[edge[1]][c]);
            }
            for (int c = 0; c < 6; ++c) stressSum[element[n]][c] += value[c];
            stressCount[element[n]] += 1;
        }
    }
    // Scaled by the internal forces of the whole model rather than by the applied loads: a
    // problem driven only by prescribed displacements has no applied load at all.
    double residual = 0.0;
    double internalNorm = 0.0;
    for (int g = 0; g < dofs; ++g) {
        solution.appliedForceN[g % 3] += external[g];
        internalNorm += internal[g] * internal[g];
        if (reduced[g] >= 0) {
            const double r = internal[g] - external[g];
            residual += r * r;
        } else {
            solution.reactionForceN[g % 3] += internal[g] - external[g];
        }
        solution.strainEnergyJ += 0.5 * solution.displacement[g / 3][g % 3] * internal[g];
    }
    solution.freeResidualRelative = internalNorm > 0.0 ? std::sqrt(residual / internalNorm) : std::sqrt(residual);

    solution.nodalStress.assign(nodeCount, Voigt{});
    solution.nodalVonMises.assign(nodeCount, 0.0);
    for (int n = 0; n < nodeCount; ++n) {
        if (stressCount[n] == 0) continue;
        for (int c = 0; c < 6; ++c) solution.nodalStress[n][c] = stressSum[n][c] / stressCount[n];
        solution.nodalVonMises[n] = vonMises(solution.nodalStress[n]);
        if (solution.nodalVonMises[n] > solution.maxNodalVonMisesPa) {
            solution.maxNodalVonMisesPa = solution.nodalVonMises[n];
            solution.maxNodalVonMisesNode = n;
        }
        const double d = length(solution.displacement[n]);
        if (d > solution.maxDisplacementM) {
            solution.maxDisplacementM = d;
            solution.maxDisplacementNode = n;
        }
    }
    return Result<LinearStaticSolution>::ok(std::move(solution));
}

double faceGroupArea(const TetMesh& mesh, const std::string& group) {
    const auto found = mesh.faceGroups.find(group);
    if (found == mesh.faceGroups.end()) return 0.0;
    const int faceNodeCount = mesh.order == ElementOrder::Quadratic ? 6 : 3;
    double area = 0.0;
    for (const auto& face : found->second) {
        const auto nodes = mesh.faceNodes(face);
        for (const auto& q : triangleQuadratureDegree4()) {
            double N[6], dS[6], dT[6];
            triangleShapeFunctions(mesh.order, q.s, q.t, N, dS, dT);
            Vec3 xs, xt;
            for (int n = 0; n < faceNodeCount; ++n) {
                xs += mesh.nodes[nodes[n]] * dS[n];
                xt += mesh.nodes[nodes[n]] * dT[n];
            }
            area += length(cross(xs, xt)) * q.weight;
        }
    }
    return area;
}

} // namespace cadnext::fea
