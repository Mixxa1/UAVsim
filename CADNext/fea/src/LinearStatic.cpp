#include "cadnext/fea/LinearStatic.hpp"

#include "cadnext/fea/TetElement.hpp"

#include "SystemAssembly.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>

namespace cadnext::fea {

namespace {

using namespace detail;

template <typename T>
Result<T> failure(ErrorCode code, const std::string& message) {
    return Result<T>::fail({code, message});
}

// What every load case of one problem shares: the DOF map, the reduced stiffness (with the prescribed
// displacements' share of the right-hand side), and the consistent mechanical loads.
struct Prepared {
    const TetMesh* mesh = nullptr;
    const IsotropicMaterial* material = nullptr;
    int nodeCount = 0;
    int dofs = 0;
    DofMap map;
    SymmetricCsc K;
    std::array<std::array<double, 6>, 6> D{};
    std::vector<double> rhsPrescribed; // free DOFs
    std::vector<double> mechanical;    // all DOFs
    const std::vector<double>* scale = nullptr; // per-element modulus factor, or none
};

std::optional<Error> prepare(const LinearStaticProblem& problem, Prepared& p) {
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) return Error{ErrorCode::InvalidArgument, "пустая сетка"};
    if (!problem.material.isValid()) return Error{ErrorCode::InvalidArgument, "некорректный материал: " + problem.material.id};
    const TetMesh& mesh = *problem.mesh;
    p.mesh = &mesh;
    p.material = &problem.material;
    p.nodeCount = static_cast<int>(mesh.nodes.size());
    p.dofs = 3 * p.nodeCount;
    if (const auto problemWithNodes = checkElementNodes(mesh)) return Error{ErrorCode::InvalidArgument, *problemWithNodes};
    if (const auto problemWithConstraints = buildDofMap(mesh, problem.constraints, p.map)) return Error{ErrorCode::InvalidArgument, *problemWithConstraints};
    if (const auto motion = freeRigidBodyMotion(mesh, p.map)) {
        return Error{ErrorCode::InvalidArgument, "конструкция не закреплена: свободное смещение как целого (" + *motion + ")"};
    }
    p.K = reducedSparsity(mesh, p.map);

    // --- Mechanical loads.
    p.mechanical.assign(p.dofs, 0.0);
    for (const auto& nodal : problem.nodalForces) {
        if (nodal.node < 0 || nodal.node >= p.nodeCount) return Error{ErrorCode::InvalidArgument, "сосредоточенная сила в несуществующем узле"};
        for (int c = 0; c < 3; ++c) p.mechanical[3 * nodal.node + c] += nodal.forceN[c];
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
                    for (int c = 0; c < 3; ++c) p.mechanical[3 * nodes[n] + c] += N[n] * load[c] * q.weight;
                }
            }
        }
        return true;
    };
    for (const auto& traction : problem.tractions)
        if (!integrateFaces(traction.faceGroup, &traction.tractionPa, nullptr)) return Error{ErrorCode::NotFound, "нет группы граней: " + traction.faceGroup};
    for (const auto& pressure : problem.pressures)
        if (!integrateFaces(pressure.faceGroup, nullptr, &pressure.pressurePa)) return Error{ErrorCode::NotFound, "нет группы граней: " + pressure.faceGroup};

    // --- Assembly.
    if (const auto invalid = firstInvalidElement(mesh)) {
        std::ostringstream message;
        message << "вырожденный, вывернутый или сложенный элемент " << invalid->first << " (min det J = " << invalid->second << ")";
        return Error{ErrorCode::ShapeInvalid, message.str()};
    }
    p.D = isotropicElasticity(problem.material.youngsModulusPa, problem.material.poissonRatio);
    if (!problem.elementModulusScale.empty()) {
        if (problem.elementModulusScale.size() != mesh.elements.size()) return Error{ErrorCode::InvalidArgument, "множители модуля не совпадают с сеткой"};
        for (double factor : problem.elementModulusScale)
            if (!(factor > 0.0)) return Error{ErrorCode::InvalidArgument, "множитель модуля упругости должен быть > 0"};
        p.scale = &problem.elementModulusScale;
    }
    p.rhsPrescribed.assign(p.map.freeCount, 0.0);
    assembleStiffness(mesh, p.D, p.map, p.K, &p.rhsPrescribed, p.scale);
    const Vec3 bodyForce = problem.bodyAcceleration * problem.material.densityKgPerM3;
    if (length(bodyForce) > 0.0) {
        std::vector<double> fe;
        const int elementDofs = 3 * mesh.nodesPerElement();
        for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
            tetBodyForce(mesh, e, bodyForce, fe);
            const auto& element = mesh.elements[e];
            for (int a = 0; a < elementDofs; ++a) p.mechanical[3 * element[a / 3] + a % 3] += fe[a];
        }
    }
    return std::nullopt;
}

