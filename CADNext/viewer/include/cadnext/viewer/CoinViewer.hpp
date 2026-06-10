#pragma once

#include <functional>
#include <memory>
#include <string>

#include "cadnext/Sketch.hpp"
#include "cadnext/viewer/SceneGraph.hpp"

class QWidget;
class SoPerspectiveCamera;
class SoSeparator;

namespace cadnext::viewer {

class PickableExaminerViewer;

// Qt-embeddable Coin3D viewport. Wraps SoQtExaminerViewer (orbit/pan/zoom
// come from the examiner viewer) around a SceneGraph with its own
// perspective camera and headlight.
//
// A clean left click (no drag) either reports the picked target (body /
// sketch entity / empty) or — while sketch input mode is active — reports
// the click position in sketch-local u/v coordinates instead. Escape
// cancels the active sketch tool via the cancel callback.
//
// SoQt::init() must have been called before constructing a CoinViewer.
class CoinViewer {
public:
    using PickCallback = std::function<void(const ViewportPickTarget& target)>;
    using SketchPointCallback = std::function<void(double u, double v)>;
    using SketchCancelCallback = std::function<void()>;

    explicit CoinViewer(QWidget* parent);
    ~CoinViewer();

    CoinViewer(const CoinViewer&) = delete;
    CoinViewer& operator=(const CoinViewer&) = delete;

    QWidget* widget() const;
    SceneGraph& scene();

    void setPickCallback(PickCallback callback);
    void setSketchPointCallback(SketchPointCallback callback);
    void setSketchCancelCallback(SketchCancelCallback callback);

    // While active, clean clicks are interpreted as sketch tool input on
    // the given plane instead of selection picks.
    void setSketchInputMode(bool active, SketchPlane plane);

    // Re-frames the current scene contents without changing orientation.
    void fitView();
    // Restores the default axonometric view and frames the scene.
    void resetCamera();

private:
    void applyDefaultCameraPose();

    std::unique_ptr<SceneGraph> scene_;
    SoSeparator* viewerRoot_ = nullptr;
    SoPerspectiveCamera* camera_ = nullptr;
    PickableExaminerViewer* viewer_ = nullptr;
};

} // namespace cadnext::viewer
