// Climatic-test building blocks, each against an answer known exactly or from its defining source.
//
// Criteria, fixed before the first run:
//   1. Air (U.S. Standard Atmosphere 1976): μ(288.15 K) = 1.7894e-5 Pa s, k(288.15 K) = 2.5326e-2 W/(m K),
//      p(1000 m) = 8.9876e4 Pa — the Standard's own table, to its 5 digits (1e-4 relative).
//      Flat-plate correlation: switches at Re_L = 5e5 and, with that text's constants, jumps there by
//      less than 2 % (the −871 of the mixed-layer formula is rounded; a larger jump is a coding error).
//   2. MIL-STD-810H cycles: the tabulated peaks come back (A1 with sun 49 °C at 16:00, 1120 W/m² at 12–13;
//      A1 induced 160 °F; C3 −51 °C), the cycle is periodic, the day's mean irradiance is the trapezoid sum.
//   3. Shading: for a closed body the sunlit area projected on the plane normal to the rays is its
//      silhouette (each ray stops at the first surface). A "Г" profile lit from above and from below —
//      the overhang shades the step under it — to 1e-12 relative, the shadow edge lying on element edges;
//      an unshaded box lit obliquely: Σ A_i max(0, n_i·s), to 1e-12.
//   4. Periodic heat conduction: a slab, convection to air T₀ + A cos ωt on one face, the rest insulated,
//      has the exact periodic solution Θ(x) = B cosh(m(L−x)), m = (1+i)√(ω/2a), B = hA/(k m sinh mL +
//      h cosh mL). Amplitude within 0.2 % and phase within 0.2° at both faces, mean within 1 mK, after the
//      start has decayed — the scheme's own error is ~0.003 % (ωΔt = 0.017) and the mesh's smaller, so
//      the margin only catches a wrong schedule, a wrong start or a wrong load split.
//   5. Radiation in time with a schedule: a thin aluminium plate (Bi ≈ 1e-4, so lumped to ~0.01 K) under
//      a sun that rises and sets, air that warms, convection and radiation to the air, against the lumped
//      ODE integrated by RK4 at 0.1 s: within 0.05 K over two hours; and the chord method must actually
//      reuse its factorisation (fewer factorisations than steps).
//   6. Free expansion: a block rotated off the axes, held by kinematicSupports, heated uniformly and then
//      with a linear field — no stress (1e-9 of EαΔT) and no reaction; the one-factorisation series gives
//      the same stresses as separate solves (1e-10 relative).

#include "fea_test_support.hpp"

#include "cadnext/fea/AirConvection.hpp"
#include "cadnext/fea/ClimaticCycles.hpp"
#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/MeshGeneration.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <cmath>
#include <complex>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

TetMesh box(double lx, double ly, double lz, int cx, int cy, int cz, const Vec3& origin, const std::array<std::string, 6>& names) {
    MappedBlockSpec spec;
    spec.cellsU = cx;
    spec.cellsV = cy;
    spec.cellsW = cz;
    spec.mapping = [=](double u, double v, double w) { return Vec3{origin.x + u * lx, origin.y + v * ly, origin.z + w * lz}; };
    spec.faceNames = names;
    return generateMappedBlock(spec);
}

double relative(double value, double reference) {
    return std::fabs(value - reference) / std::fabs(reference);
}

} // namespace

