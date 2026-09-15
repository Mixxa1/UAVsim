#include "cadnext/fea/ModalStudy.hpp"

#include "cadnext/fea/Modal.hpp"
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<ModalStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<ModalStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

} // namespace

Result<ModalStudyResult> runModalStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                       const IsotropicMaterial& material, const std::string& loadCaseName,
                                       const std::vector<FaceSupport>& supports, const ModalStudySettings& settings,
                                       const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument,
                       "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    if (settings.modeCount < 1) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    if (settings.separationMargin < 0.0) return failure(ErrorCode::InvalidArgument, "запас по частоте не может быть отрицательным");
    for (const auto& band : settings.bands) {
        if (!(band.minimumHz >= 0.0) || !(band.maximumHz >= band.minimumHz)) {
            return failure(ErrorCode::InvalidArgument, "полоса возбуждения «" + band.name + "»: нужно 0 ≤ минимум ≤ максимум");
        }
    }

    ModalStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.bands = settings.bands;
    result.separationMargin = settings.separationMargin;

    std::vector<ModalSolution> solutions;
    TetMesh finestMesh;
    int rigid = 0;
    for (int level = 0; level < 3; ++level) {
        const double size = settings.coarseElementSizeM / std::pow(settings.refinementFactor, level);
        if (progress) progress(level, "mesh");
        SolidMeshingSettings meshing;
        meshing.maximumElementSizeM = size;
        auto meshed = meshSolid(kernel, shape, meshing);
        if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
        SolidMesh solid = meshed.value();
        result.mesherVersion = solid.mesherVersion;

        ModalProblem problem;
        problem.mesh = &solid.mesh;
        problem.material = material;
        problem.attachedMasses = settings.attachedMasses;
        for (const auto& support : supports) {
            if (solid.mesh.faceGroups.count(support.face) == 0) return failure(ErrorCode::NotFound, "нет грани " + support.face + " (опора)");
            DisplacementConstraint constraint;
            constraint.nodes = solid.mesh.nodesOnGroup(support.face);
            for (int c = 0; c < 3; ++c)
                if (support.fixed[c]) constraint.value[c] = 0.0;
            problem.constraints.push_back(std::move(constraint));
        }
        // A partly supported part can still move as a whole in some directions. The solver only says
        // whether all six motions are removed; anything in between is refused rather than guessed.
        // Whether the part is free is known after the first solve; until then room for six rigid modes.
        problem.modeCount = settings.modeCount + (level == 0 ? 6 : rigid);
        if (progress) progress(level, "solve");
        auto solved = solveModal(problem);
        if (!solved.isOk()) return failure(solved.error().code, solved.error().message);
        ModalSolution solution = solved.value();
        if (level == 0) {
            rigid = solution.constrained ? 0 : 6;
            result.constrained = solution.constrained;
            result.totalMassKg = solution.totalMassKg;
            result.attachedMassKg = solution.attachedMassKg;
        }
        if (!solution.constrained && !supports.empty()) {
            return failure(ErrorCode::InvalidArgument,
                           "опоры не исключают движение детали как целого: для частично закреплённой детали число мод жёсткого тела не определено — "
                           "закрепите полностью или снимите опоры (свободная деталь)");
        }
        if (static_cast<int>(solution.modes.size()) < rigid + settings.modeCount) {
            return failure(ErrorCode::InvalidArgument, "у детали на этой сетке меньше мод, чем запрошено");
        }
        // Rigid-body modes of one connected free body sit at round-off, far below the first elastic
        // one. A seventh near-zero mode means several bodies or a mechanism, and it would otherwise be
        // reported as a flexible mode at 0 Hz.
        if (rigid > 0 && solution.modes[rigid - 1].frequencyHz >= 1e-3 * solution.modes[rigid].frequencyHz) {
            return failure(ErrorCode::InvalidArgument,
                           "у свободной детали больше шести мод с нулевой частотой — она состоит из нескольких несвязанных тел или является механизмом");
        }
        std::vector<double> frequencies;
        for (int i = 0; i < settings.modeCount; ++i) frequencies.push_back(solution.modes[rigid + i].frequencyHz);
        result.levelElementSizes.push_back(size);
        result.levelElements.push_back(solid.mesh.elements.size());
        if (level > 0 && result.levelElements[level] <= result.levelElements[level - 1]) {
            return failure(ErrorCode::KernelOperationFailed,
                           "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levelFrequencies.push_back(frequencies);
        solutions.push_back(std::move(solution));
        if (level == 2) finestMesh = std::move(solid.mesh);
    }

    const double r21 = std::cbrt(static_cast<double>(result.levelElements[2]) / result.levelElements[1]);
    const double r32 = std::cbrt(static_cast<double>(result.levelElements[1]) / result.levelElements[0]);
    std::vector<double> uncertainties;
    std::string unusable;
    for (int i = 0; i < settings.modeCount; ++i) {
        ModalStudyMode mode;
        mode.frequencyHz = result.levelFrequencies[2][i];
        // Eigenvalues of quadratic elements converge at O(h^2p) = O(h^4). Modes are matched between
        // meshes by their order; two modes crossing between meshes show up here as non-monotonic.
        mode.convergence = estimateConvergence(result.levelFrequencies[2][i], result.levelFrequencies[1][i],
                                               result.levelFrequencies[0][i], r21, r32, 1.25, kTet10EigenvalueOrder);
        const auto& finest = solutions[2].modes[rigid + i];
        for (int d = 0; d < 3; ++d) {
            mode.effectiveMassFraction[d] = solutions[2].freeMassKg[d] > 0.0 ? finest.effectiveMassKg[d] / solutions[2].freeMassKg[d] : 0.0;
        }
        if (mode.convergence.isUsable()) {
            mode.resonanceUncertaintyHz = mode.convergence.uncertaintyAbsolute;
        } else {
            mode.resonanceUncertaintyHz = std::fabs(result.levelFrequencies[2][i] - result.levelFrequencies[1][i]);
            unusable += (unusable.empty() ? "" : ", ") + std::to_string(i + 1);
            result.uncertaintyUnknown = true;
        }
        uncertainties.push_back(mode.resonanceUncertaintyHz);
        result.modes.push_back(mode);
    }
    if (result.uncertaintyUnknown) {
        result.warnings.push_back("частота мод " + unusable + " сходится немонотонно — погрешность сеткой не оценена; "
                                  "для проверки резонанса взята разность двух лучших сеток");
    }

    std::vector<double> frequencies;
    for (const auto& mode : result.modes) frequencies.push_back(mode.frequencyHz);
    result.resonance = assessResonance(frequencies, uncertainties, settings.bands, settings.separationMargin);
    for (auto finding = result.resonance.rbegin(); finding != result.resonance.rend(); ++finding) {
        if (!finding->overlaps) continue;
        result.resonanceOverlap = true;
        result.warnings.insert(result.warnings.begin(),
                               "резонанс: мода " + std::to_string(finding->modeIndex + 1) + " (" + format(finding->frequencyHz, 1)
                                   + " Гц) в полосе «" + finding->band + "»");
    }
    if (settings.bands.empty()) {
        result.warnings.push_back("полосы возбуждения не заданы — резонанс не проверен");
    }
    // Modes above the last computed one are not checked. The true frequency of the next mode is
    // at least f_N − U_N, so a band reaching that high may hold a mode nobody computed.
    if (!result.modes.empty()) {
        const double lowestUnseen = result.modes.back().frequencyHz - result.modes.back().resonanceUncertaintyHz;
        for (const auto& band : settings.bands) {
            if (band.maximumHz * (1.0 + settings.separationMargin) < lowestUnseen) continue;
            result.uncheckedBands.push_back(band.name);
            result.warnings.push_back("полоса «" + band.name + "» доходит до " + format(band.maximumHz * (1.0 + settings.separationMargin), 1)
                                      + " Гц, выше последней рассчитанной моды (" + format(result.modes.back().frequencyHz, 1)
                                      + " Гц) — моды выше не проверены, увеличьте число мод");
        }
    }

    // Surface shapes of the finest mesh.
    std::unordered_map<int, int> surfaceIndex;
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        for (const auto& face : faces) {
            const auto nodes = finestMesh.faceNodes(face);
            std::vector<int> f;
            for (int node : nodes) {
                auto found = surfaceIndex.find(node);
                if (found == surfaceIndex.end()) {
                    found = surfaceIndex.emplace(node, static_cast<int>(result.field.nodes.size())).first;
                    result.field.nodes.push_back(finestMesh.nodes[node]);
                }
                f.push_back(found->second);
            }
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
    for (int i = 0; i < settings.modeCount; ++i) {
        const auto& shape = solutions[2].modes[rigid + i].shape;
        std::vector<Vec3> surface(result.field.nodes.size());
        double largest = 0.0;
        for (const auto& [meshNode, index] : surfaceIndex) {
            surface[index] = shape[meshNode];
            largest = std::max(largest, length(shape[meshNode]));
        }
        if (largest > 0.0) {
            for (auto& d : surface) d = d * (1.0 / largest);
        }
        result.field.shapes.push_back(std::move(surface));
    }
    return Result<ModalStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
