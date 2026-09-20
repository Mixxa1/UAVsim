#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/RandomVibration.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// Random vibration of a CAD solid as an Engineering Validation test: the part on its fixture under a
// base acceleration PSD, three meshes, the RMS von Mises (Segalman) with its mesh uncertainty, and a
// verdict on the 3σ stress.
//
// Verdict:
//   - assessStrength on 3σ = 3 × RMS von Mises — the conventional design level for a Gaussian
//     response (exceeded 0.27 % of the time by a Gaussian component; von Mises itself is not Gaussian,
//     which is why the rule is a convention to state, not a probability to quote);
//   - WARNING at a fully fixed face, for a spectrum reaching above the last computed mode, for less
//     than 90 % modal mass along the excitation — as for the sine test;
//   - always WARNING at best: fatigue is not assessed (no endurance data; a random load's damage needs
//     an S–N curve and a cycle count such as Dirlik's, which this version does not have).
//
// The field carries the 3σ stress (so its colours are utilisation at the design level) and no
// deformed shape: a random response has no single shape to draw.

namespace cadnext::fea {

struct RandomStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    int modeCount = 0;               // required
    double dampingRatio = -1.0;      // required
    Vec3 direction{0.0, 0.0, 1.0};
    std::vector<AmplitudePoint> accelerationPsd; // (m/s²)²/Hz
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace;
    std::vector<StressExclusion> stressExclusions;
    StrengthCriteria criteria;
};

struct RandomStudyLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double maxRmsVonMisesPa = 0.0;
    Vec3 criticalPoint;
};

struct RandomStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    double dampingRatio = 0.0;
    std::string mesherVersion;
    double totalMassKg = 0.0;
    double attachedMassKg = 0.0;
    std::vector<RandomStudyLevel> levels;
    ConvergenceEstimate stressConvergence; // of the RMS von Mises
    StrengthAssessment assessment;         // on 3σ
    Vec3 criticalPoint;
    std::string criticalFace;
    RandomVibrationSolution finest;        // spectra and probe of the finest mesh (per-node arrays dropped)
    std::vector<double> modeFrequenciesHz;
    std::vector<std::string> warnings;
    StructuralSurfaceField field;          // vonMisesPa = 3σ, displacement = 0
};

inline constexpr const char* kRandomSolverID = "cadnext.fea.random-tet10";

Result<RandomStudyResult> runRandomStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                         const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                         const RandomStudySettings& settings, const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
