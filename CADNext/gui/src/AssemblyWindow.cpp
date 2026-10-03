#include "cadnext/gui/AssemblyStepExchange.hpp"
#include "cadnext/gui/ImportProgressDialog.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/AssemblyWindow.hpp"

#include <algorithm>
#include <cmath>
#include <memory>
#include <optional>
#include <set>

#include <QAction>
#include <QCheckBox>
#include <QCloseEvent>
#include <QDockWidget>
#include <QDoubleSpinBox>
#include <QApplication>
#include <QCoreApplication>
#include <QDir>
#include <QFileDialog>
#include <QFileInfo>
#include <QStringList>
#include <QFileInfo>
#include <QFormLayout>
#include <QGroupBox>
#include <QHeaderView>
#include <QLabel>
#include <QInputDialog>
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

// Euler display conversions live in the assembly core
// (eulerXYZDegreesFromQuaternion / quaternionFromEulerXYZDegrees) so they
// are unit-tested; the window only wires them to the spin boxes.

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
    fileMenu->addSeparator();
    fileMenu->addAction(tr("Импорт сборки (STEP, Parasolid, SOLIDWORKS)…"), this, [this]() { importStepAssembly(); });
    fileMenu->addAction(tr("Экспорт сборки (STEP, Parasolid, КОМПАС-3D)…"), this, [this]() { exportStepAssembly(); });

    QMenu* editMenu = menuBar()->addMenu(tr("Правка"));
    undoAction_ = editMenu->addAction(tr("Отменить"), QKeySequence::Undo, this,
                                      [this]() { undo(); });
    redoAction_ = editMenu->addAction(tr("Повторить"), QKeySequence::Redo, this,
                                      [this]() { redo(); });
    updateUndoRedoActions();

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
    clearUndoHistory();
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
        tr("Сборки (*.cadasm *.sldasm *.SLDASM *.step *.stp *.STEP *.STP *.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin);;"
           "Сборки CADNext (*.cadasm);;SOLIDWORKS (*.sldasm *.SLDASM);;STEP (*.step *.stp *.STEP *.STP);;"
           "Parasolid (*.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin);;Все файлы (*)"));
    if (path.isEmpty()) {
        return;
    }
    // Another system's assembly is imported into CADNext files first, then opened.
    if (QFileInfo(path).suffix().compare(QLatin1String("cadasm"), Qt::CaseInsensitive) != 0) {
        importStepAssemblyFrom(path, false);
        return;
    }
    loadFromPath(path);
}

void AssemblyWindow::importStepAssembly() {
    if (!maybeSave()) {
        return;
    }
    const QString stepPath = QFileDialog::getOpenFileName(
        this, tr("Импорт сборки"), QString(),
        tr("Сборки STEP, Parasolid, SOLIDWORKS и КОМПАС-3D (*.step *.stp *.STEP *.STP *.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin *.sldasm *.SLDASM *.a3d *.A3D);;"
           "STEP (*.step *.stp *.STEP *.STP);;Parasolid (*.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin);;"
           "SOLIDWORKS (*.sldasm *.SLDASM);;КОМПАС-3D (*.a3d *.A3D);;Все файлы (*)"));
    if (stepPath.isEmpty()) {
        return;
    }
    importStepAssemblyFrom(stepPath, false);
}

void AssemblyWindow::importStepAssemblyFrom(const QString& stepPath, bool askToSave) {
    if (askToSave && !maybeSave()) {
        return;
    }
    importAsCadnextFiles(stepPath, [this](const QString& top) { loadFromPath(top); });
}

