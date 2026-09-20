#include "cadnext/fea/ClimaticCycles.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea {

namespace {

constexpr double kKelvin = 273.15;

double fahrenheitToCelsius(double f) {
    return (f - 32.0) * 5.0 / 9.0;
}

// Tables 501.7-II/III list hours 0100…2400; hour 0 is the 2400 value.
std::array<double, 25> fromTable(const std::array<double, 24>& hour1to24F) {
    std::array<double, 25> c{};
    c[0] = fahrenheitToCelsius(hour1to24F[23]);
    for (int h = 1; h <= 24; ++h) c[h] = fahrenheitToCelsius(hour1to24F[h - 1]);
    return c;
}

double interpolate(const std::array<double, 25>& values, double timeS) {
    double t = std::fmod(timeS, kDaySeconds);
    if (t < 0.0) t += kDaySeconds;
    const double hour = t / 3600.0;
    const int h = std::min(23, static_cast<int>(std::floor(hour)));
    const double w = hour - h;
    return values[h] * (1.0 - w) + values[h + 1] * w;
}

double mean(const std::array<double, 25>& values) {
    double sum = 0.0;
    for (int h = 0; h < 24; ++h) sum += 0.5 * (values[h] + values[h + 1]);
    return sum / 24.0;
}

} // namespace

double DiurnalCycle::airK(double timeS) const {
    return interpolate(airC, timeS) + kKelvin;
}
double DiurnalCycle::irradianceWm2(double timeS) const {
    return interpolate(solarWm2, timeS);
}
double DiurnalCycle::meanAirK() const {
    return mean(airC) + kKelvin;
}
double DiurnalCycle::meanIrradianceWm2() const {
    return mean(solarWm2);
}
double DiurnalCycle::peakAirK() const {
    return *std::max_element(airC.begin(), airC.end()) + kKelvin;
}

DiurnalCycle hotCycle(HotCategory category, HotExposure exposure) {
    DiurnalCycle cycle;
    const bool a1 = category == HotCategory::A1HotDry;
    if (exposure == HotExposure::Sun) {
        static constexpr std::array<double, 25> kA1{37, 35, 34, 34, 33, 33, 32, 33, 35, 38, 41, 43, 44, 47, 48, 48, 49, 48, 48, 46, 42, 41, 39, 38, 37};
        static constexpr std::array<double, 25> kA2{33, 33, 32, 32, 31, 30, 30, 31, 34, 37, 39, 41, 42, 43, 44, 44, 44, 43, 42, 40, 38, 36, 35, 34, 33};
        static constexpr std::array<double, 25> kSun{0, 0, 0, 0, 0, 0, 55, 270, 505, 730, 915, 1040, 1120, 1120, 1040, 915, 730, 505, 270, 55, 0, 0, 0, 0, 0};
        cycle.airC = a1 ? kA1 : kA2;
        cycle.solarWm2 = kSun;
        cycle.source = std::string("MIL-STD-810H, Method 505.7, Figure 505.7-1 (Procedure I), category ") + (a1 ? "A1" : "A2");
        return cycle;
    }
    // °F, hours 0100…2400.
    static constexpr std::array<double, 24> kA1Ambient{95, 94, 93, 92, 91, 90, 91, 95, 101, 106, 110, 112, 116, 118, 119, 120, 119, 118, 114, 108, 105, 102, 100, 98};
    static constexpr std::array<double, 24> kA1Induced{95, 94, 94, 92, 92, 91, 97, 104, 111, 124, 133, 145, 156, 158, 160, 158, 153, 145, 131, 118, 105, 103, 99, 95};
    static constexpr std::array<double, 24> kA2Ambient{91, 90, 90, 88, 86, 86, 88, 93, 99, 102, 106, 107, 109, 110, 110, 110, 109, 107, 104, 100, 97, 95, 93, 91};
    static constexpr std::array<double, 24> kA2Induced{91, 90, 90, 88, 86, 88, 93, 101, 107, 113, 124, 134, 142, 145, 145, 144, 140, 134, 122, 111, 101, 95, 93, 91};
    const bool induced = exposure == HotExposure::Induced;
    cycle.airC = fromTable(a1 ? (induced ? kA1Induced : kA1Ambient) : (induced ? kA2Induced : kA2Ambient));
    cycle.source = std::string("MIL-STD-810H, Method 501.7, Table ") + (a1 ? "501.7-III (A1)" : "501.7-II (A2)")
                   + (induced ? ", induced (storage and transit) air" : ", ambient air") + ", °F values";
    return cycle;
}

ColdCondition coldCondition(ColdCategory category, ColdExposure exposure) {
    const bool induced = exposure == ColdExposure::Induced;
    ColdCondition condition;
    switch (category) {
    case ColdCategory::C1BasicCold: condition.airC = induced ? -33.0 : -32.0; break;
    case ColdCategory::C2Cold: condition.airC = -46.0; break;
    case ColdCategory::C3SevereCold: condition.airC = -51.0; break;
    }
    const char* name = category == ColdCategory::C1BasicCold ? "C1" : category == ColdCategory::C2Cold ? "C2" : "C3";
    condition.source = std::string("MIL-STD-810H, Method 502.7, Table 502.7-I, category ") + name
                       + (induced ? ", induced (storage and transit)" : ", ambient air") + ", lowest value of the range";
    return condition;
}

} // namespace cadnext::fea
