#include "cadnext/fea/StructuralPresentation.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::fea::presentation {

namespace {

ColorStop stop(double position, int r, int g, int b, const char* hex) {
    return {position, {r / 255.0f, g / 255.0f, b / 255.0f}, hex};
}

} // namespace

const std::vector<ColorStop>& utilizationStops() {
    // viridis at tenths (matplotlib `viridis`, the values its documentation and colormap
    // references publish: #440154 … #21918c … #fde725).
    static const std::vector<ColorStop> stops = {
        stop(0.0, 68, 1, 84, "#440154"),   stop(0.1, 72, 36, 117, "#482475"),
        stop(0.2, 65, 68, 135, "#414487"),  stop(0.3, 53, 95, 141, "#355f8d"),
        stop(0.4, 42, 120, 142, "#2a788e"), stop(0.5, 33, 145, 140, "#21918c"),
        stop(0.6, 34, 168, 132, "#22a884"), stop(0.7, 68, 191, 112, "#44bf70"),
        stop(0.8, 122, 209, 81, "#7ad151"), stop(0.9, 189, 223, 38, "#bddf26"),
        stop(1.0, 253, 231, 37, "#fde725"),
    };
    return stops;
}

const ColorStop& overflowColor() {
    // Dark crimson: outside viridis in hue *and* much darker than its bright yellow end, so a
    // region above the allowable separates from one just below it even in greyscale.
    static const ColorStop overflow = stop(1.0, 178, 24, 43, "#b2182b");
    return overflow;
}

std::array<float, 3> utilizationColor(double u) {
    const auto& stops = utilizationStops();
    if (!std::isfinite(u) || u <= 0.0) return stops.front().rgb;
    if (u > 1.0) return overflowColor().rgb;
    for (std::size_t i = 1; i < stops.size(); ++i) {
        if (u <= stops[i].position) {
            const double t = (u - stops[i - 1].position) / (stops[i].position - stops[i - 1].position);
            std::array<float, 3> color{};
            for (int c = 0; c < 3; ++c) {
                color[c] = static_cast<float>(stops[i - 1].rgb[c] + (stops[i].rgb[c] - stops[i - 1].rgb[c]) * t);
            }
            return color;
        }
    }
    return stops.back().rgb;
}

AllowableStress allowableStress(const IsotropicMaterial& material, double factorOfSafety) {
    const double ultimate = material.ultimateStrengthPa / factorOfSafety;
    if (material.yieldStrengthPa && *material.yieldStrengthPa <= ultimate) {
        return {*material.yieldStrengthPa, AllowableBasis::Yield};
    }
    return {ultimate, AllowableBasis::UltimateOverFactorOfSafety};
}

double deformationAutoScale(double maxDisplacementM, double boundingDiagonalM) {
    if (!(maxDisplacementM > 0.0) || !(boundingDiagonalM > 0.0)) return 1.0;
    return std::max(1.0, kDeformationDisplayFraction * boundingDiagonalM / maxDisplacementM);
}

} // namespace cadnext::fea::presentation
