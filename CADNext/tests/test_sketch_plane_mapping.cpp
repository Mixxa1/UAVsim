#include "cadnext/Sketch.hpp"
#include "cadnext/WorkPlane.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

void assertVector(cadnext::Vector3 v, double x, double y, double z) {
    assert(nearlyEqual(v.x, x));
    assert(nearlyEqual(v.y, y));
    assert(nearlyEqual(v.z, z));
}

void assertPoint(cadnext::SketchPoint2D p, double u, double v) {
    assert(nearlyEqual(p.u, u));
    assert(nearlyEqual(p.v, v));
}

} // namespace

int main() {
    const cadnext::SketchReference xy =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XY);
    const cadnext::SketchReference xz =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::XZ);
    const cadnext::SketchReference yz =
        cadnext::canonicalSketchReference(cadnext::SketchPlane::YZ);

    // Fixed Z-up axis convention of the canonical planes.
    assertVector(xy.uAxis, 1.0, 0.0, 0.0);
    assertVector(xy.vAxis, 0.0, 1.0, 0.0);
    assertVector(xy.normal, 0.0, 0.0, 1.0);

    assertVector(xz.uAxis, 1.0, 0.0, 0.0);
    assertVector(xz.vAxis, 0.0, 0.0, 1.0);
    assertVector(xz.normal, 0.0, 1.0, 0.0);

    assertVector(yz.uAxis, 0.0, 1.0, 0.0);
    assertVector(yz.vAxis, 0.0, 0.0, 1.0);
    assertVector(yz.normal, 1.0, 0.0, 0.0);

    // u=1, v=2 maps onto the matching world plane.
    assertVector(cadnext::sketchPointToWorld({1.0, 2.0}, xy), 1.0, 2.0, 0.0);
    assertVector(cadnext::sketchPointToWorld({1.0, 2.0}, xz), 1.0, 0.0, 2.0);
    assertVector(cadnext::sketchPointToWorld({1.0, 2.0}, yz), 0.0, 1.0, 2.0);

    // Negative/zero coordinates follow the same convention.
    assertVector(cadnext::sketchPointToWorld({-0.5, 0.0}, xz), -0.5, 0.0, 0.0);
    assertVector(cadnext::sketchPointToWorld({0.0, -3.0}, yz), 0.0, 0.0, -3.0);

    // Mapped points always lie on their own plane.
    assert(cadnext::isWorldPointOnSketchPlane(cadnext::sketchPointToWorld({1.0, 2.0}, xy), xy));
    assert(cadnext::isWorldPointOnSketchPlane(cadnext::sketchPointToWorld({1.0, 2.0}, xz), xz));
    assert(cadnext::isWorldPointOnSketchPlane(cadnext::sketchPointToWorld({1.0, 2.0}, yz), yz));

    // ... and never on a different canonical plane (unless u/v hits the
    // shared axis, which {1,2} does not).
    assert(!cadnext::isWorldPointOnSketchPlane(cadnext::sketchPointToWorld({1.0, 2.0}, xy), xz));
    assert(!cadnext::isWorldPointOnSketchPlane(cadnext::sketchPointToWorld({1.0, 2.0}, xz), xy));

    const cadnext::Vector3 xyWorld = cadnext::sketchPointToWorld({3.0, -4.0}, xy);
    const cadnext::Vector3 xzWorld = cadnext::sketchPointToWorld({3.0, -4.0}, xz);
    const cadnext::Vector3 yzWorld = cadnext::sketchPointToWorld({3.0, -4.0}, yz);
    assertPoint(cadnext::worldToSketchPoint(xyWorld, xy), 3.0, -4.0);
    assertPoint(cadnext::worldToSketchPoint(xzWorld, xz), 3.0, -4.0);
    assertPoint(cadnext::worldToSketchPoint(yzWorld, yz), 3.0, -4.0);
    assertVector(cadnext::sketchPointToWorld(cadnext::worldToSketchPoint(xyWorld, xy), xy),
                 xyWorld.x, xyWorld.y, xyWorld.z);
    assertVector(cadnext::sketchPointToWorld(cadnext::worldToSketchPoint(xzWorld, xz), xz),
                 xzWorld.x, xzWorld.y, xzWorld.z);
    assertVector(cadnext::sketchPointToWorld(cadnext::worldToSketchPoint(yzWorld, yz), yz),
                 yzWorld.x, yzWorld.y, yzWorld.z);

    return 0;
}
