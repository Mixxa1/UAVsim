#include "cadnext/Chamfer.hpp"

#include <cassert>
#include <limits>
#include <string>

int main() {
    cadnext::ChamferParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {"edge-1-s-a-e-b-l-c"};

    // Defaults: distance + angle mode, 45 degrees.
    assert(parameters.mode == cadnext::ChamferMode::DistanceAngle);
    assert(parameters.angleDeg == 45.0);
    assert(parameters.distanceMm == 1.0);
    assert(cadnext::chamferParametersValid(parameters));

    // Mode names roundtrip for both modes.
    assert(std::string(cadnext::chamferModeName(cadnext::ChamferMode::DistanceAngle)) ==
           "DistanceAngle");
    assert(std::string(cadnext::chamferModeName(cadnext::ChamferMode::EqualDistance)) ==
           "EqualDistance");
    assert(cadnext::chamferModeFromName("DistanceAngle") ==
           cadnext::ChamferMode::DistanceAngle);
    assert(cadnext::chamferModeFromName("EqualDistance") ==
           cadnext::ChamferMode::EqualDistance);
    assert(cadnext::chamferModeFromName("unknown") == cadnext::ChamferMode::DistanceAngle);

    // Distance validation.
    parameters.distanceMm = 0.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.distanceMm = -0.1;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.distanceMm = std::numeric_limits<double>::infinity();
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.distanceMm = 1.0;
    assert(cadnext::chamferParametersValid(parameters));

    // Angle validation only applies to the distance+angle mode.
    parameters.angleDeg = 0.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.angleDeg = 90.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.angleDeg = -30.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.angleDeg = std::numeric_limits<double>::quiet_NaN();
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.angleDeg = 30.0;
    assert(cadnext::chamferParametersValid(parameters));

    parameters.mode = cadnext::ChamferMode::EqualDistance;
    parameters.angleDeg = 0.0; // ignored in EqualDistance mode
    assert(cadnext::chamferParametersValid(parameters));

    // Target/edge validation.
    parameters.mode = cadnext::ChamferMode::DistanceAngle;
    parameters.angleDeg = 45.0;
    parameters.edgeIds.clear();
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.edgeIds = {"edge-1"};
    parameters.targetBodyId.clear();
    assert(!cadnext::chamferParametersValid(parameters));

    return 0;
}
