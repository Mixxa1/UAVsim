#include "ResponseBasis.hpp"

#include "cadnext/fea/TetElement.hpp"

#include <cmath>
#include <numeric>
#include <sstream>

namespace cadnext::fea::detail {

std::vector<Vec3> ResponseSystem::toFull(const double* reduced) const {
    std::vector<Vec3> full(nodeCount, Vec3{});
    for (int g = 0; g < 3 * nodeCount; ++g)
        if (map.reduced[g] >= 0) full[g / 3][g % 3] = reduced[map.reduced[g]];
    return full;
}

Vec3 ResponseSystem::probeOf(const std::vector<Vec3>& field) const {
    Vec3 mean;
    for (int node = 0; node < nodeCount; ++node)
        if (probeWeights[node] != 0.0) mean += field[node] * probeWeights[node];
    return mean;
}

std::optional<std::string> buildResponseSystem(const HarmonicProblem& problem, ResponseSystem& system) {
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) return std::string("пустая сетка");
    if (!problem.material.isValid()) return "некорректный материал: " + problem.material.id;
    const auto& excitation = problem.excitation;
    const double directionLength = length(excitation.direction);
    if (!(directionLength > 0.0)) return std::string("направление возбуждения не задано");
    const TetMesh& mesh = *problem.mesh;
    if (const auto message = checkElementNodes(mesh)) return message;
    for (const auto& constraint : problem.constraints)
        for (const auto& value : constraint.value)
            if (value && *value != 0.0) return std::string("закрепление — нулевое относительное перемещение, не нагрузка");
    system.mesh = &mesh;
    system.nodeCount = static_cast<int>(mesh.nodes.size());
    if (const auto message = buildDofMap(mesh, problem.constraints, system.map)) return message;
    if (const auto motion = freeRigidBodyMotion(mesh, system.map)) {
        return "вибрационное испытание требует закрепления детали на оснастке: свободно " + *motion;
    }
    if (const auto invalid = firstInvalidElement(mesh)) {
        std::ostringstream message;
        message << "вырожденный, вывернутый или сложенный элемент " << invalid->first << " (min det J = " << invalid->second << ")";
        return message.str();
    }
    if (!problem.stressExcluded.empty() && static_cast<int>(problem.stressExcluded.size()) != system.nodeCount) {
        return std::string("маска исключённых узлов не совпадает с сеткой");
    }
    system.stressExcluded = problem.stressExcluded;
    system.direction = excitation.direction * (1.0 / directionLength);
    system.base = excitation.kind == HarmonicExcitationKind::BaseAcceleration;
    system.elasticity = isotropicElasticity(problem.material.youngsModulusPa, problem.material.poissonRatio);
    const int n = system.map.freeCount;

    // Load pattern for a unit amplitude (1 m/s² of base acceleration, or 1 N).
    system.P.assign(n, 0.0);
    if (system.base) {
        system.P = baseInertiaLoad(mesh, problem.material.densityKgPerM3, problem.attachedMasses, system.map, system.direction);
        for (double& value : system.P) value = -value;
    } else {
        std::vector<double> weights(system.nodeCount, 0.0);
        if (!addFaceNodeWeights(mesh, excitation.faceGroup, weights)) return "нет группы граней для силы: " + excitation.faceGroup;
        const double area = std::accumulate(weights.begin(), weights.end(), 0.0);
        if (!(area > 0.0)) return "грань силы нулевой площади: " + excitation.faceGroup;
        for (int node = 0; node < system.nodeCount; ++node)
            for (int c = 0; c < 3; ++c)
                if (system.map.reduced[3 * node + c] >= 0) system.P[system.map.reduced[3 * node + c]] += weights[node] / area * system.direction[c];
    }
    if (!problem.probeFaceGroup.empty()) {
        system.probeWeights.assign(system.nodeCount, 0.0);
        if (!addFaceNodeWeights(mesh, problem.probeFaceGroup, system.probeWeights)) return "нет группы граней датчика: " + problem.probeFaceGroup;
        const double area = std::accumulate(system.probeWeights.begin(), system.probeWeights.end(), 0.0);
        if (!(area > 0.0)) return std::string("грань датчика нулевой площади");
        for (double& w : system.probeWeights) w /= area;
    }

    system.K = reducedSparsity(mesh, system.map);
    system.M = system.K;
    assembleStiffness(mesh, system.elasticity, system.map, system.K, nullptr);
    assembleMass(mesh, problem.material.densityKgPerM3, system.map, system.M);
    double attached = 0.0;
    if (const auto message = addAttachedMasses(mesh, problem.attachedMasses, system.map, system.M, attached)) return message;
    return std::nullopt;
}

