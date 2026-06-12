#pragma once

#include <string>
#include <vector>

namespace cadnext {

struct FilletParameters {
    std::string targetBodyId;
    std::vector<std::string> edgeIds;
    double radius = 0.1;
};

bool filletParametersValid(const FilletParameters& parameters);

} // namespace cadnext
