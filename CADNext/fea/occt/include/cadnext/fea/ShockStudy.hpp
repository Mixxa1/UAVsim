#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/Shock.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// Mechanical shock of a CAD solid as an Engineering Validation test: the part on its fixture under a
// base acceleration pulse, three meshes, the peak von Mises stress with its mesh uncertainty, and a
// verdict. A shock is one event, so the limit-load rules apply as they are — PASS is possible here,
// unlike the vibration tests, where fatigue is not assessed.
//
// Verdict: assessStrength on the peak stress; WARNING at a fully fixed face and for less than 90 % of
// the mass along the excitation in the retained modes (the static correction carries the quasi-static
// share of the rest, not their dynamics).

namespace cadnext::fea {

struct ShockStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    int modeCount = 0;               // required
    double dampingRatio = -1.0;      // required
    Vec3 direction{0.0, 0.0, 1.0};
    ShockPulse pulse;
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace;
    std::vector<StressExclusion> stressExclusions;
    StrengthCriteria criteria;
};

struct ShockStudyLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakVonMisesPa = 0.0;
    double peakTimeS = 0.0;
    Vec3 criticalPoint;
};

struct ShockStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    double dampingRatio = 0.0;
    std::string mesherVersion;
    double totalMassKg = 0.0;
    double attachedMassKg = 0.0;
    std::vector<ShockStudyLevel> levels;
    ConvergenceEstimate stressConvergence;
    StrengthAssessment assessment;
    Vec3 criticalPoint;
    std::string criticalFace;
    ShockSolution finest; // histories of the finest mesh (per-node arrays dropped)
    std::vector<double> modeFrequenciesHz;
    // Maximax absolute-acceleration shock response spectrum of the input, Q = 10 (ζ = 5 %), the way
    // shock specifications are written.
    std::vector<double> srsFrequencyHz, srsAccelerationMps2;
    std::vector<std::string> warnings;
    StructuralSurfaceField field; // at the worst instant
};

inline constexpr const char* kShockSolverID = "cadnext.fea.shock-tet10";

Result<ShockStudyResult> runShockStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                       const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                       const ShockStudySettings& settings, const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
