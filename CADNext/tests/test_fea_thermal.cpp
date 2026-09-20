// Heat conduction verification: exact solutions of one-dimensional problems on a bar meshed in 3D.
//
// Bar: L = 0.1 m along x, 20 × 20 mm, faces "left" (x = 0) and "right" (x = L), the sides insulated.
// k = 167 W/(m K), ρ = 2700 kg/m³, c = 896 J/(kg K) (the test's own numbers, aluminium-like).
//
// Criteria, fixed before the first run:
//   1. Two fixed temperatures (a linear field) and a fixed temperature with convection on the other
//      end: nodal temperatures within 1e-9 K of the closed form, heat balance within 1e-9 — a linear
//      field is inside the element's space, the finite-element answer has to be exact.
//   2. Uniform heat generation between two fixed ends (a parabola): exact for TET10 to 1e-9 relative.
//   3. Heat flux in at the left, radiation out at the right: the right face at (q/εσ + T_s⁴)^¼ and the
//      left at that + qL/k, within 1e-8 relative; Newton converges in fewer than 10 iterations.
//   4. In time: the bar at 300 K, the left end suddenly held at 400 K, the right insulated, against the
//      Fourier series. Backward Euler: error at Fo = 0.2 below 0.5 % of the 100 K step, and halving the
//      step divides it by 1.7–2.3 (first order); Crank–Nicolson at Fo = 0.5 within 0.1 %.
//   5. Thermoelasticity (static solver with a temperature change), exact to 1e-9 relative:
//      - a statically determinate bar heated uniformly: no stress, elongation αΔT·L;
//      - the same bar held axially at both ends: σ_xx = −EαΔT everywhere;
//      - a statically determinate body with a LINEAR temperature field: its thermal strain is compatible,
//        so no stress at all.

#include "fea_test_support.hpp"

#include "cadnext/fea/MeshGeneration.hpp"
#include "cadnext/fea/LinearStatic.hpp"
#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/Thermal.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;

namespace {

constexpr double kL = 0.1, kSide = 0.02;
constexpr double kK = 167.0, kRho = 2700.0, kC = 896.0;

TetMesh bar(int cells, ElementOrder order = ElementOrder::Quadratic) {
    MappedBlockSpec spec;
    spec.cellsU = cells;
    spec.cellsV = 2;
    spec.cellsW = 2;
    spec.order = order;
    spec.mapping = [](double u, double v, double w) { return Vec3{u * kL, v * kSide, w * kSide}; };
    spec.faceNames = {"left", "right", "", "", "", ""};
    return generateMappedBlock(spec);
}

double worstAgainst(const TetMesh& mesh, const std::vector<double>& T, const std::function<double(double)>& exact) {
    double worst = 0.0;
    for (std::size_t n = 0; n < mesh.nodes.size(); ++n) worst = std::max(worst, std::fabs(T[n] - exact(mesh.nodes[n].x)));
    return worst;
}

// Fourier series for the suddenly heated end: T = T1 + (T0 − T1) Σ 4/((2n+1)π) sin(λ_n x) exp(−λ_n² α t),
// λ_n = (2n+1)π/(2L), x measured from the heated end.
double seriesAt(double x, double t, double T0, double T1) {
    const double alpha = kK / (kRho * kC);
    double sum = 0.0;
    for (int n = 0; n < 400; ++n) {
        const double lambda = (2 * n + 1) * M_PI / (2 * kL);
        sum += 4.0 / ((2 * n + 1) * M_PI) * std::sin(lambda * x) * std::exp(-lambda * lambda * alpha * t);
    }
    return T1 + (T0 - T1) * sum;
}

} // namespace

