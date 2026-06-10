#pragma once

#include <string>

#include "cadnext/Vector3.hpp"

namespace cadnext {

enum class AttachmentRole {
    Frame,
    Wing,
    Payload,
    Camera,
    Sensor,
    LandingGear,
    Motor,
    Battery,
    Antenna,
    Generic
};

struct AttachmentPoint {
    std::string id;
    std::string name;
    Vector3 localPosition;
    Vector3 localRotation;
    AttachmentRole role = AttachmentRole::Generic;
    bool isSystem = true;
    bool isEnabled = true;
};

} // namespace cadnext
