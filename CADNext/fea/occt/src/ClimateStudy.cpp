#include "cadnext/fea/ClimateStudy.hpp"

#include "cadnext/fea/AirConvection.hpp"
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

Result<ClimateStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<ClimateStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

std::string celsius(double kelvin, int digits = 1) {
    return format(kelvin - 273.15, digits) + " °C";
}

constexpr double kPeriodicToleranceK = 0.01;
constexpr int kMinimumCycles = 3, kMaximumCycles = 7; // Method 505.7 §2.3.2
constexpr double kSampleIntervalS = 1800.0;

// The air, sun and film coefficient the part sees, resolved once from the settings.
struct Environment {
    bool hot = true;
    DiurnalCycle cycle;
    double coldAirK = 0.0;
    double lapseK = 0.0; // the standard's surface air cooled to the flight altitude
    double riseK = 0.0;  // adiabatic-wall rise, convection only
    bool sun = false;
    bool operating = true;
    double pressurePa = kStandardSeaLevelPressurePa;
    Vec3 up;
    double airK(double t) const { return hot ? cycle.airK(t) - lapseK : coldAirK - lapseK; }
    double irradiance(double t) const { return sun ? cycle.irradianceWm2(t) : 0.0; }
    double meanAirK() const { return hot ? cycle.meanAirK() - lapseK : coldAirK - lapseK; }
    double meanIrradiance() const { return sun ? cycle.meanIrradianceWm2() : 0.0; }
};

struct Setup {
    const TetMesh* mesh = nullptr;
    ThermalProperties properties;
    std::vector<std::string> exposed;
    std::vector<std::vector<int>> componentNodes; // per settings.components
    double emissivity = 0.0, absorptance = 0.0;
};

// One thermal computation on one mesh with one film coefficient and one time step.
struct ThermalRun {
    double peakK = -std::numeric_limits<double>::infinity(), peakTimeS = 0.0;
    int peakNode = -1;
    double lowK = std::numeric_limits<double>::infinity(), lowTimeS = 0.0;
    std::vector<double> componentMaxK, componentMaxTimeS, componentMinK;
    int cycles = 0;
    double lastChangeK = 0.0;
    bool periodic = true;
    // Fields the stress is solved for, with their times in the (last) day.
    std::vector<double> sampleTimeS;
    std::vector<std::vector<double>> samples;
    std::vector<double> hottestField;
    ClimateSeries series;
};

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

// Envelope bookkeeping of one day (or of the cold states).
struct Envelope {
    ThermalRun* run = nullptr;
    const Setup* setup = nullptr;
    double spread = -1.0, unevenTimeS = 0.0;
    std::vector<double> unevenField;
    void reset(ThermalRun& target, const Setup& s) {
        run = &target;
        setup = &s;
        run->peakK = -std::numeric_limits<double>::infinity();
        run->lowK = std::numeric_limits<double>::infinity();
        const std::size_t count = s.componentNodes.size();
        run->componentMaxK.assign(count, -std::numeric_limits<double>::infinity());
        run->componentMaxTimeS.assign(count, 0.0);
        run->componentMinK.assign(count, std::numeric_limits<double>::infinity());
        run->samples.clear();
        run->sampleTimeS.clear();
        run->series = {};
        run->series.componentMaximumK.assign(count, {});
        spread = -1.0;
    }
    void add(double time, const std::vector<double>& T) {
        const auto [lo, hi] = std::minmax_element(T.begin(), T.end());
        if (*hi > run->peakK) {
            run->peakK = *hi, run->peakTimeS = time, run->peakNode = static_cast<int>(hi - T.begin());
            run->hottestField = T;
        }
        if (*lo < run->lowK) run->lowK = *lo, run->lowTimeS = time;
        if (*hi - *lo > spread) spread = *hi - *lo, unevenField = T, unevenTimeS = time;
        for (std::size_t c = 0; c < setup->componentNodes.size(); ++c) {
            const double top = faceMaximum(T, setup->componentNodes[c]);
            if (top > run->componentMaxK[c]) run->componentMaxK[c] = top, run->componentMaxTimeS[c] = time;
            run->componentMinK[c] = std::min(run->componentMinK[c], faceMinimum(T, setup->componentNodes[c]));
        }
    }
    void record(double time, const std::vector<double>& T, const Environment& env, double absoluteTime) {
        auto& s = run->series;
        s.timeS.push_back(time);
        s.airK.push_back(env.airK(absoluteTime));
        s.irradianceWm2.push_back(env.irradiance(absoluteTime));
        const auto [lo, hi] = std::minmax_element(T.begin(), T.end());
        s.partMaximumK.push_back(*hi);
        s.partMinimumK.push_back(*lo);
        for (std::size_t c = 0; c < setup->componentNodes.size(); ++c) s.componentMaximumK[c].push_back(faceMaximum(T, setup->componentNodes[c]));
    }
};

