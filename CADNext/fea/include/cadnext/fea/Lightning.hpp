#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/fea/TetMesh.hpp"

#include <string>
#include <vector>

// The lightning environment of SAE ARP5412 and what the current does to a metal part it passes through.
//
// Test waveforms (ARP5412 "Aircraft Lightning Environment and Related Test Waveforms"):
//   A  first return stroke, 200 kA ± 10 %, action integral ∫i² dt = 2·10⁶ A² s ± 20 %, over in 500 µs;
//   B  intermediate current, 2 kA average over 5 ms, 10 C ± 10 %;
//   C  continuing current, 200 C ± 20 % at 200–800 A (0.25–1 s);
//   D  subsequent stroke, 100 kA ± 10 %, action integral 0.25·10⁶ A² s.
// A, B and D are the double exponential I(t) = I₀(e^{−αt} − e^{−βt}) that a capacitor bank produces; the
// coefficients used here are the ones commonly published for these components, and the test checks that
// they reproduce the standard's own numbers (peak, action integral, charge). C is a steady current.
//
// At the attachment point the heat the arc puts into the metal is carried by the current itself: the
// electrons are accelerated through the anode voltage drop and release the work function on entry, both
// about 4–5 V, so the flux is q ≈ 10 J for an anode and, as an upper bound, q ≈ 24 J for a cathode
// (J = I/πR², the current density at the arc root) — Chemartin et al., "Direct Effects of Lightning on
// Aircraft Structure", ONERA AerospaceLab Issue 5 (2012), AL05-09, after Kaddani et al. (1994). The arc
// plasma itself is not modelled: the radius of its root is an input, not a result.
//
// Inside the metal the current spreads by the same Laplace equation as steady heat conduction, with the
// electrical conductivity in place of the thermal one, so it is solved by the same solver; its Joule heat
// σ|∇φ|² then drives the transient thermal problem.

namespace cadnext::fea {

enum class LightningComponent { A, B, C, D };
enum class ArcPolarity { Anode, Cathode };

struct CurrentWaveform {
    // Double exponential (A, B, D); zero amplitude means the steady current of component C.
    double amplitudeA = 0.0, alphaPerS = 0.0, betaPerS = 0.0;
    double steadyA = 0.0, steadyDurationS = 0.0;
    std::string source;

    double at(double timeS) const;
    double durationS() const;          // how long the component is worth integrating
    double peakA() const;
    double actionIntegralA2s() const;  // ∫i² dt in closed form
    double chargeC() const;            // ∫i dt in closed form
};

CurrentWaveform lightningComponent(LightningComponent component);

// q'' into the metal at the arc root (W/m²) for the current of the moment.
double arcHeatFluxWm2(double currentA, double arcRootRadiusM, ArcPolarity polarity);
inline constexpr double kAnodeVoltsPerCurrent = 10.0;  // V, anode drop + work function
inline constexpr double kCathodeVoltsPerCurrent = 24.0; // V, upper bound for a cathode

// Current spread through a part: `currentA` enters over the injection faces and leaves through the faces
// held at zero potential. Potential per node, Joule heat per element (W/m³ at that current), and the
// resistance the current meets between them.
struct CurrentSpread {
    std::vector<double> potentialV;
    std::vector<double> jouleWm3;
    double resistanceOhm = 0.0;
    double balanceRelative = 0.0; // what the discrete solution leaves unbalanced (current in vs out)
};

Result<CurrentSpread> solveCurrentSpread(const TetMesh& mesh, double resistivityOhmM, const std::vector<std::string>& injectionFaces,
                                         const std::vector<std::string>& groundFaces, double currentA);

} // namespace cadnext::fea
