#include "cadnext/Fillet.hpp"

#include <cassert>
#include <limits>

int main() {
    cadnext::FilletParameters parameters;
    parameters.targetBodyId = "body-1";
    parameters.edgeIds = {"edge-1-s-a-e-b-l-c"};
    parameters.radius = 0.1;
    assert(cadnext::filletParametersValid(parameters));

    parameters.radius = 0.0;
    assert(!cadnext::filletParametersValid(parameters));
    parameters.radius = -0.1;
    assert(!cadnext::filletParametersValid(parameters));
    parameters.radius = std::numeric_limits<double>::infinity();
    assert(!cadnext::filletParametersValid(parameters));

    parameters.radius = 0.1;
    parameters.edgeIds.clear();
    assert(!cadnext::filletParametersValid(parameters));
    parameters.edgeIds = {"edge-1"};
    parameters.targetBodyId.clear();
    assert(!cadnext::filletParametersValid(parameters));

    return 0;
}
