#include "cadnext/WorkPlane.hpp"

#include <cmath>

namespace cadnext {

namespace {

constexpr double kDegreesToRadians = 3.14159265358979323846 / 180.0;

Vector3 cross(Vector3 a, Vector3 b) {
    return {a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x};
}

Vector3 normalized(Vector3 v, Vector3 fallback) {
    const double length = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    if (length <= 1.0e-12 || !std::isfinite(length)) {
        return fallback;
    }
    return {v.x / length, v.y / length, v.z / length};
}

Vector3 rotateAroundX(Vector3 v, double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return {v.x, v.y * c - v.z * s, v.y * s + v.z * c};
}

Vector3 rotateAroundY(Vector3 v, double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return {v.x * c + v.z * s, v.y, -v.x * s + v.z * c};
}

Vector3 rotateAroundZ(Vector3 v, double radians) {
    const double c = std::cos(radians);
    const double s = std::sin(radians);
    return {v.x * c - v.y * s, v.x * s + v.y * c, v.z};
}

Vector3 rotateEulerXYZ(Vector3 v, Vector3 degrees) {
    v = rotateAroundX(v, degrees.x * kDegreesToRadians);
    v = rotateAroundY(v, degrees.y * kDegreesToRadians);
    v = rotateAroundZ(v, degrees.z * kDegreesToRadians);
    return v;
}

} // namespace

const char* canonicalWorkPlaneId(SketchPlane plane) {
    switch (plane) {
    case SketchPlane::XY:
        return "workplane-xy";
    case SketchPlane::XZ:
        return "workplane-xz";
    case SketchPlane::YZ:
        return "workplane-yz";
    }
    return "workplane-xy";
}

WorkPlane makeCanonicalWorkPlane(SketchPlane plane, double extent) {
    WorkPlane workPlane;
    workPlane.id = canonicalWorkPlaneId(plane);
    workPlane.name = sketchPlaneName(plane);
    workPlane.width = extent;
    workPlane.height = extent;
    switch (plane) {
    case SketchPlane::XY:
        workPlane.kind = WorkPlaneKind::XY;
        workPlane.uAxis = {1.0, 0.0, 0.0};
        workPlane.vAxis = {0.0, 1.0, 0.0};
        workPlane.normal = {0.0, 0.0, 1.0};
        break;
    case SketchPlane::XZ:
        workPlane.kind = WorkPlaneKind::XZ;
        workPlane.uAxis = {1.0, 0.0, 0.0};
        workPlane.vAxis = {0.0, 0.0, 1.0};
        workPlane.normal = {0.0, 1.0, 0.0};
        break;
    case SketchPlane::YZ:
        workPlane.kind = WorkPlaneKind::YZ;
        workPlane.uAxis = {0.0, 1.0, 0.0};
        workPlane.vAxis = {0.0, 0.0, 1.0};
        workPlane.normal = {1.0, 0.0, 0.0};
        break;
    }
    return workPlane;
}

WorkPlane workPlaneFromReferencePlaneObject(const Object& object) {
    WorkPlane workPlane;
    workPlane.id = object.id;
    workPlane.name = object.name;
    workPlane.kind = WorkPlaneKind::ObjectPlane;
    workPlane.origin = object.transform.position;
    workPlane.uAxis = normalized(rotateEulerXYZ({1.0, 0.0, 0.0},
                                                object.transform.rotationEuler),
                                 {1.0, 0.0, 0.0});
    workPlane.vAxis = normalized(rotateEulerXYZ({0.0, 1.0, 0.0},
                                                object.transform.rotationEuler),
                                 {0.0, 1.0, 0.0});
    workPlane.normal = normalized(cross(workPlane.uAxis, workPlane.vAxis),
                                  rotateEulerXYZ({0.0, 0.0, 1.0},
                                                 object.transform.rotationEuler));
    workPlane.width = object.primitive.width * object.transform.scale.x;
    workPlane.height = object.primitive.height * object.transform.scale.y;
    if (workPlane.width <= 0.0 || !std::isfinite(workPlane.width)) {
        workPlane.width = 1.0;
    }
    if (workPlane.height <= 0.0 || !std::isfinite(workPlane.height)) {
        workPlane.height = 1.0;
    }
    return workPlane;
}

SketchReference sketchReferenceFromWorkPlane(const WorkPlane& plane) {
    SketchReference reference;
    reference.type = (plane.kind == WorkPlaneKind::ObjectPlane)
                         ? SketchReferenceType::WorkPlane
                         : (plane.kind == WorkPlaneKind::FacePlane ? SketchReferenceType::Face
                                                                   : SketchReferenceType::CanonicalPlane);
    reference.sourceId = plane.id;
    reference.origin = plane.origin;
    reference.uAxis = normalized(plane.uAxis, {1.0, 0.0, 0.0});
    reference.vAxis = normalized(plane.vAxis, {0.0, 1.0, 0.0});
    reference.normal = normalized(plane.normal, normalized(cross(reference.uAxis, reference.vAxis),
                                                           {0.0, 0.0, 1.0}));
    return reference;
}

SketchReference canonicalSketchReference(SketchPlane plane) {
    return sketchReferenceFromWorkPlane(makeCanonicalWorkPlane(plane, 1.0));
}

double planeNormalViewSide(const Vector3& uAxis, const Vector3& vAxis, const Vector3& normal) {
    const Vector3 handed = cross(uAxis, vAxis);
    const double alignment = handed.x * normal.x + handed.y * normal.y + handed.z * normal.z;
    return alignment < 0.0 ? -1.0 : 1.0;
}

} // namespace cadnext
