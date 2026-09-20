#pragma once

#include <array>
#include <string>

// MIL-STD-810H climatic conditions as the standard tabulates them (the 2019 edition, assist.dla.mil).
// Values are the standard's own; between its hours they are joined by straight lines, as Figure 505.7-1
// draws them and as its Procedure I allows ("applied continuously").
//
// Hot (categories A1 Hot Dry and A2 Basic Hot):
//   - with sun: Method 505.7, Figure 505.7-1 — the air temperature and the solar irradiance of each hour,
//     peak 1120 W/m² (not at the hour of the hottest air). Procedure I of that method, the cycling test.
//   - shaded: Method 501.7, Tables 501.7-III (A1) and -II (A2), ambient air.
//   - induced: the same tables, "induced (storage and transit)" air — already raised by the sun on a
//     shelter or a container, so no sun on top of it.
// Tables 501.7-II/III were recorded in °F and converted (their note 3 warns the °C column is not
// consistent); the °F values are used here, converted exactly. Figure 505.7-1 is given in °C only.
//
// Cold (categories C1 Basic Cold, C2 Cold, C3 Severe Cold): Method 502.7, Table 502.7-I, "the lowest value
// in each range is usually considered" (its §2.3.1a); the sun is left out, as that method says its effect
// at low temperatures is minimal.

namespace cadnext::fea {

enum class HotCategory { A1HotDry, A2BasicHot };
enum class HotExposure { Sun, Shade, Induced };
enum class ColdCategory { C1BasicCold, C2Cold, C3SevereCold };
enum class ColdExposure { Ambient, Induced };

struct DiurnalCycle {
    std::array<double, 25> airC{};       // hours 0…24 (24 is the next day's 0)
    std::array<double, 25> solarWm2{};   // on a plane normal to the rays; zeros without sun
    std::string source;
    double airK(double timeS) const;         // periodic in 24 h
    double irradianceWm2(double timeS) const;
    double meanAirK() const;                 // over the day, of the piecewise-linear curve
    double meanIrradianceWm2() const;
    double peakAirK() const;
};

DiurnalCycle hotCycle(HotCategory category, HotExposure exposure);

struct ColdCondition {
    double airC = 0.0;
    std::string source;
};
ColdCondition coldCondition(ColdCategory category, ColdExposure exposure);

inline constexpr double kDaySeconds = 86400.0;

// Chamber air speed the standard sets: Method 505.7 Procedure I 1.5–3.0 m/s (not below 0.25 m/s for an
// item shielded from wind); Methods 501.7 and 502.7 no more than 1.7 m/s near the test item.
inline constexpr double kSolarTestAirSpeedMinMps = 1.5, kSolarTestAirSpeedMaxMps = 3.0, kShieldedAirSpeedMinMps = 0.25;
inline constexpr double kTemperatureTestAirSpeedMaxMps = 1.7;

} // namespace cadnext::fea
