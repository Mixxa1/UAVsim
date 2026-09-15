#include "cadnext/fea/StructuralStudy.hpp"

#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <set>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<StructuralStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<StructuralStudyResult>::fail({code, message});
}

// Nodes within `distance` of any node of `faceNodes`, via a uniform grid of that cell size.
std::vector<bool> nodesNear(const TetMesh& mesh, const std::vector<int>& faceNodes, double distance) {
    std::vector<bool> near(mesh.nodes.size(), false);
    if (faceNodes.empty() || !(distance > 0.0)) return near;
    auto cell = [distance](double v) { return static_cast<long long>(std::floor(v / distance)); };
    auto key = [](long long x, long long y, long long z) { return (x * 73856093LL) ^ (y * 19349663LL) ^ (z * 83492791LL); };
    std::unordered_map<long long, std::vector<int>> grid;
    for (int n : faceNodes) {
        const Vec3& p = mesh.nodes[n];
        grid[key(cell(p.x), cell(p.y), cell(p.z))].push_back(n);
    }
    for (std::size_t i = 0; i < mesh.nodes.size(); ++i) {
        const Vec3& p = mesh.nodes[i];
        const long long cx = cell(p.x), cy = cell(p.y), cz = cell(p.z);
        for (long long dx = -1; dx <= 1 && !near[i]; ++dx)
            for (long long dy = -1; dy <= 1 && !near[i]; ++dy)
                for (long long dz = -1; dz <= 1 && !near[i]; ++dz) {
                    const auto found = grid.find(key(cx + dx, cy + dy, cz + dz));
                    if (found == grid.end()) continue;
                    for (int n : found->second) {
                        if (length(mesh.nodes[n] - p) <= distance) {
                            near[i] = true;
                            break;
                        }
                    }
                }
    }
    return near;
}

} // namespace

