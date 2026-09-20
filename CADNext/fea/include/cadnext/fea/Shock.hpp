#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Harmonic.hpp"

#include <string>
#include <utility>
#include <vector>

// Mechanical shock (spec §6.2; MIL-STD-810H Method 516): the part on its fixture under a base
// acceleration pulse — a catapult launch, a landing, a drop — and the largest stress it reaches. A shock
// is one event: the verdict is the limit-load one, no fatigue involved.
//
// Method: the superposition basis of the vibration solvers (static correction + modes, modal ζ), in the
// time domain — the mode-acceleration form
//
//   u(t) = u_s a(t) + Σ_r φ_r ( q_r(t) − p_r a(t) / ω_r² ),   q̈_r + 2ζω_r q̇_r + ω_r² q_r = p_r a(t),
//
// u_s the static response to a unit base acceleration, p_r = φ_rᵀP. Each modal equation is integrated
// EXACTLY for an excitation that is linear over the step (Nigam & Jennings 1969; Chopra, "Dynamics of
// Structures", §5.2), so the step only decides how finely the pulse is sampled and how finely peaks are
// caught — not the accuracy of the modal response.
//
// Stress is the von Mises of the combined stress at each instant (a transient has one phase at a time);
// its maximum over the window and the nodes is the result, with the field at that instant.

namespace cadnext::fea {

enum class PulseShape {
    HalfSine,             // a(t) = A sin(πt/τ) on [0, τ]
    TerminalPeakSawtooth, // rises linearly to A at τ, then drops to zero
    Trapezoid,            // rise, plateau, fall — `riseS` and `fallS` inside τ
    TimeHistory,          // measured points (s, m/s²), linear between them, zero after the last
};

struct ShockPulse {
    PulseShape shape = PulseShape::HalfSine;
    double peakMs2 = 0.0;   // m/s²
    double durationS = 0.0; // τ
    double riseS = 0.0, fallS = 0.0;
    std::vector<std::pair<double, double>> history;

    double at(double t) const;
    double end() const; // when the pulse is over
};

struct ShockProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints; // the fixture
    std::vector<AttachedMass> attachedMasses;
    Vec3 direction{0.0, 0.0, 1.0};
    ShockPulse pulse;
    double dampingRatio = -1.0; // no default
    int modeCount = 0;          // no default
    std::string probeFaceGroup;
    std::vector<bool> stressExcluded;
};

struct ShockSettings {
    // Response window after the pulse, in periods of the first mode: each mode's residual motion peaks
    // within half its own period after the load ends, and two first-mode periods also let the modes beat.
    double residualPeriods = 2.0;
    // Samples per period of the highest retained mode (the modal solution is exact between samples;
    // this is how finely a peak is caught: 40 → within 0.3 % of that mode's amplitude).
    int samplesPerPeriod = 40;
    bool staticCorrection = true;
    ModalSettings modal;
};

struct ShockSolution {
    ModalSolution modal;
    std::vector<double> timeS, baseAccelerationMs2;
    std::vector<double> maxVonMisesPa;       // per instant, over the nodes (outside exclusion zones)
    std::vector<double> probeAccelerationMs2; // absolute, along the excitation direction; empty without a probe
    std::vector<double> probeDisplacementM;   // relative, along the excitation direction
    std::size_t worstSample = 0;
    double peakVonMisesPa = 0.0;
    int peakNode = -1;
    // Field at the worst instant: von Mises and displacement relative to the fixture.
    std::vector<double> worstVonMisesPa;
    std::vector<Vec3> worstDisplacement;
    double effectiveMassFraction = 0.0;
    double highestModeHz = 0.0;
};

Result<ShockSolution> solveShock(const ShockProblem& problem, const ShockSettings& settings = {});

// Exact response of q̈ + 2ζωq̇ + ω²q = f(t) to f sampled at uniform steps and linear between samples,
// from rest. Returns q and q̇ at the samples. Public for the tests and for the shock response spectrum.
void integrateModalResponse(double omega, double dampingRatio, double step, const std::vector<double>& force, std::vector<double>& q,
                            std::vector<double>& qDot);

// Maximax absolute-acceleration shock response spectrum of a base acceleration (uniform samples): the
// largest |ẍ_abs| of a single-degree-of-freedom oscillator with damping ζ at each natural frequency.
std::vector<double> shockResponseSpectrum(const std::vector<double>& baseAcceleration, double step, const std::vector<double>& frequenciesHz,
                                          double dampingRatio);

} // namespace cadnext::fea
