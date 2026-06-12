#include "cadnext/gui/SketchToolBar.hpp"

#include <QActionGroup>
#include <QDoubleSpinBox>

#include "cadnext/SketchInput.hpp"

namespace cadnext::gui {

SketchToolBar::SketchToolBar(QWidget* parent)
    : QToolBar(tr("Sketch Toolbar"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonTextOnly);

    newSketchXYAction_ = addAction(tr("New Sketch XY"));
    newSketchXZAction_ = addAction(tr("New Sketch XZ"));
    newSketchYZAction_ = addAction(tr("New Sketch YZ"));
    addSeparator();
    createSketchAction_ = addAction(tr("Create Sketch"));
    enterSketchAction_ = addAction(tr("Enter Sketch"));
    exitSketchAction_ = addAction(tr("Exit Sketch"));
    addSeparator();

    toolGroup_ = new QActionGroup(this);
    toolGroup_->setExclusive(true);

    selectToolAction_ = addAction(tr("Select"));
    lineToolAction_ = addAction(tr("Line"));
    rectangleToolAction_ = addAction(tr("Rectangle"));
    circleToolAction_ = addAction(tr("Circle"));
    for (QAction* action :
         {selectToolAction_, lineToolAction_, rectangleToolAction_, circleToolAction_}) {
        action->setCheckable(true);
        toolGroup_->addAction(action);
    }
    selectToolAction_->setChecked(true);
    addSeparator();

    // Snap/grid controls. Defaults must match SketchInputOptions.
    snapGridAction_ = addAction(tr("Snap Grid"));
    snapGridAction_->setCheckable(true);
    snapGridAction_->setChecked(true);
    snapGridAction_->setToolTip(tr("Snap sketch input to the grid"));

    showGridAction_ = addAction(tr("Show Grid"));
    showGridAction_->setCheckable(true);
    showGridAction_->setChecked(true);
    showGridAction_->setToolTip(tr("Show the sketch plane grid"));

    gridStepSpinBox_ = new QDoubleSpinBox(this);
    gridStepSpinBox_->setRange(kMinSketchGridStep, 100.0);
    gridStepSpinBox_->setDecimals(3);
    gridStepSpinBox_->setSingleStep(0.1);
    gridStepSpinBox_->setValue(0.1);
    gridStepSpinBox_->setPrefix(tr("Grid: "));
    gridStepSpinBox_->setToolTip(tr("Grid step used for snapping and the sketch grid"));
    addWidget(gridStepSpinBox_);

    setSketchModeActive(false);
    setCreateSketchEnabled(false);
    setEnterSketchEnabled(false);
}

void SketchToolBar::setSketchModeActive(bool active) {
    exitSketchAction_->setEnabled(active);
    for (QAction* action :
         {selectToolAction_, lineToolAction_, rectangleToolAction_, circleToolAction_}) {
        action->setEnabled(active);
    }
    if (!active) {
        selectToolAction_->setChecked(true);
    }
}

void SketchToolBar::setCreateSketchEnabled(bool enabled) {
    createSketchAction_->setEnabled(enabled);
}

void SketchToolBar::setEnterSketchEnabled(bool enabled) {
    enterSketchAction_->setEnabled(enabled);
}

void SketchToolBar::checkSelectTool() {
    selectToolAction_->setChecked(true);
}

} // namespace cadnext::gui
