// Mechanical shock verification: the exact modal integrator, the shock response spectrum, and the
// transient response of the beam of test_fea_harmonic against beam theory.
//
// Criteria, fixed before the first run:
//   1. Single degree of freedom:
//      - a ramp force (linear, what the integrator assumes on each step) is reproduced to 1e-10 of the
//        closed form, at any step;
//      - a half-sine base pulse, 200 samples per pulse, within 1e-4 of the closed form (the pulse is
//        linearised between samples), and the error falls about fourfold when the step halves;
//      - with damping, within 1e-6 of an independent fourth-order Runge–Kutta at a fine step.
//   2. Shock response spectrum of a half-sine (undamped) within 0.5 % of the maximum taken from the
//      closed-form response on a fine time grid.
//   3. Beam (cantilever, base half-sine along z, ζ = 2 %):
//      - peak relative tip displacement within 1 % of the Euler–Bernoulli series, its modes integrated
//        by the same independent Runge–Kutta;
//      - mid-span surface stress at the worst instant within 2 % of E·(h/2)·w″ of the series;
//      - a quasi-static load gives the static tip deflection qL⁴/8EI within 1 % (the static
//        correction). Amended after the first run, and why: the first version took a half-sine ten
//        first-periods long as quasi-static, and it is not — the spectrum in item 2 shows 1.05·A at
//        fτ = 10 undamped, and the solver answered +2.4 % with ζ = 2 %. A trapezoid whose rise lasts
//        exactly ten first-mode periods leaves an UNDAMPED mode no residual motion; with ζ = 2 % the
//        transient from the start of the ramp (1/(ωt_r) = 1.6 % of static) has decayed to 28.5 % by its
//        end and no longer cancels the one from the end — 1.6 % × 0.715 = 1.14 %, which the second run
//        showed exactly (peak a quarter period after the ramp, plateau at the static value). The check is
//        about the static correction, not damping, so it runs at ζ = 0.2 %: residual below 0.2 %.
//        Threshold unchanged.

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/Shock.hpp"

#include <cmath>
#include <functional>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kLength = 1.0;
constexpr double kWidth = 0.03;
constexpr double kHeight = 0.02;
constexpr double kG = 9.80665;

TetMesh beam(int lengthCells, int sectionCells) {
    MappedBlockSpec spec;
    spec.cellsU = lengthCells;
    spec.cellsV = sectionCells;
    spec.cellsW = sectionCells;
    spec.mapping = [](double u, double v, double w) { return Vec3{u * kLength, v * kWidth, w * kHeight}; };
    spec.faceNames = {"root", "tip", "", "", "", ""};
    return generateMappedBlock(spec);
}

// Fourth-order Runge–Kutta for q̈ + 2ζωq̇ + ω²q = f(t), from rest; calls `sample(t, q, q̇)` every
// `every` steps.
void rungeKutta(double omega, double zeta, const std::function<double(double)>& f, double end, double h, int every,
                const std::function<void(double, double, double)>& sample) {
    double q = 0.0, v = 0.0, t = 0.0;
    auto acc = [&](double tt, double qq, double vv) { return f(tt) - 2.0 * zeta * omega * vv - omega * omega * qq; };
    const long steps = static_cast<long>(std::ceil(end / h));
    for (long i = 0; i <= steps; ++i) {
        if (i % every == 0) sample(t, q, v);
        const double k1q = v, k1v = acc(t, q, v);
        const double k2q = v + 0.5 * h * k1v, k2v = acc(t + 0.5 * h, q + 0.5 * h * k1q, v + 0.5 * h * k1v);
        const double k3q = v + 0.5 * h * k2v, k3v = acc(t + 0.5 * h, q + 0.5 * h * k2q, v + 0.5 * h * k2v);
        const double k4q = v + h * k3v, k4v = acc(t + h, q + h * k3q, v + h * k3v);
        q += h / 6.0 * (k1q + 2 * k2q + 2 * k3q + k4q);
        v += h / 6.0 * (k1v + 2 * k2v + 2 * k3v + k4v);
        t += h;
    }
}

