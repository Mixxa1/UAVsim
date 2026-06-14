#include "cadnext/gui/ToolBar.hpp"

namespace cadnext::gui {

ToolBar::ToolBar(QWidget* parent)
    : QToolBar(tr("Основная панель"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonTextOnly);

    addBoxAction_ = addAction(tr("Добавить брусок"));
    addCylinderAction_ = addAction(tr("Добавить цилиндр"));
    addSphereAction_ = addAction(tr("Добавить сферу"));
    addPlaneAction_ = addAction(tr("Добавить плоскость"));
    addSeparator();
    // Enabled by MainWindow whenever the relevant sketch has a valid
    // closed profile (Cut Extrude additionally needs the OCCT backend
    // and a target body).
    extrudeAction_ = addAction(tr("Выдавить"));
    extrudeAction_->setEnabled(false);
    cutExtrudeAction_ = addAction(tr("Вырезать выдавливанием"));
    cutExtrudeAction_->setEnabled(false);
    chamferAction_ = addAction(tr("Фаска"));
    chamferAction_->setEnabled(false);
    filletAction_ = addAction(tr("Скругление"));
    filletAction_->setEnabled(false);
    addSeparator();
    // Enabled by MainWindow when the selection is a sketchable planar
    // body face (CADNext 0.8 Sketch on Face).
    createSketchOnFaceAction_ = addAction(tr("Эскиз на грани"));
    createSketchOnFaceAction_->setEnabled(false);
    workPlaneFromFaceAction_ = addAction(tr("Плоскость по грани"));
    workPlaneFromFaceAction_->setEnabled(false);
    normalToFaceAction_ = addAction(tr("Нормально к грани"));
    normalToFaceAction_->setEnabled(false);
    addSeparator();
    // UAVPart v1.1: adds an attachment point to the selected body.
    addAttachmentPointAction_ = addAction(tr("Добавить точку крепления"));
    addAttachmentPointAction_->setCheckable(true);
    addSeparator();
    deleteSelectedAction_ = addAction(tr("Удалить выбранное"));
    addSeparator();
    fitSelectionAction_ = addAction(tr("Приблизить к выбранному"));
    fitViewAction_ = addAction(tr("Вписать вид"));
    resetCameraAction_ = addAction(tr("Сбросить камеру"));
}

} // namespace cadnext::gui
