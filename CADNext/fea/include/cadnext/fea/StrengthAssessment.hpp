#pragma once

#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/Material.hpp"

#include <optional>
#include <string>
#include <vector>

// Verdict on one structural load case (spec §6.1: safety factor → PASS/WARNING/FAIL).
//
// The criteria are the airworthiness ones, not invented thresholds:
//  - limit load (the largest load expected in service): no permanent deformation, i.e. stress
//    below yield — CS-23.305(a);
//  - ultimate load = limit load × factor of safety 1.5 (CS-23.303; STANAG 4671 USAR.303 for
//    UAVs): no failure, i.e. stress below ultimate strength — CS-23.305(b).
// A linear analysis at limit load answers both, because stress scales with load.
//
// WARNING has no tuning knob either. It means the result cannot honestly be called PASS:
// the margin is positive but the mesh uncertainty band reaches below zero, the uncertainty
// was never estimated, the stress did not converge, or the material is an isotropic stand-in
// for an anisotropic one.

namespace cadnext::fea {

enum class StrengthVerdict {
    Pass,
    Warning,
    Fail,
};

struct StrengthCriteria {
    double factorOfSafety = 1.5;
};

struct StrengthAssessment {
    StrengthVerdict verdict = StrengthVerdict::Warning;
    double limitStressPa = 0.0;
    std::optional<double> limitStressUncertaintyPa;
    // Margin of safety MS = allowable / applied − 1; absent when the material has no yield.
    std::optional<double> yieldMargin;
    double ultimateMargin = 0.0;
    double governingMargin = 0.0;
    // Governing margin re-evaluated at stress + uncertainty; absent without an estimate.
    std::optional<double> conservativeMargin;
    // Reserve factor in the spec's sense (§11 "Safety factor: 1.84"): allowable / applied at
    // limit load for the governing criterion, factor of safety included.
    double reserveFactor = 0.0;
    std::vector<std::string> reasons;
};

// `convergence` is the refinement study of the same stress quantity, if one was run; its
// fine value must be `limitStressPa`.
StrengthAssessment assessStrength(const IsotropicMaterial& material, double limitStressPa,
                                  const std::optional<ConvergenceEstimate>& convergence,
                                  const StrengthCriteria& criteria = {});

const char* verdictName(StrengthVerdict verdict);

} // namespace cadnext::fea