void AssemblyWindow::importAsCadnextFiles(const QString& path, std::function<void(const QString&)> then) {
    const QFileInfo source(path);
    const QString suffix = source.suffix().toLower();
    const bool parasolid = suffix == QLatin1String("x_t") || suffix == QLatin1String("x_b") ||
                           suffix == QLatin1String("xmt_txt") || suffix == QLatin1String("xmt_bin");
    const bool solidWorks = suffix == QLatin1String("sldasm") || suffix == QLatin1String("sldprt");
    const bool step = suffix == QLatin1String("step") || suffix == QLatin1String("stp");
    const bool kompas = suffix == QLatin1String("a3d") || suffix == QLatin1String("m3d");
    if (!parasolid && !solidWorks && !step && !kompas) {
        QMessageBox::warning(this, tr("Импорт"),
                             tr("Формат файла %1 здесь не принимается. Окно сборки открывает .cadasm, вставляет "
                                ".cadnext и .uavpart и переводит в них STEP (.step, .stp), Parasolid (.x_t, .x_b), "
                                "SOLIDWORKS (.sldasm, .sldprt) и КОМПАС-3D (.a3d, .m3d).").arg(source.fileName()));
        return;
    }
    const QString title = parasolid    ? tr("Импорт Parasolid")
                          : solidWorks ? tr("Импорт SOLIDWORKS")
                          : kompas     ? tr("Импорт КОМПАС-3D")
                                       : tr("Импорт STEP");
    QString configuration;
    if (suffix == QStringLiteral("sldprt")) {
        std::vector<SolidWorksConfiguration> configurations;
        QString error;
        if (!readSolidWorksPartConfigurations(path, configurations, error)) {
            QMessageBox::warning(this, title, error);
            return;
        }
        if (configurations.size() > 1) {
            QStringList names;
            for (const auto& item : configurations)
                names << (item.name.isEmpty() ? tr("Конфигурация %1").arg(item.id) : item.name);
            bool accepted = false;
            const QString choice = QInputDialog::getItem(this, title,
                tr("Конфигурация детали %1:").arg(source.fileName()), names, 0, false, &accepted);
            if (!accepted) return;
            configuration = QStringLiteral("Config-") + configurations[std::size_t(names.indexOf(choice))].id;
        }
    }
    // The parts and assemblies go into a new folder of their own next to the file — a received
    // assembly can hold hundreds of parts, and they should not spill into a working folder; an earlier
    // import's folder is left as it is. Asked only where nothing can be written next to the file (the
    // macOS folder panel shows no title, so it is said first what it is for).
    QString parent = source.absolutePath();
    if (!QFileInfo(parent).isWritable()) {
        QMessageBox::information(this, title,
                                 tr("В папку с файлом %1 записать нельзя. Выберите папку, в которой будут созданы "
                                    "детали и сборки CADNext.").arg(source.fileName()));
        parent = QFileDialog::getExistingDirectory(this, tr("Куда сохранить детали и сборки"), QDir::homePath());
        if (parent.isEmpty()) {
            statusBar()->showMessage(tr("Импорт отменён"), 5000);
            return;
        }
    }
    QString folder = QDir(parent).filePath(source.completeBaseName() + tr(" (CADNext)"));
    for (int n = 2; QFileInfo::exists(folder); ++n)
        folder = QDir(parent).filePath(source.completeBaseName() + tr(" (CADNext %1)").arg(n));

    // The reading and building on a thread of their own (their own kernel and files only); the
    // window shows each part as it goes and keeps a short outcome at the end.
    struct Outcome {
        std::optional<Result<std::string>> top;
        AssemblyExchangeReport report;
        std::vector<DetachedPartGeometry> parts; // the written parts, meshed for the viewer
    };
    const auto outcome = std::make_shared<Outcome>();
    auto* dialog = new ImportProgressDialog(title, this);
    const ImportProgress* progress = &dialog->progress();
    const std::string from = path.toStdString(), into = folder.toStdString();
    statusBar()->showMessage(tr("Импорт %1…").arg(source.fileName()));
    dialog->run(
        [outcome, progress, from, into, parasolid, solidWorks, kompas, configuration] {
            outcome->top = parasolid    ? importParasolidXtAsAssembly(from, into, outcome->report, progress)
                           : solidWorks ? importSolidWorksAsAssembly(from, into, outcome->report, progress, configuration.toStdString())
                           : kompas     ? importKompasAsAssembly(from, into, outcome->report, progress)
                                        : importStepAsAssembly(from, into, outcome->report, progress);
            if (!outcome->top->isOk()) return;
            // Meshed here too, so that opening the result costs the UI thread nothing heavy.
            const auto written = assembly::AssemblySerializer::loadFromFile(outcome->top->value());
            if (!written.isOk()) return;
            std::vector<assembly::PartReference> sources;
            std::set<std::string> seen;
            for (const assembly::AssemblyComponent& component : written.value().components())
                if (seen.insert(component.source.filePath + '\n' + component.source.bodyId).second)
                    sources.push_back(component.source);
            outcome->parts = AssemblyPartLoader::loadDetached(sources, progress);
        },
        [this, dialog, outcome, folder, then = std::move(then)] {
            const Result<std::string>& top = *outcome->top;
            if (!top.isOk()) {
                // The folder was made for this import alone: nothing of a stopped or failed one is kept.
                QDir(folder).removeRecursively();
                const bool stopped = dialog->progress().cancelled();
                dialog->finish(stopped ? tr("Импорт остановлен") : tr("Импорт не удался"),
                               stopped ? QStringList{} : QStringList{QString::fromStdString(top.error().message)}, true);
                statusBar()->clearMessage();
                return;
            }
            if (dialog->progress().cancelled()) {
                // Stopped while meshing: the files are complete, the parts load when shown.
                outcome->parts.clear();
            }
            partLoader_->adopt(std::move(outcome->parts));
            const AssemblyExchangeReport& report = outcome->report;
            QStringList lines;
            lines << tr("Деталей: %1, вхождений: %2").arg(report.parts).arg(report.occurrences)
                  << tr("Папка: %1").arg(folder);
            lines << summarizeBuildReport(report.geometry);
            for (const std::string& warning : report.warnings) lines << QString::fromStdString(warning);
            dialog->finish(tr("Готово за %1 с").arg(dialog->elapsedSeconds(), 0, 'f', 0), lines);
            statusBar()->showMessage(tr("Импортировано: %1 деталей, %2 вхождений — в %3")
                                         .arg(report.parts)
                                         .arg(report.occurrences)
                                         .arg(folder),
                                     10000);
            then(QString::fromStdString(top.value()));
        });
}

