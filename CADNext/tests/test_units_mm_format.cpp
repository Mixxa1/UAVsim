#include "cadnext/Units.hpp"

#include <cassert>
#include <cmath>
#include <limits>
#include <string>

int main() {
    // Model unit ↔ millimeter conversion (1 unit = 1000 mm).
    assert(cadnext::kMillimetersPerModelUnit == 1000.0);
    assert(cadnext::toMillimeters(1.0) == 1000.0);
    assert(cadnext::toMillimeters(0.0246) == 24.6);
    assert(cadnext::fromMillimeters(1000.0) == 1.0);
    assert(std::fabs(cadnext::fromMillimeters(cadnext::toMillimeters(0.37)) - 0.37) <
           1.0e-12);

    // UI formatting: fixed decimals + the "мм" suffix.
    assert(cadnext::formatMillimeters(0.0246) == "24.600 мм");
    assert(cadnext::formatMillimeters(1.0) == "1000.000 мм");
    assert(cadnext::formatMillimeters(0.0) == "0.000 мм");
    assert(cadnext::formatMillimeters(0.001, 1) == "1.0 мм");
    assert(cadnext::formatMillimeters(0.5, 0) == "500 мм");
    assert(cadnext::formatMillimeters(0.5, -3) == "500 мм");

    // Broken geometry must never format as a plausible number.
    assert(cadnext::formatMillimeters(std::numeric_limits<double>::quiet_NaN()) == "— мм");
    assert(cadnext::formatMillimeters(std::numeric_limits<double>::infinity()) == "— мм");

    return 0;
}
