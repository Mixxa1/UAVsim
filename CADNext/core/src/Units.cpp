#include "cadnext/Units.hpp"

#include <cmath>
#include <cstdio>

namespace cadnext {

double toMillimeters(double modelLength) {
    return modelLength * kMillimetersPerModelUnit;
}

double fromMillimeters(double millimeters) {
    return millimeters / kMillimetersPerModelUnit;
}

std::string formatMillimeters(double modelLength, int decimals) {
    if (!std::isfinite(modelLength)) {
        return "— мм"; // "— мм"
    }
    if (decimals < 0) {
        decimals = 0;
    }
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", decimals, toMillimeters(modelLength));
    return std::string(buffer) + " мм";
}

} // namespace cadnext