std::optional<Error> thermalStrainOf(const Prepared& p, const std::vector<double>& temperatureChangeK, std::vector<double>& strain,
                                     const std::vector<double>* direct = nullptr) {
    strain.clear();
    if (direct && !direct->empty()) {
        if (static_cast<int>(direct->size()) != p.nodeCount) return Error{ErrorCode::InvalidArgument, "поле теплового удлинения не совпадает с сеткой"};
        strain = *direct;
        return std::nullopt;
    }
    if (temperatureChangeK.empty()) return std::nullopt;
    if (static_cast<int>(temperatureChangeK.size()) != p.nodeCount) return Error{ErrorCode::InvalidArgument, "поле температуры не совпадает с сеткой"};
    if (!p.material->thermalExpansionPerK) {
        return Error{ErrorCode::InvalidArgument, "у материала " + p.material->id + " нет коэффициента теплового расширения"};
    }
    strain.resize(p.nodeCount);
    for (int n = 0; n < p.nodeCount; ++n) strain[n] = *p.material->thermalExpansionPerK * temperatureChangeK[n];
    return std::nullopt;
}

// External forces of one case (mechanical + thermal) and its reduced right-hand side.
void caseLoads(const Prepared& p, const std::vector<double>& thermalStrain, std::vector<double>& external, std::vector<double>& rhs) {
    external = p.mechanical;
    if (!thermalStrain.empty()) {
        std::vector<double> fe;
        const int elementDofs = 3 * p.mesh->nodesPerElement();
        for (int e = 0; e < static_cast<int>(p.mesh->elements.size()); ++e) {
            tetThermalLoad(*p.mesh, e, p.D, thermalStrain, fe);
            if (p.scale)
                for (double& value : fe) value *= (*p.scale)[e];
            const auto& element = p.mesh->elements[e];
            for (int a = 0; a < elementDofs; ++a) external[3 * element[a / 3] + a % 3] += fe[a];
        }
    }
    rhs = p.rhsPrescribed;
    for (int g = 0; g < p.dofs; ++g)
        if (p.map.reduced[g] >= 0) rhs[p.map.reduced[g]] += external[g];
}

