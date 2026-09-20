#pragma once

#include "cadnext/Result.hpp"

#include <complex>
#include <functional>
#include <string>
#include <vector>

// Flutter and divergence of a lifting surface: at what speed the air starts feeding energy into the
// structure's own modes instead of taking it out.
//
// The aerodynamics is Theodorsen's (NACA TR-496, 1935): a flat plate in incompressible flow, moving
// in plunge and pitch about an elastic axis, with the circulatory part lagged by C(k) — the ratio of
// Hankel functions that says how much of the quasi-steady lift a wake-shedding aerofoil actually
// gets at a reduced frequency k = ωb/V. The non-circulatory (apparent-mass) part is exact.
//
// The structure is a typical section: mass m, static unbalance S_α about the elastic axis, inertia
// I_α, and springs K_h and K_α. A real wing reaches this through its own modes, one strip at a time
// (Flutter.hpp of the study side).
//
// What this is not: no compressibility (Theodorsen is incompressible; above about Mach 0.6 the
// method is outside its ground and says so), no three-dimensional or tip effects beyond what strip
// theory carries, no control-surface freedom, no structural damping unless it is given, no stall.
// Transonic flutter — the dip that decides a real aircraft's envelope — is not here at all.

namespace cadnext::fea {

// C(k) = H₁⁽²⁾(k) / [H₁⁽²⁾(k) + i H₀⁽²⁾(k)]. One at k = 0, one half as k → ∞.
std::complex<double> theodorsen(double reducedFrequency);

// A section of a wing, per unit span.
struct TypicalSection {
    double semichordM = 0.0;        // b
    double elasticAxis = 0.0;       // a: where the axis is, in semichords from mid-chord, positive aft
    double massKgPerM = 0.0;        // m
    double staticUnbalanceKgM = 0.0; // S_α = m·b·x_α, positive when the centre of mass is aft of the axis
    double inertiaKgM = 0.0;        // I_α about the elastic axis, per unit span
    double plungeStiffnessNPerM2 = 0.0;  // K_h
    double pitchStiffnessNmPerRad = 0.0; // K_α
    double structuralDamping = 0.0;      // g, the same for both freedoms unless given otherwise
    double airDensityKgM3 = 1.225;
};

// The speed at which the torsional spring can no longer hold the section against its own lift:
// q_div = K_α / (2π b² · (a + ½) · 2), in closed form — the static limit that any unsteady solver
// must reproduce as its zero-frequency instability.
double divergenceSpeedMps(const TypicalSection& section);

struct FlutterPoint {
    double speedMps = 0.0;
    double frequencyHz = 0.0;
    double dampingRatio = 0.0;   // negative is stable; the crossing through zero is flutter
    double reducedFrequency = 0.0;
    int branch = 0;
};

struct FlutterSolution {
    double flutterSpeedMps = 0.0;     // the lowest speed at which a branch crosses into growth
    double flutterFrequencyHz = 0.0;
    double divergenceSpeedMps = 0.0;      // the closed form
    double divergenceFoundMps = 0.0;      // where the swept static determinant actually changed sign
    bool flutterFound = false;
    std::vector<FlutterPoint> branches; // every branch at every speed, in the order they were swept
    std::vector<std::string> warnings;
};

struct FlutterSweep {
    double lowSpeedMps = 5.0;
    double highSpeedMps = 200.0;
    int speeds = 80;
    int iterations = 40; // of the reduced frequency, per branch per speed
};

// The p-k method: at each speed, each branch's frequency and damping are found by iterating the
// reduced frequency until the aerodynamics and the eigenvalue agree. Flutter is where the damping
// of a branch crosses zero from below.
Result<FlutterSolution> solveFlutter(const TypicalSection& section, const FlutterSweep& sweep = {});

// A wing reaches flutter through its own modes, not through a section: two mass-normalised modes
// (so the generalized mass matrix is the identity and the stiffness is the squared frequencies) and
// the generalized aerodynamic matrix that the strips of the wing add up to. The convention is the
// section's: (I p² + K + Q(k, U)) q = 0, with q the modal amplitudes.
struct GeneralizedFlutterSystem {
    double frequencyRadS[2] = {0.0, 0.0};
    double structuralDamping = 0.0;
    double referenceSemichordM = 0.0; // the b that the reduced frequency k = ωb/U is measured with
    // Fills a row-major 2 × 2 with the generalized aerodynamic matrix at this reduced frequency and
    // speed. Called many times: it should be cheap.
    std::function<void(double reducedFrequency, double speedMps, std::complex<double>* matrix)> aerodynamics;
    // The same at zero frequency, for the static determinant that finds divergence.
    std::function<void(double speedMps, std::complex<double>* matrix)> steadyAerodynamics;
};

Result<FlutterSolution> solveFlutterGeneralized(const GeneralizedFlutterSystem& system, const FlutterSweep& sweep = {});

// The k-method (the classical "V-g" solution): the same aerodynamics, but with the artificial
// structural damping g that makes the motion exactly harmonic. Used here as the independent check on
// the p-k answer — at the flutter point the two must agree.
Result<FlutterSolution> solveFlutterVG(const TypicalSection& section, const FlutterSweep& sweep = {});

} // namespace cadnext::fea
