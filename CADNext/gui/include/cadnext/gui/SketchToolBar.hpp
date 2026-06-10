#pragma once

#include <QToolBar>

class QAction;
class QActionGroup;

namespace cadnext::gui {

// Sketch workflow toolbar: sketch creation on the three canonical planes,
// enter/exit sketch mode, and the exclusive tool group (Select / Line /
// Rectangle / Circle). Tool actions are only enabled inside sketch mode.
class SketchToolBar : public QToolBar {
    Q_OBJECT

public:
    explicit SketchToolBar(QWidget* parent = nullptr);

    QAction* newSketchXYAction() const { return newSketchXYAction_; }
    QAction* newSketchXZAction() const { return newSketchXZAction_; }
    QAction* newSketchYZAction() const { return newSketchYZAction_; }
    QAction* enterSketchAction() const { return enterSketchAction_; }
    QAction* exitSketchAction() const { return exitSketchAction_; }
    QAction* selectToolAction() const { return selectToolAction_; }
    QAction* lineToolAction() const { return lineToolAction_; }
    QAction* rectangleToolAction() const { return rectangleToolAction_; }
    QAction* circleToolAction() const { return circleToolAction_; }

    void setSketchModeActive(bool active);
    void setEnterSketchEnabled(bool enabled);
    void checkSelectTool();

private:
    QAction* newSketchXYAction_ = nullptr;
    QAction* newSketchXZAction_ = nullptr;
    QAction* newSketchYZAction_ = nullptr;
    QAction* enterSketchAction_ = nullptr;
    QAction* exitSketchAction_ = nullptr;
    QAction* selectToolAction_ = nullptr;
    QAction* lineToolAction_ = nullptr;
    QAction* rectangleToolAction_ = nullptr;
    QAction* circleToolAction_ = nullptr;
    QActionGroup* toolGroup_ = nullptr;
};

} // namespace cadnext::gui
