#include "cadnext/fea/Harmonic.hpp"

#include "cadnext/fea/TetElement.hpp"

#include "ResponseBasis.hpp"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <complex>
#include <numeric>
#include <sstream>

namespace cadnext::fea {

namespace {

Result<HarmonicSolution> failure(ErrorCode code, const std::string& message) {
    return Result<HarmonicSolution>::fail({code, message});
}

// Largest eigenvalue of [[a, b], [b, c]].
double largestEigenvalue(double a, double b, double c) {
    const double half = 0.5 * (a - c);
    return 0.5 * (a + c) + std::sqrt(half * half + b * b);
}

// The bilinear form whose diagonal is von Mises squared: q(σ) = ½Σ(σ_i − σ_j)² + 3Σ τ².
double vonMisesForm(const double* s, const double* t) {
    const double s01 = s[0] - s[1], s12 = s[1] - s[2], s20 = s[2] - s[0];
    const double t01 = t[0] - t[1], t12 = t[1] - t[2], t20 = t[2] - t[0];
    return 0.5 * (s01 * t01 + s12 * t12 + s20 * t20) + 3.0 * (s[3] * t[3] + s[4] * t[4] + s[5] * t[5]);
}

double peakVonMisesRaw(const double* real, const double* imaginary) {
    // σ(θ) = σ_R cos θ − σ_I sin θ, so q(σ(θ)) = [c s] [[q_RR, −q_RI], [−q_RI, q_II]] [c s]ᵀ.
    const double rr = vonMisesForm(real, real), ri = vonMisesForm(real, imaginary), ii = vonMisesForm(imaginary, imaginary);
    return std::sqrt(std::max(0.0, largestEigenvalue(rr, -ri, ii)));
}

double peakMagnitudeRaw(const double* real, const double* imaginary) {
    const double rr = real[0] * real[0] + real[1] * real[1] + real[2] * real[2];
    const double ri = real[0] * imaginary[0] + real[1] * imaginary[1] + real[2] * imaginary[2];
    const double ii = imaginary[0] * imaginary[0] + imaginary[1] * imaginary[1] + imaginary[2] * imaginary[2];
    return std::sqrt(std::max(0.0, largestEigenvalue(rr, -ri, ii)));
}

// Log–log interpolation of a profile, constant beyond its ends.
double profileAt(const std::vector<AmplitudePoint>& profile, double frequency) {
    if (profile.size() == 1 || frequency <= profile.front().frequencyHz) return profile.front().amplitude;
    if (frequency >= profile.back().frequencyHz) return profile.back().amplitude;
    for (std::size_t i = 1; i < profile.size(); ++i) {
        if (frequency <= profile[i].frequencyHz) {
            const auto& a = profile[i - 1];
            const auto& b = profile[i];
            const double slope = std::log(b.amplitude / a.amplitude) / std::log(b.frequencyHz / a.frequencyHz);
            return a.amplitude * std::pow(frequency / a.frequencyHz, slope);
        }
    }
    return profile.back().amplitude;
}

} // namespace

double peakVonMises(const Voigt& real, const Voigt& imaginary) { return peakVonMisesRaw(real.data(), imaginary.data()); }

double peakMagnitude(const Vec3& real, const Vec3& imaginary) {
    const double r[3] = {real.x, real.y, real.z}, i[3] = {imaginary.x, imaginary.y, imaginary.z};
    return peakMagnitudeRaw(r, i);
}

Result<HarmonicSolution> solveHarmonic(const HarmonicProblem& problem, const HarmonicSettings& settings) {
    using namespace detail;
    if (problem.mesh == nullptr || problem.mesh->elements.empty()) return failure(ErrorCode::InvalidArgument, "пустая сетка");
    if (!problem.material.isValid()) return failure(ErrorCode::InvalidArgument, "некорректный материал: " + problem.material.id);
    const bool direct = settings.method == HarmonicMethod::Direct;
    if (direct) {
        if (problem.dampingRatio != 0.0) return failure(ErrorCode::InvalidArgument, "прямое решение — только без демпфирования (проверочный путь)");
    } else {
        if (!(problem.dampingRatio > 0.0 && problem.dampingRatio < 1.0)) {
            return failure(ErrorCode::InvalidArgument, "задайте коэффициент демпфирования ζ: доля критического, от 0 до 1");
        }
        if (problem.modeCount < 1) return failure(ErrorCode::InvalidArgument, "не задано число мод");
    }
    if (settings.frequenciesHz.empty()) {
        if (!(problem.minimumHz > 0.0 && problem.maximumHz > problem.minimumHz && std::isfinite(problem.maximumHz))) {
            return failure(ErrorCode::InvalidArgument, "диапазон частот: 0 < от < до");
        }
        if (settings.sweepPoints < 2) return failure(ErrorCode::InvalidArgument, "в развёртке нужно не меньше двух точек");
    } else {
        for (double f : settings.frequenciesHz)
            if (!(f > 0.0 && std::isfinite(f))) return failure(ErrorCode::InvalidArgument, "частоты должны быть положительными");
    }
    const auto& excitation = problem.excitation;
    const bool base = excitation.kind == HarmonicExcitationKind::BaseAcceleration;
    const bool imbalance = !base && excitation.imbalanceKgM > 0.0;
    if (imbalance && !excitation.amplitude.empty()) {
        return failure(ErrorCode::InvalidArgument, "дисбаланс и амплитуда силы — взаимоисключающие");
    }
    if (!imbalance) {
        if (excitation.amplitude.empty()) return failure(ErrorCode::InvalidArgument, "не задана амплитуда возбуждения");
        for (std::size_t i = 0; i < excitation.amplitude.size(); ++i) {
            const auto& point = excitation.amplitude[i];
            if (!(point.amplitude > 0.0 && point.frequencyHz > 0.0 && std::isfinite(point.amplitude))) {
                return failure(ErrorCode::InvalidArgument, "амплитуды и частоты профиля должны быть положительными");
            }
            if (i > 0 && !(point.frequencyHz > excitation.amplitude[i - 1].frequencyHz)) {
                return failure(ErrorCode::InvalidArgument, "частоты профиля должны возрастать");
            }
        }
    }
    ResponseSystem system;
    if (const auto message = buildResponseSystem(problem, system)) {
        const ErrorCode code = message->find("нет группы") == 0 ? ErrorCode::NotFound
                               : message->find("вырожденный") == 0 ? ErrorCode::ShapeInvalid
                                                                    : ErrorCode::InvalidArgument;
        return failure(code, *message);
    }
    const int n = system.map.freeCount;
    const int nodeCount = system.nodeCount;
    const Vec3 d = system.direction;
    auto amplitudeAt = [&](double frequency) {
        if (imbalance) {
            const double omega = 2.0 * M_PI * frequency;
            return excitation.imbalanceKgM * omega * omega;
        }
        return profileAt(excitation.amplitude, frequency);
    };

    HarmonicSolution solution;
    solution.staticCorrection = settings.staticCorrection;
    ResponseBasis basis;
    if (!direct) {
        if (const auto message = buildResponseBasis(system, problem, settings.modal, settings.staticCorrection, basis)) {
            return failure(ErrorCode::KernelOperationFailed, *message);
        }
        solution.modal = basis.modal;
        solution.highestModeHz = basis.highestModeHz;
        solution.effectiveMassFraction = basis.effectiveMassFraction;
    } else {
        solution.effectiveMassFraction = std::nan("");
    }

    // --- Frequencies.
    std::vector<double> frequencies = settings.frequenciesHz;
    if (frequencies.empty()) {
        const double ratio = std::log(problem.maximumHz / problem.minimumHz);
        for (int i = 0; i < settings.sweepPoints; ++i)
            frequencies.push_back(problem.minimumHz * std::exp(ratio * i / (settings.sweepPoints - 1)));
        if (!direct) {
            for (const auto& mode : basis.modal.modes) {
                for (int k = -20; k <= 20; ++k) {
                    const double f = mode.frequencyHz * (1.0 + k * problem.dampingRatio / 10.0);
                    if (f >= problem.minimumHz && f <= problem.maximumHz) frequencies.push_back(f);
                }
            }
        }
    }
    std::sort(frequencies.begin(), frequencies.end());
    frequencies.erase(std::unique(frequencies.begin(), frequencies.end(),
                                  [](double a, double b) { return std::fabs(a - b) <= 1e-12 * std::max(a, b); }),
                      frequencies.end());
    const int F = static_cast<int>(frequencies.size());
    solution.samples.resize(F);
    for (int k = 0; k < F; ++k) {
        solution.samples[k].frequencyHz = frequencies[k];
        solution.samples[k].excitation = amplitudeAt(frequencies[k]);
    }

    if (direct) {
        // (K − ω²M) u = P·A(ω), one LDLᵀ per frequency.
        double worst = -1.0;
        for (int k = 0; k < F; ++k) {
            const double omega2 = std::pow(2.0 * M_PI * frequencies[k], 2.0);
            SymmetricCsc A = system.K;
            for (std::size_t i = 0; i < A.values.size(); ++i) A.values[i] = system.K.values[i] - omega2 * system.M.values[i];
            SparseCholesky ldlt;
            if (!ldlt.factor(A, true)) return failure(ErrorCode::KernelOperationFailed, "K − ω²M вырождена: частота совпала с собственной");
            std::vector<double> rhs(n), x;
            for (int i = 0; i < n; ++i) rhs[i] = system.P[i] * solution.samples[k].excitation;
            ldlt.solve(rhs, x);
            const auto u = system.toFull(x.data());
            const auto stress = averagedNodalStress(*system.mesh, system.elasticity, u);
            auto& sample = solution.samples[k];
            for (int node = 0; node < nodeCount; ++node) {
                const double vm = vonMises(stress[node]);
                if (system.counts(node) && vm > sample.maxVonMisesPa) { sample.maxVonMisesPa = vm; sample.maxVonMisesNode = node; }
                const double magnitude = length(u[node]);
                if (magnitude > sample.maxDisplacementM) { sample.maxDisplacementM = magnitude; sample.maxDisplacementNode = node; }
            }
            if (!system.probeWeights.empty()) {
                const Vec3 mean = system.probeOf(u);
                sample.probeDisplacementM = length(mean);
                const Vec3 acceleration = (base ? d * sample.excitation : Vec3{}) - mean * omega2;
                sample.probeAccelerationMs2 = length(acceleration);
            }
            if (sample.maxVonMisesPa > worst) {
                worst = sample.maxVonMisesPa;
                solution.worstSample = k;
                solution.worstVonMisesPa.assign(nodeCount, 0.0);
                for (int node = 0; node < nodeCount; ++node) solution.worstVonMisesPa[node] = vonMises(stress[node]);
                solution.worstDisplacementReal = u;
                solution.worstDisplacementImag.assign(nodeCount, Vec3{});
            }
        }
        return Result<HarmonicSolution>::ok(std::move(solution));
    }

    // Complex coefficients per frequency (column 2k real, 2k+1 imaginary), amplitude included.
    const int J = basis.J;
    const std::size_t stressRows = basis.stressRows, motionRows = basis.motionRows;
    const auto& stressBasis = basis.stressBasis;
    const auto& motionBasis = basis.motionBasis;
    std::vector<double> coefficients(static_cast<std::size_t>(J) * 2 * F, 0.0);
    for (int k = 0; k < F; ++k) {
        const double omega = 2.0 * M_PI * frequencies[k];
        const double amplitude = solution.samples[k].excitation;
        double* re = &coefficients[static_cast<std::size_t>(2 * k) * J];
        double* im = &coefficients[static_cast<std::size_t>(2 * k + 1) * J];
        basis.coefficients(omega, problem.dampingRatio, re, im);
        for (int j = 0; j < J; ++j) {
            re[j] *= amplitude;
            im[j] *= amplitude;
        }
        if (!system.probeWeights.empty()) {
            Vec3 real, imaginary;
            for (int j = 0; j < J; ++j) {
                real += basis.probeBasis[j] * re[j];
                imaginary += basis.probeBasis[j] * im[j];
            }
            auto& sample = solution.samples[k];
            sample.probeDisplacementM = peakMagnitude(real, imaginary);
            // Absolute acceleration: the base's own (real, along d) minus ω² times the relative motion.
            const Vec3 accelerationReal = (base ? d * amplitude : Vec3{}) - real * (omega * omega);
            sample.probeAccelerationMs2 = peakMagnitude(accelerationReal, imaginary * (-omega * omega));
        }
    }

    // Response = basis × coefficients, in blocks of nodes and frequencies so the product stays small.
    const int nodeBlock = 2048, frequencyBlock = 64;
    std::vector<double> product;
    for (int node0 = 0; node0 < nodeCount; node0 += nodeBlock) {
        const int nodes = std::min(nodeBlock, nodeCount - node0);
        for (int k0 = 0; k0 < F; k0 += frequencyBlock) {
            const int count = std::min(frequencyBlock, F - k0);
            for (const bool stress : {true, false}) {
                const int width = stress ? 6 : 3;
                const std::size_t rows = static_cast<std::size_t>(width) * nodes;
                product.assign(rows * 2 * count, 0.0);
                const double* source = stress ? &stressBasis[static_cast<std::size_t>(width) * node0] : &motionBasis[static_cast<std::size_t>(width) * node0];
                cblas_dgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, static_cast<int>(rows), 2 * count, J, 1.0, source,
                            static_cast<int>(stress ? stressRows : motionRows), &coefficients[static_cast<std::size_t>(2 * k0) * J], J, 0.0,
                            product.data(), static_cast<int>(rows));
                for (int k = 0; k < count; ++k) {
                    auto& sample = solution.samples[k0 + k];
                    const double* re = &product[static_cast<std::size_t>(2 * k) * rows];
                    const double* im = &product[static_cast<std::size_t>(2 * k + 1) * rows];
                    for (int i = 0; i < nodes; ++i) {
                        if (stress) {
                            const double vm = peakVonMisesRaw(re + 6 * i, im + 6 * i);
                            if (system.counts(node0 + i) && vm > sample.maxVonMisesPa) { sample.maxVonMisesPa = vm; sample.maxVonMisesNode = node0 + i; }
                        } else {
                            const double magnitude = peakMagnitudeRaw(re + 3 * i, im + 3 * i);
                            if (magnitude > sample.maxDisplacementM) { sample.maxDisplacementM = magnitude; sample.maxDisplacementNode = node0 + i; }
                        }
                    }
                }
            }
        }
    }
    for (int k = 1; k < F; ++k)
        if (solution.samples[k].maxVonMisesPa > solution.samples[solution.worstSample].maxVonMisesPa) solution.worstSample = k;

    // The field at the worst frequency, node by node.
    {
        const std::size_t w = solution.worstSample;
        const double* re = &coefficients[2 * w * J];
        const double* im = &coefficients[(2 * w + 1) * J];
        solution.worstVonMisesPa.assign(nodeCount, 0.0);
        solution.worstDisplacementReal.assign(nodeCount, Vec3{});
        solution.worstDisplacementImag.assign(nodeCount, Vec3{});
        for (int node = 0; node < nodeCount; ++node) {
            double sr[6] = {}, si[6] = {};
            for (int j = 0; j < J; ++j) {
                for (int c = 0; c < 6; ++c) {
                    const double value = stressBasis[j * stressRows + 6 * node + c];
                    sr[c] += value * re[j];
                    si[c] += value * im[j];
                }
                for (int c = 0; c < 3; ++c) {
                    const double value = motionBasis[j * motionRows + 3 * node + c];
                    solution.worstDisplacementReal[node][c] += value * re[j];
                    solution.worstDisplacementImag[node][c] += value * im[j];
                }
            }
            solution.worstVonMisesPa[node] = peakVonMisesRaw(sr, si);
        }
    }
    return Result<HarmonicSolution>::ok(std::move(solution));
}

} // namespace cadnext::fea
