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
    scene.defaultGridBounds = cadnext::defaultGridViewBounds(3.0);

    scene.entries.push_back({cadnext::ViewGeometryKind::WorldGrid,
                             bounds({-100.0, -100.0, 0.0}, {100.0, 100.0, 0.0})});
    scene.entries.push_back({cadnext::ViewGeometryKind::WorldAxes,
                             bounds({0.0, 0.0, 0.0}, {1000.0, 0.0, 0.0})});
    scene.entries.push_back({cadnext::ViewGeometryKind::HelperPlane,
                             bounds({-50.0, -50.0, 0.0}, {50.0, 50.0, 0.0})});
    scene.entries.push_back({cadnext::ViewGeometryKind::TransientPreview,
                             bounds({-20.0, -20.0, -20.0}, {20.0, 20.0, 20.0})});
    scene.entries.push_back({cadnext::ViewGeometryKind::Body,
                             bounds({1.0, 2.0, 3.0}, {2.0, 4.0, 6.0}),
                             "body-1"});

    const cadnext::CameraFocusTarget fitAll = cadnext::cameraFitAllTarget(scene);
    assert(fitAll.valid);
    assertVector(fitAll.bounds.min, 1.0, 2.0, 3.0);
    assertVector(fitAll.bounds.max, 2.0, 4.0, 6.0);

    cadnext::ViewBoundsScene emptyScene;
    emptyScene.defaultGridBounds = cadnext::defaultGridViewBounds(2.0);
    const cadnext::CameraFocusTarget emptyFit = cadnext::cameraFitAllTarget(emptyScene);
    assert(emptyFit.valid);
    assert(emptyFit.kind == "DefaultGrid");
    assertVector(emptyFit.bounds.min, -2.0, -2.0, 0.0);
    assertVector(emptyFit.bounds.max, 2.0, 2.0, 0.0);

    cadnext::ViewBoundsScene helpersOnly;
    helpersOnly.defaultGridBounds = cadnext::defaultGridViewBounds(1.0);
    helpersOnly.entries.push_back({cadnext::ViewGeometryKind::HelperPlane,
                                   bounds({-10.0, -10.0, 0.0}, {10.0, 10.0, 0.0})});
    helpersOnly.entries.push_back({cadnext::ViewGeometryKind::TransientPreview,
                                   bounds({-5.0, -5.0, -5.0}, {5.0, 5.0, 5.0})});
    const cadnext::CameraFocusTarget helperFit = cadnext::cameraFitAllTarget(helpersOnly);
    assert(helperFit.valid);
    assert(helperFit.kind == "DefaultGrid");
    assertVector(helperFit.bounds.min, -1.0, -1.0, 0.0);
    assertVector(helperFit.bounds.max, 1.0, 1.0, 0.0);

    return 0;
}
