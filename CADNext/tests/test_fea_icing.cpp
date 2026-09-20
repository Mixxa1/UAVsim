// Droplets that land on a part, and the water that freezes when they do.
//
// Criteria, fixed before the first run:
//   1. Similarity. Halve the droplet, double the speed and halve the body, and the inertia parameter
//      and the droplet's Reynolds number are both unchanged: the two cases must collect the same
//      water in the same places. The collection efficiency must agree to 0.2 % and the local one to
//      0.005 anywhere along the surface — this is the strongest statement available about droplet
//      dynamics without a published table to check against, and it fails at once if the drag, the
//      relaxation time or the geometry scaling is wrong anywhere.
//   2. Convergence. Halving the time step must change the collection efficiency by less than 0.5 %.
//   3. The two limits a cylinder has to obey: droplets heavy enough fly straight through the flow
//      and the body sweeps its own frontal height (E ≥ 0.85 at an inertia parameter of 100), and
//      droplets light enough follow the air around it (E ≤ 0.10 at 0.05). Nowhere may the local
//      efficiency exceed one — more water cannot arrive at a piece of surface than flew at it.
//   4. The surface balance closes to 1e-9 W/m², freezes everything when it is cold enough (and then
//      grows ice at exactly β·LWC·V/ρ, which is arithmetic, not a model), sits at exactly 0 °C when
//      it does not, and gives a freezing fraction that falls as the air warms and as more water
//      arrives.
//   5. The anti-ice flux does what it says: put it in, and the surface holds the temperature asked
//      for to 0.05 K with nothing freezing on it.
//   6. The regulation's takeoff condition is quoted, not approximated: 0.35 g/m³, 20 µm, −9 °C.

#include "fea_test_support.hpp"

#include "cadnext/fea/AirConvection.hpp"
#include "cadnext/fea/Icing.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

struct Case {
    double radius = 0.05, speed = 60.0, diameter = 20e-6;
    int trajectories = 241;
    double stepLengths = 0.002;
};

cadnext::Result<ImpingementResult> run(const Case& setup, double temperatureK = 263.15) {
    const auto flow = solvePanelFlow(circleSection(setup.radius, 360), setup.speed, 0.0, false);
    if (!flow.isOk()) return cadnext::Result<ImpingementResult>::fail(flow.error());
    IcingCondition condition;
    condition.temperatureK = temperatureK;
    condition.lwcKgM3 = 0.5e-3;
    condition.dropletDiameterM = setup.diameter;
    condition.airspeedMps = setup.speed;
    condition.durationS = 600.0;
    ImpingementSettings settings;
    settings.trajectories = setup.trajectories;
    settings.stepLengths = setup.stepLengths;
    settings.referenceLengthM = 2.0 * setup.radius;
    return solveImpingement(flow.value(), condition, settings);
}

} // namespace

