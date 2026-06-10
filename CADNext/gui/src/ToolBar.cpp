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
    deleteSelectedAction_ = addAction(tr("Delete Selected"));
    addSeparator();
    fitViewAction_ = addAction(tr("Fit View"));
    resetCameraAction_ = addAction(tr("Reset Camera"));
}

} // namespace cadnext::gui
