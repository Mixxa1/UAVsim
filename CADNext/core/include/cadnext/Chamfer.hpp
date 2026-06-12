#pragma once

#include <string>
#include <vector>

namespace cadnext {

enum class ChamferMode {
    EqualDistance
};

struct ChamferParameters {
    std::string targetBodyId;
    std::vector<std::string> edgeIds;

    ChamferMode mode = ChamferMode::EqualDistance;
    double distance = 0.1;
};

bool chamferParametersValid(const ChamferParameters& parameters);
const char* chamferModeName(ChamferMode mode);
ChamferMode chamferModeFromName(const std::string& name);

} // namespace cadnext
