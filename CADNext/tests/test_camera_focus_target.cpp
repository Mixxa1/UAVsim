#include "cadnext/ViewBoundsPolicy.hpp"

#include <cassert>
#include <cmath>

namespace {

bool nearlyEqual(double a, double b) {
    return std::fabs(a - b) < 1.0e-9;
}

void assertVector(cadnext::Vector3 value, double x, double y, double z) {
    assert(nearlyEqual(value.x, x));
    assert(nearlyEqual(value.y, y));
    assert(nearlyEqual(value.z, z));
}

cadnext::ViewBounds bounds(cadnext::Vector3 min, cadnext::Vector3 max) {
    cadnext::ViewBounds result;
    result.include(min);
    result.include(max);
    return result;
}

} // namespace

int main() {
    cadnext::ViewBoundsScene scene;
    scene.defaultGridBounds = cadnext::defaultGridViewBounds();

    scene.entries.push_back({cadnext::ViewGeometryKind::Body,
                             bounds({-1.0, -2.0, 0.0}, {3.0, 2.0, 4.0}),
                             "body-1"});
    scene.entries.push_back({cadnext::ViewGeometryKind::BodyFace,
                             bounds({0.0, 0.0, 4.0}, {2.0, 2.0, 4.0}),
                             "body-1",
                             "face-top"});
    scene.entries.push_back({cadnext::ViewGeometryKind::SketchEntity,
                             bounds({8.0, 1.0, 0.0}, {12.0, 1.0, 0.0}),
                             {},
                             {},
                             "sketch-1",
                             "entity-1"});
    scene.entries.push_back({cadnext::ViewGeometryKind::SketchProfile,
                             bounds({8.0, 2.0, 0.0}, {12.0, 5.0, 0.0}),
                             {},
                             {},
                             "sketch-1",
                             {},
                             "profile-1"});

    cadnext::SelectionState bodySelection;
    bodySelection.kind = cadnext::SelectionKind::Body;
    bodySelection.bodyId = "body-1";
    const cadnext::CameraFocusTarget bodyTarget =
        cadnext::cameraFocusTargetForSelection(scene, bodySelection);
    assert(bodyTarget.valid);
    assert(bodyTarget.kind == "Body");
    assertVector(bodyTarget.center, 1.0, 0.0, 2.0);

    cadnext::SelectionState faceSelection;
    faceSelection.kind = cadnext::SelectionKind::BodyFace;
    faceSelection.bodyId = "body-1";
    faceSelection.faceId = "face-top";
    const cadnext::CameraFocusTarget faceTarget =
        cadnext::cameraFocusTargetForSelection(scene, faceSelection);
    assert(faceTarget.valid);
    assert(faceTarget.kind == "Face");
    assertVector(faceTarget.center, 1.0, 1.0, 4.0);

    cadnext::SelectionState entitySelection;
    entitySelection.kind = cadnext::SelectionKind::SketchEntity;
    entitySelection.sketchId = "sketch-1";
    entitySelection.entityId = "entity-1";
    const cadnext::CameraFocusTarget entityTarget =
        cadnext::cameraFocusTargetForSelection(scene, entitySelection);
    assert(entityTarget.valid);
    assertVector(entityTarget.center, 10.0, 1.0, 0.0);

    cadnext::SelectionState profileSelection;
    profileSelection.kind = cadnext::SelectionKind::SketchProfile;
    profileSelection.sketchId = "sketch-1";
    profileSelection.profileId = "profile-1";
    const cadnext::CameraFocusTarget profileTarget =
        cadnext::cameraFocusTargetForSelection(scene, profileSelection);
    assert(profileTarget.valid);
    assertVector(profileTarget.center, 10.0, 3.5, 0.0);

    return 0;
}
