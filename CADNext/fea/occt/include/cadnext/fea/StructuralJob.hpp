#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/ClimateStudy.hpp"
#include "cadnext/fea/FireStudy.hpp"
#include "cadnext/fea/EmcStudy.hpp"
#include "cadnext/fea/FlutterStudy.hpp"
#include "cadnext/fea/IcingStudy.hpp"
#include "cadnext/fea/LightningStudy.hpp"
#include "cadnext/fea/HarmonicStudy.hpp"
#include "cadnext/fea/ModalStudy.hpp"
#include "cadnext/fea/RandomStudy.hpp"
#include "cadnext/fea/BirdStrikeStudy.hpp"
#include "cadnext/fea/ShockStudy.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>

// File contract between the Workbench (Swift) and the structural solver (this library and the
// `cadnext_structural` command line tool).
//
//   job    "cadnext-structural-job/1"     what to calculate; "analysis" is "static" (default),
//                                         "modal", "harmonic" (sine vibration), "random" (PSD) or
//                                         "shock" (base acceleration pulse) or "climate" (MIL-STD-810H
//                                         temperature, with sun, the part's own heat and thermal stress)
//                                         or "fire" (ISO 2685 / AC 20-135 flame: integrity, strength when
//                                         hot, the equipment's function) or "lightning" (ARP5412 current
//                                         through the part: spread, arc heat, burn-through) or "emc" or
//                                         "icing" or "flutter" or "bird" (14 CFR 25.571(e): the bird's
//                                         own pressure history on a face of the part)
//   result "cadnext-structural-result/1"  static: what the solver concluded — the solver half of
//                                         an Engineering Validation TestRecord (spec §4); the
//                                         Validation Engine stamps inputs and upstream on it
//          "cadnext-modal-result/1"       modal: the same envelope (outcome, metrics, warnings,
//                                         settings, fieldRef) plus modes and resonance findings
//          "cadnext-harmonic-result/1"    harmonic: the same envelope plus the response over the
//                                         sweep, the modes used and the mesh study
//          "cadnext-random-result/1"      random: the same envelope plus the spectra (input, probe,
//                                         critical stress), the modes and the mesh study
//          "cadnext-shock-result/1"       shock: the same envelope plus the time histories, the
//                                         input's shock response spectrum and the mesh study
//          "cadnext-climate-result/1"     climate: the same envelope plus the environment, the heat
//                                         exchange, the day's temperatures, the equipment against its
//                                         limits, the thermal stress and the mesh study
//          "cadnext-fire-result/1"        fire: the same envelope plus the flame, the integrity (time of
//                                         its loss), the strength when hot, the equipment, the histories
//          "cadnext-bird-result/1"        bird: the same envelope plus the bird's load (its phases and
//                                         pressures), the time histories and the mesh study
//   field  "cadnext-structural-field/1"   surface displacement and stress for display
//          "cadnext-modal-field/1"        surface mode shapes for display
//   harmonic results use the structural field (utilisation of the peak dynamic stress at the
//   worst frequency) with a "vibration" block naming that frequency
//
// Examples live in CADNext/fea/schema/. Both sides are tested against those files, so a key
// renamed on one side fails a test on the other.