// Everything after the solve: displacements, internal forces, reactions, energy, stresses.
LinearStaticSolution recover(const Prepared& p, const std::vector<double>& x, const std::vector<double>& external,
                             const std::vector<double>& thermalStrain) {
    const TetMesh& mesh = *p.mesh;
    const auto& reduced = p.map.reduced;
    LinearStaticSolution solution;
    solution.totalDofs = p.dofs;
    solution.freeDofs = p.map.freeCount;
    solution.displacement.assign(p.nodeCount, {});
    for (int g = 0; g < p.dofs; ++g) solution.displacement[g / 3][g % 3] = reduced[g] >= 0 ? x[reduced[g]] : *p.map.prescribed[g];

    std::vector<double> internal(p.dofs, 0.0), Ke;
    const int elementDofs = 3 * mesh.nodesPerElement();
    for (int e = 0; e < static_cast<int>(mesh.elements.size()); ++e) {
        tetStiffness(mesh, e, p.D, Ke);
        if (p.scale)
            for (double& value : Ke) value *= (*p.scale)[e];
        const auto& element = mesh.elements[e];
        for (int i = 0; i < elementDofs; ++i) {
            double sum = 0.0;
            for (int j = 0; j < elementDofs; ++j) sum += Ke[static_cast<std::size_t>(i) * elementDofs + j] * solution.displacement[element[j / 3]][j % 3];
            internal[3 * element[i / 3] + i % 3] += sum;
        }
    }
    // Scaled by the internal forces of the whole model rather than by the applied loads: a
    // problem driven only by prescribed displacements has no applied load at all.
    double residual = 0.0;
    double internalNorm = 0.0;
    for (int g = 0; g < p.dofs; ++g) {
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

    solution.nodalStress = averagedNodalStress(mesh, p.D, solution.displacement, &solution.maxQuadratureVonMisesPa,
                                               &solution.maxQuadratureVonMisesElement, thermalStrain.empty() ? nullptr : &thermalStrain, p.scale);
    solution.nodalVonMises.assign(p.nodeCount, 0.0);
    for (int n = 0; n < p.nodeCount; ++n) {
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
    return solution;
}

} // namespace

Result<LinearStaticSolution> solveLinearStatic(const LinearStaticProblem& problem,
                                               const LinearStaticSettings& settings) {
    Prepared p;
    if (const auto error = prepare(problem, p)) return failure<LinearStaticSolution>(error->code, error->message);
    std::vector<double> thermalStrain, external, rhs;
    if (const auto error = thermalStrainOf(p, problem.temperatureChangeK, thermalStrain, &problem.thermalStrain)) {
        return failure<LinearStaticSolution>(error->code, error->message);
    }
    caseLoads(p, thermalStrain, external, rhs);

    // --- Solve.
    const int freeCount = p.map.freeCount;
    std::vector<double> x(freeCount, 0.0);
    int iterations = 0;
    if (freeCount > 0) {
        if (settings.solver == LinearSolverKind::AccelerateCholesky) {
            SparseCholesky cholesky;
            if (!cholesky.factor(p.K)) {
                return failure<LinearStaticSolution>(ErrorCode::KernelOperationFailed,
                                                     "матрица жёсткости не положительно определена (закрепления или материал)");
            }
            cholesky.solve(rhs, x);
        } else {
            const SymmetricCsc& K = p.K;
            std::vector<double> diagonal(freeCount, 0.0);
            for (int column = 0; column < freeCount; ++column) diagonal[column] = K.at(column, column);
            std::vector<double> r = rhs, z(freeCount), d(freeCount), Ad(freeCount);
            double bNorm = 0.0;
            for (double value : rhs) bNorm += value * value;
            bNorm = std::sqrt(bNorm);
            for (int i = 0; i < freeCount; ++i) z[i] = r[i] / diagonal[i];
            d = z;
            double rz = 0.0;
            for (int i = 0; i < freeCount; ++i) rz += r[i] * z[i];
            double rNorm = bNorm;
            while (iterations < settings.maximumIterations && rNorm > settings.relativeTolerance * bNorm) {
                K.multiply(d, Ad);
                double dAd = 0.0;
                for (int i = 0; i < freeCount; ++i) dAd += d[i] * Ad[i];
                const double alpha = rz / dAd;
                rNorm = 0.0;
                for (int i = 0; i < freeCount; ++i) {
                    x[i] += alpha * d[i];
                    r[i] -= alpha * Ad[i];
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
                for (int i = 0; i < freeCount; ++i) d[i] = z[i] + beta * d[i];
                ++iterations;
            }
            if (rNorm > settings.relativeTolerance * bNorm) {
                return failure<LinearStaticSolution>(ErrorCode::KernelOperationFailed, "CG не сошёлся за отведённое число итераций");
            }
        }
    }
    auto solution = recover(p, x, external, thermalStrain);
    solution.solverIterations = iterations;
    return Result<LinearStaticSolution>::ok(std::move(solution));
}

Result<int> solveThermoelasticSeries(const LinearStaticProblem& problem, const std::vector<std::vector<double>>& temperatureChangesK,
                                     const LinearStaticVisitor& visit) {
    Prepared p;
    if (const auto error = prepare(problem, p)) return failure<int>(error->code, error->message);
    SparseCholesky cholesky;
    if (p.map.freeCount > 0 && !cholesky.factor(p.K)) {
        return failure<int>(ErrorCode::KernelOperationFailed, "матрица жёсткости не положительно определена (закрепления или материал)");
    }
    int solved = 0;
    std::vector<double> thermalStrain, external, rhs, x;
    for (std::size_t index = 0; index < temperatureChangesK.size(); ++index) {
        if (const auto error = thermalStrainOf(p, temperatureChangesK[index], thermalStrain)) return failure<int>(error->code, error->message);
        caseLoads(p, thermalStrain, external, rhs);
        x.assign(p.map.freeCount, 0.0);
        if (p.map.freeCount > 0) cholesky.solve(rhs, x);
        ++solved;
        if (!visit(index, recover(p, x, external, thermalStrain))) break;
    }
    return Result<int>::ok(solved);
}

std::vector<DisplacementConstraint> kinematicSupports(const TetMesh& mesh) {
    if (mesh.nodes.size() < 3) return {};
    // Corner nodes only (midside nodes of a TET10 are not in element slots 0–3).
    std::vector<bool> corner(mesh.nodes.size(), false);
    for (const auto& element : mesh.elements)
        for (int k = 0; k < 4; ++k) corner[element[k]] = true;
    Vec3 centre;
    int count = 0;
    for (std::size_t n = 0; n < mesh.nodes.size(); ++n)
        if (corner[n]) centre += mesh.nodes[n], ++count;
    centre = centre * (1.0 / std::max(1, count));
    auto farthest = [&](const std::function<double(const Vec3&)>& distance) {
        int best = -1;
        double bestDistance = -1.0;
        for (std::size_t n = 0; n < mesh.nodes.size(); ++n) {
            if (!corner[n]) continue;
            const double d = distance(mesh.nodes[n]);
            if (d > bestDistance) bestDistance = d, best = static_cast<int>(n);
        }
        return best;
    };
    const int a = farthest([&](const Vec3& x) { return length(x - centre); });
    const Vec3 A = mesh.nodes[a];
    const int b = farthest([&](const Vec3& x) { return length(x - A); });
    const Vec3 axis = (mesh.nodes[b] - A) * (1.0 / length(mesh.nodes[b] - A));
    const int c = farthest([&](const Vec3& x) { return length(cross(axis, x - A)); });

    std::vector<DisplacementConstraint> supports;
    supports.push_back({{a}, {0.0, 0.0, 0.0}});
    // At B, the two components across the line A–B: with its dominant component left free, rotations
    // about the other two axes are held and only the rotation about A–B remains.
    int dominant = 0;
    for (int i = 1; i < 3; ++i)
        if (std::fabs(axis[i]) > std::fabs(axis[dominant])) dominant = i;
    DisplacementConstraint atB{{b}, {}};
    for (int i = 0; i < 3; ++i)
        if (i != dominant) atB.value[i] = 0.0;
    supports.push_back(atB);
    // At C, the component along which a rotation about A–B moves it the most.
    const Vec3 swing = cross(axis, mesh.nodes[c] - A);
    int along = 0;
    for (int i = 1; i < 3; ++i)
        if (std::fabs(swing[i]) > std::fabs(swing[along])) along = i;
    DisplacementConstraint atC{{c}, {}};
    atC.value[along] = 0.0;
    supports.push_back(atC);
    return supports;
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
