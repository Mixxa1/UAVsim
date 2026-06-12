#include "cadnext/CameraNavigationState.hpp"

#include <cassert>

int main() {
    cadnext::CameraNavigationState state;
    state.enterSketch2D();
    const int enterStops = state.stopMotionRequests();

    cadnext::EscapeNavigationAction action = state.handleEscape(true);
    assert(action == cadnext::EscapeNavigationAction::CancelPendingSketch);
    assert(state.stopMotionRequests() == enterStops);
    assert(state.navigationEnabled());
    assert(!state.orbitEnabled());
    assert(state.panEnabled());
    assert(state.zoomEnabled());

    state.markCameraMotionActive(true);
    action = state.handleEscape(false);
    assert(action == cadnext::EscapeNavigationAction::StopCameraMotion);
    assert(state.stopMotionRequests() == enterStops + 1);
    assert(!state.cameraMotionActive());
    assert(state.navigationEnabled());

    action = state.handleEscape(false);
    assert(action == cadnext::EscapeNavigationAction::KeepSketchNavigation);
    assert(state.navigationEnabled());
    assert(!state.orbitEnabled());
    assert(state.panEnabled());
    assert(state.zoomEnabled());

    state.exitSketch2D();
    action = state.handleEscape(false);
    assert(action == cadnext::EscapeNavigationAction::KeepFreeNavigation);
    assert(state.navigationEnabled());
    assert(state.orbitEnabled());

    state.setNavigationEnabled(false);
    state.applyFitOrReset();
    assert(state.navigationEnabled());

    return 0;
}
