#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/BirdStrike.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// A bird into a CAD solid as an Engineering Validation test (14 CFR 25.571(e), 25.631): the part on
// its mounting, the bird's own pressure history on a chosen face, three meshes, the peak von Mises
// stress with its mesh uncertainty, and a verdict. One event, so the limit-load rules apply as they
// are and PASS is possible — as in the shock test and unlike the vibration ones.
//
// Three things about this model decide what its verdict is worth, and each is checked and said out
// loud rather than left to the reader:
//
//  1. The load is spread over the whole named face, not over the bird's footprint. The solver takes
//     a total force on a face group and distributes it as a uniform traction. When the face is
//     bigger than the bird's own frontal area the traction is diluted and the local stress comes out
//     too low. The ratio face/footprint is always reported; above 1.1 it is a warning (the mesher's
//     own area error is orders below that, so anything past a tenth is real), and above 2.0 the
//     verdict cannot stay PASS — the applied traction would then be under half the physical one, so
//     a positive margin says nothing. Below 1.0 the patch is smaller than the bird: part of the body
//     misses the face and the rest is concentrated harder than reality — conservative, so it is
//     stated but does not demote.
//
//  2. The retained modes are slower than the shock front. The shock phase lasts d/2(c₀+ku) — tens of
//     microseconds, tens of kilohertz — and no realistic modal set reaches it. Whatever is missing
//     is carried by the static correction, i.e. at its full static value; a mode whose period is
//     long against a pulse that short actually responds far less than statically, so the omission
//     over-states those modes. Stated, with the share of impulse the shock phase carries, and not
//     demoted: it errs the safe way.
//
//  3. Past yield the model stops describing the part. It is linear elastic: no plasticity, no
//     failure, no penetration, no fluid-structure coupling. A stress above yield means the answer is
//     no longer the stress — it is the statement that this part has to be tested.
//
// Verdict: assessStrength on the peak stress of the finest mesh, then demotions for a fully fixed
// face at the critical point (as everywhere else in this family), for the diluted patch above, and
// for a bird aimed at a face that is itself a rigid support — there the load goes into the fixture
// and the part barely feels it, so a positive margin says nothing about the part.

namespace cadnext::fea {

struct BirdStrikeStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    int modeCount = 0;               // required
    double dampingRatio = -1.0;      // required
    std::string impactFace;          // required — where the bird hits
    Vec3 direction{0.0, 0.0, -1.0};  // where it pushes; normalised by the solver
    BirdModel bird;                  // speed required
    std::vector<AttachedMass> attachedMasses;
    std::vector<StressExclusion> stressExclusions;
    StrengthCriteria criteria;
};

struct BirdStrikeStudyLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakVonMisesPa = 0.0;
    double peakTimeS = 0.0;
    Vec3 criticalPoint;
};

struct BirdStrikeStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    double dampingRatio = 0.0;
    std::string mesherVersion;
    double totalMassKg = 0.0;
    double attachedMassKg = 0.0;
    BirdImpact impact;
    double impactFaceAreaM2 = 0.0;
    double patchRatio = 0.0;         // face area / bird footprint
    double shockImpulseFraction = 0.0; // share of the momentum delivered in the shock phase
    double highestModeHz = 0.0;
    std::vector<BirdStrikeStudyLevel> levels;
    ConvergenceEstimate stressConvergence;
    StrengthAssessment assessment;
    Vec3 criticalPoint;
    std::string criticalFace;
    BirdStrikeSolution finest; // histories of the finest mesh (per-node arrays dropped)
    std::vector<double> modeFrequenciesHz;
    std::vector<std::string> warnings;
    StructuralSurfaceField field; // at the worst instant
};

inline constexpr const char* kBirdStrikeSolverID = "cadnext.fea.bird-tet10";

Result<BirdStrikeStudyResult> runBirdStrikeStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                                 const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                                 const BirdStrikeStudySettings& settings, const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
