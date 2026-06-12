#pragma once

#include <QToolBar>

class QAction;
class QActionGroup;
class QDoubleSpinBox;

namespace cadnext::gui {

// Sketch workflow toolbar: sketch creation on the three canonical planes,
// enter/exit sketch mode, the exclusive tool group (Select / Line /
// Rectangle / Circle) and the snap/grid input controls. Tool actions are
// only enabled inside sketch mode; the snap/grid settings persist across
// sketches.
class SketchToolBar : public QToolBar {
    Q_OBJECT

public:
    explicit SketchToolBar(QWidget* parent = nullptr);

    QAction* newSketchXYAction() const { return newSketchXYAction_; }
    QAction* newSketchXZAction() const { return newSketchXZAction_; }
    QAction* newSketchYZAction() const { return newSketchYZAction_; }
    QAction* createSketchAction() const { return createSketchAction_; }
    QAction* enterSketchAction() const { return enterSketchAction_; }
    QAction* exitSketchAction() const { return exitSketchAction_; }
    QAction* selectToolAction() const { return selectToolAction_; }
    QAction* lineToolAction() const { return lineToolAction_; }
    QAction* rectangleToolAction() const { return rectangleToolAction_; }
    QAction* circleToolAction() const { return circleToolAction_; }
    QAction* snapGridAction() const { return snapGridAction_; }
    QAction* showGridAction() const { return showGridAction_; }
    QDoubleSpinBox* gridStepSpinBox() const { return gridStepSpinBox_; }

    void setSketchModeActive(bool active);
    void setCreateSketchEnabled(bool enabled);
    void setEnterSketchEnabled(bool enabled);
    void checkSelectTool();

private:
    QAction* newSketchXYAction_ = nullptr;
    QAction* newSketchXZAction_ = nullptr;
    QAction* newSketchYZAction_ = nullptr;
    QAction* createSketchAction_ = nullptr;
    QAction* enterSketchAction_ = nullptr;
    QAction* exitSketchAction_ = nullptr;
    QAction* selectToolAction_ = nullptr;
    QAction* lineToolAction_ = nullptr;
    QAction* rectangleToolAction_ = nullptr;
    QAction* circleToolAction_ = nullptr;
    QAction* snapGridAction_ = nullptr;
    QAction* showGridAction_ = nullptr;
    QDoubleSpinBox* gridStepSpinBox_ = nullptr;
    QActionGroup* toolGroup_ = nullptr;
};

} // namespace cadnext::gui
