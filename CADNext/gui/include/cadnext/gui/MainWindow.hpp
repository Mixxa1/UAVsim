#pragma once

#include <memory>
#include <optional>
#include <string>

#include <QMainWindow>

#include "cadnext/CommandStack.hpp"
#include "cadnext/Document.hpp"
#include "cadnext/Extrude.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/SketchInput.hpp"
#include "cadnext/SketchProfile.hpp"
#include "cadnext/WorkPlane.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/Kernel.hpp"
#include "cadnext/viewer/CoinViewer.hpp"
#include "cadnext/viewer/SelectionController.hpp"

class QCloseEvent;
class QDockWidget;
class QLabel;

namespace cadnext::gui {

class ExtrudeDialog;
class ProjectTree;
class PropertyPanel;
class SketchToolBar;
class ToolBar;

// CADNext main window. The cadnext::Document is the source of truth for
// bodies and sketches; viewer nodes and tree items only mirror it. The
// selection state below is the single selection source — tree clicks,
// viewport picks and delete actions all funnel through selectBody()/
// selectSketch()/selectEntity()/clearSelection().
class MainWindow : public QMainWindow {
    Q_OBJECT

public:
    explicit MainWindow(QWidget* parent = nullptr);
    ~MainWindow() override;

    // Creates the Coin3D viewport. Must be called after SoQt::init().
    void initializeViewport();

protected:
    void closeEvent(QCloseEvent* event) override;

private:
    enum class SelectionKind { None, WorkPlane, Body, Sketch, Entity };

    // Selection.
    void selectWorkPlane(const std::string& planeId);
    void selectBody(const std::string& objectId);
    void selectSketch(const std::string& sketchId);
    void selectEntity(const std::string& sketchId, const std::string& entityId);
    void clearSelection();
    void syncTreeSelection();
    void syncViewportSelection();
    void refreshPropertyPanel();
    std::optional<WorkPlane> workPlaneById(const std::string& planeId) const;
    WorkPlane workPlaneForSketch(const Sketch& sketch) const;
    void addCanonicalWorkPlanesToTree();

    // Body creation/removal (0.2–0.4 workflow).
    void addPrimitiveObject(PrimitiveKind kind);
    void addReferencePlane();
    void deleteSelected();
    void registerObject(const Object& object);
    Vector3 nextSpawnPosition(double groundOffset) const;
    void buildObjectVisual(const Object& object);

    // Sketch workflow (0.5).
    void newSketch(SketchPlane plane);
    void createSketchFromSelectedPlane();
    void createSketchOnPlane(const WorkPlane& plane);
    void enterSketchMode(const std::string& sketchId);
    void exitSketchMode();
    void normalToSelectedPlane();
    void fitSketchView();
    void showPlaneActionPalette(bool contextClick);
    void setSketchTool(SketchTool tool);
    void onSketchPoint(double u, double v);
    void onSketchMove(double u, double v);
    void cancelSketchTool();
    void addSketchEntity(SketchEntity entity);

    // Extrude workflow (0.6): profile detection/selection + dialog.
    void refreshSketchProfiles();
    void selectProfile(const std::string& profileId);
    void selectProfileForEntity(const std::string& sketchId, const std::string& entityId);
    void updateExtrudeActionEnabled();
    std::optional<Sketch> sketchForExtrude() const;
    void openExtrudeDialog();
    void onExtrudeParametersChanged();
    void applyExtrude();
    void cancelExtrude();
    bool buildExtrudeMesh(const Sketch& sketch, const SketchProfile& profile,
                          const ExtrudeParameters& parameters,
                          kernel::TriangleMesh& outMesh, QString* failureReason);
    void buildExtrudedBodyVisual(const Object& object, const Feature& feature);
    const Feature* extrudeFeatureForBody(const std::string& objectId) const;

    // Sketch input UX (cursor / snap / live preview).
    void onSnapToggled(bool enabled);
    void onShowGridToggled(bool visible);
    void onGridStepChanged(double step);
    void refreshSketchPlaneVisual();
    void updateSketchPreview(const SketchPoint2D& current);
    void clearPendingSketchVisuals();
    // Permanent status-bar mode line: Free3D / selected plane / Sketch2D
    // (with sketch name, plane, snap and grid step).
    void updateModeStatusLabel();
    QString sketchToolPrompt() const;

    // Property edits.
    void onObjectNameEdited(const QString& objectId, const QString& newName);
    void onSketchNameEdited(const QString& sketchId, const QString& newName);
    void onEntityNameEdited(const QString& sketchId, const QString& entityId,
                            const QString& newName);
    void onTransformEdited(const QString& objectId, const Transform& transform);
    void onPrimitiveEdited(const QString& objectId, const PrimitiveParameters& parameters);

    // File handling.
    void newDocument();
    void openDocument();
    bool saveDocument();
    bool saveDocumentAs();
    bool maybeSave();
    void rebuildUiFromDocument();
    void deriveCountersFromDocument();

    // Dirty-state.
    void markDirty();
    void setClean();
    void updateWindowTitle();

    // Undo/redo (rename + sketch entity add in CADNext 0.5).
    void undo();
    void redo();
    void afterHistoryChange();
    void updateUndoRedoActions();

    void createMenus();

    Document document_;
    CommandStack commandStack_;
    std::unique_ptr<kernel::Kernel> kernel_;
    std::unique_ptr<kernel::GeometryEvaluator> evaluator_;
    std::unique_ptr<viewer::CoinViewer> viewer_;
    std::unique_ptr<viewer::SelectionController> selection_;

    SelectionKind selectionKind_ = SelectionKind::None;
    std::string selectedId_;       // body id or sketch id (entity id in Entity kind)
    std::string selectedSketchId_; // owner sketch id in Entity kind
    std::string highlightedEntitySketch_;
    std::string highlightedEntityId_;
    std::string hoveredWorkPlaneId_;

    std::optional<std::string> activeSketchId_;
    std::optional<WorkPlane> activeSketchPlane_;
    SketchReference activeSketchReference_;
    SketchInputState sketchInput_;

    // Extrude state: profiles of the active sketch (viewport display) and
    // of the sketch the dialog is operating on.
    std::vector<SketchProfile> activeProfiles_;
    std::vector<SketchProfile> dialogProfiles_;
    std::string selectedProfileId_;
    std::string extrudeSketchId_;
    ExtrudeDialog* extrudeDialog_ = nullptr;

    ToolBar* toolBar_ = nullptr;
    SketchToolBar* sketchToolBar_ = nullptr;
    ProjectTree* projectTree_ = nullptr;
    PropertyPanel* propertyPanel_ = nullptr;
    QDockWidget* treeDock_ = nullptr;
    QDockWidget* propertyDock_ = nullptr;

    QAction* undoAction_ = nullptr;
    QAction* redoAction_ = nullptr;
    QLabel* modeStatusLabel_ = nullptr;

    QString currentFilePath_;
    bool dirty_ = false;

    int nextObjectNumber_ = 1;
    int boxCount_ = 0;
    int cylinderCount_ = 0;
    int sphereCount_ = 0;
    int planeCount_ = 0;
    int nextSketchNumber_ = 1;
    int nextEntityNumber_ = 1;
    int lineCount_ = 0;
    int rectangleCount_ = 0;
    int circleCount_ = 0;
    int nextFeatureNumber_ = 1;
    int extrudeCount_ = 0;
};

} // namespace cadnext::gui
