#include "cadnext/gui/AssemblyWindow.hpp"

#include <algorithm>
#include <cmath>

#include <QAction>
#include <QCheckBox>
#include <QCloseEvent>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QFileDialog>
#include <QFileInfo>
#include <QFormLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QLabel>
#include <QLineEdit>
#include <QMenuBar>
#include <QMessageBox>
#include <QPlainTextEdit>
#include <QStatusBar>
#include <QTimer>
#include <QToolBar>
#include <QTreeWidget>
#include <QVBoxLayout>

#include "cadnext/Object.hpp"
#include "cadnext/Units.hpp"
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/assembly/DirectPlacementSolver.hpp"
#include "cadnext/gui/AssemblyJointDialog.hpp"

namespace cadnext::gui {

namespace {

constexpr int kIdRole = Qt::UserRole + 1;
constexpr int kKindRole = Qt::UserRole + 2;
constexpr int kComponentKind = 1;
constexpr int kJointKind = 2;

constexpr double kRadiansToDegrees = 180.0 / M_PI;
constexpr double kDegreesToRadians = M_PI / 180.0;

// Euler display follows the core Transform convention: degrees, applied
// about world X, then Y, then Z. The assembly core itself stays purely
// quaternion-based — these exist only for the property panel fields.
cadnext::Vector3 eulerDegreesFromQuaternion(const assembly::Quaternion& q) {
    const double m00 = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
    const double m10 = 2.0 * (q.x * q.y + q.w * q.z);
    const double m20 = 2.0 * (q.x * q.z - q.w * q.y);
    const double m21 = 2.0 * (q.y * q.z + q.w * q.x);
    const double m22 = 1.0 - 2.0 * (q.x * q.x + q.y * q.y);

    const double sy = std::clamp(-m20, -1.0, 1.0);
    const double y = std::asin(sy);
    double x = 0.0;
    double z = 0.0;
    if (std::fabs(sy) < 1.0 - 1.0e-9) {
        x = std::atan2(m21, m22);
        z = std::atan2(m10, m00);
    } else {
        // Gimbal lock: fold everything into X.
        const double m01 = 2.0 * (q.x * q.y - q.w * q.z);
        const double m11 = 1.0 - 2.0 * (q.x * q.x + q.z * q.z);
        x = std::atan2(-m01, m11);
    }
    return {x * kRadiansToDegrees, y * kRadiansToDegrees, z * kRadiansToDegrees};
}

assembly::Quaternion quaternionFromEulerDegrees(double xDeg, double yDeg, double zDeg) {
    const assembly::Quaternion qx =
        assembly::Quaternion::fromAxisAngle({1.0, 0.0, 0.0}, xDeg * kDegreesToRadians);
    const assembly::Quaternion qy =
        assembly::Quaternion::fromAxisAngle({0.0, 1.0, 0.0}, yDeg * kDegreesToRadians);
    const assembly::Quaternion qz =
        assembly::Quaternion::fromAxisAngle({0.0, 0.0, 1.0}, zDeg * kDegreesToRadians);
    // multiply applies the right factor first → X, then Y, then Z.
    return qz.multiply(qy.multiply(qx)).normalized();
}

QString jointStatusText(assembly::JointSolveStatus status) {
    switch (status) {
    case assembly::JointSolveStatus::Unsolved:
        return QCoreApplication::translate("AssemblyWindow", "Не решено");
    case assembly::JointSolveStatus::Solved:
        return QCoreApplication::translate("AssemblyWindow", "Решено");
    case assembly::JointSolveStatus::SolvedHeuristic:
        return QCoreApplication::translate("AssemblyWindow",
                                           "Решено (ссылка восстановлена)");
    case assembly::JointSolveStatus::Broken:
        return QCoreApplication::translate("AssemblyWindow", "Ссылка потеряна");
    case assembly::JointSolveStatus::Conflict:
        return QCoreApplication::translate("AssemblyWindow", "Конфликт");
    }
    return QString();
}

// World-space copies of part-local topology for picking/highlight while
// the joint tool is active (the assembly document itself always stores
// part-local frames + the component placement).
kernel::FaceReference faceTransformedBy(const kernel::FaceReference& face,
                                        const assembly::Placement& placement) {
    kernel::FaceReference out = face;
    out.origin = placement.apply(face.origin);
    out.uAxis = placement.applyDirection(face.uAxis);
    out.vAxis = placement.applyDirection(face.vAxis);
    out.normal = placement.applyDirection(face.normal);
    out.axisOrigin = placement.apply(face.axisOrigin);
    out.axisDirection = placement.applyDirection(face.axisDirection);
    for (kernel::MeshVertex& vertex : out.previewMesh.vertices) {
        const cadnext::Vector3 world =
            placement.apply({vertex.x, vertex.y, vertex.z});
        vertex = {world.x, world.y, world.z};
    }
    return out;
}

kernel::EdgeReference edgeTransformedBy(const kernel::EdgeReference& edge,
                                        const assembly::Placement& placement) {
    kernel::EdgeReference out = edge;
    out.start = placement.apply(edge.start);
    out.end = placement.apply(edge.end);
    out.center = placement.apply(edge.center);
    out.axisDirection = placement.applyDirection(edge.axisDirection);
    for (cadnext::Vector3& point : out.previewPolyline) {
        point = placement.apply(point);
    }
    return out;
}

double distancePointToSegment(const cadnext::Vector3& point, const cadnext::Vector3& a,
                              const cadnext::Vector3& b) {
    const cadnext::Vector3 ab = assembly::subtract(b, a);
    const double lengthSquared = assembly::dot(ab, ab);
    if (lengthSquared <= 1.0e-18) {
        return assembly::length(assembly::subtract(point, a));
    }
    const double t = std::clamp(
        assembly::dot(assembly::subtract(point, a), ab) / lengthSquared, 0.0, 1.0);
    const cadnext::Vector3 projected = assembly::add(a, assembly::scale(ab, t));
    return assembly::length(assembly::subtract(point, projected));
}

QString referenceKindText(assembly::GeometryReferenceKind kind) {
    switch (kind) {
    case assembly::GeometryReferenceKind::PlanarFace:
        return QCoreApplication::translate("AssemblyWindow", "плоская грань");
    case assembly::GeometryReferenceKind::CylindricalFace:
        return QCoreApplication::translate("AssemblyWindow", "цилиндрическая грань");
    case assembly::GeometryReferenceKind::LinearEdge:
        return QCoreApplication::translate("AssemblyWindow", "ребро");
    case assembly::GeometryReferenceKind::CircularEdge:
        return QCoreApplication::translate("AssemblyWindow", "круглая кромка");
    case assembly::GeometryReferenceKind::Vertex:
        return QCoreApplication::translate("AssemblyWindow", "вершина");
    case assembly::GeometryReferenceKind::LocalCoordinateSystem:
        return QCoreApplication::translate("AssemblyWindow", "ЛСК компонента");
    }
    return QString();
}

QString jointTypeText(assembly::JointType type) {
    switch (type) {
    case assembly::JointType::Coincident:
        return QCoreApplication::translate("AssemblyWindow", "Совпадение");
    case assembly::JointType::Parallel:
        return QCoreApplication::translate("AssemblyWindow", "Параллельность");
    case assembly::JointType::Perpendicular:
        return QCoreApplication::translate("AssemblyWindow", "Перпендикулярность");
    case assembly::JointType::Concentric:
        return QCoreApplication::translate("AssemblyWindow", "Соосность");
    case assembly::JointType::Distance:
        return QCoreApplication::translate("AssemblyWindow", "Расстояние");
    case assembly::JointType::Angle:
        return QCoreApplication::translate("AssemblyWindow", "Угол");
    case assembly::JointType::Rigid:
        return QCoreApplication::translate("AssemblyWindow", "Жёсткое");
    }
    return QString();
}

} // namespace

AssemblyWindow::AssemblyWindow(QWidget* parent)
    : QMainWindow(parent), partLoader_(std::make_unique<AssemblyPartLoader>()) {
    document_.setName(tr("Новая сборка").toStdString());
    setWindowTitle(QString());
    updateWindowTitle();
    resize(1280, 820);

    // --- Left dock: Components / Joints tree --------------------------------
    tree_ = new QTreeWidget(this);
    tree_->setColumnCount(2);
    tree_->setHeaderLabels({tr("Элемент"), tr("Статус")});
    tree_->header()->setStretchLastSection(true);
    tree_->setSelectionMode(QAbstractItemView::SingleSelection);
    componentsGroup_ = new QTreeWidgetItem(tree_, {tr("Компоненты"), QString()});
    jointsGroup_ = new QTreeWidgetItem(tree_, {tr("Сопряжения"), QString()});
    componentsGroup_->setExpanded(true);
    jointsGroup_->setExpanded(true);
    connect(tree_, &QTreeWidget::itemSelectionChanged, this,
            &AssemblyWindow::handleTreeSelection);

    auto* treeDock = new QDockWidget(tr("Сборка"), this);
    treeDock->setObjectName(QStringLiteral("assemblyTreeDock"));
    treeDock->setWidget(tree_);
    treeDock->setFeatures(QDockWidget::DockWidgetMovable);
    addDockWidget(Qt::LeftDockWidgetArea, treeDock);

    // --- Right dock: properties + diagnostics --------------------------------
    auto* propertiesDock = new QDockWidget(tr("Свойства"), this);
    propertiesDock->setObjectName(QStringLiteral("assemblyPropertiesDock"));
    propertiesDock->setWidget(buildPropertyPanel());
    propertiesDock->setFeatures(QDockWidget::DockWidgetMovable);
    addDockWidget(Qt::RightDockWidgetArea, propertiesDock);

    // --- Toolbar / menu -------------------------------------------------------
    auto* toolbar = addToolBar(tr("Сборка"));
    toolbar->setObjectName(QStringLiteral("assemblyToolBar"));
    toolbar->setMovable(false);

    QAction* newAction = toolbar->addAction(tr("Создать"));
    QAction* openAction = toolbar->addAction(tr("Открыть…"));
    QAction* saveAction = toolbar->addAction(tr("Сохранить"));
    toolbar->addSeparator();
    QAction* insertAction = toolbar->addAction(tr("Вставить деталь…"));
    groundAction_ = toolbar->addAction(tr("Закрепить"));
    moveModeAction_ = toolbar->addAction(tr("Переместить"));
    moveModeAction_->setCheckable(true);
    QAction* deleteAction = toolbar->addAction(tr("Удалить"));
    toolbar->addSeparator();

    const struct {
        assembly::JointType type;
        QString title;
    } jointButtons[] = {
        {assembly::JointType::Coincident, tr("Совпадение")},
        {assembly::JointType::Parallel, tr("Параллельность")},
        {assembly::JointType::Perpendicular, tr("Перпендикулярность")},
        {assembly::JointType::Concentric, tr("Соосность")},
        {assembly::JointType::Distance, tr("Расстояние")},
        {assembly::JointType::Angle, tr("Угол")},
        {assembly::JointType::Rigid, tr("Жёсткое")},
    };
    for (const auto& button : jointButtons) {
        QAction* action = toolbar->addAction(button.title);
        const assembly::JointType type = button.type;
        connect(action, &QAction::triggered, this,
                [this, type]() { startJointTool(type); });
    }
    toolbar->addSeparator();
    QAction* recomputeAction = toolbar->addAction(tr("Пересчитать"));

    connect(newAction, &QAction::triggered, this, [this]() { newAssembly(); });
    connect(openAction, &QAction::triggered, this, [this]() { openAssembly(); });
    connect(saveAction, &QAction::triggered, this, [this]() { saveAssembly(); });
    connect(insertAction, &QAction::triggered, this, [this]() { insertPart(); });
    connect(groundAction_, &QAction::triggered, this,
            [this]() { toggleGroundSelected(); });
    connect(moveModeAction_, &QAction::toggled, this,
            [this](bool active) { setMoveModeActive(active); });
    connect(deleteAction, &QAction::triggered, this, [this]() { deleteSelected(); });
    connect(recomputeAction, &QAction::triggered, this, [this]() { runRecompute(); });

    QMenu* fileMenu = menuBar()->addMenu(tr("Файл"));
    fileMenu->addAction(tr("Создать сборку"), this, [this]() { newAssembly(); });
    fileMenu->addAction(tr("Открыть сборку…"), this, [this]() { openAssembly(); });
    fileMenu->addSeparator();
    fileMenu->addAction(tr("Сохранить"), this, [this]() { saveAssembly(); });
    fileMenu->addAction(tr("Сохранить как…"), this, [this]() { saveAssemblyAs(); });

    statusBar()->showMessage(
        tr("Вставьте детали и закрепите базовую, чтобы начать сборку"), 8000);
}

AssemblyWindow::~AssemblyWindow() = default;

void AssemblyWindow::initializeViewport() {
    if (viewer_) {
        return;
    }
    viewportContainer_ = new QWidget(this);
    auto* layout = new QVBoxLayout(viewportContainer_);
    layout->setContentsMargins(0, 0, 0, 0);

    viewer_ = std::make_unique<viewer::CoinViewer>(viewportContainer_);
    layout->addWidget(viewer_->widget());
    setCentralWidget(viewportContainer_);

    viewer_->setPickCallback(
        [this](const viewer::ViewportPickTarget& target, bool contextClick) {
            handleViewportPick(target, contextClick);
        });
    // ESC in the viewport cancels the active joint tool.
    viewer_->setSketchCancelCallback([this]() { cancelJointTool(); });
    viewer_->resetCamera();
}

void AssemblyWindow::closeEvent(QCloseEvent* event) {
    if (!maybeSave()) {
        event->ignore();
        return;
    }
    setMoveModeActive(false);
    event->accept();
}

// ---------------------------------------------------------------------------
// Document lifecycle
// ---------------------------------------------------------------------------

bool AssemblyWindow::maybeSave() {
    if (!dirty_) {
        return true;
    }
    const QMessageBox::StandardButton answer = QMessageBox::question(
        this, tr("Сборка изменена"), tr("Сохранить изменения сборки?"),
        QMessageBox::Save | QMessageBox::Discard | QMessageBox::Cancel);
    if (answer == QMessageBox::Cancel) {
        return false;
    }
    if (answer == QMessageBox::Save) {
        return saveAssembly();
    }
    return true;
}

void AssemblyWindow::newAssembly() {
    if (!maybeSave()) {
        return;
    }
    cancelJointTool();
    setMoveModeActive(false);
    document_ = assembly::AssemblyDocument();
    document_.setName(tr("Новая сборка").toStdString());
    currentFilePath_.clear();
    nextComponentNumber_ = 1;
    nextJointNumber_ = 1;
    lastRecompute_ = {};
    clearSelection();
    rebuildSceneFromDocument();
    rebuildTree();
    updateDiagnosticsView();
    setClean();
}

void AssemblyWindow::openAssembly() {
    if (!maybeSave()) {
        return;
    }
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Открыть сборку"), QString(),
        tr("Сборки CADNext (*.cadasm);;Все файлы (*)"));
    if (path.isEmpty()) {
        return;
    }
    loadFromPath(path);
}

