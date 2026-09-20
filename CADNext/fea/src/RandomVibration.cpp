#include "cadnext/fea/RandomVibration.hpp"

#include "ResponseBasis.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

Result<RandomVibrationSolution> failure(ErrorCode code, const std::string& message) {
    return Result<RandomVibrationSolution>::fail({code, message});
}

// Log–log interpolation inside the span, zero outside it.
double psdAt(const std::vector<AmplitudePoint>& psd, double frequency) {
    if (frequency < psd.front().frequencyHz || frequency > psd.back().frequencyHz) return 0.0;
    for (std::size_t i = 1; i < psd.size(); ++i) {
        if (frequency <= psd[i].frequencyHz) {
            const auto& a = psd[i - 1];
            const auto& b = psd[i];
            const double slope = std::log(b.amplitude / a.amplitude) / std::log(b.frequencyHz / a.frequencyHz);
            return a.amplitude * std::pow(frequency / a.frequencyHz, slope);
        }
    }
    return psd.back().amplitude;
}

// E[q(σ, σ)] from the 6×6 covariance C of the stress components (row-major, symmetric):
// q = σ₀² + σ₁² + σ₂² − σ₀σ₁ − σ₁σ₂ − σ₂σ₀ + 3(σ₃² + σ₄² + σ₅²).
double vonMisesMeanSquare(const double* C) {
    return C[0] + C[7] + C[14] - C[1] - C[8] - C[2] + 3.0 * (C[21] + C[28] + C[35]);
}

double vonMisesSquare(const double* s) {
    return s[0] * s[0] + s[1] * s[1] + s[2] * s[2] - s[0] * s[1] - s[1] * s[2] - s[2] * s[0] + 3.0 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]);
}

} // namespace

double psdMeanSquare(const std::vector<AmplitudePoint>& psd) {
    double total = 0.0;
    for (std::size_t i = 1; i < psd.size(); ++i) {
        const auto& a = psd[i - 1];
        const auto& b = psd[i];
        const double ratio = b.frequencyHz / a.frequencyHz;
        const double slope = std::log(b.amplitude / a.amplitude) / std::log(ratio);
        total += std::fabs(slope + 1.0) < 1e-12 ? a.amplitude * a.frequencyHz * std::log(ratio)
                                                 : a.amplitude * a.frequencyHz / (slope + 1.0) * (std::pow(ratio, slope + 1.0) - 1.0);
    }
    return total;
}

