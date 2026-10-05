#include "cadnext/gui/SketchToolBar.hpp"

#include <QActionGroup>
#include <QDoubleSpinBox>

#include "cadnext/SketchInput.hpp"
#include "cadnext/Units.hpp"
#include "cadnext/gui/ToolIcons.hpp"

namespace cadnext::gui {

SketchToolBar::SketchToolBar(QWidget* parent)
    : QToolBar(tr("Панель эскиза"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonIconOnly);
    setIconSize(QSize(kToolIconSize, kToolIconSize));

    newSketchXYAction_ = addAction(toolIcon(ToolIcon::SketchXY), tr("Новый эскиз XY"));
    newSketchXZAction_ = addAction(toolIcon(ToolIcon::SketchXZ), tr("Новый эскиз XZ"));
    newSketchYZAction_ = addAction(toolIcon(ToolIcon::SketchYZ), tr("Новый эскиз YZ"));
    addSeparator();
    createSketchAction_ = addAction(toolIcon(ToolIcon::CreateSketch), tr("Создать эскиз"));
    enterSketchAction_ = addAction(toolIcon(ToolIcon::EnterSketch), tr("Войти в эскиз"));
    exitSketchAction_ = addAction(toolIcon(ToolIcon::ExitSketch), tr("Выйти из эскиза"));
    addSeparator();

    toolGroup_ = new QActionGroup(this);
    toolGroup_->setExclusive(true);

    selectToolAction_ = addAction(toolIcon(ToolIcon::SelectTool), tr("Выбор"));
    lineToolAction_ = addAction(toolIcon(ToolIcon::LineTool), tr("Линия"));
    rectangleToolAction_ = addAction(toolIcon(ToolIcon::RectangleTool), tr("Прямоугольник"));
    circleToolAction_ = addAction(toolIcon(ToolIcon::CircleTool), tr("Окружность"));
    for (QAction* action :
         {selectToolAction_, lineToolAction_, rectangleToolAction_, circleToolAction_}) {
        action->setCheckable(true);
        toolGroup_->addAction(action);
    }
    selectToolAction_->setChecked(true);
    addSeparator();

    // Snap/grid controls. Defaults must match SketchInputOptions.
    snapGridAction_ = addAction(toolIcon(ToolIcon::SnapGrid), tr("Привязка к сетке"));
    snapGridAction_->setCheckable(true);
    snapGridAction_->setChecked(true);
    snapGridAction_->setToolTip(tr("Привязывать ввод эскиза к сетке"));

    showGridAction_ = addAction(toolIcon(ToolIcon::ShowGrid), tr("Показать сетку"));
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
