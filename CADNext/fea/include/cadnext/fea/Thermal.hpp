#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/TetMesh.hpp"

#include <functional>
#include <optional>
#include <string>
#include <vector>

// Heat conduction in a solid part (spec: thermal limits / climatic tests): temperatures from the
// ambient, the sun, the part's own electronics and radiation, steady or in time.
//
// Galerkin finite elements on the structural TET4/TET10 mesh with the temperature as the nodal
// unknown:  C Ṫ + K T = f,  K = ∫ ∇Nᵀ k ∇N dV + ∫_convection h N Nᵀ dA,  C = ∫ ρc N Nᵀ dV,
// f = ∫ q_V N dV + ∫ q_s N dA + ∫ h T∞ N dA. Radiation to surroundings εσ(T⁴ − T_s⁴) is nonlinear and is
// solved by Newton's method (its tangent 4εσT³ added to K). In time: the θ-method, θ = 1/2 (Crank–
// Nicolson, second order) by default, θ = 1 (backward Euler, first order but free of the oscillations
// Crank–Nicolson shows right after a sudden change) when asked; with radiation each step iterates on a
// factored operator (the chord method) and refactors only when that slows down. Air temperature and
// sunlight can follow a schedule in time (a climatic cycle); sunlight is shaded by the part itself.
//
// Temperatures in kelvin; faces are face groups of the mesh ("face-<index>" for CAD parts).

namespace cadnext::fea {

struct ThermalProperties {
    double conductivityWmK = 0.0;
    double densityKgM3 = 0.0;
    double specificHeatJkgK = 0.0; // only needed in time
    // Temperature-dependent conductivity and specific heat (a fire heats metal by hundreds of kelvin), in
    // place of the constants when set: evaluated at every quadrature point from the temperature there.
    // Steady: iterated to convergence. In time: each step is iterated with the properties taken at the
    // step's θ-weighted temperature (the midpoint for Crank–Nicolson), which keeps second order.
    std::function<double(double temperatureK)> conductivityOf;
    std::function<double(double temperatureK)> specificHeatOf;
};

struct FixedTemperature {
    std::string faceGroup;
    double temperatureK = 0.0;
};
struct Convection {
    std::string faceGroup;
    double coefficientWm2K = 0.0;
    double ambientK = 0.0;
};
// Heat flux into the part through a face, W/m² (absorbed sunlight: α · irradiance).
struct HeatFlux {
    std::string faceGroup;
    double fluxWm2 = 0.0;
};
// A heat source on a face (electronics mounted on it), total watts spread uniformly.
struct FaceHeatLoad {
    std::string faceGroup;
    double watts = 0.0;
};
struct Radiation {
    std::string faceGroup;
    double emissivity = 0.0;
    double surroundingsK = 0.0;
};

// Sunlight: parallel rays from the direction `towardSun` (from the part to the sun) with the irradiance
// E on a plane normal to them, absorbed as q = α E max(0, n·s) wherever the ray reaches the surface and
// zero where the part shades itself. Shading is decided at every quadrature point by a ray cast against
// the whole boundary of the mesh (the flat sub-triangles of its faces), so a partly shaded face converges
// with the mesh like any other load discontinuity.
struct Sunlight {
    std::vector<std::string> faceGroups; // faces that can receive it; empty: every face group of the mesh
    Vec3 towardSun{0.0, 0.0, 1.0};
    double absorptance = 0.0;
    double irradianceWm2 = 0.0;
};

struct ThermalProblem {
    const TetMesh* mesh = nullptr;
    ThermalProperties material;
    std::vector<FixedTemperature> fixed;
    std::vector<Convection> convection;
    std::vector<HeatFlux> fluxes;
    std::vector<FaceHeatLoad> heatLoads;
    std::vector<Radiation> radiation;
    std::optional<Sunlight> sunlight;
    double volumetricHeatWm3 = 0.0;
    // Or one value per element (the Joule heat of a lightning current, which follows the current's own
    // spreading); used in addition to the uniform one.
    std::vector<double> volumetricHeatPerElementWm3;
};

// What the sunlight does on this mesh: the absorbed power at its irradiance, and the sunlit area
// projected on the plane normal to the rays — for a closed body lit from all its faces that is exactly
// its silhouette (every ray stops at the first surface it meets), which is how the shading is verified.
struct SolarExposure {
    double absorbedW = 0.0;
    double sunlitProjectedAreaM2 = 0.0;
    double shadedAreaM2 = 0.0; // facing the sun, but shaded
};
Result<SolarExposure> solarExposure(const TetMesh& mesh, const Sunlight& sunlight);

struct ThermalSettings {
    int maximumNewtonIterations = 50;
    double newtonTolerance = 1e-10; // relative change of the temperature field
};

struct ThermalSolution {
    std::vector<double> temperatureK;
    double minimumK = 0.0, maximumK = 0.0;
    int maximumNode = -1;
    int newtonIterations = 0;
    // Heat balance: power in (sources, fluxes) against power out (convection, radiation, fixed faces),
    // relative — what the discrete solution leaves unbalanced.
    double balanceRelative = 0.0;
};

Result<ThermalSolution> solveSteadyThermal(const ThermalProblem& problem, const ThermalSettings& settings = {});

// Conditions that change in time — a climatic cycle. Each set function overrides the constant value of
// the problem: `airK` becomes the ambient of every convection entry (plus `convectionRiseK`) and the
// surroundings of every radiation entry (a climatic chamber, whose walls follow its air; in flight the
// sky and the ground are not modelled); `irradianceWm2` becomes the sunlight's irradiance.
struct ThermalSchedule {
    std::function<double(double timeS)> airK;
    // Multipliers in time for the loads that a current drives: the face fluxes and the equipment's watts
    // follow the current (an arc's heat is proportional to it), the volumetric sources follow its square
    // (Joule heating). Absent: constant.
    std::function<double(double timeS)> fluxScale;
    std::function<double(double timeS)> volumetricScale;
    // Added to the convection ambient only: the adiabatic-wall (recovery) temperature rise in flight.
    double convectionRiseK = 0.0;
    std::function<double(double timeS)> irradianceWm2;
};

struct TransientSettings {
    double stepS = 0.0;
    double endS = 0.0;
    double theta = 0.5;
    double initialK = 0.0; // uniform initial temperature…
    std::vector<double> initialFieldK; // …or one per node (fixed faces keep their own value)
    ThermalSettings newton;
    ThermalSchedule schedule;
};

struct TransientSolution {
    std::vector<double> timeS;
    std::vector<std::vector<double>> temperatureK; // per saved step, per node
    std::vector<double> maximumK;                   // per step, over the nodes
    int factorisations = 0;                         // of the step operator, for the record
};

// Called after every step with its end time and the nodal temperatures; returning false ends the run
// there (a periodic state reached, for one).
using TransientObserver = std::function<bool(double timeS, const std::vector<double>& temperatureK)>;

// `saveEvery` steps are kept (the first and the last always).
Result<TransientSolution> solveTransientThermal(const ThermalProblem& problem, const TransientSettings& settings, int saveEvery = 1,
                                                const TransientObserver& observer = {});

inline constexpr double kStefanBoltzmann = 5.670374419e-8; // W/(m² K⁴), CODATA 2018 (exact in the 2019 SI)

} // namespace cadnext::fea
