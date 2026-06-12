#include "cadnext/viewer/CoinViewer.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <optional>

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/nodes/SoCamera.h>
#include <Inventor/SbLine.h>
#include <Inventor/SbPlane.h>
#include <Inventor/SbViewVolume.h>
#include <Inventor/SoPickedPoint.h>
#include <Inventor/actions/SoGLRenderAction.h>
#include <Inventor/actions/SoRayPickAction.h>
#include <Inventor/events/SoKeyboardEvent.h>
#include <Inventor/events/SoLocation2Event.h>
#include <Inventor/events/SoMouseButtonEvent.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoOrthographicCamera.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QEvent>
#include <QNativeGestureEvent>
#include <QtLogging>
#include <QWheelEvent>
#include <QWidget>

namespace cadnext::viewer {

namespace {

const SbVec3f kDefaultCameraPosition(9.0f, -9.0f, 7.0f);
const SbVec3f kSceneCenter(0.0f, 0.0f, 0.0f);
const SbVec3f kWorldUp(0.0f, 0.0f, 1.0f);
constexpr float kDefaultGridFitRadius = 5.7f;

// A press/release pair further apart than this is treated as a drag
// (camera navigation), not a pick click.
constexpr short kClickDragThresholdPx = 3;

// Sketch2D orthographic zoom clamps (view height in world units).
constexpr float kMinOrthoViewHeight = 0.05f;
constexpr float kMaxOrthoViewHeight = 500.0f;

SbVec3f toSb(const Vector3& v) {
    return {static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)};
}

Vector3 fromSb(const SbVec3f& v) {
    return {v[0], v[1], v[2]};
}

float dot(const SbVec3f& a, const SbVec3f& b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

SbVec3f cameraForward(SoCamera* camera) {
    SbVec3f forward;
    camera->orientation.getValue().multVec(SbVec3f(0.0f, 0.0f, -1.0f), forward);
    if (forward.normalize() == 0.0f) {
        return SbVec3f(0.0f, 0.0f, -1.0f);
    }
    return forward;
}

void applyClipPlanes(SoCamera* camera,
                     const CameraNavigationOptions& options,
                     double distance,
                     double radius) {
    const double safeDistance = std::max(distance, options.minDistance);
    const double safeRadius = std::max(radius, options.minDistance);
    const double nearCandidate = std::max(0.0005, safeDistance - safeRadius * 2.5);
    const double nearDistance = std::min(nearCandidate, safeDistance * 0.05);
    const double farDistance = std::max({safeDistance + safeRadius * 6.0,
                                         safeDistance * 8.0,
                                         options.minDistance * 100.0});
    camera->nearDistance = static_cast<float>(std::max(0.0005, nearDistance));
    camera->farDistance = static_cast<float>(std::min(options.maxDistance * 2.0, farDistance));
}

} // namespace

// Examiner viewer that ray-picks on clean left clicks. Navigation events
// are always forwarded to the base class, so orbit/pan/zoom keep working;
// picking only happens when the mouse did not move between press and
// release. In sketch input mode a clean click is converted to a sketch
// plane position instead of a selection pick, and Escape is consumed to
// cancel the active sketch tool (instead of toggling SoQt viewing mode).
class PickableExaminerViewer : public SoQtExaminerViewer {
public:
    explicit PickableExaminerViewer(QWidget* parent)
        : SoQtExaminerViewer(parent) {}

    std::function<void(const SoPickedPoint*, bool contextClick)> pickHandler;
    std::function<void(const SoPickedPoint*)> hoverHandler;
    std::function<void(double u, double v)> sketchPointHandler;
    std::function<void(double u, double v)> sketchMoveHandler;
    std::function<void()> sketchMissHandler;
    std::function<void()> sketchCancelHandler;
    bool sketchInputActive = false;
    bool freeOrbitEnabled = true;
    bool navigationEnabled = true;
    CameraNavigationOptions navigationOptions;
    SbVec3f orbitPivot = kSceneCenter;
    double orbitRadius = kDefaultGridFitRadius;
    SketchReference sketchReference;

    // --- Sketch2D trackpad navigation (called by the gesture filter) ----

    // Qt wheel deltas are y-down; pan treats them like dragging the
    // canvas, so the content follows the gesture.
    void panOrthoByWheel(int dxPx, int dyPx) {
        panCamera(SbVec2s(static_cast<short>(dxPx), static_cast<short>(-dyPx)));
    }