int main() {
    // --- 1. Air.
    {
        const double mu = airViscosity(288.15), k = airConductivity(288.15), p = standardPressurePa(1000.0);
        std::printf("  air at 288.15 K: μ = %.5e Pa s, k = %.5e W/(m K); p(1000 m) = %.1f Pa\n", mu, k, p);
        check(relative(mu, 1.7894e-5) <= 1e-4 && relative(k, 2.5326e-2) <= 1e-4 && relative(p, 8.9876e4) <= 1e-4,
              "air viscosity, conductivity and pressure are the U.S. Standard Atmosphere 1976 values");
        const auto below = flatPlateForcedConvection(1.0, 1.0, 300.0, 101325.0);
        const double speedAt5e5 = 5.0e5 * airViscosity(300.0) / airProperties(300.0, 101325.0).densityKgM3;
        const auto lam = flatPlateForcedConvection(speedAt5e5 * (1.0 - 1e-9), 1.0, 300.0, 101325.0);
        const auto mixed = flatPlateForcedConvection(speedAt5e5 * (1.0 + 1e-9), 1.0, 300.0, 101325.0);
        std::printf("  flat plate: Re %.0f → h %.3f W/(m² K); at Re = 5e5 laminar Nu %.1f, mixed Nu %.1f\n", below.reynolds, below.coefficientWm2K,
                    lam.nusselt, mixed.nusselt);
        check(below.laminar && lam.laminar && !mixed.laminar && relative(mixed.nusselt, lam.nusselt) < 0.02 && mixed.inValidityRange,
              "the flat-plate correlation switches at Re = 5e5 with only the rounding jump of its constants");
    }

    // --- 2. Cycles.
    {
        const auto a1 = hotCycle(HotCategory::A1HotDry, HotExposure::Sun);
        check(std::fabs(a1.airK(16 * 3600.0) - (49.0 + 273.15)) < 1e-12 && std::fabs(a1.irradianceWm2(12.5 * 3600.0) - 1120.0) < 1e-12
                  && std::fabs(a1.airK(86400.0 + 3600.0) - a1.airK(3600.0)) < 1e-12,
              "A1 with sun: 49 °C at 16:00, 1120 W/m² at 12:30, periodic in a day");
        check(std::fabs(a1.meanIrradianceWm2() - 9270.0 / 24.0) < 1e-9, "the day's mean irradiance is the trapezoid sum of the table");
        const auto induced = hotCycle(HotCategory::A1HotDry, HotExposure::Induced);
        check(std::fabs(induced.peakAirK() - ((160.0 - 32.0) * 5.0 / 9.0 + 273.15)) < 1e-12 && induced.meanIrradianceWm2() == 0.0,
              "A1 induced: 160 °F peak, no sun on top of the induced air");
        check(coldCondition(ColdCategory::C3SevereCold, ColdExposure::Ambient).airC == -51.0
                  && coldCondition(ColdCategory::C1BasicCold, ColdExposure::Induced).airC == -33.0,
              "cold categories: the lowest value of each range");
    }

    // --- 3. Shading. "Г": base 100 × 50 × 10 mm split at x = 20 and 60, a column 20 wide up to z = 60, a top
    // plate over x = 0…60 at z = 60…70. From above the step x = 20…60 of the base lies in the plate's shadow.
    {
        const double w = 0.05;
        std::vector<TetMesh> blocks = {
            box(0.02, w, 0.01, 2, 2, 1, {0, 0, 0}, {"", "", "", "", "baseA-bottom", ""}),
            box(0.04, w, 0.01, 2, 2, 1, {0.02, 0, 0}, {"", "", "", "", "baseB-bottom", "baseB-top"}),
            box(0.04, w, 0.01, 2, 2, 1, {0.06, 0, 0}, {"", "", "", "", "baseC-bottom", "baseC-top"}),
            box(0.02, w, 0.05, 2, 2, 4, {0, 0, 0.01}, {"", "", "", "", "", ""}),
            box(0.02, w, 0.01, 2, 2, 1, {0, 0, 0.06}, {"", "", "", "", "", "topA-top"}),
            box(0.04, w, 0.01, 2, 2, 1, {0.02, 0, 0.06}, {"", "", "", "", "topB-bottom", "topB-top"}),
        };
        const TetMesh shape = mergeMeshes(blocks, 1e-9);
        Sunlight sun;
        sun.faceGroups = {"baseB-top", "baseC-top", "topA-top", "topB-top"};
        sun.towardSun = {0, 0, 1};
        sun.absorptance = 0.6;
        sun.irradianceWm2 = 1000.0;
        const auto above = solarExposure(shape, sun);
        check(above.isOk() && relative(above.value().sunlitProjectedAreaM2, 0.1 * w) <= 1e-12 && relative(above.value().shadedAreaM2, 0.04 * w) <= 1e-12
                  && relative(above.value().absorbedW, 0.6 * 1000.0 * 0.1 * w) <= 1e-12,
              "lit from above: the sunlit projection is the silhouette, the step under the overhang is in shadow",
              above.isOk() ? std::to_string(above.value().sunlitProjectedAreaM2) + " / " + std::to_string(above.value().shadedAreaM2) : above.error().message);
        sun.faceGroups = {"baseA-bottom", "baseB-bottom", "baseC-bottom", "topB-bottom"};
        sun.towardSun = {0, 0, -1};
        const auto below = solarExposure(shape, sun);
        check(below.isOk() && relative(below.value().sunlitProjectedAreaM2, 0.1 * w) <= 1e-12 && relative(below.value().shadedAreaM2, 0.04 * w) <= 1e-12,
              "lit from below: the overhang's underside is shaded by the base");

        const TetMesh block = box(0.1, 0.04, 0.02, 4, 2, 2, {0, 0, 0}, {"x0", "x1", "y0", "y1", "z0", "z1"});
        Sunlight oblique;
        oblique.towardSun = {1.0, -2.0, 3.0};
        oblique.absorptance = 1.0;
        oblique.irradianceWm2 = 1.0;
        const double n = std::sqrt(14.0);
        const double exact = 0.04 * 0.02 * 1.0 / n + 0.1 * 0.02 * 2.0 / n + 0.1 * 0.04 * 3.0 / n;
        const auto lit = solarExposure(block, oblique);
        check(lit.isOk() && relative(lit.value().sunlitProjectedAreaM2, exact) <= 1e-12 && lit.value().shadedAreaM2 == 0.0,
              "an unshaded box lit obliquely: Σ A max(0, n·s)");
    }

    // --- 4. Periodic slab.
    {
        const double L = 0.02, k = 0.2, rho = 1240.0, c = 1500.0, h = 20.0, T0 = 300.0, A = 10.0, period = 3600.0;
        const double a = k / (rho * c), omega = 2.0 * M_PI / period;
        const TetMesh slab = box(L, 0.004, 0.004, 16, 1, 1, {0, 0, 0}, {"hot", "", "", "", "", ""});
        ThermalProblem problem;
        problem.mesh = &slab;
        problem.material = {k, rho, c};
        problem.convection = {{"hot", h, T0}};
        TransientSettings settings;
        settings.stepS = 10.0;
        settings.endS = 12.0 * period;
        settings.initialK = T0;
        settings.schedule.airK = [&](double t) { return T0 + A * std::cos(omega * t); };
        const int hot = slab.nearestNode({0, 0.002, 0.002}), cold = slab.nearestNode({L, 0.002, 0.002});
        // Fourier projection over the last period (trapezoid, exact for a periodic trig signal).
        double hc = 0, hs = 0, cc = 0, cs = 0, mean = 0;
        const double lastStart = settings.endS - period;
        const auto result = solveTransientThermal(problem, settings, 1000000, [&](double t, const std::vector<double>& T) {
            if (t > lastStart + 1e-6) {
                const double w = settings.stepS * 2.0 / period;
                hc += w * (T[hot] - T0) * std::cos(omega * t), hs += w * (T[hot] - T0) * std::sin(omega * t);
                cc += w * (T[cold] - T0) * std::cos(omega * t), cs += w * (T[cold] - T0) * std::sin(omega * t);
                mean += (T[cold] - T0) * settings.stepS / period;
            }
            return true;
        });
        using C = std::complex<double>;
        const C m = C(1.0, 1.0) * std::sqrt(omega / (2.0 * a));
        const C B = h * A / (k * m * std::sinh(m * L) + h * std::cosh(m * L));
        const C thetaHot = B * std::cosh(m * L), thetaCold = B;
        const C feHot(hc, -hs), feCold(cc, -cs); // T = Re[Θ e^{iωt}] = a cos + b sin with Θ = a − i b
        auto phaseDeg = [](C z) { return std::arg(z) * 180.0 / M_PI; };
        std::printf("  slab x = 0: amplitude %.5f K (exact %.5f), phase %.3f° (exact %.3f°)\n", std::abs(feHot), std::abs(thetaHot), phaseDeg(feHot),
                    phaseDeg(thetaHot));
        std::printf("  slab x = L: amplitude %.5f K (exact %.5f), phase %.3f° (exact %.3f°), mean offset %.2e K\n", std::abs(feCold), std::abs(thetaCold),
                    phaseDeg(feCold), phaseDeg(thetaCold), mean);
        check(result.isOk() && relative(std::abs(feHot), std::abs(thetaHot)) <= 0.002 && std::fabs(phaseDeg(feHot / thetaHot)) <= 0.2
                  && relative(std::abs(feCold), std::abs(thetaCold)) <= 0.002 && std::fabs(phaseDeg(feCold / thetaCold)) <= 0.2
                  && std::fabs(mean) <= 1e-3,
              "periodic slab under a scheduled air temperature: exact amplitude and phase", result.isOk() ? "" : result.error().message);
    }

    // --- 5. Radiation, sun and air in time: a thin plate against its lumped ODE.
    {
        const double a = 0.1, t = 0.002, k = 154.0, rho = 2700.0, c = 943.0, h = 10.0, eps = 0.8, alpha = 0.6;
        const TetMesh plate = box(a, a, t, 4, 4, 1, {0, 0, 0}, {"x0", "x1", "y0", "y1", "bottom", "top"});
        ThermalProblem problem;
        problem.mesh = &plate;
        problem.material = {k, rho, c};
        for (const char* face : {"x0", "x1", "y0", "y1", "bottom", "top"}) {
            problem.convection.push_back({face, h, 300.0});
            problem.radiation.push_back({face, eps, 300.0});
        }
        problem.sunlight = Sunlight{{"top"}, {0, 0, 1}, alpha, 0.0};
        const double duration = 7200.0;
        auto air = [&](double time) { return 300.0 + 10.0 * time / duration; };
        auto sun = [&](double time) { return 1000.0 * std::sin(M_PI * time / duration); };
        TransientSettings settings;
        settings.stepS = 10.0;
        settings.endS = duration;
        settings.initialK = 300.0;
        settings.schedule.airK = air;
        settings.schedule.irradianceWm2 = sun;
        const double area = 2 * a * a + 4 * a * t, mass = rho * a * a * t;
        auto rate = [&](double time, double T) {
            const double Ta = air(time);
            return (alpha * sun(time) * a * a - h * area * (T - Ta) - eps * kStefanBoltzmann * area * (std::pow(T, 4) - std::pow(Ta, 4))) / (mass * c);
        };
        double ode = 300.0, odeTime = 0.0, worst = 0.0, peak = 0.0;
        const int centre = plate.nearestNode({a / 2, a / 2, t / 2});
        const auto result = solveTransientThermal(problem, settings, 1000000, [&](double time, const std::vector<double>& T) {
            const double dt = 0.1;
            while (odeTime < time - 1e-9) {
                const double k1 = rate(odeTime, ode), k2 = rate(odeTime + dt / 2, ode + dt / 2 * k1), k3 = rate(odeTime + dt / 2, ode + dt / 2 * k2),
                             k4 = rate(odeTime + dt, ode + dt * k3);
                ode += dt / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
                odeTime += dt;
            }
            worst = std::max(worst, std::fabs(T[centre] - ode));
            peak = std::max(peak, ode - air(time));
            return true;
        });
        const int steps = static_cast<int>(duration / settings.stepS);
        std::printf("  plate in the sun: worst |FE − ODE| %.4f K over 2 h (peak rise over air %.2f K), %d factorisations for %d steps\n", worst, peak,
                    result.isOk() ? result.value().factorisations : -1, steps);
        check(result.isOk() && worst <= 0.05, "sun, convection and radiation in time: the plate follows its lumped ODE",
              result.isOk() ? std::to_string(worst) : result.error().message);
        check(result.isOk() && result.value().factorisations < steps, "the chord method reuses its factorisation");

        ThermalProblem noSun = problem;
        noSun.sunlight.reset();
        check(!solveTransientThermal(noSun, settings, 1000000).isOk(), "an irradiance schedule without sunlight in the problem is refused");
    }

    // --- 6. Free expansion on kinematic supports.
    {
        IsotropicMaterial material = *findMaterial("al_6061_t6");
        const double E = material.youngsModulusPa, alpha = *material.thermalExpansionPerK;
        // Rotation from Euler angles, so no edge lies along an axis.
        const double p = 0.3, q = 0.5, r = 0.7;
        const double cp = std::cos(p), sp = std::sin(p), cq = std::cos(q), sq = std::sin(q), cr = std::cos(r), sr = std::sin(r);
        const std::array<Vec3, 3> R = {Vec3{cq * cr, -cq * sr, sq}, Vec3{cp * sr + sp * sq * cr, cp * cr - sp * sq * sr, -sp * cq},
                                       Vec3{sp * sr - cp * sq * cr, sp * cr + cp * sq * sr, cp * cq}};
        MappedBlockSpec spec;
        spec.cellsU = 6, spec.cellsV = 3, spec.cellsW = 2;
        spec.mapping = [&](double u, double v, double w) {
            const Vec3 x{0.1 * u, 0.04 * v, 0.02 * w};
            return Vec3{dot(R[0], x), dot(R[1], x), dot(R[2], x)};
        };
        const TetMesh block = generateMappedBlock(spec);
        LinearStaticProblem problem;
        problem.mesh = &block;
        problem.material = material;
        problem.constraints = kinematicSupports(block);
        const double dT = 60.0, scale = E * alpha * dT;
        problem.temperatureChangeK.assign(block.nodes.size(), dT);
        const auto uniform = solveLinearStatic(problem);
        check(uniform.isOk() && uniform.value().maxNodalVonMisesPa <= 1e-9 * scale && length(uniform.value().reactionForceN) <= 1e-9 * scale * 0.04 * 0.02,
              "kinematic supports: a uniformly heated body expands freely — no stress, no reaction",
              uniform.isOk() ? std::to_string(uniform.value().maxNodalVonMisesPa / scale) : uniform.error().message);
        const Vec3 gradient{120.0, -80.0, 200.0};
        problem.temperatureChangeK.clear();
        for (const auto& x : block.nodes) problem.temperatureChangeK.push_back(10.0 + dot(gradient, x));
        const auto linear = solveLinearStatic(problem);
        check(linear.isOk() && linear.value().maxNodalVonMisesPa <= 1e-9 * scale, "kinematic supports: a linear temperature field leaves the body stress-free");

        std::vector<std::vector<double>> fields(3);
        for (const auto& x : block.nodes) {
            fields[0].push_back(dT);
            fields[1].push_back(10.0 + dot(gradient, x));
            fields[2].push_back(4000.0 * dot(x, x));
        }
        double worst = 0.0, largest = 0.0;
        const auto series = solveThermoelasticSeries(problem, fields, [&](std::size_t index, const LinearStaticSolution& solution) {
            LinearStaticProblem single = problem;
            single.temperatureChangeK = fields[index];
            const auto alone = solveLinearStatic(single);
            if (!alone.isOk()) return false;
            for (std::size_t n = 0; n < block.nodes.size(); ++n) {
                worst = std::max(worst, std::fabs(solution.nodalVonMises[n] - alone.value().nodalVonMises[n]));
                largest = std::max(largest, alone.value().nodalVonMises[n]);
            }
            return true;
        });
        std::printf("  series vs separate solves: largest σ %.3f MPa, worst difference %.2e Pa\n", largest / 1e6, worst);
        check(series.isOk() && series.value() == 3 && largest > 0.0 && worst <= 1e-10 * largest, "one factorisation for a series of fields gives the separate answers");
    }
    return fea_test::finish("test_fea_climate_core");
}
