#pragma once

#include <functional>
#include <optional>
#include <string>

// What a fire test needs beyond heat conduction: the standard flame, and the material as it is when hot.
//
// The standard flame (ISO 2685:1998 and FAA AC 20-135): a burner flame of a stated temperature that,
// calibrated, delivers a stated heat flux density into a calorimeter —
//   ISO 2685     1100 ± 80 °C, 116 ± 10 kW/m²;
//   AC 20-135    2000 ± 150 °F, at least 9.3 BTU/(ft² s) (105.6 kW/m²);
// "fire resistant" for 5 minutes, "fireproof" for 15. The standards give these two numbers only; how the
// flux splits between convection and radiation is not stated, and it matters once the surface is hot
// (radiation keeps pushing heat in, convection fades as the surface nears the flame). So both limits:
//   Convective   q = h (T_f − T),        h fitted so that q(T_cal) is the calibration flux;
//   Radiative    q = ε σ (T_f⁴ − T⁴),    ε fitted likewise;
// with the calorimeter's surface at T_cal = 20 °C (water-cooled; the standards do not state its temperature,
// and a colder one would fit a smaller h and ε — the test's flux is then an upper bound on what we apply).
// The surface is taken to absorb as the black calorimeter did: conservative for a shiny part.
//
// Aluminium in a fire: EN 1999-1-2:2007 (Eurocode 9 part 1-2), characteristic values, γ_M,fi = 1.0 (its
// §2.3, recommended):
//   §3.3.1.1  Δl/l = 0.1·10⁻⁷ θ² + 22.5·10⁻⁶ θ − 4.5·10⁻⁴              (0 < θ < 500 °C, all alloys)
//   §3.3.1.2  c = 0.41 θ + 903 J/(kg °C)                              (0 < θ < 500 °C, all alloys)
//   §3.3.1.3  λ = 0.07 θ + 190 W/(m °C) (3xxx, 6xxx), 0.1 θ + 140 (5xxx, 7xxx) (0 < θ < 500 °C)
//   §3.2.2    ρ = 2700 kg/m³
//   Table 2   E(θ), all alloys, after two hours at temperature
//   Table 1a  k₀.₂(θ) = f₀.₂(θ)/f₀.₂ per alloy and temper — 6061-T6 is listed, 7075 is not (nor in Table
//             1b's scope, which covers the alloys of EN 1999-1-1), so 7075 has no strength data here.
// Between tabulated temperatures linearly, as the standard allows. Above 500 °C the thermal formulas are
// outside their range; the study says so. Above 550 °C every tabulated alloy has no strength left.

namespace cadnext::fea {

enum class FireStandard { Iso2685, Ac20135 };
enum class FlameModel { Convective, Radiative };

struct StandardFlame {
    double temperatureK = 0.0;
    double calibrationFluxWm2 = 0.0;
    std::string source;
};

StandardFlame standardFlame(FireStandard standard);

inline constexpr double kCalorimeterSurfaceK = 293.15;
inline constexpr double kFireResistantS = 300.0; // 5 min
inline constexpr double kFireproofS = 900.0;     // 15 min
// EN 1991-1-2 §3.1(5): convection on the side of a member away from the fire; radiation separately.
inline constexpr double kUnexposedConvectionWm2K = 4.0;
inline constexpr double kLaboratoryK = 293.15;

double flameConvectionCoefficient(const StandardFlame& flame); // W/(m² K), the convective limit
double flameEmissivity(const StandardFlame& flame);            // the radiative limit's ε
double flameHeatFlux(const StandardFlame& flame, FlameModel model, double surfaceK);

// A material's properties as the fire heats it. Temperatures in kelvin; the ratios are to 20 °C values.
struct HotMaterial {
    std::string source;
    double densityKgM3 = 0.0;
    double dataValidUpToK = 0.0; // the range of the thermal formulas
    std::function<double(double)> conductivityWmK;
    std::function<double(double)> specificHeatJkgK;
    std::function<double(double)> thermalStrain; // Δl/l from 20 °C
    std::function<double(double)> modulusRatio;  // E(θ)/E(20 °C)
    std::function<double(double)> proofStrengthRatio; // k₀.₂(θ); empty: no data
    std::optional<double> noStrengthK; // where k₀.₂ reaches zero (550 °C in Table 1a)
};

// Only materials with a published high-temperature data set; nothing is borrowed from a neighbour alloy.
std::optional<HotMaterial> hotMaterial(const std::string& materialId);

} // namespace cadnext::fea