void AssemblyWindow::loadFromPath(const QString& path) {
    const Result<assembly::AssemblyDocument> loaded =
        assembly::AssemblySerializer::loadFromFile(path.toStdString());
    if (!loaded.isOk()) {
        QMessageBox::warning(this, tr("Не удалось открыть сборку"),
                             QString::fromStdString(loaded.error().message));
        return;
    }
    cancelJointTool();
    setMoveModeActive(false);
    document_ = loaded.value();
    currentFilePath_ = path;

    // Keep generated ids unique after load.
    int maxComponent = 0;
    for (const assembly::AssemblyComponent& component : document_.components()) {
        int number = 0;
        if (std::sscanf(component.id.c_str(), "component-%d", &number) == 1) {
            maxComponent = std::max(maxComponent, number);
        }
    }
    nextComponentNumber_ = maxComponent + 1;
    int maxJoint = 0;
    for (const assembly::AssemblyJoint& joint : document_.joints()) {
        int number = 0;
        if (std::sscanf(joint.id.c_str(), "joint-%d", &number) == 1) {
            maxJoint = std::max(maxJoint, number);
        }
    }
    nextJointNumber_ = maxJoint + 1;

    clearSelection();
    rebuildSceneFromDocument();
    rebuildTree();
    runRecompute();
    if (viewer_) {
        viewer_->fitView();
    }
    setClean();
}

