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

} // namespace

int main() {
    const cadnext::WorkPlane xy =
        cadnext::makeCanonicalWorkPlane(cadnext::SketchPlane::XY, 10.0);
    assert(xy.id == "workplane-xy");
    assert(xy.name == "XY");
    assert(xy.kind == cadnext::WorkPlaneKind::XY);
    assertVector(xy.uAxis, 1.0, 0.0, 0.0);
    assertVector(xy.vAxis, 0.0, 1.0, 0.0);
    assertVector(xy.normal, 0.0, 0.0, 1.0);

    const cadnext::WorkPlane xz =
        cadnext::makeCanonicalWorkPlane(cadnext::SketchPlane::XZ, 10.0);
    assert(xz.id == "workplane-xz");
    assertVector(xz.uAxis, 1.0, 0.0, 0.0);
    assertVector(xz.vAxis, 0.0, 0.0, 1.0);
    assertVector(xz.normal, 0.0, 1.0, 0.0);

    const cadnext::WorkPlane yz =
        cadnext::makeCanonicalWorkPlane(cadnext::SketchPlane::YZ, 10.0);
    assert(yz.id == "workplane-yz");
    assertVector(yz.uAxis, 0.0, 1.0, 0.0);
    assertVector(yz.vAxis, 0.0, 0.0, 1.0);
    assertVector(yz.normal, 1.0, 0.0, 0.0);

    cadnext::Object object;
    object.id = "object-plane-1";
    object.name = "Plane 1";
    object.type = cadnext::ObjectType::ReferencePlane;
    object.primitive.width = 2.0;
    object.primitive.height = 3.0;
    object.transform.position = {4.0, 5.0, 6.0};
    object.transform.rotationEuler = {0.0, 0.0, 90.0};

    const cadnext::WorkPlane objectPlane =
        cadnext::workPlaneFromReferencePlaneObject(object);
    assert(objectPlane.id == "object-plane-1");
    assert(objectPlane.kind == cadnext::WorkPlaneKind::ObjectPlane);
    assertVector(objectPlane.origin, 4.0, 5.0, 6.0);
    assertVector(objectPlane.uAxis, 0.0, 1.0, 0.0);
    assertVector(objectPlane.vAxis, -1.0, 0.0, 0.0);
    assertVector(objectPlane.normal, 0.0, -0.0, 1.0);
    assert(nearlyEqual(objectPlane.width, 2.0));
    assert(nearlyEqual(objectPlane.height, 3.0));

    return 0;
}
