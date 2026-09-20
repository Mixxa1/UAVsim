#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Aeroelasticity.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// Flutter of a CAD lifting surface (14 CFR 25.629 / CS 23.629: free of flutter to 1.15 V_D).
//
// The chain: the part's own modes come from the finite elements (mass-normalised, so the generalized
// mass is one and the generalized stiffness is the squared frequency); each mode is read along the
// span as a plunge and a twist of each section about that section's centroid; the air on each strip
// is Theodorsen's, integrated against the modes into a 2 × 2 generalized aerodynamic matrix; and the
// p-k method follows the two branches until one of them stops being damped.
//
// Which two modes: the pair that flutters classically is the first bending and the first torsion, and
// the study picks them by how much plunge and how much twist each mode carries. A part whose modes do
// not separate that way is refused rather than guessed at.
//
// What this does not do, and says so in the result:
//   - strip theory: each section sees the air as if it were a two-dimensional wing of infinite span,
//     so sweep, taper's induced effects, the tip and the finite aspect ratio are all missing. On a
//     straight wing of moderate aspect ratio this is the classical preliminary method and it is
//     conservative more often than not; on a short, swept or low-aspect-ratio surface it is not
//     evidence of anything;
//   - incompressible: Theodorsen's aerodynamics have no Mach number in them. Above about Mach 0.6 the
//     transonic dip decides a real flutter speed and this method cannot see it;
//   - two modes only. A control surface, a store, an engine or a third mode close in frequency can
//     flutter with the ones here, and none of them is in the model;
//   - no structural damping unless it is given, and no aerodynamic damping of the fuselage or the
//     mounting.

namespace cadnext::fea {

struct FlutterStudySettings {
    double coarseElementSizeM = 0.0;  // required
    double refinementFactor = 0.0;    // required, ≥ 1.3
    int flowAxis = 0;                 // the direction of flight
    int spanAxis = 1;
    int stations = 12;                // strips along the span
    double airDensityKgM3 = 1.225;
    double structuralDamping = 0.0;
    double diveSpeedMps = 0.0;        // V_D: the speed the regulation measures the margin from
    double marginFactor = 1.15;       // 14 CFR 25.629(b)(2)
    double lowSpeedMps = 5.0, highSpeedMps = 300.0;
    int speeds = 300;
    std::vector<FaceSupport> supports; // the root; a part without any is analysed free–free
};

struct FlutterStrip {
    double spanPositionM = 0.0;
    double chordM = 0.0, semichordM = 0.0;
    double elasticAxis = 0.0;     // the section's centroid, in semichords from mid-chord
    double widthM = 0.0;
    double plunge[2] = {0.0, 0.0}; // each mode's plunge here, metres per unit modal amplitude
    double twist[2] = {0.0, 0.0};  // and its twist, radians per unit modal amplitude
};

struct FlutterLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double bendingHz = 0.0, torsionHz = 0.0;
    double flutterSpeedMps = 0.0;
    double flutterFrequencyHz = 0.0;
};

struct FlutterStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion;
    double bendingHz = 0.0, torsionHz = 0.0;
    int bendingMode = -1, torsionMode = -1;
    double flutterSpeedMps = 0.0, flutterFrequencyHz = 0.0, flutterUncertaintyMps = 0.0;
    bool flutterFound = false;
    double divergenceSpeedMps = 0.0;
    double requiredSpeedMps = 0.0;  // marginFactor · V_D
    double marginFraction = 0.0;    // V_F / (marginFactor · V_D) − 1
    double spanM = 0.0, referenceSemichordM = 0.0;
    double machAtFlutter = 0.0;
    std::vector<FlutterStrip> strips;
    std::vector<FlutterPoint> branches;
    std::vector<FlutterLevel> levels;
    ConvergenceEstimate speedConvergence;
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons, reasons, warnings;
    StructuralSurfaceField field;     // geometry only
    std::vector<double> fieldBending, fieldTorsion; // the two mode shapes on the surface, normalised
};

inline constexpr const char* kFlutterSolverID = "cadnext.fea.flutter-pk";

Result<FlutterStudyResult> runFlutterStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                           const std::string& loadCaseName, const FlutterStudySettings& settings,
                                           const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
