#include "cadnext/fea/AirConvection.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

double airViscosity(double temperatureK) {
    return 1.458e-6 * std::pow(temperatureK, 1.5) / (temperatureK + 110.4);
}

double airConductivity(double temperatureK) {
    return 2.64638e-3 * std::pow(temperatureK, 1.5) / (temperatureK + 245.4 * std::pow(10.0, -12.0 / temperatureK));
}

AirProperties airProperties(double temperatureK, double pressurePa) {
    AirProperties air;
    air.densityKgM3 = pressurePa / (kAirGasConstant * temperatureK);
    air.viscosityPaS = airViscosity(temperatureK);
    air.conductivityWmK = airConductivity(temperatureK);
    air.specificHeatJkgK = kAirSpecificHeat;
    air.prandtl = air.viscosityPaS * air.specificHeatJkgK / air.conductivityWmK;
    return air;
}

double geopotentialHeightM(double geometricAltitudeM) {
    constexpr double r0 = 6356766.0;
    return r0 * geometricAltitudeM / (r0 + geometricAltitudeM);
}

double standardPressurePa(double geometricAltitudeM) {
    const double H = geopotentialHeightM(geometricAltitudeM);
    constexpr double L = -kStandardLapseRateKPerM;
    constexpr double molarGasConstant = 8314.32, molarMass = 28.9644;
    const double exponent = kStandardGravity * molarMass / (molarGasConstant * L);
    return kStandardSeaLevelPressurePa * std::pow(kStandardSeaLevelTemperatureK / (kStandardSeaLevelTemperatureK + L * H), exponent);
}

ForcedConvection flatPlateForcedConvection(double speedMps, double lengthM, double filmK, double pressurePa) {
    ForcedConvection result;
    const auto air = airProperties(filmK, pressurePa);
    result.reynolds = air.densityKgM3 * speedMps * lengthM / air.viscosityPaS;
    const double pr3 = std::cbrt(air.prandtl);
    result.laminar = result.reynolds <= 5.0e5;
    result.nusselt = result.laminar ? 0.664 * std::sqrt(result.reynolds) * pr3 : (0.037 * std::pow(result.reynolds, 0.8) - 871.0) * pr3;
    result.coefficientWm2K = result.nusselt * air.conductivityWmK / lengthM;
    result.inValidityRange = result.reynolds <= 1.0e8 && air.prandtl >= 0.6 && air.prandtl <= 60.0;
    const double recovery = result.laminar ? std::sqrt(air.prandtl) : pr3;
    result.recoveryRiseK = recovery * speedMps * speedMps / (2.0 * air.specificHeatJkgK);
    return result;
}

double verticalPlateNaturalConvection(double heightM, double surfaceK, double airK, double pressurePa) {
    const double film = 0.5 * (surfaceK + airK);
    const auto air = airProperties(film, pressurePa);
    const double nu = air.viscosityPaS / air.densityKgM3;
    const double diffusivity = air.conductivityWmK / (air.densityKgM3 * air.specificHeatJkgK);
    const double rayleigh = kStandardGravity / film * std::fabs(surfaceK - airK) * std::pow(heightM, 3) / (nu * diffusivity);
    const double denominator = std::pow(1.0 + std::pow(0.492 / air.prandtl, 9.0 / 16.0), 8.0 / 27.0);
    const double root = 0.825 + 0.387 * std::pow(rayleigh, 1.0 / 6.0) / denominator;
    return root * root * air.conductivityWmK / heightM;
}

} // namespace cadnext::fea
