// The lightning environment and what the current does inside the metal, against closed-form answers and
// the standard's own numbers.
//
// Criteria, fixed before the first run:
//   1. SAE ARP5412 waveforms: component A gives 200 kA within its ±10 % and ∫i² dt = 2·10⁶ A² s within its
//      ±20 %; D gives 100 kA and 0.25·10⁶ A² s the same way; B carries 10 C ±10 % and averages 2 kA over its
//      first 5 ms; C carries 200 C ±20 %. (The coefficients of the double exponentials are the published
//      ones; this is the check that they are the standard's waveforms.)
//   2. Arc attachment: q = 10 I/πR² for an anode and 24 I/πR² for a cathode (ONERA AL05-09), to round-off.
//   3. Current spreading in a bar: the potential is linear, so the finite elements are exact — the
//      resistance is ρL/A and the Joule heat ρ_e J² in every element, to 1e-9 relative; the current that
//      goes in comes out (the solver's own balance) to 1e-9.
//   4. Energy identity on a part that spreads the current unevenly (a block fed through a small patch):
//      ∫σ|∇φ|² dV = I²R to 1e-6 — the Joule heat of the field is the resistance it implies.
//   5. Joule heating in time: an insulated bar under a constant current density for 500 µs warms by
//      ρ_e J² t/(ρ c) exactly (1e-9 relative), the thermal solver taking the Joule heat per element.

#include "fea_test_support.hpp"

#include "cadnext/fea/Lightning.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/MeshGeneration.hpp"
#include "cadnext/fea/TetElement.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <cmath>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

TetMesh box(double lx, double ly, double lz, int cx, int cy, int cz, const std::array<std::string, 6>& names, const Vec3& origin = {}) {
    MappedBlockSpec spec;
    spec.cellsU = cx, spec.cellsV = cy, spec.cellsW = cz;
    spec.mapping = [=](double u, double v, double w) { return Vec3{origin.x + u * lx, origin.y + v * ly, origin.z + w * lz}; };
    spec.faceNames = names;
    return generateMappedBlock(spec);
}

double relative(double value, double reference) {
    return std::fabs(value - reference) / std::fabs(reference);
}

} // namespace