    // Zooms the orthographic camera keeping the world point under the
    // cursor fixed (factor > 1 zooms in). Widget coordinates are y-down.
    void zoomOrthoAt(double factor, const QPointF& widgetPos, const QSize& widgetSize) {
        SoCamera* camera = getCamera();
        if (!camera || !camera->isOfType(SoOrthographicCamera::getClassTypeId()) ||
            widgetSize.height() <= 0) {
            return;
        }
        auto* ortho = static_cast<SoOrthographicCamera*>(camera);
        factor = std::clamp(factor, 0.5, 2.0);
        const float oldHeight = ortho->height.getValue();
        const float newHeight = std::clamp(oldHeight / static_cast<float>(factor),
                                           kMinOrthoViewHeight, kMaxOrthoViewHeight);
        if (newHeight == oldHeight) {
            return;
        }
        const float perPixelOld = oldHeight / static_cast<float>(widgetSize.height());
        const float perPixelNew = newHeight / static_cast<float>(widgetSize.height());
        const float dxPx =
            static_cast<float>(widgetPos.x()) - static_cast<float>(widgetSize.width()) * 0.5f;
        const float dyPx =
            static_cast<float>(widgetSize.height()) * 0.5f - static_cast<float>(widgetPos.y());
        const SbRotation orientation = camera->orientation.getValue();
        SbVec3f right;
        SbVec3f up;
        orientation.multVec(SbVec3f(1.0f, 0.0f, 0.0f), right);
        orientation.multVec(SbVec3f(0.0f, 1.0f, 0.0f), up);
        camera->position = camera->position.getValue() +
                           right * (dxPx * (perPixelOld - perPixelNew)) +
                           up * (dyPx * (perPixelOld - perPixelNew));
        ortho->height = newHeight;
    }

    void zoomPerspectiveAt(double factor) {
        SoCamera* camera = getCamera();
        if (!camera || !camera->isOfType(SoPerspectiveCamera::getClassTypeId())) {
            return;
        }
        factor = std::clamp(factor, 0.25, 4.0);
        const SbVec3f forward = cameraForward(camera);
        const SbVec3f position = camera->position.getValue();
        const SbVec3f toPivot = orbitPivot - position;
        double distance = std::fabs(static_cast<double>(dot(toPivot, forward)));
        if (distance < navigationOptions.minDistance) {
            distance = std::max(static_cast<double>(toPivot.length()),
                                navigationOptions.minDistance);
        }
        const double newDistance = std::clamp(distance / factor,
                                             navigationOptions.minDistance,
                                             navigationOptions.maxDistance);
        camera->position = orbitPivot - forward * static_cast<float>(newDistance);
        camera->focalDistance = static_cast<float>(newDistance);
        applyClipPlanes(camera, navigationOptions, newDistance, orbitRadius);
    }

    void clearNavigationInputState() {
        leftButtonDown_ = false;
        dragged_ = false;
        pressPosition_ = SbVec2s(-1, -1);
        lastDragPosition_ = SbVec2s(-1, -1);
        if (QWidget* glWidget = getGLWidget()) {
            glWidget->releaseMouse();
            glWidget->releaseKeyboard();
        }
        if (QWidget* widget = getWidget()) {
            widget->releaseMouse();
            widget->releaseKeyboard();
        }
    }

    bool navigationInputActive() const {
        return leftButtonDown_ || dragged_;
    }