// Undamped relative displacement of a base-excited oscillator under a half-sine A sin(πt/τ), closed form.
double halfSineUndamped(double omega, double A, double tau, double t) {
    const double W = M_PI / tau;
    auto during = [&](double s) { return -A / (omega * omega - W * W) * (std::sin(W * s) - W / omega * std::sin(omega * s)); };
    if (t <= tau) return during(t);
    const double z = during(tau);
    const double zd = -A / (omega * omega - W * W) * (W * std::cos(W * tau) - W * std::cos(omega * tau));
    const double s = t - tau;
    return z * std::cos(omega * s) + zd / omega * std::sin(omega * s);
}

struct BeamSeries {
    struct Mode {
        double beta, sigma, omega, scale, gamma;
        double g(double z) const {
            const double bl = beta * kLength, e = std::exp(-bl);
            return 0.5 * std::exp(-z) * (1.0 + sigma) + std::exp(z - bl) * (std::sin(bl) - std::cos(bl) - e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
        }
        double shape(double x) const { return g(beta * x) - std::cos(beta * x) + sigma * std::sin(beta * x); }
        double curvature(double x) const { return beta * beta * (g(beta * x) + std::cos(beta * x) - sigma * std::sin(beta * x)); }
    };
    std::vector<Mode> modes;
    BeamSeries(double E, double rho, int count) {
        const double A = kWidth * kHeight, I = kWidth * kHeight * kHeight * kHeight / 12.0;
        for (int n = 1; n <= count; ++n) {
            double bl = n == 1 ? 1.875 : (2 * n - 1) * M_PI / 2.0;
            for (int i = 0; i < 50; ++i) bl -= (std::cos(bl) + 1.0 / std::cosh(bl)) / (-std::sin(bl) - std::tanh(bl) / std::cosh(bl));
            Mode mode{bl / kLength, 0, 0, 0, 0};
            const double e = std::exp(-bl);
            mode.sigma = (1.0 + e * e + 2.0 * std::cos(bl) * e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
            const int intervals = 20000;
            double squared = 0.0, plain = 0.0;
            for (int i = 0; i <= intervals; ++i) {
                const double x = kLength * i / intervals, w = (i == 0 || i == intervals) ? 1.0 : (i % 2 ? 4.0 : 2.0);
                squared += w * mode.shape(x) * mode.shape(x);
                plain += w * mode.shape(x);
            }
            squared *= kLength / (3.0 * intervals);
            plain *= kLength / (3.0 * intervals);
            mode.scale = 1.0 / std::sqrt(rho * A * squared);
            mode.omega = bl * bl / (kLength * kLength) * std::sqrt(E * I / (rho * A));
            mode.gamma = rho * A * mode.scale * plain;
            modes.push_back(mode);
        }
    }
};

} // namespace

int main() {
    // --- 1. Single degree of freedom.
    {
        const double omega = 2 * M_PI * 50.0, b = 3.0, step = 1.3e-4;
        std::vector<double> force(400);
        for (std::size_t i = 0; i < force.size(); ++i) force[i] = b * step * static_cast<double>(i);
        std::vector<double> q, qd;
        integrateModalResponse(omega, 0.0, step, force, q, qd);
        double worst = 0.0, scale = 0.0;
        for (std::size_t i = 0; i < q.size(); ++i) {
            const double t = step * static_cast<double>(i);
            const double exact = b / (omega * omega) * (t - std::sin(omega * t) / omega);
            worst = std::max(worst, std::fabs(q[i] - exact));
            scale = std::max(scale, std::fabs(exact));
        }
        check(worst <= 1e-10 * scale, "a ramp force is integrated exactly (the step's own assumption)", "error " + std::to_string(worst / scale));
    }
    {
        const double omega = 2 * M_PI * 80.0, A = 100.0, tau = 0.011;
        auto errorAt = [&](int samples) {
            const double step = tau / samples;
            const int n = static_cast<int>(3 * tau / step) + 1;
            std::vector<double> force(n);
            for (int i = 0; i < n; ++i) {
                const double t = step * i;
                force[i] = t <= tau ? -A * std::sin(M_PI * t / tau) : 0.0;
            }
            std::vector<double> q, qd;
            integrateModalResponse(omega, 0.0, step, force, q, qd);
            double worst = 0.0, scale = 0.0;
            for (int i = 0; i < n; ++i) {
                const double exact = halfSineUndamped(omega, A, tau, step * i);
                worst = std::max(worst, std::fabs(q[i] - exact));
                scale = std::max(scale, std::fabs(exact));
            }
            return worst / scale;
        };
        const double e200 = errorAt(200), e400 = errorAt(400);
        std::printf("  half-sine, undamped: error %.2e at 200 samples per pulse, %.2e at 400 (ratio %.2f)\n", e200, e400, e200 / e400);
        check(e200 <= 1e-4 && e200 / e400 > 3.5 && e200 / e400 < 4.5, "a half-sine pulse: error set by sampling alone, second order");
    }
    {
        const double omega = 2 * M_PI * 30.0, zeta = 0.05, A = 50.0, tau = 0.02, step = tau / 200;
        const int n = static_cast<int>(4 * tau / step) + 1;
        std::vector<double> force(n);
        auto pulse = [&](double t) { return t <= tau ? -A * std::sin(M_PI * t / tau) : 0.0; };
        for (int i = 0; i < n; ++i) force[i] = pulse(step * i);
        std::vector<double> q, qd;
        integrateModalResponse(omega, zeta, step, force, q, qd);
        // Reference: RK4 at step/200 on the same piecewise-linear force (the one the integrator is exact for).
        auto linear = [&](double t) {
            const int i = std::min(static_cast<int>(t / step), n - 2);
            const double w = t / step - i;
            return force[i] + w * (force[i + 1] - force[i]);
        };
        double worst = 0.0, scale = 0.0;
        int k = 0;
        rungeKutta(omega, zeta, linear, step * (n - 1), step / 200, 200, [&](double, double qq, double) {
            if (k < n) {
                worst = std::max(worst, std::fabs(q[k] - qq));
                scale = std::max(scale, std::fabs(qq));
            }
            ++k;
        });
        check(worst <= 1e-6 * scale, "damped: the exact integrator matches an independent Runge–Kutta", "error " + std::to_string(worst / scale));
    }

    // --- 2. Shock response spectrum of a half-sine.
    {
        const double A = 100.0, tau = 0.01, step = tau / 400;
        const int n = static_cast<int>(0.2 / step) + 1;
        std::vector<double> base(n);
        for (int i = 0; i < n; ++i) base[i] = step * i <= tau ? A * std::sin(M_PI * step * i / tau) : 0.0;
        // Not fτ = 0.5 exactly: there the pulse frequency equals the oscillator's and the closed form
        // above divides by zero (the first run hit it; the solver itself gave π/2·A, the resonant value).
        const std::vector<double> frequencies{20.0, 55.0, 80.0, 120.0, 300.0, 1000.0};
        const auto srs = shockResponseSpectrum(base, step, frequencies, 1e-9);
        double worst = 0.0;
        for (std::size_t i = 0; i < frequencies.size(); ++i) {
            const double omega = 2 * M_PI * frequencies[i];
            double peak = 0.0;
            for (double t = 0.0; t <= 0.2; t += 2e-7) peak = std::max(peak, omega * omega * std::fabs(halfSineUndamped(omega, A, tau, t)));
            worst = std::max(worst, std::fabs(srs[i] / peak - 1.0));
            std::printf("  SRS at %6.0f Hz (fτ = %.2f): %.3f A (closed form %.3f A)\n", frequencies[i], frequencies[i] * tau, srs[i] / A, peak / A);
        }
        check(worst <= 0.005, "the shock response spectrum of a half-sine matches the closed form within 0.5 %");
    }

    // --- 3. Beam.
    const auto steel = *findMaterial("steel_4130");
    const double E = steel.youngsModulusPa, rho = steel.densityKgPerM3;
    const TetMesh mesh = beam(100, 2);
    const BeamSeries series(E, rho, 30);
    const double f1 = series.modes[0].omega / (2 * M_PI);
    ShockProblem problem;
    problem.mesh = &mesh;
    problem.material = steel;
    problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
    problem.direction = {0, 0, 1};
    problem.dampingRatio = 0.02;
    problem.modeCount = 12;
    problem.probeFaceGroup = "tip";
    {
        // 20 g half-sine of 11 ms (MIL-STD-810 functional shock), between the first two bending modes.
        problem.pulse = {PulseShape::HalfSine, 20.0 * kG, 0.011};
        const auto result = solveShock(problem);
        check(result.isOk(), "shock solves", result.isOk() ? "" : result.error().message);
        if (!result.isOk()) return fea_test::finish("test_fea_shock");
        const auto& r = result.value();
        // Series reference: every mode by RK4, tip and mid-span curvature tracked at every sample.
        const double window = r.timeS.back();
        double tipPeak = 0.0;
        std::vector<std::vector<double>> modal(series.modes.size());
        const double h = 2e-6;
        for (std::size_t m = 0; m < series.modes.size(); ++m) {
            const auto& mode = series.modes[m];
            rungeKutta(mode.omega, 0.02, [&](double t) { return -mode.gamma * problem.pulse.at(t); }, window, h, 5,
                       [&](double, double qq, double) { modal[m].push_back(qq); });
        }
        std::size_t samples = modal[0].size();
        std::vector<double> tip(samples, 0.0), curvature(samples, 0.0);
        for (std::size_t m = 0; m < series.modes.size(); ++m)
            for (std::size_t i = 0; i < samples && i < modal[m].size(); ++i) {
                tip[i] += series.modes[m].scale * series.modes[m].shape(kLength) * modal[m][i];
                curvature[i] += series.modes[m].scale * series.modes[m].curvature(0.5 * kLength) * modal[m][i];
            }
        std::size_t peakAt = 0;
        for (std::size_t i = 0; i < samples; ++i)
            if (std::fabs(tip[i]) > tipPeak) tipPeak = std::fabs(tip[i]), peakAt = i;
        double fePeak = 0.0;
        for (double v : r.probeDisplacementM) fePeak = std::max(fePeak, std::fabs(v));
        std::printf("  beam, 20 g × 11 ms half-sine: tip peak FE %.5e m, series %.5e m (%+.3f %%) at t = %.2f ms; f1 %.2f Hz, %zu steps\n", fePeak,
                    tipPeak, 100 * (fePeak / tipPeak - 1), 1e3 * peakAt * 5 * h, f1, r.timeS.size());
        checkRelative(fePeak, tipPeak, 0.01, "peak tip displacement matches the beam series");
        // Mid-span stress at the FE's worst instant.
        const double tWorst = r.timeS[r.worstSample];
        const std::size_t index = std::min(samples - 1, static_cast<std::size_t>(std::lround(tWorst / (5 * h))));
        const int node = mesh.nearestNode({0.5 * kLength, 0.5 * kWidth, kHeight});
        const double reference = E * 0.5 * kHeight * std::fabs(curvature[index]);
        std::printf("  worst instant %.3f ms: peak stress %.3f MPa; mid-span surface FE %.4f MPa, series %.4f MPa (%+.3f %%)\n", 1e3 * tWorst,
                    r.peakVonMisesPa / 1e6, r.worstVonMisesPa[node] / 1e6, reference / 1e6, 100 * (r.worstVonMisesPa[node] / reference - 1));
        checkRelative(r.worstVonMisesPa[node], reference, 0.02, "mid-span surface stress at the worst instant matches E·(h/2)·w″");
    }
    {
        // Quasi-static: rise over exactly ten first-mode periods, hold, fall alike.
        problem.pulse = {PulseShape::Trapezoid, 5.0 * kG, 30.0 / f1, 10.0 / f1, 10.0 / f1};
        auto slow = problem;
        slow.dampingRatio = 0.002;
        const auto result = solveShock(slow);
        check(result.isOk(), "long pulse solves");
        if (result.isOk()) {
            double fePeak = 0.0;
            for (double v : result.value().probeDisplacementM) fePeak = std::max(fePeak, std::fabs(v));
            const double q = rho * kWidth * kHeight * 5.0 * kG, I = kWidth * kHeight * kHeight * kHeight / 12.0;
            const double statics = q * std::pow(kLength, 4) / (8 * E * I);
            std::printf("  quasi-static pulse: tip peak %.5e m, qL⁴/8EI %.5e m (%+.3f %%)\n", fePeak, statics, 100 * (fePeak / statics - 1));
            checkRelative(fePeak, statics, 0.01, "a slow pulse gives the static deflection under its peak");
        }
    }
    auto bad = problem;
    bad.dampingRatio = -1;
    check(!solveShock(bad).isOk(), "damping has no default");
    bad = problem;
    bad.pulse = {PulseShape::Trapezoid, 10.0, 0.01, 0.006, 0.006};
    check(!solveShock(bad).isOk(), "a trapezoid whose edges overlap is refused");
    return fea_test::finish("test_fea_shock");
}