Result<RandomVibrationSolution> solveRandomVibration(const RandomVibrationProblem& problem, const RandomVibrationSettings& settings) {
    using namespace detail;
    if (!(problem.dampingRatio > 0.0 && problem.dampingRatio < 1.0)) {
        return failure(ErrorCode::InvalidArgument, "задайте коэффициент демпфирования ζ: доля критического, от 0 до 1");
    }
    if (problem.modeCount < 1) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    const auto& psd = problem.accelerationPsd;
    if (psd.size() < 2) return failure(ErrorCode::InvalidArgument, "спектр PSD: нужно не меньше двух точек (от–до)");
    for (std::size_t i = 0; i < psd.size(); ++i) {
        if (!(psd[i].amplitude > 0.0 && psd[i].frequencyHz > 0.0 && std::isfinite(psd[i].amplitude))) {
            return failure(ErrorCode::InvalidArgument, "значения и частоты спектра PSD должны быть положительными");
        }
        if (i > 0 && !(psd[i].frequencyHz > psd[i - 1].frequencyHz)) return failure(ErrorCode::InvalidArgument, "частоты спектра должны возрастать");
    }
    if (settings.frequenciesHz.empty() && settings.backgroundPoints < 2) return failure(ErrorCode::InvalidArgument, "сетка интегрирования: не меньше двух точек");

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
    RandomVibrationSolution solution;
    solution.modal = basis.modal;
    solution.effectiveMassFraction = basis.effectiveMassFraction;
    solution.highestModeHz = basis.highestModeHz;
    solution.inputRmsMs2 = std::sqrt(psdMeanSquare(psd));

    // --- Integration grid over the spectrum's span.
    const double low = psd.front().frequencyHz, high = psd.back().frequencyHz;
    std::vector<double> f = settings.frequenciesHz;
    if (f.empty()) {
        const double ratio = std::log(high / low);
        for (int i = 0; i < settings.backgroundPoints; ++i) f.push_back(low * std::exp(ratio * i / (settings.backgroundPoints - 1)));
        for (const auto& point : psd) f.push_back(point.frequencyHz);
        for (const auto& mode : basis.modal.modes) {
            for (int k = -100; k <= 100; ++k) {
                const double value = mode.frequencyHz * (1.0 + k * problem.dampingRatio / 10.0);
                if (value >= low && value <= high) f.push_back(value);
            }
        }
    }
    std::sort(f.begin(), f.end());
    f.erase(std::unique(f.begin(), f.end(), [](double a, double b) { return std::fabs(a - b) <= 1e-12 * std::max(a, b); }), f.end());
    const int F = static_cast<int>(f.size());
    std::vector<double> weight(F, 0.0), S(F, 0.0);
    for (int i = 0; i < F; ++i) {
        weight[i] = 0.5 * ((i + 1 < F ? f[i + 1] : f[i]) - (i > 0 ? f[i - 1] : f[i]));
        S[i] = psdAt(psd, f[i]);
    }

    // --- Modal covariance A (J × J) and the coefficients kept per frequency for the spectra.
    const int J = basis.J;
    std::vector<double> A(static_cast<std::size_t>(J) * J, 0.0), re(J), im(J);
    std::vector<double> coefficientsRe(static_cast<std::size_t>(J) * F), coefficientsIm(static_cast<std::size_t>(J) * F);
    for (int i = 0; i < F; ++i) {
        basis.coefficients(2.0 * M_PI * f[i], problem.dampingRatio, re.data(), im.data());
        std::copy(re.begin(), re.end(), coefficientsRe.begin() + static_cast<std::ptrdiff_t>(i) * J);
        std::copy(im.begin(), im.end(), coefficientsIm.begin() + static_cast<std::ptrdiff_t>(i) * J);
        const double w = weight[i] * S[i];
        if (w == 0.0) continue;
        for (int j = 0; j < J; ++j)
            for (int k = 0; k < J; ++k) A[static_cast<std::size_t>(j) * J + k] += w * (re[j] * re[k] + im[j] * im[k]);
    }

    // --- Mean squares at every node: W = basis × A, then the 6×6 (or 3×3) covariance per node.
    const int nodeCount = system.nodeCount;
    solution.rmsVonMisesPa.assign(nodeCount, 0.0);
    solution.rmsDisplacementM.assign(nodeCount, 0.0);
    const int nodeBlock = 4096;
    std::vector<double> W;
    for (int node0 = 0; node0 < nodeCount; node0 += nodeBlock) {
        const int nodes = std::min(nodeBlock, nodeCount - node0);
        for (const bool stress : {true, false}) {
            const int width = stress ? 6 : 3;
            const std::size_t rows = static_cast<std::size_t>(width) * nodes;
            const std::size_t lda = stress ? basis.stressRows : basis.motionRows;
            const double* source = stress ? &basis.stressBasis[static_cast<std::size_t>(width) * node0] : &basis.motionBasis[static_cast<std::size_t>(width) * node0];
            W.assign(rows * J, 0.0);
            // A is symmetric, so row- or column-major is the same matrix.
            cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, static_cast<int>(rows), J, J, 1.0, source, static_cast<int>(lda), A.data(), J,
                        0.0, W.data(), static_cast<int>(rows));
            for (int n = 0; n < nodes; ++n) {
                if (stress) {
                    double C[36] = {};
                    for (int k = 0; k < J; ++k) {
                        const double* w = &W[static_cast<std::size_t>(k) * rows + 6 * n];
                        const double* s = source + static_cast<std::size_t>(k) * lda + 6 * n;
                        for (int a = 0; a < 6; ++a)
                            for (int b = 0; b < 6; ++b) C[a * 6 + b] += w[a] * s[b];
                    }
                    solution.rmsVonMisesPa[node0 + n] = std::sqrt(std::max(0.0, vonMisesMeanSquare(C)));
                } else {
                    double total = 0.0;
                    for (int k = 0; k < J; ++k) {
                        const double* w = &W[static_cast<std::size_t>(k) * rows + 3 * n];
                        const double* u = source + static_cast<std::size_t>(k) * lda + 3 * n;
                        total += w[0] * u[0] + w[1] * u[1] + w[2] * u[2];
                    }
                    solution.rmsDisplacementM[node0 + n] = std::sqrt(std::max(0.0, total));
                }
            }
        }
    }
    for (int node = 0; node < nodeCount; ++node) {
        if (system.counts(node) && solution.rmsVonMisesPa[node] > solution.maxRmsVonMisesPa) {
            solution.maxRmsVonMisesPa = solution.rmsVonMisesPa[node];
            solution.maxRmsVonMisesNode = node;
        }
        if (solution.rmsDisplacementM[node] > solution.maxRmsDisplacementM) {
            solution.maxRmsDisplacementM = solution.rmsDisplacementM[node];
            solution.maxRmsDisplacementNode = node;
        }
    }

    // --- Spectra on the grid: input, probe, and the critical node's von Mises integrand.
    solution.frequencyHz = f;
    solution.inputPsd = S;
    solution.criticalStressPsd.assign(F, 0.0);
    if (!system.probeWeights.empty()) solution.probeAccelerationPsd.assign(F, 0.0);
    double probeDisplacement = 0.0, probeAcceleration = 0.0, m0 = 0.0, m2 = 0.0;
    const int critical = solution.maxRmsVonMisesNode;
    for (int i = 0; i < F; ++i) {
        const double* cr = &coefficientsRe[static_cast<std::size_t>(i) * J];
        const double* ci = &coefficientsIm[static_cast<std::size_t>(i) * J];
        const double omega2 = std::pow(2.0 * M_PI * f[i], 2.0);
        if (!system.probeWeights.empty()) {
            Vec3 pr, pi;
            for (int j = 0; j < J; ++j) {
                pr += basis.probeBasis[j] * cr[j];
                pi += basis.probeBasis[j] * ci[j];
            }
            probeDisplacement += weight[i] * S[i] * (dot(pr, pr) + dot(pi, pi));
            const Vec3 ar = system.direction - pr * omega2, ai = pi * (-omega2);
            solution.probeAccelerationPsd[i] = (dot(ar, ar) + dot(ai, ai)) * S[i];
            probeAcceleration += weight[i] * solution.probeAccelerationPsd[i];
        }
        if (critical >= 0) {
            double sr[6] = {}, si[6] = {};
            for (int j = 0; j < J; ++j) {
                const double* s = &basis.stressBasis[static_cast<std::size_t>(j) * basis.stressRows + 6 * static_cast<std::size_t>(critical)];
                for (int c = 0; c < 6; ++c) {
                    sr[c] += s[c] * cr[j];
                    si[c] += s[c] * ci[j];
                }
            }
            solution.criticalStressPsd[i] = (vonMisesSquare(sr) + vonMisesSquare(si)) * S[i];
            m0 += weight[i] * solution.criticalStressPsd[i];
            m2 += weight[i] * f[i] * f[i] * solution.criticalStressPsd[i];
        }
    }
    solution.probeRmsDisplacementM = std::sqrt(probeDisplacement);
    solution.probeRmsAccelerationMs2 = std::sqrt(probeAcceleration);
    solution.criticalApparentFrequencyHz = m0 > 0.0 ? std::sqrt(m2 / m0) : 0.0;
    return Result<RandomVibrationSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