bool AssemblyWindow::saveAssembly() {
    if (currentFilePath_.isEmpty()) {
        return saveAssemblyAs();
    }
    return saveToPath(currentFilePath_);
}

bool AssemblyWindow::saveAssemblyAs() {
    QString path = QFileDialog::getSaveFileName(
        this, tr("Сохранить сборку"), QString(),
        tr("Сборки CADNext (*.cadasm);;Все файлы (*)"));
    if (path.isEmpty()) {
        return false;
    }
    if (!path.endsWith(QStringLiteral(".cadasm"), Qt::CaseInsensitive)) {
        path += QStringLiteral(".cadasm");
    }
    return saveToPath(path);
}

bool AssemblyWindow::saveToPath(const QString& path) {
    const Result<bool> saved =
        assembly::AssemblySerializer::saveToFile(document_, path.toStdString());
    if (!saved.isOk()) {
        QMessageBox::warning(this, tr("Не удалось сохранить сборку"),
                             QString::fromStdString(saved.error().message));
        return false;
    }
    currentFilePath_ = path;
    setClean();
    statusBar()->showMessage(tr("Сборка сохранена: %1").arg(path), 5000);
    return true;
}

void AssemblyWindow::markDirty() {
    dirty_ = true;
    updateWindowTitle();
}

void AssemblyWindow::setClean() {
    dirty_ = false;
    updateWindowTitle();
}

void AssemblyWindow::updateWindowTitle() {
    const QString name = currentFilePath_.isEmpty()
                             ? QString::fromStdString(document_.name())
                             : QFileInfo(currentFilePath_).completeBaseName();
    setWindowTitle(tr("Сборка — %1%2").arg(name, dirty_ ? QStringLiteral(" *")
                                                        : QString()));
}

// ---------------------------------------------------------------------------
// Components
// ---------------------------------------------------------------------------

std::string AssemblyWindow::nextComponentId() const {
    return "component-" + std::to_string(nextComponentNumber_);
}

void AssemblyWindow::insertPart() {
    const QString path = QFileDialog::getOpenFileName(
        this, tr("Вставить деталь"), QString(),
        tr("Детали и сборки (*.uavpart *.cadnext *.cadasm);;Детали UAVPart "
           "(*.uavpart);;CAD-документы (*.cadnext);;Подсборки (*.cadasm);;Все "
           "файлы (*)"));
    if (path.isEmpty()) {
        return;
    }

    // A subassembly cannot contain itself, directly or transitively.
    if (!currentFilePath_.isEmpty() &&
        QFileInfo(path).canonicalFilePath() ==
            QFileInfo(currentFilePath_).canonicalFilePath()) {
        QMessageBox::warning(this, tr("Не удалось вставить деталь"),
                             tr("Сборка не может содержать саму себя."));
        return;
    }

    assembly::PartReference source;
    if (path.endsWith(QStringLiteral(".cadnext"), Qt::CaseInsensitive)) {
        source.kind = assembly::PartSourceKind::CadnextDocument;
    } else if (path.endsWith(QStringLiteral(".cadasm"), Qt::CaseInsensitive)) {
        source.kind = assembly::PartSourceKind::Assembly;
    } else {
        source.kind = assembly::PartSourceKind::UavPart;
    }
    source.filePath = path.toStdString();

    const AssemblyPartGeometry& geometry = partLoader_->geometryForSource(source);
    if (!geometry.valid) {
        QMessageBox::warning(this, tr("Не удалось вставить деталь"), geometry.error);
        return;
    }
    source.contentHash = geometry.contentHash;

    assembly::AssemblyComponent component;
    component.id = nextComponentId();
    ++nextComponentNumber_;
    component.name = geometry.displayName.empty()
                         ? QFileInfo(path).completeBaseName().toStdString()
                         : geometry.displayName;
    component.source = source;
    // Spread inserted parts along X so each one stays visible.
    component.placement.translation = {
        1.5 * static_cast<double>(document_.components().size()), 0.0, 0.0};

    const bool isFirstComponent = document_.components().empty();
    document_.addComponent(component);

    if (isFirstComponent) {
        const QMessageBox::StandardButton answer = QMessageBox::question(
            this, tr("Закрепить деталь"),
            tr("Сделать «%1» неподвижным основанием сборки?")
                .arg(QString::fromStdString(component.name)),
            QMessageBox::Yes | QMessageBox::No, QMessageBox::Yes);
        if (answer == QMessageBox::Yes) {
            if (assembly::AssemblyComponent* stored =
                    document_.mutableComponentById(component.id)) {
                stored->isGrounded = true;
            }
        }
    }

    refreshComponentVisual(document_.componentById(component.id).value());
    rebuildTree();
    selectComponent(component.id);
    markDirty();
    runRecompute();
    if (viewer_) {
        viewer_->fitView();
    }
}

assembly::AssemblyComponent* AssemblyWindow::selectedComponent() {
    if (selectionKind_ != SelectionKind::Component) {
        return nullptr;
    }
    return document_.mutableComponentById(selectedComponentId_);
}

const assembly::AssemblyComponent* AssemblyWindow::selectedComponentConst() const {
    if (selectionKind_ != SelectionKind::Component) {
        return nullptr;
    }
    for (const assembly::AssemblyComponent& component : document_.components()) {
        if (component.id == selectedComponentId_) {
            return &component;
        }
    }
    return nullptr;
}

