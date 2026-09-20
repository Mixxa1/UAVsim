#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/ClimaticCycles.hpp"
#include "cadnext/fea/Convergence.hpp"
#include "cadnext/fea/StrengthAssessment.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <optional>
#include <string>
#include <vector>

// Climatic test of a CAD solid (MIL-STD-810H Methods 501.7, 502.7, 505.7): the part in the standard's
// air — and, in the hot categories with sun, under the standard's sun — with the heat of its own
// equipment; its temperatures over the day against the limits of that equipment and of its material,
// and the thermal stress the temperature field causes where the part is held.
//
// Hot: the diurnal cycle is repeated until it repeats itself — at least three cycles and at most seven,
// as Method 505.7 §2.3.2 runs the test; earlier than the seventh only when the peak of two consecutive
// cycles agrees within 0.01 K (the standard's ±2 °C is a laboratory tolerance; a computation has no
// reason to stop that far from the periodic state, and 0.01 K is well below any mesh uncertainty).
// Crank–Nicolson in time from the steady state at the day's mean conditions; the thermal stress is
// solved every half hour of the last cycle and at its hottest and most uneven instants.
// Cold: a constant temperature (Method 502.7): the cold-soaked part is at the air temperature (exact),
// and, with its equipment on, it is solved to its steady state.
//
// Heat exchange of every face that is not covered (a face carrying equipment or clamped in the fixture is
// covered: no sun, air or radiation there):
//   - forced convection from a flat-plate correlation over the part's length along the flow
//     (AirConvection.hpp), at the chamber's air speed or the flight airspeed; natural convection is
//     left out, which over-predicts the temperature and is reported beside the result;
//   - radiation εσ(T⁴ − T_air⁴) to surroundings at the air temperature (the chamber's walls; sky and
//     ground in flight are not modelled);
//   - the sun from `upDirection`, α E max(0, n·s), shaded by the part itself.
// The correlation is a flat plate's, so h carries a band (±`convectionBand`): the temperatures are
// taken at the band's low edge (less cooling, higher temperature — the conservative side), the stress
// at both edges, whichever is higher.
//
// Uncertainty of a temperature = the grid convergence index of three meshes plus the time-step error
// (the coarse mesh rerun at half the step, Richardson with Crank–Nicolson's order 2).
// A temperature limit is met (PASS) when the value plus its uncertainty stays inside it, exceeded (FAIL)
// when the value minus its uncertainty is outside, undecided (WARNING) in between. Without a limit for the
// material there is nothing to hold its temperature against: WARNING, "no data". Strength is the
// material's room-temperature strength; hotter, it is lower, and the result says so.

