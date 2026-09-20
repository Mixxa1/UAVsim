#include "cadnext/fea/ShockStudy.hpp"

#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<ShockStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<ShockStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

} // namespace

Result<ShockStudyResult> runShockStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                         const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                         const ShockStudySettings& settings, const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument,
                       "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (supports.empty()) return failure(ErrorCode::InvalidArgument, "испытание на удар требует опор — закрепления на оснастке");

    ShockStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.factorOfSafety = settings.criteria.factorOfSafety;
    result.dampingRatio = settings.dampingRatio;

    TetMesh finestMesh;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
    std::vector<double> highestModes;
    std::vector<double> finestFieldVonMises;
    std::vector<Vec3> finestFieldDisplacement;
    for (int level = 0; level < 3; ++level) {
        const double size = settings.coarseElementSizeM / std::pow(settings.refinementFactor, level);
        if (progress) progress(level, "mesh");
        SolidMeshingSettings meshing;
        meshing.maximumElementSizeM = size;
        auto meshed = meshSolid(kernel, shape, meshing);
        if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
        SolidMesh solid = meshed.value();
        result.mesherVersion = solid.mesherVersion;
        TetMesh& mesh = solid.mesh;
        auto requireFace = [&](const std::string& face) { return mesh.faceGroups.count(face) > 0; };

        ShockProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.attachedMasses = settings.attachedMasses;
        problem.direction = settings.direction;
        problem.pulse = settings.pulse;
        problem.dampingRatio = settings.dampingRatio;
        problem.modeCount = settings.modeCount;
        problem.probeFaceGroup = settings.probeFace;
        std::vector<int> supportNodes;
        for (const auto& support : supports) {
            if (!requireFace(support.face)) return failure(ErrorCode::NotFound, "нет грани " + support.face + " (опора)");
            DisplacementConstraint constraint;
            constraint.nodes = mesh.nodesOnGroup(support.face);
            for (int c = 0; c < 3; ++c)
                if (support.fixed[c]) constraint.value[c] = 0.0;
            if (support.fixed[0] && support.fixed[1] && support.fixed[2]) {
                supportNodes.insert(supportNodes.end(), constraint.nodes.begin(), constraint.nodes.end());
            }
            problem.constraints.push_back(std::move(constraint));
        }
        if (!settings.probeFace.empty() && !requireFace(settings.probeFace)) return failure(ErrorCode::NotFound, "нет грани " + settings.probeFace + " (датчик)");
        if (!settings.stressExclusions.empty()) {
            problem.stressExcluded.assign(mesh.nodes.size(), false);
            for (const auto& exclusion : settings.stressExclusions) {
                if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
                const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
                for (std::size_t n = 0; n < near.size(); ++n) problem.stressExcluded[n] = problem.stressExcluded[n] || near[n];
            }
        }

        if (progress) progress(level, "solve");
        auto solved = solveShock(problem);
        if (!solved.isOk()) return failure(solved.error().code, solved.error().message);
        ShockSolution solution = std::move(solved.value());
        if (static_cast<int>(solution.modal.modes.size()) < settings.modeCount) {
            return failure(ErrorCode::InvalidArgument, "у детали на этой сетке меньше мод, чем запрошено");
        }
        if (solution.peakNode < 0) return failure(ErrorCode::InvalidArgument, "зоны исключения покрыли всю деталь");

        ShockStudyLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.peakVonMisesPa = solution.peakVonMisesPa;
        record.peakTimeS = solution.timeS[solution.worstSample];
        record.criticalPoint = mesh.nodes[solution.peakNode];
        if (level > 0 && record.elements <= result.levels.back().elements) {
            return failure(ErrorCode::KernelOperationFailed,
                           "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levels.push_back(record);
        highestModes.push_back(solution.highestModeHz);
        if (level == 0) {
            result.totalMassKg = solution.modal.totalMassKg;
            result.attachedMassKg = solution.modal.attachedMassKg;
        }
        if (level == 2) {
            finestMesh = std::move(mesh);
            result.finest = std::move(solution);
            finestFieldVonMises = result.finest.worstVonMisesPa;
            finestFieldDisplacement = result.finest.worstDisplacement;
            finestSupportNodes = std::move(supportNodes);
            finestElementSize = size;
        }
    }

    const auto& coarse = result.levels[0];
    const auto& medium = result.levels[1];
    const auto& fine = result.levels[2];
    const double r21 = std::cbrt(static_cast<double>(fine.elements) / static_cast<double>(medium.elements));
    const double r32 = std::cbrt(static_cast<double>(medium.elements) / static_cast<double>(coarse.elements));
    result.stressConvergence = estimateConvergence(fine.peakVonMisesPa, medium.peakVonMisesPa, coarse.peakVonMisesPa, r21, r32, 1.25,
                                                   kTet10StressOrder);
    result.assessment = assessStrength(material, fine.peakVonMisesPa, result.stressConvergence, settings.criteria);
    result.criticalPoint = fine.criticalPoint;

    const int criticalNode = result.finest.peakNode;
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        const auto nodes = finestMesh.nodesOnGroup(name);
        if (std::binary_search(nodes.begin(), nodes.end(), criticalNode)) {
            result.criticalFace = name;
            break;
        }
    }
    auto demote = [&](const std::string& reason) {
        result.assessment.reasons.push_back(reason);
        if (result.assessment.verdict == StrengthVerdict::Pass) result.assessment.verdict = StrengthVerdict::Warning;
    };
    if (nodesNear(finestMesh, finestSupportNodes, finestElementSize)[criticalNode]) {
        demote("максимум напряжения у жёсткой заделки — вероятна особенность идеализированного закрепления; задайте зону исключения или смоделируйте крепёж");
    }
    if (result.finest.effectiveMassFraction < 0.9) {
        demote("рассчитанные моды несут " + format(100.0 * result.finest.effectiveMassFraction, 1)
               + " % массы вдоль удара (нужно ≥ 90 %) — увеличьте число мод");
    }
    if (!settings.stressExclusions.empty()) result.warnings.push_back("максимум напряжения взят вне заданных зон исключения");
    if (result.stressConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
    }
    (void)highestModes;

    // Shock response spectrum of the input, Q = 10, from 1/(10 τ) to 100/τ (and the modes' range).
    {
        const auto& t = result.finest.timeS;
        const double step = t.size() > 1 ? t[1] - t[0] : 0.0;
        const double tau = std::max(settings.pulse.end(), step);
        double low = 0.1 / tau, high = 100.0 / tau;
        for (const auto& mode : result.finest.modal.modes) {
            low = std::min(low, 0.5 * mode.frequencyHz);
            high = std::max(high, 2.0 * mode.frequencyHz);
        }
        high = std::min(high, 0.1 / step); // ten samples per period at least
        std::vector<double> base = result.finest.baseAccelerationMs2;
        // Long enough for the lowest oscillator's residual peak: half its period after the pulse.
        const std::size_t needed = static_cast<std::size_t>((settings.pulse.end() + 0.75 / low) / step) + 1;
        if (base.size() < needed) base.resize(needed, 0.0);
        for (int i = 0; i < 60; ++i) result.srsFrequencyHz.push_back(low * std::pow(high / low, i / 59.0));
        result.srsAccelerationMps2 = shockResponseSpectrum(base, step, result.srsFrequencyHz, 0.05);
    }

    // Surface field at the worst instant: von Mises and the displacement then.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back(finestFieldDisplacement[meshNode]);
        result.field.vonMisesPa.push_back(finestFieldVonMises[meshNode]);
        fieldIndex.emplace(meshNode, index);
        return index;
    };
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        for (const auto& face : faces) {
            const auto n = finestMesh.faceNodes(face);
            std::vector<int> f;
            for (int node : n) f.push_back(fieldNode(node));
            if (f.size() == 6) {
                result.field.triangles.push_back({f[0], f[3], f[5]});
                result.field.triangles.push_back({f[3], f[1], f[4]});
                result.field.triangles.push_back({f[5], f[4], f[2]});
                result.field.triangles.push_back({f[3], f[4], f[5]});
                for (int k = 0; k < 4; ++k) result.field.triangleFace.push_back(name);
            } else {
                result.field.triangles.push_back({f[0], f[1], f[2]});
                result.field.triangleFace.push_back(name);
            }
        }
    }
    // The per-node arrays of the finest solution are no longer needed; the spectra and scalars stay.
    for (const auto& mode : result.finest.modal.modes) result.modeFrequenciesHz.push_back(mode.frequencyHz);
    result.finest.worstVonMisesPa.clear();
    result.finest.worstDisplacement.clear();
    result.finest.modal.modes.clear();
    return Result<ShockStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