void AssemblyWindow::toggleGroundSelected() {
    assembly::AssemblyComponent* component = selectedComponent();
    if (!component) {
        statusBar()->showMessage(tr("Выберите компонент, чтобы закрепить его"), 4000);
        return;
    }
    component->isGrounded = !component->isGrounded;
    markDirty();
    rebuildTree();
    selectComponent(component->id);
    runRecompute();
}

void AssemblyWindow::deleteSelected() {
    cancelJointTool();
    if (selectionKind_ == SelectionKind::Component && !selectedComponentId_.empty()) {
        if (manipComponentId_ == selectedComponentId_) {
            setMoveModeActive(false);
        }
        if (viewer_) {
            viewer_->scene().removeObjectNode(selectedComponentId_);
        }
        document_.removeComponent(selectedComponentId_);
        clearSelection();
        rebuildTree();
        markDirty();
        runRecompute();
        return;
    }
    if (selectionKind_ == SelectionKind::Joint && !selectedJointId_.empty()) {
        document_.removeJoint(selectedJointId_);
        clearSelection();
        rebuildTree();
        markDirty();
        runRecompute();
        return;
    }
    statusBar()->showMessage(tr("Выберите компонент или сопряжение для удаления"), 4000);
}

void AssemblyWindow::setMoveModeActive(bool active) {
    if (moveModeAction_ && moveModeAction_->isChecked() != active) {
        const QSignalBlocker blocker(moveModeAction_);
        moveModeAction_->setChecked(active);
    }
    if (!viewer_) {
        return;
    }
    if (!active && !manipComponentId_.empty()) {
        viewer_->scene().detachTransformManip(manipComponentId_);
        manipComponentId_.clear();
    }
    viewer_->setSceneInteractionMode(active);
    if (active) {
        syncMoveManip();
    }
}

void AssemblyWindow::syncMoveManip() {
    if (!viewer_ || !moveModeAction_ || !moveModeAction_->isChecked()) {
        return;
    }
    const assembly::AssemblyComponent* component = selectedComponentConst();
    const std::string targetId = component && !component->isGrounded ? component->id
                                                                     : std::string();
    if (manipComponentId_ == targetId) {
        return;
    }
    if (!manipComponentId_.empty()) {
        viewer_->scene().detachTransformManip(manipComponentId_);
        manipComponentId_.clear();
    }
    if (targetId.empty()) {
        if (component && component->isGrounded) {
            statusBar()->showMessage(
                tr("Компонент закреплён — сначала открепите его"), 4000);
        }
        return;
    }
    const bool attached = viewer_->scene().attachTransformManip(
        targetId, [this](const std::string& componentId) {
            // Deferred: dragger callbacks must not restructure the scene
            // graph they are dragging in.
            QTimer::singleShot(0, this, [this, componentId]() {
                handleManipFinished(componentId);
            });
        });
    if (attached) {
        manipComponentId_ = targetId;
    }
}

void AssemblyWindow::handleManipFinished(const std::string& componentId) {
    if (!viewer_) {
        return;
    }
    cadnext::Vector3 position;
    double quaternion[4] = {0.0, 0.0, 0.0, 1.0};
    if (!viewer_->scene().manipPlacement(componentId, position, quaternion)) {
        return;
    }
    assembly::AssemblyComponent* component = document_.mutableComponentById(componentId);
    if (!component || component->isGrounded) {
        return;
    }
    component->placement.translation = position;
    component->placement.rotation =
        assembly::Quaternion{quaternion[0], quaternion[1], quaternion[2], quaternion[3]}
            .normalized();
    markDirty();
    runRecompute();
    refreshPropertyPanel();
}

// ---------------------------------------------------------------------------
// Recompute + mirroring
// ---------------------------------------------------------------------------

assembly::AssemblyRecomputeEngine::TopologyProvider AssemblyWindow::topologyProvider() {
    return [this](const assembly::AssemblyComponent& component)
               -> const assembly::PartTopology* {
        const AssemblyPartGeometry& geometry =
            partLoader_->geometryForSource(component.source);
        return geometry.valid ? &geometry.topology : nullptr;
    };
}

void AssemblyWindow::refreshSourceRevisions() {
    QStringList changed;
    for (const assembly::AssemblyComponent& component : document_.components()) {
        if (component.source.filePath.empty()) {
            continue;
        }
        const std::string hash =
            assembly::AssemblySerializer::contentHashForFile(component.source.filePath);
        if (hash.empty()) {
            continue; // unreadable — surfaced as a load error during recompute
        }
        assembly::AssemblyComponent* stored =
            document_.mutableComponentById(component.id);
        if (!stored) {
            continue;
        }
        if (stored->source.contentHash.empty()) {
            stored->source.contentHash = hash; // first bind after an older save
        } else if (stored->source.contentHash != hash) {
            partLoader_->invalidate(stored->source.filePath);
            stored->source.contentHash = hash;
            stored->source.expectedRevision += 1;
            changed << QString::fromStdString(stored->name);
            markDirty();
        }
    }
    if (!changed.isEmpty()) {
        statusBar()->showMessage(
            tr("Исходные детали изменены: %1 — геометрия перезагружена, "
               "ссылки перепривязаны")
                .arg(changed.join(QStringLiteral(", "))),
            8000);
    }
}

void AssemblyWindow::runRecompute() {
    refreshSourceRevisions();
    lastRecompute_ = recomputeEngine_.recompute(document_, topologyProvider());
    applyPlacementsToScene();
    refreshTreeStatuses();
    refreshPropertyPanel();
    updateDiagnosticsView();
    if (lastRecompute_.placementsChanged) {
        markDirty();
    }
}

void AssemblyWindow::refreshComponentVisual(const assembly::AssemblyComponent& component) {
    if (!viewer_) {
        return;
    }
    if (!component.isVisible || component.isSuppressed) {
        viewer_->scene().removeObjectNode(component.id);
        return;
    }
    const AssemblyPartGeometry& geometry = partLoader_->geometryForSource(component.source);
    if (!geometry.valid) {
        viewer_->scene().removeObjectNode(component.id);
        return;
    }

    Object object;
    object.id = component.id;
    object.name = component.name;
    object.type = ObjectType::Body;
    viewer_->scene().addOrUpdateObjectMesh(object, geometry.mesh);
    viewer_->scene().updateObjectPlacement(
        component.id, component.placement.translation, component.placement.rotation.x,
        component.placement.rotation.y, component.placement.rotation.z,
        component.placement.rotation.w);
}

void AssemblyWindow::rebuildSceneFromDocument() {
    if (!viewer_) {
        return;
    }
    if (!manipComponentId_.empty()) {
        viewer_->scene().detachTransformManip(manipComponentId_);
        manipComponentId_.clear();
    }
    viewer_->scene().clearObjectNodes();
    viewer_->scene().clearBodyFaces();
    viewer_->scene().clearBodyEdges();
    for (const assembly::AssemblyComponent& component : document_.components()) {
        refreshComponentVisual(component);
    }
    syncMoveManip();
}

void AssemblyWindow::applyPlacementsToScene() {
    if (!viewer_) {
        return;
    }
    for (const assembly::AssemblyComponent& component : document_.components()) {
        viewer_->scene().updateObjectPlacement(
            component.id, component.placement.translation,
            component.placement.rotation.x, component.placement.rotation.y,
            component.placement.rotation.z, component.placement.rotation.w);
    }
}