int main() {
    // --- 1. The standard's waveforms.
    {
        const auto a = lightningComponent(LightningComponent::A), b = lightningComponent(LightningComponent::B);
        const auto c = lightningComponent(LightningComponent::C), d = lightningComponent(LightningComponent::D);
        // Component B's first 5 ms carry its charge: ∫i dt over them, over the 5 ms.
        double chargeOfB = 0.0;
        const double step = 1e-6;
        for (double t = 0.5 * step; t < 5e-3; t += step) chargeOfB += b.at(t) * step;
        std::printf("  A: peak %.1f kA, ∫i²dt %.3f MA²s, %.1f C; D: %.1f kA, %.3f MA²s; B: %.2f C, mean over 5 ms %.0f A; C: %.0f C\n", a.peakA() / 1e3,
                    a.actionIntegralA2s() / 1e6, a.chargeC(), d.peakA() / 1e3, d.actionIntegralA2s() / 1e6, b.chargeC(), chargeOfB / 5e-3, c.chargeC());
        check(relative(a.peakA(), 200e3) <= 0.10 && relative(a.actionIntegralA2s(), 2e6) <= 0.20, "component A: 200 kA and 2·10⁶ A²s within the standard's bands");
        check(relative(d.peakA(), 100e3) <= 0.10 && relative(d.actionIntegralA2s(), 0.25e6) <= 0.20, "component D: 100 kA and 0.25·10⁶ A²s");
        check(relative(b.chargeC(), 10.0) <= 0.10 && relative(chargeOfB / 5e-3, 2000.0) <= 0.10, "component B: 10 C and 2 kA averaged over 5 ms");
        check(relative(c.chargeC(), 200.0) <= 0.20 && c.peakA() >= 200.0 && c.peakA() <= 800.0, "component C: 200 C at a current inside the standard's range");
    }

    // --- 2. The arc's heat flux.
    {
        const double current = 400.0, radius = 0.005;
        const double density = current / (M_PI * radius * radius);
        check(relative(arcHeatFluxWm2(current, radius, ArcPolarity::Anode), 10.0 * density) <= 1e-12
                  && relative(arcHeatFluxWm2(current, radius, ArcPolarity::Cathode), 24.0 * density) <= 1e-12 && arcHeatFluxWm2(current, 0.0, ArcPolarity::Anode) == 0.0,
              "arc attachment: q = 10 J for an anode, 24 J for a cathode");
    }

    const auto aluminium = *findMaterial("al_6061_t6");
    check(aluminium.electricalResistivityOhmM && relative(*aluminium.electricalResistivityOhmM, 1.7241e-8 / 0.43) <= 1e-12
              && !findMaterial("cfrp_quasi_isotropic")->electricalResistivityOhmM,
          "the resistivity of 6061-T6 is its 43 % IACS, and a material without a sourced value has none");

    // --- 3. A bar: the exact answers.
    {
        const double L = 0.1, side = 0.02, current = 1000.0;
        const double resistivity = *aluminium.electricalResistivityOhmM;
        const TetMesh bar = box(L, side, side, 10, 2, 2, {"in", "out", "", "", "", ""});
        const auto spread = solveCurrentSpread(bar, resistivity, {"in"}, {"out"}, current);
        check(spread.isOk(), "the bar's current spread solves", spread.isOk() ? "" : spread.error().message);
        if (spread.isOk()) {
            const double exact = resistivity * L / (side * side);
            const double J = current / (side * side);
            double worst = 0.0;
            for (double q : spread.value().jouleWm3) worst = std::max(worst, relative(q, resistivity * J * J));
            std::printf("  bar: R %.6e Ω (exact %.6e, %+.2e), Joule %.6e W/m³ worst deviation %.2e, balance %.2e\n", spread.value().resistanceOhm, exact,
                        relative(spread.value().resistanceOhm, exact), resistivity * J * J, worst, spread.value().balanceRelative);
            check(relative(spread.value().resistanceOhm, exact) <= 1e-9 && worst <= 1e-9 && spread.value().balanceRelative <= 1e-9,
                  "bar: R = ρL/A, the Joule heat ρ_e J² everywhere, the current balances");
        }
    }

    // --- 4. A block fed through a small patch: the energy identity.
    {
        const double resistivity = *aluminium.electricalResistivityOhmM, current = 1000.0;
        // The patch is the top face of a small block sitting on a wide one: one mesh, two blocks merged.
        std::vector<TetMesh> parts = {box(0.08, 0.08, 0.02, 8, 8, 2, {"", "", "", "", "ground", ""}),
                                      box(0.01, 0.01, 0.01, 2, 2, 2, {"", "", "", "", "", "patch"}, {0.035, 0.035, 0.02})};
        const TetMesh block = mergeMeshes(parts, 1e-9);
        const auto spread = solveCurrentSpread(block, resistivity, {"patch"}, {"ground"}, current);
        check(spread.isOk(), "the block's current spread solves", spread.isOk() ? "" : spread.error().message);
        if (spread.isOk()) {
            double power = 0.0;
            for (std::size_t e = 0; e < block.elements.size(); ++e) power += spread.value().jouleWm3[e] * tetVolume(block, static_cast<int>(e));
            const double implied = current * current * spread.value().resistanceOhm;
            std::printf("  block through a patch: R %.4e Ω, ∫σ|∇φ|²dV %.6f W, I²R %.6f W, difference %.2e\n", spread.value().resistanceOhm, power, implied,
                        relative(power, implied));
            check(relative(power, implied) <= 1e-6, "the Joule heat of the field is the resistance it implies");
        }
    }

    // --- 5. Joule heating in time.
    {
        const double L = 0.05, side = 0.01, current = 5000.0, duration = 500e-6;
        const double resistivity = *aluminium.electricalResistivityOhmM;
        const TetMesh bar = box(L, side, side, 6, 2, 2, {"in", "out", "", "", "", ""});
        const auto spread = solveCurrentSpread(bar, resistivity, {"in"}, {"out"}, current);
        if (!spread.isOk()) return fea_test::finish("test_fea_lightning");
        ThermalProblem problem;
        problem.mesh = &bar;
        problem.material = {*aluminium.thermalConductivityWmK, aluminium.densityKgPerM3, *aluminium.specificHeatJkgK};
        problem.volumetricHeatPerElementWm3 = spread.value().jouleWm3;
        problem.fixed.clear(); // every face insulated: the bar only warms
        TransientSettings settings;
        settings.stepS = duration / 20.0;
        settings.endS = duration;
        settings.initialK = 293.15;
        const auto heated = solveTransientThermal(problem, settings, 1000000);
        const double J = current / (side * side);
        const double exact = resistivity * J * J * duration / (aluminium.densityKgPerM3 * *aluminium.specificHeatJkgK);
        double worst = 0.0;
        if (heated.isOk())
            for (double T : heated.value().temperatureK.back()) worst = std::max(worst, std::fabs(T - 293.15 - exact));
        std::printf("  Joule heating: ΔT %.6f K (exact %.6f K), worst node %.2e K\n", heated.isOk() ? heated.value().maximumK.back() - 293.15 : NAN, exact, worst);
        check(heated.isOk() && worst <= 1e-9 * exact, "an insulated bar warms by ρ_e J² t/(ρ c)", heated.isOk() ? "" : heated.error().message);
    }
    return fea_test::finish("test_fea_lightning");
}
