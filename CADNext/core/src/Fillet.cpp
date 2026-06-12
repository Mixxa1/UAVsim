#include "cadnext/Fillet.hpp"

#include <cmath>

namespace cadnext {

bool filletParametersValid(const FilletParameters& parameters) {
    return !parameters.targetBodyId.empty() && !parameters.edgeIds.empty() &&
           std::isfinite(parameters.radiusMm) && parameters.radiusMm > 0.0;
}

} // namespace cadnext