void AssemblyWindow::rebuildTree() {
    const QSignalBlocker blocker(tree_);
    while (componentsGroup_->childCount() > 0) {
        delete componentsGroup_->takeChild(0);
    }
    while (jointsGroup_->childCount() > 0) {
        delete jointsGroup_->takeChild(0);
    }
    for (const assembly::AssemblyComponent& component : document_.components()) {
        auto* item = new QTreeWidgetItem(componentsGroup_);
        item->setData(0, kIdRole, QString::fromStdString(component.id));
        item->setData(0, kKindRole, kComponentKind);
        item->setText(0, (component.isGrounded ? QStringLiteral("🔒 ") : QString()) +
                             QString::fromStdString(component.name));
    }
    for (const assembly::AssemblyJoint& joint : document_.joints()) {
        auto* item = new QTreeWidgetItem(jointsGroup_);
        item->setData(0, kIdRole, QString::fromStdString(joint.id));
        item->setData(0, kKindRole, kJointKind);
        item->setText(0, QString::fromStdString(joint.name));
    }
    refreshTreeStatuses();
}

void AssemblyWindow::refreshTreeStatuses() {
    const QSignalBlocker blocker(tree_);
    for (int i = 0; i < componentsGroup_->childCount(); ++i) {
        QTreeWidgetItem* item = componentsGroup_->child(i);
        const std::string componentId =
            item->data(0, kIdRole).toString().toStdString();
        const auto component = document_.componentById(componentId);
        if (!component.isOk()) {
            continue;
        }
        item->setText(0, (component.value().isGrounded ? QStringLiteral("🔒 ")
                                                       : QString()) +
                             QString::fromStdString(component.value().name));
        QString status;
        const auto dofIt = lastRecompute_.dofByComponent.find(componentId);
        if (component.value().isGrounded) {
            status = tr("Закреплена");
        } else if (dofIt != lastRecompute_.dofByComponent.end()) {
            const auto& info = dofIt->second;
            if (info.conflict) {
                status = tr("Конфликт");
            } else if (info.overconstrained) {
                status = tr("Переопределена");
            } else if (info.remainingDof == 0) {
                status = tr("Полностью определена");
            } else if (info.remainingDof > 0) {
                status = tr("Недоопределена: %1 DOF").arg(info.remainingDof);
            } else if (!info.inGroundedGroup) {
                status = tr("Не закреплена");
            }
        }
        item->setText(1, status);
    }
    for (int i = 0; i < jointsGroup_->childCount(); ++i) {
        QTreeWidgetItem* item = jointsGroup_->child(i);
        const std::string jointId = item->data(0, kIdRole).toString().toStdString();
        const auto joint = document_.jointById(jointId);
        if (!joint.isOk()) {
            continue;
        }
        item->setText(1, jointStatusText(joint.value().solveState.status));
    }
}

void AssemblyWindow::updateDiagnosticsView() {
    if (!diagnosticsView_) {
        return;
    }
    QStringList lines;
    for (const assembly::AssemblyDiagnostic& diagnostic : document_.diagnostics()) {
        QString prefix;
        switch (diagnostic.severity) {
        case assembly::DiagnosticSeverity::Info:
            prefix = tr("Инфо");
            break;
        case assembly::DiagnosticSeverity::Warning:
            prefix = tr("Предупреждение");
            break;
        case assembly::DiagnosticSeverity::Error:
            prefix = tr("Ошибка");
            break;
        }
        lines << QStringLiteral("[%1] %2").arg(prefix,
                                               QString::fromStdString(diagnostic.message));
    }
    diagnosticsView_->setPlainText(lines.join(QStringLiteral("\n")));
}

// ---------------------------------------------------------------------------
// Selection
// ---------------------------------------------------------------------------

void AssemblyWindow::handleViewportPick(const viewer::ViewportPickTarget& target,
                                        bool contextClick) {
    Q_UNUSED(contextClick);
    if (jointToolActive_) {
        handleJointPick(target);
        return;
    }
    if (target.isBody()) {
        selectComponent(target.objectId);
        return;
    }
    if (target.isEmpty()) {
        clearSelection();
    }
}

void AssemblyWindow::handleTreeSelection() {
    const QList<QTreeWidgetItem*> selected = tree_->selectedItems();
    if (selected.isEmpty()) {
        clearSelection();
        return;
    }
    QTreeWidgetItem* item = selected.first();
    const int kind = item->data(0, kKindRole).toInt();
    const std::string id = item->data(0, kIdRole).toString().toStdString();
    if (jointToolActive_ && kind == kComponentKind) {
        // Tree click while the joint tool is active picks the component's
        // local coordinate system (LCS reference).
        useLcsPick(id);
        return;
    }
    if (kind == kComponentKind) {
        selectComponent(id);
    } else if (kind == kJointKind) {
        selectJoint(id);
    } else {
        clearSelection();
    }
}

void AssemblyWindow::selectComponent(const std::string& componentId) {
    if (!document_.componentById(componentId).isOk()) {
        return;
    }
    selectionKind_ = SelectionKind::Component;
    selectedComponentId_ = componentId;
    selectedJointId_.clear();
    document_.setSelectedComponentId(componentId);
    document_.setSelectedJointId(std::string());

    if (viewer_) {
        for (const assembly::AssemblyComponent& component : document_.components()) {
            viewer_->scene().setHighlighted(component.id, component.id == componentId);
        }
    }
    {
        const QSignalBlocker blocker(tree_);
        tree_->clearSelection();
        for (int i = 0; i < componentsGroup_->childCount(); ++i) {
            QTreeWidgetItem* item = componentsGroup_->child(i);
            if (item->data(0, kIdRole).toString().toStdString() == componentId) {
                item->setSelected(true);
                tree_->setCurrentItem(item);
                break;
            }
        }
    }
    refreshPropertyPanel();
    syncMoveManip();
}

void AssemblyWindow::selectJoint(const std::string& jointId) {
    if (!document_.jointById(jointId).isOk()) {
        return;
    }
    selectionKind_ = SelectionKind::Joint;
    selectedJointId_ = jointId;
    selectedComponentId_.clear();
    document_.setSelectedJointId(jointId);
    document_.setSelectedComponentId(std::string());
    if (viewer_) {
        for (const assembly::AssemblyComponent& component : document_.components()) {
            viewer_->scene().setHighlighted(component.id, false);
        }
    }
    refreshPropertyPanel();
    syncMoveManip();
}

void AssemblyWindow::clearSelection() {
    selectionKind_ = SelectionKind::None;
    selectedComponentId_.clear();
    selectedJointId_.clear();
    document_.setSelectedComponentId(std::string());
    document_.setSelectedJointId(std::string());
    if (viewer_) {
        for (const assembly::AssemblyComponent& component : document_.components()) {
            viewer_->scene().setHighlighted(component.id, false);
        }
    }
    {
        const QSignalBlocker blocker(tree_);
        tree_->clearSelection();
    }
    refreshPropertyPanel();
    syncMoveManip();
}

// ---------------------------------------------------------------------------
// Property panel
// ---------------------------------------------------------------------------

