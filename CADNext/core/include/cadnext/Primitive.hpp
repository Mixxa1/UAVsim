#pragma once

#include <string>

namespace cadnext {

// CADNext 0.2 primitive descriptor.
// This is a construction/viewer descriptor, not the final BRep source of truth.
// In CADNext 0.3+ this will be backed by OCCT shapes.
enum class PrimitiveKind {
    None,
    Box,
    Cylinder,
    Sphere,
    Cone
};

struct PrimitiveParameters {
    PrimitiveKind kind = PrimitiveKind::None;

    // Box: width (X), depth (Y), height (Z).
    // Cylinder/Cone: radius + height (along Z).
    // Sphere: radius.
    // Reference plane (ObjectType::ReferencePlane, kind None): width + height.
    double width = 1.0;
    double height = 1.0;
    double depth = 1.0;

    double radius = 0.5;
};

inline const char* primitiveKindName(PrimitiveKind kind) {
    switch (kind) {
    case PrimitiveKind::Box: return "Box";
    case PrimitiveKind::Cylinder: return "Cylinder";
    case PrimitiveKind::Sphere: return "Sphere";
    case PrimitiveKind::Cone: return "Cone";
    case PrimitiveKind::None: return "None";
    }
    return "None";
}

inline PrimitiveKind primitiveKindFromName(const std::string& name) {
    if (name == "Box") return PrimitiveKind::Box;
    if (name == "Cylinder") return PrimitiveKind::Cylinder;
    if (name == "Sphere") return PrimitiveKind::Sphere;
    if (name == "Cone") return PrimitiveKind::Cone;
    return PrimitiveKind::None;
}

} // namespace cadnext
