#pragma once

namespace cadnext {

enum class NavigationMode {
    Free3D,
    Sketch2D
};

enum class EscapeNavigationAction {
    CancelPendingSketch,
    StopCameraMotion,
    KeepSketchNavigation,
    KeepFreeNavigation
};

class CameraNavigationState {
public:
    NavigationMode mode() const { return mode_; }
    bool navigationEnabled() const { return navigationEnabled_; }
    bool orbitEnabled() const { return orbitEnabled_; }
    bool panEnabled() const { return panEnabled_; }
    bool zoomEnabled() const { return zoomEnabled_; }
    bool inertiaEnabled() const { return inertiaEnabled_; }
    bool cameraMotionActive() const { return cameraMotionActive_; }
    int stopMotionRequests() const { return stopMotionRequests_; }

    void setNavigationEnabled(bool enabled);
    void markCameraMotionActive(bool active);
    void stopCameraMotion();
    void enterSketch2D();
    void exitSketch2D();
    EscapeNavigationAction handleEscape(bool hasPendingSketch);
    void applyFitOrReset();

private:
    NavigationMode mode_ = NavigationMode::Free3D;
    bool navigationEnabled_ = true;
    bool orbitEnabled_ = true;
    bool panEnabled_ = true;
    bool zoomEnabled_ = true;
    bool inertiaEnabled_ = true;
    bool cameraMotionActive_ = false;
    int stopMotionRequests_ = 0;
};

} // namespace cadnext
