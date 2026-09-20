#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Icing.hpp"
#include "cadnext/fea/StructuralStudy.hpp"

#include <string>
#include <vector>

// Ice on a CAD part: the part is cut across the flow into stations, each station is a section the
// droplets fly at, and what freezes on it is added up along the span.
//
// The chain, station by station: the section is taken from the part's own surface; the air around it
// is the potential flow of PanelFlow.hpp; the droplets of the cloud are followed through that flow
// until they land, which gives the collection efficiency at every panel; the heat leaving each panel
// is a flat plate's, from the stagnation point with the local speed the flow gives; and Messinger's
// balance turns the water and the heat into a freezing fraction and a thickness.
//
// What this does not do, and says so in every result:
//   - the ice does not change the flow. The thickness is the first instant's rate held for the whole
//     exposure, which over a long one overstates a rime shape and says nothing about a glaze horn;
//   - runback is not routed along the surface, so a glaze station reports the fraction that would
//     run back, not where it ends up;
//   - each station is two-dimensional: no sweep, no spanwise flow, no tip;
//   - the boundary layer is a flat plate's, not this section's, and roughness is not modelled — the
//     heat transfer is the largest uncertainty in the number, and the result carries a band for it.
//     At the nose a flat plate's film coefficient runs away (it goes as 1/√s from the stagnation
//     point, so a finer panel gives a larger number for ever), and there the value is capped by
//     Frössling's for a cylinder of the section's own leading-edge radius, which is finite and is
//     what a leading edge actually is;
//   - Appendix O (supercooled large drops) needs splashing and break-up, which are not here.

namespace cadnext::fea {

struct IcingStudySettings {
    // Which way the part flies and how it is cut: the flow comes along `flowAxis`, the stations are
    // cut perpendicular to `spanAxis`, and the angle of attack turns the flow about the span.
    int flowAxis = 0; // 0 = x, 1 = y, 2 = z
    int spanAxis = 1;
    double angleOfAttackRad = 0.0;
    int stations = 3;             // across the span, evenly spaced inside the part
    int panels = 240;             // per section, on the coarse level
    int trajectories = 200;       // droplets per section, on the coarse level
    double refinementFactor = 1.5; // the finer levels multiply panels and trajectories by this
    IcingCondition condition;
    double surfaceElementSizeM = 0.0; // the triangulation the sections are cut from
    double antiIceTargetK = 0.0;      // if set, the surface temperature an anti-ice system holds
    double antiIceBudgetW = 0.0;      // if set, the power available for it
    double maximumIceThicknessM = 0.0; // if set, the thickness the design may not exceed
};

struct IcingStationResult {
    double spanPositionM = 0.0;
    double chordM = 0.0;
    double collectionEfficiency = 0.0, maximumBeta = 0.0;
    double waterKgPerSPerM = 0.0;
    double maximumIceThicknessM = 0.0;
    double maximumGrowthMps = 0.0;
    double freezingFractionAtStagnation = 0.0;
    double surfaceTemperatureK = 0.0;
    bool glaze = false;
    double impingementLengthM = 0.0;     // how far along the surface water lands
    double antiIcePowerWPerM = 0.0;      // to hold the target over that length
    double iceMassKgPerM = 0.0;          // per metre of span, after the exposure
    double leadingEdgeRadiusM = 0.0;
    double stagnationFilmWm2K = 0.0;
    double evaporatedKgSm2 = 0.0;   // at the thickest panel
    double impingingKgSm2 = 0.0;    // at the thickest panel
    std::vector<double> arcLengthM, betaPerPanel, iceThicknessM, heatTransferWm2K;
    std::vector<double> panelXM, panelYM; // where each panel sits in the section's own plane
};

struct IcingLevel {
    int panels = 0, trajectories = 0;
    double maximumIceThicknessM = 0.0;
    double collectionEfficiency = 0.0;
};

struct IcingStudyResult {
    std::string loadCaseName;
    IsotropicMaterial material;
    std::string mesherVersion;
    IcingCondition condition;
    double spanM = 0.0;
    double maximumIceThicknessM = 0.0, thicknessUncertaintyM = 0.0;
    double iceMassKg = 0.0;
    double collectionEfficiency = 0.0;
    double antiIcePowerW = 0.0;
    double inertiaParameter = 0.0;
    double heatTransferBandLow = 0.0, heatTransferBandHigh = 0.0; // the band the flat plate leaves
    std::vector<IcingStationResult> stations;
    std::vector<IcingLevel> levels;
    ConvergenceEstimate thicknessConvergence;
    StrengthVerdict verdict = StrengthVerdict::Warning;
    std::vector<std::string> failureReasons, reasons, warnings;
    StructuralSurfaceField field;      // geometry only
    std::vector<double> fieldIceM;     // ice thickness at every surface node
};

inline constexpr const char* kIcingSolverID = "cadnext.fea.icing-panel";

Result<IcingStudyResult> runIcingStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                       const std::string& loadCaseName, const IcingStudySettings& settings, const StructuralStudyProgress& progress = {});

} // namespace cadnext::fea