void AssemblyWindow::exportStepAssembly() {
    // Export reads the assembly the way it is on disk, with its part files: the unsaved state in
    // this window is not what another CAD would receive.
    if (currentFilePath_.isEmpty() || dirty_) {
        const QMessageBox::StandardButton answer = QMessageBox::question(
            this, tr("Экспорт сборки"),
            tr("Экспорт берёт сохранённый файл сборки. Сохранить сборку сейчас?"),
            QMessageBox::Save | QMessageBox::Cancel);
        if (answer != QMessageBox::Save || !saveAssembly()) {
            return;
        }
    }
    const QFileInfo current(currentFilePath_);
    QString selectedFilter;
    const QString ap214 = tr("STEP AP214 — открывается в любой CAD (*.step *.stp)");
    const QString ap242 = tr("STEP AP242 — современный стандарт (*.step *.stp)");
    const QString xtText = tr("Parasolid, текст — SOLIDWORKS, Solid Edge, NX, КОМПАС-3D, AutoCAD (*.x_t)");
    const QString xtBinary = tr("Parasolid, двоичный (*.x_b)");
    const QString kompas = tr("КОМПАС-3D, сборка и её детали (*.a3d)");
    QString stepPath = QFileDialog::getSaveFileName(
        this, tr("Экспорт сборки"),
        current.absoluteDir().filePath(current.completeBaseName() + QStringLiteral(".step")),
        QStringList{ap214, ap242, xtText, xtBinary, kompas}.join(QStringLiteral(";;")), &selectedFilter);
    if (stepPath.isEmpty()) {
        return;
    }
    QString suffix = QFileInfo(stepPath).suffix().toLower();
    if (selectedFilter == kompas || suffix == QLatin1String("a3d")) {
        if (suffix != QLatin1String("a3d")) stepPath += QStringLiteral(".a3d");
        QApplication::setOverrideCursor(Qt::WaitCursor);
        const Result<AssemblyExchangeReport> exported = exportAssemblyToKompas(currentFilePath_.toStdString(), stepPath.toStdString());
        QApplication::restoreOverrideCursor();
        const QString title = tr("Экспорт сборки в КОМПАС-3D");
        if (!exported.isOk()) {
            QMessageBox::warning(this, title, QString::fromStdString(exported.error().message));
            return;
        }
        const AssemblyExchangeReport& report = exported.value();
        const QString summary = tr("Записано: %1 деталей, %2 вхождений — %3").arg(report.parts).arg(report.occurrences).arg(stepPath);
        statusBar()->showMessage(summary, 10000);
        QStringList lines;
        for (const std::string& warning : report.warnings) lines << QString::fromStdString(warning);
        if (!lines.isEmpty()) QMessageBox::information(this, title, summary + QStringLiteral("\n\n") + lines.join(QStringLiteral("\n")));
        return;
    }
    const bool parasolid = selectedFilter == xtText || selectedFilter == xtBinary ||
                           suffix == QLatin1String("x_t") || suffix == QLatin1String("x_b");
    const bool binary = parasolid && (selectedFilter == xtBinary || suffix == QLatin1String("x_b"));
    const QString wanted = parasolid ? (binary ? QStringLiteral("x_b") : QStringLiteral("x_t")) : QStringLiteral("step");
    if (parasolid ? suffix != wanted : (suffix != QStringLiteral("step") && suffix != QStringLiteral("stp"))) {
        stepPath += QLatin1Char('.') + wanted;
    }
    const QString title = parasolid ? tr("Экспорт сборки в Parasolid") : tr("Экспорт сборки в STEP");
    const kernel::StepSchema schema =
        selectedFilter == ap242 ? kernel::StepSchema::AP242 : kernel::StepSchema::AP214;
    QApplication::setOverrideCursor(Qt::WaitCursor);
    const Result<AssemblyExchangeReport> exported =
        parasolid ? exportAssemblyToParasolid(currentFilePath_.toStdString(), stepPath.toStdString(),
                                              binary ? ParasolidXtEncoding::Binary : ParasolidXtEncoding::Text)
                  : exportAssemblyToStep(currentFilePath_.toStdString(), stepPath.toStdString(), schema);
    QApplication::restoreOverrideCursor();
    if (!exported.isOk()) {
        QMessageBox::warning(this, title, QString::fromStdString(exported.error().message));
        return;
    }
    const AssemblyExchangeReport& report = exported.value();
    const QString summary = tr("Записано: %1 деталей, %2 сборок, %3 вхождений — %4")
                                .arg(report.parts)
                                .arg(report.assemblies)
                                .arg(report.occurrences)
                                .arg(stepPath);
    statusBar()->showMessage(summary, 10000);
    if (!report.warnings.empty()) {
        QStringList lines;
        for (const std::string& warning : report.warnings) lines << QString::fromStdString(warning);
        QMessageBox::information(this, title,
                                 summary + QStringLiteral("\n\n") + lines.join(QStringLiteral("\n")));
    }
}