namespace cadnext::fea {

struct ClimateComponent {
    std::string name;
    std::string face;       // where it is mounted
    double powerW = 0.0;    // dissipated while operating
    std::optional<double> minimumK, maximumK; // its case temperature limits, from its datasheet
};

enum class ClimateEnvironment { Hot, Cold };
enum class ClimateAirflow { Chamber, Flight };

struct ClimateStudySettings {
    double coarseElementSizeM = 0.0; // required
    double refinementFactor = 0.0;   // required, ≥ 1.3
    ClimateEnvironment environment = ClimateEnvironment::Hot;
    HotCategory hotCategory = HotCategory::A1HotDry;
    HotExposure hotExposure = HotExposure::Sun;
    ColdCategory coldCategory = ColdCategory::C2Cold;
    ColdExposure coldExposure = ColdExposure::Ambient;
    ClimateAirflow airflow = ClimateAirflow::Chamber;
    double airSpeedMps = 0.0;        // required: across the item in the chamber, or the flight airspeed
    double altitudeM = 0.0;          // flight: the standard's surface air cooled at the standard lapse rate
    Vec3 upDirection{0.0, 0.0, 1.0}; // in the part's frame; the sun (the chamber's lamps) is there
    Vec3 flowDirection{1.0, 0.0, 0.0};
    double solarAbsorptance = 0.0;   // required with sun: a property of the surface finish
    double emissivity = 0.0;         // required: likewise
    double stressFreeK = 0.0;        // required: the temperature the part was assembled at
    bool operating = true;           // the components dissipate their power
    std::vector<ClimateComponent> components;
    std::optional<double> materialMinimumK, materialMaximumK;
    double convectionBand = 0.25;
    double stepS = 0.0;              // required for the hot cycle
    std::vector<StressExclusion> stressExclusions;
    StrengthCriteria criteria;
};

struct ClimateLevel {
    double maximumElementSizeM = 0.0;
    std::size_t elements = 0;
    double peakK = 0.0, lowK = 0.0, peakStressPa = 0.0;
    int cycles = 0;
};

struct TemperatureCheck {
    double valueK = 0.0;
    double uncertaintyK = 0.0;
    double limitK = 0.0;
    bool upper = true; // a maximum limit
    StrengthVerdict verdict = StrengthVerdict::Warning;
};

struct ClimateComponentResult {
    std::string name, face;
    double powerW = 0.0;
    double maximumK = 0.0, minimumK = 0.0;
    double maximumTimeS = 0.0;
    ConvergenceEstimate maximumConvergence;
    double uncertaintyK = 0.0;
    std::vector<TemperatureCheck> checks;
    StrengthVerdict verdict = StrengthVerdict::Pass;
};

// The last cycle on the finest mesh (hot), every `sample` seconds.
struct ClimateSeries {
    std::vector<double> timeS, airK, irradianceWm2, partMaximumK, partMinimumK;
    std::vector<std::vector<double>> componentMaximumK; // per component, per sample
};

struct ClimateStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    double factorOfSafety = 1.5;
    std::string mesherVersion;
    std::string conditionSource;
    bool transient = false;
    double airPeakK = 0.0, airLowK = 0.0, irradiancePeakWm2 = 0.0, pressurePa = 0.0;
    // Heat exchange.
    double characteristicLengthM = 0.0;
    double convectionWm2K = 0.0, convectionLowWm2K = 0.0, convectionHighWm2K = 0.0;
    double reynolds = 0.0;
    bool laminar = true;
    double recoveryRiseK = 0.0;
    double naturalConvectionWm2K = 0.0; // Churchill–Chu at the largest part-to-air difference, not used
    double sunlitProjectedAreaM2 = 0.0, shadedAreaM2 = 0.0, absorbedSolarPeakW = 0.0;
    double exposedAreaM2 = 0.0, coveredAreaM2 = 0.0;
    // Time.
    int cycles = 0;
    double lastCycleChangeK = 0.0;
    bool periodic = true;
    double stepS = 0.0;
    double timeStepErrorK = 0.0;
    // Part temperature (conservative edge of h), stress (worse edge).
    std::vector<ClimateLevel> levels;
    ConvergenceEstimate peakConvergence, lowConvergence, stressConvergence;
    double peakK = 0.0, peakTimeS = 0.0, lowK = 0.0, lowTimeS = 0.0;
    double peakUncertaintyK = 0.0, lowUncertaintyK = 0.0;
    double peakOtherEdgeK = 0.0; // with h at the band's high edge
    Vec3 hottestPoint;
    double peakStressPa = 0.0, peakStressTimeS = 0.0, peakStressOtherEdgePa = 0.0;
    Vec3 criticalPoint;
    std::string criticalFace;
    StrengthAssessment assessment; // strength under the thermal stress
    std::vector<TemperatureCheck> materialChecks;
    std::vector<ClimateComponentResult> components;
    // Everything together.
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons; // what failed
    std::vector<std::string> reasons;        // what keeps the rest from PASS
    std::vector<std::string> warnings;       // notes that do not change the verdict
    ClimateSeries series;
    // Temperature at the hottest instant (in `temperatureK`), von Mises and displacement at the instant of
    // the largest stress.
    StructuralSurfaceField field;
    std::vector<double> fieldTemperatureK;
};

inline constexpr const char* kClimateSolverID = "cadnext.fea.climate-tet10";

Result<ClimateStudyResult> runClimateStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                           const std::string& loadCaseName, const std::vector<FaceSupport>& supports,
                                           const ClimateStudySettings& settings, const StructuralStudyProgress& progress = {});

// The verdict of a temperature against a limit with its uncertainty (see above).
TemperatureCheck checkTemperature(double valueK, double uncertaintyK, double limitK, bool upper);

} // namespace cadnext::fea
