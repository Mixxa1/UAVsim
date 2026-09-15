// The presentation contract every viewer draws from (StructuralPresentation.hpp).

#include "fea_test_support.hpp"

#include "cadnext/fea/Material.hpp"
#include "cadnext/fea/StructuralPresentation.hpp"

#include <cmath>

using namespace cadnext::fea;
using fea_test::check;

int main() {
    const auto& stops = presentation::utilizationStops();
    bool ascending = stops.front().position == 0.0 && stops.back().position == 1.0;
    for (std::size_t i = 1; i < stops.size(); ++i) ascending = ascending && stops[i].position > stops[i - 1].position;
    check(ascending, "colour stops cover [0, 1] in ascending order");

    // viridis is perceptually uniform only if its lightness rises monotonically; check the
    // stops keep that property (Rec. 709 luma as a proxy).
    auto luma = [](const std::array<float, 3>& c) { return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
    bool brighter = true;
    for (std::size_t i = 1; i < stops.size(); ++i) brighter = brighter && luma(stops[i].rgb) > luma(stops[i - 1].rgb);
    check(brighter, "lightness rises monotonically along the scale");
    check(luma(presentation::overflowColor().rgb) < luma(stops.back().rgb) * 0.5,
          "overflow colour is far darker than the top of the scale, so it separates in greyscale");

    check(presentation::utilizationColor(0.0) == stops.front().rgb, "u = 0 → first stop");
    check(presentation::utilizationColor(1.0) == stops.back().rgb, "u = 1 → last stop (still allowed)");
    check(presentation::utilizationColor(1.0000001) == presentation::overflowColor().rgb, "u > 1 → overflow colour");
    check(presentation::utilizationColor(NAN) == stops.front().rgb, "non-finite → first stop, never overflow");
    const auto mid = presentation::utilizationColor(0.55);
    bool between = true;
    for (int c = 0; c < 3; ++c) {
        const double lo = std::min(stops[5].rgb[c], stops[6].rgb[c]), hi = std::max(stops[5].rgb[c], stops[6].rgb[c]);
        between = between && mid[c] >= lo - 1e-6 && mid[c] <= hi + 1e-6;
    }
    check(between, "u = 0.55 interpolates between the 0.5 and 0.6 stops");

    const auto steel = presentation::allowableStress(*findMaterial("steel_4130"), 1.5);
    check(steel.basis == AllowableBasis::Yield && std::fabs(steel.stressPa - 435e6) < 1, "4130: yield (435) governs over 670/1.5");
    const auto aluminium = presentation::allowableStress(*findMaterial("al_6061_t6"), 1.5);
    check(aluminium.basis == AllowableBasis::UltimateOverFactorOfSafety && std::fabs(aluminium.stressPa - 310e6 / 1.5) < 1,
          "6061: 310/1.5 governs over yield 276");
    const auto carbon = presentation::allowableStress(*findMaterial("cfrp_quasi_isotropic"), 1.5);
    check(carbon.basis == AllowableBasis::UltimateOverFactorOfSafety, "laminate without yield: ultimate / FoS");

    check(std::fabs(presentation::deformationAutoScale(1e-5, 0.2) - 1000.0) < 1e-9, "tiny deflection magnified to 5 % of the diagonal");
    check(presentation::deformationAutoScale(0.05, 0.2) == 1.0, "large deflection is never shrunk below true scale");
    check(presentation::deformationAutoScale(0.0, 0.2) == 1.0, "no deflection → true scale");

    return fea_test::finish("test_fea_presentation");
}