ThermalProblem thermalProblem(const Setup& setup, const Environment& env, const ClimateStudySettings& settings, double h, double airK,
                              double irradiance) {
    ThermalProblem problem;
    problem.mesh = setup.mesh;
    problem.material = setup.properties;
    for (const auto& group : setup.exposed) {
        problem.convection.push_back({group, h, airK + env.riseK});
        problem.radiation.push_back({group, setup.emissivity, airK});
    }
    if (env.sun) problem.sunlight = Sunlight{setup.exposed, env.up, setup.absorptance, irradiance};
    if (env.operating)
        for (const auto& component : settings.components)
            if (component.powerW > 0.0) problem.heatLoads.push_back({component.face, component.powerW});
    return problem;
}

Result<ThermalRun> runHot(const Setup& setup, const Environment& env, const ClimateStudySettings& settings, double h, double stepS) {
    using R = Result<ThermalRun>;
    ThermalRun run;
    const ThermalProblem mean = thermalProblem(setup, env, settings, h, env.meanAirK(), env.meanIrradiance());
    const auto start = solveSteadyThermal(mean);
    if (!start.isOk()) return R::fail(start.error());
    ThermalProblem problem = mean;
    TransientSettings transient;
    transient.stepS = stepS;
    transient.endS = kMaximumCycles * kDaySeconds;
    transient.initialFieldK = start.value().temperatureK;
    transient.schedule.airK = [&](double t) { return env.airK(t); };
    transient.schedule.convectionRiseK = env.riseK;
    if (env.sun) transient.schedule.irradianceWm2 = [&](double t) { return env.irradiance(t); };
    const long perDay = std::lround(kDaySeconds / stepS), perSample = std::lround(kSampleIntervalS / stepS);
    Envelope envelope;
    envelope.reset(run, setup);
    envelope.add(0.0, transient.initialFieldK);
    envelope.record(0.0, transient.initialFieldK, env, 0.0);
    long step = 0;
    double previousPeak = std::numeric_limits<double>::quiet_NaN();
    const auto solved = solveTransientThermal(problem, transient, std::numeric_limits<int>::max(), [&](double t, const std::vector<double>& T) {
        ++step;
        const long day = (step - 1) / perDay;
        const double inDay = t - day * kDaySeconds;
        envelope.add(inDay, T);
        if (step % perSample == 0) {
            run.samples.push_back(T);
            run.sampleTimeS.push_back(inDay);
            envelope.record(inDay, T, env, t);
        }
        if (step % perDay != 0) return true;
        run.cycles = static_cast<int>(step / perDay);
        const double change = std::fabs(run.peakK - previousPeak);
        run.lastChangeK = std::isnan(change) ? 0.0 : change;
        const bool repeats = !std::isnan(change) && change <= kPeriodicToleranceK;
        if ((run.cycles >= kMinimumCycles && repeats) || run.cycles >= kMaximumCycles) {
            run.periodic = repeats;
            return false;
        }
        previousPeak = run.peakK;
        envelope.reset(run, setup);
        envelope.add(0.0, T);
        envelope.record(0.0, T, env, t);
        return true;
    });
    if (!solved.isOk()) return R::fail(solved.error());
    // The hottest and the most uneven instants join the half-hourly samples for the stress.
    run.samples.push_back(run.hottestField);
    run.sampleTimeS.push_back(run.peakTimeS);
    run.samples.push_back(envelope.unevenField);
    run.sampleTimeS.push_back(envelope.unevenTimeS);
    return R::ok(std::move(run));
}

Result<ThermalRun> runCold(const Setup& setup, const Environment& env, const ClimateStudySettings& settings, double h) {
    using R = Result<ThermalRun>;
    ThermalRun run;
    Envelope envelope;
    envelope.reset(run, setup);
    const std::vector<double> soak(setup.mesh->nodes.size(), env.airK(0.0));
    envelope.add(0.0, soak);
    run.samples.push_back(soak);
    run.sampleTimeS.push_back(0.0);
    bool powered = false;
    for (const auto& component : settings.components) powered = powered || component.powerW > 0.0;
    if (env.operating && powered) {
        const auto solved = solveSteadyThermal(thermalProblem(setup, env, settings, h, env.airK(0.0), 0.0));
        if (!solved.isOk()) return R::fail(solved.error());
        envelope.add(1.0, solved.value().temperatureK); // "time" 1: the operating state
        run.samples.push_back(solved.value().temperatureK);
        run.sampleTimeS.push_back(1.0);
    }
    return R::ok(std::move(run));
}

