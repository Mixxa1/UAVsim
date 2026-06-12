#include "cadnext/gui/MainWindow.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>

#include <QCloseEvent>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QCursor>
#include <QLabel>
#include <QMenu>
#include <QMenuBar>
#include <QMessageBox>
#include <QSignalBlocker>
#include <QStatusBar>
#include <QVBoxLayout>
#include <QtLogging>

#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/gui/CutExtrudeDialog.hpp"
#include "cadnext/gui/ExtrudeDialog.hpp"
#include "cadnext/gui/ProjectTree.hpp"
#include "cadnext/gui/PropertyPanel.hpp"
#include "cadnext/gui/SketchToolBar.hpp"
#include "cadnext/gui/ToolBar.hpp"
#include "cadnext/kernel/ExtrudeMesh.hpp"
#include "cadnext/kernel/KernelFactory.hpp"

namespace cadnext::gui {

namespace {

constexpr double kMinScale = 0.001;
constexpr double kMinDimension = 0.001;
constexpr double kMinSketchExtent = 1.0e-6;

// Cut Extrude runs through the OCCT boolean pipeline only — there is no
// procedural mesh-boolean fallback by design.
#ifdef CADNEXT_WITH_OCCT
constexpr bool kOcctBackendAvailable = true;
#else
constexpr bool kOcctBackendAvailable = false;
#endif

double sanitize(double value, double fallback, double minimum = -1.0e12) {
    if (!std::isfinite(value)) {
        return fallback;
    }
    return std::max(value, minimum);
}

QString treeTypeText(const Object& object) {
    if (object.type == ObjectType::ReferencePlane) {
        return QObject::tr("Reference Plane");
    }
    return QString::fromUtf8(primitiveKindName(object.primitive.kind));
}

QString workPlaneTypeText(const WorkPlane& plane) {
    switch (plane.kind) {
    case WorkPlaneKind::XY: return QObject::tr("Canonical XY");
    case WorkPlaneKind::XZ: return QObject::tr("Canonical XZ");
    case WorkPlaneKind::YZ: return QObject::tr("Canonical YZ");
    case WorkPlaneKind::ObjectPlane: return QObject::tr("Reference Plane");
    case WorkPlaneKind::FacePlane: return QObject::tr("Face Plane");
    }
    return QObject::tr("Work Plane");
}

int maxNumberSuffix(const std::string& id, const char* prefix, int current) {
    if (id.rfind(prefix, 0) == 0) {
        const int number = std::atoi(id.c_str() + std::strlen(prefix));
        return std::max(current, number + 1);
    }
    return current;
}

QString profileKindText(cadnext::SketchProfileKind kind) {
    switch (kind) {
    case cadnext::SketchProfileKind::Rectangle: return QObject::tr("Rectangle");
    case cadnext::SketchProfileKind::Circle: return QObject::tr("Circle");
    case cadnext::SketchProfileKind::Polygon: return QObject::tr("Polygon");
    case cadnext::SketchProfileKind::Unsupported: break;
    }
    return QObject::tr("Profile");
}

const cadnext::SketchProfile* profileById(const std::vector<cadnext::SketchProfile>& profiles,
                                          const std::string& profileId) {
    for (const cadnext::SketchProfile& profile : profiles) {
        if (profile.id == profileId) {
            return &profile;
        }
    }
    return nullptr;
}

// Profile a clicked entity stands for: rectangles/circles match their own
// profile, a line matches the polygon loop it participates in.
const cadnext::SketchProfile* profileForEntityId(
    const std::vector<cadnext::SketchProfile>& profiles, const std::string& entityId) {
    for (const cadnext::SketchProfile& profile : profiles) {
        if (profile.sourceEntityId == entityId) {
            return &profile;
        }
        for (const std::string& id : profile.sourceEntityIds) {
            if (id == entityId) {
                return &profile;
            }
        }
    }
    return nullptr;
}

double dot(const Vector3& a, const Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

double projectedOffsetAlongNormal(const Vector3& point, const SketchReference& reference) {
    const Vector3 delta{point.x - reference.origin.x,
                        point.y - reference.origin.y,
                        point.z - reference.origin.z};
    return dot(delta, reference.normal);
}

void accumulateProjectedBounds(const kernel::ShapeBounds& bounds,
                               const SketchReference& reference,
                               double& outMin, double& outMax) {
    outMin = std::numeric_limits<double>::infinity();
    outMax = -std::numeric_limits<double>::infinity();
    const std::array<Vector3, 8> corners = {
        Vector3{bounds.min.x, bounds.min.y, bounds.min.z},
        Vector3{bounds.max.x, bounds.min.y, bounds.min.z},
        Vector3{bounds.min.x, bounds.max.y, bounds.min.z},
        Vector3{bounds.max.x, bounds.max.y, bounds.min.z},
        Vector3{bounds.min.x, bounds.min.y, bounds.max.z},
        Vector3{bounds.max.x, bounds.min.y, bounds.max.z},
        Vector3{bounds.min.x, bounds.max.y, bounds.max.z},
        Vector3{bounds.max.x, bounds.max.y, bounds.max.z},
    };
    for (const Vector3& corner : corners) {
        const double offset = projectedOffsetAlongNormal(corner, reference);
        outMin = std::min(outMin, offset);
        outMax = std::max(outMax, offset);
    }
}

double boundsDiagonal(const kernel::ShapeBounds& bounds) {
    const double dx = bounds.max.x - bounds.min.x;
    const double dy = bounds.max.y - bounds.min.y;
    const double dz = bounds.max.z - bounds.min.z;
    return std::sqrt(dx * dx + dy * dy + dz * dz);
}

QString cutDepthModeText(CutDepthMode mode) {
    switch (mode) {
    case CutDepthMode::Distance: return QObject::tr("Distance");
    case CutDepthMode::ThroughAll: return QObject::tr("Through All");
    case CutDepthMode::ToObject: return QObject::tr("To Object");
    }
    return QObject::tr("Distance");
}

} // namespace

MainWindow::MainWindow(QWidget* parent)
    : QMainWindow(parent) {
    document_.setName("CADNext Prototype Document");

    // makeKernel falls back to the stub backend when OCCT is not compiled
    // in; the evaluator then reports isValid=false and the viewer keeps
    // using procedural primitives.
    kernel_ = kernel::makeKernel(kernel::KernelBackend::Occt);
    evaluator_ = std::make_unique<kernel::GeometryEvaluator>(*kernel_);

    toolBar_ = new ToolBar(this);
    addToolBar(Qt::TopToolBarArea, toolBar_);

    sketchToolBar_ = new SketchToolBar(this);
    addToolBarBreak(Qt::TopToolBarArea);
    addToolBar(Qt::TopToolBarArea, sketchToolBar_);

    projectTree_ = new ProjectTree(this);
    addCanonicalWorkPlanesToTree();
    treeDock_ = new QDockWidget(tr("Project"), this);
    treeDock_->setWidget(projectTree_);
    treeDock_->setFeatures(QDockWidget::DockWidgetMovable);
    addDockWidget(Qt::LeftDockWidgetArea, treeDock_);

    // Properties live in a right-side inspector dock (CAD layout: tree |
    // viewport | inspector) so they no longer cost viewport height.
    propertyPanel_ = new PropertyPanel(this);
    propertyDock_ = new QDockWidget(tr("Properties"), this);
    propertyDock_->setWidget(propertyPanel_);
    propertyDock_->setFeatures(QDockWidget::DockWidgetMovable |
                               QDockWidget::DockWidgetClosable);
    propertyDock_->setMinimumWidth(300);
    addDockWidget(Qt::RightDockWidgetArea, propertyDock_);

    createMenus();

    // Body toolbar.
    connect(toolBar_->addBoxAction(), &QAction::triggered, this,
            [this]() { addPrimitiveObject(PrimitiveKind::Box); });
    connect(toolBar_->addCylinderAction(), &QAction::triggered, this,
            [this]() { addPrimitiveObject(PrimitiveKind::Cylinder); });
    connect(toolBar_->addSphereAction(), &QAction::triggered, this,
            [this]() { addPrimitiveObject(PrimitiveKind::Sphere); });
    connect(toolBar_->addPlaneAction(), &QAction::triggered, this,
            [this]() { addReferencePlane(); });
    connect(toolBar_->extrudeAction(), &QAction::triggered, this,
            [this]() { openExtrudeDialog(); });
    connect(toolBar_->cutExtrudeAction(), &QAction::triggered, this,
            [this]() { openCutExtrudeDialog(); });
    connect(toolBar_->createSketchOnFaceAction(), &QAction::triggered, this,
            [this]() { createSketchOnSelectedFace(); });
    connect(toolBar_->workPlaneFromFaceAction(), &QAction::triggered, this,
            [this]() { createWorkPlaneFromSelectedFace(); });
    connect(toolBar_->normalToFaceAction(), &QAction::triggered, this,
            [this]() { normalToSelectedFace(); });
    connect(toolBar_->deleteSelectedAction(), &QAction::triggered, this,
            [this]() { deleteSelected(); });
    connect(toolBar_->fitViewAction(), &QAction::triggered, this, [this]() {
        if (viewer_) {
            viewer_->fitView();
        }
    });
    connect(toolBar_->resetCameraAction(), &QAction::triggered, this, [this]() {
        if (viewer_) {
            viewer_->resetCamera();
        }
    });

    // Sketch toolbar.
    connect(sketchToolBar_->newSketchXYAction(), &QAction::triggered, this,
            [this]() { newSketch(SketchPlane::XY); });
    connect(sketchToolBar_->newSketchXZAction(), &QAction::triggered, this,
            [this]() { newSketch(SketchPlane::XZ); });
    connect(sketchToolBar_->newSketchYZAction(), &QAction::triggered, this,
            [this]() { newSketch(SketchPlane::YZ); });
    connect(sketchToolBar_->createSketchAction(), &QAction::triggered, this,
            [this]() { createSketchFromSelectedPlane(); });
    connect(sketchToolBar_->enterSketchAction(), &QAction::triggered, this, [this]() {
        if (selectionKind_ == SelectionKind::Sketch) {
            enterSketchMode(selectedId_);
        }
    });
    connect(sketchToolBar_->exitSketchAction(), &QAction::triggered, this,
            [this]() { exitSketchMode(); });
    connect(sketchToolBar_->selectToolAction(), &QAction::triggered, this,
            [this]() { setSketchTool(SketchTool::Select); });
    connect(sketchToolBar_->lineToolAction(), &QAction::triggered, this,
            [this]() { setSketchTool(SketchTool::Line); });
    connect(sketchToolBar_->rectangleToolAction(), &QAction::triggered, this,
            [this]() { setSketchTool(SketchTool::Rectangle); });
    connect(sketchToolBar_->circleToolAction(), &QAction::triggered, this,
            [this]() { setSketchTool(SketchTool::Circle); });
    connect(sketchToolBar_->snapGridAction(), &QAction::toggled, this,
            [this](bool enabled) { onSnapToggled(enabled); });
    connect(sketchToolBar_->showGridAction(), &QAction::toggled, this,
            [this](bool visible) { onShowGridToggled(visible); });
    connect(sketchToolBar_->gridStepSpinBox(), &QDoubleSpinBox::valueChanged, this,
            [this](double step) { onGridStepChanged(step); });

    // Project tree.
    connect(projectTree_, &ProjectTree::workPlaneSelected, this,
            [this](const QString& planeId) { selectWorkPlane(planeId.toStdString()); });
    connect(projectTree_, &ProjectTree::bodySelected, this,
            [this](const QString& objectId) { selectBody(objectId.toStdString()); });
    connect(projectTree_, &ProjectTree::sketchSelected, this,
            [this](const QString& sketchId) { selectSketch(sketchId.toStdString()); });
    connect(projectTree_, &ProjectTree::entitySelected, this,
            [this](const QString& sketchId, const QString& entityId) {
                selectEntity(sketchId.toStdString(), entityId.toStdString());
            });
    connect(projectTree_, &ProjectTree::selectionCleared, this, [this]() { clearSelection(); });
    connect(projectTree_, &ProjectTree::sketchActivated, this, [this](const QString& sketchId) {
        selectSketch(sketchId.toStdString());
        enterSketchMode(sketchId.toStdString());
    });

    // Property panel.
    connect(propertyPanel_, &PropertyPanel::nameEdited, this,
            [this](const QString& objectId, const QString& newName) {
                onObjectNameEdited(objectId, newName);
            });
    connect(propertyPanel_, &PropertyPanel::sketchNameEdited, this,
            [this](const QString& sketchId, const QString& newName) {
                onSketchNameEdited(sketchId, newName);
            });
    connect(propertyPanel_, &PropertyPanel::entityNameEdited, this,
            [this](const QString& sketchId, const QString& entityId, const QString& newName) {
                onEntityNameEdited(sketchId, entityId, newName);
            });
    connect(propertyPanel_, &PropertyPanel::transformEdited, this,
            [this](const QString& objectId, const Transform& transform) {
                onTransformEdited(objectId, transform);
            });
    connect(propertyPanel_, &PropertyPanel::primitiveEdited, this,
            [this](const QString& objectId, const PrimitiveParameters& parameters) {
                onPrimitiveEdited(objectId, parameters);
            });

    statusBar()->showMessage(tr("Free3D: select body, work plane or sketch"));
    modeStatusLabel_ = new QLabel(this);
    statusBar()->addPermanentWidget(modeStatusLabel_);
    updateModeStatusLabel();
#ifdef CADNEXT_WITH_OCCT
    statusBar()->addPermanentWidget(
        new QLabel(tr("Geometry backend: OCCT BRep evaluation"), this));
#else
    statusBar()->addPermanentWidget(
        new QLabel(tr("Geometry backend: Procedural viewer primitives"), this));
#endif

    updateWindowTitle();
    updateUndoRedoActions();
}

MainWindow::~MainWindow() = default;

void MainWindow::initializeViewport() {
    auto* container = new QWidget(this);
    auto* layout = new QVBoxLayout(container);
    layout->setContentsMargins(0, 0, 0, 0);

    viewer_ = std::make_unique<viewer::CoinViewer>(container);
    layout->addWidget(viewer_->widget());
    setCentralWidget(container);

    // Sketch2D plane identity badge: overlay in the viewport corner so the
    // user always sees which plane (and which world axes) they draw on.
    planeBadge_ = new QLabel(container);
    planeBadge_->setStyleSheet(
        QStringLiteral("background-color: rgba(20, 24, 34, 190); color: #e8ecf4;"
                       "border: 1px solid rgba(120, 150, 210, 120); border-radius: 4px;"
                       "padding: 6px 10px; font-weight: 600;"));
    planeBadge_->setAttribute(Qt::WA_TransparentForMouseEvents);
    planeBadge_->move(16, 16);
    planeBadge_->hide();

    selection_ = std::make_unique<viewer::SelectionController>(viewer_->scene());

    viewer_->setPickCallback([this](const viewer::ViewportPickTarget& target, bool contextClick) {
        if (target.isSketchEntity()) {
            selectEntity(target.sketchId, target.entityId);
        } else if (target.isProfile()) {
            // Click inside a detected closed region selects the profile.
            selectProfile(target.profileId);
        } else if (target.isWorkPlane()) {
            selectWorkPlane(target.workPlaneId);
            showPlaneActionPalette(contextClick);
        } else if (target.isBodyFace()) {
            // Face picking layers on top of body picking: the click
            // selects the face; the owning body stays reachable through
            // the tree (and is reported in the property panel).
            qInfo("[FacePick] body=%s triangle=%d faceId=%s",
                  target.objectId.c_str(), target.triangleIndex, target.faceId.c_str());
            selectBodyFace(target.objectId, target.faceId);
            showFaceActionPalette(contextClick);
        } else if (target.isBody()) {
            if (target.faceLookupAttempted) {
                qInfo("[FacePick] fallback Body selection: body=%s triangle=%d has no faceId",
                      target.objectId.c_str(), target.triangleIndex);
            } else if (!kOcctBackendAvailable &&
                       bodyFaces_.find(target.objectId) == bodyFaces_.end()) {
                statusBar()->showMessage(tr("Face picking requires OCCT backend"), 5000);
            }
            selectBody(target.objectId);
        } else {
            clearSelection();
        }
        // Context click on a profile/entity offers Extrude/Cut directly.
        if (contextClick && (target.isProfile() || target.isSketchEntity()) &&
            (toolBar_->extrudeAction()->isEnabled() ||
             toolBar_->cutExtrudeAction()->isEnabled())) {
            QMenu menu(this);
            QAction* extrude = nullptr;
            QAction* cutExtrude = nullptr;
            if (toolBar_->extrudeAction()->isEnabled()) {
                extrude = menu.addAction(tr("Extrude"));
            }
            if (toolBar_->cutExtrudeAction()->isEnabled()) {
                cutExtrude = menu.addAction(tr("Cut Extrude"));
            }
            QAction* chosen = menu.exec(QCursor::pos());
            if (chosen == extrude) {
                openExtrudeDialog();
            } else if (chosen == cutExtrude) {
                openCutExtrudeDialog();
            }
        }
    });
    viewer_->setHoverCallback([this](const viewer::ViewportPickTarget& target) {
        const std::string nextPlane =
            target.isWorkPlane() ? target.workPlaneId : std::string();
        if (nextPlane != hoveredWorkPlaneId_) {
            hoveredWorkPlaneId_ = nextPlane;
            viewer_->scene().setHoveredWorkPlane(hoveredWorkPlaneId_);
        }
        const std::string nextFaceBody =
            target.isBodyFace() ? target.objectId : std::string();
        const std::string nextFaceId = target.isBodyFace() ? target.faceId : std::string();
        if (nextFaceBody != hoveredFace_.bodyId || nextFaceId != hoveredFace_.faceId) {
            hoveredFace_.bodyId = nextFaceBody;
            hoveredFace_.faceId = nextFaceId;
            viewer_->scene().setHoveredBodyFace(hoveredFace_.bodyId, hoveredFace_.faceId);
        }
    });
    viewer_->setSketchPointCallback([this](double u, double v) { onSketchPoint(u, v); });
    viewer_->setSketchMoveCallback([this](double u, double v) { onSketchMove(u, v); });
    viewer_->setSketchMissCallback([this]() {
        statusBar()->showMessage(tr("Cursor is not over the active sketch plane"), 3000);
    });
    viewer_->setSketchCancelCallback([this]() { cancelSketchTool(); });
}

void MainWindow::closeEvent(QCloseEvent* event) {
    if (maybeSave()) {
        event->accept();
    } else {
        event->ignore();
    }
}

// --- Selection ------------------------------------------------------------

void MainWindow::selectWorkPlane(const std::string& planeId) {
    if (selectionKind_ == SelectionKind::WorkPlane && selectedId_ == planeId) {
        return;
    }
    selectionKind_ = SelectionKind::WorkPlane;
    selectedId_ = planeId;
    selectedSketchId_.clear();
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
}

void MainWindow::selectBody(const std::string& objectId) {
    if (selectionKind_ == SelectionKind::Body && selectedId_ == objectId) {
        return;
    }
    selectionKind_ = SelectionKind::Body;
    selectedId_ = objectId;
    selectedSketchId_.clear();
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
}

void MainWindow::selectBodyFace(const std::string& bodyId, const std::string& faceId) {
    if (selectionKind_ == SelectionKind::BodyFace && selectedFace_.bodyId == bodyId &&
        selectedFace_.faceId == faceId) {
        return;
    }
    selectionKind_ = SelectionKind::BodyFace;
    selectedId_ = bodyId; // the owning body, so body-based actions keep working
    selectedSketchId_.clear();
    selectedFace_ = {bodyId, faceId};
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
    if (const kernel::FaceReference* face = findBodyFace(bodyId, faceId)) {
        qInfo("[FacePick] selected BodyFace body=%s face=%s sketchable=%s",
              bodyId.c_str(), faceId.c_str(), face->isSketchable ? "true" : "false");
        statusBar()->showMessage(
            face->isSketchable
                ? tr("Planar face selected — Sketch on Face / Work Plane from Face available")
                : tr("Face selected — not planar, sketches need a planar face"),
            5000);
    } else {
        qInfo("[FacePick] selected BodyFace body=%s face=%s but FaceReference was not found",
              bodyId.c_str(), faceId.c_str());
    }
}

void MainWindow::selectSketch(const std::string& sketchId) {
    if (selectionKind_ == SelectionKind::Sketch && selectedId_ == sketchId) {
        return;
    }
    selectionKind_ = SelectionKind::Sketch;
    selectedId_ = sketchId;
    selectedSketchId_.clear();
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
}

void MainWindow::selectEntity(const std::string& sketchId, const std::string& entityId) {
    if (selectionKind_ == SelectionKind::Entity && selectedId_ == entityId &&
        selectedSketchId_ == sketchId) {
        return;
    }
    selectionKind_ = SelectionKind::Entity;
    selectedId_ = entityId;
    selectedSketchId_ = sketchId;
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
    // A rectangle/circle (or a loop line) stands for its profile.
    selectProfileForEntity(sketchId, entityId);
}

void MainWindow::clearSelection() {
    if (selectionKind_ == SelectionKind::None) {
        return;
    }
    selectionKind_ = SelectionKind::None;
    selectedId_.clear();
    selectedSketchId_.clear();
    selectedFace_ = {};
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
}

void MainWindow::syncTreeSelection() {
    const QSignalBlocker blocker(projectTree_);
    switch (selectionKind_) {
    case SelectionKind::WorkPlane:
        projectTree_->setCurrentWorkPlane(QString::fromStdString(selectedId_));
        break;
    case SelectionKind::Body:
        projectTree_->setCurrentBody(QString::fromStdString(selectedId_));
        break;
    case SelectionKind::BodyFace:
        // Faces have no tree rows; highlight the owning body instead.
        projectTree_->setCurrentBody(QString::fromStdString(selectedFace_.bodyId));
        break;
    case SelectionKind::Sketch:
        projectTree_->setCurrentSketch(QString::fromStdString(selectedId_));
        break;
    case SelectionKind::Entity:
        projectTree_->setCurrentEntity(QString::fromStdString(selectedSketchId_),
                                       QString::fromStdString(selectedId_));
        break;
    case SelectionKind::None:
        projectTree_->clearTreeSelection();
        break;
    }
}

void MainWindow::syncViewportSelection() {
    if (!selection_) {
        return;
    }

    // Body highlight.
    if (selectionKind_ == SelectionKind::Body) {
        selection_->selectObject(selectedId_);
    } else {
        selection_->clearSelection();
    }
    viewer_->setSelectedWorkPlane(selectionKind_ == SelectionKind::WorkPlane
                                      ? selectedId_
                                      : std::string());

    // Body face highlight (0.8).
    if (selectionKind_ == SelectionKind::BodyFace) {
        viewer_->scene().setSelectedBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
    } else {
        viewer_->scene().setSelectedBodyFace(std::string(), std::string());
    }

    // Sketch entity highlight.
    if (!highlightedEntityId_.empty()) {
        viewer_->scene().setSketchEntityHighlighted(highlightedEntitySketch_,
                                                    highlightedEntityId_, false);
        highlightedEntitySketch_.clear();
        highlightedEntityId_.clear();
    }
    if (selectionKind_ == SelectionKind::Entity) {
        viewer_->scene().setSketchEntityHighlighted(selectedSketchId_, selectedId_, true);
        highlightedEntitySketch_ = selectedSketchId_;
        highlightedEntityId_ = selectedId_;
    }

    sketchToolBar_->setCreateSketchEnabled(selectionKind_ == SelectionKind::WorkPlane);
    sketchToolBar_->setEnterSketchEnabled(selectionKind_ == SelectionKind::Sketch &&
                                          !activeSketchId_);
    updateExtrudeActionEnabled();
    updateFaceActionsEnabled();
    updateModeStatusLabel();
}

void MainWindow::refreshPropertyPanel() {
    switch (selectionKind_) {
    case SelectionKind::WorkPlane: {
        const std::optional<WorkPlane> plane = workPlaneById(selectedId_);
        if (plane) {
            propertyPanel_->showWorkPlane(*plane);
            return;
        }
        break;
    }
    case SelectionKind::Body: {
        const Result<Object> object = document_.objectById(selectedId_);
        if (object.isOk()) {
            propertyPanel_->showObject(object.value());
            return;
        }
        break;
    }
    case SelectionKind::Sketch: {
        const Result<Sketch> sketch = document_.sketchById(selectedId_);
        if (sketch.isOk()) {
            propertyPanel_->showSketch(sketch.value());
            return;
        }
        break;
    }
    case SelectionKind::Entity: {
        const Result<Sketch> sketch = document_.sketchById(selectedSketchId_);
        if (sketch.isOk()) {
            if (const SketchEntity* entity = findSketchEntity(sketch.value(), selectedId_)) {
                propertyPanel_->showSketchEntity(sketch.value(), *entity);
                return;
            }
        }
        break;
    }
    case SelectionKind::BodyFace: {
        const kernel::FaceReference* face =
            findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
        const Result<Object> body = document_.objectById(selectedFace_.bodyId);
        if (face && body.isOk()) {
            propertyPanel_->showBodyFace(QString::fromStdString(body.value().name), *face);
            return;
        }
        break;
    }
    case SelectionKind::None:
        break;
    }
    propertyPanel_->clearObject();
}

std::optional<WorkPlane> MainWindow::workPlaneById(const std::string& planeId) const {
    if (planeId == canonicalWorkPlaneId(SketchPlane::XY)) {
        return makeCanonicalWorkPlane(SketchPlane::XY, 8.0);
    }
    if (planeId == canonicalWorkPlaneId(SketchPlane::XZ)) {
        return makeCanonicalWorkPlane(SketchPlane::XZ, 8.0);
    }
    if (planeId == canonicalWorkPlaneId(SketchPlane::YZ)) {
        return makeCanonicalWorkPlane(SketchPlane::YZ, 8.0);
    }
    const Result<Object> object = document_.objectById(planeId);
    if (object.isOk() && object.value().type == ObjectType::ReferencePlane) {
        return workPlaneFromReferencePlaneObject(object.value());
    }
    // Document work planes (0.8: planes created from body faces).
    const Result<WorkPlane> documentPlane = document_.workPlaneById(planeId);
    if (documentPlane.isOk()) {
        return documentPlane.value();
    }
    return std::nullopt;
}

WorkPlane MainWindow::workPlaneForSketch(const Sketch& sketch) const {
    if (sketch.reference.type == SketchReferenceType::WorkPlane) {
        const std::optional<WorkPlane> plane = workPlaneById(sketch.reference.sourceId);
        if (plane) {
            return *plane;
        }
    }
    if (sketch.reference.type == SketchReferenceType::CanonicalPlane) {
        if (const std::optional<WorkPlane> plane = workPlaneById(sketch.reference.sourceId)) {
            return *plane;
        }
        return makeCanonicalWorkPlane(sketch.plane, 8.0);
    }

    WorkPlane plane;
    plane.id = sketch.reference.sourceId;
    plane.name = sketch.reference.displayName.empty() ? sketch.name
                                                      : sketch.reference.displayName;
    plane.kind = sketch.reference.type == SketchReferenceType::BodyFace
                     ? WorkPlaneKind::FacePlane
                     : WorkPlaneKind::ObjectPlane;
    // Always the recorded reference frame: the committed entities live in
    // its u/v coordinates, so grid/camera and geometry can never disagree.
    plane.origin = sketch.reference.origin;
    plane.uAxis = sketch.reference.uAxis;
    plane.vAxis = sketch.reference.vAxis;
    plane.normal = sketch.reference.normal;
    plane.width = 8.0;
    plane.height = 8.0;
    if (sketch.reference.type == SketchReferenceType::BodyFace) {
        plane.sourceBodyId = sketch.reference.sourceBodyId;
        plane.sourceFaceId = sketch.reference.sourceFaceId;
        // Size the helper from the live face when it still resolves; a
        // missing face keeps a compact default instead of the 8 m helper.
        plane.width = 4.0;
        plane.height = 4.0;
        if (const kernel::FaceReference* face = findBodyFace(
                sketch.reference.sourceBodyId, sketch.reference.sourceFaceId)) {
            plane.width = std::max(face->width * 1.6, 1.0);
            plane.height = std::max(face->height * 1.6, 1.0);
        }
    }
    return plane;
}

void MainWindow::addCanonicalWorkPlanesToTree() {
    const WorkPlane planes[] = {
        makeCanonicalWorkPlane(SketchPlane::XY, 8.0),
        makeCanonicalWorkPlane(SketchPlane::XZ, 8.0),
        makeCanonicalWorkPlane(SketchPlane::YZ, 8.0),
    };
    const QSignalBlocker blocker(projectTree_);
    for (const WorkPlane& plane : planes) {
        projectTree_->addWorkPlaneItem(QString::fromStdString(plane.id),
                                       QString::fromStdString(plane.name),
                                       workPlaneTypeText(plane));
    }
}

// --- Body creation/removal ----------------------------------------------

void MainWindow::addPrimitiveObject(PrimitiveKind kind) {
    if (!viewer_) {
        return;
    }

    Object object;
    object.id = "object-" + std::to_string(nextObjectNumber_++);
    object.type = ObjectType::Body;
    object.primitive.kind = kind;

    switch (kind) {
    case PrimitiveKind::Box:
        object.name = "Box " + std::to_string(++boxCount_);
        object.primitive.width = 1.0;
        object.primitive.depth = 1.0;
        object.primitive.height = 1.0;
        object.transform.position = nextSpawnPosition(object.primitive.height * 0.5);
        break;
    case PrimitiveKind::Cylinder:
        object.name = "Cylinder " + std::to_string(++cylinderCount_);
        object.primitive.radius = 0.5;
        object.primitive.height = 1.2;
        object.transform.position = nextSpawnPosition(object.primitive.height * 0.5);
        break;
    case PrimitiveKind::Sphere:
        object.name = "Sphere " + std::to_string(++sphereCount_);
        object.primitive.radius = 0.6;
        object.transform.position = nextSpawnPosition(object.primitive.radius);
        break;
    case PrimitiveKind::Cone:
    case PrimitiveKind::None:
        return;
    }

    registerObject(object);
}

void MainWindow::addReferencePlane() {
    if (!viewer_) {
        return;
    }

    Object object;
    object.id = "object-" + std::to_string(nextObjectNumber_++);
    object.type = ObjectType::ReferencePlane;
    object.name = "Plane " + std::to_string(++planeCount_);
    object.primitive.width = 2.0;
    object.primitive.height = 2.0;
    object.transform.position = nextSpawnPosition(0.0);

    registerObject(object);
}

void MainWindow::registerObject(const Object& object) {
    document_.addObject(object);
    buildObjectVisual(object);
    {
        const QSignalBlocker blocker(projectTree_);
        if (object.type == ObjectType::ReferencePlane) {
            const WorkPlane plane = workPlaneFromReferencePlaneObject(object);
            projectTree_->addWorkPlaneItem(QString::fromStdString(plane.id),
                                           QString::fromStdString(plane.name),
                                           workPlaneTypeText(plane));
        } else {
            projectTree_->addBodyItem(QString::fromStdString(object.id),
                                      QString::fromStdString(object.name), treeTypeText(object));
        }
    }
    if (object.type == ObjectType::ReferencePlane) {
        selectWorkPlane(object.id);
    } else {
        selectBody(object.id);
    }
    markDirty();
}

void MainWindow::buildObjectVisual(const Object& object) {
    if (!viewer_) {
        return;
    }

    if (evaluator_) {
        const cadnext::Result<kernel::EvaluatedGeometry> evaluated =
            evaluator_->evaluateObject(object);
        if (evaluated.isOk() && evaluated.value().isValid &&
            !evaluated.value().previewMesh.isEmpty()) {
            // Remember the BRep handle: Cut Extrude needs the target's
            // current shape, not just its display mesh.
            bodyShapes_[object.id] = evaluated.value().shape;
            bodyMeshes_[object.id] = evaluated.value().previewMesh;
            viewer_->scene().addOrUpdateObjectMesh(object, evaluated.value().previewMesh);
            refreshBodyFaces(object.id);
            return;
        }
#ifdef CADNEXT_WITH_OCCT
        // With OCCT compiled in, a body failing evaluation is unexpected —
        // report it; reference planes are viewer-only by design.
        if (object.type == ObjectType::Body) {
            const QString reason = evaluated.isOk()
                                       ? QString::fromStdString(evaluated.value().message)
                                       : QString::fromStdString(evaluated.error().message);
            qWarning("CADNext: OCCT evaluation failed for %s: %s", object.name.c_str(),
                     reason.toUtf8().constData());
            statusBar()->showMessage(
                tr("OCCT evaluation failed for %1 — using procedural fallback (%2)")
                    .arg(QString::fromStdString(object.name), reason),
                8000);
        }
#endif
    }

    // Procedural fallback path (no BRep backend or evaluation failed).
    bodyShapes_.erase(object.id);
    bodyMeshes_.erase(object.id);
    bodyFaces_.erase(object.id);
    viewer_->scene().removeBodyFaces(object.id);
    if (viewer_->scene().hasObjectNode(object.id)) {
        viewer_->scene().updateObjectPrimitive(object);
    } else {
        viewer_->scene().addObjectNode(object);
    }
}

Vector3 MainWindow::nextSpawnPosition(double groundOffset) const {
    // Spread new objects along X so each addition stays visible.
    const double x = 1.8 * static_cast<double>(document_.objects().size());
    return Vector3{x, 0.0, groundOffset};
}

void MainWindow::deleteSelected() {
    switch (selectionKind_) {
    case SelectionKind::WorkPlane: {
        const std::optional<WorkPlane> plane = workPlaneById(selectedId_);
        if (!plane || (plane->kind != WorkPlaneKind::ObjectPlane &&
                       plane->kind != WorkPlaneKind::FacePlane)) {
            statusBar()->showMessage(tr("Canonical work planes cannot be deleted"), 3000);
            break;
        }
        const std::string planeId = selectedId_;
        clearSelection();
        if (plane->kind == WorkPlaneKind::FacePlane) {
            // Document work plane (created from a face): not an object.
            document_.removeWorkPlane(planeId);
            viewer_->scene().removeDocumentWorkPlane(planeId);
        } else {
        document_.removeObject(planeId);
        bodyShapes_.erase(planeId);
        bodyMeshes_.erase(planeId);
        viewer_->scene().removeObjectNode(planeId);
        }
        {
            const QSignalBlocker blocker(projectTree_);
            projectTree_->removeWorkPlaneItem(QString::fromStdString(planeId));
        }
        markDirty();
        break;
    }
    case SelectionKind::Body: {
        const std::string objectId = selectedId_;
        clearSelection();
        document_.removeObject(objectId);
        bodyShapes_.erase(objectId);
        bodyMeshes_.erase(objectId);
        bodyFaces_.erase(objectId);
        viewer_->scene().removeObjectNode(objectId);
        {
            const QSignalBlocker blocker(projectTree_);
            projectTree_->removeBodyItem(QString::fromStdString(objectId));
        }
        markDirty();
        break;
    }
    case SelectionKind::BodyFace:
        statusBar()->showMessage(
            tr("Faces cannot be deleted — delete the body instead"), 3000);
        break;
    case SelectionKind::Sketch: {
        const std::string sketchId = selectedId_;
        if (activeSketchId_ == sketchId) {
            exitSketchMode();
        }
        clearSelection();
        document_.removeSketch(sketchId);
        viewer_->scene().removeSketchNode(sketchId);
        {
            const QSignalBlocker blocker(projectTree_);
            projectTree_->removeSketchItem(QString::fromStdString(sketchId));
        }
        markDirty();
        break;
    }
    case SelectionKind::Entity: {
        const std::string sketchId = selectedSketchId_;
        const std::string entityId = selectedId_;
        clearSelection();
        if (Sketch* sketch = document_.mutableSketchById(sketchId)) {
            removeSketchEntity(*sketch, entityId);
            viewer_->scene().addOrUpdateSketchNode(*sketch);
        }
        {
            const QSignalBlocker blocker(projectTree_);
            projectTree_->removeEntityItem(QString::fromStdString(sketchId),
                                           QString::fromStdString(entityId));
        }
        refreshSketchProfiles();
        selectSketch(sketchId);
        markDirty();
        break;
    }
    case SelectionKind::None:
        break;
    }
}

// --- Sketch workflow ----------------------------------------------------

void MainWindow::newSketch(SketchPlane plane) {
    createSketchOnPlane(makeCanonicalWorkPlane(plane, 8.0));
}

void MainWindow::createSketchFromSelectedPlane() {
    if (selectionKind_ != SelectionKind::WorkPlane) {
        return;
    }
    const std::optional<WorkPlane> plane = workPlaneById(selectedId_);
    if (plane) {
        createSketchOnPlane(*plane);
    }
}

void MainWindow::createSketchOnPlane(const WorkPlane& plane) {
    enterSketchOnReference(sketchReferenceFromWorkPlane(plane));
}

// The single sketch-creation entry point: canonical planes, reference
// planes, document work planes and body faces all create and enter their
// sketches here, with the reference as the only geometric input.
void MainWindow::enterSketchOnReference(const SketchReference& reference) {
    if (!viewer_) {
        return;
    }

    Sketch sketch;
    sketch.id = "sketch-" + std::to_string(nextSketchNumber_);
    sketch.plane = SketchPlane::XY;
    std::string label = reference.displayName;
    if (reference.type == SketchReferenceType::CanonicalPlane) {
        if (reference.sourceId == canonicalWorkPlaneId(SketchPlane::XZ)) {
            sketch.plane = SketchPlane::XZ;
        } else if (reference.sourceId == canonicalWorkPlaneId(SketchPlane::YZ)) {
            sketch.plane = SketchPlane::YZ;
        }
        label = sketchPlaneName(sketch.plane);
    } else if (label.empty()) {
        const std::optional<WorkPlane> plane = workPlaneById(reference.sourceId);
        label = plane ? plane->name : "Plane";
    }
    sketch.name = "Sketch " + label + " " + std::to_string(nextSketchNumber_);
    ++nextSketchNumber_;
    sketch.reference = reference;

    document_.addSketch(sketch);
    viewer_->scene().addOrUpdateSketchNode(sketch);
    {
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addSketchItem(QString::fromStdString(sketch.id),
                                    QString::fromStdString(sketch.name));
    }
    markDirty();
    selectSketch(sketch.id);
    enterSketchMode(sketch.id);
}

void MainWindow::enterSketchMode(const std::string& sketchId) {
    const Result<Sketch> sketch = document_.sketchById(sketchId);
    if (!sketch.isOk() || !viewer_) {
        return;
    }
    activeSketchId_ = sketchId;
    sketchInput_.resetPending();
    sketchInput_.activeTool = SketchTool::Select;
    activeSketchPlane_ = workPlaneForSketch(sketch.value());
    // Input/preview must use the same reference the committed entities are
    // rendered with (the recorded one when present).
    activeSketchReference_ = sketch.value().reference.sourceId.empty()
                                 ? canonicalSketchReference(sketch.value().plane)
                                 : sketch.value().reference;

    viewer_->enterSketch2DView(*activeSketchPlane_, sketchInput_.options.gridStep,
                               sketchInput_.options.showSketchGrid);
    viewer_->setSketchInputMode(false, activeSketchReference_);
    // Face overlays must never steal sketch picks; the dimmed body stays
    // visible as orientation context.
    viewer_->scene().setBodyFacesVisible(false);
    refreshSketchProfiles();
    sketchToolBar_->setSketchModeActive(true);
    sketchToolBar_->checkSelectTool();
    sketchToolBar_->setEnterSketchEnabled(false);
    updateModeStatusLabel();
    updatePlaneBadge();
    statusBar()->showMessage(
        tr("Sketch2D (%1): pick Line / Rectangle / Circle and click on the plane; "
           "Esc cancels, Exit Sketch finishes")
            .arg(QString::fromStdString(sketch.value().name)));
}

void MainWindow::exitSketchMode() {
    if (!activeSketchId_) {
        return;
    }
    activeSketchId_.reset();
    activeSketchPlane_.reset();
    sketchInput_.resetPending();
    sketchInput_.activeTool = SketchTool::Select;
    if (viewer_) {
        viewer_->setSketchInputMode(false, SketchReference{});
        // Also hides the sketch plane and clears cursor/anchor/preview.
        viewer_->exitSketch2DView();
        viewer_->scene().clearSketchProfiles();
        viewer_->scene().setSelectedProfile(std::string());
        viewer_->scene().setBodyFacesVisible(true);
    }
    activeProfiles_.clear();
    selectedProfileId_.clear();
    updateExtrudeActionEnabled();
    sketchToolBar_->setSketchModeActive(false);
    sketchToolBar_->setEnterSketchEnabled(selectionKind_ == SelectionKind::Sketch);
    updateModeStatusLabel();
    updatePlaneBadge();
    statusBar()->showMessage(tr("Free3D: select body, work plane or sketch"));
}

void MainWindow::setSketchTool(SketchTool tool) {
    sketchInput_.activeTool = tool;
    sketchInput_.resetPending();
    if (!viewer_) {
        return;
    }
    clearPendingSketchVisuals();
    if (tool == SketchTool::Select) {
        viewer_->scene().hideSketchCursor();
    }
    if (!activeSketchId_) {
        return;
    }
    viewer_->setSketchInputMode(tool != SketchTool::Select, activeSketchReference_);
    if (tool != SketchTool::Select) {
        statusBar()->showMessage(sketchToolPrompt());
    }
}

void MainWindow::cancelSketchTool() {
    if (sketchInput_.phase == SketchInputPhase::WaitingSecondPoint) {
        // First Esc cancels only the pending operation; the tool stays
        // armed. A second Esc then drops back to Select.
        sketchInput_.resetPending();
        clearPendingSketchVisuals();
        statusBar()->showMessage(tr("Cancelled — %1").arg(sketchToolPrompt()));
        return;
    }
    setSketchTool(SketchTool::Select);
    sketchToolBar_->checkSelectTool();
    statusBar()->showMessage(tr("Sketch tool cancelled"), 3000);
}

void MainWindow::onSketchPoint(double u, double v) {
    if (!activeSketchId_ || sketchInput_.activeTool == SketchTool::Select) {
        return;
    }
    if (!std::isfinite(u) || !std::isfinite(v)) {
        return;
    }

    const SketchPoint2D point = applySketchSnap({u, v}, sketchInput_.options);

    if (sketchInput_.phase == SketchInputPhase::Idle) {
        sketchInput_.firstPoint = point;
        sketchInput_.currentPoint = point;
        sketchInput_.phase = SketchInputPhase::WaitingSecondPoint;
        if (viewer_) {
            viewer_->scene().showSketchAnchor(point, activeSketchReference_);
            updateSketchPreview(point);
        }
        switch (sketchInput_.activeTool) {
        case SketchTool::Line:
            statusBar()->showMessage(
                tr("Line: first point set — click second point (Esc cancels)"));
            break;
        case SketchTool::Rectangle:
            statusBar()->showMessage(
                tr("Rectangle: first corner set — click opposite corner (Esc cancels)"));
            break;
        case SketchTool::Circle:
            statusBar()->showMessage(
                tr("Circle: center set — click radius point (Esc cancels)"));
            break;
        case SketchTool::Select:
            break;
        }
        return;
    }

    const SketchPoint2D first = *sketchInput_.firstPoint;

    SketchEntity entity;
    entity.id = "entity-" + std::to_string(nextEntityNumber_++);

    switch (sketchInput_.activeTool) {
    case SketchTool::Line: {
        if (std::fabs(point.u - first.u) < kMinSketchExtent &&
            std::fabs(point.v - first.v) < kMinSketchExtent) {
            statusBar()->showMessage(tr("Zero-length line ignored — click a different point"),
                                     3000);
            return;
        }
        entity.type = SketchEntityType::Line;
        entity.name = "Line " + std::to_string(++lineCount_);
        entity.line.start = first;
        entity.line.end = point;
        break;
    }
    case SketchTool::Rectangle: {
        const double width = std::fabs(point.u - first.u);
        const double height = std::fabs(point.v - first.v);
        if (width < kMinSketchExtent || height < kMinSketchExtent) {
            statusBar()->showMessage(tr("Degenerate rectangle ignored — click a different corner"),
                                     3000);
            return;
        }
        entity.type = SketchEntityType::Rectangle;
        entity.name = "Rectangle " + std::to_string(++rectangleCount_);
        entity.rectangle.origin = {std::min(first.u, point.u), std::min(first.v, point.v)};
        entity.rectangle.width = width;
        entity.rectangle.height = height;
        break;
    }
    case SketchTool::Circle: {
        const double radius = std::hypot(point.u - first.u, point.v - first.v);
        if (radius < kMinSketchExtent) {
            statusBar()->showMessage(tr("Zero-radius circle ignored — click a different point"),
                                     3000);
            return;
        }
        entity.type = SketchEntityType::Circle;
        entity.name = "Circle " + std::to_string(++circleCount_);
        entity.circle.center = first;
        entity.circle.radius = radius;
        break;
    }
    case SketchTool::Select:
        return;
    }

    // Plane-integrity check: both committed points, mapped through the
    // active reference, must land on the active plane. This only fires
    // when the reference axes are inconsistent with its normal.
    if (!isWorldPointOnSketchPlane(sketchPointToWorld(first, activeSketchReference_),
                                   activeSketchReference_) ||
        !isWorldPointOnSketchPlane(sketchPointToWorld(point, activeSketchReference_),
                                   activeSketchReference_)) {
        qWarning("CADNext: sketch reference axes are inconsistent with its normal; "
                 "entity %s may render off-plane", entity.id.c_str());
    }

    sketchInput_.resetPending();
    clearPendingSketchVisuals();
    addSketchEntity(std::move(entity));
    // The tool stays armed for the next entity (CAD workflow).
    statusBar()->showMessage(sketchToolPrompt());
}

void MainWindow::onSketchMove(double u, double v) {
    if (!viewer_ || !activeSketchId_ || sketchInput_.activeTool == SketchTool::Select) {
        return;
    }
    if (!std::isfinite(u) || !std::isfinite(v)) {
        return;
    }

    const SketchPoint2D snapped = applySketchSnap({u, v}, sketchInput_.options);
    sketchInput_.currentPoint = snapped;
    if (sketchInput_.options.showSketchCursor) {
        viewer_->scene().showSketchCursor(snapped, activeSketchReference_);
    }
    if (sketchInput_.phase == SketchInputPhase::WaitingSecondPoint) {
        updateSketchPreview(snapped);
    }
}

// --- Sketch input UX helpers ----------------------------------------------

void MainWindow::updateSketchPreview(const SketchPoint2D& current) {
    if (!viewer_ || !sketchInput_.firstPoint || !sketchInput_.options.showLivePreview) {
        return;
    }
    const SketchPoint2D first = *sketchInput_.firstPoint;
    switch (sketchInput_.activeTool) {
    case SketchTool::Line:
        viewer_->scene().updateLinePreview(first, current, activeSketchReference_);
        break;
    case SketchTool::Rectangle:
        viewer_->scene().updateRectanglePreview(first, current, activeSketchReference_);
        break;
    case SketchTool::Circle:
        viewer_->scene().updateCirclePreview(first, current, activeSketchReference_);
        break;
    case SketchTool::Select:
        break;
    }
}

void MainWindow::clearPendingSketchVisuals() {
    if (!viewer_) {
        return;
    }
    viewer_->scene().clearSketchPreview();
    viewer_->scene().hideSketchAnchor();
}

void MainWindow::onSnapToggled(bool enabled) {
    sketchInput_.options.snapToGrid = enabled;
    updateModeStatusLabel();
    statusBar()->showMessage(enabled ? tr("Snap to grid: ON") : tr("Snap to grid: OFF"), 3000);
}

void MainWindow::onShowGridToggled(bool visible) {
    sketchInput_.options.showSketchGrid = visible;
    refreshSketchPlaneVisual();
    statusBar()->showMessage(visible ? tr("Sketch grid: shown") : tr("Sketch grid: hidden"),
                             3000);
}

void MainWindow::onGridStepChanged(double step) {
    if (!std::isfinite(step) || step <= 0.0) {
        return; // the spinbox range already prevents this
    }
    sketchInput_.options.gridStep = std::max(step, kMinSketchGridStep);
    refreshSketchPlaneVisual();
    updateModeStatusLabel();
}

void MainWindow::refreshSketchPlaneVisual() {
    if (!viewer_ || !activeSketchId_ || !activeSketchPlane_) {
        return;
    }
    // Rebuilding the plane helper clears the transient visuals, so restore
    // the ones that represent live input state.
    viewer_->scene().showSketchPlane(*activeSketchPlane_, sketchInput_.options.gridStep,
                                     sketchInput_.options.showSketchGrid);
    if (sketchInput_.firstPoint) {
        viewer_->scene().showSketchAnchor(*sketchInput_.firstPoint, activeSketchReference_);
    }
    if (sketchInput_.currentPoint && sketchInput_.activeTool != SketchTool::Select &&
        sketchInput_.options.showSketchCursor) {
        viewer_->scene().showSketchCursor(*sketchInput_.currentPoint, activeSketchReference_);
        if (sketchInput_.phase == SketchInputPhase::WaitingSecondPoint) {
            updateSketchPreview(*sketchInput_.currentPoint);
        }
    }
}

void MainWindow::updateModeStatusLabel() {
    if (!modeStatusLabel_) {
        return;
    }
    if (activeSketchId_) {
        const Result<Sketch> sketch = document_.sketchById(*activeSketchId_);
        const QString sketchName = sketch.isOk() ? QString::fromStdString(sketch.value().name)
                                                 : tr("Sketch");
        const QString plane = activeSketchPlane_
                                  ? QString::fromStdString(activeSketchPlane_->name)
                                  : tr("plane");
        modeStatusLabel_->setText(
            sketchInput_.options.snapToGrid
                ? tr("Sketch2D: %1, Plane %2, Snap ON, Grid %3")
                      .arg(sketchName, plane)
                      .arg(sketchInput_.options.gridStep, 0, 'f', 3)
                : tr("Sketch2D: %1, Plane %2, Snap OFF").arg(sketchName, plane));
        return;
    }
    if (selectionKind_ == SelectionKind::WorkPlane) {
        if (const std::optional<WorkPlane> plane = workPlaneById(selectedId_)) {
            modeStatusLabel_->setText(
                tr("Selected plane: %1 — Create Sketch or Normal to Plane")
                    .arg(QString::fromStdString(plane->name)));
            return;
        }
    }
    if (selectionKind_ == SelectionKind::BodyFace) {
        const kernel::FaceReference* face =
            findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
        modeStatusLabel_->setText(
            face && face->isSketchable
                ? tr("Selected face: planar — Sketch on Face or Work Plane from Face")
                : tr("Selected face: not planar"));
        return;
    }
    modeStatusLabel_->setText(tr("Free3D: select body, work plane or sketch"));
}

QString MainWindow::sketchToolPrompt() const {
    switch (sketchInput_.activeTool) {
    case SketchTool::Line:
        return tr("Line: click first point");
    case SketchTool::Rectangle:
        return tr("Rectangle: click first corner");
    case SketchTool::Circle:
        return tr("Circle: click center");
    case SketchTool::Select:
        break;
    }
    return tr("Select: click an entity on the plane");
}

// --- Work plane view helpers ------------------------------------------------

void MainWindow::normalToSelectedPlane() {
    if (!viewer_ || selectionKind_ != SelectionKind::WorkPlane) {
        return;
    }
    const std::optional<WorkPlane> plane = workPlaneById(selectedId_);
    if (plane) {
        viewer_->setViewNormalToPlane(*plane);
    }
}

void MainWindow::fitSketchView() {
    if (viewer_) {
        viewer_->fitView();
    }
}

void MainWindow::showPlaneActionPalette(bool contextClick) {
    // The palette only appears on context (right/middle) clicks; a plain
    // left click on a plane just selects it. A plain QMenu for now — the
    // entries share their handlers with the toolbar paths, so it can be
    // swapped for a floating action palette later.
    if (!contextClick || selectionKind_ != SelectionKind::WorkPlane || activeSketchId_) {
        return;
    }
    QMenu menu(this);
    QAction* createSketch = menu.addAction(tr("Create Sketch"));
    QAction* normalView = menu.addAction(tr("Normal to Plane"));
    QAction* fitPlane = menu.addAction(tr("Fit Plane"));
    const bool othersHidden = viewer_->otherWorkPlanesHidden();
    QAction* hideOthers = menu.addAction(othersHidden ? tr("Show Other Planes")
                                                      : tr("Hide Other Planes"));
    QAction* chosen = menu.exec(QCursor::pos());
    if (chosen == createSketch) {
        createSketchFromSelectedPlane();
    } else if (chosen == normalView) {
        normalToSelectedPlane();
    } else if (chosen == fitPlane) {
        viewer_->fitWorkPlane(selectedId_);
    } else if (chosen == hideOthers) {
        viewer_->setOtherWorkPlanesHidden(!othersHidden);
        statusBar()->showMessage(othersHidden ? tr("All work planes shown")
                                              : tr("Other work planes hidden"),
                                 3000);
    }
}

void MainWindow::addSketchEntity(SketchEntity entity) {
    if (!activeSketchId_) {
        return;
    }
    const std::string sketchId = *activeSketchId_;
    const QString entityId = QString::fromStdString(entity.id);
    const QString entityName = QString::fromStdString(entity.name);
    const QString entityType = QString::fromUtf8(sketchEntityTypeName(entity.type));

    commandStack_.push(std::make_unique<AddSketchEntityCommand>(sketchId, std::move(entity)),
                       document_);

    const Sketch* sketch = document_.mutableSketchById(sketchId);
    if (sketch) {
        viewer_->scene().addOrUpdateSketchNode(*sketch);
    }
    {
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addEntityItem(QString::fromStdString(sketchId), entityId, entityName,
                                    entityType);
    }
    refreshSketchProfiles();
    selectEntity(sketchId, entityId.toStdString());
    markDirty();
    updateUndoRedoActions();
}

// --- Extrude workflow ---------------------------------------------------------

void MainWindow::refreshSketchProfiles() {
    if (!viewer_) {
        return;
    }
    if (!activeSketchId_) {
        activeProfiles_.clear();
        viewer_->scene().clearSketchProfiles();
        updateExtrudeActionEnabled();
        return;
    }
    const Result<Sketch> sketch = document_.sketchById(*activeSketchId_);
    if (!sketch.isOk()) {
        return;
    }
    activeProfiles_ = SketchProfileDetector().detect(sketch.value());
    if (!selectedProfileId_.empty() && !profileById(activeProfiles_, selectedProfileId_)) {
        selectedProfileId_.clear();
        viewer_->scene().setSelectedProfile(std::string());
    }
    viewer_->scene().showSketchProfiles(sketch.value(), activeProfiles_);
    updateExtrudeActionEnabled();
}

void MainWindow::selectProfile(const std::string& profileId) {
    if (!viewer_) {
        return;
    }
    selectedProfileId_ = profileId;
    viewer_->scene().setSelectedProfile(profileId);
    updateExtrudeActionEnabled();
    if (const SketchProfile* profile = profileById(activeProfiles_, profileId)) {
        statusBar()->showMessage(tr("Profile selected: %1 (area %2) — Extrude is available")
                                     .arg(profileKindText(profile->kind))
                                     .arg(profile->area, 0, 'f', 3));
    }
}

void MainWindow::selectProfileForEntity(const std::string& sketchId,
                                        const std::string& entityId) {
    if (!viewer_ || !activeSketchId_ || *activeSketchId_ != sketchId) {
        return;
    }
    if (const SketchProfile* profile = profileForEntityId(activeProfiles_, entityId)) {
        selectProfile(profile->id);
    } else {
        selectedProfileId_.clear();
        viewer_->scene().setSelectedProfile(std::string());
    }
}

void MainWindow::updateExtrudeActionEnabled() {
    bool hasValidProfile = false;
    if (const std::optional<Sketch> sketch = sketchForExtrude()) {
        const std::vector<SketchProfile> profiles = SketchProfileDetector().detect(*sketch);
        for (const SketchProfile& profile : profiles) {
            if (profile.isValid) {
                hasValidProfile = true;
                break;
            }
        }
    }
    toolBar_->extrudeAction()->setEnabled(hasValidProfile);

    bool hasTargetBody = false;
    for (const Object& object : document_.objects()) {
        if (object.type == ObjectType::Body && bodyShapes_.find(object.id) != bodyShapes_.end()) {
            hasTargetBody = true;
            break;
        }
    }
    toolBar_->cutExtrudeAction()->setEnabled(kOcctBackendAvailable && hasValidProfile &&
                                             hasTargetBody);
}

std::optional<Sketch> MainWindow::sketchForExtrude() const {
    // Priority: the sketch being edited, then the selected sketch, then
    // the sketch owning the selected entity.
    std::string sketchId;
    if (activeSketchId_) {
        sketchId = *activeSketchId_;
    } else if (selectionKind_ == SelectionKind::Sketch) {
        sketchId = selectedId_;
    } else if (selectionKind_ == SelectionKind::Entity) {
        sketchId = selectedSketchId_;
    }
    if (sketchId.empty()) {
        return std::nullopt;
    }
    const Result<Sketch> sketch = document_.sketchById(sketchId);
    if (!sketch.isOk()) {
        return std::nullopt;
    }
    return sketch.value();
}

void MainWindow::openExtrudeDialog() {
    if (!viewer_) {
        return;
    }
    const std::optional<Sketch> sketch = sketchForExtrude();
    if (!sketch) {
        statusBar()->showMessage(
            tr("Select a sketch with a closed profile to extrude"), 5000);
        return;
    }

    dialogProfiles_.clear();
    for (SketchProfile& profile : SketchProfileDetector().detect(*sketch)) {
        if (profile.isValid) {
            dialogProfiles_.push_back(std::move(profile));
        }
    }
    if (dialogProfiles_.empty()) {
        statusBar()->showMessage(
            selectionKind_ == SelectionKind::Entity
                ? tr("Selected sketch entity is not a closed profile.")
                : tr("Sketch has no closed profile to extrude"),
            5000);
        return;
    }
    extrudeSketchId_ = sketch->id;

    // Leave Sketch2D first: the prism preview only reads in the free 3D
    // view (in the flat normal view it projects to the profile itself).
    if (activeSketchId_) {
        exitSketchMode();
    }

    if (!extrudeDialog_) {
        extrudeDialog_ = new ExtrudeDialog(this);
        connect(extrudeDialog_, &ExtrudeDialog::parametersChanged, this,
                [this]() { onExtrudeParametersChanged(); });
        connect(extrudeDialog_, &ExtrudeDialog::applyRequested, this,
                [this]() { applyExtrude(); });
        connect(extrudeDialog_, &ExtrudeDialog::cancelRequested, this,
                [this]() { cancelExtrude(); });
    }

    QList<ExtrudeProfileItem> items;
    QString selected;
    for (const SketchProfile& profile : dialogProfiles_) {
        QString label = profileKindText(profile.kind);
        if (!profile.sourceEntityId.empty()) {
            if (const SketchEntity* entity =
                    findSketchEntity(*sketch, profile.sourceEntityId)) {
                label = QString::fromStdString(entity->name);
            }
        } else if (profile.kind == SketchProfileKind::Polygon) {
            label = tr("Polygon Profile (%1 lines)")
                        .arg(profile.sourceEntityIds.size());
        }
        label += tr(" — area %1").arg(profile.area, 0, 'f', 3);
        items.append({QString::fromStdString(profile.id), label});
        if (profile.id == selectedProfileId_) {
            selected = QString::fromStdString(profile.id);
        }
    }
    extrudeDialog_->setProfiles(items, selected);
    extrudeDialog_->show();
    extrudeDialog_->raise();
    extrudeDialog_->activateWindow();
    onExtrudeParametersChanged();
    statusBar()->showMessage(
        tr("Extrude: pick profile, distance and direction — Apply creates a new body"));
}

void MainWindow::onExtrudeParametersChanged() {
    if (!viewer_ || !extrudeDialog_ || !extrudeDialog_->isVisible()) {
        return;
    }
    if (!extrudeDialog_->previewEnabled()) {
        viewer_->scene().hideExtrudePreview();
        return;
    }
    const std::string profileId = extrudeDialog_->selectedProfileId().toStdString();
    const SketchProfile* profile = profileById(dialogProfiles_, profileId);
    const Result<Sketch> sketch = document_.sketchById(extrudeSketchId_);
    if (!profile || !sketch.isOk()) {
        viewer_->scene().hideExtrudePreview();
        return;
    }

    ExtrudeParameters parameters;
    parameters.sketchId = extrudeSketchId_;
    parameters.profileId = profileId;
    parameters.direction = extrudeDialog_->direction();
    parameters.distance = extrudeDialog_->distance();

    kernel::TriangleMesh mesh;
    if (buildExtrudeMesh(sketch.value(), *profile, parameters, mesh, nullptr)) {
        viewer_->scene().showExtrudePreview(mesh);
    } else {
        viewer_->scene().hideExtrudePreview();
    }
}

void MainWindow::applyExtrude() {
    if (!viewer_ || !extrudeDialog_) {
        return;
    }
    const std::string profileId = extrudeDialog_->selectedProfileId().toStdString();
    const SketchProfile* profile = profileById(dialogProfiles_, profileId);
    const Result<Sketch> sketch = document_.sketchById(extrudeSketchId_);
    if (!profile || !profile->isValid || !sketch.isOk()) {
        statusBar()->showMessage(tr("Selected sketch entity is not a closed profile."), 5000);
        return;
    }

    ExtrudeParameters parameters;
    parameters.sketchId = extrudeSketchId_;
    parameters.profileId = profileId;
    parameters.direction = extrudeDialog_->direction();
    parameters.distance = extrudeDialog_->distance();
    if (!extrudeParametersValid(parameters)) {
        statusBar()->showMessage(tr("Extrude distance must be greater than zero"), 5000);
        return;
    }

    QString failureReason;
    kernel::TriangleMesh mesh;
    kernel::ShapeHandle shape;
    if (!buildExtrudeMesh(sketch.value(), *profile, parameters, mesh, &failureReason,
                          &shape)) {
        QMessageBox::warning(this, tr("Extrude Failed"),
                             failureReason.isEmpty()
                                 ? tr("The profile could not be extruded.")
                                 : failureReason);
        return;
    }

    // The mesh is built in world coordinates; the body keeps an identity
    // transform (moving it later goes through the normal transform path).
    Object body;
    body.id = "object-" + std::to_string(nextObjectNumber_++);
    body.type = ObjectType::Body;
    body.name = "Extrude Body " + std::to_string(extrudeCount_ + 1);
    body.primitive.kind = PrimitiveKind::None;
    document_.addObject(body);
    if (!shape.isNull()) {
        bodyShapes_[body.id] = shape;
    }
    bodyMeshes_[body.id] = mesh;
    viewer_->scene().addOrUpdateObjectMesh(body, mesh);
    refreshBodyFaces(body.id);

    Feature feature;
    feature.id = "feature-" + std::to_string(nextFeatureNumber_++);
    feature.name = "Extrude " + std::to_string(extrudeCount_ + 1);
    feature.type = FeatureType::Extrude;
    feature.targetObjectId = body.id;
    feature.createdBodyId = body.id;
    feature.extrude = parameters;
    document_.addFeature(feature);
    ++extrudeCount_;

    {
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addBodyItem(QString::fromStdString(body.id),
                                  QString::fromStdString(body.name), tr("Extrude"));
    }

    viewer_->scene().hideExtrudePreview();
    extrudeDialog_->hide();
    selectBody(body.id);
    markDirty();
    statusBar()->showMessage(tr("%1 created from %2")
                                 .arg(QString::fromStdString(body.name),
                                      QString::fromStdString(sketch.value().name)),
                             5000);
}

void MainWindow::cancelExtrude() {
    if (viewer_) {
        viewer_->scene().hideExtrudePreview();
    }
    if (extrudeDialog_) {
        extrudeDialog_->hide();
    }
    statusBar()->showMessage(tr("Extrude cancelled"), 3000);
}

bool MainWindow::buildExtrudeMesh(const Sketch& sketch, const SketchProfile& profile,
                                  const ExtrudeParameters& parameters,
                                  kernel::TriangleMesh& outMesh, QString* failureReason,
                                  kernel::ShapeHandle* outShape) {
    const SketchReference reference = sketch.reference.sourceId.empty()
                                          ? canonicalSketchReference(sketch.plane)
                                          : sketch.reference;
    // BRep path first (exact prism + extracted mesh in OCCT builds) ...
    if (evaluator_) {
        const Result<kernel::EvaluatedGeometry> evaluated =
            evaluator_->evaluateExtrude(reference, profile, parameters);
        if (evaluated.isOk() && evaluated.value().isValid &&
            !evaluated.value().previewMesh.isEmpty()) {
            outMesh = evaluated.value().previewMesh;
            if (outShape) {
                *outShape = evaluated.value().shape;
            }
            return true;
        }
        if (!evaluated.isOk() && failureReason) {
            *failureReason = QString::fromStdString(evaluated.error().message);
        }
    }
    // ... procedural prism fallback otherwise (no BRep backend).
    const Result<kernel::TriangleMesh> mesh =
        kernel::buildExtrudedProfileMesh(reference, profile, parameters);
    if (mesh.isOk() && !mesh.value().isEmpty()) {
        outMesh = mesh.value();
        return true;
    }
    if (failureReason && failureReason->isEmpty() && !mesh.isOk()) {
        *failureReason = QString::fromStdString(mesh.error().message);
    }
    return false;
}

void MainWindow::buildExtrudedBodyVisual(const Object& object, const Feature& feature) {
    if (!viewer_) {
        return;
    }
    const Result<Sketch> sketch = document_.sketchById(feature.extrude.sketchId);
    if (!sketch.isOk()) {
        qWarning("CADNext: extrude feature %s references missing sketch %s",
                 feature.id.c_str(), feature.extrude.sketchId.c_str());
        return;
    }
    // Profiles are not serialized: re-detect and look the recipe's profile
    // up by its stable id (with a fallback for pre-0.7 ids).
    const std::vector<SketchProfile> profiles =
        SketchProfileDetector().detect(sketch.value());
    const SketchProfile* profile =
        profileByIdOrLegacy(profiles, feature.extrude.profileId, sketch.value());
    if (!profile) {
        qWarning("CADNext: extrude feature %s references missing profile %s",
                 feature.id.c_str(), feature.extrude.profileId.c_str());
        return;
    }
    QString failureReason;
    kernel::TriangleMesh mesh;
    kernel::ShapeHandle shape;
    if (buildExtrudeMesh(sketch.value(), *profile, feature.extrude, mesh, &failureReason,
                         &shape)) {
        if (!shape.isNull()) {
            bodyShapes_[object.id] = shape;
        }
        bodyMeshes_[object.id] = mesh;
        viewer_->scene().addOrUpdateObjectMesh(object, mesh);
        refreshBodyFaces(object.id);
    } else {
        qWarning("CADNext: extrude regeneration failed for %s: %s", object.name.c_str(),
                 failureReason.toUtf8().constData());
    }
}

const SketchProfile* MainWindow::profileByIdOrLegacy(
    const std::vector<SketchProfile>& profiles, const std::string& profileId,
    const Sketch& sketch) const {
    if (const SketchProfile* profile = profileById(profiles, profileId)) {
        return profile;
    }
    // Pre-0.7 ids: "<entityId>" for rectangle/circle profiles and
    // "<sketchId>-loop" for the single sequential line loop.
    for (const SketchProfile& profile : profiles) {
        if (!profile.sourceEntityId.empty() && profile.sourceEntityId == profileId) {
            return &profile;
        }
    }
    if (profileId == sketch.id + "-loop") {
        for (const SketchProfile& profile : profiles) {
            if (profile.kind == SketchProfileKind::Polygon && profile.isValid) {
                return &profile;
            }
        }
    }
    return nullptr;
}

const Feature* MainWindow::extrudeFeatureForBody(const std::string& objectId) const {
    for (const Feature& feature : document_.features()) {
        if (feature.type == FeatureType::Extrude && feature.createdBodyId == objectId) {
            return &feature;
        }
    }
    return nullptr;
}

void MainWindow::openCutExtrudeDialog() {
    if (!viewer_) {
        return;
    }
    if (!kOcctBackendAvailable) {
        statusBar()->showMessage(tr("Cut Extrude requires OCCT backend."), 6000);
        return;
    }

    const std::optional<Sketch> sketch = sketchForExtrude();
    if (!sketch) {
        statusBar()->showMessage(tr("Select a closed sketch profile."), 5000);
        return;
    }

    cutDialogProfiles_.clear();
    for (SketchProfile& profile : SketchProfileDetector().detect(*sketch)) {
        if (profile.isValid) {
            cutDialogProfiles_.push_back(std::move(profile));
        }
    }
    if (cutDialogProfiles_.empty()) {
        statusBar()->showMessage(tr("Select a closed sketch profile."), 5000);
        return;
    }

    QList<CutBodyItem> bodies;
    QString selectedBody;
    for (const Object& object : document_.objects()) {
        if (object.type != ObjectType::Body) {
            continue;
        }
        if (bodyShapes_.find(object.id) == bodyShapes_.end()) {
            continue;
        }
        bodies.append({QString::fromStdString(object.id),
                       QString::fromStdString(object.name)});
        if (selectionKind_ == SelectionKind::Body && selectedId_ == object.id) {
            selectedBody = QString::fromStdString(object.id);
        }
    }
    if (bodies.empty()) {
        statusBar()->showMessage(tr("Select target body for cut."), 5000);
        return;
    }
    if (selectedBody.isEmpty()) {
        selectedBody = bodies.front().id;
    }

    cutSketchId_ = sketch->id;
    if (activeSketchId_) {
        exitSketchMode();
    }

    if (!cutDialog_) {
        cutDialog_ = new CutExtrudeDialog(this);
        connect(cutDialog_, &CutExtrudeDialog::parametersChanged, this,
                [this]() { onCutParametersChanged(); });
        connect(cutDialog_, &CutExtrudeDialog::applyRequested, this,
                [this]() { applyCutExtrude(); });
        connect(cutDialog_, &CutExtrudeDialog::cancelRequested, this,
                [this]() { cancelCutExtrude(); });
    }

    QList<ExtrudeProfileItem> profiles;
    QString selectedProfile;
    for (const SketchProfile& profile : cutDialogProfiles_) {
        QString label = profileKindText(profile.kind);
        if (!profile.sourceEntityId.empty()) {
            if (const SketchEntity* entity = findSketchEntity(*sketch, profile.sourceEntityId)) {
                label = QString::fromStdString(entity->name);
            }
        } else if (profile.kind == SketchProfileKind::Polygon) {
            label = tr("Polygon Profile (%1 lines)").arg(profile.sourceEntityIds.size());
        }
        label += tr(" — area %1").arg(profile.area, 0, 'f', 3);
        profiles.append({QString::fromStdString(profile.id), label});
        if (profile.id == selectedProfileId_) {
            selectedProfile = QString::fromStdString(profile.id);
        }
    }
    if (selectedProfile.isEmpty() && !profiles.empty()) {
        selectedProfile = profiles.front().id;
    }
    QString selectedLimit;
    for (const CutBodyItem& body : bodies) {
        if (body.id != selectedBody) {
            selectedLimit = body.id;
            break;
        }
    }

    cutDialog_->setTargetBodies(bodies, selectedBody);
    cutDialog_->setProfiles(profiles, selectedProfile);
    cutDialog_->setLimitObjects(bodies, selectedLimit);
    cutDialog_->show();
    cutDialog_->raise();
    cutDialog_->activateWindow();
    onCutParametersChanged();
    statusBar()->showMessage(
        tr("Cut Extrude: choose target, profile and depth mode — Apply modifies the body"));
}

void MainWindow::onCutParametersChanged() {
    if (!viewer_ || !cutDialog_ || !cutDialog_->isVisible()) {
        return;
    }
    if (!cutDialog_->previewEnabled()) {
        viewer_->scene().hideExtrudePreview();
        return;
    }

    const std::string profileId = cutDialog_->selectedProfileId().toStdString();
    const SketchProfile* profile = profileById(cutDialogProfiles_, profileId);
    const Result<Sketch> sketch = document_.sketchById(cutSketchId_);
    if (!profile || !profile->isValid || !sketch.isOk()) {
        viewer_->scene().hideExtrudePreview();
        return;
    }

    ExtrudeCutParameters parameters;
    parameters.targetBodyId = cutDialog_->targetBodyId().toStdString();
    parameters.sketchId = cutSketchId_;
    parameters.profileId = profileId;
    parameters.depthMode = cutDialog_->depthMode();
    parameters.direction = cutDialog_->direction();
    parameters.distance = cutDialog_->distance();
    parameters.limitObjectId = cutDialog_->limitObjectId().toStdString();

    const SketchReference reference = sketch.value().reference.sourceId.empty()
                                          ? canonicalSketchReference(sketch.value().plane)
                                          : sketch.value().reference;
    CutSpan span;
    QString failureReason;
    if (!computeCutSpanForParameters(parameters, reference, span, &failureReason)) {
        viewer_->scene().hideExtrudePreview();
        return;
    }
    const Result<kernel::TriangleMesh> mesh =
        kernel::buildProfilePrismMesh(reference, *profile, span.start, span.end);
    if (mesh.isOk() && !mesh.value().isEmpty()) {
        viewer_->scene().showExtrudePreview(mesh.value(), true);
    } else {
        viewer_->scene().hideExtrudePreview();
    }
}

void MainWindow::applyCutExtrude() {
    if (!viewer_ || !cutDialog_) {
        return;
    }
    if (!kOcctBackendAvailable) {
        statusBar()->showMessage(tr("Cut Extrude requires OCCT backend."), 6000);
        return;
    }

    const std::string targetBodyId = cutDialog_->targetBodyId().toStdString();
    Object* target = document_.mutableObjectById(targetBodyId);
    if (!target || target->type != ObjectType::Body) {
        statusBar()->showMessage(tr("Select target body for cut."), 5000);
        return;
    }

    const std::string profileId = cutDialog_->selectedProfileId().toStdString();
    const SketchProfile* profile = profileById(cutDialogProfiles_, profileId);
    const Result<Sketch> sketch = document_.sketchById(cutSketchId_);
    if (!profile || !profile->isValid || !sketch.isOk()) {
        statusBar()->showMessage(tr("Select a closed sketch profile."), 5000);
        return;
    }

    ExtrudeCutParameters parameters;
    parameters.targetBodyId = targetBodyId;
    parameters.sketchId = cutSketchId_;
    parameters.profileId = profileId;
    parameters.depthMode = cutDialog_->depthMode();
    parameters.direction = cutDialog_->direction();
    parameters.distance = cutDialog_->distance();
    parameters.limitObjectId = cutDialog_->limitObjectId().toStdString();
    if (!extrudeCutParametersValid(parameters)) {
        statusBar()->showMessage(tr("Cut parameters are invalid."), 5000);
        return;
    }

    const SketchReference reference = sketch.value().reference.sourceId.empty()
                                          ? canonicalSketchReference(sketch.value().plane)
                                          : sketch.value().reference;
    CutSpan span;
    QString failureReason;
    if (!computeCutSpanForParameters(parameters, reference, span, &failureReason)) {
        QMessageBox::warning(this, tr("Cut Extrude Failed"),
                             failureReason.isEmpty()
                                 ? tr("The cut extent could not be computed.")
                                 : failureReason);
        return;
    }

    const auto targetShapeIt = bodyShapes_.find(targetBodyId);
    if (targetShapeIt == bodyShapes_.end() || targetShapeIt->second.isNull()) {
        QMessageBox::warning(this, tr("Cut Extrude Failed"),
                             tr("Target body has no OCCT shape."));
        return;
    }

    const Result<kernel::EvaluatedGeometry> evaluated =
        evaluator_->evaluateExtrudeCut(targetShapeIt->second, reference, *profile, span);
    if (!evaluated.isOk() || !evaluated.value().isValid ||
        evaluated.value().previewMesh.isEmpty()) {
        const QString reason = evaluated.isOk()
                                   ? QString::fromStdString(evaluated.value().message)
                                   : QString::fromStdString(evaluated.error().message);
        QMessageBox::warning(this, tr("Cut Extrude Failed"),
                             reason.isEmpty() ? tr("OCCT boolean cut failed.") : reason);
        return;
    }

    bodyShapes_[targetBodyId] = evaluated.value().shape;
    bodyMeshes_[targetBodyId] = evaluated.value().previewMesh;
    viewer_->scene().addOrUpdateObjectMesh(*target, evaluated.value().previewMesh);
    refreshBodyFaces(targetBodyId);

    Feature feature;
    feature.id = "feature-" + std::to_string(nextFeatureNumber_++);
    feature.name = "Cut Extrude " + std::to_string(cutCount_ + 1);
    feature.type = FeatureType::ExtrudeCut;
    feature.targetObjectId = targetBodyId;
    feature.modifiedBodyId = targetBodyId;
    feature.extrudeCut = parameters;
    document_.addFeature(feature);
    ++cutCount_;

    viewer_->scene().hideExtrudePreview();
    cutDialog_->hide();
    selectBody(targetBodyId);
    markDirty();
    statusBar()->showMessage(
        tr("%1 cut applied (%2)")
            .arg(QString::fromStdString(target->name), cutDepthModeText(parameters.depthMode)),
        5000);
}

void MainWindow::cancelCutExtrude() {
    if (viewer_) {
        viewer_->scene().hideExtrudePreview();
    }
    if (cutDialog_) {
        cutDialog_->hide();
    }
    statusBar()->showMessage(tr("Cut Extrude cancelled"), 3000);
}

bool MainWindow::computeCutSpanForParameters(const ExtrudeCutParameters& parameters,
                                             const SketchReference& reference,
                                             CutSpan& outSpan,
                                             QString* failureReason) {
    if (!kernel_) {
        if (failureReason) {
            *failureReason = tr("Geometry kernel is not available.");
        }
        return false;
    }
    if (!extrudeCutParametersValid(parameters)) {
        if (failureReason) {
            *failureReason = tr("Cut parameters are invalid.");
        }
        return false;
    }

    const auto targetIt = bodyShapes_.find(parameters.targetBodyId);
    if (targetIt == bodyShapes_.end() || targetIt->second.isNull()) {
        if (failureReason) {
            *failureReason = tr("Target body has no OCCT shape.");
        }
        return false;
    }

    CutExtents extents;
    const Result<kernel::ShapeBounds> targetBounds = kernel_->boundingBox(targetIt->second);
    if (!targetBounds.isOk()) {
        if (failureReason) {
            *failureReason = QString::fromStdString(targetBounds.error().message);
        }
        return false;
    }
    accumulateProjectedBounds(targetBounds.value(), reference, extents.targetMin,
                              extents.targetMax);
    extents.targetDiagonal = boundsDiagonal(targetBounds.value());

    if (parameters.depthMode == CutDepthMode::ToObject) {
        if (parameters.limitObjectId == parameters.targetBodyId) {
            if (failureReason) {
                *failureReason = tr("Limit object must be different from the target body.");
            }
            return false;
        }
        const auto limitIt = bodyShapes_.find(parameters.limitObjectId);
        if (limitIt == bodyShapes_.end() || limitIt->second.isNull()) {
            if (failureReason) {
                *failureReason = tr("Limit object has no OCCT shape.");
            }
            return false;
        }
        const Result<kernel::ShapeBounds> limitBounds = kernel_->boundingBox(limitIt->second);
        if (!limitBounds.isOk()) {
            if (failureReason) {
                *failureReason = QString::fromStdString(limitBounds.error().message);
            }
            return false;
        }
        accumulateProjectedBounds(limitBounds.value(), reference, extents.limitMin,
                                  extents.limitMax);
        extents.hasLimit = true;
    }

    const Result<CutSpan> span = computeCutSpan(parameters, extents);
    if (!span.isOk()) {
        if (failureReason) {
            *failureReason = QString::fromStdString(span.error().message);
        }
        return false;
    }
    outSpan = span.value();
    return true;
}

bool MainWindow::replayExtrudeCutFeature(const Feature& feature, QString* failureReason) {
    if (feature.type != FeatureType::ExtrudeCut || feature.suppressed) {
        return true;
    }
    if (!kOcctBackendAvailable) {
        if (failureReason) {
            *failureReason = tr("Cut Extrude requires OCCT backend.");
        }
        return false;
    }

    Object* target = document_.mutableObjectById(feature.extrudeCut.targetBodyId);
    if (!target || target->type != ObjectType::Body) {
        if (failureReason) {
            *failureReason = tr("Cut feature references a missing target body.");
        }
        return false;
    }
    const Result<Sketch> sketch = document_.sketchById(feature.extrudeCut.sketchId);
    if (!sketch.isOk()) {
        if (failureReason) {
            *failureReason = QString::fromStdString(sketch.error().message);
        }
        return false;
    }
    const std::vector<SketchProfile> profiles = SketchProfileDetector().detect(sketch.value());
    const SketchProfile* profile =
        profileByIdOrLegacy(profiles, feature.extrudeCut.profileId, sketch.value());
    if (!profile || !profile->isValid) {
        if (failureReason) {
            *failureReason = tr("Cut feature references a missing or invalid profile.");
        }
        return false;
    }

    const SketchReference reference = sketch.value().reference.sourceId.empty()
                                          ? canonicalSketchReference(sketch.value().plane)
                                          : sketch.value().reference;
    CutSpan span;
    if (!computeCutSpanForParameters(feature.extrudeCut, reference, span, failureReason)) {
        return false;
    }
    const auto targetShapeIt = bodyShapes_.find(feature.extrudeCut.targetBodyId);
    if (targetShapeIt == bodyShapes_.end() || targetShapeIt->second.isNull()) {
        if (failureReason) {
            *failureReason = tr("Target body has no OCCT shape.");
        }
        return false;
    }
    const Result<kernel::EvaluatedGeometry> evaluated =
        evaluator_->evaluateExtrudeCut(targetShapeIt->second, reference, *profile, span);
    if (!evaluated.isOk() || !evaluated.value().isValid ||
        evaluated.value().previewMesh.isEmpty()) {
        if (failureReason) {
            *failureReason = evaluated.isOk()
                                 ? QString::fromStdString(evaluated.value().message)
                                 : QString::fromStdString(evaluated.error().message);
        }
        return false;
    }
    bodyShapes_[target->id] = evaluated.value().shape;
    bodyMeshes_[target->id] = evaluated.value().previewMesh;
    if (viewer_) {
        viewer_->scene().addOrUpdateObjectMesh(*target, evaluated.value().previewMesh);
    }
    refreshBodyFaces(target->id);
    return true;
}

// --- Face workflow (0.8 Sketch on Face) --------------------------------------

void MainWindow::refreshBodyFaces(const std::string& bodyId) {
    if (!viewer_ || !kernel_) {
        return;
    }
    const auto shapeIt = bodyShapes_.find(bodyId);
    if (shapeIt == bodyShapes_.end() || shapeIt->second.isNull()) {
        const auto meshIt = bodyMeshes_.find(bodyId);
        if (meshIt != bodyMeshes_.end()) {
            std::vector<kernel::FaceReference> faces =
                kernel::planarFacesForMesh(bodyId, meshIt->second);
            viewer_->scene().setBodyFaces(bodyId, faces);
            bodyFaces_[bodyId] = std::move(faces);
            if (selectionKind_ == SelectionKind::BodyFace && selectedFace_.bodyId == bodyId &&
                !findBodyFace(bodyId, selectedFace_.faceId)) {
                clearSelection();
            }
            updateFaceActionsEnabled();
            return;
        }
        bodyFaces_.erase(bodyId);
        viewer_->scene().removeBodyFaces(bodyId);
        updateFaceActionsEnabled();
        return;
    }
    kernel::FaceAnalyzer analyzer(*kernel_);
    std::vector<kernel::FaceReference> faces =
        analyzer.planarFacesForBody(bodyId, shapeIt->second);
    viewer_->scene().setBodyFaces(bodyId, faces);
    bodyFaces_[bodyId] = std::move(faces);
    // The shape changed, so the selected face id may no longer exist.
    if (selectionKind_ == SelectionKind::BodyFace && selectedFace_.bodyId == bodyId &&
        !findBodyFace(bodyId, selectedFace_.faceId)) {
        clearSelection();
    }
    updateFaceActionsEnabled();
}

const kernel::FaceReference* MainWindow::findBodyFace(const std::string& bodyId,
                                                      const std::string& faceId) const {
    const auto it = bodyFaces_.find(bodyId);
    if (it == bodyFaces_.end()) {
        return nullptr;
    }
    for (const kernel::FaceReference& face : it->second) {
        if (face.faceId == faceId) {
            return &face;
        }
    }
    return nullptr;
}

SketchReference MainWindow::sketchReferenceFromFace(const kernel::FaceReference& face) const {
    SketchReference reference;
    reference.type = SketchReferenceType::BodyFace;
    reference.sourceId = face.faceId;
    reference.sourceBodyId = face.bodyId;
    reference.sourceFaceId = face.faceId;
    reference.origin = face.origin;
    reference.uAxis = face.uAxis;
    reference.vAxis = face.vAxis;
    reference.normal = face.normal;
    const Result<Object> body = document_.objectById(face.bodyId);
    reference.displayName =
        "Face of " + (body.isOk() ? body.value().name : face.bodyId);
    return reference;
}

void MainWindow::createSketchOnSelectedFace() {
    if (selectionKind_ != SelectionKind::BodyFace) {
        statusBar()->showMessage(tr("Select a planar body face first."), 5000);
        return;
    }
    const kernel::FaceReference* face =
        findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
    if (!face || !face->isSketchable) {
        statusBar()->showMessage(tr("Sketches need a planar face."), 5000);
        return;
    }
    enterSketchOnReference(sketchReferenceFromFace(*face));
}

void MainWindow::createWorkPlaneFromSelectedFace() {
    if (!viewer_ || selectionKind_ != SelectionKind::BodyFace) {
        statusBar()->showMessage(tr("Select a planar body face first."), 5000);
        return;
    }
    const kernel::FaceReference* face =
        findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
    if (!face || !face->isSketchable) {
        statusBar()->showMessage(tr("Work planes need a planar face."), 5000);
        return;
    }

    WorkPlane plane;
    ++facePlaneCount_;
    plane.id = "faceplane-" + std::to_string(facePlaneCount_);
    plane.name = "Plane from Face " + std::to_string(facePlaneCount_);
    plane.kind = WorkPlaneKind::FacePlane;
    plane.origin = face->origin;
    plane.uAxis = face->uAxis;
    plane.vAxis = face->vAxis;
    plane.normal = face->normal;
    plane.width = std::max(face->width, 0.25);
    plane.height = std::max(face->height, 0.25);
    plane.sourceBodyId = face->bodyId;
    plane.sourceFaceId = face->faceId;

    document_.addWorkPlane(plane);
    viewer_->scene().addOrUpdateDocumentWorkPlane(plane);
    {
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addWorkPlaneItem(QString::fromStdString(plane.id),
                                       QString::fromStdString(plane.name),
                                       workPlaneTypeText(plane));
    }
    markDirty();
    selectWorkPlane(plane.id);
    statusBar()->showMessage(tr("%1 created — Create Sketch or Normal to Plane")
                                 .arg(QString::fromStdString(plane.name)),
                             5000);
}

void MainWindow::normalToSelectedFace() {
    if (!viewer_ || selectionKind_ != SelectionKind::BodyFace) {
        return;
    }
    const kernel::FaceReference* face =
        findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
    if (!face) {
        return;
    }
    WorkPlane plane;
    plane.id = face->faceId;
    plane.name = "Face";
    plane.kind = WorkPlaneKind::FacePlane;
    plane.origin = face->origin;
    plane.uAxis = face->uAxis;
    plane.vAxis = face->vAxis;
    plane.normal = face->normal;
    plane.width = std::max(face->width, 0.25);
    plane.height = std::max(face->height, 0.25);
    viewer_->setViewNormalToPlane(plane);
}

void MainWindow::updateFaceActionsEnabled() {
    const kernel::FaceReference* face =
        selectionKind_ == SelectionKind::BodyFace
            ? findBodyFace(selectedFace_.bodyId, selectedFace_.faceId)
            : nullptr;
    const bool planar = face && face->isSketchable;
    toolBar_->createSketchOnFaceAction()->setEnabled(planar && !activeSketchId_);
    toolBar_->workPlaneFromFaceAction()->setEnabled(planar && !activeSketchId_);
    toolBar_->normalToFaceAction()->setEnabled(planar);
}

void MainWindow::showFaceActionPalette(bool contextClick) {
    if (!contextClick || selectionKind_ != SelectionKind::BodyFace || activeSketchId_) {
        return;
    }
    const kernel::FaceReference* face =
        findBodyFace(selectedFace_.bodyId, selectedFace_.faceId);
    if (!face) {
        return;
    }
    QMenu menu(this);
    QAction* createSketch = nullptr;
    QAction* createPlane = nullptr;
    QAction* normalView = nullptr;
    if (face->isSketchable) {
        createSketch = menu.addAction(tr("Create Sketch"));
        createPlane = menu.addAction(tr("Create Work Plane"));
        normalView = menu.addAction(tr("Normal to Face"));
    } else {
        menu.addAction(tr("Face is not planar — no sketch actions"))->setEnabled(false);
    }
    QAction* chosen = menu.exec(QCursor::pos());
    if (chosen && chosen == createSketch) {
        createSketchOnSelectedFace();
    } else if (chosen && chosen == createPlane) {
        createWorkPlaneFromSelectedFace();
    } else if (chosen && chosen == normalView) {
        normalToSelectedFace();
    }
}

void MainWindow::resolveFaceReferencesAfterLoad() {
    // Stable-ish face ids v1: try to re-resolve every saved bodyId/faceId
    // pair against the rebuilt bodies. Found faces refresh the resolved
    // plane (the body may have been re-evaluated slightly differently);
    // missing ids keep the saved resolved plane — the document must load
    // and stay editable either way.
    for (const Sketch& sketch : document_.sketches()) {
        if (sketch.reference.type != SketchReferenceType::BodyFace ||
            sketch.reference.sourceFaceId.empty()) {
            continue;
        }
        Sketch* mutableSketch = document_.mutableSketchById(sketch.id);
        if (!mutableSketch) {
            continue;
        }
        if (const kernel::FaceReference* face = findBodyFace(
                sketch.reference.sourceBodyId, sketch.reference.sourceFaceId)) {
            mutableSketch->reference.origin = face->origin;
            mutableSketch->reference.uAxis = face->uAxis;
            mutableSketch->reference.vAxis = face->vAxis;
            mutableSketch->reference.normal = face->normal;
        } else {
            qWarning("CADNext: sketch %s references face %s that no longer resolves; "
                     "using the saved plane fallback",
                     sketch.id.c_str(), sketch.reference.sourceFaceId.c_str());
        }
    }
    for (const WorkPlane& plane : document_.workPlanes()) {
        if (plane.kind != WorkPlaneKind::FacePlane || plane.sourceFaceId.empty()) {
            continue;
        }
        WorkPlane* mutablePlane = document_.mutableWorkPlaneById(plane.id);
        if (!mutablePlane) {
            continue;
        }
        if (const kernel::FaceReference* face =
                findBodyFace(plane.sourceBodyId, plane.sourceFaceId)) {
            mutablePlane->origin = face->origin;
            mutablePlane->uAxis = face->uAxis;
            mutablePlane->vAxis = face->vAxis;
            mutablePlane->normal = face->normal;
            mutablePlane->width = std::max(face->width, 0.25);
            mutablePlane->height = std::max(face->height, 0.25);
        } else {
            qWarning("CADNext: work plane %s references face %s that no longer resolves; "
                     "using the saved plane fallback",
                     plane.id.c_str(), plane.sourceFaceId.c_str());
        }
    }
}

void MainWindow::updatePlaneBadge() {
    if (!planeBadge_) {
        return;
    }
    if (!activeSketchId_ || !activeSketchPlane_) {
        planeBadge_->hide();
        return;
    }
    const QString plane = QString::fromStdString(activeSketchPlane_->name);
    const QString uAxis = QString::fromUtf8(dominantWorldAxisName(activeSketchPlane_->uAxis));
    const QString vAxis = QString::fromUtf8(dominantWorldAxisName(activeSketchPlane_->vAxis));
    planeBadge_->setText(tr("Sketch2D — Plane %1\nU: %2    V: %3")
                             .arg(plane, uAxis, vAxis));
    planeBadge_->adjustSize();
    planeBadge_->show();
}

// --- Property edits ---------------------------------------------------------

void MainWindow::onObjectNameEdited(const QString& objectId, const QString& newName) {
    Object* object = document_.mutableObjectById(objectId.toStdString());
    if (!object) {
        return;
    }
    const std::string name = newName.toStdString();
    if (object->name == name) {
        return;
    }
    commandStack_.push(
        std::make_unique<RenameObjectCommand>(object->id, object->name, name), document_);
    projectTree_->updateBodyName(objectId, newName);
    markDirty();
    updateUndoRedoActions();
}

void MainWindow::onSketchNameEdited(const QString& sketchId, const QString& newName) {
    Sketch* sketch = document_.mutableSketchById(sketchId.toStdString());
    if (!sketch || sketch->name == newName.toStdString()) {
        return;
    }
    sketch->name = newName.toStdString();
    projectTree_->updateSketchName(sketchId, newName);
    markDirty();
}

void MainWindow::onEntityNameEdited(const QString& sketchId, const QString& entityId,
                                    const QString& newName) {
    Sketch* sketch = document_.mutableSketchById(sketchId.toStdString());
    if (!sketch) {
        return;
    }
    SketchEntity* entity = findSketchEntity(*sketch, entityId.toStdString());
    if (!entity || entity->name == newName.toStdString()) {
        return;
    }
    commandStack_.push(std::make_unique<RenameSketchEntityCommand>(
                           sketch->id, entity->id, entity->name, newName.toStdString()),
                       document_);
    projectTree_->updateEntityName(sketchId, entityId, newName);
    markDirty();
    updateUndoRedoActions();
}

void MainWindow::onTransformEdited(const QString& objectId, const Transform& transform) {
    Object* object = document_.mutableObjectById(objectId.toStdString());
    if (!object || !viewer_) {
        return;
    }
    Transform sanitized;
    sanitized.position = {sanitize(transform.position.x, 0.0),
                          sanitize(transform.position.y, 0.0),
                          sanitize(transform.position.z, 0.0)};
    sanitized.rotationEuler = {sanitize(transform.rotationEuler.x, 0.0),
                               sanitize(transform.rotationEuler.y, 0.0),
                               sanitize(transform.rotationEuler.z, 0.0)};
    sanitized.scale = {sanitize(transform.scale.x, 1.0, kMinScale),
                       sanitize(transform.scale.y, 1.0, kMinScale),
                       sanitize(transform.scale.z, 1.0, kMinScale)};

    object->transform = sanitized;
    viewer_->scene().updateObjectTransform(object->id, sanitized);
    markDirty();
}

void MainWindow::onPrimitiveEdited(const QString& objectId,
                                   const PrimitiveParameters& parameters) {
    Object* object = document_.mutableObjectById(objectId.toStdString());
    if (!object || !viewer_) {
        return;
    }
    // The kind never changes through the property panel.
    object->primitive.width = sanitize(parameters.width, 1.0, kMinDimension);
    object->primitive.height = sanitize(parameters.height, 1.0, kMinDimension);
    object->primitive.depth = sanitize(parameters.depth, 1.0, kMinDimension);
    object->primitive.radius = sanitize(parameters.radius, 0.5, kMinDimension);

    // Dimension changes re-evaluate the BRep shape and rebuild the mesh;
    // transform-only changes never do (see onTransformEdited).
    buildObjectVisual(*object);
    markDirty();
}

// --- File handling -----------------------------------------------------------

void MainWindow::newDocument() {
    if (!maybeSave()) {
        return;
    }
    document_ = Document();
    document_.setName("CADNext Prototype Document");
    commandStack_.clear();
    currentFilePath_.clear();
    rebuildUiFromDocument();
    setClean();
    updateUndoRedoActions();
}

void MainWindow::openDocument() {
    if (!maybeSave()) {
        return;
    }
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Open CADNext Document"), QString(),
        tr("CADNext Documents (*.cadnext);;All Files (*)"));
    if (path.isEmpty()) {
        return;
    }
    const Result<Document> loaded = DocumentSerializer::loadFromFile(path.toStdString());
    if (!loaded.isOk()) {
        QMessageBox::warning(this, tr("Open Failed"),
                             QString::fromStdString(loaded.error().message));
        return;
    }
    document_ = loaded.value();
    commandStack_.clear();
    currentFilePath_ = path;
    rebuildUiFromDocument();
    setClean();
    updateUndoRedoActions();
}

bool MainWindow::saveDocument() {
    if (currentFilePath_.isEmpty()) {
        return saveDocumentAs();
    }
    const Result<bool> saved =
        DocumentSerializer::saveToFile(document_, currentFilePath_.toStdString());
    if (!saved.isOk()) {
        QMessageBox::warning(this, tr("Save Failed"),
                             QString::fromStdString(saved.error().message));
        return false;
    }
    setClean();
    return true;
}

bool MainWindow::saveDocumentAs() {
    QString path = QFileDialog::getSaveFileName(
        this, tr("Save CADNext Document"), QStringLiteral("untitled.cadnext"),
        tr("CADNext Documents (*.cadnext)"));
    if (path.isEmpty()) {
        return false;
    }
    if (!path.endsWith(QStringLiteral(".cadnext"), Qt::CaseInsensitive)) {
        path += QStringLiteral(".cadnext");
    }
    currentFilePath_ = path;
    return saveDocument();
}

bool MainWindow::maybeSave() {
    if (!dirty_) {
        return true;
    }
    const QMessageBox::StandardButton choice = QMessageBox::warning(
        this, tr("Unsaved Changes"),
        tr("The document has unsaved changes.\nDo you want to save them?"),
        QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel, QMessageBox::Save);
    switch (choice) {
    case QMessageBox::Save:
        return saveDocument();
    case QMessageBox::Discard:
        return true;
    default:
        return false;
    }
}

void MainWindow::rebuildUiFromDocument() {
    exitSketchMode();
    clearSelection();
    {
        const QSignalBlocker blocker(projectTree_);
        projectTree_->clearAll();
    }
    addCanonicalWorkPlanesToTree();
    if (viewer_) {
        viewer_->scene().clearObjectNodes();
        viewer_->scene().clearSketchNodes();
        viewer_->scene().clearDocumentWorkPlanes();
        viewer_->scene().hideSketchPlane();
    }
    bodyShapes_.clear();
    bodyMeshes_.clear();
    bodyFaces_.clear();
    for (const Object& object : document_.objects()) {
        // Shapes are never serialized; every load re-evaluates the
        // primitive descriptors through the kernel. Extruded bodies are
        // re-derived from their feature recipe (sketch profile + extrude
        // parameters).
        const Feature* extrudeFeature = extrudeFeatureForBody(object.id);
        if (extrudeFeature) {
            buildExtrudedBodyVisual(object, *extrudeFeature);
        } else {
            buildObjectVisual(object);
        }
        const QSignalBlocker blocker(projectTree_);
        if (object.type == ObjectType::ReferencePlane) {
            const WorkPlane plane = workPlaneFromReferencePlaneObject(object);
            projectTree_->addWorkPlaneItem(QString::fromStdString(plane.id),
                                           QString::fromStdString(plane.name),
                                           workPlaneTypeText(plane));
        } else {
            projectTree_->addBodyItem(QString::fromStdString(object.id),
                                      QString::fromStdString(object.name),
                                      extrudeFeature ? tr("Extrude") : treeTypeText(object));
        }
    }
    for (const Feature& feature : document_.features()) {
        if (feature.type != FeatureType::ExtrudeCut) {
            continue;
        }
        QString failureReason;
        if (!replayExtrudeCutFeature(feature, &failureReason)) {
            qWarning("CADNext: cut feature %s replay failed: %s",
                     feature.id.c_str(), failureReason.toUtf8().constData());
            statusBar()->showMessage(
                tr("Cut feature replay failed for %1 (%2)")
                    .arg(QString::fromStdString(feature.name), failureReason),
                8000);
        }
    }
    // Re-attach face-based references against the rebuilt bodies (found
    // ids refresh the resolved plane, missing ids keep the saved one),
    // then mirror the document work planes into scene and tree.
    resolveFaceReferencesAfterLoad();
    for (const WorkPlane& plane : document_.workPlanes()) {
        if (viewer_) {
            viewer_->scene().addOrUpdateDocumentWorkPlane(plane);
        }
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addWorkPlaneItem(QString::fromStdString(plane.id),
                                       QString::fromStdString(plane.name),
                                       workPlaneTypeText(plane));
    }
    for (const Sketch& sketch : document_.sketches()) {
        if (viewer_) {
            viewer_->scene().addOrUpdateSketchNode(sketch);
        }
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addSketchItem(QString::fromStdString(sketch.id),
                                    QString::fromStdString(sketch.name));
        for (const SketchEntity& entity : sketch.entities) {
            projectTree_->addEntityItem(QString::fromStdString(sketch.id),
                                        QString::fromStdString(entity.id),
                                        QString::fromStdString(entity.name),
                                        QString::fromUtf8(sketchEntityTypeName(entity.type)));
        }
    }
    deriveCountersFromDocument();
    refreshPropertyPanel();
    updateExtrudeActionEnabled();
}

void MainWindow::deriveCountersFromDocument() {
    nextObjectNumber_ = 1;
    boxCount_ = 0;
    cylinderCount_ = 0;
    sphereCount_ = 0;
    planeCount_ = 0;
    nextSketchNumber_ = 1;
    nextEntityNumber_ = 1;
    lineCount_ = 0;
    rectangleCount_ = 0;
    circleCount_ = 0;
    nextFeatureNumber_ = 1;
    extrudeCount_ = 0;
    cutCount_ = 0;
    facePlaneCount_ = 0;

    for (const WorkPlane& plane : document_.workPlanes()) {
        // facePlaneCount_ is the highest used "faceplane-N" number, so new
        // planes continue after the loaded ones.
        if (plane.id.rfind("faceplane-", 0) == 0) {
            facePlaneCount_ =
                std::max(facePlaneCount_, std::atoi(plane.id.c_str() + 10));
        }
    }

    for (const Feature& feature : document_.features()) {
        nextFeatureNumber_ = maxNumberSuffix(feature.id, "feature-", nextFeatureNumber_);
        if (feature.type == FeatureType::Extrude) {
            ++extrudeCount_;
        } else if (feature.type == FeatureType::ExtrudeCut) {
            ++cutCount_;
        }
    }

    for (const Object& object : document_.objects()) {
        // Keep generated ids unique across load: continue after the
        // highest existing "object-N" suffix.
        nextObjectNumber_ = maxNumberSuffix(object.id, "object-", nextObjectNumber_);
        if (object.type == ObjectType::ReferencePlane) {
            ++planeCount_;
            continue;
        }
        switch (object.primitive.kind) {
        case PrimitiveKind::Box: ++boxCount_; break;
        case PrimitiveKind::Cylinder: ++cylinderCount_; break;
        case PrimitiveKind::Sphere: ++sphereCount_; break;
        default: break;
        }
    }

    for (const Sketch& sketch : document_.sketches()) {
        nextSketchNumber_ = maxNumberSuffix(sketch.id, "sketch-", nextSketchNumber_);
        for (const SketchEntity& entity : sketch.entities) {
            nextEntityNumber_ = maxNumberSuffix(entity.id, "entity-", nextEntityNumber_);
            switch (entity.type) {
            case SketchEntityType::Line: ++lineCount_; break;
            case SketchEntityType::Rectangle: ++rectangleCount_; break;
            case SketchEntityType::Circle: ++circleCount_; break;
            }
        }
    }
}

// --- Dirty-state -------------------------------------------------------------

void MainWindow::markDirty() {
    if (!dirty_) {
        dirty_ = true;
        updateWindowTitle();
    }
}

void MainWindow::setClean() {
    dirty_ = false;
    updateWindowTitle();
}

void MainWindow::updateWindowTitle() {
    const QString base = currentFilePath_.isEmpty()
                             ? QString::fromStdString(document_.name())
                             : QFileInfo(currentFilePath_).fileName();
    setWindowTitle(QStringLiteral("%1%2 — CADNext 0.8")
                       .arg(base, dirty_ ? QStringLiteral("*") : QString()));
}

// --- Undo/redo ----------------------------------------------------------------

void MainWindow::undo() {
    if (!commandStack_.canUndo()) {
        return;
    }
    commandStack_.undo(document_);
    afterHistoryChange();
}

void MainWindow::redo() {
    if (!commandStack_.canRedo()) {
        return;
    }
    commandStack_.redo(document_);
    afterHistoryChange();
}

void MainWindow::afterHistoryChange() {
    // Commands can add/remove sketch entities as well as rename things, so
    // rebuild the mirrored UI state from the document, restoring sketch
    // mode when the active sketch still exists.
    const std::optional<std::string> rememberedSketch = activeSketchId_;
    rebuildUiFromDocument();
    if (rememberedSketch && document_.sketchById(*rememberedSketch).isOk()) {
        enterSketchMode(*rememberedSketch);
    }
    markDirty();
    updateUndoRedoActions();
}

void MainWindow::updateUndoRedoActions() {
    undoAction_->setEnabled(commandStack_.canUndo());
    redoAction_->setEnabled(commandStack_.canRedo());
}

// --- Menus --------------------------------------------------------------------

void MainWindow::createMenus() {
    QMenu* fileMenu = menuBar()->addMenu(tr("&File"));
    fileMenu->addAction(tr("&New"), QKeySequence::New, this, [this]() { newDocument(); });
    fileMenu->addAction(tr("&Open…"), QKeySequence::Open, this, [this]() { openDocument(); });
    fileMenu->addSeparator();
    fileMenu->addAction(tr("&Save"), QKeySequence::Save, this, [this]() { saveDocument(); });
    fileMenu->addAction(tr("Save &As…"), QKeySequence::SaveAs, this,
                        [this]() { saveDocumentAs(); });

    QMenu* editMenu = menuBar()->addMenu(tr("&Edit"));
    undoAction_ = editMenu->addAction(tr("&Undo"), QKeySequence::Undo, this,
                                      [this]() { undo(); });
    redoAction_ = editMenu->addAction(tr("&Redo"), QKeySequence::Redo, this,
                                      [this]() { redo(); });

    QMenu* partMenu = menuBar()->addMenu(tr("&Part"));
    partMenu->addAction(toolBar_->extrudeAction());
    partMenu->addAction(toolBar_->cutExtrudeAction());
    partMenu->addSeparator();
    partMenu->addAction(toolBar_->createSketchOnFaceAction());
    partMenu->addAction(toolBar_->workPlaneFromFaceAction());
    partMenu->addAction(toolBar_->normalToFaceAction());

    QMenu* viewMenu = menuBar()->addMenu(tr("&View"));
    viewMenu->addAction(treeDock_->toggleViewAction());
    viewMenu->addAction(propertyDock_->toggleViewAction());
}

} // namespace cadnext::gui