int main() {
    const double viscosity = airViscosity(263.15);

    // --- 1. Similarity.
    {
        Case base;
        Case scaled;
        scaled.radius = base.radius / 2.0;
        scaled.speed = base.speed * 2.0;
        scaled.diameter = base.diameter / 2.0;
        scaled.trajectories = base.trajectories;
        const auto a = run(base), b = run(scaled);
        check(a.isOk() && b.isOk(), "both cases run", a.isOk() ? (b.isOk() ? "" : b.error().message) : a.error().message);
        if (a.isOk() && b.isOk()) {
            const double kA = inertiaParameter(base.diameter, base.speed, 2.0 * base.radius, viscosity);
            const double kB = inertiaParameter(scaled.diameter, scaled.speed, 2.0 * scaled.radius, viscosity);
            double worst = 0.0;
            for (std::size_t i = 0; i < a.value().betaPerPanel.size() && i < b.value().betaPerPanel.size(); ++i) {
                worst = std::max(worst, std::fabs(a.value().betaPerPanel[i] - b.value().betaPerPanel[i]));
            }
            std::printf("  similarity: K %.4f and %.4f, E %.5f and %.5f (%+.3f %%), worst Δβ %.2e\n", kA, kB, a.value().totalEfficiency,
                        b.value().totalEfficiency, 100.0 * (b.value().totalEfficiency / a.value().totalEfficiency - 1.0), worst);
            check(std::fabs(kA / kB - 1.0) <= 1e-12 && std::fabs(b.value().totalEfficiency / a.value().totalEfficiency - 1.0) <= 0.002 && worst <= 0.005,
                  "the same inertia parameter and the same droplet Reynolds number give the same catch");
        }
    }

    // --- 2. Convergence in the time step.
    {
        Case coarse;
        Case fine = coarse;
        fine.stepLengths = coarse.stepLengths / 2.0;
        const auto a = run(coarse), b = run(fine);
        if (a.isOk() && b.isOk()) {
            const double change = std::fabs(b.value().totalEfficiency / a.value().totalEfficiency - 1.0);
            std::printf("  step: E %.5f at %.4f lengths, %.5f at half of it (%+.3f %%)\n", a.value().totalEfficiency, coarse.stepLengths,
                        b.value().totalEfficiency, 100.0 * change);
            check(change <= 0.005, "halving the time step does not move the answer");
        }
    }

    // --- 3. The two limits.
    {
        // K = ρ_w d² V / (18 μ L): the diameter that puts a cylinder at a given K.
        auto diameterFor = [&](double k, double speed, double length) { return std::sqrt(k * 18.0 * viscosity * length / (kWaterDensityKgM3 * speed)); };
        Case heavy;
        heavy.radius = 0.05, heavy.speed = 60.0;
        heavy.diameter = diameterFor(100.0, heavy.speed, 2.0 * heavy.radius);
        Case light = heavy;
        light.diameter = diameterFor(0.05, light.speed, 2.0 * light.radius);
        const auto big = run(heavy), small = run(light);
        check(big.isOk() && small.isOk(), "both limits run");
        if (big.isOk() && small.isOk()) {
            std::printf("  limits: K = 100 (d = %.0f µm) gives E %.4f, β max %.4f; K = 0.05 (d = %.2f µm) gives E %.4f\n", heavy.diameter * 1e6,
                        big.value().totalEfficiency, big.value().maximumBeta, light.diameter * 1e6, small.value().totalEfficiency);
            check(big.value().totalEfficiency >= 0.85 && small.value().totalEfficiency <= 0.10,
                  "heavy droplets fly straight at the body and light ones follow the air around it");
            check(big.value().maximumBeta <= 1.0 + 1e-6 && small.value().maximumBeta <= 1.0 + 1e-6,
                  "no piece of surface collects more water than flew at it");
        }
    }

    // --- 4. The surface balance.
    {
        MessingerInput input;
        input.pressurePa = standardPressurePa(1000.0);
        input.airspeedMps = 60.0;
        input.localSpeedMps = 80.0;
        input.heatTransferWm2K = 250.0;
        input.impingingKgSm2 = 0.9 * 0.5e-3 * 60.0; // β·LWC·V
        const double cold = solveMessinger([&] {
            MessingerInput c = input;
            c.airTemperatureK = kMeltingPointK - 25.0;
            return c;
        }()).freezingFraction;
        MessingerInput coldInput = input;
        coldInput.airTemperatureK = kMeltingPointK - 25.0;
        const auto rime = solveMessinger(coldInput);
        MessingerInput warmInput = input;
        warmInput.airTemperatureK = kMeltingPointK - 2.0;
        const auto glaze = solveMessinger(warmInput);
        MessingerInput wetInput = warmInput;
        wetInput.impingingKgSm2 *= 4.0;
        const auto wet = solveMessinger(wetInput);
        std::printf("  balance: −25 °C gives n = %.4f at %.2f °C (ice %.3f mm/min, residual %.1e W/m²); −2 °C gives n = %.4f at %.2f °C; "
                    "four times the water gives n = %.4f\n",
                    rime.freezingFraction, rime.surfaceTemperatureK - kMeltingPointK, rime.iceGrowthMps * 60e3, rime.residualWm2, glaze.freezingFraction,
                    glaze.surfaceTemperatureK - kMeltingPointK, wet.freezingFraction);
        const double exactGrowth = (coldInput.impingingKgSm2 - rime.evaporatedKgSm2) / kRimeIceDensityKgM3;
        check(std::fabs(rime.residualWm2) <= 1e-9 && std::fabs(glaze.residualWm2) <= 1e-9 && std::fabs(wet.residualWm2) <= 1e-9,
              "the balance closes at every branch");
        check(rime.freezingFraction == 1.0 && !rime.glaze && std::fabs(rime.iceGrowthMps / exactGrowth - 1.0) <= 1e-12 && cold == 1.0,
              "cold enough: everything that lands freezes, and the ice grows by arithmetic");
        check(glaze.glaze && glaze.freezingFraction < 1.0 && glaze.freezingFraction > 0.0
                  && std::fabs(glaze.surfaceTemperatureK - kMeltingPointK) <= 1e-12,
              "warm enough: part of the water freezes and the surface sits at melting");
        check(wet.freezingFraction < glaze.freezingFraction && glaze.freezingFraction < rime.freezingFraction,
              "the freezing fraction falls as the air warms and as more water arrives");
    }

    // --- 5. The anti-ice flux.
    {
        MessingerInput input;
        input.airTemperatureK = kMeltingPointK - 15.0;
        input.pressurePa = standardPressurePa(1500.0);
        input.airspeedMps = 55.0;
        input.localSpeedMps = 70.0;
        input.heatTransferWm2K = 300.0;
        input.impingingKgSm2 = 0.8 * 0.6e-3 * 55.0;
        const double target = kMeltingPointK + 2.0;
        const double flux = antiIceHeatFluxWm2(input, target);
        MessingerInput heated = input;
        heated.surfaceHeatFluxWm2 = flux;
        const auto held = solveMessinger(heated);
        std::printf("  anti-ice: %.0f W/m² holds the surface at %.3f °C, freezing fraction %.3f (без обогрева %.2f °C, n = %.3f)\n", flux,
                    held.surfaceTemperatureK - kMeltingPointK, held.freezingFraction, solveMessinger(input).surfaceTemperatureK - kMeltingPointK,
                    solveMessinger(input).freezingFraction);
        check(flux > input.heatTransferWm2K * (target - input.airTemperatureK) * 0.5, "the flux is at least of the order the convection alone demands");
        check(std::fabs(held.surfaceTemperatureK - target) <= 0.05 && held.freezingFraction == 0.0,
              "with that flux the surface holds the temperature and nothing freezes");
    }

    // --- 6. The regulation, quoted.
    {
        const auto condition = takeoffMaximumIcing(50.0, 600.0);
        check(std::fabs(condition.lwcKgM3 - 0.35e-3) <= 1e-12 && std::fabs(condition.dropletDiameterM - 20e-6) <= 1e-15
                  && std::fabs(condition.temperatureK - (kMeltingPointK - 9.0)) <= 1e-12 && condition.source.find("Appendix C") != std::string::npos,
              "the takeoff maximum icing condition is the one the regulation states in words");
    }
    return fea_test::finish("test_fea_icing");
}
