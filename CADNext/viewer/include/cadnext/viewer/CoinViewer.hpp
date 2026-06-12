#pragma once

#include <functional>
#include <memory>
#include <string>

#include "cadnext/Selection.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/ViewBoundsPolicy.hpp"
#include "cadnext/ViewportPolicy.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/viewer/SceneGraph.hpp"

class QWidget;
class SoCamera;
class SoSeparator;

namespace cadnext::viewer {

class PickableExaminerViewer;
class SketchNavigationFilter;

enum class ViewMode {
    Free3D,
    Sketch2D
};

// Qt-embeddable Coin3D viewport. Wraps SoQtExaminerViewer (orbit/pan/zoom
// come from the examiner viewer) around a SceneGraph with its own
// perspective camera and headlight.
//
// A clean left click (no drag) either reports the picked target (body /
// sketch entity / empty) or — while sketch input mode is active — reports
// the click position in sketch-local u/v coordinates instead. Mouse moves
// in sketch input mode are projected onto the plane the same way and
// reported through the move callback (raw, unsnapped u/v). Escape cancels
// the active sketch tool via the cancel callback.
//
// Sketch2D is a true flat sketch view: an orthographic camera locked
// normal to the plane (U right, V up), orbit disabled, trackpad pinch =
// zoom at the cursor and two-finger scroll = pan. Helper visibility per
// mode comes from the core ViewportPolicy.
//
// SoQt::init() must have been called before constructing a CoinViewer.
class CoinViewer {
public:
    using PickCallback = std::function<void(const ViewportPickTarget& target, bool contextClick)>;
    using HoverCallback = std::function<void(const ViewportPickTarget& target)>;
    using SketchPointCallback = std::function<void(double u, double v)>;
    using SketchMoveCallback = std::function<void(double u, double v)>;
    // Fired when a sketch click cannot be projected onto the active plane
    // (camera ray parallel to it) so the GUI can warn instead of silently
    // dropping the click.
    using SketchMissCallback = std::function<void()>;
    using SketchCancelCallback = std::function<void()>;

    explicit CoinViewer(QWidget* parent);
    ~CoinViewer();

    CoinViewer(const CoinViewer&) = delete;
    CoinViewer& operator=(const CoinViewer&) = delete;

    QWidget* widget() const;
    SceneGraph& scene();

    void setPickCallback(PickCallback callback);
    void setHoverCallback(HoverCallback callback);
    void setSketchPointCallback(SketchPointCallback callback);
    void setSketchMoveCallback(SketchMoveCallback callback);
    void setSketchMissCallback(SketchMissCallback callback);
    void setSketchCancelCallback(SketchCancelCallback callback);

    // While active, clean clicks are interpreted as sketch tool input on
    // the given plane instead of selection picks.
    void setSketchInputMode(bool active, const SketchReference& reference);

    void setViewNormalToPlane(const WorkPlane& plane);
    void enterSketch2DView(const WorkPlane& plane, double gridStep = 1.0, bool showGrid = true);
    void exitSketch2DView();
    ViewMode viewMode() const;

    // Selection / visibility policy for the work plane helpers. The
    // selected plane drives both the outline highlight and the Free3D
    // "Hide Other Planes" mode.
    void setSelectedWorkPlane(const std::string& planeId);
    void setOtherWorkPlanesHidden(bool hidden);
    bool otherWorkPlanesHidden() const;

    // Frames the given canonical work plane without changing orientation.
    void fitWorkPlane(const std::string& planeId);

    void setCameraBoundsScene(const ViewBoundsScene& scene);
    void setOrbitPivot(const cadnext::Vector3& pivot);
    void focusSelection(const SelectionState& selection);
    void frameSelection(const SelectionState& selection);

    // Re-frames per ViewportPolicy: the active sketch plane in Sketch2D,
    // otherwise bodies+sketches, falling back to the selected plane and
    // then the whole scene. Helper grid/axes never inflate the fit.
    void fitView();
    // Restores the default axonometric view and frames the scene.
    void resetCamera();

private:
    void applyDefaultCameraPose();
    void applyIsometricCameraPose(const Vector3& center, double distance);
    void frameCameraTarget(const CameraFocusTarget& target, bool isometric);
    void focusCameraTarget(const CameraFocusTarget& target);
    void updateClipping(double distance, double radius);
    void replaceCamera(bool orthographic);
    // Applies the ViewportPolicy visibility/navigation state to the scene.
    void applyHelperVisibility();

    std::unique_ptr<SceneGraph> scene_;
    SoSeparator* viewerRoot_ = nullptr;
    SoCamera* camera_ = nullptr;
    PickableExaminerViewer* viewer_ = nullptr;
    SketchNavigationFilter* gestureFilter_ = nullptr;
    ViewportPolicy policy_;
    CameraNavigationOptions navigationOptions_;
    ViewBoundsScene cameraBounds_;
    SelectionState lastSelection_;
    Vector3 orbitPivot_;
    ViewMode viewMode_ = ViewMode::Free3D;
};

} // namespace cadnext::viewer
