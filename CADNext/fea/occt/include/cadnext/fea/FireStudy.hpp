#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/ClimateStudy.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/Fire.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>
#include <vector>

// Fire resistance of a CAD part (ISO 2685 / FAA AC 20-135): the standard flame on the faces a fire would
// reach, for 5 minutes ("fire resistant") or 15 ("fireproof"), the part carrying its loads and its
// equipment. Does it keep its integrity, its strength and its equipment's function to the end?
//
// Heat: the flame by its two limiting models (Fire.hpp) — each mesh with the one that is worse for this
// part (chosen on the coarse mesh: the earlier loss of integrity, else the hotter end), the other one on
// the finest mesh as well; the faces away from the flame lose heat by convection (EN 1991-1-2 §3.1(5),
// 4 W/(m² K)) and radiation (EN 1999-1-2 §2.2 emissivity) to a laboratory at 20 °C; faces carrying
// equipment or clamped are covered. Conductivity and specific heat follow the material's temperature
// (EN 1999-1-2), Crank–Nicolson in time from 20 °C.
//
// Criteria (EN 1999-1-2, γ_M,fi = 1.0):
//   integrity   no point of the part reaches the temperature where its 0.2 % proof strength is gone
//               (550 °C for the alloys of Table 1a) before the required time — the run stops there and
//               reports the time;
//   strength    σ_vM ≤ k₀.₂(θ) f₀.₂ at every point and every sampled instant, the stress from the loads of
//               the fire situation (the load case) and the thermal expansion (Δl/l of §3.3.1.1) with E(θ);
//   function    each piece of equipment within its limits over the exposure.
// A material without published high-temperature data is refused; one without strength data (7075) is
// assessed for integrity and function only, and says "нет данных" for strength. Above 500 °C the
// standard's thermal formulas are extrapolated, and the result says so.
//
// Uncertainty: the grid convergence index of three meshes plus the time-step error (the coarse mesh at
// half the step, Richardson with order 2), for the temperatures, the time of failure and the utilisation.

namespace cadnext::fea {

struct FireStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    FireStandard standard = FireStandard::Iso2685;
    double durationS = 0.0;          // required: 300 fire resistant, 900 fireproof
    std::vector<std::string> flameFaces; // required
    double surfaceEmissivity = 0.0;  // required: 0.3 clean, 0.7 painted or sooted (EN 1999-1-2 §2.2)
    double stepS = 0.0;              // required
    bool operating = true;
    std::vector<ClimateComponent> components;
    // The loads the part carries during the fire (the fire situation's combination).
    std::vector<FaceForce> forces;
    std::vector<FacePressure> pressures;
    Vec3 bodyAccelerationMps2;
    std::vector<StressExclusion> stressExclusions;
};

struct FireLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakK = 0.0;          // at the end of the exposure, or when integrity was lost
    double failureTimeS = -1.0;  // −1: kept its integrity to the end
    double utilization = 0.0;
};

struct FireModelRun {
    FlameModel model = FlameModel::Radiative;
    double peakK = 0.0, failureTimeS = -1.0, utilization = 0.0;
};

struct FireSeries {
    std::vector<double> timeS, partMaximumK, partMinimumK;
    std::vector<std::vector<double>> componentMaximumK;
    std::vector<double> sampleTimeS, utilization; // at the stress samples
};

struct FireStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion;
    StandardFlame flame;
    double durationS = 0.0, stepS = 0.0;
    double flameConvectionWm2K = 0.0, flameEmissivity = 0.0;
    std::string hotMaterialSource;
    double dataValidUpToK = 0.0;
    std::optional<double> noStrengthK;
    bool strengthData = false;
    FlameModel governingModel = FlameModel::Radiative;
    std::vector<FireModelRun> finestModels; // both, on the finest mesh
    std::vector<FireLevel> levels;          // the governing model
    ConvergenceEstimate peakConvergence, failureConvergence, utilizationConvergence;
    double timeStepErrorK = 0.0, timeStepErrorS = 0.0, timeStepErrorUtilization = 0.0;
    // Worst over the two flame models on the finest mesh, with the governing model's uncertainty.
    double peakK = 0.0, peakUncertaintyK = 0.0;
    Vec3 hottestPoint;
    bool integrityLost = false;
    double failureTimeS = -1.0, failureUncertaintyS = 0.0;
    double utilization = 0.0, utilizationUncertainty = 0.0, utilizationTimeS = 0.0;
    Vec3 criticalPoint;
    std::string criticalFace;
    std::vector<ClimateComponentResult> components;
    double exposedAreaM2 = 0.0, flameAreaM2 = 0.0, coveredAreaM2 = 0.0;
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons, reasons, warnings;
    FireSeries series; // the governing model on the finest mesh
    // Finest mesh, governing model: temperature at the end (or the loss of integrity); stress, displacement
    // and utilisation σ/(k₀.₂(θ) f₀.₂) at the instant of the largest utilisation.
    StructuralSurfaceField field;
    std::vector<double> fieldTemperatureK, fieldUtilization;
};

inline constexpr const char* kFireSolverID = "cadnext.fea.fire-tet10";

Result<FireStudyResult> runFireStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                     const std::string& loadCaseName, const std::vector<FaceSupport>& supports, const FireStudySettings& settings,
                                     const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