void AssemblyWindow::loadFromPath(const QString& path) {
    // Not a CADNext assembly: imported first (or told why not), never parsed as one.
    if (QFileInfo(path).suffix().compare(QLatin1String("cadasm"), Qt::CaseInsensitive) != 0) {
        importStepAssemblyFrom(path);
        return;
    }
    const Result<assembly::AssemblyDocument> loaded =
        assembly::AssemblySerializer::loadFromFile(path.toStdString());
    if (!loaded.isOk()) {
        QMessageBox::warning(this, tr("Не удалось открыть сборку"),
                             QString::fromStdString(loaded.error().message));
        return;
    }
    // Parts not cached yet are loaded — replayed, meshed — on a thread of their own first; the UI
    // thread then only takes them in (seconds against tens of milliseconds for the NIST MTC box).
    std::vector<assembly::PartReference> missing = partLoader_->uncachedSources(loaded.value());
    if (missing.empty()) {
        showLoadedDocument(loaded.value(), path);
        return;
    }
    auto* dialog = new ImportProgressDialog(tr("Открытие сборки"), this);
    const ImportProgress* progress = &dialog->progress();
    const auto parts = std::make_shared<std::vector<DetachedPartGeometry>>();
    dialog->run([parts, progress, missing = std::move(missing)] { *parts = AssemblyPartLoader::loadDetached(missing, progress); },
                [this, dialog, parts, document = loaded.value(), path] {
                    if (dialog->progress().cancelled()) {
                        dialog->finish(tr("Открытие остановлено"), {}, true);
                        return;
                    }
                    partLoader_->adopt(std::move(*parts));
                    dialog->close();
                    showLoadedDocument(document, path);
                });
}

