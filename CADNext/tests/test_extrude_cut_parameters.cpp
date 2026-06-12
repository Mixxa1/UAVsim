#include "cadnext/ExtrudeCut.hpp"

#include <cassert>

namespace {

cadnext::ExtrudeCutParameters validDistance() {
    cadnext::ExtrudeCutParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.sketchId = "sketch-1";
    parameters.profileId = "profile-1";
    parameters.depthMode = cadnext::CutDepthMode::Distance;
    parameters.direction = cadnext::CutDirection::Positive;
    parameters.distance = 1.0;
    return parameters;
}

} // namespace

int main() {
    assert(!cadnext::extrudeCutParametersValid({}));

    cadnext::ExtrudeCutParameters parameters = validDistance();
    assert(cadnext::extrudeCutParametersValid(parameters));

    parameters.distance = 0.0;
    assert(!cadnext::extrudeCutParametersValid(parameters));

    parameters = validDistance();
    parameters.depthMode = cadnext::CutDepthMode::ThroughAll;
    parameters.distance = 0.0;
    assert(cadnext::extrudeCutParametersValid(parameters));

    parameters = validDistance();
    parameters.depthMode = cadnext::CutDepthMode::ToObject;
    parameters.limitObjectId = "body-2";
    assert(cadnext::extrudeCutParametersValid(parameters));

    parameters.direction = cadnext::CutDirection::Symmetric;
    assert(!cadnext::extrudeCutParametersValid(parameters));

    parameters.direction = cadnext::CutDirection::Negative;
    parameters.limitObjectId.clear();
    assert(!cadnext::extrudeCutParametersValid(parameters));

    assert(cadnext::cutDepthModeFromName("ThroughAll") == cadnext::CutDepthMode::ThroughAll);
    assert(cadnext::cutDepthModeFromName("ToObject") == cadnext::CutDepthMode::ToObject);
    assert(cadnext::cutDirectionFromName("Negative") == cadnext::CutDirection::Negative);
    assert(cadnext::cutDirectionFromName("Symmetric") == cadnext::CutDirection::Symmetric);

    return 0;
}
