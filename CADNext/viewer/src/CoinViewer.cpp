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
#include <QWheelEvent>
#include <QWidget>

namespace cadnext::viewer {

namespace {

const SbVec3f kDefaultCameraPosition(9.0f, -9.0f, 7.0f);
const SbVec3f kSceneCenter(0.0f, 0.0f, 0.0f);
const SbVec3f kWorldUp(0.0f, 0.0f, 1.0f);

// A press/release pair further apart than this is treated as a drag
// (camera navigation), not a pick click.
constexpr short kClickDragThresholdPx = 3;

// Sketch2D orthographic zoom clamps (view height in world units).
constexpr float kMinOrthoViewHeight = 0.05f;
constexpr float kMaxOrthoViewHeight = 500.0f;

SbVec3f toSb(const Vector3& v) {
    return {static_cast<float>(v.x), static_cast<float>(v.y), static_cast<float>(v.z)};
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

protected:
    SbBool processSoEvent(const SoEvent* event) override {
        if (event->isOfType(SoKeyboardEvent::getClassTypeId())) {
            const auto* keyEvent = static_cast<const SoKeyboardEvent*>(event);
            if (keyEvent->getKey() == SoKeyboardEvent::ESCAPE &&
                keyEvent->getState() == SoButtonEvent::DOWN && sketchInputActive) {
                if (sketchCancelHandler) {
                    sketchCancelHandler();
                }
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
// navigation: two-finger scroll pans along the plane U/V, pinch zooms at
// the cursor, and a plain mouse wheel zooms too. The events are consumed
// so SoQt's default wheel-dolly/orbit can never knock the camera off the
// plane normal. Inactive in Free3D, where the examiner viewer keeps its
// standard navigation.
class SketchNavigationFilter : public QObject {
public:
    explicit SketchNavigationFilter(PickableExaminerViewer* viewer)
        : viewer_(viewer) {}

    bool sketch2DActive = false;

protected:
    bool eventFilter(QObject* watched, QEvent* event) override {
        auto* widget = qobject_cast<QWidget*>(watched);
        if (!sketch2DActive || !widget) {
            return QObject::eventFilter(watched, event);
        }
        if (event->type() == QEvent::Wheel) {
            const auto* wheel = static_cast<QWheelEvent*>(event);
            const QPoint pixels = wheel->pixelDelta();
            if (!pixels.isNull()) {
                // Trackpad two-finger scroll: pan.
                viewer_->panOrthoByWheel(pixels.x(), pixels.y());
            } else {
                // Discrete mouse wheel: zoom around the cursor.
                const double steps = wheel->angleDelta().y() / 120.0;
                viewer_->zoomOrthoAt(std::pow(1.12, steps), wheel->position(), widget->size());
            }
            return true;
        }
        if (event->type() == QEvent::NativeGesture) {
            const auto* gesture = static_cast<QNativeGestureEvent*>(event);
            if (gesture->gestureType() == Qt::ZoomNativeGesture) {
                viewer_->zoomOrthoAt(1.0 + gesture->value(), gesture->position(),
                                     widget->size());
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
    // Blended (not screen-door) transparency so the faint plane fills
    // read as a light tint over the bodies.
    viewer_->setTransparencyType(SoGLRenderAction::SORTED_OBJECT_BLEND);

    gestureFilter_ = new SketchNavigationFilter(viewer_);
    if (QWidget* glWidget = viewer_->getGLWidget()) {
        glWidget->installEventFilter(gestureFilter_);
    }

    applyDefaultCameraPose();
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
    viewMode_ = ViewMode::Sketch2D;
    policy_.enterSketch2D(sketchReferenceFromWorkPlane(plane));
    replaceCamera(true);
    // Hides the world grid/axes and every work plane frame, and disables
    // orbit — Sketch2D shows only the active sketch plane helper.
    applyHelperVisibility();
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
    viewMode_ = ViewMode::Free3D;
    policy_.exitSketch2D();
    viewer_->sketchInputActive = false;
    scene_->setBodiesDimmed(false);
    scene_->hideSketchPlane();
    replaceCamera(false);
    applyHelperVisibility();
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
    if (SoSeparator* node = scene_->workPlaneNode(planeId)) {
        camera_->viewAll(node, viewer_->getViewportRegion());
    }
}

void CoinViewer::fitView() {
    switch (policy_.fitTarget(scene_->objectsRoot()->getNumChildren() > 0)) {
    case ViewportFitTarget::ActiveSketchPlane:
        camera_->viewAll(scene_->sketchPlaneRoot(), viewer_->getViewportRegion());
        return;
    case ViewportFitTarget::Bodies:
        // Bodies plus committed sketches; helper planes/axes are excluded.
        camera_->viewAll(scene_->documentRoot(), viewer_->getViewportRegion());
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
    camera_->viewAll(viewerRoot_, viewer_->getViewportRegion());
}

void CoinViewer::resetCamera() {
    if (viewMode_ == ViewMode::Sketch2D) {
        return;
    }
    applyDefaultCameraPose();
    camera_->viewAll(viewerRoot_, viewer_->getViewportRegion());
}

void CoinViewer::applyDefaultCameraPose() {
    camera_->position = kDefaultCameraPosition;
    camera_->pointAt(kSceneCenter, kWorldUp);
    camera_->nearDistance = 0.05f;
    camera_->farDistance = 1000.0f;
    camera_->focalDistance = (kDefaultCameraPosition - kSceneCenter).length();
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
    viewer_->freeOrbitEnabled = policy_.orbitEnabled();
    gestureFilter_->sketch2DActive = policy_.inSketch2D();
}

} // namespace cadnext::viewer