QWidget* AssemblyWindow::buildPropertyPanel() {
    auto* panel = new QWidget(this);
    auto* layout = new QVBoxLayout(panel);

    componentGroup_ = new QGroupBox(tr("Компонент"), panel);
    auto* componentForm = new QFormLayout(componentGroup_);

    nameEdit_ = new QLineEdit(componentGroup_);
    componentForm->addRow(tr("Имя"), nameEdit_);
    connect(nameEdit_, &QLineEdit::editingFinished, this,
            [this]() { applyPanelName(); });

    sourceLabel_ = new QLabel(componentGroup_);
    sourceLabel_->setWordWrap(true);
    componentForm->addRow(tr("Файл"), sourceLabel_);

    groundedCheck_ = new QCheckBox(tr("Закреплена"), componentGroup_);
    componentForm->addRow(QString(), groundedCheck_);
    connect(groundedCheck_, &QCheckBox::toggled, this, [this]() { applyPanelFlags(); });

    visibleCheck_ = new QCheckBox(tr("Видимая"), componentGroup_);
    componentForm->addRow(QString(), visibleCheck_);
    connect(visibleCheck_, &QCheckBox::toggled, this, [this]() { applyPanelFlags(); });

    // Model units are meters; the UI is millimeters everywhere (Units.hpp).
    const QString positionLabels[3] = {tr("X"), tr("Y"), tr("Z")};
    for (int i = 0; i < 3; ++i) {
        positionSpins_[i] = new QDoubleSpinBox(componentGroup_);
        positionSpins_[i]->setRange(-1.0e7, 1.0e7);
        positionSpins_[i]->setDecimals(3);
        positionSpins_[i]->setSingleStep(1.0);
        positionSpins_[i]->setSuffix(tr(" мм"));
        componentForm->addRow(positionLabels[i], positionSpins_[i]);
        connect(positionSpins_[i], &QDoubleSpinBox::editingFinished, this,
                [this]() { applyPanelPlacement(); });
    }
    const QString rotationLabels[3] = {tr("Поворот X, °"), tr("Поворот Y, °"),
                                       tr("Поворот Z, °")};
    for (int i = 0; i < 3; ++i) {
        rotationSpins_[i] = new QDoubleSpinBox(componentGroup_);
        rotationSpins_[i]->setRange(-360.0, 360.0);
        rotationSpins_[i]->setDecimals(2);
        rotationSpins_[i]->setSingleStep(1.0);
        componentForm->addRow(rotationLabels[i], rotationSpins_[i]);
        connect(rotationSpins_[i], &QDoubleSpinBox::editingFinished, this,
                [this]() { applyPanelPlacement(); });
    }

    dofLabel_ = new QLabel(componentGroup_);
    componentForm->addRow(tr("Статус"), dofLabel_);

    layout->addWidget(componentGroup_);

    jointGroup_ = new QGroupBox(tr("Сопряжение"), panel);
    auto* jointForm = new QFormLayout(jointGroup_);
    jointTypeLabel_ = new QLabel(jointGroup_);
    jointForm->addRow(tr("Тип"), jointTypeLabel_);
    jointStatusLabel_ = new QLabel(jointGroup_);
    jointStatusLabel_->setWordWrap(true);
    jointForm->addRow(tr("Статус"), jointStatusLabel_);
    layout->addWidget(jointGroup_);

    auto* diagnosticsBox = new QGroupBox(tr("Диагностика"), panel);
    auto* diagnosticsLayout = new QVBoxLayout(diagnosticsBox);
    diagnosticsView_ = new QPlainTextEdit(diagnosticsBox);
    diagnosticsView_->setReadOnly(true);
    diagnosticsLayout->addWidget(diagnosticsView_);
    layout->addWidget(diagnosticsBox, 1);

    refreshPropertyPanel();
    return panel;
}

void AssemblyWindow::refreshPropertyPanel() {
    if (!componentGroup_) {
        return;
    }
    updatingPanel_ = true;

    const assembly::AssemblyComponent* component = selectedComponentConst();
    componentGroup_->setEnabled(component != nullptr);
    if (component) {
        nameEdit_->setText(QString::fromStdString(component->name));
        sourceLabel_->setText(QString::fromStdString(component->source.filePath));
        groundedCheck_->setChecked(component->isGrounded);
        visibleCheck_->setChecked(component->isVisible);
        positionSpins_[0]->setValue(
            cadnext::toMillimeters(component->placement.translation.x));
        positionSpins_[1]->setValue(
            cadnext::toMillimeters(component->placement.translation.y));
        positionSpins_[2]->setValue(
            cadnext::toMillimeters(component->placement.translation.z));
        const cadnext::Vector3 euler =
            eulerDegreesFromQuaternion(component->placement.rotation);
        rotationSpins_[0]->setValue(euler.x);
        rotationSpins_[1]->setValue(euler.y);
        rotationSpins_[2]->setValue(euler.z);
        const bool editable = !component->isGrounded;
        for (int i = 0; i < 3; ++i) {
            positionSpins_[i]->setEnabled(editable);
            rotationSpins_[i]->setEnabled(editable);
        }

        QString status;
        const auto dofIt = lastRecompute_.dofByComponent.find(component->id);
        if (component->isGrounded) {
            status = tr("Закреплена (0 DOF)");
        } else if (dofIt != lastRecompute_.dofByComponent.end()) {
            const auto& info = dofIt->second;
            if (info.conflict) {
                status = tr("Конфликт ограничений");
            } else if (info.overconstrained) {
                status = tr("Переопределена");
            } else if (info.remainingDof == 0) {
                status = tr("Полностью определена");
            } else if (info.remainingDof > 0) {
                status = tr("Недоопределена: %1 DOF").arg(info.remainingDof);
            } else if (!info.inGroundedGroup) {
                status = tr("Группа без неподвижного основания");
            } else {
                status = tr("Свободна");
            }
        } else {
            status = tr("Свободна (6 DOF)");
        }
        dofLabel_->setText(status);
    } else {
        nameEdit_->clear();
        sourceLabel_->clear();
        dofLabel_->clear();
    }

    const assembly::AssemblyJoint* joint = nullptr;
    if (selectionKind_ == SelectionKind::Joint) {
        for (const assembly::AssemblyJoint& candidate : document_.joints()) {
            if (candidate.id == selectedJointId_) {
                joint = &candidate;
                break;
            }
        }
    }
    jointGroup_->setEnabled(joint != nullptr);
    if (joint) {
        jointTypeLabel_->setText(jointTypeText(joint->type));
        QString status = jointStatusText(joint->solveState.status);
        if (!joint->solveState.message.empty()) {
            status += QStringLiteral(" — ") +
                      QString::fromStdString(joint->solveState.message);
        }
        jointStatusLabel_->setText(status);
    } else {
        jointTypeLabel_->clear();
        jointStatusLabel_->clear();
    }

    updatingPanel_ = false;
}

void AssemblyWindow::applyPanelName() {
    if (updatingPanel_) {
        return;
    }
    assembly::AssemblyComponent* component = selectedComponent();
    if (!component) {
        return;
    }
    const std::string newName = nameEdit_->text().trimmed().toStdString();
    if (newName.empty() || newName == component->name) {
        return;
    }
    component->name = newName;
    markDirty();
    rebuildTree();
    selectComponent(component->id);
}