    void stopCameraMotion(bool animationEnabledAfterStop) {
        stopAnimating();
        setAnimationEnabled(FALSE);
        setAnimationEnabled(animationEnabledAfterStop ? TRUE : FALSE);
        clearNavigationInputState();
    }

protected:
    SbBool processSoEvent(const SoEvent* event) override {
        if (!navigationEnabled) {
            return TRUE;
        }
        if (event->isOfType(SoKeyboardEvent::getClassTypeId())) {
            const auto* keyEvent = static_cast<const SoKeyboardEvent*>(event);
            if (keyEvent->getKey() == SoKeyboardEvent::ESCAPE &&
                keyEvent->getState() == SoButtonEvent::DOWN) {
                if (sketchCancelHandler) {
                    sketchCancelHandler();
                }
                clearNavigationInputState();
                return TRUE; // do not let SoQt toggle viewing/arrow mode
            }
        } else if (event->isOfType(SoMouseButtonEvent::getClassTypeId())) {
            const auto* buttonEvent = static_cast<const SoMouseButtonEvent*>(event);
            if (buttonEvent->getButton() == SoMouseButtonEvent::BUTTON1) {
                if (buttonEvent->getState() == SoButtonEvent::DOWN) {
                    leftButtonDown_ = true;
                    dragged_ = false;
                    pressPosition_ = event->getPosition();
                    lastDragPosition_ = pressPosition_;
                } else if (buttonEvent->getState() == SoButtonEvent::UP) {
                    const bool isClick = leftButtonDown_ && !dragged_;
                    leftButtonDown_ = false;
                    if (isClick) {
                        handleClick(event->getPosition(), false);
                    }
                }
                if (!freeOrbitEnabled) {
                    return TRUE;
                }
            } else if ((buttonEvent->getButton() == SoMouseButtonEvent::BUTTON2 ||
                        buttonEvent->getButton() == SoMouseButtonEvent::BUTTON3) &&
                       buttonEvent->getState() == SoButtonEvent::DOWN) {
                handleClick(event->getPosition(), true);
                return TRUE;
            }
        } else if (event->isOfType(SoLocation2Event::getClassTypeId())) {
            if (leftButtonDown_) {
                const SbVec2s delta = event->getPosition() - pressPosition_;
                if (std::abs(delta[0]) > kClickDragThresholdPx ||
                    std::abs(delta[1]) > kClickDragThresholdPx) {
                    dragged_ = true;
                }
                if (!freeOrbitEnabled && dragged_) {
                    // Sketch2D: orbit is disabled, so a left drag pans the
                    // orthographic view instead (it must never knock the
                    // camera off the sketch plane normal).
                    panCamera(event->getPosition() - lastDragPosition_);
                }
                lastDragPosition_ = event->getPosition();
            }
            if (sketchInputActive) {
                // Sketch cursor / rubber-band preview tracking. The hover
                // pick is skipped here on purpose: work plane hovering is
                // meaningless while a sketch tool is active.
                handleSketchMove(event->getPosition());
            } else if (!leftButtonDown_) {
                handleHover(event->getPosition());
            }
            if (leftButtonDown_ && !freeOrbitEnabled) {
                return TRUE;
            }
        }
        return SoQtExaminerViewer::processSoEvent(event);
    }

private:
    template <typename Consumer>
    void withPickedPoint(const SbVec2s& position, Consumer consumer) {
        SoRayPickAction pick(getViewportRegion());
        pick.setPoint(position);
        pick.setRadius(4.0f);
        // The scene manager graph contains the camera, which the pick
        // action needs to build the ray.
        pick.apply(getSceneManager()->getSceneGraph());
        consumer(pick.getPickedPoint());
    }

    // Analytic mouse → active sketch plane projection: build the ray
    // through the mouse position from the camera view volume and intersect
    // it with the reference plane (origin/normal). Unlike a ray pick this
    // covers the whole viewport — the sketch plane is mathematically
    // infinite — and can never accidentally hit other scene geometry, so
    // cursor, preview and committed points always live on the same plane.
    std::optional<SbVec3f> intersectMouseWithSketchPlane(const SbVec2s& position) {
        SoCamera* camera = getCamera();
        if (!camera) {
            return std::nullopt;
        }
        const SbViewportRegion region = getViewportRegion();
        const SbVec2s pixels = region.getViewportSizePixels();
        if (pixels[0] <= 0 || pixels[1] <= 0) {
            return std::nullopt;
        }
        const float aspect = region.getViewportAspectRatio();
        SbViewVolume volume = camera->getViewVolume(aspect);
        if (aspect < 1.0f && camera->viewportMapping.getValue() == SoCamera::ADJUST_CAMERA) {
            volume.scale(1.0f / aspect);
        }
        SbLine line;
        volume.projectPointToLine(SbVec2f(position[0] / static_cast<float>(pixels[0]),
                                          position[1] / static_cast<float>(pixels[1])),
                                  line);
        const SbPlane plane(toSb(sketchReference.normal), toSb(sketchReference.origin));
        SbVec3f world;
        if (!plane.intersect(line, world)) {
            return std::nullopt; // ray parallel to the sketch plane
        }
        return world;
    }

    void handleClick(const SbVec2s& position, bool contextClick) {
        if (sketchInputActive) {
            // Sketch tool input is left-click only; context clicks neither
            // place points nor open palettes while a tool is active.
            if (contextClick || !sketchPointHandler) {
                return;
            }
            const std::optional<SbVec3f> world = intersectMouseWithSketchPlane(position);
            if (!world) {
                if (sketchMissHandler) {
                    sketchMissHandler();
                }
                return;
            }
            const SketchPoint2D local = worldToSketchPoint(
                Vector3{(*world)[0], (*world)[1], (*world)[2]}, sketchReference);
            sketchPointHandler(local.u, local.v);
            return;
        }

        withPickedPoint(position, [&](const SoPickedPoint* picked) {
            if (pickHandler) {
                pickHandler(picked, contextClick);
            }
        });
    }