Result<StructuralStudyResult> runStructuralStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                                 const IsotropicMaterial& material, const StructuralLoadCase& loadCase,
                                                 const StructuralStudySettings& settings,
                                                 const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) {
        return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    }
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument,
                       "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (loadCase.supports.empty()) {
        return failure(ErrorCode::InvalidArgument, "в нагрузочном случае нет опор");
    }

    StructuralStudyResult result;
    result.loadCaseName = loadCase.name;
    result.material = material;
    result.factorOfSafety = settings.criteria.factorOfSafety;

    TetMesh finestMesh;
    LinearStaticSolution finestSolution;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
    int finestCriticalNode = -1;

    for (int level = 0; level < 3; ++level) {
        const double size = settings.coarseElementSizeM / std::pow(settings.refinementFactor, level);
        if (progress) progress(level, "mesh");
        SolidMeshingSettings meshing;
        meshing.maximumElementSizeM = size;
        auto meshed = meshSolid(kernel, shape, meshing);
        if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
        SolidMesh solid = meshed.value();
        result.mesherVersion = solid.mesherVersion;
        result.cadVolumeM3 = solid.cadVolumeM3;
        TetMesh& mesh = solid.mesh;

        auto requireFace = [&](const std::string& face) { return mesh.faceGroups.count(face) > 0; };
        LinearStaticProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        std::vector<int> supportNodes;
        for (const auto& support : loadCase.supports) {
            if (!requireFace(support.face)) return failure(ErrorCode::NotFound, "нет грани " + support.face + " (опора)");
            DisplacementConstraint constraint;
            constraint.nodes = mesh.nodesOnGroup(support.face);
            for (int c = 0; c < 3; ++c) {
                if (support.fixed[c]) constraint.value[c] = 0.0;
            }
            // Only a full clamp restrains Poisson contraction and makes its edge singular; a
            // symmetry or roller support (one component) does not.
            if (support.fixed[0] && support.fixed[1] && support.fixed[2]) {
                supportNodes.insert(supportNodes.end(), constraint.nodes.begin(), constraint.nodes.end());
            }
            problem.constraints.push_back(std::move(constraint));
        }
        for (const auto& force : loadCase.forces) {
            if (!requireFace(force.face)) return failure(ErrorCode::NotFound, "нет грани " + force.face + " (сила)");
            const double area = faceGroupArea(mesh, force.face);
            problem.tractions.push_back({force.face, force.totalForceN * (1.0 / area)});
        }
        for (const auto& pressure : loadCase.pressures) {
            if (!requireFace(pressure.face)) return failure(ErrorCode::NotFound, "нет грани " + pressure.face + " (давление)");
            problem.pressures.push_back({pressure.face, pressure.pressurePa});
        }
        problem.bodyAcceleration = loadCase.bodyAccelerationMps2;

        if (progress) progress(level, "solve");
        auto solved = solveLinearStatic(problem);
        if (!solved.isOk()) return failure(solved.error().code, solved.error().message);
        LinearStaticSolution solution = solved.value();

        std::vector<bool> excluded(mesh.nodes.size(), false);
        for (const auto& exclusion : loadCase.stressExclusions) {
            if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
            const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
            for (std::size_t n = 0; n < near.size(); ++n) excluded[n] = excluded[n] || near[n];
        }
        StructuralStudyLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.dofs = solution.totalDofs;
        record.maxDisplacementM = solution.maxDisplacementM;
        int critical = -1;
        for (std::size_t n = 0; n < mesh.nodes.size(); ++n) {
            if (excluded[n]) continue;
            if (critical < 0 || solution.nodalVonMises[n] > solution.nodalVonMises[critical]) critical = static_cast<int>(n);
        }
        if (critical < 0) return failure(ErrorCode::InvalidArgument, "зоны исключения покрыли всю деталь");
        record.maxVonMisesPa = solution.nodalVonMises[critical];
        record.criticalPoint = mesh.nodes[critical];
        if (level > 0 && record.elements <= result.levels.back().elements) {
            return failure(ErrorCode::KernelOperationFailed,
                           "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levels.push_back(record);

        if (level == 2) {
            finestMesh = std::move(mesh);
            finestSolution = std::move(solution);
            finestSupportNodes = std::move(supportNodes);
            finestElementSize = size;
            finestCriticalNode = critical;
        }
    }

    const auto& coarse = result.levels[0];
    const auto& medium = result.levels[1];
    const auto& fine = result.levels[2];
    const double r21 = std::cbrt(static_cast<double>(fine.elements) / static_cast<double>(medium.elements));
    const double r32 = std::cbrt(static_cast<double>(medium.elements) / static_cast<double>(coarse.elements));
    result.stressConvergence = estimateConvergence(fine.maxVonMisesPa, medium.maxVonMisesPa, coarse.maxVonMisesPa, r21,
                                                   r32, 1.25, kTet10StressOrder);
    result.displacementConvergence = estimateConvergence(fine.maxDisplacementM, medium.maxDisplacementM,
                                                         coarse.maxDisplacementM, r21, r32, 1.25, kTet10DisplacementOrder);
    result.assessment = assessStrength(material, fine.maxVonMisesPa, result.stressConvergence, settings.criteria);
    result.criticalPoint = fine.criticalPoint;

    for (const auto& [name, faces] : finestMesh.faceGroups) {
        const auto nodes = finestMesh.nodesOnGroup(name);
        if (std::binary_search(nodes.begin(), nodes.end(), finestCriticalNode)) {
            result.criticalFace = name;
            break;
        }
    }

    // A maximum sitting on an idealised support is the classic false answer of a static analysis:
    // a fully fixed face is infinitely stiff, and the stress at its edge grows with refinement
    // more slowly than three meshes can reveal. "Within one finest element" is the mesh's own
    // resolution, not a tuned distance.
    const auto nearSupport = nodesNear(finestMesh, finestSupportNodes, finestElementSize);
    if (nearSupport[finestCriticalNode]) {
        const std::string reason = "максимум напряжения у жёсткой заделки — вероятна особенность идеализированного закрепления; задайте зону исключения или смоделируйте крепёж";
        result.assessment.reasons.push_back(reason);
        if (result.assessment.verdict == StrengthVerdict::Pass) result.assessment.verdict = StrengthVerdict::Warning;
    }
    if (!loadCase.stressExclusions.empty()) {
        result.warnings.push_back("максимум напряжения взят вне заданных зон исключения");
    }
    if (result.stressConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
    }

    // Surface field of the finest mesh.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back(finestSolution.displacement[meshNode]);
        result.field.vonMisesPa.push_back(finestSolution.nodalVonMises[meshNode]);
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
    return Result<StructuralStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
