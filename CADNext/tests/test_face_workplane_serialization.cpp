// CADNext 0.8: document work planes created from body faces — document
// storage, save/load roundtrip, and backwards compatibility with pre-0.8
// files that have no "workPlanes" array.

#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/WorkPlane.hpp"

#include <cassert>
#include <cmath>
#include <string>

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
    // Kind names are stable serialization strings.
    assert(std::string(cadnext::workPlaneKindName(cadnext::WorkPlaneKind::FacePlane)) ==
           "FacePlane");
    assert(cadnext::workPlaneKindFromName("FacePlane") ==
           cadnext::WorkPlaneKind::FacePlane);
    assert(cadnext::workPlaneKindFromName("ObjectPlane") ==
           cadnext::WorkPlaneKind::ObjectPlane);

    cadnext::Document document;

    cadnext::WorkPlane plane;
    plane.id = "faceplane-2";
    plane.name = "Plane from Face 2";
    plane.kind = cadnext::WorkPlaneKind::FacePlane;
    plane.origin = {0.0, 0.0, 1.0};
    plane.uAxis = {1.0, 0.0, 0.0};
    plane.vAxis = {0.0, 1.0, 0.0};
    plane.normal = {0.0, 0.0, 1.0};
    plane.width = 2.0;
    plane.height = 3.0;
    plane.sourceBodyId = "object-1";
    plane.sourceFaceId = "face-5-deadbeef-cafebabe-12345678";
    document.addWorkPlane(plane);

    // Document accessors.
    assert(document.workPlanes().size() == 1);
    assert(document.workPlaneById("faceplane-2").isOk());
    assert(!document.workPlaneById("faceplane-404").isOk());
    cadnext::WorkPlane* mutablePlane = document.mutableWorkPlaneById("faceplane-2");
    assert(mutablePlane != nullptr);

    // Save → load roundtrip.
    const std::string json = cadnext::DocumentSerializer::toJson(document);
    const cadnext::Result<cadnext::Document> loaded =
        cadnext::DocumentSerializer::fromJson(json);
    assert(loaded.isOk());
    assert(loaded.value().workPlanes().size() == 1);
    const cadnext::WorkPlane& restored = loaded.value().workPlanes().front();
    assert(restored.id == "faceplane-2");
    assert(restored.name == "Plane from Face 2");
    assert(restored.kind == cadnext::WorkPlaneKind::FacePlane);
    assert(restored.sourceBodyId == "object-1");
    assert(restored.sourceFaceId == "face-5-deadbeef-cafebabe-12345678");
    assertVector(restored.origin, 0.0, 0.0, 1.0);
    assertVector(restored.uAxis, 1.0, 0.0, 0.0);
    assertVector(restored.vAxis, 0.0, 1.0, 0.0);
    assertVector(restored.normal, 0.0, 0.0, 1.0);
    assert(nearlyEqual(restored.width, 2.0));
    assert(nearlyEqual(restored.height, 3.0));

    // Removal works.
    cadnext::Document removable = loaded.value();
    assert(removable.removeWorkPlane("faceplane-2"));
    assert(!removable.removeWorkPlane("faceplane-2"));
    assert(removable.workPlanes().empty());

    // Pre-0.8 documents (no "workPlanes" array) keep loading.
    const std::string legacyJson =
        "{ \"format\": \"cadnext\", \"version\": 1, \"document\": {"
        " \"id\": \"doc\", \"name\": \"Legacy\", \"unitSystem\": \"Metric\","
        " \"objects\": [], \"sketches\": [], \"features\": [] } }";
    const cadnext::Result<cadnext::Document> legacy =
        cadnext::DocumentSerializer::fromJson(legacyJson);
    assert(legacy.isOk());
    assert(legacy.value().workPlanes().empty());

    return 0;
}
