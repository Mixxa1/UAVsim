#pragma once

#include "cadnext/Vector3.hpp"

namespace cadnext::bridge {

struct MassPropertiesExport {
    double massKg = 0.0;
    Vector3 centerOfMass;
    Vector3 boundingBoxMin;
    Vector3 boundingBoxMax;
};

} // namespace cadnext::bridge
