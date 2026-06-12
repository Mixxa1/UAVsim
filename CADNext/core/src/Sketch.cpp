#include "cadnext/Sketch.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext {

namespace {

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vector3 normalizedOr(const Vector3& v, const Vector3& fallback) {
    const double length = std::sqrt(dot(v, v));
    if (length <= 1.0e-12 || !std::isfinite(length)) {
        return fallback;
    }
    return {v.x / length, v.y / length, v.z / length};
}

} // namespace

const char* sketchPlaneName(SketchPlane plane) {
    switch (plane) {
    case SketchPlane::XY: return "XY";
    case SketchPlane::XZ: return "XZ";
    case SketchPlane::YZ: return "YZ";
    }
    return "XY";
}

SketchPlane sketchPlaneFromName(const std::string& name) {
    if (name == "XZ") return SketchPlane::XZ;
    if (name == "YZ") return SketchPlane::YZ;
    return SketchPlane::XY;
}

const char* sketchReferenceTypeName(SketchReferenceType type) {
    switch (type) {
    case SketchReferenceType::CanonicalPlane: return "CanonicalPlane";
    case SketchReferenceType::WorkPlane: return "WorkPlane";
    case SketchReferenceType::BodyFace: return "BodyFace";
    }
    return "CanonicalPlane";
}

SketchReferenceType sketchReferenceTypeFromName(const std::string& name) {
    if (name == "WorkPlane") return SketchReferenceType::WorkPlane;
    // "Face" is the pre-0.8 spelling of the body-face reference type.
    if (name == "BodyFace" || name == "Face") return SketchReferenceType::BodyFace;
    return SketchReferenceType::CanonicalPlane;
}

const char* sketchEntityTypeName(SketchEntityType type) {
    switch (type) {
    case SketchEntityType::Line: return "Line";
    case SketchEntityType::Rectangle: return "Rectangle";
    case SketchEntityType::Circle: return "Circle";
    }
    return "Line";
}

SketchEntityType sketchEntityTypeFromName(const std::string& name) {
    if (name == "Rectangle") return SketchEntityType::Rectangle;
    if (name == "Circle") return SketchEntityType::Circle;
    return SketchEntityType::Line;
}

SketchEntity* findSketchEntity(Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    return it == sketch.entities.end() ? nullptr : &*it;
}

const SketchEntity* findSketchEntity(const Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    return it == sketch.entities.end() ? nullptr : &*it;
}

bool removeSketchEntity(Sketch& sketch, const std::string& entityId) {
    auto it = std::find_if(sketch.entities.begin(), sketch.entities.end(),
                           [&](const SketchEntity& entity) { return entity.id == entityId; });
    if (it == sketch.entities.end()) {
        return false;
    }
    sketch.entities.erase(it);
    return true;
}

Vector3 sketchPointToWorld(const SketchPoint2D& point, const SketchReference& reference) {
    return {reference.origin.x + reference.uAxis.x * point.u + reference.vAxis.x * point.v,
            reference.origin.y + reference.uAxis.y * point.u + reference.vAxis.y * point.v,
            reference.origin.z + reference.uAxis.z * point.u + reference.vAxis.z * point.v};
}

SketchPoint2D worldToSketchPoint(const Vector3& world, const SketchReference& reference) {
    const Vector3 delta{world.x - reference.origin.x,
                        world.y - reference.origin.y,
                        world.z - reference.origin.z};
    const Vector3 u = normalizedOr(reference.uAxis, {1.0, 0.0, 0.0});
    const Vector3 v = normalizedOr(reference.vAxis, {0.0, 1.0, 0.0});
    return {dot(delta, u), dot(delta, v)};
}

bool isWorldPointOnSketchPlane(const Vector3& world, const SketchReference& reference,
                               double tolerance) {
    const Vector3 delta{world.x - reference.origin.x,
                        world.y - reference.origin.y,
                        world.z - reference.origin.z};
    const Vector3 normal = normalizedOr(reference.normal, {0.0, 0.0, 1.0});
    return std::fabs(dot(delta, normal)) < tolerance;
}

} // namespace cadnext