struct StressRun {
    double peakPa = 0.0, timeS = 0.0;
    int node = -1;
    std::vector<double> vonMises;
    std::vector<Vec3> displacement;
};

Result<StressRun> runStress(const TetMesh& mesh, const IsotropicMaterial& material, const std::vector<DisplacementConstraint>& constraints,
                            const std::vector<bool>& excluded, const ThermalRun& thermal, double stressFreeK, bool keepField) {
    using R = Result<StressRun>;
    LinearStaticProblem problem;
    problem.mesh = &mesh;
    problem.material = material;
    problem.constraints = constraints;
    std::vector<std::vector<double>> changes;
    changes.reserve(thermal.samples.size());
    for (const auto& field : thermal.samples) {
        std::vector<double> change(field.size());
        for (std::size_t n = 0; n < field.size(); ++n) change[n] = field[n] - stressFreeK;
        changes.push_back(std::move(change));
    }
    StressRun stress;
    stress.peakPa = -1.0;
    const auto solved = solveThermoelasticSeries(problem, changes, [&](std::size_t index, const LinearStaticSolution& solution) {
        for (std::size_t n = 0; n < solution.nodalVonMises.size(); ++n) {
            if (!excluded.empty() && excluded[n]) continue;
            if (solution.nodalVonMises[n] > stress.peakPa) {
                stress.peakPa = solution.nodalVonMises[n];
                stress.node = static_cast<int>(n);
                stress.timeS = thermal.sampleTimeS[index];
                if (keepField) {
                    stress.vonMises = solution.nodalVonMises;
                    stress.displacement = solution.displacement;
                }
            }
        }
        return true;
    });
    if (!solved.isOk()) return R::fail(solved.error());
    if (stress.node < 0) return R::fail({ErrorCode::InvalidArgument, "зоны исключения покрыли всю деталь"});
    return R::ok(std::move(stress));
}

// Extent of the corner nodes along a direction.
double extentAlong(const TetMesh& mesh, const Vec3& direction) {
    double lo = std::numeric_limits<double>::infinity(), hi = -lo;
    for (const auto& element : mesh.elements)
        for (int k = 0; k < 4; ++k) {
            const double s = dot(mesh.nodes[element[k]], direction);
            lo = std::min(lo, s), hi = std::max(hi, s);
        }
    return hi - lo;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

// A temperature's uncertainty: the mesh (GCI when it converges, the spread of the three meshes when not)
// plus the time step.
double temperatureUncertainty(const ConvergenceEstimate& estimate, double fine, double medium, double coarse, double timeErrorK) {
    const double mesh = estimate.isUsable() ? estimate.uncertaintyAbsolute : std::max({fine, medium, coarse}) - std::min({fine, medium, coarse});
    return mesh + timeErrorK;
}

} // namespace

TemperatureCheck checkTemperature(double valueK, double uncertaintyK, double limitK, bool upper) {
    TemperatureCheck check;
    check.valueK = valueK;
    check.uncertaintyK = uncertaintyK;
    check.limitK = limitK;
    check.upper = upper;
    const double worst = upper ? valueK + uncertaintyK : valueK - uncertaintyK;
    const double best = upper ? valueK - uncertaintyK : valueK + uncertaintyK;
    const bool worstInside = upper ? worst <= limitK : worst >= limitK;
    const bool bestOutside = upper ? best > limitK : best < limitK;
    check.verdict = worstInside ? StrengthVerdict::Pass : bestOutside ? StrengthVerdict::Fail : StrengthVerdict::Warning;
    return check;
}

