#include "cadnext/fea/Fire.hpp"

#include "cadnext/fea/Thermal.hpp"

#include <array>
#include <cmath>
#include <utility>
#include <vector>

namespace cadnext::fea {

namespace {

constexpr double kKelvin = 273.15;

// Linear between the table's points; the end values outside.
double interpolate(const std::vector<std::pair<double, double>>& table, double celsius) {
    if (celsius <= table.front().first) return table.front().second;
    for (std::size_t i = 1; i < table.size(); ++i) {
        if (celsius <= table[i].first) {
            const double w = (celsius - table[i - 1].first) / (table[i].first - table[i - 1].first);
            return table[i - 1].second * (1.0 - w) + table[i].second * w;
        }
    }
    return table.back().second;
}

// EN 1999-1-2 Table 2 (N/mm², all aluminium alloys), as a ratio to its own 20 °C value.
double modulusRatio(double kelvin) {
    static const std::vector<std::pair<double, double>> kTable = {{20, 70000}, {50, 69300}, {100, 67900}, {150, 65100}, {200, 60200},
                                                                  {250, 54600}, {300, 47600}, {350, 37800}, {400, 28000}, {550, 0}};
    return interpolate(kTable, kelvin - kKelvin) / 70000.0;
}

// EN 1999-1-2 Table 1a, EN AW-6061 T6.
double proofStrengthRatio6061T6(double kelvin) {
    static const std::vector<std::pair<double, double>> kTable = {{20, 1.00}, {100, 0.95}, {150, 0.91}, {200, 0.79},
                                                                  {250, 0.55}, {300, 0.31}, {350, 0.10}, {550, 0.0}};
    return interpolate(kTable, kelvin - kKelvin);
}

const char* kEurocode9 = "EN 1999-1-2:2007 (Eurocode 9, part 1-2): §3.2.2 ρ, §3.3.1 λ(θ), c(θ), Δl/l(θ) (0–500 °C), Table 2 E(θ)";

HotMaterial aluminium(double conductivitySlope, double conductivityAt0) {
    HotMaterial m;
    m.densityKgM3 = 2700.0;
    m.dataValidUpToK = 500.0 + kKelvin;
    m.conductivityWmK = [=](double k) { return conductivitySlope * (k - kKelvin) + conductivityAt0; };
    m.specificHeatJkgK = [](double k) { return 0.41 * (k - kKelvin) + 903.0; };
    m.thermalStrain = [](double k) {
        const double t = k - kKelvin;
        return 0.1e-7 * t * t + 22.5e-6 * t - 4.5e-4;
    };
    m.modulusRatio = modulusRatio;
    return m;
}

} // namespace

StandardFlame standardFlame(FireStandard standard) {
    if (standard == FireStandard::Iso2685) return {1100.0 + kKelvin, 116.0e3, "ISO 2685:1998: 1100 ± 80 °C, 116 ± 10 kW/m²"};
    // 2000 °F; 9.3 BTU/(ft² s) with 1 BTU/(ft² s) = 1055.056 J / 0.09290304 m² = 11 356.53 W/m².
    return {(2000.0 - 32.0) * 5.0 / 9.0 + kKelvin, 9.3 * 1055.05585262 / 0.09290304, "FAA AC 20-135: 2000 ± 150 °F, ≥ 9.3 BTU/(ft² s)"};
}

double flameConvectionCoefficient(const StandardFlame& flame) {
    return flame.calibrationFluxWm2 / (flame.temperatureK - kCalorimeterSurfaceK);
}

double flameEmissivity(const StandardFlame& flame) {
    return flame.calibrationFluxWm2 / (kStefanBoltzmann * (std::pow(flame.temperatureK, 4) - std::pow(kCalorimeterSurfaceK, 4)));
}

double flameHeatFlux(const StandardFlame& flame, FlameModel model, double surfaceK) {
    if (model == FlameModel::Convective) return flameConvectionCoefficient(flame) * (flame.temperatureK - surfaceK);
    return flameEmissivity(flame) * kStefanBoltzmann * (std::pow(flame.temperatureK, 4) - std::pow(surfaceK, 4));
}

std::optional<HotMaterial> hotMaterial(const std::string& materialId) {
    if (materialId == "al_6061_t6") {
        HotMaterial m = aluminium(0.07, 190.0);
        m.proofStrengthRatio = proofStrengthRatio6061T6;
        m.noStrengthK = 550.0 + kKelvin;
        m.source = std::string(kEurocode9) + "; Table 1a EN AW-6061 T6 k₀.₂(θ)";
        return m;
    }
    if (materialId == "al_7075_t6") {
        HotMaterial m = aluminium(0.1, 140.0);
        m.source = std::string(kEurocode9) + " (7xxx series); no k₀.₂(θ) for 7075 in Table 1a — нет данных о прочности при нагреве";
        return m;
    }
    return std::nullopt;
}

} // namespace cadnext::fea
