#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/PanelFlow.hpp"

#include <string>
#include <vector>

// Ice on a part flying through a cloud: where the droplets land, how much of the water freezes where
// it lands, how thick the ice gets, and how much heat it takes to stop it.
//
// The environment. 14 CFR 25 Appendix C fixes the icing design envelopes in FIGURES — curves of
// liquid water content against drop diameter and temperature — and this solver does not hold them:
// нет данных. What the regulation states in words, it states here: the takeoff maximum condition
// (0.35 g/m³, 20 µm, −9 °C, to 1500 ft) and the standard horizontal extents of the continuous and
// intermittent maxima. Every other condition is given by the caller as three numbers.
//
// The droplets. Each one is followed through the flow of PanelFlow.hpp with the drag of a sphere
// (Schiller & Naumann's correlation, within 5 % of measurement to Re ≈ 800), which at the sizes of
// Appendix C is most of what decides where it lands. A droplet is a point: it does not deform, does
// not break up, does not splash back off the surface, and does not affect the air. Appendix O's
// supercooled large drops do all four, so this is not an Appendix O solver.
//
// The freezing. Messinger's control volume (1953): what lands, what runs in from upstream, what
// freezes, what evaporates and what runs on, with the heat that each of those carries. Below the
// Ludlam limit everything freezes where it lands (rime) and the surface is colder than melting;
// above it the surface sits at 0 °C and only a fraction freezes (glaze), the rest running back. The
// runback is not routed along the surface here — each station is solved on its own — so a glaze
// shape's horns are not predicted, only the fraction that makes them.

namespace cadnext::fea {

// Water and ice, at and about the melting point. Sources: CRC Handbook of Chemistry and Physics
// (density and specific heat of water and ice, latent heats); the values are the standard ones.
inline constexpr double kWaterDensityKgM3 = 999.8;
inline constexpr double kIceDensityKgM3 = 917.0;      // solid ice; rime is lighter and the caller is told
inline constexpr double kRimeIceDensityKgM3 = 880.0;  // a common value for dry-growth rime; reported, not assumed
inline constexpr double kLatentHeatFusionJkg = 3.337e5;
inline constexpr double kLatentHeatVaporisationJkg = 2.501e6;
inline constexpr double kWaterSpecificHeatJkgK = 4218.0;
inline constexpr double kIceSpecificHeatJkgK = 2050.0;
inline constexpr double kMeltingPointK = 273.15;

// One point of the icing envelope.
struct IcingCondition {
    double temperatureK = 0.0;      // ambient static temperature
    double lwcKgM3 = 0.0;           // liquid water content of the cloud
    double dropletDiameterM = 0.0;  // the median volumetric diameter, treated here as one size
    double altitudeM = 0.0;
    double airspeedMps = 0.0;
    double durationS = 0.0;
    double relativeHumidity = 1.0;  // in cloud
    std::string source;
};

// 14 CFR 25 Appendix C (c), quoted: "the cloud liquid water content of 0.35 g/m3, the mean effective
// diameter of the cloud droplets of 20 microns, and the ambient air temperature at ground level of
// minus 9 degrees Celsius", from the ground to 1500 ft.
IcingCondition takeoffMaximumIcing(double airspeedMps, double durationS);

// The horizontal extents the same appendix names, for the factor that scales water content with the
// length of the cloud (the factor's own curve is a figure: нет данных).
inline constexpr double kContinuousMaximumExtentM = 17.4 * 1852.0;
inline constexpr double kIntermittentMaximumExtentM = 2.6 * 1852.0;

// The drag of a sphere, as the ratio C_D·Re/24 — one in Stokes' flow and larger as the droplet
// outruns it (Schiller & Naumann 1933).
double dropletDragFactor(double reynolds);

// ρ_w d² V / (18 μ L): how far a droplet's inertia carries it, against the size of what it is flying
// at. Everything about impingement follows this number and the droplet's Reynolds number.
double inertiaParameter(double dropletDiameterM, double airspeedMps, double referenceLengthM, double airViscosityPasS);

struct ImpingementSettings {
    int trajectories = 200;       // released across the body's frontal height
    double startLengths = 6.0;    // how far upstream, in reference lengths
    double stepLengths = 0.002;   // the time step, as a fraction of a reference length travelled
    double referenceLengthM = 0.0; // defaults to the section's chord
};

struct ImpingementResult {
    std::vector<double> betaPerPanel;    // local collection efficiency at each panel
    std::vector<double> arcLengthM;      // where each panel's midpoint sits along the surface
    double maximumBeta = 0.0;
    double totalEfficiency = 0.0;        // the captured height over the frontal height
    double capturedHeightM = 0.0;        // the band of the free stream that reaches the body
    double upperLimitArcM = 0.0, lowerLimitArcM = 0.0; // where impingement stops, along the surface
    double waterKgPerSPerM = 0.0;        // water caught per second per metre of span
    int impacts = 0;
    std::vector<std::string> warnings;
};

// Follows a fan of droplets through the flow and counts what lands where.
Result<ImpingementResult> solveImpingement(const PanelFlowSolution& flow, const IcingCondition& condition, const ImpingementSettings& settings = {});

// --- The surface balance, one station at a time.
struct MessingerInput {
    double airTemperatureK = 0.0;
    double pressurePa = 0.0;
    double airspeedMps = 0.0;        // the free stream
    double localSpeedMps = 0.0;      // the flow just outside the boundary layer here
    double heatTransferWm2K = 0.0;   // the convective coefficient here
    double impingingKgSm2 = 0.0;     // β·LWC·V
    double runbackInKgSm2 = 0.0;
    double relativeHumidity = 1.0;
    double recoveryFactor = 0.9;     // turbulent boundary layer; laminar is 0.85
    double surfaceHeatFluxWm2 = 0.0; // what an anti-ice system puts in, positive into the surface
};

struct MessingerResult {
    // The share of the water that freezes, of what is left after evaporation: the mass balance is
    // caught = ice + evaporated + runback, exactly, at every fraction.
    double freezingFraction = 0.0;
    double surfaceTemperatureK = 0.0;
    double recoveryTemperatureK = 0.0;
    double iceKgSm2 = 0.0, evaporatedKgSm2 = 0.0, runbackOutKgSm2 = 0.0;
    double iceGrowthMps = 0.0;
    // The terms of the balance, in W/m², positive when they warm the surface.
    double convectiveWm2 = 0.0, evaporativeWm2 = 0.0, latentWm2 = 0.0, sensibleWm2 = 0.0, kineticWm2 = 0.0, suppliedWm2 = 0.0;
    double residualWm2 = 0.0; // what the balance failed to close by
    bool glaze = false;
};

MessingerResult solveMessinger(const MessingerInput& input);

// The heat a surface needs to hold a temperature with nothing freezing on it: the anti-ice flux. At
// `targetK` a little above melting the water runs back wet; high enough and it all evaporates.
double antiIceHeatFluxWm2(const MessingerInput& input, double targetK);

// Saturation vapour pressure over water, Buck's 1981 correlation (within 0.05 % from −40 to +50 °C).
double saturationVapourPressurePa(double temperatureK);

} // namespace cadnext::fea
