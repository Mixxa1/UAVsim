#include "cadnext/gui/ToolBar.hpp"

#include "cadnext/gui/ToolIcons.hpp"

namespace cadnext::gui {

ToolBar::ToolBar(QWidget* parent)
    : QToolBar(tr("Основная панель"), parent) {
    setMovable(false);
    // Glyphs only: the action's text is its tooltip and its name in the menus.
    setToolButtonStyle(Qt::ToolButtonIconOnly);
    setIconSize(QSize(kToolIconSize, kToolIconSize));

    addBoxAction_ = addAction(toolIcon(ToolIcon::AddBox), tr("Добавить брусок"));
    addCylinderAction_ = addAction(toolIcon(ToolIcon::AddCylinder), tr("Добавить цилиндр"));
    addSphereAction_ = addAction(toolIcon(ToolIcon::AddSphere), tr("Добавить сферу"));
    addPlaneAction_ = addAction(toolIcon(ToolIcon::AddPlane), tr("Добавить плоскость"));
    addSeparator();
    // Enabled by MainWindow whenever the relevant sketch has a valid
    // closed profile (Cut Extrude additionally needs the OCCT backend
    // and a target body).
    extrudeAction_ = addAction(toolIcon(ToolIcon::Extrude), tr("Выдавить"));
    extrudeAction_->setEnabled(false);
    revolveAction_ = addAction(toolIcon(ToolIcon::Revolve), tr("Вращать"));
    revolveAction_->setEnabled(false);
    cutExtrudeAction_ = addAction(toolIcon(ToolIcon::CutExtrude), tr("Вырезать выдавливанием"));
    cutExtrudeAction_->setEnabled(false);
    chamferAction_ = addAction(toolIcon(ToolIcon::Chamfer), tr("Фаска"));
    chamferAction_->setEnabled(false);
    filletAction_ = addAction(toolIcon(ToolIcon::Fillet), tr("Скругление"));
    filletAction_->setEnabled(false);
    threadAction_ = addAction(toolIcon(ToolIcon::Thread), tr("Резьба"));
    threadAction_->setToolTip(tr("Резьба с настоящими витками на цилиндрической или конической грани"));
    threadAction_->setEnabled(false);
    addSeparator();
    // Enabled by MainWindow when the selection is a sketchable planar
    // body face (CADNext 0.8 Sketch on Face).
    createSketchOnFaceAction_ = addAction(toolIcon(ToolIcon::SketchOnFace), tr("Эскиз на грани"));
    createSketchOnFaceAction_->setEnabled(false);
    workPlaneFromFaceAction_ = addAction(toolIcon(ToolIcon::WorkPlaneFromFace), tr("Плоскость по грани"));
    workPlaneFromFaceAction_->setEnabled(false);
    normalToFaceAction_ = addAction(toolIcon(ToolIcon::NormalToFace), tr("Нормально к грани"));
    normalToFaceAction_->setEnabled(false);
    addSeparator();
    // UAVPart v1.1: adds an attachment point to the selected body.
    addAttachmentPointAction_ = addAction(toolIcon(ToolIcon::AttachmentPoint), tr("Добавить точку крепления"));
    addAttachmentPointAction_->setCheckable(true);
    addSeparator();
    deleteSelectedAction_ = addAction(toolIcon(ToolIcon::Delete), tr("Удалить выбранное"));
    addSeparator();
    fitSelectionAction_ = addAction(toolIcon(ToolIcon::FitSelection), tr("Приблизить к выбранному"));
    fitViewAction_ = addAction(toolIcon(ToolIcon::FitView), tr("Вписать вид"));
    resetCameraAction_ = addAction(toolIcon(ToolIcon::ResetCamera), tr("Сбросить камеру"));
}

} // namespace cadnext::gui
