#include "cadnext/CameraNavigationState.hpp"

#include <cassert>

int main() {
    cadnext::CameraNavigationState state;

    assert(state.mode() == cadnext::NavigationMode::Free3D);
    assert(state.navigationEnabled());
    assert(state.orbitEnabled());
    assert(state.panEnabled());
    assert(state.zoomEnabled());
    assert(state.inertiaEnabled());

    state.markCameraMotionActive(true);
    state.enterSketch2D();
    assert(state.mode() == cadnext::NavigationMode::Sketch2D);
    assert(state.stopMotionRequests() == 1);
    assert(!state.cameraMotionActive());
    assert(state.navigationEnabled());
    assert(!state.orbitEnabled());
    assert(state.panEnabled());
    assert(state.zoomEnabled());
    assert(!state.inertiaEnabled());

    state.exitSketch2D();
    assert(state.mode() == cadnext::NavigationMode::Free3D);
    assert(state.stopMotionRequests() == 2);
    assert(state.navigationEnabled());
    assert(state.orbitEnabled());
    assert(state.panEnabled());
    assert(state.zoomEnabled());
    assert(state.inertiaEnabled());

    state.setNavigationEnabled(false);
    state.applyFitOrReset();
    assert(state.navigationEnabled());

    return 0;
}
