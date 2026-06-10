#include "cadnext/gui/SketchToolBar.hpp"

#include <QActionGroup>

namespace cadnext::gui {

SketchToolBar::SketchToolBar(QWidget* parent)
    : QToolBar(tr("Sketch Toolbar"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonTextOnly);

    newSketchXYAction_ = addAction(tr("New Sketch XY"));
    newSketchXZAction_ = addAction(tr("New Sketch XZ"));
    newSketchYZAction_ = addAction(tr("New Sketch YZ"));
    addSeparator();
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

    setSketchModeActive(false);
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

void SketchToolBar::setEnterSketchEnabled(bool enabled) {
    enterSketchAction_->setEnabled(enabled);
}

void SketchToolBar::checkSelectTool() {
    selectToolAction_->setChecked(true);
}

} // namespace cadnext::gui