std::optional<std::string> buildResponseBasis(const ResponseSystem& system, const HarmonicProblem& problem, const ModalSettings& modalSettings,
                                              bool staticCorrection, ResponseBasis& basis) {
    ModalProblem modal;
    modal.mesh = problem.mesh;
    modal.material = problem.material;
    modal.constraints = problem.constraints;
    modal.attachedMasses = problem.attachedMasses;
    modal.modeCount = problem.modeCount;
    auto modes = solveModal(modal, modalSettings);
    if (!modes.isOk()) return modes.error().message;
    basis.modal = std::move(modes.value());
    if (basis.modal.modes.empty()) return std::string("не найдено ни одной моды");
    basis.highestModeHz = basis.modal.modes.back().frequencyHz;
    basis.staticCorrection = staticCorrection;

    const Vec3& d = system.direction;
    if (system.base) {
        double gamma = 0.0, freeMass = 0.0;
        for (int c = 0; c < 3; ++c) freeMass += d[c] * d[c] * basis.modal.freeMassKg[c];
        for (const auto& mode : basis.modal.modes) {
            const double participation = mode.participation.x * d.x + mode.participation.y * d.y + mode.participation.z * d.z;
            gamma += participation * participation;
        }
        basis.effectiveMassFraction = freeMass > 0.0 ? gamma / freeMass : 0.0;
    } else {
        basis.effectiveMassFraction = std::nan("");
    }

    const auto& modes_ = basis.modal.modes;
    const int R = static_cast<int>(modes_.size());
    basis.offset = staticCorrection ? 1 : 0;
    basis.J = R + basis.offset;
    std::vector<std::vector<Vec3>> displacement;
    basis.modalLoad.assign(R, 0.0);
    if (staticCorrection) {
        SymmetricCsc K = system.K;
        SparseCholesky cholesky;
        if (!cholesky.factor(K)) return std::string("матрица жёсткости не положительно определена (закрепления или материал)");
        std::vector<double> rhs = system.P, x;
        cholesky.solve(rhs, x);
        displacement.push_back(system.toFull(x.data()));
    }
    for (int r = 0; r < R; ++r) {
        displacement.push_back(modes_[r].shape);
        double load = 0.0;
        for (int g = 0; g < 3 * system.nodeCount; ++g)
            if (system.map.reduced[g] >= 0) load += modes_[r].shape[g / 3][g % 3] * system.P[system.map.reduced[g]];
        basis.modalLoad[r] = load;
    }
    basis.stressRows = 6 * static_cast<std::size_t>(system.nodeCount);
    basis.motionRows = 3 * static_cast<std::size_t>(system.nodeCount);
    basis.stressBasis.assign(basis.stressRows * basis.J, 0.0);
    basis.motionBasis.assign(basis.motionRows * basis.J, 0.0);
    basis.probeBasis.assign(basis.J, Vec3{});
    for (int j = 0; j < basis.J; ++j) {
        const auto stress = averagedNodalStress(*system.mesh, system.elasticity, displacement[j]);
        for (int node = 0; node < system.nodeCount; ++node) {
            for (int c = 0; c < 6; ++c) basis.stressBasis[j * basis.stressRows + 6 * node + c] = stress[node][c];
            for (int c = 0; c < 3; ++c) basis.motionBasis[j * basis.motionRows + 3 * node + c] = displacement[j][node][c];
        }
        if (!system.probeWeights.empty()) basis.probeBasis[j] = system.probeOf(displacement[j]);
    }
    return std::nullopt;
}

void ResponseBasis::coefficients(double omega, double dampingRatio, double* real, double* imaginary) const {
    if (staticCorrection) {
        real[0] = 1.0;
        imaginary[0] = 0.0;
    }
    const auto& modes_ = modal.modes;
    for (std::size_t r = 0; r < modes_.size(); ++r) {
        const double wr2 = modes_[r].eigenvalue, wr = std::sqrt(wr2);
        const std::complex<double> H = 1.0 / std::complex<double>(wr2 - omega * omega, 2.0 * dampingRatio * wr * omega);
        const std::complex<double> c = modalLoad[r] * (staticCorrection ? H - 1.0 / wr2 : H);
        real[offset + r] = c.real();
        imaginary[offset + r] = c.imag();
    }
}

} // namespace cadnext::fea::detail
