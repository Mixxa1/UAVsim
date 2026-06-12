#include "cadnext/gui/ProjectTree.hpp"

namespace cadnext::gui {

namespace {
constexpr int kKindRole = Qt::UserRole;
constexpr int kIdRole = Qt::UserRole + 1;
constexpr int kSketchRole = Qt::UserRole + 2;
} // namespace

ProjectTree::ProjectTree(QWidget* parent)
    : QTreeWidget(parent) {
    setColumnCount(2);
    setHeaderLabels({tr("Объект"), tr("Тип")});
    setSelectionMode(QAbstractItemView::SingleSelection);
    setSelectionBehavior(QAbstractItemView::SelectRows);

    clearAll();

    connect(this, &QTreeWidget::itemSelectionChanged, this, [this]() {
        const QList<QTreeWidgetItem*> selected = selectedItems();
        if (selected.isEmpty()) {
            emit selectionCleared();
            return;
        }
        QTreeWidgetItem* item = selected.first();
        switch (item->data(0, kKindRole).toInt()) {
        case WorkPlaneKind:
            emit workPlaneSelected(item->data(0, kIdRole).toString());
            break;
        case BodyKind:
            emit bodySelected(item->data(0, kIdRole).toString());
            break;
        case SketchKind:
            emit sketchSelected(item->data(0, kIdRole).toString());
            break;
        case EntityKind:
            emit entitySelected(item->data(0, kSketchRole).toString(),
                                item->data(0, kIdRole).toString());
            break;
        default:
            emit selectionCleared();
            break;
        }
    });

    connect(this, &QTreeWidget::itemDoubleClicked, this, [this](QTreeWidgetItem* item, int) {
        if (item && item->data(0, kKindRole).toInt() == SketchKind) {
            emit sketchActivated(item->data(0, kIdRole).toString());
        }
    });
}

void ProjectTree::clearAll() {
    clear();

    workPlanesGroup_ = new QTreeWidgetItem(this);
    workPlanesGroup_->setText(0, tr("Рабочие плоскости"));
    workPlanesGroup_->setData(0, kKindRole, GroupKind);
    workPlanesGroup_->setFlags(Qt::ItemIsEnabled);

    bodiesGroup_ = new QTreeWidgetItem(this);
    bodiesGroup_->setText(0, tr("Тела"));
    bodiesGroup_->setData(0, kKindRole, GroupKind);
    bodiesGroup_->setFlags(Qt::ItemIsEnabled);

    sketchesGroup_ = new QTreeWidgetItem(this);
    sketchesGroup_->setText(0, tr("Эскизы"));
    sketchesGroup_->setData(0, kKindRole, GroupKind);
    sketchesGroup_->setFlags(Qt::ItemIsEnabled);

    expandAll();
}

void ProjectTree::addWorkPlaneItem(const QString& planeId, const QString& name,
                                   const QString& type) {
    auto* item = new QTreeWidgetItem(workPlanesGroup_);
    item->setText(0, name);
    item->setText(1, type);
    item->setData(0, kKindRole, WorkPlaneKind);
    item->setData(0, kIdRole, planeId);
    workPlanesGroup_->setExpanded(true);
}

void ProjectTree::removeWorkPlaneItem(const QString& planeId) {
    delete workPlaneItem(planeId);
}

void ProjectTree::updateWorkPlaneName(const QString& planeId, const QString& name) {
    if (QTreeWidgetItem* item = workPlaneItem(planeId)) {
        item->setText(0, name);
    }
}

void ProjectTree::setCurrentWorkPlane(const QString& planeId) {
    if (QTreeWidgetItem* item = workPlaneItem(planeId)) {
        setCurrentItem(item);
    } else {
        clearTreeSelection();
    }
}

void ProjectTree::addBodyItem(const QString& objectId, const QString& name,
                              const QString& type) {
    auto* item = new QTreeWidgetItem(bodiesGroup_);
    item->setText(0, name);
    item->setText(1, type);
    item->setData(0, kKindRole, BodyKind);
    item->setData(0, kIdRole, objectId);
    bodiesGroup_->setExpanded(true);
}

void ProjectTree::removeBodyItem(const QString& objectId) {
    delete bodyItem(objectId);
}

void ProjectTree::updateBodyName(const QString& objectId, const QString& name) {
    if (QTreeWidgetItem* item = bodyItem(objectId)) {
        item->setText(0, name);
    }
}

void ProjectTree::setCurrentBody(const QString& objectId) {
    if (QTreeWidgetItem* item = bodyItem(objectId)) {
        setCurrentItem(item);
    } else {
        clearTreeSelection();
    }
}

void ProjectTree::addSketchItem(const QString& sketchId, const QString& name) {
    auto* item = new QTreeWidgetItem(sketchesGroup_);
    item->setText(0, name);
    item->setText(1, tr("Эскиз"));
    item->setData(0, kKindRole, SketchKind);
    item->setData(0, kIdRole, sketchId);
    sketchesGroup_->setExpanded(true);
}

void ProjectTree::removeSketchItem(const QString& sketchId) {
    delete sketchItem(sketchId);
}

void ProjectTree::updateSketchName(const QString& sketchId, const QString& name) {
    if (QTreeWidgetItem* item = sketchItem(sketchId)) {
        item->setText(0, name);
    }
}

void ProjectTree::setCurrentSketch(const QString& sketchId) {
    if (QTreeWidgetItem* item = sketchItem(sketchId)) {
        setCurrentItem(item);
    } else {
        clearTreeSelection();
    }
}

void ProjectTree::addEntityItem(const QString& sketchId, const QString& entityId,
                                const QString& name, const QString& type) {
    QTreeWidgetItem* parent = sketchItem(sketchId);
    if (!parent) {
        return;
    }
    auto* item = new QTreeWidgetItem(parent);
    item->setText(0, name);
    item->setText(1, type);
    item->setData(0, kKindRole, EntityKind);
    item->setData(0, kIdRole, entityId);
    item->setData(0, kSketchRole, sketchId);
    parent->setExpanded(true);
}

void ProjectTree::removeEntityItem(const QString& sketchId, const QString& entityId) {
    delete entityItem(sketchId, entityId);
}

void ProjectTree::updateEntityName(const QString& sketchId, const QString& entityId,
                                   const QString& name) {
    if (QTreeWidgetItem* item = entityItem(sketchId, entityId)) {
        item->setText(0, name);
    }
}

void ProjectTree::setCurrentEntity(const QString& sketchId, const QString& entityId) {
    if (QTreeWidgetItem* item = entityItem(sketchId, entityId)) {
        setCurrentItem(item);
    } else {
        clearTreeSelection();
    }
}

void ProjectTree::clearTreeSelection() {
    clearSelection();
    setCurrentItem(nullptr);
}

QTreeWidgetItem* ProjectTree::workPlaneItem(const QString& planeId) const {
    for (int i = 0; i < workPlanesGroup_->childCount(); ++i) {
        QTreeWidgetItem* item = workPlanesGroup_->child(i);
        if (item->data(0, kIdRole).toString() == planeId) {
            return item;
        }
    }
    return nullptr;
}

QTreeWidgetItem* ProjectTree::bodyItem(const QString& objectId) const {
    for (int i = 0; i < bodiesGroup_->childCount(); ++i) {
        QTreeWidgetItem* item = bodiesGroup_->child(i);
        if (item->data(0, kIdRole).toString() == objectId) {
            return item;
        }
    }
    return nullptr;
}

QTreeWidgetItem* ProjectTree::sketchItem(const QString& sketchId) const {
    for (int i = 0; i < sketchesGroup_->childCount(); ++i) {
        QTreeWidgetItem* item = sketchesGroup_->child(i);
        if (item->data(0, kIdRole).toString() == sketchId) {
            return item;
        }
    }
    return nullptr;
}

QTreeWidgetItem* ProjectTree::entityItem(const QString& sketchId,
                                         const QString& entityId) const {
    QTreeWidgetItem* parent = sketchItem(sketchId);
    if (!parent) {
        return nullptr;
    }
    for (int i = 0; i < parent->childCount(); ++i) {
        QTreeWidgetItem* item = parent->child(i);
        if (item->data(0, kIdRole).toString() == entityId) {
            return item;
        }
    }
    return nullptr;
}

} // namespace cadnext::gui
