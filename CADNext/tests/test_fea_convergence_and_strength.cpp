// The Richardson/GCI estimator on sequences with known answers, and the strength verdict
// rules (CS-23.303/.305: yield at limit load, ultimate at 1.5 × limit load).

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;

int main() {
    // f(h) = 10 + 3h² on h = 0.25, 0.5, 1 → order 2, limit 10.
    {
        auto f = [](double h) { return 10.0 + 3.0 * h * h; };
        const auto estimate = estimateConvergence(f(0.25), f(0.5), f(1.0), 2.0);
        check(estimate.behaviour == ConvergenceBehaviour::Monotonic, "quadratic sequence is monotonic");
        check(std::fabs(estimate.observedOrder - 2.0) < 1e-12, "observed order recovers p = 2");
        check(std::fabs(estimate.extrapolated - 10.0) < 1e-12, "Richardson extrapolation recovers the limit");
        const double expectedGci = 1.25 * std::fabs((f(0.5) - f(0.25)) / f(0.25)) / 3.0;
        check(std::fabs(estimate.gciFineRelative - expectedGci) < 1e-15, "GCI_fine matches Celik et al. eq. (7)");
        // With relative errors (Celik eq. 7) an exact power law gives GCI32 / (r^p GCI21) = f1/f2,
        // which tends to one as the solutions approach their limit.
        check(std::fabs(estimate.asymptoticRatio - f(0.25) / f(0.5)) < 1e-12, "asymptotic ratio follows its definition");
        check(estimate.uncertaintyAbsolute >= std::fabs(f(0.25) - 10.0), "the GCI band covers the true error here");
    }
    {
        // Unstructured refinement: h = 0.2, 0.13, 0.1 (ratios 1.538 and 1.3), f = 4 − 5h^1.7.
        auto f = [](double h) { return 4.0 - 5.0 * std::pow(h, 1.7); };
        const auto estimate = estimateConvergence(f(0.1), f(0.13), f(0.2), 1.3, 0.2 / 0.13, 1.25);
        check(estimate.behaviour == ConvergenceBehaviour::Monotonic, "variable ratios: monotonic");
        check(std::fabs(estimate.observedOrder - 1.7) < 1e-9,
              "variable ratios: fixed-point iteration recovers p = 1.7 (" + std::to_string(estimate.observedOrder) + ")");
        check(std::fabs(estimate.extrapolated - 4.0) < 1e-9, "variable ratios: extrapolation recovers the limit");
    }
    check(std::fabs(representativeCellSize(8.0, 1000) - 0.2) < 1e-15, "h = (V/N)^(1/3)");
    {
        // Values from the CAD cantilever on Netgen meshes: observed p ≈ 10 for a TET10 displacement.
        const auto unbounded = estimateConvergence(0.00311681, 0.00311553, 0.00311202, 1.30, 1.13, 1.25);
        const auto bounded = estimateConvergence(0.00311681, 0.00311553, 0.00311202, 1.30, 1.13, 1.25, kTet10DisplacementOrder);
        check(unbounded.observedOrder > kTet10DisplacementOrder && !unbounded.orderLimitedToFormal,
              "unstructured sequence reports an order above the formal one");
        check(bounded.orderLimitedToFormal && bounded.uncertaintyAbsolute > 10.0 * unbounded.uncertaintyAbsolute,
              "limiting p to the formal order widens the band instead of trusting it (±"
                  + std::to_string(unbounded.gciFineRelative * 100) + "% → ±" + std::to_string(bounded.gciFineRelative * 100) + "%)");
    }
    {
        const auto estimate = estimateConvergence(10.0, 11.0, 9.5, 2.0);
        check(estimate.behaviour == ConvergenceBehaviour::Oscillatory && !estimate.isUsable(), "sign change → oscillatory, not usable");
    }
    {
        // A stress at a singularity keeps growing: 10 → 12 → 20.
        const auto estimate = estimateConvergence(20.0, 12.0, 10.0, 2.0);
        check(estimate.behaviour == ConvergenceBehaviour::Divergent && !estimate.isUsable(), "growing change → divergent, not usable");
    }
    {
        const auto estimate = estimateConvergence(5.0, 5.0, 4.0, 2.0);
        check(estimate.behaviour == ConvergenceBehaviour::Converged, "identical fine/medium → converged");
    }

    const auto aluminium = *findMaterial("al_6061_t6"); // σy 276, σu 310 MPa
    const auto steel = *findMaterial("steel_4130");     // σy 435, σu 670 MPa
    const auto carbon = *findMaterial("cfrp_quasi_isotropic");
    auto band = [](double stress, double uncertainty) {
        ConvergenceEstimate e;
        e.behaviour = ConvergenceBehaviour::Monotonic;
        e.fine = stress;
        e.uncertaintyAbsolute = uncertainty;
        return std::optional<ConvergenceEstimate>(e);
    };
    {
        const auto r = assessStrength(aluminium, 100e6, band(100e6, 1e6));
        check(r.verdict == StrengthVerdict::Pass, "6061 at 100 MPa, converged → PASS");
        check(std::fabs(*r.yieldMargin - (276.0 / 100.0 - 1.0)) < 1e-12, "yield margin = σy/σ − 1");
        check(std::fabs(r.ultimateMargin - (310.0 / 150.0 - 1.0)) < 1e-12, "ultimate margin = σu/(1.5σ) − 1");
        check(std::fabs(r.governingMargin - r.ultimateMargin) < 1e-15, "6061: ultimate at 1.5× governs");
    }
    {
        const auto r = assessStrength(aluminium, 210e6, band(210e6, 1e6));
        check(r.verdict == StrengthVerdict::Fail && r.reasons.front().find("разрушение") != std::string::npos,
              "6061 at 210 MPa: fails at ultimate load (310 < 1.5 × 210)");
    }
    {
        const auto r = assessStrength(steel, 440e6, band(440e6, 1e6));
        check(r.verdict == StrengthVerdict::Fail && r.reasons.front().find("текучесть") != std::string::npos,
              "4130 at 440 MPa: yields at limit load although 670 > 1.5 × 440");
    }
    {
        const auto r = assessStrength(aluminium, 205e6, band(205e6, 5e6));
        check(r.governingMargin > 0.0 && r.verdict == StrengthVerdict::Warning,
              "positive margin whose uncertainty band crosses zero → WARNING");
    }
    {
        const auto r = assessStrength(aluminium, 100e6, std::nullopt);
        check(r.verdict == StrengthVerdict::Warning, "no convergence study → never PASS");
    }
    {
        auto divergent = band(100e6, 1e6);
        divergent->behaviour = ConvergenceBehaviour::Divergent;
        const auto r = assessStrength(aluminium, 100e6, divergent);
        check(r.verdict == StrengthVerdict::Warning, "non-converging stress → WARNING, not a number to trust");
    }
    {
        const auto r = assessStrength(carbon, 100e6, band(100e6, 1e6));
        check(r.verdict == StrengthVerdict::Warning && !r.yieldMargin, "laminate: ultimate only, always flagged as an approximation");
    }
    for (const auto& material : materialLibrary()) {
        check(material.isValid(), "material " + material.id + " is self-consistent");
    }
    check(findMaterial("default_abs").has_value(), "CAD part default material resolves");

    return fea_test::finish("test_fea_convergence_and_strength");
}
