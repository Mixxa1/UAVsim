#include "cadnext/fea/FireStudy.hpp"

#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/SolidMesher.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <set>
#include <unordered_map>

namespace cadnext::fea {

namespace {

Result<FireStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<FireStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

std::string celsius(double kelvin) {
    return format(kelvin - 273.15, 1) + " °C";
}

constexpr int kStressSamples = 20; // over the exposure, besides the last instant before any loss of integrity

struct Setup {
    const TetMesh* mesh = nullptr;
    std::vector<std::string> flameFaces, unexposed;
    std::vector<std::vector<int>> componentNodes;
    std::vector<DisplacementConstraint> constraints;
    std::vector<SurfaceTraction> tractions;
    std::vector<SurfacePressure> pressures;
    Vec3 bodyAcceleration;
    std::vector<bool> excluded;
};

// One exposure of one mesh to one flame model with one time step, and its stress.
struct Run {
    FlameModel model = FlameModel::Radiative;
    double peakK = 0.0;
    int peakNode = -1;
    double failureTimeS = -1.0;
    std::vector<double> componentMaxK, componentMaxTimeS, componentMinK;
    FireSeries series;
    std::vector<std::vector<double>> samples;
    std::vector<double> sampleTimeS;
    std::vector<double> finalField;
    double utilization = 0.0, utilizationTimeS = 0.0;
    int utilizationNode = -1;
    std::vector<double> vonMises, utilizationField;
    std::vector<Vec3> displacement;
};

ThermalProblem thermalProblem(const Setup& setup, const HotMaterial& hot, const StandardFlame& flame, FlameModel model, const FireStudySettings& settings) {
    ThermalProblem problem;
    problem.mesh = setup.mesh;
    problem.material.densityKgM3 = hot.densityKgM3;
    problem.material.conductivityOf = hot.conductivityWmK;
    problem.material.specificHeatOf = hot.specificHeatJkgK;
    for (const auto& face : setup.flameFaces) {
        if (model == FlameModel::Convective) problem.convection.push_back({face, flameConvectionCoefficient(flame), flame.temperatureK});
        else problem.radiation.push_back({face, flameEmissivity(flame), flame.temperatureK});
    }
    for (const auto& face : setup.unexposed) {
        problem.convection.push_back({face, kUnexposedConvectionWm2K, kLaboratoryK});
        problem.radiation.push_back({face, settings.surfaceEmissivity, kLaboratoryK});
    }
    if (settings.operating)
        for (const auto& component : settings.components)
            if (component.powerW > 0.0) problem.heatLoads.push_back({component.face, component.powerW});
    return problem;
}

double faceMaximum(const std::vector<double>& T, const std::vector<int>& nodes) {
    double value = -std::numeric_limits<double>::infinity();
    for (int n : nodes) value = std::max(value, T[n]);
    return value;
}
double faceMinimum(const std::vector<double>& T, const std::vector<int>& nodes) {
    double value = std::numeric_limits<double>::infinity();
    for (int n : nodes) value = std::min(value, T[n]);
    return value;
}

Result<Run> runThermal(const Setup& setup, const HotMaterial& hot, const StandardFlame& flame, FlameModel model, const FireStudySettings& settings,
                       double stepS) {
    using R = Result<Run>;
    Run run;
    run.model = model;
    const std::size_t count = setup.componentNodes.size();
    run.componentMaxK.assign(count, kLaboratoryK);
    run.componentMaxTimeS.assign(count, 0.0);
    run.componentMinK.assign(count, kLaboratoryK);
    run.series.componentMaximumK.assign(count, {kLaboratoryK});
    run.series.timeS = {0.0};
    run.series.partMaximumK = {kLaboratoryK};
    run.series.partMinimumK = {kLaboratoryK};
    TransientSettings transient;
    transient.stepS = stepS;
    transient.endS = settings.durationS;
    transient.initialK = kLaboratoryK;
    const int steps = static_cast<int>(std::ceil(settings.durationS / stepS - 1e-9));
    const int sampleEvery = std::max(1, static_cast<int>(std::lround(static_cast<double>(steps) / kStressSamples)));
    int step = 0;
    double previousMax = kLaboratoryK;
    std::vector<double> previous(setup.mesh->nodes.size(), kLaboratoryK), blended;
    const auto solved = solveTransientThermal(thermalProblem(setup, hot, flame, model, settings), transient, std::numeric_limits<int>::max(),
                                              [&](double t, const std::vector<double>& computed) {
        ++step;
        const std::vector<double>* field = &computed;
        double time = t;
        // Integrity: where the proof strength is gone. The step that crosses it is cut back to the instant
        // of the crossing (linear between the two steps), so nothing is reported from beyond it.
        const double hottest = *std::max_element(computed.begin(), computed.end());
        const bool fails = hot.noStrengthK && hottest >= *hot.noStrengthK;
        if (fails) {
            const double w = (*hot.noStrengthK - previousMax) / (hottest - previousMax);
            blended.resize(computed.size());
            for (std::size_t n = 0; n < computed.size(); ++n) blended[n] = previous[n] + w * (computed[n] - previous[n]);
            field = &blended;
            time = t - stepS + w * stepS;
        }
        const auto& T = *field;
        const auto [lo, hi] = std::minmax_element(T.begin(), T.end());
        run.series.timeS.push_back(time);
        run.series.partMaximumK.push_back(*hi);
        run.series.partMinimumK.push_back(*lo);
        for (std::size_t c = 0; c < count; ++c) {
            const double top = faceMaximum(T, setup.componentNodes[c]);
            run.series.componentMaximumK[c].push_back(top);
            if (top > run.componentMaxK[c]) run.componentMaxK[c] = top, run.componentMaxTimeS[c] = time;
            run.componentMinK[c] = std::min(run.componentMinK[c], faceMinimum(T, setup.componentNodes[c]));
        }
        if (*hi > run.peakK) run.peakK = *hi, run.peakNode = static_cast<int>(hi - T.begin());
        if (fails) {
            run.failureTimeS = time;
            run.finalField = T;
            return false;
        }
        previousMax = *hi;
        previous = computed;
        if (step % sampleEvery == 0 || step == steps) {
            run.samples.push_back(T);
            run.sampleTimeS.push_back(t);
        }
        if (step == steps) run.finalField = T;
        return true;
    });
    if (!solved.isOk()) return R::fail(solved.error());
    return R::ok(std::move(run));
}

// Utilisation σ_vM / (k₀.₂(θ) f₀.₂) over the samples (none after the loss of integrity).
std::optional<std::string> runStress(Run& run, const Setup& setup, const IsotropicMaterial& material, const HotMaterial& hot, bool keepField) {
    const TetMesh& mesh = *setup.mesh;
    const double f02 = material.yieldStrengthPa.value_or(material.ultimateStrengthPa);
    for (std::size_t s = 0; s < run.samples.size(); ++s) {
        const auto& T = run.samples[s];
        LinearStaticProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.constraints = setup.constraints;
        problem.tractions = setup.tractions;
        problem.pressures = setup.pressures;
        problem.bodyAcceleration = setup.bodyAcceleration;
        problem.thermalStrain.resize(T.size());
        const double reference = hot.thermalStrain(kLaboratoryK);
        for (std::size_t n = 0; n < T.size(); ++n) problem.thermalStrain[n] = hot.thermalStrain(T[n]) - reference;
        problem.elementModulusScale.resize(mesh.elements.size());
        for (std::size_t e = 0; e < mesh.elements.size(); ++e) {
            const auto& element = mesh.elements[e];
            double mean = 0.0;
            if (mesh.order == ElementOrder::Quadratic) {
                // Volume mean of a quadratic field over a tetrahedron: ∫N_corner = −V/20, ∫N_midside = V/5.
                for (int k = 0; k < 4; ++k) mean -= T[element[k]] / 20.0;
                for (int k = 4; k < 10; ++k) mean += T[element[k]] / 5.0;
            } else {
                for (int k = 0; k < 4; ++k) mean += T[element[k]] / 4.0;
            }
            // E vanishes at 550 °C (Table 2); a sample is never taken past the loss of integrity, but a floor
            // keeps the stiffness positive where a corner already approaches it.
            problem.elementModulusScale[e] = std::max(hot.modulusRatio(mean), 1e-3);
        }
        const auto solved = solveLinearStatic(problem);
        if (!solved.isOk()) return solved.error().message;
        const auto& solution = solved.value();
        for (std::size_t n = 0; n < T.size(); ++n) {
            if (!setup.excluded.empty() && setup.excluded[n]) continue;
            const double strength = hot.proofStrengthRatio(T[n]) * f02;
            const double u = strength > 0.0 ? solution.nodalVonMises[n] / strength : std::numeric_limits<double>::infinity();
            if (u > run.utilization) {
                run.utilization = u, run.utilizationTimeS = run.sampleTimeS[s], run.utilizationNode = static_cast<int>(n);
                if (keepField) {
                    run.vonMises = solution.nodalVonMises;
                    run.displacement = solution.displacement;
                    run.utilizationField.resize(T.size());
                    for (std::size_t m = 0; m < T.size(); ++m) {
                        const double sm = hot.proofStrengthRatio(T[m]) * f02;
                        run.utilizationField[m] = sm > 0.0 ? solution.nodalVonMises[m] / sm : 1e9;
                    }
                }
            }
        }
        run.series.sampleTimeS.push_back(run.sampleTimeS[s]);
        run.series.utilization.push_back(run.utilization);
    }
    return std::nullopt;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

double bandOf(const ConvergenceEstimate& estimate, double fine, double medium, double coarse) {
    return estimate.isUsable() ? estimate.uncertaintyAbsolute : std::max({fine, medium, coarse}) - std::min({fine, medium, coarse});
}

} // namespace

Result<FireStudyResult> runFireStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                     const std::string& loadCaseName, const std::vector<FaceSupport>& supports, const FireStudySettings& settings,
                                     const StructuralStudyProgress& progress) {
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument, "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    const auto hot = hotMaterial(material.id);
    if (!hot) {
        return failure(ErrorCode::InvalidArgument, "нет данных: свойства материала «" + material.displayName
                                                       + "» при нагреве (опубликованный набор есть для алюминия 6061-T6 и 7075-T6 по EN 1999-1-2)");
    }
    if (!(settings.durationS > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана длительность воздействия (5 мин — огнестойкий, 15 — огненепроницаемый)");
    if (settings.flameFaces.empty()) return failure(ErrorCode::InvalidArgument, "не заданы грани под пламенем");
    if (!(settings.surfaceEmissivity > 0.0 && settings.surfaceEmissivity <= 1.0)) {
        return failure(ErrorCode::InvalidArgument, "не задана излучательная способность поверхности (EN 1999-1-2: 0.3 чистая, 0.7 окрашенная)");
    }
    if (!(settings.stepS > 0.0 && settings.stepS <= settings.durationS / 10.0)) return failure(ErrorCode::InvalidArgument, "шаг по времени: > 0 и не больше десятой доли воздействия");
    const bool loaded = !settings.forces.empty() || !settings.pressures.empty() || length(settings.bodyAccelerationMps2) > 0.0;
    if (loaded && supports.empty()) return failure(ErrorCode::InvalidArgument, "нагрузки без опор: закрепите деталь");

    FireStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.flame = standardFlame(settings.standard);
    result.durationS = settings.durationS;
    result.stepS = settings.stepS;
    result.flameConvectionWm2K = flameConvectionCoefficient(result.flame);
    result.flameEmissivity = flameEmissivity(result.flame);
    result.hotMaterialSource = hot->source;
    result.dataValidUpToK = hot->dataValidUpToK;
    result.noStrengthK = hot->noStrengthK;
    result.strengthData = static_cast<bool>(hot->proofStrengthRatio);

    std::vector<Run> runs; // governing model per level
    Run other;
    double timeErrorK = 0.0, timeErrorS = 0.0, timeErrorU = 0.0;
    TetMesh finestMesh;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
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

        Setup setup;
        setup.mesh = &mesh;
        std::set<std::string> flame, covered;
        for (const auto& face : settings.flameFaces) {
            if (!requireFace(face)) return failure(ErrorCode::NotFound, "нет грани " + face + " (пламя)");
            flame.insert(face);
        }
        for (const auto& component : settings.components) {
            if (!requireFace(component.face)) return failure(ErrorCode::NotFound, "нет грани " + component.face + " (оборудование " + component.name + ")");
            if (flame.count(component.face)) return failure(ErrorCode::InvalidArgument, "оборудование «" + component.name + "» стоит на грани под пламенем");
            covered.insert(component.face);
            setup.componentNodes.push_back(mesh.nodesOnGroup(component.face));
        }
        std::vector<int> supportNodes;
        for (const auto& support : supports) {
            if (!requireFace(support.face)) return failure(ErrorCode::NotFound, "нет грани " + support.face + " (опора)");
            if (flame.count(support.face)) return failure(ErrorCode::InvalidArgument, "грань " + support.face + " одновременно под пламенем и в опоре");
            covered.insert(support.face);
            DisplacementConstraint constraint;
            constraint.nodes = mesh.nodesOnGroup(support.face);
            for (int c = 0; c < 3; ++c)
                if (support.fixed[c]) constraint.value[c] = 0.0;
            if (support.fixed[0] && support.fixed[1] && support.fixed[2]) supportNodes.insert(supportNodes.end(), constraint.nodes.begin(), constraint.nodes.end());
            setup.constraints.push_back(std::move(constraint));
        }
        if (supports.empty()) setup.constraints = kinematicSupports(mesh);
        for (const auto& force : settings.forces) {
            if (!requireFace(force.face)) return failure(ErrorCode::NotFound, "нет грани " + force.face + " (сила)");
            setup.tractions.push_back({force.face, force.totalForceN * (1.0 / faceGroupArea(mesh, force.face))});
        }
        for (const auto& pressure : settings.pressures) {
            if (!requireFace(pressure.face)) return failure(ErrorCode::NotFound, "нет грани " + pressure.face + " (давление)");
            setup.pressures.push_back({pressure.face, pressure.pressurePa});
        }
        setup.bodyAcceleration = settings.bodyAccelerationMps2;
        setup.flameFaces.assign(flame.begin(), flame.end());
        for (const auto& [name, faces] : mesh.faceGroups)
            if (!flame.count(name) && !covered.count(name)) setup.unexposed.push_back(name);
        if (!settings.stressExclusions.empty()) {
            setup.excluded.assign(mesh.nodes.size(), false);
            for (const auto& exclusion : settings.stressExclusions) {
                if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
                const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
                for (std::size_t n = 0; n < near.size(); ++n) setup.excluded[n] = setup.excluded[n] || near[n];
            }
        }

        if (progress) progress(level, "solve");
        auto exposed = [&](FlameModel model, double step, bool stress, bool keepField) -> Result<Run> {
            auto run = runThermal(setup, *hot, result.flame, model, settings, step);
            if (!run.isOk()) return run;
            Run value = std::move(run.value());
            if (stress && result.strengthData) {
                if (const auto message = runStress(value, setup, material, *hot, keepField)) return Result<Run>::fail({ErrorCode::KernelOperationFailed, *message});
            }
            return Result<Run>::ok(std::move(value));
        };
        if (level == 0) {
            // Which limit of the flame is worse for this part: the earlier loss of integrity, else the hotter end.
            auto convective = exposed(FlameModel::Convective, settings.stepS, false, false);
            auto radiative = exposed(FlameModel::Radiative, settings.stepS, false, false);
            if (!convective.isOk()) return failure(convective.error().code, convective.error().message);
            if (!radiative.isOk()) return failure(radiative.error().code, radiative.error().message);
            const auto& c = convective.value();
            const auto& r = radiative.value();
            const bool cFails = c.failureTimeS >= 0.0, rFails = r.failureTimeS >= 0.0;
            if (cFails || rFails) result.governingModel = (cFails && (!rFails || c.failureTimeS < r.failureTimeS)) ? FlameModel::Convective : FlameModel::Radiative;
            else result.governingModel = c.peakK > r.peakK ? FlameModel::Convective : FlameModel::Radiative;
        }
        auto governing = exposed(result.governingModel, settings.stepS, true, level == 2);
        if (!governing.isOk()) return failure(governing.error().code, governing.error().message);
        Run run = std::move(governing.value());
        if (level == 0) {
            auto half = exposed(result.governingModel, settings.stepS / 2.0, true, false);
            if (!half.isOk()) return failure(half.error().code, half.error().message);
            timeErrorK = std::fabs(run.peakK - half.value().peakK) / 3.0;
            for (std::size_t c = 0; c < run.componentMaxK.size(); ++c) timeErrorK = std::max(timeErrorK, std::fabs(run.componentMaxK[c] - half.value().componentMaxK[c]) / 3.0);
            if (run.failureTimeS >= 0.0 && half.value().failureTimeS >= 0.0) timeErrorS = std::fabs(run.failureTimeS - half.value().failureTimeS) / 3.0;
            timeErrorU = std::fabs(run.utilization - half.value().utilization) / 3.0;
        }
        FireLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.peakK = run.peakK;
        record.failureTimeS = run.failureTimeS;
        record.utilization = run.utilization;
        if (level > 0 && record.elements <= result.levels.back().elements) {
            return failure(ErrorCode::KernelOperationFailed, "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levels.push_back(record);
        if (level == 2) {
            const FlameModel otherModel = result.governingModel == FlameModel::Radiative ? FlameModel::Convective : FlameModel::Radiative;
            auto otherRun = exposed(otherModel, settings.stepS, true, false);
            if (!otherRun.isOk()) return failure(otherRun.error().code, otherRun.error().message);
            other = std::move(otherRun.value());
            for (const auto& face : setup.flameFaces) result.flameAreaM2 += faceGroupArea(mesh, face);
            for (const auto& face : setup.unexposed) result.exposedAreaM2 += faceGroupArea(mesh, face);
            for (const auto& face : covered) result.coveredAreaM2 += faceGroupArea(mesh, face);
            finestMesh = std::move(mesh);
            finestSupportNodes = std::move(supportNodes);
            finestElementSize = size;
        }
        runs.push_back(std::move(run));
    }

    // --- Convergence (the governing model).
    const auto& coarse = result.levels[0];
    const auto& medium = result.levels[1];
    const auto& fine = result.levels[2];
    const double r21 = std::cbrt(static_cast<double>(fine.elements) / static_cast<double>(medium.elements));
    const double r32 = std::cbrt(static_cast<double>(medium.elements) / static_cast<double>(coarse.elements));
    auto converge = [&](double f, double m, double c, double order) { return estimateConvergence(f, m, c, r21, r32, 1.25, order); };
    result.peakConvergence = converge(fine.peakK, medium.peakK, coarse.peakK, kTet10DisplacementOrder);
    const bool failsEverywhere = fine.failureTimeS >= 0.0 && medium.failureTimeS >= 0.0 && coarse.failureTimeS >= 0.0;
    const bool failsSomewhere = fine.failureTimeS >= 0.0 || medium.failureTimeS >= 0.0 || coarse.failureTimeS >= 0.0;
    if (failsEverywhere) result.failureConvergence = converge(fine.failureTimeS, medium.failureTimeS, coarse.failureTimeS, kTet10DisplacementOrder);
    if (result.strengthData) result.utilizationConvergence = converge(fine.utilization, medium.utilization, coarse.utilization, kTet10StressOrder);
    result.timeStepErrorK = timeErrorK, result.timeStepErrorS = timeErrorS, result.timeStepErrorUtilization = timeErrorU;

    // --- Worst of the two flame models on the finest mesh.
    const Run& finest = runs[2];
    result.finestModels = {{finest.model, finest.peakK, finest.failureTimeS, finest.utilization}, {other.model, other.peakK, other.failureTimeS, other.utilization}};
    result.peakK = std::max(finest.peakK, other.peakK);
    result.peakUncertaintyK = bandOf(result.peakConvergence, fine.peakK, medium.peakK, coarse.peakK) + timeErrorK;
    result.hottestPoint = finestMesh.nodes[finest.peakNode];
    const bool finestFails = finest.failureTimeS >= 0.0, otherFails = other.failureTimeS >= 0.0;
    result.integrityLost = finestFails || otherFails;
    if (result.integrityLost) {
        result.failureTimeS = finestFails && otherFails ? std::min(finest.failureTimeS, other.failureTimeS) : finestFails ? finest.failureTimeS : other.failureTimeS;
        result.failureUncertaintyS = (failsEverywhere ? bandOf(result.failureConvergence, fine.failureTimeS, medium.failureTimeS, coarse.failureTimeS) : 0.0) + timeErrorS;
    }
    result.utilization = std::max(finest.utilization, other.utilization);
    result.utilizationTimeS = finest.utilization >= other.utilization ? finest.utilizationTimeS : other.utilizationTimeS;
    if (result.strengthData) result.utilizationUncertainty = bandOf(result.utilizationConvergence, fine.utilization, medium.utilization, coarse.utilization) + timeErrorU;
    if (finest.utilizationNode >= 0) result.criticalPoint = finestMesh.nodes[finest.utilizationNode];
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        const auto nodes = finestMesh.nodesOnGroup(name);
        if (finest.utilizationNode >= 0 && std::binary_search(nodes.begin(), nodes.end(), finest.utilizationNode)) {
            result.criticalFace = name;
            break;
        }
    }

    // --- Verdict.
    StrengthVerdict verdict = StrengthVerdict::Pass;
    auto report = [&](StrengthVerdict v, const std::string& text) {
        verdict = worse(verdict, v);
        if (v == StrengthVerdict::Fail) result.failureReasons.push_back(text);
        else if (v == StrengthVerdict::Warning) result.reasons.push_back(text);
    };
    if (result.integrityLost) {
        const bool clearly = result.failureTimeS + result.failureUncertaintyS < settings.durationS;
        report(clearly ? StrengthVerdict::Fail : StrengthVerdict::Warning,
               "целостность: через " + format(result.failureTimeS, 1) + " ± " + format(result.failureUncertaintyS, 1) + " с деталь нагрелась до "
                   + celsius(*hot->noStrengthK) + ", где прочность по EN 1999-1-2 равна нулю (требуется " + format(settings.durationS, 0) + " с)");
        if (failsSomewhere && !failsEverywhere) report(StrengthVerdict::Warning, "потеря целостности на одних сетках и не на других — результат у самого предела");
    } else if (hot->noStrengthK) {
        if (result.peakK + result.peakUncertaintyK >= *hot->noStrengthK) {
            report(StrengthVerdict::Warning, "целостность: максимум " + celsius(result.peakK) + " в пределах погрешности от " + celsius(*hot->noStrengthK));
        }
    } else {
        report(StrengthVerdict::Warning, "нет данных: температура, при которой материал «" + material.displayName + "» теряет прочность");
    }
    if (result.strengthData) {
        const auto check = checkTemperature(result.utilization, result.utilizationUncertainty, 1.0, true);
        if (check.verdict != StrengthVerdict::Pass) {
            report(check.verdict, "прочность при нагреве: σ/(k₀.₂(θ)·f₀.₂) = " + format(result.utilization, 3) + " ± " + format(result.utilizationUncertainty, 3)
                                      + " (EN 1999-1-2, γ_M,fi = 1.0)");
        }
        if (result.utilizationConvergence.behaviour == ConvergenceBehaviour::Divergent && result.utilization > 0.0) {
            report(StrengthVerdict::Warning, "использование прочности не сходится по сетке — вероятна особенность (острый угол, точечная опора)");
        }
        if (finest.utilizationNode >= 0 && !finestSupportNodes.empty() && nodesNear(finestMesh, finestSupportNodes, finestElementSize)[finest.utilizationNode]) {
            report(StrengthVerdict::Warning, "максимум использования у жёсткой заделки — идеализированное закрепление без теплового расширения завышает его");
        }
    } else {
        report(StrengthVerdict::Warning, "нет данных: прочность материала «" + material.displayName + "» при нагреве (EN 1999-1-2 Table 1a её не приводит)");
    }
    for (std::size_t c = 0; c < settings.components.size(); ++c) {
        const auto& component = settings.components[c];
        ClimateComponentResult out;
        out.name = component.name;
        out.face = component.face;
        out.powerW = settings.operating ? component.powerW : 0.0;
        out.maximumK = std::max(finest.componentMaxK[c], other.componentMaxK[c]);
        out.maximumTimeS = finest.componentMaxK[c] >= other.componentMaxK[c] ? finest.componentMaxTimeS[c] : other.componentMaxTimeS[c];
        out.minimumK = std::min(finest.componentMinK[c], other.componentMinK[c]);
        out.maximumConvergence = converge(runs[2].componentMaxK[c], runs[1].componentMaxK[c], runs[0].componentMaxK[c], kTet10DisplacementOrder);
        out.uncertaintyK = bandOf(out.maximumConvergence, runs[2].componentMaxK[c], runs[1].componentMaxK[c], runs[0].componentMaxK[c]) + timeErrorK;
        if (component.maximumK) out.checks.push_back(checkTemperature(out.maximumK, out.uncertaintyK, *component.maximumK, true));
        if (component.minimumK) out.checks.push_back(checkTemperature(out.minimumK, out.uncertaintyK, *component.minimumK, false));
        for (const auto& check : out.checks) {
            out.verdict = worse(out.verdict, check.verdict);
            if (check.verdict != StrengthVerdict::Pass) {
                report(check.verdict, component.name + ": " + (check.upper ? "максимум " : "минимум ") + celsius(check.valueK) + " ± " + format(check.uncertaintyK, 2)
                                          + " K против предела " + celsius(check.limitK));
            }
        }
        if (out.checks.empty()) {
            out.verdict = StrengthVerdict::Warning;
            report(StrengthVerdict::Warning, "нет пределов температуры у оборудования «" + component.name + "» — задайте по его паспорту");
        }
        result.components.push_back(std::move(out));
    }
    if (result.peakK > hot->dataValidUpToK) {
        report(StrengthVerdict::Warning, "максимум " + celsius(result.peakK) + " выше 500 °C — свойства EN 1999-1-2 там экстраполированы");
    }
    result.verdict = verdict;
    result.warnings.push_back("пламя " + result.flame.source + "; расчёт по худшему из двух пределов (конвекция / излучение): "
                              + std::string(result.governingModel == FlameModel::Radiative ? "излучение" : "конвекция"));
    result.warnings.push_back("f₀.₂ при 20 °C — типичное значение базы материалов, не расчётное по EN 1999-1-1");
    if (result.peakConvergence.orderLimitedToFormal || result.utilizationConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
    }
    if (!settings.stressExclusions.empty()) result.warnings.push_back("максимум использования взят вне заданных зон исключения");
    result.series = finest.series;

    // --- Surface field.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back(finest.displacement.empty() ? Vec3{} : finest.displacement[meshNode]);
        result.field.vonMisesPa.push_back(finest.vonMises.empty() ? 0.0 : finest.vonMises[meshNode]);
        result.fieldTemperatureK.push_back(finest.finalField.empty() ? kLaboratoryK : finest.finalField[meshNode]);
        result.fieldUtilization.push_back(finest.utilizationField.empty() ? 0.0 : finest.utilizationField[meshNode]);
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
    return Result<FireStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
