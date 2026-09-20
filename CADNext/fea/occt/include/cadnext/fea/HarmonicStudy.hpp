#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/Harmonic.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// Sine vibration of a CAD solid as an Engineering Validation test (spec §6.2 Modal / Vibration): the
// part on its fixture, shaken by the table or by a rotor, swept through a frequency range. Three
// meshes, the peak dynamic stress with its discretisation uncertainty, and a verdict.
//
// Verdict (the same rules as the static study, applied to the stress amplitude at the specified
// vibration level, which plays the role of the limit load):
//   - assessStrength: yield at the level, ultimate at the level × factor of safety, WARNING when the
//     mesh band crosses zero or the stress did not converge;
//   - WARNING when the maximum sits at a fully fixed face (the singular edge of an idealised clamp);
//   - WARNING when the range reaches above the last computed mode (a resonance up there is unseen);
//   - WARNING, base excitation, when the retained modes carry less than 90 % of the mass along the
//     excitation (common practice for modal superposition; the static correction covers the
//     quasi-static share of the rest, but not their resonances);
//   - always WARNING at best because fatigue is not assessed: the material table has no endurance
//     limits, and a sustained vibration fails in fatigue at amplitudes well below yield. So this
//     version answers FAIL or WARNING, never PASS.

namespace cadnext::fea {

struct HarmonicStudySettings {
    double coarseElementSizeM = 0.0; // required, as for the static study
    double refinementFactor = 0.0;   // required, ≥ 1.3
    int modeCount = 0;               // required
    double dampingRatio = -1.0;      // required, 0 < ζ < 1
    double minimumHz = 0.0, maximumHz = 0.0;
    int sweepPoints = 200;
    // Faces are "face-<index>"; a force excitation names its face in `excitation.faceGroup`.
    HarmonicExcitation excitation;
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace; // optional
    std::vector<StressExclusion> stressExclusions;
    StrengthCriteria criteria;
};

struct HarmonicStudyLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakVonMisesPa = 0.0;  // largest over the sweep, outside exclusion zones
    double peakFrequencyHz = 0.0; // where it occurs
    Vec3 criticalPoint;
};

struct HarmonicStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    double dampingRatio = 0.0;
    std::string mesherVersion;
    double totalMassKg = 0.0;
    double attachedMassKg = 0.0;
    std::vector<HarmonicStudyLevel> levels;
    ConvergenceEstimate stressConvergence;
    StrengthAssessment assessment;
    Vec3 criticalPoint;
    std::string criticalFace;
    // Sweep and modes of the finest mesh.
    std::vector<HarmonicSample> samples;
    std::vector<double> modeFrequenciesHz;
    double effectiveMassFraction = 0.0; // NaN for force excitation
    double highestModeHz = 0.0;
    std::size_t worstSample = 0;
    std::vector<std::string> warnings;
    // Finest mesh at the worst frequency: peak von Mises over the cycle per node, and the
    // displacement at the instant the largest motion peaks.
    StructuralSurfaceField field;
};

inline constexpr const char* kHarmonicSolverID = "cadnext.fea.harmonic-tet10";

Result<HarmonicStudyResult> runHarmonicStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape,
                                             const IsotropicMaterial& material, const std::string& loadCaseName,
                                             const std::vector<FaceSupport>& supports, const HarmonicStudySettings& settings,
                                             const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
