#include "cadnext/gui/ToolBar.hpp"

namespace cadnext::gui {

ToolBar::ToolBar(QWidget* parent)
    : QToolBar(tr("Main Toolbar"), parent) {
    setMovable(false);
    setToolButtonStyle(Qt::ToolButtonTextOnly);

    addBoxAction_ = addAction(tr("Add Box"));
    addCylinderAction_ = addAction(tr("Add Cylinder"));
    addSphereAction_ = addAction(tr("Add Sphere"));
    addPlaneAction_ = addAction(tr("Add Plane"));
    addSeparator();
    // Enabled by MainWindow whenever the relevant sketch has a valid
    // closed profile (Cut Extrude additionally needs the OCCT backend
    // and a target body).
    extrudeAction_ = addAction(tr("Extrude"));
    extrudeAction_->setEnabled(false);
    cutExtrudeAction_ = addAction(tr("Cut Extrude"));
    cutExtrudeAction_->setEnabled(false);
    addSeparator();
    // Enabled by MainWindow when the selection is a sketchable planar
    // body face (CADNext 0.8 Sketch on Face).
    createSketchOnFaceAction_ = addAction(tr("Create Sketch on Face"));
    createSketchOnFaceAction_->setEnabled(false);
    workPlaneFromFaceAction_ = addAction(tr("Work Plane from Face"));
    workPlaneFromFaceAction_->setEnabled(false);
    normalToFaceAction_ = addAction(tr("Normal to Face"));
    normalToFaceAction_->setEnabled(false);
    addSeparator();
    deleteSelectedAction_ = addAction(tr("Delete Selected"));
    addSeparator();
    fitViewAction_ = addAction(tr("Fit View"));
    resetCameraAction_ = addAction(tr("Reset Camera"));
}

} // namespace cadnext::gui
