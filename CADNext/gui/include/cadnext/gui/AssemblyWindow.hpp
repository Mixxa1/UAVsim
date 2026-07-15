#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

#include <QMainWindow>

#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"
#include "cadnext/gui/AssemblyPartLoader.hpp"
#include "cadnext/viewer/CoinViewer.hpp"

class QAction;
class QCheckBox;
class QCloseEvent;
class QDoubleSpinBox;
class QGroupBox;
class QLabel;
class QLineEdit;
class QPlainTextEdit;
class QTreeWidget;
class QTreeWidgetItem;

namespace cadnext::gui {

// CAD Assembly workbench window. The assembly::AssemblyDocument is the
// source of truth; the Coin3D scene, the Components/Joints tree and the
// property panel only mirror it. Components are links to part files
// (.uavpart в первой очереди) — geometry lives in the AssemblyPartLoader
// cache, one entry per source file regardless of instance count.
//
// Not related to the Mount Editor and never based on AttachmentPoint:
// joints reference real topology (faces/edges/vertices/LCS).
class AssemblyWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit AssemblyWindow(QWidget* parent = nullptr);
    ~AssemblyWindow() override;

    // Creates the Coin3D viewport. SoQt::init() must already be done
    // (the main window does it at startup).
    void initializeViewport();

    // Starts a fresh assembly / opens a .cadasm through a file dialog.
    void newAssembly();
    void openAssembly();

protected:
    void closeEvent(QCloseEvent* event) override;

private:
    enum class SelectionKind { None, Component, Joint };

    // One picked geometry element during joint creation.
    struct JointPickSelection {
        bool valid = false;
        std::string componentId;
        assembly::GeometryReference reference;
        QString label;
    };

    // --- Document lifecycle -------------------------------------------------
    bool maybeSave();
    bool saveAssembly();
    bool saveAssemblyAs();
    bool saveToPath(const QString& path);
    void loadFromPath(const QString& path);
    void markDirty();
    void setClean();
    void updateWindowTitle();

    // --- Components ----------------------------------------------------------
    void insertPart();
    void toggleGroundSelected();
    void deleteSelected();
    void setMoveModeActive(bool active);
    std::string nextComponentId() const;
    assembly::AssemblyComponent* selectedComponent();
    const assembly::AssemblyComponent* selectedComponentConst() const;

    // --- Recompute + mirroring -------------------------------------------------
    // Detects source parts changed on disk (contentHash mismatch), drops
    // their cached geometry so topology reloads, bumps the stored revision
    // and reports which parts changed (spec §14). References re-resolve
    // during the following recompute.
    void refreshSourceRevisions();
    void runRecompute();
    void rebuildSceneFromDocument();
    void rebuildTree();
    void refreshTreeStatuses();
    void applyPlacementsToScene();
    void refreshPropertyPanel();
    void updateDiagnosticsView();
    void refreshComponentVisual(const assembly::AssemblyComponent& component);
    assembly::AssemblyRecomputeEngine::TopologyProvider topologyProvider();

    // --- Selection --------------------------------------------------------------
    void selectComponent(const std::string& componentId);
    void selectJoint(const std::string& jointId);
    void clearSelection();
    void handleViewportPick(const viewer::ViewportPickTarget& target, bool contextClick);
    void handleTreeSelection();
    void syncMoveManip();

    // --- Property panel edits ------------------------------------------------
    void applyPanelPlacement();
    void applyPanelName();
    void applyPanelFlags();
    void handleManipFinished(const std::string& componentId);

    QWidget* buildPropertyPanel();

    // --- Joint tool -------------------------------------------------------------
    // Кнопка типа → пик элемента первой детали → пик второй → ghost-preview
    // (DirectPlacementSolver) → диалог параметров → joint в документ.
    void startJointTool(assembly::JointType type);
    void cancelJointTool();
    void handleJointPick(const viewer::ViewportPickTarget& target);
    JointPickSelection resolveJointPick(const viewer::ViewportPickTarget& target);
    void useLcsPick(const std::string& componentId);
    void acceptJointPick(const JointPickSelection& pick);
    void highlightJointPick(const JointPickSelection& pick);
    void enterJointPickVisuals();
    void leaveJointPickVisuals();
    void applyJointPreview(assembly::JointAlignment alignment, double offsetMeters,
                           double angleRadians);
    void finishJointTool();
    std::string nextJointName(assembly::JointType type) const;

    // --- State -----------------------------------------------------------------
    assembly::AssemblyDocument document_;
    std::unique_ptr<AssemblyPartLoader> partLoader_;
    assembly::AssemblyRecomputeEngine recomputeEngine_;
    assembly::AssemblyRecomputeEngine::RecomputeResult lastRecompute_;

    std::unique_ptr<viewer::CoinViewer> viewer_;
    QWidget* viewportContainer_ = nullptr;

    QTreeWidget* tree_ = nullptr;
    QTreeWidgetItem* componentsGroup_ = nullptr;
    QTreeWidgetItem* jointsGroup_ = nullptr;

    // Property panel widgets.
    QGroupBox* componentGroup_ = nullptr;
    QLineEdit* nameEdit_ = nullptr;
    QLabel* sourceLabel_ = nullptr;
    QCheckBox* groundedCheck_ = nullptr;
    QCheckBox* visibleCheck_ = nullptr;
    QDoubleSpinBox* positionSpins_[3] = {nullptr, nullptr, nullptr};
    QDoubleSpinBox* rotationSpins_[3] = {nullptr, nullptr, nullptr};
    QLabel* dofLabel_ = nullptr;
    QGroupBox* jointGroup_ = nullptr;
    QLabel* jointTypeLabel_ = nullptr;
    QLabel* jointStatusLabel_ = nullptr;
    QPlainTextEdit* diagnosticsView_ = nullptr;

    QAction* moveModeAction_ = nullptr;
    QAction* groundAction_ = nullptr;

    SelectionKind selectionKind_ = SelectionKind::None;
    std::string selectedComponentId_;
    std::string selectedJointId_;
    std::string manipComponentId_;

    QString currentFilePath_;
    bool dirty_ = false;
    bool updatingPanel_ = false;
    int nextComponentNumber_ = 1;
    int nextJointNumber_ = 1;

    // Joint tool state.
    bool jointToolActive_ = false;
    assembly::JointType jointToolType_ = assembly::JointType::Coincident;
    JointPickSelection firstPick_;
    JointPickSelection secondPick_;
    // World-space edge copies per component for proximity picking while
    // the joint tool is active.
    std::map<std::string, std::vector<kernel::EdgeReference>> worldEdgesByComponent_;
    assembly::Placement previewOriginalPlacement_;
    bool previewActive_ = false;
};

} // namespace cadnext::gui
