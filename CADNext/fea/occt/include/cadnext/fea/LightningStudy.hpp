#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/ClimateStudy.hpp"
#include "cadnext/fea/Fire.hpp"
#include "cadnext/fea/Lightning.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>
#include <vector>

// A lightning strike to a CAD part (SAE ARP5412 waveforms, ARP5416-style direct-effects test): the current
// enters at the arc's attachment, spreads through the metal to where the part is bonded, and heats it both
// at the attachment (the arc's own heat) and inside (Joule). Does the part burn through, and does its
// equipment survive?
//
// The spread is solved once per mesh at one ampere — the field is linear in the current — and then followed
// in time: the arc's flux with i(t), the Joule heat with i(t)². Components are applied one after another in
// the order given, each with its own time step, the temperature carried across.
//
// What is modelled and what is not:
//   - the arc's heat is q = U_eff · i / A over the attachment faces, U_eff ≈ 10 V for an anode and ≤ 24 V
//     for a cathode (Fire.hpp's sources); the arc plasma is not modelled, so the size of its root is what
//     the chosen attachment faces say it is — the result reports their equivalent radius;
//   - the metal's resistivity is its 20 °C value (the database has no temperature dependence), which
//     understates the Joule heat of hot metal; in aluminium that heat is small beside the arc's anyway;
//   - between the components the part only cools by convection (4 W/(m² K), EN 1991-1-2 §3.1(5)) and
//     radiation to the laboratory, as in the fire test;
//   - equipment dissipation is left out: a strike lasts under a second.
//
// Integrity is judged by the temperature at which the material has no strength left (550 °C for the alloys
// of EN 1999-1-2 Table 1a) — reached anywhere, the part is holed or locally destroyed at that moment.

namespace cadnext::fea {

struct LightningStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    std::vector<LightningComponent> components; // applied in this order; required
    std::vector<std::string> attachmentFaces;   // the arc root; required
    std::vector<std::string> groundFaces;       // bonded to the structure, held at zero potential; required
    ArcPolarity polarity = ArcPolarity::Anode;
    double continuingCurrentA = 400.0; // component C, inside the standard's 200–800 A
    double surfaceEmissivity = 0.0;    // required: EN 1999-1-2 §2.2, 0.3 clean, 0.7 painted
    int stepsPerComponent = 500;
    std::vector<ClimateComponent> equipment;
};

struct LightningLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakK = 0.0;
    double burnThroughTimeS = -1.0;
    double resistanceOhm = 0.0;
};

struct LightningSeries {
    std::vector<double> timeS, currentA, partMaximumK;
    std::vector<std::vector<double>> equipmentMaximumK;
};

struct LightningStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion, hotMaterialSource;
    std::vector<CurrentWaveform> waveforms;
    double totalChargeC = 0.0, totalActionIntegralA2s = 0.0, peakCurrentA = 0.0;
    double arcVoltsPerAmp = 0.0;
    double attachmentAreaM2 = 0.0, arcRootRadiusM = 0.0;
    double resistanceOhm = 0.0;
    double arcEnergyJ = 0.0, jouleEnergyJ = 0.0;
    double peakCurrentDensityAm2 = 0.0;
    std::optional<double> noStrengthK;
    std::vector<LightningLevel> levels;
    ConvergenceEstimate peakConvergence, burnThroughConvergence;
    double peakK = 0.0, peakUncertaintyK = 0.0, timeStepErrorK = 0.0;
    Vec3 hottestPoint;
    bool burnedThrough = false;
    double burnThroughTimeS = -1.0, burnThroughUncertaintyS = 0.0;
    std::vector<ClimateComponentResult> equipment;
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons, reasons, warnings;
    LightningSeries series;
    StructuralSurfaceField field; // geometry only; the temperature per node is beside it
    std::vector<double> fieldTemperatureK, fieldPotentialV;
};

inline constexpr const char* kLightningSolverID = "cadnext.fea.lightning-tet10";

Result<LightningStudyResult> runLightningStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                               const std::string& loadCaseName, const LightningStudySettings& settings,
                                               const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
