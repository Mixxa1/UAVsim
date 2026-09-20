// Fire-test building blocks against exact answers and their sources.
//
// Criteria, fixed before the first run:
//   1. Standard flames: ISO 2685 1373.15 K / 116 kW/m², AC 20-135 2000 °F / 9.3 BTU/(ft² s); both flame
//      models deliver exactly the calibration flux into the calorimeter at 20 °C (1e-12), and less into a
//      hotter surface, the radiative one more than the convective one there.
//   2. EN 1999-1-2 data come back as tabulated: k₀.₂ of 6061-T6 at 20/250/550 °C and linear between
//      (175 °C → 0.85); E(375 °C)/E(20 °C) = 0.47; λ(300 °C) = 211 W/(m K), c(300 °C) = 1026 J/(kg K) for
//      6061; 7075 has thermal data and no strength data.
//   3. Conduction with k(T) (the 6061 law), a bar held at 300 K and 800 K: the exact solution through the
//      Kirchhoff transform (∫k dT linear along the bar), to 1e-5 of the 500 K difference; heat balance 1e-9.
//   4. In time with c(T), k(T) and the radiative flame on one face of a 1 mm plate (the others adiabatic):
//      the lumped ODE ρ c(T) t Ṫ = ε σ (T_f⁴ − T⁴) by RK4 at 1 ms, mid-thickness temperature within 0.5 % of
//      the rise over 12 s (the plate's own non-uniformity is ~0.02 K).
//   5. Statics with E(θ) and the Eurocode expansion law, exact to 1e-9: a free body at a uniform 300 °C has
//      no stress and grows by Δ(Δl/l)·L; a bar held axially at both ends carries σ = −E(θ) Δ(Δl/l).

#include "fea_test_support.hpp"

#include "cadnext/fea/Fire.hpp"
#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/MeshGeneration.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <cmath>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

TetMesh box(double lx, double ly, double lz, int cx, int cy, int cz, const std::array<std::string, 6>& names) {
    MappedBlockSpec spec;
    spec.cellsU = cx, spec.cellsV = cy, spec.cellsW = cz;
    spec.mapping = [=](double u, double v, double w) { return Vec3{u * lx, v * ly, w * lz}; };
    spec.faceNames = names;
    return generateMappedBlock(spec);
}

double relative(double a, double b) {
    return std::fabs(a - b) / std::fabs(b);
}

} // namespace

