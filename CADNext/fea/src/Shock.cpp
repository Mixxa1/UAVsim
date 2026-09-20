#include "cadnext/fea/Shock.hpp"

#include "ResponseBasis.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

Result<ShockSolution> failure(ErrorCode code, const std::string& message) {
    return Result<ShockSolution>::fail({code, message});
}

double vonMisesOf(const double* s) {
    return std::sqrt(std::max(0.0, s[0] * s[0] + s[1] * s[1] + s[2] * s[2] - s[0] * s[1] - s[1] * s[2] - s[2] * s[0]
                                       + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5])));
}

} // namespace

double ShockPulse::at(double t) const {
    if (t < 0.0) return 0.0;
    switch (shape) {
    case PulseShape::HalfSine:
        return t <= durationS ? peakMs2 * std::sin(M_PI * t / durationS) : 0.0;
    case PulseShape::TerminalPeakSawtooth:
        return t <= durationS ? peakMs2 * t / durationS : 0.0;
    case PulseShape::Trapezoid:
        if (t > durationS) return 0.0;
        if (t < riseS) return peakMs2 * t / riseS;
        if (t > durationS - fallS) return peakMs2 * (durationS - t) / fallS;
        return peakMs2;
    case PulseShape::TimeHistory:
        if (history.empty() || t > history.back().first) return 0.0;
        for (std::size_t i = 1; i < history.size(); ++i) {
            if (t <= history[i].first) {
                const double w = (t - history[i - 1].first) / (history[i].first - history[i - 1].first);
                return history[i - 1].second + w * (history[i].second - history[i - 1].second);
            }
        }
        return 0.0;
    }
    return 0.0;
}

double ShockPulse::end() const {
    return shape == PulseShape::TimeHistory ? (history.empty() ? 0.0 : history.back().first) : durationS;
}

void integrateModalResponse(double omega, double zeta, double step, const std::vector<double>& force, std::vector<double>& q,
                            std::vector<double>& qDot) {
    const std::size_t n = force.size();
    q.assign(n, 0.0);
    qDot.assign(n, 0.0);
    if (n == 0) return;
    // Exact over each step for a force linear in the step, f = a + bτ: the particular solution
    // q_p = a/ω² − 2ζb/ω³ + bτ/ω² (substitution checks it), plus the free damped motion of the rest.
    const double w2 = omega * omega;
    const double wd = omega * std::sqrt(1.0 - zeta * zeta);
    const double decay = std::exp(-zeta * omega * step);
    const double c = std::cos(wd * step), s = std::sin(wd * step);
    double position = 0.0, velocity = 0.0;
    for (std::size_t i = 0; i + 1 < n; ++i) {
        const double a = force[i];
        const double b = (force[i + 1] - force[i]) / step;
        const double p0 = a / w2 - 2.0 * zeta * b / (w2 * omega);
        const double v0 = b / w2;
        const double h = position - p0, hd = velocity - v0;
        const double hNext = decay * (h * c + (hd + zeta * omega * h) / wd * s);
        const double hdNext = decay * (hd * c - (w2 * h + zeta * omega * hd) / wd * s);
        position = hNext + p0 + b * step / w2;
        velocity = hdNext + v0;
        q[i + 1] = position;
        qDot[i + 1] = velocity;
    }
}

std::vector<double> shockResponseSpectrum(const std::vector<double>& baseAcceleration, double step, const std::vector<double>& frequenciesHz,
                                          double zeta) {
    std::vector<double> spectrum;
    std::vector<double> force(baseAcceleration.size()), z, zDot;
    for (std::size_t i = 0; i < force.size(); ++i) force[i] = -baseAcceleration[i];
    for (double f : frequenciesHz) {
        const double omega = 2.0 * M_PI * f;
        integrateModalResponse(omega, zeta, step, force, z, zDot);
        // Absolute acceleration of the mass: −(2ζω ż + ω² z).
        double peak = 0.0;
        for (std::size_t i = 0; i < z.size(); ++i) peak = std::max(peak, std::fabs(2.0 * zeta * omega * zDot[i] + omega * omega * z[i]));
        spectrum.push_back(peak);
    }
    return spectrum;
}

