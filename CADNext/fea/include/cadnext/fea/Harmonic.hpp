#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Modal.hpp"

#include <string>
#include <vector>

// Steady-state response to harmonic excitation (spec §6.2, vibration): what a vibration table or an
// unbalanced rotor does to the part, frequency by frequency — the amplitude of the motion and the
// dynamic stress that the modal test alone cannot give ("a mode sits in the band" says nothing about
// whether that is dangerous).
//
// Method: modal superposition with the static correction (the mode-acceleration method, Williams
// 1945; Craig & Kurdila, "Fundamentals of Structural Dynamics"):
//
//   u(ω) = K⁻¹P + Σ_r φ_r (φ_rᵀP) [ 1/(ω_r² − ω² + 2iζω_rω) − 1/ω_r² ]
//
// The first term is the exact static response to the load pattern P; the sum adds the dynamic part of
// each retained mode. Plain superposition (the sum without the static term and the −1/ω_r²) misses
// the quasi-static share of every mode that was not computed — local stress under a concentrated load
// above all — and that share does not shrink as ω → 0. With the correction the truncation error falls
// as (ω/ω_{N+1})². Damping is modal: one ratio ζ for every mode.
//
// Excitations:
//   base acceleration — the supports move together along a direction with a given acceleration
//     amplitude (a vibration table); the response is relative to them, so stresses come from the
//     deformation alone. Load P = −(M r)_f including the coupling of free DOFs to the supports.
//   face force — a force spread uniformly over a face (a motor mount); either a given amplitude or a
//     rotor imbalance U = m·e, whose force U·Ω² grows with the square of the frequency.
//
// Amplitudes are peak values of a sinusoid. Stress and displacement are reported as their peak over
// the cycle: components of a damped response are not in phase, so the largest von Mises during the
// cycle is not the von Mises of the component amplitudes. It is computed exactly (the largest
// eigenvalue of a 2×2 form), not by sampling phases.

namespace cadnext::fea {

enum class HarmonicExcitationKind {
    BaseAcceleration,
    FaceForce,
};

struct AmplitudePoint {
    double frequencyHz = 0.0;
    double amplitude = 0.0;
};

struct HarmonicExcitation {
    HarmonicExcitationKind kind = HarmonicExcitationKind::BaseAcceleration;
    Vec3 direction{0.0, 0.0, 1.0}; // normalised by the solver
    // Base: peak acceleration of the supports, m/s². Force: peak force, N. One point is a constant;
    // several are interpolated log–log in frequency and held constant beyond the ends (a sine-sweep
    // profile is given this way).
    std::vector<AmplitudePoint> amplitude;
    std::string faceGroup; // FaceForce only
    // FaceForce only: rotor imbalance U = m·e, kg·m. When positive, the force is U·Ω² with Ω the
    // excitation frequency, and `amplitude` must be empty.
    double imbalanceKgM = 0.0;
};

struct HarmonicProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints; // the fixture: zero relative displacement
    std::vector<AttachedMass> attachedMasses;
    HarmonicExcitation excitation;
    double dampingRatio = -1.0; // ζ of every mode; no default — it is a property of the build
    int modeCount = 0;          // no default either
    double minimumHz = 0.0, maximumHz = 0.0;
    // Optional: a face whose mean motion is reported (where an accelerometer would sit).
    std::string probeFaceGroup;
    // Optional, one flag per node: nodes left out of the stress maximum (exclusion zones around an
    // idealised support). The field still carries their values.
    std::vector<bool> stressExcluded;
};

enum class HarmonicMethod {
    // Modal superposition with the static correction. The production path.
    ModalSuperposition,
    // (K − ω²M) u = P solved directly at every frequency, undamped (ζ = 0 only). Exists as an
    // independent cross-check of the superposition, not for use.
    Direct,
};

struct HarmonicSettings {
    HarmonicMethod method = HarmonicMethod::ModalSuperposition;
    // Mode-acceleration correction; switched off only to measure what it contributes.
    bool staticCorrection = true;
    // Log-spaced points over the range; every resonance in the range adds 41 points across ±2ζ of
    // its frequency (spacing ζ/10: the peak is caught within 0.12 %).
    int sweepPoints = 200;
    // Explicit frequencies instead of the sweep.
    std::vector<double> frequenciesHz;
    ModalSettings modal;
};

struct HarmonicSample {
    double frequencyHz = 0.0;
    double excitation = 0.0;          // the amplitude applied at this frequency, m/s² or N
    double maxVonMisesPa = 0.0;       // peak over the cycle, largest over the nodes
    int maxVonMisesNode = -1;
    double maxDisplacementM = 0.0;    // peak over the cycle of |u| (relative to the base)
    int maxDisplacementNode = -1;
    double probeDisplacementM = 0.0;  // peak of the probe face's mean motion (relative)
    double probeAccelerationMs2 = 0.0; // peak of its absolute acceleration (base motion included)
};

struct HarmonicSolution {
    ModalSolution modal;
    std::vector<HarmonicSample> samples; // ascending frequency
    std::size_t worstSample = 0;         // highest stress
    // Field at the worst frequency, per node: peak von Mises over the cycle and the complex
    // displacement amplitude (real and imaginary parts).
    std::vector<double> worstVonMisesPa;
    std::vector<Vec3> worstDisplacementReal, worstDisplacementImag;
    // Base excitation: share of the free mass along the excitation direction that the retained
    // modes carry, Σ Γ_d² / m_free,d. Force excitation: NaN.
    double effectiveMassFraction = 0.0;
    double highestModeHz = 0.0;
    bool staticCorrection = true;
};

Result<HarmonicSolution> solveHarmonic(const HarmonicProblem& problem, const HarmonicSettings& settings = {});

// Peak over the cycle of the von Mises stress of Re(σ̂ e^{iωt}), for a complex amplitude given as its
// real and imaginary parts.
double peakVonMises(const Voigt& real, const Voigt& imaginary);
// Peak over the cycle of |Re(v̂ e^{iωt})|.
double peakMagnitude(const Vec3& real, const Vec3& imaginary);

} // namespace cadnext::fea
