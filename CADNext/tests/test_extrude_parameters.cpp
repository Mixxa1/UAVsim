#include "cadnext/Extrude.hpp"

#include <cassert>
#include <cmath>
#include <limits>
#include <string>

int main() {
    // Defaults match the v1 contract.
    cadnext::ExtrudeParameters defaults;
    assert(defaults.operation == cadnext::ExtrudeOperation::NewBody);
    assert(defaults.direction == cadnext::ExtrudeDirection::Positive);
    assert(defaults.depthMode == cadnext::ExtrudeDepthMode::Distance);
    assert(defaults.distance == 1.0);

    // Valid parameters: ids set, finite positive distance.
    cadnext::ExtrudeParameters valid;
    valid.sketchId = "sketch-1";
    valid.profileId = "profile-1";
    valid.distance = 2.5;
    assert(cadnext::extrudeParametersValid(valid));

    // Distance <= 0 is invalid.
    cadnext::ExtrudeParameters zero = valid;
    zero.distance = 0.0;
    assert(!cadnext::extrudeParametersValid(zero));
    cadnext::ExtrudeParameters negative = valid;
    negative.distance = -1.0;
    assert(!cadnext::extrudeParametersValid(negative));

    // Non-finite distance is invalid.
    cadnext::ExtrudeParameters notFinite = valid;
    notFinite.distance = std::numeric_limits<double>::quiet_NaN();
    assert(!cadnext::extrudeParametersValid(notFinite));
    notFinite.distance = std::numeric_limits<double>::infinity();
    assert(!cadnext::extrudeParametersValid(notFinite));

    // Missing ids are invalid.
    cadnext::ExtrudeParameters noSketch = valid;
    noSketch.sketchId.clear();
    assert(!cadnext::extrudeParametersValid(noSketch));
    cadnext::ExtrudeParameters noProfile = valid;
    noProfile.profileId.clear();
    assert(!cadnext::extrudeParametersValid(noProfile));

    // Serialization names round-trip.
    assert(std::string(cadnext::extrudeOperationName(cadnext::ExtrudeOperation::NewBody)) ==
           "NewBody");
    assert(cadnext::extrudeOperationFromName("NewBody") == cadnext::ExtrudeOperation::NewBody);
    for (const cadnext::ExtrudeDirection direction :
         {cadnext::ExtrudeDirection::Positive, cadnext::ExtrudeDirection::Negative,
          cadnext::ExtrudeDirection::Symmetric}) {
        assert(cadnext::extrudeDirectionFromName(
                   cadnext::extrudeDirectionName(direction)) == direction);
    }
    assert(std::string(cadnext::extrudeDepthModeName(cadnext::ExtrudeDepthMode::Distance)) ==
           "Distance");
    assert(cadnext::extrudeDepthModeFromName("Distance") ==
           cadnext::ExtrudeDepthMode::Distance);

    return 0;
}
