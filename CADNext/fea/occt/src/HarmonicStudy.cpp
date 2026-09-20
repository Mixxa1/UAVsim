#include "cadnext/fea/HarmonicStudy.hpp"

#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<HarmonicStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<HarmonicStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

} // namespace

Result<HarmonicStudyResult> runHarmonicStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                             const IsotropicMaterial& material, const std::string& loadCaseName,
                                             const std::vector<FaceSupport>& supports, const HarmonicStudySettings& settings,
                                             const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument,
                       "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (supports.empty()) return failure(ErrorCode::InvalidArgument, "вибрационное испытание требует опор — закрепления на оснастке");

    HarmonicStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.factorOfSafety = settings.criteria.factorOfSafety;
    result.dampingRatio = settings.dampingRatio;

    TetMesh finestMesh;
    HarmonicSolution finest;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
    std::vector<double> highestModes;
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

        HarmonicProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.attachedMasses = settings.attachedMasses;
        problem.excitation = settings.excitation;
        problem.dampingRatio = settings.dampingRatio;
        problem.modeCount = settings.modeCount;
        problem.minimumHz = settings.minimumHz;
        problem.maximumHz = settings.maximumHz;
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
        if (settings.excitation.kind == HarmonicExcitationKind::FaceForce && !requireFace(settings.excitation.faceGroup)) {
            return failure(ErrorCode::NotFound, "нет грани " + settings.excitation.faceGroup + " (сила)");
        }
        if (!settings.probeFace.empty() && !requireFace(settings.probeFace)) {
            return failure(ErrorCode::NotFound, "нет грани " + settings.probeFace + " (датчик)");
        }
        if (!settings.stressExclusions.empty()) {
            problem.stressExcluded.assign(mesh.nodes.size(), false);
            for (const auto& exclusion : settings.stressExclusions) {
                if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
                const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
                for (std::size_t n = 0; n < near.size(); ++n) problem.stressExcluded[n] = problem.stressExcluded[n] || near[n];
            }
        }

        if (progress) progress(level, "solve");
        HarmonicSettings harmonic;
        harmonic.sweepPoints = settings.sweepPoints;
        auto solved = solveHarmonic(problem, harmonic);
        if (!solved.isOk()) return failure(solved.error().code, solved.error().message);
        HarmonicSolution solution = std::move(solved.value());
        if (static_cast<int>(solution.modal.modes.size()) < settings.modeCount) {
            return failure(ErrorCode::InvalidArgument, "у детали на этой сетке меньше мод, чем запрошено");
        }
        const auto& worst = solution.samples[solution.worstSample];
        if (worst.maxVonMisesNode < 0) return failure(ErrorCode::InvalidArgument, "зоны исключения покрыли всю деталь");

        HarmonicStudyLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.peakVonMisesPa = worst.maxVonMisesPa;
        record.peakFrequencyHz = worst.frequencyHz;
        record.criticalPoint = mesh.nodes[worst.maxVonMisesNode];
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
            finest = std::move(solution);
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
    result.samples = finest.samples;
    result.worstSample = finest.worstSample;
    result.effectiveMassFraction = finest.effectiveMassFraction;
    result.highestModeHz = finest.highestModeHz;
    for (const auto& mode : finest.modal.modes) result.modeFrequenciesHz.push_back(mode.frequencyHz);

    const int criticalNode = finest.samples[finest.worstSample].maxVonMisesNode;
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
        demote("максимум динамического напряжения у жёсткой заделки — вероятна особенность идеализированного закрепления; задайте зону исключения или смоделируйте крепёж");
    }
    // The next mode above the last computed one lies at least at f_N − |f_N − f_N(medium)|.
    const double lowestUnseen = highestModes[2] - std::fabs(highestModes[2] - highestModes[1]);
    if (settings.maximumHz >= lowestUnseen) {
        demote("диапазон до " + format(settings.maximumHz, 1) + " Гц выше последней рассчитанной моды (" + format(highestModes[2], 1)
               + " Гц) — резонансы выше не видны, увеличьте число мод");
    }
    if (settings.excitation.kind == HarmonicExcitationKind::BaseAcceleration && finest.effectiveMassFraction < 0.9) {
        demote("рассчитанные моды несут " + format(100.0 * finest.effectiveMassFraction, 1)
               + " % массы вдоль возбуждения (нужно ≥ 90 %) — увеличьте число мод");
    }
    // Sustained vibration fails in fatigue, and there is no endurance limit to check against: a
    // PASS on yield alone would claim more than was shown.
    demote("усталость не оценена: в базе материалов нет предела выносливости, а длительная вибрация разрушает "
           "при амплитудах заметно ниже предела текучести");
    if (!settings.stressExclusions.empty()) result.warnings.push_back("максимум напряжения взят вне заданных зон исключения");
    if (result.stressConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
    }

    // Surface field of the finest mesh at the worst frequency. Displacement is shown at the instant
    // the largest motion peaks: u(θ) = u_R cos θ − u_I sin θ with θ from the 2×2 form of that node.
    Vec3 phase{1.0, 0.0, 0.0};
    {
        int node = 0;
        double largest = -1.0;
        for (std::size_t i = 0; i < finestMesh.nodes.size(); ++i) {
            const double value = peakMagnitude(finest.worstDisplacementReal[i], finest.worstDisplacementImag[i]);
            if (value > largest) { largest = value; node = static_cast<int>(i); }
        }
        const Vec3& re = finest.worstDisplacementReal[node];
        const Vec3& im = finest.worstDisplacementImag[node];
        const double a = dot(re, re), b = -dot(re, im), c = dot(im, im);
        const double half = 0.5 * (a - c), lambda = 0.5 * (a + c) + std::sqrt(half * half + b * b);
        double x = b, y = lambda - a;
        if (std::fabs(x) + std::fabs(y) < 1e-300) { x = lambda - c; y = b; }
        const double norm = std::hypot(x, y);
        if (norm > 0.0) phase = {x / norm, y / norm, 0.0};
    }
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back(finest.worstDisplacementReal[meshNode] * phase.x - finest.worstDisplacementImag[meshNode] * phase.y);
        result.field.vonMisesPa.push_back(finest.worstVonMisesPa[meshNode]);
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
    return Result<HarmonicStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
