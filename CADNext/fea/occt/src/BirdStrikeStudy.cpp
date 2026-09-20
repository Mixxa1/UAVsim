#include "cadnext/fea/BirdStrikeStudy.hpp"

#include "cadnext/fea/LinearStatic.hpp" // faceGroupArea
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<BirdStrikeStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<BirdStrikeStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

// Past this the traction is under half the physical one; a positive margin would mean nothing.
constexpr double kPatchDemotionRatio = 2.0;
// The mesher's own area error is orders below a tenth, so anything past it is a real dilution.
constexpr double kPatchWarningRatio = 1.1;

} // namespace

Result<BirdStrikeStudyResult> runBirdStrikeStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                                 const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                                 const BirdStrikeStudySettings& settings, const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument,
                       "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (settings.impactFace.empty()) return failure(ErrorCode::InvalidArgument, "не задана грань удара");
    if (supports.empty()) return failure(ErrorCode::InvalidArgument, "удар птицы требует опор — закрепления детали на конструкции");

    const auto load = birdImpact(settings.bird);
    if (!load.isOk()) return failure(load.error().code, load.error().message);

    BirdStrikeStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.factorOfSafety = settings.criteria.factorOfSafety;
    result.dampingRatio = settings.dampingRatio;
    result.impact = load.value();
    result.warnings = result.impact.warnings;

    TetMesh finestMesh;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
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

        if (!requireFace(settings.impactFace)) return failure(ErrorCode::NotFound, "нет грани " + settings.impactFace + " (грань удара)");

        BirdStrikeProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.attachedMasses = settings.attachedMasses;
        problem.impactFaceGroup = settings.impactFace;
        problem.direction = settings.direction;
        problem.bird = settings.bird;
        problem.dampingRatio = settings.dampingRatio;
        problem.modeCount = settings.modeCount;
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
        if (!settings.stressExclusions.empty()) {
            problem.stressExcluded.assign(mesh.nodes.size(), false);
            for (const auto& exclusion : settings.stressExclusions) {
                if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
                const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
                for (std::size_t n = 0; n < near.size(); ++n) problem.stressExcluded[n] = problem.stressExcluded[n] || near[n];
            }
        }

        if (progress) progress(level, "solve");
        auto solved = solveBirdStrike(problem);
        if (!solved.isOk()) return failure(solved.error().code, solved.error().message);
        BirdStrikeSolution solution = std::move(solved.value());
        if (static_cast<int>(solution.modal.modes.size()) < settings.modeCount) {
            return failure(ErrorCode::InvalidArgument, "у детали на этой сетке меньше мод, чем запрошено");
        }
        if (solution.peakNode < 0) return failure(ErrorCode::InvalidArgument, "зоны исключения покрыли всю деталь");

        BirdStrikeStudyLevel record;
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
        if (level == 0) {
            result.totalMassKg = solution.modal.totalMassKg;
            result.attachedMassKg = solution.modal.attachedMassKg;
        }
        if (level == 2) {
            result.impactFaceAreaM2 = faceGroupArea(mesh, settings.impactFace);
            result.highestModeHz = solution.highestModeHz;
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

    // 0. The bird into the mounting. A struck face that is itself a rigid support reacts the load
    // straight into the fixture: the part sees almost nothing and a positive margin means nothing.
    for (const auto& support : supports) {
        if (support.face != settings.impactFace) continue;
        if (support.fixed[0] && support.fixed[1] && support.fixed[2]) {
            demote("птица бьёт в жёстко закреплённую грань " + settings.impactFace
                   + ": нагрузка уходит прямо в заделку, деталь её почти не чувствует — выберите грань, которая работает");
        }
    }

    // 1. The patch. The load is a uniform traction over the whole named face.
    result.patchRatio = result.impact.areaM2 > 0.0 ? result.impactFaceAreaM2 / result.impact.areaM2 : 0.0;
    if (result.patchRatio > kPatchDemotionRatio) {
        demote("грань удара в " + format(result.patchRatio, 1) + " раза больше миделя птицы (" + format(result.impact.areaM2 * 1e4, 1)
               + " см²): нагрузка размазана по всей грани, местное напряжение занижено — выделите площадку размером с птицу");
    } else if (result.patchRatio > kPatchWarningRatio) {
        result.warnings.push_back("грань удара в " + format(result.patchRatio, 2) + " раза больше миделя птицы — местное напряжение занижено на эту долю");
    } else if (result.patchRatio > 0.0 && result.patchRatio < 1.0) {
        result.warnings.push_back("грань удара меньше миделя птицы (" + format(result.patchRatio, 2)
                                  + " от него): часть тела проходит мимо грани, а остальное сосредоточено сильнее, чем в действительности — оценка с запасом");
    }

    // 2. The modes against the shock front.
    const double shockImpulse = result.impact.areaM2 * result.impact.hugoniotPressurePa * result.impact.shockDurationS;
    result.shockImpulseFraction = result.impact.normalMomentumNs > 0.0 ? shockImpulse / result.impact.normalMomentumNs : 0.0;
    if (result.impact.shockDurationS > 0.0 && result.highestModeHz * result.impact.shockDurationS < 1.0) {
        result.warnings.push_back("ударная фаза длится " + format(result.impact.shockDurationS * 1e6, 1) + " мкс и несёт "
                                  + format(100.0 * result.shockImpulseFraction, 1) + " % импульса, а самая быстрая удержанная мода — "
                                  + format(result.highestModeHz * 1e-3, 1)
                                  + " кГц: неудержанные моды учтены статической поправкой, то есть в полную статическую величину, тогда как на столь "
                                    "коротком импульсе они отозвались бы слабее — оценка с запасом");
    }

    // 3. Past yield the linear answer is not the stress any more.
    if (material.yieldStrengthPa > 0.0 && fine.peakVonMisesPa > material.yieldStrengthPa) {
        result.warnings.push_back("расчётное напряжение выше предела текучести: линейно-упругая модель за ним не описывает деталь — результат означает "
                                  "необходимость испытания, а не величину напряжения");
    }
    if (!settings.stressExclusions.empty()) result.warnings.push_back("максимум напряжения взят вне заданных зон исключения");
    if (result.stressConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
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
    for (const auto& mode : result.finest.modal.modes) result.modeFrequenciesHz.push_back(mode.frequencyHz);
    result.finest.worstVonMisesPa.clear();
    result.finest.worstDisplacement.clear();
    result.finest.modal.modes.clear();
    return Result<BirdStrikeStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
