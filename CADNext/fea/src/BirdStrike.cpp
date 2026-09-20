#include "cadnext/fea/BirdStrike.hpp"

#include "cadnext/fea/Shock.hpp" // integrateModalResponse

#include "ResponseBasis.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

using detail::ResponseBasis;
using detail::ResponseSystem;

namespace {

Result<BirdStrikeSolution> failure(ErrorCode code, const std::string& message) {
    return Result<BirdStrikeSolution>::fail({code, message});
}

double vonMisesOf(const double* s) {
    const double a = s[0] - s[1], b = s[1] - s[2], c = s[2] - s[0];
    return std::sqrt(0.5 * (a * a + b * b + c * c) + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]));
}

} // namespace

double BirdImpact::pressureAt(double timeS) const {
    if (timeS < 0.0 || timeS > totalDurationS) return 0.0;
    if (timeS <= shockDurationS) return hugoniotPressurePa;
    if (timeS <= shockDurationS + decayDurationS) {
        const double weight = decayDurationS > 0.0 ? (timeS - shockDurationS) / decayDurationS : 1.0;
        return hugoniotPressurePa + weight * (steadyPressurePa - hugoniotPressurePa);
    }
    return steadyPressurePa;
}

Result<BirdImpact> birdImpact(const BirdModel& bird) {
    using R = Result<BirdImpact>;
    if (!(bird.massKg > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана масса птицы"});
    if (!(bird.densityKgM3 > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана плотность птицы"});
    if (!(bird.speedMps > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана скорость удара"});
    if (!(bird.lengthToDiameter > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задано удлинение тела птицы"});
    if (!(bird.obliquityRad > 0.0) || bird.obliquityRad > M_PI_2 + 1e-12) {
        return R::fail({ErrorCode::InvalidArgument, "угол встречи: от нуля (скользящий) до 90° (в лоб)"});
    }
    if (!(bird.shockSpeedMps > 0.0)) return R::fail({ErrorCode::InvalidArgument, "не задана скорость звука в теле птицы"});

    BirdImpact impact;
    // A right cylinder of the given slenderness: V = πd²L/4 with L = (L/d)·d.
    const double volume = bird.massKg / bird.densityKgM3;
    impact.diameterM = std::cbrt(4.0 * volume / (M_PI * bird.lengthToDiameter));
    impact.lengthM = bird.lengthToDiameter * impact.diameterM;
    impact.areaM2 = M_PI * impact.diameterM * impact.diameterM / 4.0;
    impact.normalSpeedMps = bird.speedMps * std::sin(bird.obliquityRad);
    const double u = impact.normalSpeedMps;
    impact.hugoniotPressurePa = bird.densityKgM3 * (bird.shockSpeedMps + bird.shockSlope * u) * u;
    impact.steadyPressurePa = 0.5 * bird.densityKgM3 * u * u;
    impact.normalMomentumNs = bird.massKg * u;
    impact.energyJ = 0.5 * bird.massKg * bird.speedMps * bird.speedMps;
    impact.geometricDurationS = impact.lengthM / std::max(u, 1e-12);

    // The shock stands until the release wave from the rim reaches the axis, and the decay is taken
    // as long again — the usual reading of the measured traces.
    impact.shockDurationS = 0.5 * impact.diameterM / (bird.shockSpeedMps + bird.shockSlope * u);
    impact.decayDurationS = impact.shockDurationS;
    // The steady phase carries whatever momentum the first two did not: that is what makes the total
    // exact rather than assumed.
    const double shockImpulse = impact.areaM2 * impact.hugoniotPressurePa * impact.shockDurationS;
    const double decayImpulse = impact.areaM2 * 0.5 * (impact.hugoniotPressurePa + impact.steadyPressurePa) * impact.decayDurationS;
    const double remaining = impact.normalMomentumNs - shockImpulse - decayImpulse;
    if (!(impact.steadyPressurePa > 0.0)) return R::fail({ErrorCode::InvalidArgument, "нулевое давление торможения"});
    impact.steadyDurationS = remaining / (impact.areaM2 * impact.steadyPressurePa);
    if (impact.steadyDurationS < 0.0) {
        impact.warnings.push_back("ударная фаза уносит больше импульса, чем есть у птицы: при такой скорости форма импульса не описывает удар");
        impact.steadyDurationS = 0.0;
    }
    impact.totalDurationS = impact.shockDurationS + impact.decayDurationS + impact.steadyDurationS;
    const double ratio = impact.geometricDurationS > 0.0 ? impact.totalDurationS / impact.geometricDurationS : 0.0;
    if (ratio < 0.5 || ratio > 2.0) {
        impact.warnings.push_back("длительность из импульса отличается от L/u в " + std::to_string(ratio) + " раза: форма импульса подогнана под импульс, "
                                                                                                            "но не под геометрию тела");
    }
    return R::ok(std::move(impact));
}

Result<BirdStrikeSolution> solveBirdStrike(const BirdStrikeProblem& problem, const BirdStrikeSettings& settings) {
    if (problem.mesh == nullptr) return failure(ErrorCode::InvalidArgument, "нет сетки");
    if (problem.impactFaceGroup.empty()) return failure(ErrorCode::InvalidArgument, "не задана грань удара");
    if (!(problem.dampingRatio >= 0.0)) return failure(ErrorCode::InvalidArgument, "не задано модальное демпфирование");
    if (problem.modeCount <= 0) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    if (!(settings.residualPeriods > 0.0) || settings.samplesPerPeriod < 8) return failure(ErrorCode::InvalidArgument, "окно отклика и шаг выборки");

    BirdStrikeSolution solution;
    // The load in time: the bird's own, or the one given.
    std::vector<std::pair<double, double>> history = problem.forceHistory;
    double duration = 0.0;
    if (history.empty()) {
        const auto impact = birdImpact(problem.bird);
        if (!impact.isOk()) return failure(impact.error().code, impact.error().message);
        solution.impact = impact.value();
        duration = solution.impact.totalDurationS;
        if (!(duration > 0.0)) return failure(ErrorCode::InvalidArgument, "нулевая длительность удара");
    } else {
        for (std::size_t i = 0; i < history.size(); ++i) {
            if (history[i].first < 0.0) return failure(ErrorCode::InvalidArgument, "запись силы: время не может быть отрицательным");
            if (i > 0 && !(history[i].first > history[i - 1].first)) return failure(ErrorCode::InvalidArgument, "запись силы: время должно возрастать");
        }
        duration = history.back().first;
        if (!(duration > 0.0)) return failure(ErrorCode::InvalidArgument, "запись силы пуста");
    }

    HarmonicProblem shared;
    shared.mesh = problem.mesh;
    shared.material = problem.material;
    shared.constraints = problem.constraints;
    shared.attachedMasses = problem.attachedMasses;
    shared.excitation.kind = HarmonicExcitationKind::FaceForce;
    shared.excitation.direction = problem.direction;
    shared.excitation.faceGroup = problem.impactFaceGroup;
    shared.dampingRatio = problem.dampingRatio;
    shared.modeCount = problem.modeCount;
    shared.stressExcluded = problem.stressExcluded;
    ResponseSystem system;
    if (const auto message = detail::buildResponseSystem(shared, system)) {
        return failure(message->find("нет группы") == 0 ? ErrorCode::NotFound : ErrorCode::InvalidArgument, *message);
    }
    ResponseBasis basis;
    if (const auto message = detail::buildResponseBasis(system, shared, settings.modal, settings.staticCorrection, basis)) {
        return failure(ErrorCode::KernelOperationFailed, *message);
    }
    solution.modal = basis.modal;
    solution.highestModeHz = basis.highestModeHz;

    const auto& modes = basis.modal.modes;
    const double firstPeriod = 1.0 / modes.front().frequencyHz;
    const double lastPeriod = 1.0 / modes.back().frequencyHz;
    double step = std::min(lastPeriod / settings.samplesPerPeriod, duration / 200.0);
    if (!history.empty()) {
        for (std::size_t i = 1; i < history.size(); ++i) step = std::min(step, (history[i].first - history[i - 1].first) / 4.0);
    } else {
        // The bird's load is piecewise linear with two kinks at the ends of the shock phase, and the
        // grid is uniform: the trapezoidal impulse loses (Δslope)·step²/8 at each kink. At the plain
        // step above that is a percent of the bird's momentum — the very thing the shape was built
        // to carry exactly. An eighth of the shock phase puts it below a hundredth of a percent.
        step = std::min(step, solution.impact.shockDurationS / 8.0);
    }
    const double window = duration + settings.residualPeriods * firstPeriod;
    const std::size_t T = static_cast<std::size_t>(std::ceil(window / step)) + 1;
    if (T > 2000000) return failure(ErrorCode::InvalidArgument, "слишком много шагов по времени — сократите число мод или окно отклика");

    auto forceAt = [&](double t) {
        if (history.empty()) return solution.impact.forceAt(t);
        if (t <= history.front().first) return history.front().second * (t < 0.0 ? 0.0 : 1.0);
        if (t >= history.back().first) return 0.0;
        for (std::size_t i = 1; i < history.size(); ++i) {
            if (t <= history[i].first) {
                const double span = history[i].first - history[i - 1].first;
                const double weight = span > 0.0 ? (t - history[i - 1].first) / span : 0.0;
                return history[i - 1].second + weight * (history[i].second - history[i - 1].second);
            }
        }
        return 0.0;
    };
    solution.timeS.resize(T);
    solution.forceN.resize(T);
    for (std::size_t i = 0; i < T; ++i) {
        solution.timeS[i] = step * static_cast<double>(i);
        solution.forceN[i] = forceAt(solution.timeS[i]);
        solution.peakForceN = std::max(solution.peakForceN, std::fabs(solution.forceN[i]));
    }
    for (std::size_t i = 1; i < T; ++i) solution.impulseNs += 0.5 * (solution.forceN[i] + solution.forceN[i - 1]) * step;
    solution.areaM2 = history.empty() ? solution.impact.areaM2 : 0.0;

    // Modal responses, then the coefficient of every basis vector at every instant.
    const int J = basis.J, R = static_cast<int>(modes.size());
    std::vector<double> coefficients(static_cast<std::size_t>(J) * T, 0.0), force(T), q, qDot;
    for (int r = 0; r < R; ++r) {
        const double omega = std::sqrt(modes[r].eigenvalue);
        for (std::size_t i = 0; i < T; ++i) force[i] = basis.modalLoad[r] * solution.forceN[i];
        integrateModalResponse(omega, problem.dampingRatio, step, force, q, qDot);
        for (std::size_t i = 0; i < T; ++i) {
            coefficients[i * J + basis.offset + r] = settings.staticCorrection ? q[i] - basis.modalLoad[r] * solution.forceN[i] / (omega * omega) : q[i];
        }
    }
    if (settings.staticCorrection)
        for (std::size_t i = 0; i < T; ++i) coefficients[i * J] = solution.forceN[i];

    const int nodeCount = system.nodeCount;
    solution.maxVonMisesPa.assign(T, 0.0);
    std::vector<int> maxNode(T, -1);
    const int nodeBlock = 1024, timeBlock = 256;
    std::vector<double> product;
    for (int node0 = 0; node0 < nodeCount; node0 += nodeBlock) {
        const int nodes = std::min(nodeBlock, nodeCount - node0);
        const std::size_t rows = 6 * static_cast<std::size_t>(nodes);
        for (std::size_t t0 = 0; t0 < T; t0 += timeBlock) {
            const int count = static_cast<int>(std::min<std::size_t>(timeBlock, T - t0));
            product.assign(rows * count, 0.0);
            cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, static_cast<int>(rows), count, J, 1.0,
                        &basis.stressBasis[6 * static_cast<std::size_t>(node0)], static_cast<int>(basis.stressRows), &coefficients[t0 * J], J, 0.0,
                        product.data(), static_cast<int>(rows));
            for (int k = 0; k < count; ++k) {
                const double* column = &product[static_cast<std::size_t>(k) * rows];
                for (int n = 0; n < nodes; ++n) {
                    if (!system.counts(node0 + n)) continue;
                    const double vm = vonMisesOf(column + 6 * n);
                    if (vm > solution.maxVonMisesPa[t0 + k]) {
                        solution.maxVonMisesPa[t0 + k] = vm;
                        maxNode[t0 + k] = node0 + n;
                    }
                }
            }
        }
    }
    for (std::size_t i = 1; i < T; ++i)
        if (solution.maxVonMisesPa[i] > solution.maxVonMisesPa[solution.worstSample]) solution.worstSample = i;
    solution.peakVonMisesPa = solution.maxVonMisesPa[solution.worstSample];
    solution.peakNode = maxNode[solution.worstSample];

    {
        const double* c = &coefficients[solution.worstSample * J];
        solution.worstVonMisesPa.assign(nodeCount, 0.0);
        solution.worstDisplacement.assign(nodeCount, Vec3{});
        for (int node = 0; node < nodeCount; ++node) {
            double s[6] = {};
            for (int j = 0; j < J; ++j) {
                for (int k = 0; k < 6; ++k) s[k] += basis.stressBasis[j * basis.stressRows + 6 * node + k] * c[j];
                for (int k = 0; k < 3; ++k) solution.worstDisplacement[node][k] += basis.motionBasis[j * basis.motionRows + 3 * node + k] * c[j];
            }
            solution.worstVonMisesPa[node] = vonMisesOf(s);
        }
    }
    return Result<BirdStrikeSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
