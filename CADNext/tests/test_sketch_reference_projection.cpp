#include "cadnext/Sketch.hpp"
#include "cadnext/WorkPlane.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

// world → local → world must reproduce the original on-plane point.
void assertRoundtrip(const cadnext::SketchReference& reference, double u, double v) {
    const cadnext::Vector3 world = cadnext::sketchPointToWorld({u, v}, reference);
    assert(cadnext::isWorldPointOnSketchPlane(world, reference));

    const cadnext::SketchPoint2D local = cadnext::worldToSketchPoint(world, reference);
    assert(nearlyEqual(local.u, u));
    assert(nearlyEqual(local.v, v));

    const cadnext::Vector3 back = cadnext::sketchPointToWorld(local, reference);
    assert(nearlyEqual(back.x, world.x));
    assert(nearlyEqual(back.y, world.y));
    assert(nearlyEqual(back.z, world.z));
}

} // namespace

int main() {
    const double samples[][2] = {
        {0.0, 0.0}, {1.0, 2.0}, {-1.5, 0.25}, {3.7, -2.9}, {-0.1, -0.1},
    };

    for (const cadnext::SketchPlane plane :
         {cadnext::SketchPlane::XY, cadnext::SketchPlane::XZ, cadnext::SketchPlane::YZ}) {
        const cadnext::SketchReference reference = cadnext::canonicalSketchReference(plane);
        for (const auto& sample : samples) {
            assertRoundtrip(reference, sample[0], sample[1]);
        }
    }

    // Rotated/offset reference plane (object plane rotated 90° about Z,
    // origin away from the world origin) keeps the roundtrip exact.
    cadnext::Object object;
    object.id = "object-plane-1";
    object.name = "Plane 1";
    object.type = cadnext::ObjectType::ReferencePlane;
    object.primitive.width = 2.0;
    object.primitive.height = 2.0;
    object.transform.position = {4.0, 5.0, 6.0};
    object.transform.rotationEuler = {0.0, 0.0, 90.0};
    const cadnext::SketchReference rotated = cadnext::sketchReferenceFromWorkPlane(
        cadnext::workPlaneFromReferencePlaneObject(object));
    for (const auto& sample : samples) {
        assertRoundtrip(rotated, sample[0], sample[1]);
    }

    // Off-plane points are rejected by the plane check.
    const cadnext::SketchReference xy =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY);
    assert(!cadnext::isWorldPointOnSketchPlane({0.0, 0.0, 0.5}, xy));
    assert(!cadnext::isWorldPointOnSketchPlane({1.0, 2.0, -1.0e-3}, xy));
    assert(cadnext::isWorldPointOnSketchPlane({1.0, 2.0, 1.0e-8}, xy));

    return 0;
}
