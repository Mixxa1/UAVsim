// Harmonic (sine) vibration verification: modal superposition with the static correction against beam
// theory and against the direct solution of the same discrete system.
//
// Beam as in test_fea_modal: L = 1 m, b = 30 mm (y) × h = 20 mm (z), steel 4130, clamped at x = 0.
// Base excitation along z (the weak bending plane), ζ = 2 %, probe = the tip face.
//
// Reference: Euler–Bernoulli cantilever under base acceleration a with modal damping,
//   w(x, ω) = −a Σ_n Φ_n(x) Γ_n / (ω_n² − ω² + 2iζω_nω),   Γ_n = ∫ρA Φ_n dx,
// Φ_n the mass-normalised clamped–free modes (Blevins), 40 of them — the tail of the displacement
// series falls as β_n⁻⁵ and of the curvature as β_n⁻³. Mode functions are evaluated in a form that does
// not cancel e^{βx} against e^{βx} (the textbook form loses all digits past β L ≈ 30), and their
// integrals are taken numerically rather than from memory.
//
// Criteria, fixed before the first run:
//   1. Tip motion (at the resonance peak, at 0.01 f₁ — the static limit, at 0.3 f₁ and at 3 f₁) within
//      1 % of the series. The frequencies on this mesh already match beam theory to about 0.1 % (the
//      solid's clamped root; test_fea_modal), the resonance amplitude goes as 1/ω₁² (0.2 %), and the
//      sweep catches the peak within 0.12 %; 1 % leaves three times that.
//   2. Surface stress at mid-span at the resonance within 2 % of E·(h/2)·w″: the displacement error
//      plus the extrapolation of stress from quadrature points to the surface node.
//   3. Against the direct solution of (K − ω²M)u = P (undamped, both sides; the superposition with
//      ζ = 1e-6), 12 modes, frequencies up to between the 2nd and 3rd weak bending modes: tip motion
//      within 0.1 %, peak stress within 0.5 %, for base excitation and for a force on the tip. Without
//      the static correction the error must be larger — that is what the correction is for.
//      Amended after the first run, and why: the point between the 2nd and 3rd modes (196.6 Hz) is an
//      anti-resonance of the tip — its motion there is 1.3e-7 m, 10⁴ times the motion at 8 Hz — and a
//      relative error of a quantity passing near zero measures nothing (0.39 % there, 5e-10 m). The
//      tip error is now taken against the larger of the direct response and the quasi-static one
//      (at 0.01 f₁), threshold unchanged; and at that point 24 modes must cut the plain relative error
//      at least tenfold, which is what truncation — and only truncation — does (measured: 3.9e-3 →
//      2.5e-5 → 1.1e-5 with 12 → 24 → 48 modes).
//   4. Peak von Mises over the cycle: the closed form against 3600 sampled phases.

#include "fea_test_support.hpp"

#include "cadnext/fea/Harmonic.hpp"
#include "cadnext/fea/Material.hpp"

#include <cmath>
#include <complex>
#include <random>

using namespace cadnext::fea;
using fea_test::check;
using fea_test::checkRelative;

