#include "cadnext/CameraNavigationState.hpp"

namespace cadnext {

void CameraNavigationState::setNavigationEnabled(bool enabled) {
    navigationEnabled_ = enabled;
}

void CameraNavigationState::markCameraMotionActive(bool active) {
    cameraMotionActive_ = active;
}

void CameraNavigationState::stopCameraMotion() {
    cameraMotionActive_ = false;
    ++stopMotionRequests_;
}

void CameraNavigationState::enterSketch2D() {
    stopCameraMotion();
    mode_ = NavigationMode::Sketch2D;
    navigationEnabled_ = true;
    orbitEnabled_ = false;
    panEnabled_ = true;
    zoomEnabled_ = true;
    inertiaEnabled_ = false;
}

void CameraNavigationState::exitSketch2D() {
    stopCameraMotion();
    mode_ = NavigationMode::Free3D;
    navigationEnabled_ = true;
    orbitEnabled_ = true;
    panEnabled_ = true;
    zoomEnabled_ = true;
    inertiaEnabled_ = true;
}

EscapeNavigationAction CameraNavigationState::handleEscape(bool hasPendingSketch) {
    navigationEnabled_ = true;
    if (hasPendingSketch) {
        return EscapeNavigationAction::CancelPendingSketch;
    }
    if (cameraMotionActive_) {
        stopCameraMotion();
        return EscapeNavigationAction::StopCameraMotion;
    }
    return mode_ == NavigationMode::Sketch2D ? EscapeNavigationAction::KeepSketchNavigation
                                             : EscapeNavigationAction::KeepFreeNavigation;
}

void CameraNavigationState::applyFitOrReset() {
    navigationEnabled_ = true;
}

} // namespace cadnext
