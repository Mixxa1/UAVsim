#include "cadnext/Chamfer.hpp"

#include <cmath>

namespace cadnext {

bool chamferParametersValid(const ChamferParameters& parameters) {
    if (parameters.targetBodyId.empty() || parameters.edgeIds.empty()) {
        return false;
    }
    if (!std::isfinite(parameters.distanceMm) || parameters.distanceMm <= 0.0) {
        return false;
    }
    if (parameters.mode == ChamferMode::DistanceAngle) {
        // The chamfer plane degenerates at 0° and 90°.
        if (!std::isfinite(parameters.angleDeg) || parameters.angleDeg <= 0.0 ||
            parameters.angleDeg >= 90.0) {
            return false;
        }
    }
    return true;
}

const char* chamferModeName(ChamferMode mode) {
    switch (mode) {
    case ChamferMode::EqualDistance: return "EqualDistance";
    case ChamferMode::DistanceAngle: return "DistanceAngle";
    }
    return "DistanceAngle";
}

ChamferMode chamferModeFromName(const std::string& name) {
    if (name == "EqualDistance") {
        return ChamferMode::EqualDistance;
    }
    return ChamferMode::DistanceAngle;
}

} // namespace cadnext