namespace cadnext::fea {

inline constexpr const char* kStructuralJobSchema = "cadnext-structural-job/1";
inline constexpr const char* kStructuralResultSchema = "cadnext-structural-result/1";
inline constexpr const char* kStructuralFieldSchema = "cadnext-structural-field/1";
inline constexpr const char* kModalResultSchema = "cadnext-modal-result/1";
inline constexpr const char* kModalFieldSchema = "cadnext-modal-field/1";
inline constexpr const char* kHarmonicResultSchema = "cadnext-harmonic-result/1";
inline constexpr const char* kRandomResultSchema = "cadnext-random-result/1";
inline constexpr const char* kShockResultSchema = "cadnext-shock-result/1";
inline constexpr const char* kClimateResultSchema = "cadnext-climate-result/1";
inline constexpr const char* kFireResultSchema = "cadnext-fire-result/1";
inline constexpr const char* kLightningResultSchema = "cadnext-lightning-result/1";
inline constexpr const char* kEmcResultSchema = "cadnext-emc-result/1";
inline constexpr const char* kIcingResultSchema = "cadnext-icing-result/1";
inline constexpr const char* kFlutterResultSchema = "cadnext-flutter-result/1";
inline constexpr const char* kBirdResultSchema = "cadnext-bird-result/1";

enum class StructuralAnalysis { Static, Modal, Harmonic, Random, Shock, Climate, Fire, Lightning, Emc, Icing, Flutter, Bird };

// Flutter: {"flowAxis": "x" | "y" | "z", "spanAxis": …, "stations", "airDensityKgM3",
// "structuralDamping", "diveSpeedMps", "marginFactor" (1.15 by 14 CFR 25.629), "lowSpeedMps",
// "highSpeedMps", "speeds"}. The load case's supports are the root; its loads are not used.
struct FlutterJobSettings {
    int flowAxis = 0, spanAxis = 1;
    int stations = 12;
    double airDensityKgM3 = 1.225;
    double structuralDamping = 0.0;
    double diveSpeedMps = 0.0;
    double marginFactor = 1.15;
    double lowSpeedMps = 5.0, highSpeedMps = 300.0;
    int speeds = 300;
};

// Icing: {"flowAxis": "x" | "y" | "z", "spanAxis": …, "angleOfAttackDeg", "stations", "panels",
// "trajectories", "refinementFactor", "surfaceElementSizeM", "condition": "takeoffMaximum" or
// {"temperatureC", "lwcGm3", "dropletMicrons", "altitudeM", "airspeedMps", "durationS"},
// "antiIceTargetC", "antiIceBudgetW", "maximumIceThicknessMm"}. The load case carries nothing: an
// icing test loads the part with water, not with force.
struct IcingJobSettings {
    int flowAxis = 0, spanAxis = 1;
    double angleOfAttackRad = 0.0;
    int stations = 3, panels = 240, trajectories = 200;
    double refinementFactor = 1.5;
    double surfaceElementSizeM = 0.0;
    std::string conditionId; // "takeoffMaximum", or empty when the numbers are given
    IcingCondition condition;
    double antiIceTargetK = 0.0, antiIceBudgetW = 0.0, maximumIceThicknessM = 0.0;
};

// EMC: {"incidence": "+x" | "-x" | "+y" | …, "polarization": "x" | "y" | "z", "level": one of the
// standard's ids (or omitted with "fieldVm"), "fieldVm", "lowHz", "highHz", "points", "cellM",
// "refinementFactor", "surfaceElementSizeM", "pmlCells", "marginCells",
// "equipment": [{"name", "x", "y", "z", "immunityVm"}] — points inside the enclosure, in the part's
// own coordinates}. The load case carries nothing here: nothing is loaded and nothing is supported.
struct EmcJobSettings {
    em::Axis incidence = em::Axis::X;
    bool forward = true;
    em::Axis polarization = em::Axis::Z;
    std::string levelId;
    double fieldVm = 0.0;
    double lowHz = 0.0, highHz = 0.0;
    int points = 0;
    double surfaceElementSizeM = 0.0;
    int pmlCells = 8, marginCells = 4;
    std::vector<EmcProbe> equipment;
};

// Lightning: {"components": ["A", "B", "C", "D"] (in this order), "attachmentFaces": ["face-…"],
// "groundFaces": ["face-…"], "polarity": "anode" | "cathode", "continuingCurrentA" (200–800),
// "surfaceEmissivity", "stepsPerComponent", "equipment": [{"name", "face", "minimumK", "maximumK"}]}.
struct LightningJobSettings {
    std::vector<LightningComponent> components;
    std::vector<std::string> attachmentFaces, groundFaces;
    ArcPolarity polarity = ArcPolarity::Anode;
    double continuingCurrentA = 400.0;
    double surfaceEmissivity = 0.0;
    int stepsPerComponent = 500;
    std::vector<ClimateComponent> equipment;
};

// Fire: {"standard": "iso2685" | "ac20135", "durationS" (300 fire resistant, 900 fireproof), "flameFaces":
// ["face-…"], "surfaceEmissivity" (EN 1999-1-2 §2.2: 0.3 clean, 0.7 painted), "stepS", "operating",
// "components": [{"name", "face", "powerW", "minimumK", "maximumK"}]}. The load case's supports, forces,
// pressures and acceleration are those of the fire situation. No defaults for the duration, the flame
// faces, the emissivity or the step.
struct FireJobSettings {
    FireStandard standard = FireStandard::Iso2685;
    double durationS = 0.0;
    std::vector<std::string> flameFaces;
    double surfaceEmissivity = 0.0;
    double stepS = 0.0;
    bool operating = true;
    std::vector<ClimateComponent> components;
};

// Climate: {"environment": "hot" | "cold", "category": "A1" | "A2" | "C1" | "C2" | "C3",
// "exposure": "sun" | "shade" | "induced" (hot), "ambient" | "induced" (cold), "airflow": "chamber" |
// "flight", "airSpeedMps", "altitudeM", "upDirection", "flowDirection", "solarAbsorptance", "emissivity",
// "stressFreeK", "operating", "components": [{"name", "face", "powerW", "minimumK", "maximumK"}],
// "materialMinimumK", "materialMaximumK", "convectionBand", "stepS"}. No defaults for the air speed, the
// surface's α and ε, the assembly temperature or the time step. Supports in the load case clamp the part
// (and cover those faces); without them it expands freely.
struct ClimateJobSettings {
    ClimateEnvironment environment = ClimateEnvironment::Hot;
    HotCategory hotCategory = HotCategory::A1HotDry;
    HotExposure hotExposure = HotExposure::Sun;
    ColdCategory coldCategory = ColdCategory::C2Cold;
    ColdExposure coldExposure = ColdExposure::Ambient;
    ClimateAirflow airflow = ClimateAirflow::Chamber;
    double airSpeedMps = 0.0;
    double altitudeM = 0.0;
    Vec3 upDirection{0.0, 0.0, 1.0};
    Vec3 flowDirection{1.0, 0.0, 0.0};
    double solarAbsorptance = 0.0;
    double emissivity = 0.0;
    double stressFreeK = 0.0;
    bool operating = true;
    std::vector<ClimateComponent> components;
    std::optional<double> materialMinimumK, materialMaximumK;
    double convectionBand = 0.25;
    double stepS = 0.0;
};

// Shock: {"modeCount", "dampingRatio", "direction", "pulse": {"shape": "halfSine" | "sawtooth" |
// "trapezoid" | "history", "peakMps2", "durationS", "riseS", "fallS", "history": [[s, m/s²], …]},
// "attachedMasses", "probeFace"}. No defaults for ζ, the mode count or the pulse.
struct ShockJobSettings {
    int modeCount = 0;
    double dampingRatio = -1.0;
    Vec3 direction{0.0, 0.0, 1.0};
    ShockPulse pulse;
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace;
};

// Bird strike: {"modeCount", "dampingRatio", "impactFace", "direction" (where the bird pushes),
// "bird": {"massKg" (1.81 = 4 lb by default, 3.63 = 8 lb for the empennage), "speedMps" (required),
// "obliquityDeg" (90 = head-on), "densityKgM3", "lengthToDiameter", "shockSpeedMps", "shockSlope"},
// "attachedMasses"}. No defaults for ζ, the mode count, the face or the speed. The load case's
// supports hold the part; its static loads are refused — the bird is the load.
struct BirdJobSettings {
    int modeCount = 0;
    double dampingRatio = -1.0;
    std::string impactFace;
    Vec3 direction{0.0, 0.0, -1.0};
    BirdModel bird;
    std::vector<AttachedMass> attachedMasses;
};

// Random vibration: {"modeCount", "dampingRatio", "direction": [x, y, z], "accelerationPsd":
// [[Hz, (m/s²)²/Hz], …] (at least two points; log–log between them, zero outside), "attachedMasses",
// "probeFace"}. No defaults for ζ, the mode count or the spectrum.
struct RandomJobSettings {
    int modeCount = 0;
    double dampingRatio = -1.0;
    Vec3 direction{0.0, 0.0, 1.0};
    std::vector<AmplitudePoint> accelerationPsd;
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace;
};

// Sine vibration: {"modeCount", "dampingRatio", "excitation": {"kind": "base" | "force",
// "direction": [x, y, z], "amplitude": [[Hz, value], …] (m/s² for base, N for force) or, for a
// force, "imbalanceKgM"; "face" for a force}, "frequencyRangeHz": [from, to], "sweepPoints",
// "attachedMasses", "probeFace"}. No defaults for ζ, the mode count or the range.
struct HarmonicJobSettings {
    int modeCount = 0;
    double dampingRatio = -1.0;
    HarmonicExcitation excitation;
    double minimumHz = 0.0, maximumHz = 0.0;
    int sweepPoints = 200;
    std::vector<AttachedMass> attachedMasses;
    std::string probeFace;
};

struct ModalJobSettings {
    int modeCount = 0;
    // Rotors become their 1P and NP bands; other excitation (2P, engine orders) is listed as
    // explicit bands.
    std::vector<RotorExcitation> rotors;
    std::vector<ExcitationBand> bands;
    double separationMargin = 0.0;
    // Equipment mass on faces: {"face": "face-3", "massKg": 0.18}.
    std::vector<AttachedMass> attachedMasses;