namespace {

constexpr double kLength = 1.0;
constexpr double kWidth = 0.03;  // y
constexpr double kHeight = 0.02; // z
constexpr double kZeta = 0.02;

TetMesh beam(int lengthCells, int sectionCells) {
    MappedBlockSpec spec;
    spec.cellsU = lengthCells;
    spec.cellsV = sectionCells;
    spec.cellsW = sectionCells;
    spec.mapping = [](double u, double v, double w) { return Vec3{u * kLength, v * kWidth, w * kHeight}; };
    spec.faceNames = {"root", "tip", "", "", "", ""};
    return generateMappedBlock(spec);
}

// Clamped–free Euler–Bernoulli beam, evaluated without cancellation.
struct CantileverMode {
    double beta = 0.0;  // 1/m
    double sigma = 0.0;
    // cosh z − σ sinh z = e^{−z}(1 + σ)/2 + e^{z}(1 − σ)/2, the second written as e^{z − βL}·(…).
    double g(double z) const {
        const double bl = beta * kLength;
        const double e = std::exp(-bl);
        const double oneMinusSigmaScaled = (std::sin(bl) - std::cos(bl) - e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
        return 0.5 * std::exp(-z) * (1.0 + sigma) + std::exp(z - bl) * oneMinusSigmaScaled;
    }
    double shape(double x) const { return g(beta * x) - std::cos(beta * x) + sigma * std::sin(beta * x); }
    double curvature(double x) const { return beta * beta * (g(beta * x) + std::cos(beta * x) - sigma * std::sin(beta * x)); }
};

struct BeamSeries {
    std::vector<CantileverMode> modes;
    std::vector<double> omega;    // rad/s
    std::vector<double> scale;    // Φ = scale · φ (mass normalisation)
    std::vector<double> gamma;    // Γ = ∫ρA Φ dx

