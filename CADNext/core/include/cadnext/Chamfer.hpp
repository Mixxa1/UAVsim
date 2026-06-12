#pragma once

#include <string>
#include <vector>

namespace cadnext {

// Chamfer construction modes. DistanceAngle (distance + angle in degrees)
// is the default; EqualDistance keeps the classic symmetric 45°-style
// chamfer as an additional mode.
enum class ChamferMode {
    EqualDistance,
    DistanceAngle
};

struct ChamferParameters {
    std::string targetBodyId;
    std::vector<std::string> edgeIds;

    ChamferMode mode = ChamferMode::DistanceAngle;

    // User-facing units: millimeters and degrees. Conversion to model
    // units happens once, in the geometry evaluator.
    double distanceMm = 1.0;
    double angleDeg = 45.0;
};

bool chamferParametersValid(const ChamferParameters& parameters);
const char* chamferModeName(ChamferMode mode);
ChamferMode chamferModeFromName(const std::string& name);

} // namespace cadnext