void AssemblyWindow::showLoadedDocument(const assembly::AssemblyDocument& loaded, const QString& path) {
    cancelJointTool();
    setMoveModeActive(false);
    document_ = loaded;
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

    clearUndoHistory();
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

// ---------------------------------------------------------------------------
// Undo/Redo
// ---------------------------------------------------------------------------

std::string AssemblyWindow::documentSnapshot() const {
    // Empty file path keeps absolute source paths in the snapshot (undo
    // never rewrites them relative).
    return assembly::AssemblySerializer::toJson(document_);
}

void AssemblyWindow::pushUndoSnapshot() {
    pushUndoSnapshot(documentSnapshot());
}

void AssemblyWindow::pushUndoSnapshot(std::string snapshot) {
    constexpr size_t kUndoDepthLimit = 50;
    undoStack_.push_back(std::move(snapshot));
    if (undoStack_.size() > kUndoDepthLimit) {
        undoStack_.erase(undoStack_.begin());
    }
    redoStack_.clear();
    updateUndoRedoActions();
}

void AssemblyWindow::restoreSnapshot(const std::string& snapshot) {
    const Result<assembly::AssemblyDocument> restored =
        assembly::AssemblySerializer::fromJson(snapshot);
    if (!restored.isOk()) {
        statusBar()->showMessage(tr("Не удалось восстановить состояние сборки"), 5000);
        return;
    }
    cancelJointTool();
    setMoveModeActive(false);
    document_ = restored.value();
    clearSelection();
    rebuildSceneFromDocument();
    rebuildTree();
    runRecompute();
    markDirty();
}

void AssemblyWindow::undo() {
    if (undoStack_.empty()) {
        return;
    }
    redoStack_.push_back(documentSnapshot());
    const std::string snapshot = undoStack_.back();
    undoStack_.pop_back();
    restoreSnapshot(snapshot);
    updateUndoRedoActions();
}

void AssemblyWindow::redo() {
    if (redoStack_.empty()) {
        return;
    }
    undoStack_.push_back(documentSnapshot());
    const std::string snapshot = redoStack_.back();
    redoStack_.pop_back();
    restoreSnapshot(snapshot);
    updateUndoRedoActions();
}

void AssemblyWindow::clearUndoHistory() {
    undoStack_.clear();
    redoStack_.clear();
    updateUndoRedoActions();
}

void AssemblyWindow::updateUndoRedoActions() {
    if (undoAction_) {
        undoAction_->setEnabled(!undoStack_.empty());
    }
    if (redoAction_) {
        redoAction_->setEnabled(!redoStack_.empty());
    }
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
        tr("Детали и сборки (*.uavpart *.cadnext *.cadasm *.sldprt *.SLDPRT *.sldasm *.SLDASM *.step *.stp *.STEP *.STP "
           "*.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin);;Детали UAVPart "
           "(*.uavpart);;CAD-документы (*.cadnext);;Подсборки (*.cadasm);;"
           "SOLIDWORKS (*.sldprt *.SLDPRT *.sldasm *.SLDASM);;STEP (*.step *.stp *.STEP *.STP);;"
           "Parasolid (*.x_t *.x_b *.X_T *.X_B *.xmt_txt *.xmt_bin);;Все файлы (*)"));
    if (path.isEmpty()) {
        return;
    }
    // Another system's file becomes CADNext files first: a single part placed where it is goes in as
    // that part, anything more as a subassembly.
    if (const QString suffix = QFileInfo(path).suffix().toLower();
        suffix != QLatin1String("uavpart") && suffix != QLatin1String("cadnext") && suffix != QLatin1String("cadasm")) {
        importAsCadnextFiles(path, [this](const QString& top) {
            QString inserted = top;
            const auto imported = assembly::AssemblySerializer::loadFromFile(top.toStdString());
            if (imported.isOk() && imported.value().components().size() == 1) {
                const assembly::AssemblyComponent& only = imported.value().components().front();
                const assembly::Placement& at = only.placement;
                if (only.source.kind == assembly::PartSourceKind::CadnextDocument && at.translation.x == 0.0 &&
                    at.translation.y == 0.0 && at.translation.z == 0.0 && at.rotation.w == 1.0 &&
                    at.rotation.x == 0.0 && at.rotation.y == 0.0 && at.rotation.z == 0.0) {
                    insertPartFrom(QString::fromStdString(only.source.filePath), only.source.bodyId);
                    return;
                }
            }
            insertPartFrom(inserted);
        });
        return;
    }
    insertPartFrom(path);
}

