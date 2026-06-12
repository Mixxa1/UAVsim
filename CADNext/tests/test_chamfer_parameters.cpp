#include "cadnext/Chamfer.hpp"

#include <cassert>
#include <limits>
#include <string>

int main() {
    cadnext::ChamferParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {"edge-1-s-a-e-b-l-c"};
    parameters.distance = 0.1;
    assert(cadnext::chamferParametersValid(parameters));
    assert(parameters.mode == cadnext::ChamferMode::EqualDistance);
    assert(std::string(cadnext::chamferModeName(parameters.mode)) == "EqualDistance");
    assert(cadnext::chamferModeFromName("EqualDistance") ==
           cadnext::ChamferMode::EqualDistance);

    parameters.distance = 0.0;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.distance = -0.1;
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.distance = std::numeric_limits<double>::infinity();
    assert(!cadnext::chamferParametersValid(parameters));

    parameters.distance = 0.1;
    parameters.edgeIds.clear();
    assert(!cadnext::chamferParametersValid(parameters));
    parameters.edgeIds = {"edge-1"};
    parameters.targetBodyId.clear();
    assert(!cadnext::chamferParametersValid(parameters));

    return 0;
}