int main() {
    ThermalProperties aluminium{kK, kRho, kC};

    // --- 1. Linear fields.
    for (const auto order : {ElementOrder::Linear, ElementOrder::Quadratic}) {
        const auto mesh = bar(10, order);
        const std::string name = order == ElementOrder::Linear ? "TET4" : "TET10";
        ThermalProblem problem;
        problem.mesh = &mesh;
        problem.material = aluminium;
        problem.fixed = {{"left", 300.0}, {"right", 400.0}};
        const auto fixedBoth = solveSteadyThermal(problem);
        check(fixedBoth.isOk() && worstAgainst(mesh, fixedBoth.value().temperatureK, [](double x) { return 300.0 + 100.0 * x / kL; }) <= 1e-9
                  && fixedBoth.value().balanceRelative <= 1e-9,
              name + ": two fixed temperatures give the exact linear field and a closed heat balance",
              fixedBoth.isOk() ? "balance " + std::to_string(fixedBoth.value().balanceRelative) : fixedBoth.error().message);
        problem.fixed = {{"left", 300.0}};
        problem.convection = {{"right", 50.0, 350.0}};
        const double q = (350.0 - 300.0) / (kL / kK + 1.0 / 50.0);
        const auto convective = solveSteadyThermal(problem);
        check(convective.isOk() && worstAgainst(mesh, convective.value().temperatureK, [&](double x) { return 300.0 + q * x / kK; }) <= 1e-9
                  && convective.value().balanceRelative <= 1e-9,
              name + ": fixed temperature and convection give the exact field and a closed heat balance",
              convective.isOk() ? "balance " + std::to_string(convective.value().balanceRelative) : convective.error().message);
    }

    // --- 2. Uniform generation.
    {
        const auto mesh = bar(10);
        ThermalProblem problem;
        problem.mesh = &mesh;
        problem.material = aluminium;
        problem.fixed = {{"left", 300.0}, {"right", 300.0}};
        problem.volumetricHeatWm3 = 5e7;
        const auto result = solveSteadyThermal(problem);
        const double peak = 5e7 * kL * kL / (8 * kK);
        const double worst = result.isOk() ? worstAgainst(mesh, result.value().temperatureK, [](double x) { return 300.0 + 5e7 * x * (kL - x) / (2 * kK); }) : 1.0;
        std::printf("  generation: peak rise %.4f K, largest error %.2e K, balance %.1e\n", peak, worst,
                    result.isOk() ? result.value().balanceRelative : 1.0);
        check(result.isOk() && worst <= 1e-9 * peak && result.value().balanceRelative <= 1e-9,
              "TET10: uniform generation gives the exact parabola and a closed heat balance");
    }

    // --- 3. Flux in, radiation out.
    {
        const auto mesh = bar(10);
        ThermalProblem problem;
        problem.mesh = &mesh;
        problem.material = aluminium;
        problem.fluxes = {{"left", 2000.0}};
        problem.radiation = {{"right", 0.8, 250.0}};
        const auto result = solveSteadyThermal(problem);
        const double right = std::pow(2000.0 / (0.8 * kStefanBoltzmann) + std::pow(250.0, 4), 0.25);
        const double left = right + 2000.0 * kL / kK;
        const double worst = result.isOk() ? worstAgainst(mesh, result.value().temperatureK, [&](double x) { return left - 2000.0 * x / kK; }) : 1.0;
        std::printf("  radiation: right face %.6f K (exact %.6f), %d Newton iterations, balance %.1e\n",
                    result.isOk() ? result.value().minimumK : 0.0, right, result.isOk() ? result.value().newtonIterations : 0,
                    result.isOk() ? result.value().balanceRelative : 1.0);
        check(result.isOk() && worst <= 1e-8 * right && result.value().newtonIterations < 10,
              "radiation: equilibrium temperature matches (q/εσ + T_s⁴)^¼ and Newton converges quickly");
    }

    // --- 4. In time.
    {
        const auto mesh = bar(40);
        ThermalProblem problem;
        problem.mesh = &mesh;
        problem.material = aluminium;
        problem.fixed = {{"left", 400.0}};
        const double alpha = kK / (kRho * kC);
        const double fo02 = 0.2 * kL * kL / alpha, fo05 = 0.5 * kL * kL / alpha;
        auto errorAt = [&](double theta, double dt, double time) {
            TransientSettings settings;
            settings.stepS = dt;
            settings.endS = time;
            settings.theta = theta;
            settings.initialK = 300.0;
            const auto result = solveTransientThermal(problem, settings, 1000000);
            if (!result.isOk()) return 1.0;
            const auto& last = result.value().temperatureK.back();
            return worstAgainst(mesh, last, [&](double x) { return seriesAt(x, result.value().timeS.back(), 300.0, 400.0); }) / 100.0;
        };
        const double coarse = errorAt(1.0, fo02 / 50, fo02), fine = errorAt(1.0, fo02 / 100, fo02);
        std::printf("  backward Euler at Fo = 0.2: error %.3e (50 steps), %.3e (100 steps), ratio %.2f\n", coarse, fine, coarse / fine);
        check(coarse <= 0.005 && coarse / fine > 1.7 && coarse / fine < 2.3, "backward Euler: accurate and first order in time");
        const double crank = errorAt(0.5, fo05 / 100, fo05);
        std::printf("  Crank–Nicolson at Fo = 0.5: error %.3e (100 steps)\n", crank);
        check(crank <= 0.001, "Crank–Nicolson: within 0.1 % once the start has damped out");
    }

    // --- 5. Thermoelasticity.
    {
        const auto mesh = bar(10);
        IsotropicMaterial material = *findMaterial("al_6061_t6");
        material.thermalExpansionPerK = 23e-6; // the test's own number
        const double E = material.youngsModulusPa, a = *material.thermalExpansionPerK, dT = 80.0;
        // 3-2-1: the corner at the origin fixed, the far corner on x held in y and z, a corner on y held in z.
        const int origin = mesh.nearestNode({0, 0, 0}), far = mesh.nearestNode({kL, 0, 0}), side = mesh.nearestNode({0, kSide, 0});
        LinearStaticProblem problem;
        problem.mesh = &mesh;
        problem.material = material;
        problem.constraints = {{{origin}, {0.0, 0.0, 0.0}}, {{far}, {std::nullopt, 0.0, 0.0}}, {{side}, {std::nullopt, std::nullopt, 0.0}}};
        problem.temperatureChangeK.assign(mesh.nodes.size(), dT);
        auto free = solveLinearStatic(problem);
        check(free.isOk() && free.value().maxNodalVonMisesPa <= 1e-9 * E * a * dT
                  && std::fabs(free.value().displacement[far].x - a * dT * kL) <= 1e-9 * a * dT * kL,
              "a free bar heated uniformly: no stress, elongation αΔT·L", free.isOk() ? std::to_string(free.value().maxNodalVonMisesPa) : free.error().message);

        // Held axially at both ends (x only), the rest as before.
        LinearStaticProblem held = problem;
        held.constraints = {{mesh.nodesOnGroup("left"), {0.0, std::nullopt, std::nullopt}}, {mesh.nodesOnGroup("right"), {0.0, std::nullopt, std::nullopt}},
                            {{origin}, {0.0, 0.0, 0.0}}, {{side}, {0.0, std::nullopt, 0.0}}};
        const auto clamped = solveLinearStatic(held);
        double worst = 0.0;
        if (clamped.isOk())
            for (const auto& s : clamped.value().nodalStress) worst = std::max(worst, std::fabs(s[0] + E * a * dT) + std::fabs(s[1]) + std::fabs(s[2]));
        check(clamped.isOk() && worst <= 1e-9 * E * a * dT, "a bar held at both ends: σ_xx = −EαΔT, no lateral stress",
              clamped.isOk() ? std::to_string(worst / (E * a * dT)) : clamped.error().message);

        // Linear temperature across the bar (along y) on a free body: compatible, stress-free.
        problem.temperatureChangeK.clear();
        for (const auto& node : mesh.nodes) problem.temperatureChangeK.push_back(20.0 + 3000.0 * node.y);
        const auto gradient = solveLinearStatic(problem);
        check(gradient.isOk() && gradient.value().maxNodalVonMisesPa <= 1e-9 * E * a * 80.0,
              "a free body with a linear temperature field stays stress-free",
              gradient.isOk() ? std::to_string(gradient.value().maxNodalVonMisesPa) : gradient.error().message);

        IsotropicMaterial unknown = material;
        unknown.thermalExpansionPerK.reset();
        problem.material = unknown;
        check(!solveLinearStatic(problem).isOk(), "a material without an expansion coefficient is refused for a thermal load");
    }

    // Refusals.
    {
        const auto mesh = bar(4);
        ThermalProblem problem;
        problem.mesh = &mesh;
        problem.material = {0.0, kRho, kC};
        problem.fixed = {{"left", 300.0}};
        check(!solveSteadyThermal(problem).isOk(), "a material without conductivity is refused, not guessed");
        problem.material = aluminium;
        problem.fixed.clear();
        problem.fluxes = {{"left", 100.0}};
        check(!solveSteadyThermal(problem).isOk(), "heat with nowhere to go (no fixed face, convection or radiation) is refused");
    }
    return fea_test::finish("test_fea_thermal");
}
