#include "cadnext/gui/SketchToolBar.hpp"

#include <QActionGroup>
#include <QDoubleSpinBox>

#include "cadnext/SketchInput.hpp"
#include "cadnext/Units.hpp"

namespace cadnext::gui {

SketchToolBar::SketchToolBar(QWidget* parent)
    : QToolBar(tr("Панель эскиза"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonTextOnly);

    newSketchXYAction_ = addAction(tr("Новый эскиз XY"));
    newSketchXZAction_ = addAction(tr("Новый эскиз XZ"));
    newSketchYZAction_ = addAction(tr("Новый эскиз YZ"));
    addSeparator();
    createSketchAction_ = addAction(tr("Создать эскиз"));
    enterSketchAction_ = addAction(tr("Войти в эскиз"));
    exitSketchAction_ = addAction(tr("Выйти из эскиза"));
    addSeparator();

    toolGroup_ = new QActionGroup(this);
    toolGroup_->setExclusive(true);

    selectToolAction_ = addAction(tr("Выбор"));
    lineToolAction_ = addAction(tr("Линия"));
    rectangleToolAction_ = addAction(tr("Прямоугольник"));
    circleToolAction_ = addAction(tr("Окружность"));
    for (QAction* action :
         {selectToolAction_, lineToolAction_, rectangleToolAction_, circleToolAction_}) {
        action->setCheckable(true);
        toolGroup_->addAction(action);
    }
    selectToolAction_->setChecked(true);
    addSeparator();

    // Snap/grid controls. Defaults must match SketchInputOptions.
    snapGridAction_ = addAction(tr("Привязка к сетке"));
    snapGridAction_->setCheckable(true);
    snapGridAction_->setChecked(true);
    snapGridAction_->setToolTip(tr("Привязывать ввод эскиза к сетке"));

    showGridAction_ = addAction(tr("Показать сетку"));
    showGridAction_->setCheckable(true);
    showGridAction_->setChecked(true);
    showGridAction_->setToolTip(tr("Показывать сетку плоскости эскиза"));

    // The spin box edits the grid step in millimeters; the model keeps it
    // in model units (see MainWindow::onGridStepChanged).
    gridStepSpinBox_ = new QDoubleSpinBox(this);
    gridStepSpinBox_->setRange(toMillimeters(kMinSketchGridStep), 100000.0);
    gridStepSpinBox_->setDecimals(1);
    gridStepSpinBox_->setSingleStep(10.0);
    gridStepSpinBox_->setValue(100.0);
    gridStepSpinBox_->setPrefix(tr("Сетка: "));
    gridStepSpinBox_->setSuffix(tr(" мм"));
    gridStepSpinBox_->setToolTip(tr("Шаг сетки для привязки и сетки эскиза"));
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