    std::vector<ExcitationBand> allBands() const;
};

struct StructuralJob {
    StructuralAnalysis analysis = StructuralAnalysis::Static;
    std::string geometryPath;   // absolute after parsing
    std::string geometryFormat; // "brep" | "uavpart"
    // Library id; when absent a .uavpart's own material is used.
    std::optional<std::string> materialId;
    // Modal: only the supports are used, and loads are refused — a linear modal analysis does not
    // see them, and a job carrying loads would suggest it did.
    StructuralLoadCase loadCase;
    StructuralStudySettings settings;
    ModalJobSettings modal;
    HarmonicJobSettings harmonic;
    RandomJobSettings random;
    ShockJobSettings shock;
    ClimateJobSettings climate;
    FireJobSettings fire;
    LightningJobSettings lightning;
    EmcJobSettings emc;
    IcingJobSettings icing;
    FlutterJobSettings flutter;
    BirdJobSettings bird;
    std::string resultPath;
    std::string fieldPath;
};

ModalStudySettings modalStudySettings(const StructuralJob& job);
HarmonicStudySettings harmonicStudySettings(const StructuralJob& job);
RandomStudySettings randomStudySettings(const StructuralJob& job);
ShockStudySettings shockStudySettings(const StructuralJob& job);
ClimateStudySettings climateStudySettings(const StructuralJob& job);
FireStudySettings fireStudySettings(const StructuralJob& job);
LightningStudySettings lightningStudySettings(const StructuralJob& job);
EmcStudySettings emcStudySettings(const StructuralJob& job);
IcingStudySettings icingStudySettings(const StructuralJob& job);
FlutterStudySettings flutterStudySettings(const StructuralJob& job);
BirdStrikeStudySettings birdStrikeStudySettings(const StructuralJob& job);

// Relative paths resolve against `baseDirectory` (the job file's folder).
Result<StructuralJob> parseStructuralJob(const std::string& jsonText, const std::string& baseDirectory);

// Writes a job file that parseStructuralJob reads back to the same job. Paths are written as
// stored in the job (relative ones stay relative to the file's folder).
std::string structuralJobJson(const StructuralJob& job);

std::string structuralResultJson(const StructuralStudyResult& result, const StructuralJob& job,
                                 const std::string& fieldReference);

// A calculation that did not complete is ERROR, never FAIL (spec §16).
std::string structuralErrorJson(const std::string& message, const StructuralJob* job);

std::string structuralFieldJson(const StructuralStudyResult& result);

// Modal verdict: WARNING when a mode overlaps an excitation band (spec §6.2), when no band was
// given (resonance then is not checked at all), when a band reaches above the last computed mode
// (modes above it are not checked), or when a frequency has no usable mesh uncertainty; PASS
// otherwise. Never FAIL — a computed overlap is a risk for the vibration test
// to confirm, not a demonstrated failure.
std::string modalResultJson(const ModalStudyResult& result, const StructuralJob& job, const std::string& fieldReference);

std::string modalFieldJson(const ModalStudyResult& result);

// Harmonic verdict: see HarmonicStudy.hpp — FAIL on the peak dynamic stress, otherwise WARNING:
// fatigue is not assessed yet (and clamp singularity, uncovered range, too little modal mass).
std::string harmonicResultJson(const HarmonicStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string harmonicFieldJson(const HarmonicStudyResult& result);

// Random verdict: see RandomStudy.hpp — FAIL on the 3σ stress, otherwise WARNING (fatigue is not
// assessed). The field's stress is 3σ; it has no deformed shape.
std::string randomResultJson(const RandomStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string randomFieldJson(const RandomStudyResult& result);

// Shock verdict: see ShockStudy.hpp — PASS / WARNING / FAIL on the peak stress (a single event).
std::string shockResultJson(const ShockStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string shockFieldJson(const ShockStudyResult& result);

// Climate verdict: see ClimateStudy.hpp — the worst of the equipment's and the material's temperature
// limits and of the strength under the thermal stress. The field carries the von Mises stress of the
// worst instant (as the structural field does) and, per node, the temperature of the hottest instant.
std::string climateResultJson(const ClimateStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string climateFieldJson(const ClimateStudyResult& result);

// Fire verdict: see FireStudy.hpp — the worst of integrity (FAIL when the part reaches the temperature of no
// strength before the required time), strength when hot, and the equipment's limits. The field carries the
// temperature at the end (or at the loss of integrity) and the utilisation against the hot strength.
std::string fireResultJson(const FireStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string fireFieldJson(const FireStudyResult& result);

// Lightning verdict: see LightningStudy.hpp — FAIL when the part burns through before the strike is over,
// otherwise the equipment's limits and how close the metal came to losing its strength. The field carries
// the temperature at the end (or at the burn-through) and the potential of the spreading current.
std::string lightningResultJson(const LightningStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string lightningFieldJson(const LightningStudyResult& result);

// EMC verdict: see EmcStudy.hpp — FAIL when the field that reaches a piece of equipment is above what that
// equipment is qualified for; WARNING when the grid's own band reaches that far, or when the shielding is a
// lower bound rather than a measurement. The field carries |E| on the surface at the worst frequency.
std::string emcResultJson(const EmcStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string emcFieldJson(const EmcStudyResult& result);

// Icing verdict: see IcingStudy.hpp — FAIL when the ice is thicker than the design allows or the
// anti-ice system needs more power than it has; WARNING when there is nothing to compare against, or
// when the grid's band or the heat-transfer band reaches the limit. The field carries the thickness
// of the ice at every node of the surface.
std::string icingResultJson(const IcingStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string icingFieldJson(const IcingStudyResult& result);

// Flutter verdict: see FlutterStudy.hpp — FAIL when the lowest instability, flutter or divergence,
// comes before the margin the regulation asks for (1.15·V_D); WARNING when the grid's band reaches
// that far, when there is no dive speed to compare against, or when the answer lands where the
// aerodynamics no longer apply. The field carries the two mode shapes that flutter with each other.
std::string flutterResultJson(const FlutterStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string flutterFieldJson(const FlutterStudyResult& result);

// Bird strike verdict: see BirdStrikeStudy.hpp — the limit-load rules on the peak stress of a single
// event, demoted when the load is spread over a face much larger than the bird. The field carries
// von Mises and the displacement at the worst instant, as the shock field does.
std::string birdResultJson(const BirdStrikeStudyResult& result, const StructuralJob& job, const std::string& fieldReference);
std::string birdFieldJson(const BirdStrikeStudyResult& result);

} // namespace cadnext::fea
