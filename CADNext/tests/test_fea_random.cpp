// Random vibration verification: modal covariance (Segalman RMS von Mises) against beam theory and
// against the sine solver.
//
// Beam as in test_fea_harmonic: L = 1 m, b = 30 mm (y) × h = 20 mm (z), steel 4130, clamped at x = 0,
// base acceleration along z, 12 modes.
//
// Reference: the damped Euler–Bernoulli series of test_fea_harmonic, its mean squares integrated on a
// grid of 200 000 log-spaced points (relative spacing 1.7e-5, far below ζ) — no resonance can hide
// between points.
//
// Criteria, fixed before the first run:
//   1. Flat 0.01 g²/Hz from 5 to 150 Hz (the first two weak-plane bending modes inside), ζ = 2 %:
//      RMS tip displacement and RMS absolute tip acceleration within 1 % of the series. The sine test
//      matched the same series to 0.3 %, and the integration grid adds < 0.5 %.
//   2. RMS stress at the mid-span top surface, where the stress is uniaxial, within 2 % of
//      E·(h/2)·√∫|w″|²S df — the displacement error plus the extrapolation to the surface node.
//   3. A narrow band (±0.01 % around 8 Hz, off resonance, ζ = 0.1 %) of total power A²/2 must give, at
//      every node, RMS von Mises = sine peak over the cycle / √2 within 0.1 %: two separate code paths
//      (the sine's per-frequency peak and the covariance's quadratic form) on the same basis.
//   4. The PSD's mean square is exact for power-law segments: a +1 slope over one decade against the
//      closed form to round-off.

#include "fea_test_support.hpp"

#include "cadnext/fea/Harmonic.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/RandomVibration.hpp"

#include <cmath>
#include <complex>

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
    double zeta;
    BeamSeries(double E, double rho, int count, double dampingRatio) : zeta(dampingRatio) {
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
    // Per unit base acceleration.
    std::complex<double> response(double x, double f, bool curvature) const {
        std::complex<double> total = 0.0;
        const double w = 2.0 * M_PI * f;
        for (const auto& m : modes)
            total += -m.scale * (curvature ? m.curvature(x) : m.shape(x)) * m.gamma / std::complex<double>(m.omega * m.omega - w * w, 2 * zeta * m.omega * w);
        return total;
    }
};

} // namespace

