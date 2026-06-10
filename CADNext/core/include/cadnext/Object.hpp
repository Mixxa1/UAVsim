#pragma once

#include <string>
#include <vector>

#include "cadnext/AttachmentPoint.hpp"
#include "cadnext/Primitive.hpp"
#include "cadnext/Transform.hpp"

namespace cadnext {

enum class ObjectType {
    Body,
    Sketch,
    Assembly,
    ReferencePlane,
    Unknown
};

struct Object {
    std::string id;
    std::string name;
    ObjectType type = ObjectType::Unknown;
    Transform transform;
    PrimitiveParameters primitive;
    std::vector<AttachmentPoint> attachmentPoints;
};

} // namespace cadnext
