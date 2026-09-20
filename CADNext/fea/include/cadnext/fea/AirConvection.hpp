#pragma once

// Air and the heat it takes from a surface: what a climatic test needs to turn "1.5 m/s across the
// test item" or "25 m/s at 1000 m" into a film coefficient.
//
// Air as the U.S. Standard Atmosphere 1976 (NOAA/NASA/USAF, NOAA-S/T 76-1562) defines it — dry, an ideal
// gas with M₀ = 28.9644 kg/kmol and R* = 8314.32 J/(kmol K), γ = 1.4:
//   viscosity     μ = β T^{3/2} / (T + S),  β = 1.458e-6 kg/(m s K^½), S = 110.4 K     (its eq. 51)
//   conductivity  k = 2.64638e-3 T^{3/2} / (T + 245.4 · 10^{−12/T}) W/(m K)            (its eq. 53)
//   troposphere   p = p₀ [T₀ / (T₀ + L H)]^{g₀ M₀ / (R* L)}, L = −6.5 K/km, H geopotential (its eq. 33a)
// The Standard's table gives μ = 1.7894e-5 Pa s and k = 2.5326e-2 W/(m K) at 288.15 K; the test checks
// these formulas against it.
//
// Film coefficients of a flat plate in parallel flow, averaged over its length L (Incropera, DeWitt,
// Bergman, Lavine, "Fundamentals of Heat and Mass Transfer", 6th ed., eqs. 7.30 and 7.38, with the
// transition Reynolds number 5·10⁵ of that text):
//   Re_L ≤ 5·10⁵:  Nu = 0.664 Re^{1/2} Pr^{1/3}
//   Re_L > 5·10⁵:  Nu = (0.037 Re^{4/5} − 871) Pr^{1/3}          (laminar start, then turbulent)
// valid for 0.6 ≤ Pr ≤ 60 and Re_L ≤ 10⁸. Natural convection from a vertical plate (Churchill & Chu 1975,
// the same text's eq. 9.26), for reporting what the forced-only model leaves out:
//   Nu = {0.825 + 0.387 Ra^{1/6} / [1 + (0.492/Pr)^{9/16}]^{8/27}}²
// These correlations describe a flat plate; on a three-dimensional part they are an approximation, and
// the climatic study carries that as an explicit band on h rather than as hidden confidence.

namespace cadnext::fea {

struct AirProperties {
    double densityKgM3 = 0.0;
    double viscosityPaS = 0.0;
    double conductivityWmK = 0.0;
    double specificHeatJkgK = 0.0;
    double prandtl = 0.0;
};

inline constexpr double kAirGasConstant = 8314.32 / 28.9644;                          // J/(kg K)
inline constexpr double kAirSpecificHeat = 1.4 * kAirGasConstant / (1.4 - 1.0);       // J/(kg K), γR/(γ−1)
inline constexpr double kStandardSeaLevelPressurePa = 101325.0;
inline constexpr double kStandardSeaLevelTemperatureK = 288.15;
inline constexpr double kStandardLapseRateKPerM = 0.0065;                             // troposphere, per metre of geopotential height
inline constexpr double kStandardGravity = 9.80665;

double airViscosity(double temperatureK);
double airConductivity(double temperatureK);
AirProperties airProperties(double temperatureK, double pressurePa);

// Pressure of the standard troposphere at a geometric altitude, 0…11 km.
double standardPressurePa(double geometricAltitudeM);
// Geopotential height of a geometric altitude (r₀ = 6356766 m, the Standard's value).
double geopotentialHeightM(double geometricAltitudeM);

struct ForcedConvection {
    double coefficientWm2K = 0.0;
    double reynolds = 0.0;
    double nusselt = 0.0;
    bool laminar = true;
    bool inValidityRange = true; // Re_L ≤ 1e8, 0.6 ≤ Pr ≤ 60
    // Adiabatic-wall temperature above the air, r V²/(2 c_p), r = Pr^{1/2} laminar, Pr^{1/3} turbulent.
    double recoveryRiseK = 0.0;
};

// Air at `speedMps` along a plate of length `lengthM`, properties at the film temperature.
ForcedConvection flatPlateForcedConvection(double speedMps, double lengthM, double filmK, double pressurePa);

// Natural convection coefficient of a vertical plate of height `heightM` at `surfaceK` in still air.
double verticalPlateNaturalConvection(double heightM, double surfaceK, double airK, double pressurePa);

} // namespace cadnext::fea
