#pragma once

#include <string>
#include <vector>

// Natural frequencies against excitation bands (spec §6.2: "Natural mode 121 Hz; propeller
// excitation 118–126 Hz → WARNING, resonance overlap").
//
// A rotor excites the structure mainly at its rotation frequency 1P (imbalance) and at the
// blade-passing frequency NP (N blades); over an RPM range each is a band. Other harmonics (2P,
// 2NP, engine firing orders) are real too but depend on the machine — they are added as explicit
// bands rather than guessed.
//
// Separation margin: widens every band by ± that fraction. Deliberately zero unless the analyst
// sets it — there is no single standard margin for UAV airframes, and a made-up one would turn
// into warnings nobody can justify. The actual margin of every mode to every band is reported
// either way.

namespace cadnext::fea {

struct ExcitationBand {
    std::string name;
    double minimumHz = 0.0;
    double maximumHz = 0.0;
};

struct RotorExcitation {
    std::string name;
    double minimumRpm = 0.0;
    double maximumRpm = 0.0;
    int bladeCount = 2;
};

// 1P and NP bands of a rotor.
std::vector<ExcitationBand> rotorExcitationBands(const RotorExcitation& rotor);

struct ResonanceFinding {
    int modeIndex = 0; // 0-based
    double frequencyHz = 0.0;
    std::string band;
    // Signed distance from the (margin-widened) band, as a fraction of the mode frequency:
    // negative inside, zero at the edge, positive outside.
    double separation = 0.0;
    bool overlaps = false;
};

// For every mode, its nearest band. A mode whose frequency uncertainty band reaches into an
// excitation band counts as overlapping: a resonance cannot be ruled out by a number that the mesh
// does not support.
std::vector<ResonanceFinding> assessResonance(const std::vector<double>& frequenciesHz,
                                              const std::vector<double>& uncertaintiesHz,
                                              const std::vector<ExcitationBand>& bands, double separationMargin);

} // namespace cadnext::fea