    void handleHover(const SbVec2s& position) {
        if (!hoverHandler) {
            return;
        }
        withPickedPoint(position, [&](const SoPickedPoint* picked) { hoverHandler(picked); });
    }

    // Mouse move in sketch input mode: the exact same projection as
    // clicks, so the cursor marker and the committed point can never
    // disagree. Moves whose ray misses the plane are ignored.
    void handleSketchMove(const SbVec2s& position) {
        if (!sketchMoveHandler) {
            return;
        }
        const std::optional<SbVec3f> world = intersectMouseWithSketchPlane(position);
        if (!world) {
            return;
        }
        const SketchPoint2D local = worldToSketchPoint(
            Vector3{(*world)[0], (*world)[1], (*world)[2]}, sketchReference);
        sketchMoveHandler(local.u, local.v);
    }

    // Sketch2D pan: translate the orthographic camera in its own
    // right/up axes by the dragged pixel delta.
    void panCamera(const SbVec2s& deltaPx) {
        SoCamera* camera = getCamera();
        if (!camera || !camera->isOfType(SoOrthographicCamera::getClassTypeId())) {
            return;
        }
        const SbVec2s pixels = getViewportRegion().getViewportSizePixels();
        if (pixels[1] <= 0) {
            return;
        }
        auto* ortho = static_cast<SoOrthographicCamera*>(camera);
        const float worldPerPixel = ortho->height.getValue() / static_cast<float>(pixels[1]);
        const SbRotation orientation = camera->orientation.getValue();
        SbVec3f right;
        SbVec3f up;
        orientation.multVec(SbVec3f(1.0f, 0.0f, 0.0f), right);
        orientation.multVec(SbVec3f(0.0f, 1.0f, 0.0f), up);
        camera->position = camera->position.getValue() -
                           right * (deltaPx[0] * worldPerPixel) -
                           up * (deltaPx[1] * worldPerPixel);
    }

    SbVec2s pressPosition_{-1, -1};
    SbVec2s lastDragPosition_{-1, -1};
    bool leftButtonDown_ = false;
    bool dragged_ = false;
};

// Qt event filter on the viewer's GL widget for Sketch2D trackpad
// navigation. In Sketch2D, two-finger scroll pans along the plane U/V and
// zoom is orthographic at the cursor. In Free3D, wheel/pinch zooms toward
// the current CAD pivot so it cannot get stuck orbiting the world origin.
class SketchNavigationFilter : public QObject {
public:
    explicit SketchNavigationFilter(PickableExaminerViewer* viewer)
        : viewer_(viewer) {}

