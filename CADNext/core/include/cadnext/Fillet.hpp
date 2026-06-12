#pragma once

#include <string>
#include <vector>

namespace cadnext {

struct FilletParameters {
    std::string targetBodyId;
    std::vector<std::string> edgeIds;

    // User-facing unit: millimeters. Conversion to model units happens
    // once, in the geometry evaluator.
    double radiusMm = 1.0;
};

bool filletParametersValid(const FilletParameters& parameters);

} // namespace cadnext
