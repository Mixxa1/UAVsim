#pragma once

#include <string>

namespace cadnext {

enum class RevolveAxis { U, V };

// The axis lies in the sketch plane. For U it is v=axisOffset;
// for V it is u=axisOffset. Angles are positive degrees.
struct RevolveParameters {
    std::string sketchId;
    std::string profileId;
    RevolveAxis axis = RevolveAxis::V;
    double axisOffset = 0.0;
    double angleDegrees = 360.0;
};

} // namespace cadnext
