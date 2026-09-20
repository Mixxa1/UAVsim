#pragma once

#include "cadnext/Result.hpp"

#include <functional>
#include <optional>
#include <string>
#include <vector>

// Pyrolysis of a solid under radiant heating: how fast it turns into fuel gas, how hot it gets behind, and
// when it is gone. This is the condensed-phase half of flammability — what a cone calorimeter or a
// gasification apparatus measures; the flame itself is not modelled.
//
// One dimension through the thickness, finite volumes on a Lagrangian grid: every cell keeps its own solid
// mass, and its thickness is that mass over the material's density, so a cell that has gasified shrinks to
// nothing and the surface recedes — without that a non-charring polymer would leave a vacuum where it
// burnt away and stop conducting heat.
//
// Per cell:  Σ m_i c_p Ṫ = q_in − q_out + ε q_e α e^{−αx} dx − Σ ΔH_r ω_r
// with reactions in series, each first order in its species' mass and Arrhenius in temperature:
//   ω_r = A_r e^{−E_r/(R T)} m_r,   m_r → yield_r · m_{r+1} + (1 − yield_r) gas.
// Over a step the temperature is held fixed for the species, which have the closed-form solution of a
// first-order chain — no stiff ODE to integrate. The gas leaves at once: transport and pressure inside the
// solid are not modelled, and neither is swelling.
//
// Surface: the incident radiant flux is absorbed in depth (Beer–Lambert with the material's absorption
// coefficient), the surface re-radiates εσ(T⁴ − T_wall⁴) and loses convection h(T − T_gas). Behind the
// sample any number of inert layers (the backing insulation of a test) and then an adiabatic back.

namespace cadnext::fea {

struct PyrolysisReaction {
    double preExponentialPerS = 0.0;
    double activationEnergyJPerMol = 0.0;
    double solidYield = 0.0;          // of the mass consumed, the share that stays solid (the next species)
    double heatOfReactionJPerKg = 0.0; // > 0 endothermic
};

// The MaCFP property files' form: two straight lines that change over at `boundaryK` — and do not have to
// meet there (the PMMA set steps by 163 J/(kg K) at its glass transition). A property that jumps makes a
// cell sitting on the boundary flip branches from one iteration of a step to the next and never settle, so
// the two lines are blended over ±`kPropertyBlendK` around it. The band is far narrower than any
// temperature the result is read at.
inline constexpr double kPropertyBlendK = 1.0;

struct PiecewiseLinear {
    double boundaryK = 0.0;
    double slope[2] = {0.0, 0.0};
    double intercept[2] = {0.0, 0.0};
    double at(double temperatureK) const;
};

struct PyrolysisMaterial {
    std::string id, source;
    double densityKgM3 = 0.0;
    double absorptionPerM = 0.0; // in-depth absorption of the incident radiation
    double emissivity = 0.0;
    PiecewiseLinear specificHeatJkgK, conductivityWmK;
    std::vector<PyrolysisReaction> reactions; // in series
};

// Only materials with a published, citable property set.
std::optional<PyrolysisMaterial> pyrolysisMaterial(const std::string& id);

// An inert layer behind the sample (backing insulation).
struct InertLayer {
    double thicknessM = 0.0;
    double densityKgM3 = 0.0;
    double specificHeatJkgK = 0.0;
    std::function<double(double temperatureK)> conductivityWmK;
    int cells = 10;
};

struct PyrolysisProblem {
    PyrolysisMaterial material;
    double thicknessM = 0.0;
    int cells = 200;
    std::vector<InertLayer> backing;
    // Incident radiant flux in time (the shutter of a test opens at t = 0 and the heater's flux settles).
    std::function<double(double timeS)> incidentFluxWm2;
    double convectionWm2K = 0.0;
    double gasK = 293.15;   // the gas the surface convects to
    double wallK = 293.15;  // what the surface radiates to
    double initialK = 293.15;
};

struct PyrolysisSettings {
    double stepS = 0.0;
    double endS = 0.0;
    int saveEvery = 1;
    int maximumIterations = 20;
    double tolerance = 1e-9; // relative change of the temperature field within a step
};

struct PyrolysisSolution {
    std::vector<double> timeS;
    std::vector<double> massLossRateGm2s;  // of the sample, per unit of its original area
    std::vector<double> surfaceK;
    std::vector<double> backOfSampleK;     // at the sample's back face (where a test's thermocouples sit)
    std::vector<double> remainingMassFraction;
    std::vector<double> thicknessM;
};

Result<PyrolysisSolution> solvePyrolysis(const PyrolysisProblem& problem, const PyrolysisSettings& settings);

inline constexpr double kGasConstant = 8.31446261815324; // J/(mol K), CODATA 2018 (exact in the 2019 SI)

} // namespace cadnext::fea
