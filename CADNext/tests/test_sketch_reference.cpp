#include "cadnext/Document.hpp"
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
    cadnext::Document document;

    const cadnext::WorkPlane xy =
        cadnext::makeCanonicalWorkPlane(cadnext::SketchPlane::XY, 10.0);
    cadnext::Sketch canonicalSketch;
    canonicalSketch.id = "sketch-xy";
    canonicalSketch.name = "Sketch XY 1";
    canonicalSketch.plane = cadnext::SketchPlane::XY;
    canonicalSketch.reference = cadnext::sketchReferenceFromWorkPlane(xy);
    document.addSketch(canonicalSketch);

    const cadnext::Sketch& restoredCanonical = document.sketches().front();
    assert(restoredCanonical.reference.type == cadnext::SketchReferenceType::CanonicalPlane);
    assert(restoredCanonical.reference.sourceId == "workplane-xy");
    assertVector(restoredCanonical.reference.origin, 0.0, 0.0, 0.0);
    assertVector(restoredCanonical.reference.uAxis, 1.0, 0.0, 0.0);
    assertVector(restoredCanonical.reference.vAxis, 0.0, 1.0, 0.0);
    assertVector(restoredCanonical.reference.normal, 0.0, 0.0, 1.0);

    cadnext::Object planeObject;
    planeObject.id = "object-plane-1";
    planeObject.name = "Plane 1";
    planeObject.type = cadnext::ObjectType::ReferencePlane;
    planeObject.primitive.width = 2.0;
    planeObject.primitive.height = 2.0;
    planeObject.transform.position = {1.0, 2.0, 3.0};
    document.addObject(planeObject);

    const cadnext::WorkPlane objectPlane =
        cadnext::workPlaneFromReferencePlaneObject(planeObject);
    cadnext::Sketch objectSketch;
    objectSketch.id = "sketch-plane-object";
    objectSketch.name = "Sketch Plane 1";
    objectSketch.reference = cadnext::sketchReferenceFromWorkPlane(objectPlane);
    document.addSketch(objectSketch);

    const cadnext::Sketch& restoredObjectSketch = document.sketches().back();
    assert(restoredObjectSketch.reference.type == cadnext::SketchReferenceType::WorkPlane);
    assert(restoredObjectSketch.reference.sourceId == "object-plane-1");
    assertVector(restoredObjectSketch.reference.origin, 1.0, 2.0, 3.0);
    assertVector(restoredObjectSketch.reference.uAxis, 1.0, 0.0, 0.0);
    assertVector(restoredObjectSketch.reference.vAxis, 0.0, 1.0, 0.0);
    assertVector(restoredObjectSketch.reference.normal, 0.0, 0.0, 1.0);

    return 0;
}