Result<ClimateStudyResult> runClimateStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                           const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                           const ClimateStudySettings& settings, const StructuralStudyProgress& progress) {
    // --- Settings.
    if (!(settings.coarseElementSizeM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан размер элемента грубой сетки");
    if (!(settings.refinementFactor >= 1.3)) {
        return failure(ErrorCode::InvalidArgument, "коэффициент измельчения должен быть не меньше 1.3 (Celik et al. 2008), иначе разница сеток тонет в шуме");
    }
    const bool hot = settings.environment == ClimateEnvironment::Hot;
    const bool flight = settings.airflow == ClimateAirflow::Flight;
    Environment env;
    env.hot = hot;
    ClimateStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.factorOfSafety = settings.criteria.factorOfSafety;
    result.transient = hot;
    if (hot) {
        env.cycle = hotCycle(settings.hotCategory, settings.hotExposure);
        env.sun = settings.hotExposure == HotExposure::Sun;
        result.conditionSource = env.cycle.source;
    } else {
        const auto cold = coldCondition(settings.coldCategory, settings.coldExposure);
        env.coldAirK = cold.airC + 273.15;
        result.conditionSource = cold.source;
    }
    // Storage and transit: the equipment is off.
    const bool storage = (hot && settings.hotExposure == HotExposure::Induced) || (!hot && settings.coldExposure == ColdExposure::Induced);
    env.operating = settings.operating && !storage;
    if (!(settings.airSpeedMps > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана скорость воздуха");
    if (flight) {
        if (!(settings.altitudeM >= 0.0 && settings.altitudeM <= 11000.0)) return failure(ErrorCode::InvalidArgument, "высота полёта 0…11 км (тропосфера)");
        env.lapseK = kStandardLapseRateKPerM * geopotentialHeightM(settings.altitudeM);
        env.pressurePa = standardPressurePa(settings.altitudeM);
    } else if (hot && env.sun) {
        if (settings.airSpeedMps < kShieldedAirSpeedMinMps || settings.airSpeedMps > kSolarTestAirSpeedMaxMps) {
            return failure(ErrorCode::InvalidArgument, "метод 505.7: обдув 1.5–3.0 м/с (для укрытого от ветра изделия не ниже 0.25 м/с)");
        }
    } else if (settings.airSpeedMps > kTemperatureTestAirSpeedMaxMps) {
        return failure(ErrorCode::InvalidArgument, "методы 501.7/502.7: скорость воздуха у изделия не выше 1.7 м/с");
    }
    if (!(length(settings.upDirection) > 0.0) || !(length(settings.flowDirection) > 0.0)) return failure(ErrorCode::InvalidArgument, "не заданы направления «вверх» и потока");
    env.up = settings.upDirection * (1.0 / length(settings.upDirection));
    const Vec3 flow = settings.flowDirection * (1.0 / length(settings.flowDirection));
    if (!(settings.emissivity > 0.0 && settings.emissivity <= 1.0)) return failure(ErrorCode::InvalidArgument, "не задана излучательная способность покрытия (0 < ε ≤ 1)");
    if (env.sun && !(settings.solarAbsorptance > 0.0 && settings.solarAbsorptance <= 1.0)) {
        return failure(ErrorCode::InvalidArgument, "не задана поглощательная способность покрытия для солнца (0 < α ≤ 1)");
    }
    if (!(settings.stressFreeK > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана температура сборки (без напряжений)");
    if (!(settings.convectionBand >= 0.0 && settings.convectionBand < 1.0)) return failure(ErrorCode::InvalidArgument, "полоса коэффициента теплоотдачи 0…1");
    if (!material.thermalExpansionPerK) return failure(ErrorCode::InvalidArgument, "нет данных: коэффициент теплового расширения материала " + material.displayName);
    bool powered = false;
    for (const auto& component : settings.components) {
        if (component.face.empty()) return failure(ErrorCode::InvalidArgument, "у компонента " + component.name + " не задана грань");
        if (!(component.powerW >= 0.0)) return failure(ErrorCode::InvalidArgument, "мощность компонента не может быть отрицательной");
        powered = powered || (component.powerW > 0.0 && env.operating);
    }
    const bool needsHeat = hot || powered;
    if (needsHeat && !material.thermalConductivityWmK) return failure(ErrorCode::InvalidArgument, "нет данных: теплопроводность материала " + material.displayName);
    if (hot && !material.specificHeatJkgK) return failure(ErrorCode::InvalidArgument, "нет данных: теплоёмкость материала " + material.displayName);
    if (hot) {
        const double perSample = kSampleIntervalS / settings.stepS;
        if (!(settings.stepS > 0.0) || std::fabs(perSample - std::round(perSample)) > 1e-9) {
            return failure(ErrorCode::InvalidArgument, "шаг по времени должен делить 30 минут нацело (60, 120, 300, 600 с…)");
        }
    }
    result.stepS = hot ? settings.stepS : 0.0;
    result.airPeakK = hot ? env.cycle.peakAirK() - env.lapseK : env.airK(0.0);
    result.airLowK = hot ? *std::min_element(env.cycle.airC.begin(), env.cycle.airC.end()) + 273.15 - env.lapseK : env.airK(0.0);
    result.irradiancePeakWm2 = env.sun ? *std::max_element(env.cycle.solarWm2.begin(), env.cycle.solarWm2.end()) : 0.0;
    result.pressurePa = env.pressurePa;

    double hNominal = 0.0, hLow = 0.0, hHigh = 0.0;
    double timeErrorK = 0.0;
    std::vector<ThermalRun> runs; // low edge of h, per level
    std::vector<StressRun> stresses;
    ThermalRun otherEdge;
    StressRun otherEdgeStress;
    TetMesh finestMesh;
    std::vector<int> finestSupportNodes;
    double finestElementSize = 0.0;
    double heightM = 0.0;
    bool correlationOutOfRange = false;
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
        setup.properties = {material.thermalConductivityWmK.value_or(0.0), material.densityKgPerM3, material.specificHeatJkgK.value_or(0.0)};
        setup.emissivity = settings.emissivity;
        setup.absorptance = settings.solarAbsorptance;
        std::set<std::string> covered;
        for (const auto& component : settings.components) {
            if (!requireFace(component.face)) return failure(ErrorCode::NotFound, "нет грани " + component.face + " (компонент " + component.name + ")");
            covered.insert(component.face);
            setup.componentNodes.push_back(mesh.nodesOnGroup(component.face));
        }
        std::vector<DisplacementConstraint> constraints;
        std::vector<int> supportNodes;
        for (const auto& support : supports) {
            if (!requireFace(support.face)) return failure(ErrorCode::NotFound, "нет грани " + support.face + " (опора)");
            covered.insert(support.face);
            DisplacementConstraint constraint;
            constraint.nodes = mesh.nodesOnGroup(support.face);
            for (int c = 0; c < 3; ++c)
                if (support.fixed[c]) constraint.value[c] = 0.0;
            if (support.fixed[0] && support.fixed[1] && support.fixed[2]) supportNodes.insert(supportNodes.end(), constraint.nodes.begin(), constraint.nodes.end());
            constraints.push_back(std::move(constraint));
        }
        if (supports.empty()) constraints = kinematicSupports(mesh);
        for (const auto& [name, faces] : mesh.faceGroups)
            if (!covered.count(name)) setup.exposed.push_back(name);
        if (setup.exposed.empty()) return failure(ErrorCode::InvalidArgument, "все грани детали закрыты компонентами и опорами — теплу некуда уходить");
        std::vector<bool> excluded;
        if (!settings.stressExclusions.empty()) {
            excluded.assign(mesh.nodes.size(), false);
            for (const auto& exclusion : settings.stressExclusions) {
                if (!requireFace(exclusion.face)) return failure(ErrorCode::NotFound, "нет грани " + exclusion.face + " (зона исключения)");
                const auto near = nodesNear(mesh, mesh.nodesOnGroup(exclusion.face), exclusion.distanceM);
                for (std::size_t n = 0; n < near.size(); ++n) excluded[n] = excluded[n] || near[n];
            }
        }

        if (level == 0) {
            // One film coefficient for all three meshes (otherwise the meshes would not solve the same problem).
            result.characteristicLengthM = extentAlong(mesh, flow);
            heightM = extentAlong(mesh, env.up);
            const auto forced = flatPlateForcedConvection(settings.airSpeedMps, result.characteristicLengthM, env.meanAirK(), env.pressurePa);
            hNominal = forced.coefficientWm2K;
            hLow = hNominal * (1.0 - settings.convectionBand);
            hHigh = hNominal * (1.0 + settings.convectionBand);
            result.convectionWm2K = hNominal, result.convectionLowWm2K = hLow, result.convectionHighWm2K = hHigh;
            result.reynolds = forced.reynolds;
            result.laminar = forced.laminar;
            env.riseK = flight ? forced.recoveryRiseK : 0.0;
            result.recoveryRiseK = env.riseK;
            correlationOutOfRange = !forced.inValidityRange;
        }

        if (progress) progress(level, "solve");
        auto thermal = hot ? runHot(setup, env, settings, hLow, settings.stepS) : runCold(setup, env, settings, hLow);
        if (!thermal.isOk()) return failure(thermal.error().code, thermal.error().message);
        ThermalRun run = std::move(thermal.value());
        if (level == 0 && hot) {
            // Time-step error: the coarse mesh again at half the step; Richardson with order 2.
            auto half = runHot(setup, env, settings, hLow, settings.stepS / 2.0);
            if (!half.isOk()) return failure(half.error().code, half.error().message);
            const auto& h2 = half.value();
            timeErrorK = std::max(std::fabs(run.peakK - h2.peakK), std::fabs(run.lowK - h2.lowK));
            for (std::size_t c = 0; c < run.componentMaxK.size(); ++c) {
                timeErrorK = std::max(timeErrorK, std::fabs(run.componentMaxK[c] - h2.componentMaxK[c]));
                timeErrorK = std::max(timeErrorK, std::fabs(run.componentMinK[c] - h2.componentMinK[c]));
            }
            timeErrorK /= 3.0;
        }
        auto stress = runStress(mesh, material, constraints, excluded, run, settings.stressFreeK, level == 2);
        if (!stress.isOk()) return failure(stress.error().code, stress.error().message);

        ClimateLevel record;
        record.maximumElementSizeM = size;
        record.elements = mesh.elements.size();
        record.peakK = run.peakK;
        record.lowK = run.lowK;
        record.peakStressPa = stress.value().peakPa;
        record.cycles = run.cycles;
        if (level > 0 && record.elements <= result.levels.back().elements) {
            return failure(ErrorCode::KernelOperationFailed, "сетка не измельчилась между уровнями — деталь уже упирается в размер своих граней, увеличьте начальный размер");
        }
        result.levels.push_back(record);

        if (level == 2) {
            // The other edge of the band on the finest mesh.
            auto other = hot ? runHot(setup, env, settings, hHigh, settings.stepS) : runCold(setup, env, settings, hHigh);
            if (!other.isOk()) return failure(other.error().code, other.error().message);
            otherEdge = std::move(other.value());
            auto otherStress = runStress(mesh, material, constraints, excluded, otherEdge, settings.stressFreeK, true);
            if (!otherStress.isOk()) return failure(otherStress.error().code, otherStress.error().message);
            otherEdgeStress = std::move(otherStress.value());
            // What the sun does on this mesh at its peak.
            if (env.sun) {
                const auto exposure = solarExposure(mesh, Sunlight{setup.exposed, env.up, settings.solarAbsorptance, result.irradiancePeakWm2});
                if (exposure.isOk()) {
                    result.sunlitProjectedAreaM2 = exposure.value().sunlitProjectedAreaM2;
                    result.shadedAreaM2 = exposure.value().shadedAreaM2;
                    result.absorbedSolarPeakW = exposure.value().absorbedW;
                }
            }
            for (const auto& group : setup.exposed) result.exposedAreaM2 += faceGroupArea(mesh, group);
            for (const auto& group : covered) result.coveredAreaM2 += faceGroupArea(mesh, group);
            finestMesh = std::move(mesh);
            finestSupportNodes = std::move(supportNodes);
            finestElementSize = size;
        }
        runs.push_back(std::move(run));
        stresses.push_back(std::move(stress.value()));
    }

    // --- Convergence.
    const auto& coarse = result.levels[0];
    const auto& medium = result.levels[1];
    const auto& fine = result.levels[2];
    const double r21 = std::cbrt(static_cast<double>(fine.elements) / static_cast<double>(medium.elements));
    const double r32 = std::cbrt(static_cast<double>(medium.elements) / static_cast<double>(coarse.elements));
    // Temperature is the quadratic primary unknown, like the displacement: formal order 3.
    auto temperatureConvergence = [&](double f, double m, double c) { return estimateConvergence(f, m, c, r21, r32, 1.25, kTet10DisplacementOrder); };
    result.peakConvergence = temperatureConvergence(fine.peakK, medium.peakK, coarse.peakK);
    result.lowConvergence = temperatureConvergence(fine.lowK, medium.lowK, coarse.lowK);
    result.timeStepErrorK = timeErrorK;
    const ThermalRun& finest = runs[2];
    result.peakK = std::max(finest.peakK, otherEdge.peakK);
    result.peakTimeS = finest.peakK >= otherEdge.peakK ? finest.peakTimeS : otherEdge.peakTimeS;
    result.lowK = std::min(finest.lowK, otherEdge.lowK);
    result.lowTimeS = finest.lowK <= otherEdge.lowK ? finest.lowTimeS : otherEdge.lowTimeS;
    result.peakOtherEdgeK = otherEdge.peakK;
    result.peakUncertaintyK = temperatureUncertainty(result.peakConvergence, fine.peakK, medium.peakK, coarse.peakK, timeErrorK);
    result.lowUncertaintyK = temperatureUncertainty(result.lowConvergence, fine.lowK, medium.lowK, coarse.lowK, timeErrorK);
    result.hottestPoint = finestMesh.nodes[finest.peakNode];
    result.cycles = finest.cycles;
    result.lastCycleChangeK = finest.lastChangeK;
    result.periodic = true;
    for (const auto& run : runs) result.periodic = result.periodic && run.periodic;
    result.periodic = result.periodic && otherEdge.periodic;
    result.series = finest.series;
    if (hot) {
        const double largestDifference = [&] {
            double d = 0.0;
            for (std::size_t i = 0; i < finest.series.timeS.size(); ++i) d = std::max(d, finest.series.partMaximumK[i] - finest.series.airK[i]);
            return d;
        }();
        if (largestDifference > 0.0 && heightM > 0.0) {
            result.naturalConvectionWm2K = verticalPlateNaturalConvection(heightM, result.airPeakK + largestDifference, result.airPeakK, env.pressurePa);
        }
    }

    // --- Stress: the worse edge of h, with the mesh band of the low edge's three meshes.
    const double stressScale = material.youngsModulusPa * *material.thermalExpansionPerK
                               * std::max(std::fabs(result.peakK - settings.stressFreeK), std::fabs(result.lowK - settings.stressFreeK));
    const bool otherWorse = otherEdgeStress.peakPa > stresses[2].peakPa;
    const StressRun& governing = otherWorse ? otherEdgeStress : stresses[2];
    result.peakStressPa = governing.peakPa;
    result.peakStressTimeS = governing.timeS;
    result.peakStressOtherEdgePa = otherEdgeStress.peakPa;
    result.criticalPoint = finestMesh.nodes[governing.node];
    // A body that expands freely under a uniform or linear field has no stress; what the solver leaves
    // then is round-off (≈1e-9 of E α ΔT), not a stress to converge or assess.
    const bool stressFree = !(result.peakStressPa > 1e-6 * stressScale);
    if (stressFree) {
        result.stressConvergence.behaviour = ConvergenceBehaviour::Converged;
        result.assessment = assessStrength(material, 0.0, result.stressConvergence, settings.criteria);
        result.warnings.push_back("термонапряжений нет: деталь расширяется свободно при однородном (или линейном) поле температуры");
        result.peakStressPa = 0.0;
    } else {
        result.stressConvergence = estimateConvergence(fine.peakStressPa, medium.peakStressPa, coarse.peakStressPa, r21, r32, 1.25, kTet10StressOrder);
        ConvergenceEstimate scaled = result.stressConvergence;
        if (otherWorse) {
            scaled.fine = result.peakStressPa;
            scaled.uncertaintyAbsolute = scaled.gciFineRelative * result.peakStressPa;
        }
        result.assessment = assessStrength(material, result.peakStressPa, scaled, settings.criteria);
    }
    for (const auto& [name, faces] : finestMesh.faceGroups) {
        const auto nodes = finestMesh.nodesOnGroup(name);
        if (std::binary_search(nodes.begin(), nodes.end(), governing.node)) {
            result.criticalFace = name;
            break;
        }
    }

    // --- Verdict.
    StrengthVerdict verdict = result.assessment.verdict;
    for (std::size_t i = 0; i < result.assessment.reasons.size(); ++i) {
        const bool failed = i == 0 && result.assessment.verdict == StrengthVerdict::Fail;
        (failed ? result.failureReasons : result.reasons).push_back("прочность: " + result.assessment.reasons[i]);
    }
    auto report = [&](StrengthVerdict v, const std::string& text) {
        if (v == StrengthVerdict::Fail) result.failureReasons.push_back(text);
        else if (v == StrengthVerdict::Warning) result.reasons.push_back(text);
    };
    auto demote = [&](const std::string& reason) {
        result.reasons.push_back(reason);
        verdict = worse(verdict, StrengthVerdict::Warning);
    };
    if (correlationOutOfRange) demote("корреляция пластины вне области применимости (Re ≤ 1e8, 0.6 ≤ Pr ≤ 60)");
    if (!stressFree && nodesNear(finestMesh, finestSupportNodes, finestElementSize)[governing.node]) {
        demote("максимум термонапряжения у жёсткой заделки — жёсткое крепление без теплового расширения завышает его; смоделируйте крепёж или задайте зону исключения");
    }
    // Oscillating meshes are reported with their spread as the band (Celik et al. 2008) and need no more;
    // a difference that grows with refinement is a singularity (a point source, a knife edge) and does —
    // once it can be told from the time integration's own error (the time step and what is left of the
    // periodic state): below that, meshes that agree to 1e-5 K classify as anything, and it changes nothing.
    const double resolvableK = timeErrorK + result.lastCycleChangeK;
    if (result.peakConvergence.behaviour == ConvergenceBehaviour::Divergent && std::fabs(fine.peakK - medium.peakK) > resolvableK) {
        demote("пиковая температура расходится при измельчении сетки (" + format(std::fabs(fine.peakK - medium.peakK), 4)
               + " K между двумя мелкими сетками) — вероятна особенность (точечный источник, острая кромка)");
    }
    // Material temperature limits.
    // The limit that matters is the one the environment pushes against: the maximum in heat, the minimum in cold.
    if (settings.materialMaximumK) {
        result.materialChecks.push_back(checkTemperature(result.peakK, result.peakUncertaintyK, *settings.materialMaximumK, true));
    } else if (hot) {
        demote("нет данных о допустимой температуре материала «" + material.displayName + "» — задайте её по паспорту материала (максимум " + celsius(result.peakK) + ")");
    }
    if (settings.materialMinimumK) {
        result.materialChecks.push_back(checkTemperature(result.lowK, result.lowUncertaintyK, *settings.materialMinimumK, false));
    } else if (!hot) {
        demote("нет данных о минимальной температуре материала «" + material.displayName + "» — задайте её по паспорту материала (минимум " + celsius(result.lowK) + ")");
    }
    for (const auto& check : result.materialChecks) {
        verdict = worse(verdict, check.verdict);
        report(check.verdict, std::string("материал: ") + (check.upper ? "максимум " : "минимум ") + celsius(check.valueK) + " ± " + format(check.uncertaintyK, 3)
                                  + " K против предела " + celsius(check.limitK));
    }
    // Components.
    for (std::size_t c = 0; c < settings.components.size(); ++c) {
        const auto& component = settings.components[c];
        ClimateComponentResult out;
        out.name = component.name;
        out.face = component.face;
        out.powerW = env.operating ? component.powerW : 0.0;
        out.maximumK = std::max(finest.componentMaxK[c], otherEdge.componentMaxK[c]);
        out.maximumTimeS = finest.componentMaxK[c] >= otherEdge.componentMaxK[c] ? finest.componentMaxTimeS[c] : otherEdge.componentMaxTimeS[c];
        out.minimumK = std::min(finest.componentMinK[c], otherEdge.componentMinK[c]);
        out.maximumConvergence = temperatureConvergence(runs[2].componentMaxK[c], runs[1].componentMaxK[c], runs[0].componentMaxK[c]);
        out.uncertaintyK = temperatureUncertainty(out.maximumConvergence, runs[2].componentMaxK[c], runs[1].componentMaxK[c], runs[0].componentMaxK[c], timeErrorK);
        if (component.maximumK) out.checks.push_back(checkTemperature(out.maximumK, out.uncertaintyK, *component.maximumK, true));
        if (component.minimumK) out.checks.push_back(checkTemperature(out.minimumK, out.uncertaintyK, *component.minimumK, false));
        for (const auto& check : out.checks) {
            out.verdict = worse(out.verdict, check.verdict);
            report(check.verdict, component.name + ": " + (check.upper ? "максимум " : "минимум ") + celsius(check.valueK) + " ± " + format(check.uncertaintyK, 3)
                                      + " K против предела " + celsius(check.limitK));
        }
        if (out.checks.empty()) {
            out.verdict = StrengthVerdict::Warning;
            result.reasons.push_back("нет пределов температуры у компонента «" + component.name + "» — задайте по его паспорту");
        }
        verdict = worse(verdict, out.verdict);
        result.components.push_back(std::move(out));
    }
    result.verdict = verdict;

    // --- Notes that do not change the verdict.
    if (hot && !result.periodic) {
        result.warnings.push_back("за 7 циклов (предел метода 505.7) пик ещё менялся на " + format(result.lastCycleChangeK, 3) + " K за цикл — результат как у испытания, остановленного стандартом");
    }
    if (hot && !stressFree) result.warnings.push_back("прочность взята при комнатной температуре; при " + celsius(result.peakK) + " она ниже — нет данных");
    if (!flight && env.sun && settings.airSpeedMps < kSolarTestAirSpeedMinMps) {
        result.warnings.push_back("обдув ниже 1.5 м/с метод 505.7 допускает только для изделий, укрытых от ветра");
    }
    if (result.naturalConvectionWm2K > 0.0) {
        result.warnings.push_back("естественная конвекция не учтена (консервативно): её оценка " + format(result.naturalConvectionWm2K, 1)
                                  + " Вт/(м²·К) против вынужденной " + format(hLow, 1) + "–" + format(hHigh, 1));
    }
    if (storage && settings.operating) result.warnings.push_back("хранение и перевозка: оборудование выключено");
    if (flight) {
        result.warnings.push_back("полёт: воздух стандарта у земли охлаждён по градиенту МСА (6.5 К/км) до " + format(settings.altitudeM, 0)
                                  + " м; небо и земля не моделируются, излучение уходит к воздуху");
    }
    if (!settings.stressExclusions.empty()) result.warnings.push_back("максимум напряжения взят вне заданных зон исключения");
    if (result.peakConvergence.orderLimitedToFormal || result.stressConvergence.orderLimitedToFormal) {
        result.warnings.push_back("наблюдаемый порядок сходимости выше теоретического — погрешность оценена по теоретическому");
    }

    // --- Surface field of the finest mesh.
    const auto& hottest = finest.peakK >= otherEdge.peakK ? finest.hottestField : otherEdge.hottestField;
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(finestMesh.nodes[meshNode]);
        result.field.displacement.push_back(governing.displacement.empty() ? Vec3{} : governing.displacement[meshNode]);
        result.field.vonMisesPa.push_back(governing.vonMises.empty() ? 0.0 : governing.vonMises[meshNode]);
        result.fieldTemperatureK.push_back(hottest[meshNode]);
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
    return Result<ClimateStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
