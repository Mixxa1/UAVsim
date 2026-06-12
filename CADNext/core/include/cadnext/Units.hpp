#pragma once

#include <string>

namespace cadnext {

enum class UnitSystem {
    Metric,
    Imperial
};

// CADNext model lengths are stored in model units (1 unit = 1 m). All
// user-facing linear dimensions are presented in millimeters; these two
// helpers are the single conversion point between the model and the UI.
inline constexpr double kMillimetersPerModelUnit = 1000.0;

double toMillimeters(double modelLength);
double fromMillimeters(double millimeters);

// "24.600 мм" (fixed decimals, UTF-8). Non-finite values come back as
// "— мм" so broken geometry never formats as a plausible number.
std::string formatMillimeters(double modelLength, int decimals = 3);

} // namespace cadnext