    bool sketch2DActive = false;

protected:
    bool eventFilter(QObject* watched, QEvent* event) override {
        auto* widget = qobject_cast<QWidget*>(watched);
        if (!widget) {
            return QObject::eventFilter(watched, event);
        }
        if (!viewer_->navigationEnabled) {
            return true;
        }
        if (event->type() == QEvent::Wheel) {
            const auto* wheel = static_cast<QWheelEvent*>(event);
            if (sketch2DActive) {
                const QPoint pixels = wheel->pixelDelta();
                if (!pixels.isNull()) {
                    // Trackpad two-finger scroll: pan.
                    viewer_->panOrthoByWheel(pixels.x(), pixels.y());
                } else {
                    // Discrete mouse wheel: zoom around the cursor.
                    const double steps = wheel->angleDelta().y() / 120.0;
                    viewer_->zoomOrthoAt(std::pow(1.12, steps), wheel->position(),
                                         widget->size());
                }
            } else {
                const QPoint pixels = wheel->pixelDelta();
                const double steps = !pixels.isNull()
                                         ? static_cast<double>(pixels.y()) / 100.0
                                         : static_cast<double>(wheel->angleDelta().y()) / 120.0;
                viewer_->zoomPerspectiveAt(std::pow(viewer_->navigationOptions.zoomSpeed,
                                                     steps));
            }
            return true;
        }
        if (event->type() == QEvent::NativeGesture) {
            const auto* gesture = static_cast<QNativeGestureEvent*>(event);
            if (gesture->gestureType() == Qt::ZoomNativeGesture) {
                if (sketch2DActive) {
                    viewer_->zoomOrthoAt(1.0 + gesture->value(), gesture->position(),
                                         widget->size());
                } else {
                    viewer_->zoomPerspectiveAt(1.0 + gesture->value());
                }
                return true;
            }
        }
        return QObject::eventFilter(watched, event);
    }

private:
    PickableExaminerViewer* viewer_;
};

CoinViewer::CoinViewer(QWidget* parent)
    : scene_(std::make_unique<SceneGraph>()) {
    cameraBounds_.defaultGridBounds = defaultGridViewBounds();
    orbitPivot_ = cameraBounds_.defaultGridBounds.center();

    viewerRoot_ = new SoSeparator;
    viewerRoot_->ref();

    camera_ = new SoPerspectiveCamera;
    viewerRoot_->addChild(camera_);

    auto* fillLight = new SoDirectionalLight;
    fillLight->direction = SbVec3f(-0.4f, 0.3f, -1.0f);
    fillLight->intensity = 0.4f;
    viewerRoot_->addChild(fillLight);

    viewerRoot_->addChild(scene_->root());

    viewer_ = new PickableExaminerViewer(parent);
    viewer_->setSceneGraph(viewerRoot_);
    viewer_->setHeadlight(TRUE);
    viewer_->setDecoration(FALSE);
    viewer_->setBackgroundColor(SbColor(0.13f, 0.14f, 0.17f));
    viewer_->navigationOptions = navigationOptions_;
    viewer_->orbitPivot = toSb(orbitPivot_);
    viewer_->orbitRadius = cameraBounds_.defaultGridBounds.radius();
    // Blended (not screen-door) transparency so the faint plane fills
    // read as a light tint over the bodies.
    viewer_->setTransparencyType(SoGLRenderAction::SORTED_OBJECT_BLEND);

    gestureFilter_ = new SketchNavigationFilter(viewer_);
    if (QWidget* glWidget = viewer_->getGLWidget()) {
        glWidget->installEventFilter(gestureFilter_);
    }

    applyDefaultCameraPose();
    applyNavigationState("init");
}

CoinViewer::~CoinViewer() {
    delete viewer_;
    delete gestureFilter_;
    viewerRoot_->unref();
}

QWidget* CoinViewer::widget() const {
    return viewer_->getWidget();
}

SceneGraph& CoinViewer::scene() {
    return *scene_;
}

void CoinViewer::setPickCallback(PickCallback callback) {
    viewer_->pickHandler = [this, callback = std::move(callback)](const SoPickedPoint* picked,
                                                                  bool contextClick) {
        if (!callback) {
            return;
        }
        callback(picked ? scene_->pickTargetForPickedPoint(picked) : ViewportPickTarget{},
                 contextClick);
    };
}

void CoinViewer::setHoverCallback(HoverCallback callback) {
    viewer_->hoverHandler = [this, callback = std::move(callback)](const SoPickedPoint* picked) {
        if (!callback) {
            return;
        }
        callback(picked ? scene_->pickTargetForPickedPoint(picked) : ViewportPickTarget{});
    };
}

void CoinViewer::setSketchPointCallback(SketchPointCallback callback) {
    viewer_->sketchPointHandler = std::move(callback);
}

void CoinViewer::setSketchMoveCallback(SketchMoveCallback callback) {
    viewer_->sketchMoveHandler = std::move(callback);
}

void CoinViewer::setSketchMissCallback(SketchMissCallback callback) {
    viewer_->sketchMissHandler = std::move(callback);
}

void CoinViewer::setSketchCancelCallback(SketchCancelCallback callback) {
    viewer_->sketchCancelHandler = std::move(callback);
}

void CoinViewer::setSketchInputMode(bool active, const SketchReference& reference) {
    viewer_->sketchInputActive = active;
    viewer_->sketchReference = reference;
}

void CoinViewer::setViewNormalToPlane(const WorkPlane& plane) {
    stopCameraMotion("normalToPlane");
    const SbVec3f origin(static_cast<float>(plane.origin.x),
                         static_cast<float>(plane.origin.y),
                         static_cast<float>(plane.origin.z));
    const SbVec3f normal(static_cast<float>(plane.normal.x),
                         static_cast<float>(plane.normal.y),
                         static_cast<float>(plane.normal.z));
    const SbVec3f up(static_cast<float>(plane.vAxis.x),
                     static_cast<float>(plane.vAxis.y),
                     static_cast<float>(plane.vAxis.z));
    // The camera sits on the side that keeps +U pointing right on screen
    // with up = +V; the canonical XZ plane is left-handed, so its normal
    // view looks from -Y (see planeNormalViewSide).
    const float side =
        static_cast<float>(planeNormalViewSide(plane.uAxis, plane.vAxis, plane.normal));
    const float distance = static_cast<float>(std::max({plane.width, plane.height, 1.0}) * 2.0);
    camera_->position = origin + normal * (distance * side);
    camera_->pointAt(origin, up);
    camera_->nearDistance = 0.01f;
    camera_->farDistance = 1000.0f;
    camera_->focalDistance = distance;
}

void CoinViewer::enterSketch2DView(const WorkPlane& plane, double gridStep, bool showGrid) {
    navigationState_.enterSketch2D();
    stopViewerCameraMotion("enterSketch2D");
    qInfo("[Camera] enterSketch2D navigation=panZoomOnly");
    viewMode_ = ViewMode::Sketch2D;
    policy_.enterSketch2D(sketchReferenceFromWorkPlane(plane));
    replaceCamera(true);
    // Hides the world grid/axes and every work plane frame, and disables
    // orbit — Sketch2D shows only the active sketch plane helper.
    applyHelperVisibility();
    applyNavigationState("enterSketch2D");
    scene_->setBodiesDimmed(true);
    scene_->showSketchPlane(plane, gridStep, showGrid);
    setViewNormalToPlane(plane);
    // Frame only the active sketch plane: hidden helpers and far-away
    // bodies must not inflate the flat 2D view.
    camera_->viewAll(scene_->sketchPlaneRoot(), viewer_->getViewportRegion());
}

void CoinViewer::exitSketch2DView() {
    if (viewMode_ == ViewMode::Free3D) {
        return;
    }
    navigationState_.exitSketch2D();
    stopViewerCameraMotion("exitSketch2D");
    qInfo("[Camera] exitSketch2D navigation=freeOrbit");
    viewMode_ = ViewMode::Free3D;
    policy_.exitSketch2D();
    viewer_->sketchInputActive = false;
    scene_->setBodiesDimmed(false);
    scene_->hideSketchPlane();
    replaceCamera(false);
    applyHelperVisibility();
    applyNavigationState("exitSketch2D");
    applyDefaultCameraPose();
    camera_->viewAll(viewerRoot_, viewer_->getViewportRegion());
}

ViewMode CoinViewer::viewMode() const {
    return viewMode_;
}

void CoinViewer::setSelectedWorkPlane(const std::string& planeId) {
    policy_.setSelectedWorkPlane(planeId);
    scene_->setSelectedWorkPlane(planeId);
    // In "hide other planes" mode the visible plane follows the selection.
    applyHelperVisibility();
}

void CoinViewer::setOtherWorkPlanesHidden(bool hidden) {
    policy_.setOtherWorkPlanesHidden(hidden);
    applyHelperVisibility();
}

bool CoinViewer::otherWorkPlanesHidden() const {
    return policy_.otherWorkPlanesHidden();
}

void CoinViewer::fitWorkPlane(const std::string& planeId) {
    stopCameraMotion("fitWorkPlane");
    if (SoSeparator* node = scene_->workPlaneNode(planeId)) {
        camera_->viewAll(node, viewer_->getViewportRegion());
    }
}

void CoinViewer::setCameraBoundsScene(const ViewBoundsScene& scene) {
    cameraBounds_ = scene;
    if (!cameraBounds_.defaultGridBounds.valid) {
        cameraBounds_.defaultGridBounds = defaultGridViewBounds();
    }
}

void CoinViewer::setOrbitPivot(const cadnext::Vector3& pivot) {
    orbitPivot_ = pivot;
    viewer_->orbitPivot = toSb(pivot);
    if (camera_) {
        const SbVec3f position = camera_->position.getValue();
        const double distance = std::max(static_cast<double>((position - toSb(pivot)).length()),
                                         navigationOptions_.minDistance);
        camera_->focalDistance = static_cast<float>(distance);
    }
    qInfo("[Camera] OrbitPivot=(%.4f, %.4f, %.4f)",
          pivot.x, pivot.y, pivot.z);
}

void CoinViewer::focusSelection(const SelectionState& selection) {
    lastSelection_ = selection;
    const CameraFocusTarget target = cameraFocusTargetForSelection(cameraBounds_, selection);
    if (!target.valid) {
        return;
    }
    setOrbitPivot(target.center);
    viewer_->orbitRadius = target.radius;
    if (viewMode_ != ViewMode::Sketch2D) {
        focusCameraTarget(target);
    }
}

void CoinViewer::frameSelection(const SelectionState& selection) {
    stopCameraMotion("fitSelection");
    lastSelection_ = selection;
    const CameraFocusTarget target = cameraFocusTargetForSelection(cameraBounds_, selection);
    if (!target.valid) {
        fitView();
        return;
    }
    qInfo("[Camera] FitSelection kind=%s center=(%.4f, %.4f, %.4f) radius=%.4f",
          target.kind.c_str(), target.center.x, target.center.y, target.center.z,
          target.radius);
    frameCameraTarget(target, false);
}

void CoinViewer::fitView() {
    stopCameraMotion("fitView");
    const CameraFocusTarget target = cameraFitAllTarget(cameraBounds_, lastSelection_);
    if (!target.valid) {
        return;
    }
    qInfo("[Camera] FitAll bounds=(%.4f, %.4f, %.4f)-(%.4f, %.4f, %.4f)",
          target.bounds.min.x, target.bounds.min.y, target.bounds.min.z,
          target.bounds.max.x, target.bounds.max.y, target.bounds.max.z);

    switch (policy_.fitTarget(target.kind != "DefaultGrid")) {
    case ViewportFitTarget::ActiveSketchPlane:
        frameCameraTarget(target, false);
        return;
    case ViewportFitTarget::Bodies:
        // Bodies plus committed sketches; helper planes/axes are excluded.
        frameCameraTarget(target, false);
        return;
    case ViewportFitTarget::SelectedPlane:
        if (SoSeparator* node = scene_->workPlaneNode(policy_.selectedWorkPlane())) {
            camera_->viewAll(node, viewer_->getViewportRegion());
            return;
        }
        break;
    case ViewportFitTarget::WholeScene:
        break;
    }
    frameCameraTarget(target, false);
}

void CoinViewer::resetCamera() {
    stopCameraMotion("resetCamera");
    if (viewMode_ == ViewMode::Sketch2D) {
        fitView();
        return;
    }
    CameraFocusTarget target = cameraFocusTargetForSelection(cameraBounds_, lastSelection_);
    if (!target.valid) {
        target = cameraFitAllTarget(cameraBounds_, lastSelection_);
    }
    if (!target.valid) {
        applyDefaultCameraPose();
        return;
    }
    frameCameraTarget(target, true);
}

void CoinViewer::applyDefaultCameraPose() {
    camera_->position = kDefaultCameraPosition;
    camera_->pointAt(kSceneCenter, kWorldUp);
    camera_->nearDistance = 0.05f;
    camera_->farDistance = 1000.0f;
    camera_->focalDistance = (kDefaultCameraPosition - kSceneCenter).length();
    setOrbitPivot(fromSb(kSceneCenter));
    viewer_->orbitRadius = kDefaultGridFitRadius;
}

void CoinViewer::applyIsometricCameraPose(const Vector3& center, double distance) {
    SbVec3f direction = kDefaultCameraPosition - kSceneCenter;
    if (direction.normalize() == 0.0f) {
        direction = SbVec3f(0.55f, -0.55f, 0.45f);
        direction.normalize();
    }
    const SbVec3f sbCenter = toSb(center);
    camera_->position = sbCenter + direction * static_cast<float>(distance);
    camera_->pointAt(sbCenter, kWorldUp);
    camera_->focalDistance = static_cast<float>(distance);
}

void CoinViewer::frameCameraTarget(const CameraFocusTarget& target, bool isometric) {
    if (!target.valid || !camera_) {
        return;
    }
    const double paddedRadius =
        std::max(target.radius * navigationOptions_.fitPadding, navigationOptions_.minDistance);
    double distance = paddedRadius * 2.5;

    if (camera_->isOfType(SoPerspectiveCamera::getClassTypeId())) {
        auto* perspective = static_cast<SoPerspectiveCamera*>(camera_);
        const double verticalFov = perspective->heightAngle.getValue();
        const double fov = std::clamp(verticalFov, 0.1, 2.8);
        distance = paddedRadius / std::sin(fov * 0.5);
    } else if (camera_->isOfType(SoOrthographicCamera::getClassTypeId())) {
        auto* ortho = static_cast<SoOrthographicCamera*>(camera_);
        const SbVec2s pixels = viewer_->getViewportRegion().getViewportSizePixels();
        const double aspect = pixels[1] > 0
                                  ? std::max(0.1, static_cast<double>(pixels[0]) /
                                                     static_cast<double>(pixels[1]))
                                  : 1.0;
        const double width = std::max(target.bounds.max.x - target.bounds.min.x,
                                      target.bounds.max.y - target.bounds.min.y);
        const double height = std::max({target.bounds.max.z - target.bounds.min.z,
                                        target.bounds.max.y - target.bounds.min.y,
                                        target.bounds.max.x - target.bounds.min.x});
        ortho->height = static_cast<float>(
            std::clamp(std::max(height, width / aspect) * navigationOptions_.fitPadding,
                       static_cast<double>(kMinOrthoViewHeight),
                       static_cast<double>(kMaxOrthoViewHeight)));
    }

    distance = std::clamp(distance, navigationOptions_.minDistance,
                          navigationOptions_.maxDistance);
    if (isometric) {
        applyIsometricCameraPose(target.center, distance);
    } else {
        const SbVec3f forward = cameraForward(camera_);
        camera_->position = toSb(target.center) - forward * static_cast<float>(distance);
        camera_->focalDistance = static_cast<float>(distance);
    }
    setOrbitPivot(target.center);
    viewer_->orbitRadius = target.radius;
    updateClipping(distance, target.radius);
}

void CoinViewer::focusCameraTarget(const CameraFocusTarget& target) {
    if (!target.valid || !camera_) {
        return;
    }
    const SbVec3f forward = cameraForward(camera_);
    const SbVec3f position = camera_->position.getValue();
    double distance = std::fabs(static_cast<double>(dot(toSb(target.center) - position,
                                                       forward)));
    if (distance < navigationOptions_.minDistance) {
        distance = std::max(static_cast<double>((position - toSb(target.center)).length()),
                            target.radius * navigationOptions_.fitPadding);
    }
    distance = std::clamp(distance, navigationOptions_.minDistance,
                          navigationOptions_.maxDistance);
    camera_->position = toSb(target.center) - forward * static_cast<float>(distance);
    camera_->focalDistance = static_cast<float>(distance);
    updateClipping(distance, target.radius);
}

void CoinViewer::updateClipping(double distance, double radius) {
    if (!camera_) {
        return;
    }
    applyClipPlanes(camera_, navigationOptions_, distance, radius);
}

void CoinViewer::stopViewerCameraMotion(const char* reason) {
    qInfo("[Camera] stopCameraMotion reason=%s", reason ? reason : "unspecified");
    if (viewer_) {
        viewer_->stopCameraMotion(navigationState_.inertiaEnabled());
    }
}

void CoinViewer::stopCameraMotion(const char* reason) {
    navigationState_.stopCameraMotion();
    stopViewerCameraMotion(reason);
}

void CoinViewer::clearNavigationInputState() {
    if (viewer_) {
        viewer_->clearNavigationInputState();
    }
}

bool CoinViewer::hasCameraMotion() const {
    return viewer_ &&
           (viewer_->isAnimating() || viewer_->navigationInputActive() ||
            navigationState_.cameraMotionActive());
}

bool CoinViewer::isNavigationEnabled() const {
    return navigationState_.navigationEnabled();
}

void CoinViewer::setNavigationEnabled(bool enabled) {
    navigationState_.setNavigationEnabled(enabled);
    applyNavigationState(enabled ? "enableNavigation" : "disableNavigation");
}

void CoinViewer::applyNavigationState(const char* /*reason*/) {
    if (!viewer_) {
        return;
    }
    viewer_->navigationEnabled = navigationState_.navigationEnabled();
    viewer_->freeOrbitEnabled = policy_.orbitEnabled() && navigationState_.orbitEnabled();
    viewer_->setAnimationEnabled(navigationState_.inertiaEnabled() ? TRUE : FALSE);
    gestureFilter_->sketch2DActive = policy_.inSketch2D() &&
                                     navigationState_.mode() == NavigationMode::Sketch2D;
}

void CoinViewer::replaceCamera(bool orthographic) {
    SoCamera* newCamera = orthographic ? static_cast<SoCamera*>(new SoOrthographicCamera)
                                       : static_cast<SoCamera*>(new SoPerspectiveCamera);
    viewerRoot_->replaceChild(0, newCamera);
    camera_ = newCamera;
    viewer_->setCamera(camera_);
}

void CoinViewer::applyHelperVisibility() {
    scene_->setWorldHelpersVisible(policy_.worldGridVisible());
    const SketchPlane planes[] = {SketchPlane::XY, SketchPlane::XZ, SketchPlane::YZ};
    for (const SketchPlane plane : planes) {
        const std::string planeId = canonicalWorkPlaneId(plane);
        scene_->setWorkPlaneVisible(planeId, policy_.workPlaneVisible(planeId));
    }
    applyNavigationState("helperVisibility");
}

} // namespace cadnext::viewer
