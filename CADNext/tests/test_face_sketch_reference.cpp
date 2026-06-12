// CADNext 0.8: BodyFace sketch references — world/local mapping on face
// planes, the work-plane adapter, and save/load via the document
// serializer (including the resolved-plane fallback contract).

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

// A side face of a unit box at x = +0.5: normal +X, u = +Y, v = +Z
// (orthonormal right-handed triad, u x v == normal).
cadnext::SketchReference sideFaceReference() {
    cadnext::SketchReference reference;
    reference.type = cadnext::SketchReferenceType::BodyFace;
    reference.sourceId = "face-3-aabbccdd-11223344-55667788";
    reference.sourceBodyId = "object-7";
    reference.sourceFaceId = reference.sourceId;
    reference.origin = {0.5, 0.0, 0.5};
    reference.uAxis = {0.0, 1.0, 0.0};
    reference.vAxis = {0.0, 0.0, 1.0};
    reference.normal = {1.0, 0.0, 0.0};
    reference.displayName = "Face of Extrude Body 1";
    return reference;
}

} // namespace

int main() {
    const cadnext::SketchReference reference = sideFaceReference();

    // World/local roundtrip on the face plane.
    const cadnext::SketchPoint2D local{0.25, -0.4};
    const cadnext::Vector3 world = cadnext::sketchPointToWorld(local, reference);
    assertVector(world, 0.5, 0.25, 0.1);
    assert(cadnext::isWorldPointOnSketchPlane(world, reference));
    const cadnext::SketchPoint2D roundtrip = cadnext::worldToSketchPoint(world, reference);
    assert(nearlyEqual(roundtrip.u, local.u));
    assert(nearlyEqual(roundtrip.v, local.v));

    // Reference type names: BodyFace is stable, the pre-0.8 "Face"
    // spelling still loads.
    assert(std::string(cadnext::sketchReferenceTypeName(
               cadnext::SketchReferenceType::BodyFace)) == "BodyFace");
    assert(cadnext::sketchReferenceTypeFromName("BodyFace") ==
           cadnext::SketchReferenceType::BodyFace);
    assert(cadnext::sketchReferenceTypeFromName("Face") ==
           cadnext::SketchReferenceType::BodyFace);

    // A FacePlane work plane adapts into a BodyFace reference and carries
    // the face source ids through.
    cadnext::WorkPlane facePlane;
    facePlane.id = "faceplane-1";
    facePlane.name = "Plane from Face 1";
    facePlane.kind = cadnext::WorkPlaneKind::FacePlane;
    facePlane.origin = reference.origin;
    facePlane.uAxis = reference.uAxis;
    facePlane.vAxis = reference.vAxis;
    facePlane.normal = reference.normal;
    facePlane.sourceBodyId = "object-7";
    facePlane.sourceFaceId = reference.sourceFaceId;
    const cadnext::SketchReference fromPlane =
        cadnext::sketchReferenceFromWorkPlane(facePlane);
    assert(fromPlane.type == cadnext::SketchReferenceType::BodyFace);
    assert(fromPlane.sourceId == "faceplane-1");
    assert(fromPlane.sourceBodyId == "object-7");
    assert(fromPlane.sourceFaceId == reference.sourceFaceId);
    assert(fromPlane.displayName == "Plane from Face 1");

    // Save/load: the face-based sketch keeps its reference, including the
    // resolved plane geometry (the fallback when the faceId is missing
    // after a reload — exactly what an unresolved id must keep using).
    cadnext::Document document;
    cadnext::Sketch sketch;
    sketch.id = "sketch-1";
    sketch.name = "Sketch Face of Extrude Body 1 1";
    sketch.reference = reference;
    cadnext::SketchEntity entity;
    entity.id = "entity-1";
    entity.name = "Rectangle 1";
    entity.type = cadnext::SketchEntityType::Rectangle;
    entity.rectangle.origin = {-0.2, -0.2};
    entity.rectangle.width = 0.4;
    entity.rectangle.height = 0.3;
    sketch.entities.push_back(entity);
    document.addSketch(sketch);

    const std::string json = cadnext::DocumentSerializer::toJson(document);
    const cadnext::Result<cadnext::Document> loaded =
        cadnext::DocumentSerializer::fromJson(json);
    assert(loaded.isOk());
    const cadnext::Result<cadnext::Sketch> loadedSketch =
        loaded.value().sketchById("sketch-1");
    assert(loadedSketch.isOk());
    const cadnext::SketchReference& restored = loadedSketch.value().reference;
    assert(restored.type == cadnext::SketchReferenceType::BodyFace);
    assert(restored.sourceId == reference.sourceId);
    assert(restored.sourceBodyId == "object-7");
    assert(restored.sourceFaceId == reference.sourceFaceId);
    assert(restored.displayName == "Face of Extrude Body 1");
    assertVector(restored.origin, 0.5, 0.0, 0.5);
    assertVector(restored.uAxis, 0.0, 1.0, 0.0);
    assertVector(restored.vAxis, 0.0, 0.0, 1.0);
    assertVector(restored.normal, 1.0, 0.0, 0.0);

    // Entities survive in face-local u/v.
    assert(loadedSketch.value().entities.size() == 1);
    assert(nearlyEqual(loadedSketch.value().entities.front().rectangle.width, 0.4));

    return 0;
}
