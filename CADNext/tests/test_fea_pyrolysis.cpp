// Pyrolysis of a solid under radiant heating, against the measurements it is meant to reproduce.
//
// Case: the MaCFP-PMMA anaerobic gasification experiments of NIST — a PMMA disc (7 cm across) bonded to
// Kaowool PM insulation, heated from above in nitrogen at a nominal 25 or 50 kW/m², mass loss rate and
// back-surface temperature recorded. Data: MaCFP Condensed Phase Material Database (matl-db, MIT licence),
// PMMA/Validation_Data/NIST_Gasification_Apparatus, cited as Leventon, I.T., De Lannoye, K. (2023),
// "Experimental Measurements for Pyrolysis Model Validation — Anaerobic Gasification of PMMA Under
// External Thermal Radiation", NIST, https://doi.org/10.18434/mds2-2940. Properties: the same database's
// MaCFP_PMMA_UMD.json (the set the working group named closest to the mean of all submitted models).
//
// Boundary conditions as the dataset documents them: measured steady flux 49.3 kW/m² (r < 3.5 cm) and
// 24.7 kW/m², with the measured rise of the heater after the shutter opens (its Table 1); chamber walls at
// 14–18 °C; the sample backed by 5.72 mm of Kaowool bonded to it and four more discs (22.9 mm), then
// adiabatic; Kaowool ρ = 256 kg/m³, c = 1070 J/(kg K), λ(θ) of its Table 4. The standard does not give a
// convective coefficient (the dataset says to estimate it), so h = 10 W/(m² K) with 5 and 15 reported
// beside it.
//
// Criteria, fixed before the first run — the spread between the models submitted to MaCFP is of this order,
// and this one is simpler than they are (one dimension, the gas leaves at once, no swelling, the epoxy
// layer left out):
//   1. Numerics of the solver itself: the integrated mass loss equals the mass that left the sample
//      (1e-6 relative); halving the time step and doubling the cells moves the peak mass loss rate by
//      less than 2 %.
//   2. 50 kW/m²: peak mass loss rate within 25 % of the measured mean (27.80–29.88 g/m²s in three runs)
//      and its instant within 25 % of 336 s.
//   3. 25 kW/m²: the back-surface temperature within 25 K of the measurement at 60, 120, 180 and 240 s
//      (312.0, 355.4, 396.0, 429.0 K).
// Whatever comes out is reported as it is; a criterion that fails stays red as a record.

#include "fea_test_support.hpp"

#include "cadnext/fea/Pyrolysis.hpp"

#include <cmath>
#include <cstdio>

using namespace cadnext::fea;
using fea_test::check;

namespace {

// Kaowool PM insulation board, the dataset's Table 4 (Thermal Ceramics data sheet); between the points
// linearly, outside them the end values.
double kaowoolConductivity(double kelvin) {
    const double celsius = kelvin - 273.15;
    const double t[] = {260.0, 538.0, 816.0, 1093.0};
    const double k[] = {0.0576, 0.085, 0.125, 0.183};
    if (celsius <= t[0]) return k[0];
    for (int i = 1; i < 4; ++i)
        if (celsius <= t[i]) return k[i - 1] + (k[i] - k[i - 1]) * (celsius - t[i - 1]) / (t[i] - t[i - 1]);
    return k[3];
}

// The heater's measured rise after the shutter opens, normalised to its steady value (dataset Table 1).
double fluxFactor(double timeS, bool fifty) {
    const double edges[] = {1, 10, 60, 120, 180, 240, 300};
    const double at25[] = {0.9326, 0.9521, 0.9770, 0.9916, 0.9977, 1.0000, 1.0008};
    const double at50[] = {0.9401, 0.9598, 0.9831, 0.9946, 0.9987, 1.0000, 1.0004};
    const double* factor = fifty ? at50 : at25;
    for (int i = 0; i < 7; ++i)
        if (timeS <= edges[i]) return factor[i];
    return factor[6];
}

PyrolysisProblem gasification(double thicknessM, double steadyFluxWm2, bool fifty, double convection, int cells) {
    PyrolysisProblem problem;
    problem.material = *pyrolysisMaterial("macfp_pmma_umd");
    problem.thicknessM = thicknessM;
    problem.cells = cells;
    InertLayer kaowool;
    kaowool.thicknessM = 0.00572 + 4 * 0.00572; // bonded disc plus the four below it
    kaowool.densityKgM3 = 256.0;
    kaowool.specificHeatJkgK = 1070.0;
    kaowool.conductivityWmK = kaowoolConductivity;
    kaowool.cells = 30;
    problem.backing = {kaowool};
    problem.incidentFluxWm2 = [=](double t) { return steadyFluxWm2 * fluxFactor(t, fifty); };
    problem.convectionWm2K = convection;
    problem.gasK = 289.15;  // chamber 14–18 °C
    problem.wallK = 289.15;
    problem.initialK = 293.15;
    return problem;
}

double peakOf(const std::vector<double>& values, const std::vector<double>& time, double& when) {
    double peak = 0.0;
    for (std::size_t i = 0; i < values.size(); ++i)
        if (values[i] > peak) peak = values[i], when = time[i];
    return peak;
}

double at(const PyrolysisSolution& solution, const std::vector<double>& values, double timeS) {
    double best = 0.0, distance = 1e300;
    for (std::size_t i = 0; i < solution.timeS.size(); ++i) {
        const double d = std::fabs(solution.timeS[i] - timeS);
        if (d < distance) distance = d, best = values[i];
    }
    return best;
}

} // namespace

