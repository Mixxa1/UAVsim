#include "cadnext/Sketch.hpp"
#include "cadnext/WorkPlane.hpp"

#include <cassert>
#include <cmath>

// Canonical Sketch2D view convention: the plane U axis maps to the screen
// horizontal and V to the screen vertical when the camera sits on the
// planeNormalViewSide of the plane with up = V. These tests pin the axis
// triads, the camera side and the world <-> sketch round trip the
// Sketch2D camera relies on.

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

void assertVector(cadnext::Vector3 v, double x, double y, double z) {
    assert(nearlyEqual(v.x, x));
    assert(nearlyEqual(v.y, y));
    assert(nearlyEqual(v.z, z));
}

cadnext::Vector3 cross(cadnext::Vector3 a, cadnext::Vector3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

void checkPlane(cadnext::SketchPlane plane, cadnext::Vector3 u, cadnext::Vector3 v,
                cadnext::Vector3 n, double viewSide) {
    const cadnext::WorkPlane workPlane = cadnext::makeCanonicalWorkPlane(plane, 8.0);
    const cadnext::SketchReference reference = cadnext::sketchReferenceFromWorkPlane(workPlane);

    assertVector(reference.uAxis, u.x, u.y, u.z);
    assertVector(reference.vAxis, v.x, v.y, v.z);
    assertVector(reference.normal, n.x, n.y, n.z);

    // u x v == viewSide * n: the camera sits on origin + viewSide * n so
    // that with up = v the U axis points right and V points up on screen.
    const cadnext::Vector3 handed = cross(reference.uAxis, reference.vAxis);
    assertVector(handed, viewSide * n.x, viewSide * n.y, viewSide * n.z);
    assert(nearlyEqual(
        cadnext::planeNormalViewSide(reference.uAxis, reference.vAxis, reference.normal),
        viewSide));

    // Round trip: sketch -> world -> sketch is the identity.
    const cadnext::SketchPoint2D point{1.25, -2.5};
    const cadnext::Vector3 world = cadnext::sketchPointToWorld(point, reference);
    assert(cadnext::isWorldPointOnSketchPlane(world, reference));
    const cadnext::SketchPoint2D back = cadnext::worldToSketchPoint(world, reference);
    assert(nearlyEqual(back.u, point.u));
    assert(nearlyEqual(back.v, point.v));
}

} // namespace

int main() {
    checkPlane(cadnext::SketchPlane::XY,
               {1.0, 0.0, 0.0}, {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}, 1.0);
    // Canonical XZ is a left-handed u/v/normal triad: the Sketch2D camera
    // must sit on the -Y side to keep +X pointing right.
    checkPlane(cadnext::SketchPlane::XZ,
               {1.0, 0.0, 0.0}, {0.0, 0.0, 1.0}, {0.0, 1.0, 0.0}, -1.0);
    checkPlane(cadnext::SketchPlane::YZ,
               {0.0, 1.0, 0.0}, {0.0, 0.0, 1.0}, {1.0, 0.0, 0.0}, 1.0);

    // The recorded sketch reference keeps the same triad as the work
    // plane it was created from (no axis swap on the way into the file).
    const cadnext::WorkPlane yz = cadnext::makeCanonicalWorkPlane(cadnext::SketchPlane::YZ, 8.0);
    const cadnext::SketchReference reference = cadnext::sketchReferenceFromWorkPlane(yz);
    assert(reference.sourceId == cadnext::canonicalWorkPlaneId(cadnext::SketchPlane::YZ));
    assert(reference.type == cadnext::SketchReferenceType::CanonicalPlane);

    return 0;
}
