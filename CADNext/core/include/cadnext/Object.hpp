#pragma once

#include <string>
#include <cstdint>
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
    // Exact geometry for bodies imported from an external CAD file. Kept
    // inside .cadnext so reopening the document does not depend on the
    // original exchange file or substitute a placeholder primitive.
    std::vector<std::uint8_t> importedBRep;
    std::vector<AttachmentPoint> attachmentPoints;
};

} // namespace cadnext