void AssemblyWindow::insertPartFrom(const QString& path, const std::string& bodyId) {
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
    source.bodyId = bodyId;

    const AssemblyPartGeometry& geometry = partLoader_->geometryForSource(source);
    if (!geometry.valid) {
        QMessageBox::warning(this, tr("Не удалось вставить деталь"), geometry.error);
        return;
    }
    source.contentHash = geometry.contentHash;

    pushUndoSnapshot();

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
    pushUndoSnapshot();
    component->isGrounded = !component->isGrounded;
    markDirty();
    rebuildTree();
    selectComponent(component->id);
    runRecompute();
}

void AssemblyWindow::deleteSelected() {
    cancelJointTool();
    if (selectionKind_ == SelectionKind::Component && !selectedComponentId_.empty()) {
        pushUndoSnapshot();
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
        pushUndoSnapshot();
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
    pushUndoSnapshot();
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
        if (manipComponentId_ == component.id) {
            manipComponentId_.clear(); // the scene detaches the manip itself
        }
        viewer_->scene().removeObjectNode(component.id);
        return;
    }
    const AssemblyPartGeometry& geometry = partLoader_->geometryForSource(component.source);
    if (!geometry.valid) {
        if (manipComponentId_ == component.id) {
            manipComponentId_.clear();
        }
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
            } else if (info.remainingDof == 0) {
                status = tr("Полностью определена");
            } else if (info.remainingDof == 6) {
                status = tr("Свободна (6 DOF)");
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
            assembly::eulerXYZDegreesFromQuaternion(component->placement.rotation);
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
            } else if (info.remainingDof == 0) {
                status = tr("Полностью определена");
            } else if (info.remainingDof == 6) {
                status = tr("Свободна (6 DOF)");
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
    pushUndoSnapshot();
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
    if (component->isGrounded != groundedCheck_->isChecked() ||
        component->isVisible != visibleCheck_->isChecked()) {
        pushUndoSnapshot();
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
    placement.rotation = assembly::quaternionFromEulerXYZDegrees(
        rotationSpins_[0]->value(), rotationSpins_[1]->value(),
        rotationSpins_[2]->value());

    const bool samePosition = assembly::nearlyEqual(
        placement.translation, component->placement.translation, 1.0e-9);
    const cadnext::Vector3 currentEuler =
        assembly::eulerXYZDegreesFromQuaternion(component->placement.rotation);
    const cadnext::Vector3 newEuler = assembly::eulerXYZDegreesFromQuaternion(placement.rotation);
    const bool sameRotation = assembly::nearlyEqual(currentEuler, newEuler, 1.0e-6);
    if (samePosition && sameRotation) {
        return;
    }

    pushUndoSnapshot();
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
    // adaptive tolerance policy as the part editor: 2.5% of the edge
    // cloud's extent, clamped to sane absolute bounds).
    if (target.hasWorldPoint) {
        const auto edgesIt = worldEdgesByComponent_.find(pick.componentId);
        if (edgesIt != worldEdgesByComponent_.end() && !edgesIt->second.empty()) {
            cadnext::Vector3 boundsMin{1.0e30, 1.0e30, 1.0e30};
            cadnext::Vector3 boundsMax{-1.0e30, -1.0e30, -1.0e30};
            const auto includePoint = [&](const cadnext::Vector3& point) {
                boundsMin.x = std::min(boundsMin.x, point.x);
                boundsMin.y = std::min(boundsMin.y, point.y);
                boundsMin.z = std::min(boundsMin.z, point.z);
                boundsMax.x = std::max(boundsMax.x, point.x);
                boundsMax.y = std::max(boundsMax.y, point.y);
                boundsMax.z = std::max(boundsMax.z, point.z);
            };
            const kernel::EdgeReference* best = nullptr;
            double bestDistance = std::numeric_limits<double>::infinity();
            for (const kernel::EdgeReference& edge : edgesIt->second) {
                std::vector<cadnext::Vector3> points = edge.previewPolyline;
                if (points.size() < 2) {
                    points = {edge.start, edge.end};
                }
                for (const cadnext::Vector3& point : points) {
                    includePoint(point);
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
            const double diagonal =
                assembly::length(assembly::subtract(boundsMax, boundsMin));
            const double tolerance = std::clamp(diagonal * 0.025, 0.015, 0.25);
            if (best && bestDistance <= tolerance) {
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
    // Undo state captured before the ghost preview moves the child; only
    // pushed when the joint is actually confirmed.
    std::string preJointSnapshot = documentSnapshot();

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

    pushUndoSnapshot(std::move(preJointSnapshot));

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
