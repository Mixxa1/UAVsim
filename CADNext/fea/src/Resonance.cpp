#include "cadnext/fea/Resonance.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace cadnext::fea {

std::vector<ExcitationBand> rotorExcitationBands(const RotorExcitation& rotor) {
    const double low = rotor.minimumRpm / 60.0;
    const double high = rotor.maximumRpm / 60.0;
    return {
        {rotor.name + " 1P", low, high},
        {rotor.name + " " + std::to_string(rotor.bladeCount) + "P", low * rotor.bladeCount, high * rotor.bladeCount},
    };
}

std::vector<ResonanceFinding> assessResonance(const std::vector<double>& frequencies, const std::vector<double>& uncertainties,
                                              const std::vector<ExcitationBand>& bands, double margin) {
    std::vector<ResonanceFinding> findings;
    if (bands.empty()) return findings;
    for (std::size_t i = 0; i < frequencies.size(); ++i) {
        const double f = frequencies[i];
        const double u = i < uncertainties.size() ? uncertainties[i] : 0.0;
        ResonanceFinding best;
        best.separation = std::numeric_limits<double>::infinity();
        for (const auto& band : bands) {
            const double low = band.minimumHz * (1.0 - margin);
            const double high = band.maximumHz * (1.0 + margin);
            // Distance of f from [low, high]: negative inside.
            double distance;
            if (f < low) {
                distance = low - f;
            } else if (f > high) {
                distance = f - high;
            } else {
                distance = -std::min(f - low, high - f);
            }
            const double separation = f > 0.0 ? distance / f : distance;
            if (separation < best.separation) {
                best.separation = separation;
                best.band = band.name;
                best.overlaps = distance <= u; // inside, or within the mesh uncertainty of the edge
            }
        }
        best.modeIndex = static_cast<int>(i);
        best.frequencyHz = f;
        findings.push_back(best);
    }
    return findings;
}

} // namespace cadnext::fea
