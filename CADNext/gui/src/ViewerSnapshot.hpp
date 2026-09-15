#pragma once

#include <QImage>

class QWidget;
class SoNode;
class SoQtExaminerViewer;

namespace cadnext::gui::detail {

// `window` grabbed as displayed, with the examiner viewer's area re-rendered offscreen from
// `sceneGraph` and the viewer's camera (SoQt draws into a QWindow that QWidget::grab() does not
// see). A headlight along the view stands in for the one SoQt adds outside the scene graph.
QImage snapshotWithViewer(QWidget& window, SoQtExaminerViewer& viewer, SoNode* sceneGraph);

} // namespace cadnext::gui::detail