int main() {
    // --- 1. Flames.
    {
        const auto iso = standardFlame(FireStandard::Iso2685), faa = standardFlame(FireStandard::Ac20135);
        std::printf("  ISO 2685: %.2f K, %.0f W/m², h %.3f W/(m² K), ε %.4f; AC 20-135: %.2f K, %.1f W/m²\n", iso.temperatureK, iso.calibrationFluxWm2,
                    flameConvectionCoefficient(iso), flameEmissivity(iso), faa.temperatureK, faa.calibrationFluxWm2);
        check(iso.temperatureK == 1373.15 && iso.calibrationFluxWm2 == 116e3 && std::fabs(faa.temperatureK - 1366.483333333) < 1e-6
                  && std::fabs(faa.calibrationFluxWm2 - 105615.7) < 0.1,
              "standard flames: ISO 2685 and AC 20-135 as the standards state them");
        bool calibrated = true;
        for (const auto& flame : {iso, faa})
            for (auto model : {FlameModel::Convective, FlameModel::Radiative})
                calibrated = calibrated && relative(flameHeatFlux(flame, model, kCalorimeterSurfaceK), flame.calibrationFluxWm2) <= 1e-12;
        check(calibrated, "both flame models deliver the calibration flux into the calorimeter at 20 °C");
        const double hot = 900.0;
        check(flameHeatFlux(iso, FlameModel::Radiative, hot) > flameHeatFlux(iso, FlameModel::Convective, hot)
                  && flameHeatFlux(iso, FlameModel::Convective, hot) < iso.calibrationFluxWm2,
              "into a hot surface both deliver less, the radiative limit more than the convective one");
    }

    // --- 2. Eurocode 9 data.
    {
        const auto m = hotMaterial("al_6061_t6");
        const auto m7 = hotMaterial("al_7075_t6");
        auto K = [](double c) { return c + 273.15; };
        check(m && m->proofStrengthRatio && m->proofStrengthRatio(K(20)) == 1.0 && m->proofStrengthRatio(K(250)) == 0.55
                  && std::fabs(m->proofStrengthRatio(K(175)) - 0.85) < 1e-12 && m->proofStrengthRatio(K(550)) == 0.0 && m->proofStrengthRatio(K(600)) == 0.0,
              "6061-T6 k₀.₂(θ): EN 1999-1-2 Table 1a, linear between");
        check(m && std::fabs(m->modulusRatio(K(375)) - 0.47) < 1e-12 && std::fabs(m->conductivityWmK(K(300)) - 211.0) < 1e-9
                  && std::fabs(m->specificHeatJkgK(K(300)) - 1026.0) < 1e-9,
              "E(θ) Table 2, λ(θ) and c(θ) §3.3.1");
        check(m7 && !m7->proofStrengthRatio && std::fabs(m7->conductivityWmK(K(100)) - 150.0) < 1e-9 && !hotMaterial("steel_4130"),
              "7075: thermal data (7xxx law), no strength data; no data set for a material the standard does not cover");
    }

    // --- 3. Steady conduction with k(T).
    {
        const auto m = *hotMaterial("al_6061_t6");
        const double L = 0.1, T1 = 300.0, T2 = 800.0;
        const TetMesh bar = box(L, 0.01, 0.01, 20, 1, 1, {"left", "right", "", "", "", ""});
        ThermalProblem problem;
        problem.mesh = &bar;
        problem.material.conductivityOf = m.conductivityWmK;
        problem.fixed = {{"left", T1}, {"right", T2}};
        const auto solved = solveSteadyThermal(problem);
        // ∫k dT = 0.035 u² + 190 u with u = T − 273.15, linear in x.
        auto F = [](double T) {
            const double u = T - 273.15;
            return 0.035 * u * u + 190.0 * u;
        };
        auto exact = [&](double x) {
            const double target = F(T1) + (F(T2) - F(T1)) * x / L;
            return 273.15 + (-190.0 + std::sqrt(190.0 * 190.0 + 4.0 * 0.035 * target)) / (2.0 * 0.035);
        };
        double worst = 0.0;
        if (solved.isOk())
            for (std::size_t n = 0; n < bar.nodes.size(); ++n) worst = std::max(worst, std::fabs(solved.value().temperatureK[n] - exact(bar.nodes[n].x)));
        std::printf("  k(T) bar: worst %.3e K (1e-5 of ΔT = %.3e K), %d iterations, balance %.2e\n", worst, 1e-5 * (T2 - T1),
                    solved.isOk() ? solved.value().newtonIterations : -1, solved.isOk() ? solved.value().balanceRelative : -1.0);
        check(solved.isOk() && worst <= 1e-5 * (T2 - T1) && solved.value().balanceRelative <= 1e-9, "conduction with k(T): the Kirchhoff-transform solution",
              solved.isOk() ? "" : solved.error().message);
    }

    // --- 4. In time: c(T), k(T), the radiative flame.
    {
        const auto m = *hotMaterial("al_6061_t6");
        const auto flame = standardFlame(FireStandard::Iso2685);
        const double t = 0.001;
        const TetMesh plate = box(0.02, 0.02, t, 2, 2, 1, {"", "", "", "", "bottom", "top"});
        ThermalProblem problem;
        problem.mesh = &plate;
        problem.material.densityKgM3 = m.densityKgM3;
        problem.material.conductivityOf = m.conductivityWmK;
        problem.material.specificHeatOf = m.specificHeatJkgK;
        problem.radiation = {{"top", flameEmissivity(flame), flame.temperatureK}};
        TransientSettings settings;
        settings.stepS = 0.05;
        settings.endS = 12.0;
        settings.initialK = 293.15;
        const int middle = plate.nearestNode({0.01, 0.01, t / 2});
        double ode = 293.15, odeTime = 0.0, worst = 0.0, rise = 0.0;
        const double eps = flameEmissivity(flame);
        auto rate = [&](double T) { return eps * kStefanBoltzmann * (std::pow(flame.temperatureK, 4) - std::pow(T, 4)) / (m.densityKgM3 * m.specificHeatJkgK(T) * t); };
        const auto result = solveTransientThermal(problem, settings, 1000000, [&](double time, const std::vector<double>& T) {
            const double h = 1e-3;
            while (odeTime < time - 1e-9) {
                const double k1 = rate(ode), k2 = rate(ode + h / 2 * k1), k3 = rate(ode + h / 2 * k2), k4 = rate(ode + h * k3);
                ode += h / 6 * (k1 + 2 * k2 + 2 * k3 + k4);
                odeTime += h;
            }
            worst = std::max(worst, std::fabs(T[middle] - ode));
            rise = ode - 293.15;
            return true;
        });
        std::printf("  flame on a 1 mm plate: after 12 s %.2f K (ODE), worst |FE − ODE| %.4f K, %d factorisations\n", ode, worst,
                    result.isOk() ? result.value().factorisations : -1);
        check(result.isOk() && worst <= 0.005 * rise, "c(T), k(T) and the radiative flame in time: the plate follows its lumped ODE",
              result.isOk() ? std::to_string(worst) : result.error().message);
    }

    // --- 5. Statics with E(θ) and the Eurocode expansion.
    {
        const auto hot = *hotMaterial("al_6061_t6");
        IsotropicMaterial material = *findMaterial("al_6061_t6");
        const double L = 0.1, side = 0.02, theta = 300.0 + 273.15;
        const TetMesh bar = box(L, side, side, 10, 2, 2, {"left", "right", "", "", "", ""});
        const double strain = hot.thermalStrain(theta) - hot.thermalStrain(293.15);
        const double ratio = hot.modulusRatio(theta);
        LinearStaticProblem problem;
        problem.mesh = &bar;
        problem.material = material;
        problem.constraints = kinematicSupports(bar);
        problem.thermalStrain.assign(bar.nodes.size(), strain);
        problem.elementModulusScale.assign(bar.elements.size(), ratio);
        const auto free = solveLinearStatic(problem);
        const int far = bar.nearestNode({L, side / 2, side / 2}), near = bar.nearestNode({0, side / 2, side / 2});
        const double stressScale = material.youngsModulusPa * ratio * strain;
        check(free.isOk() && free.value().maxNodalVonMisesPa <= 1e-9 * stressScale
                  && std::fabs((free.value().displacement[far].x - free.value().displacement[near].x) - strain * L) <= 1e-9 * strain * L,
              "a free body at 300 °C: no stress, grows by the Eurocode strain", free.isOk() ? "" : free.error().message);
        LinearStaticProblem held = problem;
        held.constraints = {{bar.nodesOnGroup("left"), {0.0, std::nullopt, std::nullopt}}, {bar.nodesOnGroup("right"), {0.0, std::nullopt, std::nullopt}},
                            {{bar.nearestNode({0, 0, 0})}, {0.0, 0.0, 0.0}}, {{bar.nearestNode({0, side, 0})}, {0.0, std::nullopt, 0.0}}};
        const auto clamped = solveLinearStatic(held);
        double worst = 0.0;
        if (clamped.isOk())
            for (const auto& s : clamped.value().nodalStress) worst = std::max(worst, std::fabs(s[0] + stressScale) + std::fabs(s[1]) + std::fabs(s[2]));
        std::printf("  held bar at 300 °C: σ = %.3f MPa expected (E ratio %.3f, Δε %.5f)\n", -stressScale / 1e6, ratio, strain);
        check(clamped.isOk() && worst <= 1e-9 * stressScale, "a bar held at both ends at 300 °C: σ = −E(θ)·Δ(Δl/l)");
    }
    return fea_test::finish("test_fea_fire_core");
}
