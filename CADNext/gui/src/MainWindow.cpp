#include "cadnext/gui/MainWindow.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>

#include <QCloseEvent>
#include <QDockWidget>
#include <QFileDialog>
#include <QFileInfo>
#include <QLabel>
#include <QMenuBar>
#include <QMessageBox>
#include <QSignalBlocker>
#include <QStatusBar>
#include <QVBoxLayout>
#include <QtLogging>

#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/gui/ProjectTree.hpp"
#include "cadnext/gui/PropertyPanel.hpp"
#include "cadnext/gui/SketchToolBar.hpp"
#include "cadnext/gui/ToolBar.hpp"
#include "cadnext/kernel/KernelFactory.hpp"

namespace cadnext::gui {

namespace {

constexpr double kMinScale = 0.001;
constexpr double kMinDimension = 0.001;
constexpr double kMinSketchExtent = 1.0e-6;

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

int maxNumberSuffix(const std::string& id, const char* prefix, int current) {
    if (id.rfind(prefix, 0) == 0) {
        const int number = std::atoi(id.c_str() + std::strlen(prefix));
        return std::max(current, number + 1);
    }
    return current;
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
    auto* treeDock = new QDockWidget(tr("Project"), this);
    treeDock->setWidget(projectTree_);
    treeDock->setFeatures(QDockWidget::DockWidgetMovable);
    addDockWidget(Qt::LeftDockWidgetArea, treeDock);

    propertyPanel_ = new PropertyPanel(this);
    auto* propertyDock = new QDockWidget(tr("Properties"), this);
    propertyDock->setWidget(propertyPanel_);
    propertyDock->setFeatures(QDockWidget::DockWidgetMovable);
    addDockWidget(Qt::BottomDockWidgetArea, propertyDock);

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

    // Project tree.
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

    statusBar()->showMessage(
        tr("Click an object in the viewport or the project tree to select it; "
           "click empty space to clear the selection"));
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

    selection_ = std::make_unique<viewer::SelectionController>(viewer_->scene());

    viewer_->setPickCallback([this](const viewer::ViewportPickTarget& target) {
        if (target.isSketchEntity()) {
            selectEntity(target.sketchId, target.entityId);
        } else if (target.isBody()) {
            selectBody(target.objectId);
        } else {
            clearSelection();
        }
    });
    viewer_->setSketchPointCallback([this](double u, double v) { onSketchPoint(u, v); });
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
}

void MainWindow::clearSelection() {
    if (selectionKind_ == SelectionKind::None) {
        return;
    }
    selectionKind_ = SelectionKind::None;
    selectedId_.clear();
    selectedSketchId_.clear();
    syncTreeSelection();
    syncViewportSelection();
    refreshPropertyPanel();
}

void MainWindow::syncTreeSelection() {
    const QSignalBlocker blocker(projectTree_);
    switch (selectionKind_) {
    case SelectionKind::Body:
        projectTree_->setCurrentBody(QString::fromStdString(selectedId_));
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

    sketchToolBar_->setEnterSketchEnabled(selectionKind_ == SelectionKind::Sketch &&
                                          !activeSketchId_);
}

void MainWindow::refreshPropertyPanel() {
    switch (selectionKind_) {
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
    case SelectionKind::None:
        break;
    }
    propertyPanel_->clearObject();
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
        projectTree_->addBodyItem(QString::fromStdString(object.id),
                                  QString::fromStdString(object.name), treeTypeText(object));
    }
    selectBody(object.id);
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
            viewer_->scene().addOrUpdateObjectMesh(object, evaluated.value().previewMesh);
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
    case SelectionKind::Body: {
        const std::string objectId = selectedId_;
        clearSelection();
        document_.removeObject(objectId);
        viewer_->scene().removeObjectNode(objectId);
        {
            const QSignalBlocker blocker(projectTree_);
            projectTree_->removeBodyItem(QString::fromStdString(objectId));
        }
        markDirty();
        break;
    }
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
    if (!viewer_) {
        return;
    }

    Sketch sketch;
    sketch.id = "sketch-" + std::to_string(nextSketchNumber_);
    sketch.name = std::string("Sketch ") + sketchPlaneName(plane) + " " +
                  std::to_string(nextSketchNumber_);
    ++nextSketchNumber_;
    sketch.plane = plane;

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
    pendingSketchPoint_.reset();
    sketchTool_ = SketchTool::Select;

    viewer_->scene().showSketchPlane(sketch.value().plane);
    viewer_->setSketchInputMode(false, sketch.value().plane);
    sketchToolBar_->setSketchModeActive(true);
    sketchToolBar_->checkSelectTool();
    sketchToolBar_->setEnterSketchEnabled(false);
    statusBar()->showMessage(
        tr("Sketch mode (%1): pick Line / Rectangle / Circle and click on the plane; "
           "Esc cancels the tool, Exit Sketch finishes")
            .arg(QString::fromStdString(sketch.value().name)));
}

void MainWindow::exitSketchMode() {
    if (!activeSketchId_) {
        return;
    }
    activeSketchId_.reset();
    pendingSketchPoint_.reset();
    sketchTool_ = SketchTool::Select;
    if (viewer_) {
        viewer_->scene().hideSketchPlane();
        viewer_->setSketchInputMode(false, SketchPlane::XY);
    }
    sketchToolBar_->setSketchModeActive(false);
    sketchToolBar_->setEnterSketchEnabled(selectionKind_ == SelectionKind::Sketch);
    statusBar()->showMessage(tr("Sketch mode finished"), 4000);
}

void MainWindow::setSketchTool(SketchTool tool) {
    sketchTool_ = tool;
    pendingSketchPoint_.reset();
    if (!viewer_ || !activeSketchId_) {
        return;
    }
    const Result<Sketch> sketch = document_.sketchById(*activeSketchId_);
    if (!sketch.isOk()) {
        return;
    }
    viewer_->setSketchInputMode(tool != SketchTool::Select, sketch.value().plane);
}

void MainWindow::cancelSketchTool() {
    pendingSketchPoint_.reset();
    setSketchTool(SketchTool::Select);
    sketchToolBar_->checkSelectTool();
    statusBar()->showMessage(tr("Sketch tool cancelled"), 3000);
}

void MainWindow::onSketchPoint(double u, double v) {
    if (!activeSketchId_ || sketchTool_ == SketchTool::Select) {
        return;
    }
    if (!std::isfinite(u) || !std::isfinite(v)) {
        return;
    }

    if (!pendingSketchPoint_) {
        pendingSketchPoint_ = SketchPoint2D{u, v};
        statusBar()->showMessage(tr("First point set — click the second point (Esc cancels)"));
        return;
    }

    const SketchPoint2D first = *pendingSketchPoint_;
    pendingSketchPoint_.reset();

    SketchEntity entity;
    entity.id = "entity-" + std::to_string(nextEntityNumber_++);

    switch (sketchTool_) {
    case SketchTool::Line: {
        if (std::fabs(u - first.u) < kMinSketchExtent &&
            std::fabs(v - first.v) < kMinSketchExtent) {
            statusBar()->showMessage(tr("Zero-length line ignored"), 3000);
            return;
        }
        entity.type = SketchEntityType::Line;
        entity.name = "Line " + std::to_string(++lineCount_);
        entity.line.start = first;
        entity.line.end = {u, v};
        break;
    }
    case SketchTool::Rectangle: {
        const double width = std::fabs(u - first.u);
        const double height = std::fabs(v - first.v);
        if (width < kMinSketchExtent || height < kMinSketchExtent) {
            statusBar()->showMessage(tr("Degenerate rectangle ignored"), 3000);
            return;
        }
        entity.type = SketchEntityType::Rectangle;
        entity.name = "Rectangle " + std::to_string(++rectangleCount_);
        entity.rectangle.origin = {std::min(first.u, u), std::min(first.v, v)};
        entity.rectangle.width = width;
        entity.rectangle.height = height;
        break;
    }
    case SketchTool::Circle: {
        const double radius = std::hypot(u - first.u, v - first.v);
        if (radius < kMinSketchExtent) {
            statusBar()->showMessage(tr("Zero-radius circle ignored"), 3000);
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

    addSketchEntity(std::move(entity));
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
    selectEntity(sketchId, entityId.toStdString());
    markDirty();
    updateUndoRedoActions();
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
    if (viewer_) {
        viewer_->scene().clearObjectNodes();
        viewer_->scene().clearSketchNodes();
        viewer_->scene().hideSketchPlane();
    }
    for (const Object& object : document_.objects()) {
        // Shapes are never serialized; every load re-evaluates the
        // primitive descriptors through the kernel.
        buildObjectVisual(object);
        const QSignalBlocker blocker(projectTree_);
        projectTree_->addBodyItem(QString::fromStdString(object.id),
                                  QString::fromStdString(object.name), treeTypeText(object));
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
    setWindowTitle(QStringLiteral("%1%2 — CADNext 0.5")
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
}

} // namespace cadnext::gui
