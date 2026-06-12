#pragma once

#include <QTreeWidget>

namespace cadnext::gui {

// Project tree with two fixed groups:
//
//   Work Planes
//     XY ...
//   Bodies
//     Box 1 ...
//   Sketches
//     Sketch XY 1
//       Line 1 ...
//
// Selection here is one of the two selection sources (the other is
// viewport picking); both funnel through MainWindow.
class ProjectTree : public QTreeWidget {
    Q_OBJECT

public:
    explicit ProjectTree(QWidget* parent = nullptr);

    void clearAll();

    // Work planes.
    void addWorkPlaneItem(const QString& planeId, const QString& name, const QString& type);
    void removeWorkPlaneItem(const QString& planeId);
    void updateWorkPlaneName(const QString& planeId, const QString& name);
    void setCurrentWorkPlane(const QString& planeId);

    // Bodies / reference planes.
    void addBodyItem(const QString& objectId, const QString& name, const QString& type);
    void removeBodyItem(const QString& objectId);
    void updateBodyName(const QString& objectId, const QString& name);
    void setCurrentBody(const QString& objectId);

    // Sketches and their entities.
    void addSketchItem(const QString& sketchId, const QString& name);
    void removeSketchItem(const QString& sketchId);
    void updateSketchName(const QString& sketchId, const QString& name);
    void setCurrentSketch(const QString& sketchId);

    void addEntityItem(const QString& sketchId, const QString& entityId, const QString& name,
                       const QString& type);
    void removeEntityItem(const QString& sketchId, const QString& entityId);
    void updateEntityName(const QString& sketchId, const QString& entityId,
                          const QString& name);
    void setCurrentEntity(const QString& sketchId, const QString& entityId);

    void clearTreeSelection();

signals:
    void workPlaneSelected(const QString& planeId);
    void bodySelected(const QString& objectId);
    void sketchSelected(const QString& sketchId);
    void entitySelected(const QString& sketchId, const QString& entityId);
    void selectionCleared();
    void sketchActivated(const QString& sketchId); // double-click → enter sketch mode

private:
    enum ItemKind { GroupKind = 0, WorkPlaneKind, BodyKind, SketchKind, EntityKind };

    QTreeWidgetItem* workPlaneItem(const QString& planeId) const;
    QTreeWidgetItem* bodyItem(const QString& objectId) const;
    QTreeWidgetItem* sketchItem(const QString& sketchId) const;
    QTreeWidgetItem* entityItem(const QString& sketchId, const QString& entityId) const;

    QTreeWidgetItem* workPlanesGroup_ = nullptr;
    QTreeWidgetItem* bodiesGroup_ = nullptr;
    QTreeWidgetItem* sketchesGroup_ = nullptr;
};

} // namespace cadnext::gui