void AssemblyWindow::applyPanelFlags() {
    if (updatingPanel_) {
        return;
    }
    assembly::AssemblyComponent* component = selectedComponent();
    if (!component) {
        return;
    }
    bool changed = false;
    if (component->isGrounded != groundedCheck_->isChecked()) {
        component->isGrounded = groundedCheck_->isChecked();
        changed = true;
    }
    if (component->isVisible != visibleCheck_->isChecked()) {
        component->isVisible = visibleCheck_->isChecked();
        refreshComponentVisual(*component);
        changed = true;
    }
    if (changed) {
        markDirty();
        rebuildTree();
        selectComponent(component->id);
        runRecompute();
    }
}

void AssemblyWindow::applyPanelPlacement() {
    if (updatingPanel_) {
        return;
    }
    assembly::AssemblyComponent* component = selectedComponent();
    if (!component || component->isGrounded) {
        return;
    }
    assembly::Placement placement;
    placement.translation = {cadnext::fromMillimeters(positionSpins_[0]->value()),
                             cadnext::fromMillimeters(positionSpins_[1]->value()),
                             cadnext::fromMillimeters(positionSpins_[2]->value())};
    placement.rotation = quaternionFromEulerDegrees(
        rotationSpins_[0]->value(), rotationSpins_[1]->value(),
        rotationSpins_[2]->value());

    const bool samePosition = assembly::nearlyEqual(
        placement.translation, component->placement.translation, 1.0e-9);
    const cadnext::Vector3 currentEuler =
        eulerDegreesFromQuaternion(component->placement.rotation);
    const cadnext::Vector3 newEuler = eulerDegreesFromQuaternion(placement.rotation);
    const bool sameRotation = assembly::nearlyEqual(currentEuler, newEuler, 1.0e-6);
    if (samePosition && sameRotation) {
        return;
    }

    component->placement = placement;
    markDirty();
    runRecompute();
}

// ---------------------------------------------------------------------------
// Joint tool
// ---------------------------------------------------------------------------

std::string AssemblyWindow::nextJointName(assembly::JointType type) const {
    return jointTypeText(type).toStdString() + " " + std::to_string(nextJointNumber_);
}

void AssemblyWindow::startJointTool(assembly::JointType type) {
    if (document_.components().size() < 2) {
        statusBar()->showMessage(
            tr("Для сопряжения нужны минимум два компонента"), 5000);
        return;
    }
    cancelJointTool();
    setMoveModeActive(false);
    jointToolActive_ = true;
    jointToolType_ = type;
    firstPick_ = {};
    secondPick_ = {};
    enterJointPickVisuals();
    statusBar()->showMessage(
        tr("%1: выберите грань, ребро или вершину первой детали (клик по "
           "компоненту в дереве — его ЛСК, Esc — отмена)")
            .arg(jointTypeText(type)));
}

void AssemblyWindow::enterJointPickVisuals() {
    if (!viewer_) {
        return;
    }
    worldEdgesByComponent_.clear();
    for (const assembly::AssemblyComponent& component : document_.components()) {
        if (!component.isVisible || component.isSuppressed) {
            continue;
        }
        const AssemblyPartGeometry& geometry =
            partLoader_->geometryForSource(component.source);
        if (!geometry.valid) {
            continue;
        }
        // World-space edges for proximity picking + highlight.
        std::vector<kernel::EdgeReference> worldEdges;
        worldEdges.reserve(geometry.topology.edges.size());
        for (const kernel::EdgeReference& edge : geometry.topology.edges) {
            kernel::EdgeReference world = edgeTransformedBy(edge, component.placement);
            world.bodyId = component.id;
            worldEdges.push_back(std::move(world));
        }
        viewer_->scene().setBodyEdges(component.id, worldEdges);
        worldEdgesByComponent_[component.id] = std::move(worldEdges);

        // Vertex markers reuse the attachment-marker path (local
        // coordinates inside the body node, so they track placements).
        std::vector<AttachmentPoint> vertexMarkers;
        vertexMarkers.reserve(geometry.topology.vertices.size());
        for (const kernel::VertexReference& vertex : geometry.topology.vertices) {
            AttachmentPoint marker;
            marker.id = vertex.vertexId;
            marker.name = vertex.vertexId;
            marker.localPosition = vertex.position;
            vertexMarkers.push_back(std::move(marker));
        }
        viewer_->scene().addOrUpdateAttachmentPointMarkers(component.id, vertexMarkers);
    }
}

void AssemblyWindow::leaveJointPickVisuals() {
    if (!viewer_) {
        return;
    }
    viewer_->scene().clearBodyFaces();
    viewer_->scene().clearBodyEdges();
    viewer_->scene().clearBodyEdgeHighlight();
    viewer_->scene().clearAttachmentPointMarkers();
    viewer_->scene().clearSelectedAttachmentPoint();
    for (const assembly::AssemblyComponent& component : document_.components()) {
        viewer_->scene().setHighlighted(component.id, false);
    }
    worldEdgesByComponent_.clear();
}

void AssemblyWindow::cancelJointTool() {
    if (!jointToolActive_) {
        return;
    }
    jointToolActive_ = false;
    if (previewActive_) {
        if (assembly::AssemblyComponent* child =
                document_.mutableComponentById(secondPick_.componentId)) {
            child->placement = previewOriginalPlacement_;
        }
        previewActive_ = false;
        applyPlacementsToScene();
    }
    firstPick_ = {};
    secondPick_ = {};
    leaveJointPickVisuals();
    statusBar()->showMessage(tr("Создание сопряжения отменено"), 3000);
}

AssemblyWindow::JointPickSelection AssemblyWindow::resolveJointPick(
    const viewer::ViewportPickTarget& target) {
    JointPickSelection pick;
    if (target.objectId.empty()) {
        return pick;
    }
    const auto component = document_.componentById(target.objectId);
    if (!component.isOk()) {
        return pick;
    }
    const AssemblyPartGeometry& geometry =
        partLoader_->geometryForSource(component.value().source);
    if (!geometry.valid) {
        return pick;
    }
    pick.componentId = target.objectId;

    // Vertex markers win (explicit small targets).
    if (target.isAttachmentPoint()) {
        for (const kernel::VertexReference& vertex : geometry.topology.vertices) {
            if (vertex.vertexId == target.attachmentPointId) {
                pick.reference = assembly::GeometryReferenceResolver::makeVertexReference(
                    {pick.componentId}, vertex);
                pick.valid = true;
                break;
            }
        }
        if (pick.valid) {
            pick.label = tr("%1 — %2").arg(
                QString::fromStdString(component.value().name),
                referenceKindText(pick.reference.kind));
            return pick;
        }
    }

    // Edge if the click landed near one (world-space proximity, same
    // tolerance policy as the part editor).
    if (target.hasWorldPoint) {
        const auto edgesIt = worldEdgesByComponent_.find(pick.componentId);
        if (edgesIt != worldEdgesByComponent_.end() && !edgesIt->second.empty()) {
            const kernel::EdgeReference* best = nullptr;
            double bestDistance = std::numeric_limits<double>::infinity();
            for (const kernel::EdgeReference& edge : edgesIt->second) {
                std::vector<cadnext::Vector3> points = edge.previewPolyline;
                if (points.size() < 2) {
                    points = {edge.start, edge.end};
                }
                for (size_t i = 1; i < points.size(); ++i) {
                    const double distance = distancePointToSegment(
                        target.worldPoint, points[i - 1], points[i]);
                    if (distance < bestDistance) {
                        bestDistance = distance;
                        best = &edge;
                    }
                }
            }
            if (best && bestDistance <= 0.02) {
                for (const kernel::EdgeReference& localEdge : geometry.topology.edges) {
                    if (localEdge.edgeId == best->edgeId) {
                        pick.reference =
                            assembly::GeometryReferenceResolver::makeEdgeReference(
                                {pick.componentId}, localEdge);
                        pick.valid = true;
                        break;
                    }
                }
                if (pick.valid) {
                    pick.label = tr("%1 — %2").arg(
                        QString::fromStdString(component.value().name),
                        referenceKindText(pick.reference.kind));
                    return pick;
                }
            }
        }
    }

    // Face from the mesh pick.
    if (target.isBodyFace()) {
        for (const kernel::FaceReference& face : geometry.topology.faces) {
            if (face.faceId == target.faceId) {
                pick.reference = assembly::GeometryReferenceResolver::makeFaceReference(
                    {pick.componentId}, face);
                pick.valid = true;
                break;
            }
        }
        if (pick.valid) {
            pick.label = tr("%1 — %2").arg(
                QString::fromStdString(component.value().name),
                referenceKindText(pick.reference.kind));
            return pick;
        }
    }
    return pick;
}

