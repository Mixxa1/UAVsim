#include "cadnext/Chamfer.hpp"

#include <cmath>

namespace cadnext {

bool chamferParametersValid(const ChamferParameters& parameters) {
    return !parameters.targetBodyId.empty() && !parameters.edgeIds.empty() &&
           std::isfinite(parameters.distance) && parameters.distance > 0.0;
}

const char* chamferModeName(ChamferMode mode) {
    switch (mode) {
    case ChamferMode::EqualDistance: return "EqualDistance";
    }
    return "EqualDistance";
}

ChamferMode chamferModeFromName(const std::string& name) {
    (void)name;
    return ChamferMode::EqualDistance;
}

} // namespace cadnext
