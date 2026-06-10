#pragma once

#include <string>

namespace cadnext {

struct Material {
    std::string id;
    std::string name;
    double densityKgPerM3 = 0.0;
};

} // namespace cadnext