void AssemblyWindow::useLcsPick(const std::string& componentId) {
    const auto component = document_.componentById(componentId);
    if (!component.isOk()) {
        return;
    }
    JointPickSelection pick;
    pick.valid = true;
    pick.componentId = componentId;
    pick.reference =
        assembly::GeometryReferenceResolver::makeLcsReference({componentId});
    pick.label = tr("%1 — %2").arg(QString::fromStdString(component.value().name),
                                   referenceKindText(pick.reference.kind));
    acceptJointPick(pick);
}

void AssemblyWindow::highlightJointPick(const JointPickSelection& pick) {
    if (!viewer_ || !pick.valid) {
        return;
    }
    const auto component = document_.componentById(pick.componentId);
    if (!component.isOk()) {
        return;
    }
    switch (pick.reference.kind) {
    case assembly::GeometryReferenceKind::PlanarFace:
    case assembly::GeometryReferenceKind::CylindricalFace: {
        const AssemblyPartGeometry& geometry =
            partLoader_->geometryForSource(component.value().source);
        for (const kernel::FaceReference& face : geometry.topology.faces) {
            if (face.faceId == pick.reference.persistentTopologyId) {
                kernel::FaceReference world =
                    faceTransformedBy(face, component.value().placement);
                world.bodyId = pick.componentId;
                viewer_->scene().setBodyFaces(pick.componentId, {world});
                viewer_->scene().setSelectedBodyFace(pick.componentId, world.faceId);
                break;
            }
        }
        break;
    }
    case assembly::GeometryReferenceKind::LinearEdge:
    case assembly::GeometryReferenceKind::CircularEdge:
        viewer_->scene().highlightBodyEdge(pick.componentId,
                                           pick.reference.persistentTopologyId);
        break;
    case assembly::GeometryReferenceKind::Vertex:
        viewer_->scene().setSelectedAttachmentPoint(
            pick.componentId, pick.reference.persistentTopologyId);
        break;
    case assembly::GeometryReferenceKind::LocalCoordinateSystem:
        viewer_->scene().setHighlighted(pick.componentId, true);
        break;
    }
}

void AssemblyWindow::handleJointPick(const viewer::ViewportPickTarget& target) {
    const JointPickSelection pick = resolveJointPick(target);
    if (!pick.valid) {
        statusBar()->showMessage(
            tr("Выберите грань, ребро или вершину детали"), 4000);
        return;
    }
    acceptJointPick(pick);
}

void AssemblyWindow::acceptJointPick(const JointPickSelection& pick) {
    if (!jointToolActive_) {
        return;
    }
    if (!firstPick_.valid) {
        firstPick_ = pick;
        highlightJointPick(firstPick_);
        statusBar()->showMessage(
            tr("Первый элемент: %1. Теперь выберите элемент второй детали")
                .arg(firstPick_.label));
        return;
    }
    if (pick.componentId == firstPick_.componentId) {
        statusBar()->showMessage(
            tr("Второй элемент должен принадлежать другой детали"), 4000);
        return;
    }
    secondPick_ = pick;
    highlightJointPick(secondPick_);
    finishJointTool();
}

void AssemblyWindow::applyJointPreview(assembly::JointAlignment alignment,
                                       double offsetMeters, double angleRadians) {
    const auto parent = document_.componentById(firstPick_.componentId);
    assembly::AssemblyComponent* child =
        document_.mutableComponentById(secondPick_.componentId);
    if (!parent.isOk() || !child) {
        return;
    }

    assembly::DirectPlacementSolver::Input input;
    input.type = jointToolType_;
    input.alignment = alignment;
    input.offsetMeters = offsetMeters;
    input.angleRadians = angleRadians;
    input.parentPlacement = parent.value().placement;
    input.parentLocalFrame = firstPick_.reference.fallbackFrame;
    input.childPlacement =
        previewActive_ ? previewOriginalPlacement_ : child->placement;
    input.childLocalFrame = secondPick_.reference.fallbackFrame;

    if (!previewActive_) {
        previewOriginalPlacement_ = child->placement;
        previewActive_ = true;
    }
    child->placement = assembly::DirectPlacementSolver::solveChildPlacement(input);
    applyPlacementsToScene();
}

void AssemblyWindow::finishJointTool() {
    // Preview the snap immediately with the dialog's initial parameters.
    AssemblyJointDialog dialog(jointToolType_, firstPick_.label, secondPick_.label,
                               this);
    connect(&dialog, &AssemblyJointDialog::parametersChanged, this, [this, &dialog]() {
        applyJointPreview(dialog.alignment(), dialog.offsetMeters(),
                          dialog.angleRadians());
    });
    applyJointPreview(dialog.alignment(), dialog.offsetMeters(), dialog.angleRadians());

    const int result = dialog.exec();
    if (result != QDialog::Accepted) {
        cancelJointTool();
        return;
    }

    assembly::AssemblyJoint joint;
    joint.id = "joint-" + std::to_string(nextJointNumber_);
    joint.name = nextJointName(jointToolType_);
    ++nextJointNumber_;
    joint.type = jointToolType_;
    joint.first = firstPick_.reference;
    joint.second = secondPick_.reference;
    joint.alignment = dialog.alignment();
    joint.offsetMeters = dialog.offsetMeters();
    joint.angleRadians = dialog.angleRadians();
    joint.lockRotation = dialog.lockRotation();

    if (jointToolType_ == assembly::JointType::Rigid) {
        // Fix the mutual position exactly as previewed/confirmed.
        const auto parent = document_.componentById(firstPick_.componentId);
        const auto child = document_.componentById(secondPick_.componentId);
        if (parent.isOk() && child.isOk()) {
            joint.hasCapturedRelativePlacement = true;
            joint.capturedRelativePlacement =
                parent.value().placement.inverse().compose(child.value().placement);
        }
    }

    document_.addJoint(joint);

    jointToolActive_ = false;
    previewActive_ = false;
    firstPick_ = {};
    secondPick_ = {};
    leaveJointPickVisuals();

    markDirty();
    rebuildTree();
    selectJoint(joint.id);
    runRecompute();
    statusBar()->showMessage(
        tr("Сопряжение «%1» создано").arg(QString::fromStdString(joint.name)), 5000);
}

} // namespace cadnext::gui
