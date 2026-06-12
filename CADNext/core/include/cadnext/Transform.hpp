#pragma once

#include "cadnext/Vector3.hpp"

namespace cadnext {

struct Transform {
    Vector3 position;
    Vector3 rotationEuler;
    Vector3 scale{1.0, 1.0, 1.0};
};

} // namespace cadnext