int main() {
    const auto steel = *findMaterial("steel_4130");
    const double E = steel.youngsModulusPa, rho = steel.densityKgPerM3;

    // --- 4. Mean square of a power-law segment.
    {
        const std::vector<AmplitudePoint> slope{{10.0, 0.02}, {100.0, 0.2}}; // S = 0.002 f
        checkRelative(psdMeanSquare(slope), 0.002 * (100.0 * 100.0 - 10.0 * 10.0) / 2.0, 1e-12, "PSD mean square is exact for a power-law segment");
        const std::vector<AmplitudePoint> flat{{5.0, 0.01 * kG * kG}, {150.0, 0.01 * kG * kG}};
        checkRelative(std::sqrt(psdMeanSquare(flat)) / kG, std::sqrt(0.01 * 145.0), 1e-12, "flat 0.01 g²/Hz over 5–150 Hz is 1.204 grms");
    }

    const TetMesh mesh = beam(100, 2);
    RandomVibrationProblem problem;
    problem.mesh = &mesh;
    problem.material = steel;
    problem.constraints.push_back({mesh.nodesOnGroup("root"), {0.0, 0.0, 0.0}});
    problem.direction = {0, 0, 1};
    problem.dampingRatio = 0.02;
    problem.modeCount = 12;
    problem.probeFaceGroup = "tip";

    // --- 1, 2. Flat spectrum against the series.
    {
        const double level = 0.01 * kG * kG;
        problem.accelerationPsd = {{5.0, level}, {150.0, level}};
        const auto result = solveRandomVibration(problem);
        check(result.isOk(), "random vibration solves", result.isOk() ? "" : result.error().message);
        if (!result.isOk()) return fea_test::finish("test_fea_random");
        const auto& r = result.value();
        const BeamSeries series(E, rho, 40, 0.02);
        const int points = 200000;
        double displacement = 0.0, acceleration = 0.0, curvature = 0.0, previousD = 0.0, previousA = 0.0, previousC = 0.0, previousF = 0.0;
        const int node = mesh.nearestNode({0.5 * kLength, 0.5 * kWidth, kHeight});
        for (int i = 0; i < points; ++i) {
            const double f = 5.0 * std::pow(150.0 / 5.0, static_cast<double>(i) / (points - 1));
            const double w2 = std::pow(2.0 * M_PI * f, 2.0);
            const auto w = series.response(kLength, f, false);
            const double d = std::norm(w) * level, a = std::norm(1.0 - w2 * w) * level, c = std::norm(series.response(0.5 * kLength, f, true)) * level;
            if (i > 0) {
                displacement += 0.5 * (d + previousD) * (f - previousF);
                acceleration += 0.5 * (a + previousA) * (f - previousF);
                curvature += 0.5 * (c + previousC) * (f - previousF);
            }
            previousD = d, previousA = a, previousC = c, previousF = f;
        }
        const double stressReference = E * 0.5 * kHeight * std::sqrt(curvature);
        std::printf("  input %.4f grms, integration grid %zu points, effective mass %.2f %%\n", r.inputRmsMs2 / kG, r.frequencyHz.size(),
                    100 * r.effectiveMassFraction);
        std::printf("  tip RMS displacement %.5e m (series %.5e, %+.3f %%)\n", r.probeRmsDisplacementM, std::sqrt(displacement),
                    100 * (r.probeRmsDisplacementM / std::sqrt(displacement) - 1));
        std::printf("  tip RMS acceleration %.4f g (series %.4f g, %+.3f %%)\n", r.probeRmsAccelerationMs2 / kG, std::sqrt(acceleration) / kG,
                    100 * (r.probeRmsAccelerationMs2 / std::sqrt(acceleration) - 1));
        std::printf("  mid-span surface RMS von Mises %.4f MPa (series %.4f MPa, %+.3f %%); largest %.4f MPa at node %d; apparent frequency %.2f Hz\n",
                    r.rmsVonMisesPa[node] / 1e6, stressReference / 1e6, 100 * (r.rmsVonMisesPa[node] / stressReference - 1), r.maxRmsVonMisesPa / 1e6,
                    r.maxRmsVonMisesNode, r.criticalApparentFrequencyHz);
        checkRelative(r.probeRmsDisplacementM, std::sqrt(displacement), 0.01, "RMS tip displacement matches the damped beam series");
        checkRelative(r.probeRmsAccelerationMs2, std::sqrt(acceleration), 0.01, "RMS absolute tip acceleration matches the damped beam series");
        checkRelative(r.rmsVonMisesPa[node], stressReference, 0.02, "RMS mid-span surface stress matches E·(h/2)·√∫|w″|²S df");
        // The critical node's spectrum integrates back to its own mean square (spectrum and covariance agree).
        double m0 = 0.0;
        for (std::size_t i = 1; i < r.frequencyHz.size(); ++i)
            m0 += 0.5 * (r.criticalStressPsd[i] + r.criticalStressPsd[i - 1]) * (r.frequencyHz[i] - r.frequencyHz[i - 1]);
        checkRelative(std::sqrt(m0), r.maxRmsVonMisesPa, 1e-9, "the critical stress spectrum integrates to the node's RMS");
    }

    // --- 3. Narrow band against the sine solver, node by node.
    {
        const double f0 = 8.0, epsilon = 1e-4, amplitude = kG;
        auto narrow = problem;
        narrow.dampingRatio = 0.001;
        const double level = amplitude * amplitude / 2.0 / (2.0 * epsilon * f0);
        narrow.accelerationPsd = {{f0 * (1 - epsilon), level}, {f0 * (1 + epsilon), level}};
        const auto random = solveRandomVibration(narrow);
        HarmonicProblem sine;
        sine.mesh = &mesh;
        sine.material = steel;
        sine.constraints = problem.constraints;
        sine.excitation.direction = {0, 0, 1};
        sine.excitation.amplitude = {{1.0, amplitude}};
        sine.dampingRatio = 0.001;
        sine.modeCount = 12;
        HarmonicSettings at;
        at.frequenciesHz = {f0};
        const auto harmonic = solveHarmonic(sine, at);
        check(random.isOk() && harmonic.isOk(), "narrow band and sine both solve");
        if (random.isOk() && harmonic.isOk()) {
            double worst = 0.0;
            const auto& peaks = harmonic.value().worstVonMisesPa;
            const double scale = *std::max_element(peaks.begin(), peaks.end());
            for (std::size_t n = 0; n < peaks.size(); ++n) {
                if (peaks[n] < 1e-3 * scale) continue; // nodes at the neutral axis carry no stress to compare
                worst = std::max(worst, std::fabs(random.value().rmsVonMisesPa[n] * std::sqrt(2.0) / peaks[n] - 1.0));
            }
            std::printf("  narrow band at %.1f Hz: largest |√2·RMS / sine peak − 1| over the nodes %.2e\n", f0, worst);
            check(worst <= 1e-3, "a narrow band of power A²/2 gives RMS = sine peak / √2 at every node");
        }
    }

    auto bad = problem;
    bad.accelerationPsd = {{5.0, 1.0}};
    check(!solveRandomVibration(bad).isOk(), "a one-point spectrum has no span and is refused");
    bad = problem;
    bad.accelerationPsd = {{5.0, 1.0}, {50.0, 1.0}};
    bad.dampingRatio = -1.0;
    check(!solveRandomVibration(bad).isOk(), "damping has no default");
    return fea_test::finish("test_fea_random");
}
