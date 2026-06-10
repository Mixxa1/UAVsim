#include "cadnext/viewer/CoinViewer.hpp"

#include <cstdlib>

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/SoPickedPoint.h>
#include <Inventor/actions/SoRayPickAction.h>
#include <Inventor/events/SoKeyboardEvent.h>
#include <Inventor/events/SoLocation2Event.h>
#include <Inventor/events/SoMouseButtonEvent.h>
#include <Inventor/nodes/SoDirectionalLight.h>
#include <Inventor/nodes/SoPerspectiveCamera.h>
#include <Inventor/nodes/SoSeparator.h>

#include <QWidget>

namespace cadnext::viewer {

namespace {

const SbVec3f kDefaultCameraPosition(9.0f, -9.0f, 7.0f);
const SbVec3f kSceneCenter(0.0f, 0.0f, 0.0f);
const SbVec3f kWorldUp(0.0f, 0.0f, 1.0f);

// A press/release pair further apart than this is treated as a drag
// (camera navigation), not a pick click.
constexpr short kClickDragThresholdPx = 3;

// Extracts sketch-local u/v from a world point on a canonical plane
// (planes pass through the origin, so this is component selection).
void worldToSketchUV(SketchPlane plane, const SbVec3f& world, double& u, double& v) {
    switch (plane) {
    case SketchPlane::XY:
        u = world[0];
        v = world[1];
        return;
    case SketchPlane::XZ:
        u = world[0];
        v = world[2];
        return;
    case SketchPlane::YZ:
        u = world[1];
        v = world[2];
        return;
    }
    u = world[0];
    v = world[1];
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

    std::function<void(const SoPickedPoint*)> pickHandler;
    std::function<void(double u, double v)> sketchPointHandler;
    std::function<void()> sketchCancelHandler;
    bool sketchInputActive = false;
    SketchPlane sketchPlane = SketchPlane::XY;

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
                } else if (buttonEvent->getState() == SoButtonEvent::UP) {
                    const bool isClick = leftButtonDown_ && !dragged_;
                    leftButtonDown_ = false;
                    if (isClick) {
                        handleClick(event->getPosition());
                    }
                }
            }
        } else if (leftButtonDown_ && event->isOfType(SoLocation2Event::getClassTypeId())) {
            const SbVec2s delta = event->getPosition() - pressPosition_;
            if (std::abs(delta[0]) > kClickDragThresholdPx ||
                std::abs(delta[1]) > kClickDragThresholdPx) {
                dragged_ = true;
            }
        }
        return SoQtExaminerViewer::processSoEvent(event);
    }

private:
    void handleClick(const SbVec2s& position) {
        SoRayPickAction pick(getViewportRegion());
        pick.setPoint(position);
        pick.setRadius(4.0f);
        // The scene manager graph contains the camera, which the pick
        // action needs to build the ray.
        pick.apply(getSceneManager()->getSceneGraph());
        const SoPickedPoint* picked = pick.getPickedPoint();

        if (sketchInputActive && sketchPointHandler) {
            // Sketch tool click: read the position from the ray hit (the
            // translucent sketch plane quad is pickable for exactly this)
            // and flatten it onto the plane.
            if (picked) {
                double u = 0.0;
                double v = 0.0;
                worldToSketchUV(sketchPlane, picked->getPoint(), u, v);
                sketchPointHandler(u, v);
            }
            return;
        }

        if (pickHandler) {
            pickHandler(picked);
        }
    }

    SbVec2s pressPosition_{-1, -1};
    bool leftButtonDown_ = false;
    bool dragged_ = false;
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

    applyDefaultCameraPose();
}

CoinViewer::~CoinViewer() {
    delete viewer_;
    viewerRoot_->unref();
}

QWidget* CoinViewer::widget() const {
    return viewer_->getWidget();
}

SceneGraph& CoinViewer::scene() {
    return *scene_;
}

void CoinViewer::setPickCallback(PickCallback callback) {
    viewer_->pickHandler = [this, callback = std::move(callback)](const SoPickedPoint* picked) {
        if (!callback) {
            return;
        }
        callback(picked ? scene_->pickTargetForPath(picked->getPath()) : ViewportPickTarget{});
    };
}

void CoinViewer::setSketchPointCallback(SketchPointCallback callback) {
    viewer_->sketchPointHandler = std::move(callback);
}

void CoinViewer::setSketchCancelCallback(SketchCancelCallback callback) {
    viewer_->sketchCancelHandler = std::move(callback);
}

void CoinViewer::setSketchInputMode(bool active, SketchPlane plane) {
    viewer_->sketchInputActive = active;
    viewer_->sketchPlane = plane;
}

void CoinViewer::fitView() {
    // Frame the document objects when there are any; otherwise frame the
    // whole scene so the grid stays in view in an empty document.
    if (scene_->objectsRoot()->getNumChildren() > 0) {
        camera_->viewAll(scene_->objectsRoot(), viewer_->getViewportRegion());
    } else {
        camera_->viewAll(viewerRoot_, viewer_->getViewportRegion());
    }
}

void CoinViewer::resetCamera() {
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

} // namespace cadnext::viewer