Result<ShockSolution> solveShock(const ShockProblem& problem, const ShockSettings& settings) {
    using namespace detail;
    if (!(problem.dampingRatio > 0.0 && problem.dampingRatio < 1.0)) {
        return failure(ErrorCode::InvalidArgument, "задайте коэффициент демпфирования ζ: доля критического, от 0 до 1");
    }
    if (problem.modeCount < 1) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    const auto& pulse = problem.pulse;
    if (pulse.shape == PulseShape::TimeHistory) {
        if (pulse.history.size() < 2) return failure(ErrorCode::InvalidArgument, "запись ускорения: нужно не меньше двух точек");
        for (std::size_t i = 0; i < pulse.history.size(); ++i) {
            if (!(pulse.history[i].first >= 0.0) || !std::isfinite(pulse.history[i].second)) {
                return failure(ErrorCode::InvalidArgument, "запись ускорения: время ≥ 0, конечные значения");
            }
            if (i > 0 && !(pulse.history[i].first > pulse.history[i - 1].first)) return failure(ErrorCode::InvalidArgument, "запись ускорения: время должно возрастать");
        }
    } else {
        if (!(pulse.peakMs2 > 0.0 && pulse.durationS > 0.0)) return failure(ErrorCode::InvalidArgument, "импульс: амплитуда и длительность должны быть положительными");
        if (pulse.shape == PulseShape::Trapezoid && !(pulse.riseS > 0.0 && pulse.fallS > 0.0 && pulse.riseS + pulse.fallS <= pulse.durationS)) {
            return failure(ErrorCode::InvalidArgument, "трапеция: фронт и спад положительные и вместе не длиннее импульса");
        }
    }
    if (!(settings.residualPeriods > 0.0) || settings.samplesPerPeriod < 8) return failure(ErrorCode::InvalidArgument, "окно отклика и шаг выборки");

    HarmonicProblem shared;
    shared.mesh = problem.mesh;
    shared.material = problem.material;
    shared.constraints = problem.constraints;
    shared.attachedMasses = problem.attachedMasses;
    shared.excitation.kind = HarmonicExcitationKind::BaseAcceleration;
    shared.excitation.direction = problem.direction;
    shared.dampingRatio = problem.dampingRatio;
    shared.modeCount = problem.modeCount;
    shared.probeFaceGroup = problem.probeFaceGroup;
    shared.stressExcluded = problem.stressExcluded;
    ResponseSystem system;
    if (const auto message = buildResponseSystem(shared, system)) {
        return failure(message->find("нет группы") == 0 ? ErrorCode::NotFound : ErrorCode::InvalidArgument, *message);
    }
    ResponseBasis basis;
    if (const auto message = buildResponseBasis(system, shared, settings.modal, settings.staticCorrection, basis)) {
        return failure(ErrorCode::KernelOperationFailed, *message);
    }
    ShockSolution solution;
    solution.modal = basis.modal;
    solution.effectiveMassFraction = basis.effectiveMassFraction;
    solution.highestModeHz = basis.highestModeHz;

    // --- Time grid: the pulse resolved, the highest mode's peaks caught, the residual motion covered.
    const auto& modes = basis.modal.modes;
    const double firstPeriod = 1.0 / modes.front().frequencyHz;
    const double lastPeriod = 1.0 / modes.back().frequencyHz;
    double step = lastPeriod / settings.samplesPerPeriod;
    if (pulse.shape != PulseShape::TimeHistory) step = std::min(step, pulse.durationS / 200.0);
    else
        for (std::size_t i = 1; i < pulse.history.size(); ++i) step = std::min(step, (pulse.history[i].first - pulse.history[i - 1].first) / 4.0);
    const double window = pulse.end() + settings.residualPeriods * firstPeriod;
    const std::size_t T = static_cast<std::size_t>(std::ceil(window / step)) + 1;
    if (T > 2000000) return failure(ErrorCode::InvalidArgument, "слишком много шагов по времени — сократите число мод или окно отклика");
    solution.timeS.resize(T);
    solution.baseAccelerationMs2.resize(T);
    for (std::size_t i = 0; i < T; ++i) {
        solution.timeS[i] = step * static_cast<double>(i);
        solution.baseAccelerationMs2[i] = pulse.at(solution.timeS[i]);
    }

    // --- Modal responses and the coefficient of every basis vector at every instant.
    const int J = basis.J, R = static_cast<int>(modes.size());
    std::vector<double> coefficients(static_cast<std::size_t>(J) * T, 0.0), force(T), q, qDot;
    std::vector<std::vector<double>> modalAcceleration(R);
    for (int r = 0; r < R; ++r) {
        const double omega = std::sqrt(modes[r].eigenvalue);
        for (std::size_t i = 0; i < T; ++i) force[i] = basis.modalLoad[r] * solution.baseAccelerationMs2[i];
        integrateModalResponse(omega, problem.dampingRatio, step, force, q, qDot);
        modalAcceleration[r].resize(T);
        for (std::size_t i = 0; i < T; ++i) {
            coefficients[i * J + basis.offset + r] = settings.staticCorrection ? q[i] - basis.modalLoad[r] * solution.baseAccelerationMs2[i] / (omega * omega) : q[i];
            modalAcceleration[r][i] = force[i] - 2.0 * problem.dampingRatio * omega * qDot[i] - omega * omega * q[i];
        }
    }
    if (settings.staticCorrection)
        for (std::size_t i = 0; i < T; ++i) coefficients[i * J] = solution.baseAccelerationMs2[i];

    // --- Probe: relative displacement and absolute acceleration along the excitation.
    const Vec3& d = system.direction;
    if (!system.probeWeights.empty()) {
        solution.probeAccelerationMs2.resize(T);
        solution.probeDisplacementM.resize(T);
        for (std::size_t i = 0; i < T; ++i) {
            double displacement = 0.0, acceleration = solution.baseAccelerationMs2[i];
            for (int j = 0; j < J; ++j) displacement += dot(basis.probeBasis[j], d) * coefficients[i * J + j];
            for (int r = 0; r < R; ++r) acceleration += dot(basis.probeBasis[basis.offset + r], d) * modalAcceleration[r][i];
            solution.probeDisplacementM[i] = displacement;
            solution.probeAccelerationMs2[i] = acceleration;
        }
    }

    // --- Stress at every node and instant: basis × coefficients in blocks, the maximum kept.
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

    // --- The field at the worst instant.
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
    return Result<ShockSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