int main() {
    const auto pmma = pyrolysisMaterial("macfp_pmma_umd");
    check(pmma && pmma->reactions.size() == 2 && pmma->densityKgM3 == 1210.0 && std::fabs(pmma->specificHeatJkgK.at(300.0) - (8.33 * 300.0 - 1390.0)) < 1e-9
              && std::fabs(pmma->conductivityWmK.at(500.0) - (0.34 - 0.00042 * 500.0)) < 1e-12 && !pyrolysisMaterial("pla_fdm"),
          "the MaCFP PMMA property set is what its file says, and nothing is invented for a material without one");

    // --- 1. The solver's own numbers.
    {
        auto problem = gasification(0.0059, 49.3e3, true, 10.0, 200);
        PyrolysisSettings settings;
        settings.stepS = 0.1;
        settings.endS = 480.0;
        settings.saveEvery = 10;
        const auto solved = solvePyrolysis(problem, settings);
        check(solved.isOk(), "the gasification case runs", solved.isOk() ? "" : solved.error().message);
        if (!solved.isOk()) return fea_test::finish("test_fea_pyrolysis");
        const auto& s = solved.value();
        // Mass conservation: ∫MLR dt against the mass the sample actually lost.
        // Each recorded rate is the mean over its own interval, so the exact reconstruction is rate × interval.
        double integrated = 0.0;
        for (std::size_t i = 1; i < s.timeS.size(); ++i) integrated += s.massLossRateGm2s[i] / 1000.0 * (s.timeS[i] - s.timeS[i - 1]);
        const double lost = (1.0 - s.remainingMassFraction.back()) * 1210.0 * 0.0059;
        std::printf("  mass: lost %.4f kg/m², integrated MLR %.4f kg/m², difference %.2e; left %.4f %% of the sample\n", lost, integrated,
                    std::fabs(integrated - lost), 100.0 * s.remainingMassFraction.back());
        check(std::fabs(integrated - lost) <= 1e-6 * lost, "the integrated mass loss rate is the mass the sample lost");

        double whenCoarse = 0.0, whenFine = 0.0;
        const double coarse = peakOf(s.massLossRateGm2s, s.timeS, whenCoarse);
        auto fineProblem = gasification(0.0059, 49.3e3, true, 10.0, 400);
        PyrolysisSettings fineSettings = settings;
        fineSettings.stepS = 0.05;
        fineSettings.saveEvery = 20;
        const auto fine = solvePyrolysis(fineProblem, fineSettings);
        if (!fine.isOk()) std::printf("  fine run failed: %s\n", fine.error().message.c_str());
        const double finePeak = fine.isOk() ? peakOf(fine.value().massLossRateGm2s, fine.value().timeS, whenFine) : 0.0;
        std::printf("  numerics: peak %.3f g/m²s at %.0f s (200 cells, 0.1 s) vs %.3f at %.0f s (400 cells, 0.05 s), %+.2f %%\n", coarse, whenCoarse, finePeak,
                    whenFine, 100.0 * (finePeak / coarse - 1.0));
        check(fine.isOk() && std::fabs(finePeak / coarse - 1.0) <= 0.02, "halving the step and doubling the cells barely moves the peak");

        // --- 2. Against the measured mass loss rate at 50 kW/m².
        const double measuredPeak = (29.88 + 28.06 + 27.80) / 3.0, measuredWhen = (346.0 + 326.0 + 337.0) / 3.0;
        std::printf("  50 kW/m²: MLR at 60/120/180/240/300 s = %.2f / %.2f / %.2f / %.2f / %.2f g/m²s (measured ≈ 13.7 / 18.5 / 20.8 / 23.1 / 26.3)\n",
                    at(s, s.massLossRateGm2s, 60), at(s, s.massLossRateGm2s, 120), at(s, s.massLossRateGm2s, 180), at(s, s.massLossRateGm2s, 240),
                    at(s, s.massLossRateGm2s, 300));
        std::printf("  50 kW/m²: peak %.2f g/m²s at %.0f s; measured %.2f at %.0f s (%+.1f %%, %+.1f %%); surface %.0f K at the peak\n", coarse, whenCoarse,
                    measuredPeak, measuredWhen, 100.0 * (coarse / measuredPeak - 1.0), 100.0 * (whenCoarse / measuredWhen - 1.0), at(s, s.surfaceK, whenCoarse));
        check(std::fabs(coarse / measuredPeak - 1.0) <= 0.25, "peak mass loss rate within 25 % of the measurement");
        check(std::fabs(whenCoarse / measuredWhen - 1.0) <= 0.25, "the peak comes within 25 % of the measured instant");

        for (double h : {5.0, 15.0}) {
            auto sensitivity = gasification(0.0059, 49.3e3, true, h, 200);
            const auto other = solvePyrolysis(sensitivity, settings);
            double when = 0.0;
            if (other.isOk()) {
                const double peak = peakOf(other.value().massLossRateGm2s, other.value().timeS, when);
                std::printf("  sensitivity h = %.0f W/(m² K): peak %.2f g/m²s at %.0f s (%+.1f %% of the h = 10 case)\n", h, peak, when,
                            100.0 * (peak / coarse - 1.0));
            }
        }
    }

    // --- 3. Back-surface temperature at 25 kW/m² (test R1: 6.26 mm thick).
    {
        auto problem = gasification(0.00626, 24.7e3, false, 10.0, 200);
        PyrolysisSettings settings;
        settings.stepS = 0.1;
        settings.endS = 260.0;
        settings.saveEvery = 10;
        const auto solved = solvePyrolysis(problem, settings);
        check(solved.isOk(), "the 25 kW/m² case runs", solved.isOk() ? "" : solved.error().message);
        if (!solved.isOk()) return fea_test::finish("test_fea_pyrolysis");
        const auto& s = solved.value();
        const double measured[] = {312.0, 355.4, 396.0, 429.0};
        const double times[] = {60.0, 120.0, 180.0, 240.0};
        double worst = 0.0;
        for (int i = 0; i < 4; ++i) worst = std::max(worst, std::fabs(at(s, s.backOfSampleK, times[i]) - measured[i]));
        std::printf("  25 kW/m²: back face %.1f / %.1f / %.1f / %.1f K at 60/120/180/240 s (measured %.1f / %.1f / %.1f / %.1f), worst %.1f K\n",
                    at(s, s.backOfSampleK, 60), at(s, s.backOfSampleK, 120), at(s, s.backOfSampleK, 180), at(s, s.backOfSampleK, 240), measured[0], measured[1],
                    measured[2], measured[3], worst);
        check(worst <= 25.0, "the back-surface temperature within 25 K of the measurement");
    }
    return fea_test::finish("test_fea_pyrolysis");
}
