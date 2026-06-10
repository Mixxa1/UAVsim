#pragma once

#include <string>

#include "cadnext/Vector3.hpp"

namespace cadnext::bridge {

struct AttachmentExport {
    std::string id;
    std::string name;
    std::string role;
    Vector3 localPosition;
    Vector3 localRotation;
};

} // namespace cadnext::bridge
