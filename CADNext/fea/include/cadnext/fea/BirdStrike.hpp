#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Modal.hpp"

#include <string>
#include <utility>
#include <vector>

// A bird into a part (14 CFR 25.571(e) and 25.631: continued safe flight after a bird at cruise
// speed, 4 lb on the airframe and 8 lb on the empennage).
//
// The load. Above a few tens of metres a second a bird behaves as a fluid, not as a solid: the
// classical description (Wilbeck 1978; Barber, Wilbeck & Taylor's impact studies) has three phases —
// an initial shock, a decay, and a steady flow while the rest of the body is consumed:
//   - the shock pressure is the Hugoniot jump, P = ρ U_s u with U_s = c₀ + k u, the linear shock
//     relation of a water-like material;
//   - the steady pressure is the stagnation one, P = ½ρu²;
//   - the whole event carries the bird's normal momentum, m·u·sin θ, and that is imposed exactly:
//     the length of the steady phase is solved from it rather than assumed. How far that solved
//     length is from the geometric estimate L/u says how well the shape fits, and the result reports
//     both.
//
// The structure. The pressure acts on a chosen patch and the part answers through its own modes
// (the same basis as the shock solver, each modal equation integrated exactly between samples). The
// answer is linear elastic: it says how much stress the impact raises, not what tears.
//
// What this is not: no large deformation, no failure, no penetration, no fluid–structure coupling,
// no bird that slides along the surface or breaks into pieces, and no account of what a real
// substitute bird does in a real test. A structure whose stress goes past the material's ultimate
// under this model has not been shown to fail — it has been shown to need a test.

namespace cadnext::fea {

struct BirdModel {
    double massKg = 1.81;            // 4 lb, the bird of 25.571(e)
    double densityKgM3 = 950.0;      // the usual substitute-bird density
    double lengthToDiameter = 2.0;   // the standard right cylinder
    double speedMps = 0.0;           // required
    double obliquityRad = 1.5707963267948966; // 90° is head-on; the normal component is what acts
    double shockSpeedMps = 1480.0;   // c₀ of the linear Hugoniot (water)
    double shockSlope = 2.0;         // k of U_s = c₀ + k u
};

struct BirdImpact {
    double diameterM = 0.0, lengthM = 0.0, areaM2 = 0.0;
    double normalSpeedMps = 0.0;
    double hugoniotPressurePa = 0.0, steadyPressurePa = 0.0;
    double shockDurationS = 0.0, decayDurationS = 0.0, steadyDurationS = 0.0, totalDurationS = 0.0;
    double geometricDurationS = 0.0; // L/u, what the bird's own length would suggest
    double normalMomentumNs = 0.0, energyJ = 0.0;
    std::vector<std::string> warnings;

    double pressureAt(double timeS) const;
    double forceAt(double timeS) const { return pressureAt(timeS) * areaM2; }
};

Result<BirdImpact> birdImpact(const BirdModel& bird);

// The load in time: either the bird's own history, or one given point by point (for checking the
// solver against the static and the impulsive limits).
struct BirdStrikeProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints; // the part's mounting
    std::vector<AttachedMass> attachedMasses;
    std::string impactFaceGroup;   // where the bird hits
    Vec3 direction{0.0, 0.0, -1.0}; // where it pushes
    BirdModel bird;
    std::vector<std::pair<double, double>> forceHistory; // (s, N); when given, it is used instead
    double dampingRatio = -1.0; // no default
    int modeCount = 0;          // no default
    std::vector<bool> stressExcluded;
};

struct BirdStrikeSettings {
    double residualPeriods = 2.0;
    int samplesPerPeriod = 40;
    bool staticCorrection = true;
    ModalSettings modal;
};

struct BirdStrikeSolution {
    ModalSolution modal;
    BirdImpact impact;
    std::vector<double> timeS, forceN;
    std::vector<double> maxVonMisesPa;
    std::size_t worstSample = 0;
    double peakVonMisesPa = 0.0;
    double peakForceN = 0.0;
    double impulseNs = 0.0;      // what the history actually carried
    int peakNode = -1;
    std::vector<double> worstVonMisesPa;
    std::vector<Vec3> worstDisplacement;
    double highestModeHz = 0.0;
    double areaM2 = 0.0;
};

Result<BirdStrikeSolution> solveBirdStrike(const BirdStrikeProblem& problem, const BirdStrikeSettings& settings = {});

} // namespace cadnext::fea
