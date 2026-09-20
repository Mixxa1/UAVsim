#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/Harmonic.hpp"

#include <string>
#include <vector>

// Random vibration (spec §6.2, vibration): the part on its fixture under a stationary Gaussian base
// acceleration given by its power spectral density — the qualification test for equipment carried on
// an airframe, and what the airframe's own vibration does to the part.
//
// Frequency domain, on the superposition basis of the sine solver (static correction + modes, modal ζ):
// every response is linear in the base acceleration, y(f) = Σ_j c_j(f) Y_j per unit acceleration, so
// the covariance of all responses follows from one J × J matrix
//
//   A_jk = ∫ Re(c_j c_k*) S_a(f) df
//
// integrated once over the spectrum. The mean square of any quadratic quantity is then a quadratic
// form in the basis responses at a node — no per-node frequency loop:
//
//   E[σ_vm²] = Σ_jk A_jk q(S_j, S_k),  q the von Mises form (its diagonal is σ_vm²)
//
// This is the RMS von Mises of Segalman et al. (Sandia, 2000) — the mean square of the von Mises
// stress of a Gaussian stress tensor, exact, not the von Mises of component RMS values (which is not a
// stress at all: components peak at different times). Displacements alike: E[|u|²] = Σ A_jk U_j·U_k.
//
// The integral is taken by the trapezoid rule over the spectrum's span on a grid that is log-spaced and
// dense across every resonance (±10ζ at spacing ζ/10: a Lorentzian tail beyond ±2ζ still carries 30 % of
// the area, so the dense band has to be wide). Outside the span the PSD is zero.

namespace cadnext::fea {

struct RandomVibrationProblem {
    const TetMesh* mesh = nullptr;
    IsotropicMaterial material;
    std::vector<DisplacementConstraint> constraints; // the fixture
    std::vector<AttachedMass> attachedMasses;
    Vec3 direction{0.0, 0.0, 1.0};
    // Acceleration PSD of the base, (m/s²)²/Hz, at ascending frequencies; log–log between points
    // (a constant slope in dB/octave, as test profiles are written), zero outside the first–last span.
    std::vector<AmplitudePoint> accelerationPsd;
    double dampingRatio = -1.0; // no default
    int modeCount = 0;          // no default
    std::string probeFaceGroup;
    std::vector<bool> stressExcluded;
};

struct RandomVibrationSettings {
    int backgroundPoints = 400;
    bool staticCorrection = true;
    // Explicit integration grid instead of the automatic one (tests).
    std::vector<double> frequenciesHz;
    ModalSettings modal;
};

struct RandomVibrationSolution {
    ModalSolution modal;
    double inputRmsMs2 = 0.0; // √∫S_a df
    // Per node: RMS von Mises (Segalman) and RMS |u| relative to the fixture.
    std::vector<double> rmsVonMisesPa;
    std::vector<double> rmsDisplacementM;
    double maxRmsVonMisesPa = 0.0; // outside exclusion zones
    int maxRmsVonMisesNode = -1;
    double maxRmsDisplacementM = 0.0;
    int maxRmsDisplacementNode = -1;
    double probeRmsDisplacementM = 0.0;
    double probeRmsAccelerationMs2 = 0.0; // absolute (base motion included)
    // The integration grid and the spectra on it: input, probe absolute acceleration ((m/s²)²/Hz),
    // and the von Mises "PSD" of the critical node — the integrand of E[σ_vm²], Pa²/Hz.
    std::vector<double> frequencyHz, inputPsd, probeAccelerationPsd, criticalStressPsd;
    // √(m₂/m₀) of the critical node's integrand: its apparent frequency, the number a fatigue
    // estimate starts from (cycles per second of the stress).
    double criticalApparentFrequencyHz = 0.0;
    double effectiveMassFraction = 0.0;
    double highestModeHz = 0.0;
};

Result<RandomVibrationSolution> solveRandomVibration(const RandomVibrationProblem& problem, const RandomVibrationSettings& settings = {});

// ∫ S df of a PSD table by the same log–log law (exact for each segment's power law), m²/s⁴ → RMS².
double psdMeanSquare(const std::vector<AmplitudePoint>& psd);

} // namespace cadnext::fea