    BeamSeries(double E, double rho, int count) {
        const double A = kWidth * kHeight, I = kWidth * kHeight * kHeight * kHeight / 12.0;
        for (int n = 1; n <= count; ++n) {
            // Roots of 1 + cos βL cosh βL = 0 by Newton from the asymptote (2n − 1)π/2.
            double bl = n == 1 ? 1.875 : (2 * n - 1) * M_PI / 2.0;
            for (int i = 0; i < 50; ++i) {
                // f = cos(bl) + 1/cosh(bl): the same roots, bounded.
                const double f = std::cos(bl) + 1.0 / std::cosh(bl);
                const double df = -std::sin(bl) - std::tanh(bl) / std::cosh(bl);
                bl -= f / df;
            }
            CantileverMode mode;
            mode.beta = bl / kLength;
            const double e = std::exp(-bl);
            // σ = (cosh + cos)/(sinh + sin) with e^{βL}/2 factored out of both.
            mode.sigma = (1.0 + e * e + 2.0 * std::cos(bl) * e) / (1.0 - e * e + 2.0 * std::sin(bl) * e);
            // Mass normalisation and participation by Simpson's rule.
            const int intervals = 20000;
            double squared = 0.0, plain = 0.0;
            for (int i = 0; i <= intervals; ++i) {
                const double x = kLength * i / intervals;
                const double w = (i == 0 || i == intervals) ? 1.0 : (i % 2 ? 4.0 : 2.0);
                const double phi = mode.shape(x);
                squared += w * phi * phi;
                plain += w * phi;
            }
            squared *= kLength / (3.0 * intervals);
            plain *= kLength / (3.0 * intervals);
            const double s = 1.0 / std::sqrt(rho * A * squared);
            modes.push_back(mode);
            omega.push_back(bl * bl / (kLength * kLength) * std::sqrt(E * I / (rho * A)));
            scale.push_back(s);
            gamma.push_back(rho * A * s * plain);
        }
    }
    // Complex relative displacement and curvature at x for base acceleration a (peak), ζ.
    std::complex<double> displacement(double x, double f, double a) const {
        std::complex<double> sum = 0.0;
        const double w = 2.0 * M_PI * f;
        for (std::size_t n = 0; n < modes.size(); ++n)
            sum += -a * scale[n] * modes[n].shape(x) * gamma[n] / std::complex<double>(omega[n] * omega[n] - w * w, 2 * kZeta * omega[n] * w);
        return sum;
    }
    std::complex<double> curvature(double x, double f, double a) const {
        std::complex<double> sum = 0.0;
        const double w = 2.0 * M_PI * f;
        for (std::size_t n = 0; n < modes.size(); ++n)
            sum += -a * scale[n] * modes[n].curvature(x) * gamma[n] / std::complex<double>(omega[n] * omega[n] - w * w, 2 * kZeta * omega[n] * w);
        return sum;
    }
};

HarmonicSolution solveOrDie(const HarmonicProblem& problem, const HarmonicSettings& settings) {
    const auto result = solveHarmonic(problem, settings);
    if (!result.isOk()) {
        std::printf("  FAIL  harmonic solver: %s\n", result.error().message.c_str());
        ++fea_test::failures();
        std::exit(fea_test::finish("test_fea_harmonic"));
    }
    return result.value();
}

} // namespace

int main() {
    const auto steel = *findMaterial("steel_4130");
    const double E = steel.youngsModulusPa, rho = steel.densityKgPerM3;
    const double g0 = 9.80665;

    // --- 4. Peak over the cycle, closed form against sampled phases.
    {
        std::mt19937 random(11);
        std::uniform_real_distribution<double> value(-1.0, 1.0);
        double worst = 0.0;
        bool neverAbove = true;
        for (int trial = 0; trial < 200; ++trial) {
            Voigt re{}, im{};
            for (int c = 0; c < 6; ++c) { re[c] = value(random); im[c] = value(random); }
            const double exact = peakVonMises(re, im);
            double sampled = 0.0;
            for (int k = 0; k < 3600; ++k) {
                const double t = 2.0 * M_PI * k / 3600.0;
                Voigt s{};
                for (int c = 0; c < 6; ++c) s[c] = re[c] * std::cos(t) - im[c] * std::sin(t);
                sampled = std::max(sampled, vonMises(s));
            }
            neverAbove = neverAbove && sampled <= exact * (1 + 1e-12);
            worst = std::max(worst, 1.0 - sampled / exact);
        }
        check(neverAbove && worst < 1e-5, "peak von Mises over the cycle: closed form bounds and matches 3600 sampled phases",
              "largest shortfall of sampling " + std::to_string(worst));
    }

    const TetMesh mesh = beam(100, 2);
    const BeamSeries series(E, rho, 40);
    const double f1 = series.omega[0] / (2 * M_PI);
    std::printf("  beam theory: f1 = %.4f Hz, f2 = %.4f Hz, f3 = %.4f Hz (weak plane)\n", f1, series.omega[1] / (2 * M_PI),
                series.omega[2] / (2 * M_PI));

    HarmonicProblem problem;
    problem.mesh = &mesh;
    problem.material = steel;
    problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
    problem.excitation.kind = HarmonicExcitationKind::BaseAcceleration;
    problem.excitation.direction = {0, 0, 1};
    problem.excitation.amplitude = {{1.0, g0}};
    problem.dampingRatio = kZeta;
    problem.modeCount = 12;
    problem.minimumHz = 0.01 * f1;
    problem.maximumHz = 3.0 * f1;
    problem.probeFaceGroup = "tip";

    // --- 1, 2. Against beam theory.
    {
        HarmonicSettings settings;
        settings.sweepPoints = 120;
        const auto solution = solveOrDie(problem, settings);
        std::printf("  retained 12 modes up to %.1f Hz, effective mass along z %.2f %%\n", solution.highestModeHz,
                    100.0 * solution.effectiveMassFraction);
        // Resonance: the largest tip motion of the sweep against the series' own peak.
        double fePeak = 0.0, feAt = 0.0;
        for (const auto& s : solution.samples)
            if (s.probeDisplacementM > fePeak) { fePeak = s.probeDisplacementM; feAt = s.frequencyHz; }
        double beamPeak = 0.0, beamAt = 0.0;
        for (int k = -2000; k <= 2000; ++k) {
            const double f = f1 * (1.0 + k * kZeta / 1000.0);
            const double value = std::abs(series.displacement(kLength, f, g0));
            if (value > beamPeak) { beamPeak = value; beamAt = f; }
        }
        std::printf("  resonance: FE %.6e m at %.4f Hz, beam %.6e m at %.4f Hz (Q-factor check: w/w_static = %.2f)\n", fePeak, feAt,
                    beamPeak, beamAt, beamPeak / std::abs(series.displacement(kLength, 1e-6, g0)));
        checkRelative(fePeak, beamPeak, 0.01, "tip motion at the first resonance matches the damped beam series");
        for (const double ratio : {0.01, 0.3, 3.0}) {
            HarmonicSettings at;
            at.frequenciesHz = {ratio * f1};
            const auto point = solveOrDie(problem, at);
            const double fe = point.samples[0].probeDisplacementM, reference = std::abs(series.displacement(kLength, ratio * f1, g0));
            std::printf("  f = %.2f f1: FE %.6e m, beam %.6e m (%+.3f %%)\n", ratio, fe, reference, 100 * (fe / reference - 1));
            checkRelative(fe, reference, 0.01, "tip motion at " + std::to_string(ratio).substr(0, 4) + " f1 matches the beam series");
        }
        // Static limit in closed form as well: uniform load ρAa, tip deflection qL⁴/(8EI).
        {
            const double q = rho * kWidth * kHeight * g0, I = kWidth * kHeight * kHeight * kHeight / 12.0;
            checkRelative(std::abs(series.displacement(kLength, 1e-4 * f1, g0)), q * std::pow(kLength, 4) / (8 * E * I), 1e-4,
                          "the beam series itself reduces to qL⁴/8EI in the static limit");
        }
        // Mid-span surface stress at the worst (resonant) frequency.
        const auto& worst = solution.samples[solution.worstSample];
        const int node = mesh.nearestNode({0.5 * kLength, 0.5 * kWidth, kHeight});
        const double fe = solution.worstVonMisesPa[node];
        const double reference = E * 0.5 * kHeight * std::abs(series.curvature(0.5 * kLength, worst.frequencyHz, g0));
        std::printf("  worst frequency %.4f Hz: peak stress %.4f MPa at node %d; mid-span surface FE %.4f MPa, beam %.4f MPa (%+.3f %%)\n",
                    worst.frequencyHz, worst.maxVonMisesPa / 1e6, worst.maxVonMisesNode, fe / 1e6, reference / 1e6, 100 * (fe / reference - 1));
        checkRelative(fe, reference, 0.02, "mid-span surface stress at resonance matches E·(h/2)·w″ of the beam series");
    }

    // --- 3. Superposition against the direct solution of the same system.
    {
        HarmonicSettings modal;
        const double antiResonance = 0.5 * (series.omega[1] + series.omega[2]) / (2 * M_PI);
        modal.frequenciesHz = {0.01 * f1, 0.5 * f1, 3.0 * f1, antiResonance};
        HarmonicSettings plainSettings = modal;
        plainSettings.staticCorrection = false;
        HarmonicSettings directSettings = modal;
        directSettings.method = HarmonicMethod::Direct;

        struct Case {
            std::string name;
            HarmonicExcitation excitation;
        };
        HarmonicExcitation tipForce;
        tipForce.kind = HarmonicExcitationKind::FaceForce;
        tipForce.faceGroup = "tip";
        tipForce.direction = {0, 0, 1};
        tipForce.amplitude = {{1.0, 10.0}};
        for (const auto& c : std::vector<Case>{{"base z", problem.excitation}, {"tip force z", tipForce}}) {
            auto p = problem;
            p.excitation = c.excitation;
            p.dampingRatio = 1e-6;
            const auto corrected = solveOrDie(p, modal);
            const auto plain = solveOrDie(p, plainSettings);
            auto undamped = p;
            undamped.dampingRatio = 0.0;
            const auto direct = solveOrDie(undamped, directSettings);
            bool correctionHelps = true;
            const double quasiStatic = direct.samples[0].probeDisplacementM;
            for (std::size_t k = 0; k < direct.samples.size(); ++k) {
                const auto& a = corrected.samples[k];
                const auto& b = direct.samples[k];
                const auto& n = plain.samples[k];
                const double motion = (a.probeDisplacementM - b.probeDisplacementM) / std::max(b.probeDisplacementM, quasiStatic);
                const double stress = a.maxVonMisesPa / b.maxVonMisesPa - 1;
                const double plainStress = n.maxVonMisesPa / b.maxVonMisesPa - 1;
                std::printf("  %s at %.2f Hz: tip %+.2e, peak stress %+.2e (without correction %+.2e)\n", c.name.c_str(), b.frequencyHz,
                            motion, stress, plainStress);
                check(std::fabs(motion) <= 1e-3 && std::fabs(stress) <= 5e-3,
                      c.name + ": superposition matches the direct solution at " + std::to_string(b.frequencyHz).substr(0, 6) + " Hz");
                correctionHelps = correctionHelps && std::fabs(stress) <= std::fabs(plainStress);
            }
            check(correctionHelps, c.name + ": the static correction brings the stress closer to the direct solution at every frequency");
            if (c.name == "base z") {
                auto more = p;
                more.modeCount = 24;
                HarmonicSettings at;
                at.frequenciesHz = {antiResonance};
                const auto finer = solveOrDie(more, at);
                const double reference = direct.samples.back().probeDisplacementM;
                const double with12 = std::fabs(corrected.samples.back().probeDisplacementM / reference - 1);
                const double with24 = std::fabs(finer.samples[0].probeDisplacementM / reference - 1);
                std::printf("  base z at the tip anti-resonance: relative error %.2e with 12 modes, %.2e with 24\n", with12, with24);
                check(with24 * 10 <= with12, "base z: at the tip anti-resonance the error is truncation — 24 modes cut it at least tenfold");
            }
        }
    }

    // Excitation bookkeeping: imbalance is U·Ω²; a profile is interpolated log–log.
    {
        auto p = problem;
        p.excitation.kind = HarmonicExcitationKind::FaceForce;
        p.excitation.faceGroup = "tip";
        p.excitation.amplitude.clear();
        p.excitation.imbalanceKgM = 2e-5;
        HarmonicSettings at;
        at.frequenciesHz = {0.7 * f1};
        const auto imbalance = solveOrDie(p, at);
        p.excitation.imbalanceKgM = 0.0;
        const double omega = 2 * M_PI * 0.7 * f1;
        p.excitation.amplitude = {{1.0, 2e-5 * omega * omega}};
        const auto equivalent = solveOrDie(p, at);
        // Two separate solves agree only to ~1e-9: Accelerate's multithreaded factorisation sums in a
        // varying order (identical with VECLIB_MAXIMUM_THREADS=1). A wrong law — U·Ω, a lost 2π —
        // would differ by orders of magnitude, so 1e-6 loses nothing.
        checkRelative(imbalance.samples[0].maxVonMisesPa, equivalent.samples[0].maxVonMisesPa, 1e-6, "an imbalance U acts as the force U·Ω²");
        p.excitation.amplitude = {{10.0, 1.0}, {100.0, 100.0}};
        at.frequenciesHz = {5.0, std::sqrt(1000.0), 400.0};
        const auto profile = solveOrDie(p, at);
        check(std::fabs(profile.samples[0].excitation - 1.0) < 1e-12 && std::fabs(profile.samples[1].excitation - 10.0) < 1e-9 &&
                  std::fabs(profile.samples[2].excitation - 100.0) < 1e-12,
              "an amplitude profile is interpolated log–log and held beyond its ends");
        auto bad = problem;
        bad.dampingRatio = -1.0;
        check(!solveHarmonic(bad).isOk(), "damping has no default: a missing ζ is refused");
        bad = problem;
        bad.constraints.clear();
        check(!solveHarmonic(bad).isOk(), "a part not fixed to the fixture is refused");
    }
    return fea_test::finish("test_fea_harmonic");
}
