#pragma once

#include "cadnext/fea/Material.hpp"

#include <array>
#include <string>
#include <vector>

// How a structural result is shown — one definition for every surface that shows it (CADNext,
// the Workbench, the vehicle passport, the HTML report, replay). The field file carries these
// values, so a viewer draws what the solver side decided instead of re-deciding it.
//
// Two decisions live here, both about honesty rather than looks:
//
// 1. Colour means *utilisation* u = σ_vM / σ_allowable, with the allowable of the strength
//    check (min of yield and ultimate / factor of safety, CS-23.305). Not min–max of the field:
//    an auto-ranged plot paints every part red at its own maximum, including one with a reserve
//    factor of 18. Anything above u = 1 gets a colour outside the scale.
//
// 2. The scale is perceptually uniform (viridis, van der Walt & Smith 2015): equal steps in
//    utilisation read as equal steps in colour, and it survives colour-blind vision and
//    greyscale printing. The rainbow of most FEA viewers invents boundaries at yellow and cyan
//    that are not in the data.

namespace cadnext::fea {

struct ColorStop {
    double position = 0.0;
    std::array<float, 3> rgb{};
    std::string hex;
};

enum class AllowableBasis {
    Yield,
    UltimateOverFactorOfSafety,
};

struct AllowableStress {
    double stressPa = 0.0;
    AllowableBasis basis = AllowableBasis::Yield;
};

namespace presentation {

const std::vector<ColorStop>& utilizationStops();
const ColorStop& overflowColor();

// u in [0, 1] → scale colour; u > 1 → overflow colour; negative or non-finite → first stop.
std::array<float, 3> utilizationColor(double utilization);

AllowableStress allowableStress(const IsotropicMaterial& material, double factorOfSafety);

// Display-only magnification for the deformed shape: the largest displacement is drawn as 5 %
// of the part's bounding diagonal, never magnified below true scale. Always labelled "×N" by
// the viewer; it changes nothing in the analysis.
double deformationAutoScale(double maxDisplacementM, double boundingDiagonalM);

inline constexpr double kDeformationDisplayFraction = 0.05;

} // namespace presentation

} // namespace cadnext::fea
