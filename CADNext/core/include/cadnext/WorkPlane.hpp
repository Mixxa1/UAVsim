#pragma once

#include <string>

#include "cadnext/Object.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/Vector3.hpp"

namespace cadnext {

// Selectable work plane (Sketch Plane UX stage). The three canonical
// planes always exist at the UI level — they are NOT document objects and
// can never be deleted through the document. Reference-plane objects and
// (later) body faces are adapted into WorkPlane on demand.
enum class WorkPlaneKind {
    XY,
    XZ,
    YZ,
    ObjectPlane,
    FacePlane
};

struct WorkPlane {
    std::string id;
    std::string name;
    WorkPlaneKind kind = WorkPlaneKind::XY;

    Vector3 origin;
    Vector3 uAxis{1.0, 0.0, 0.0};
    Vector3 vAxis{0.0, 1.0, 0.0};
    Vector3 normal{0.0, 0.0, 1.0};

    double width = 1.0;
    double height = 1.0;
};

// Stable ids of the canonical planes: "workplane-xy" / "workplane-xz" /
// "workplane-yz".
const char* canonicalWorkPlaneId(SketchPlane plane);

// Canonical plane following the documented u/v convention
// (XY: u=X,v=Y,n=Z | XZ: u=X,v=Z,n=Y | YZ: u=Y,v=Z,n=X).
WorkPlane makeCanonicalWorkPlane(SketchPlane plane, double extent);

// Adapts a ReferencePlane document object into a work plane: origin from
// the object position, axes rotated by the object's rotationEuler
// (degrees, applied X then Y then Z), size from the primitive descriptor.
WorkPlane workPlaneFromReferencePlaneObject(const Object& object);

// Builds the sketch reference recorded inside a Sketch for a work plane.
SketchReference sketchReferenceFromWorkPlane(const WorkPlane& plane);

// Reference for a bare canonical plane enum (legacy files and convenience).
SketchReference canonicalSketchReference(SketchPlane plane);

// Side of the plane a normal-to-plane (Sketch2D) camera must sit on so
// that +U points right and +V points up on screen with camera up = vAxis:
// +1 for a right-handed u/v/normal triad, -1 for a left-handed one (the
// canonical XZ plane, where u x v == -normal).
double planeNormalViewSide(const Vector3& uAxis, const Vector3& vAxis, const Vector3& normal);

} // namespace cadnext
