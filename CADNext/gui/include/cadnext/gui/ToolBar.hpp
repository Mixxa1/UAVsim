#pragma once

#include <QToolBar>

class QAction;

namespace cadnext::gui {

// Main toolbar with the CADNext 0.2 construction and view actions.
class ToolBar : public QToolBar {
    Q_OBJECT

public:
    explicit ToolBar(QWidget* parent = nullptr);

    QAction* addBoxAction() const { return addBoxAction_; }
    QAction* addCylinderAction() const { return addCylinderAction_; }
    QAction* addSphereAction() const { return addSphereAction_; }
    QAction* addPlaneAction() const { return addPlaneAction_; }
    QAction* deleteSelectedAction() const { return deleteSelectedAction_; }
    QAction* fitViewAction() const { return fitViewAction_; }
    QAction* resetCameraAction() const { return resetCameraAction_; }

private:
    QAction* addBoxAction_ = nullptr;
    QAction* addCylinderAction_ = nullptr;
    QAction* addSphereAction_ = nullptr;
    QAction* addPlaneAction_ = nullptr;
    QAction* deleteSelectedAction_ = nullptr;
    QAction* fitViewAction_ = nullptr;
    QAction* resetCameraAction_ = nullptr;
};

} // namespace cadnext::gui
