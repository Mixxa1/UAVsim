#pragma once

#include <QWidget>

#include "cadnext/Object.hpp"
#include "cadnext/Sketch.hpp"
#include "cadnext/WorkPlane.hpp"

class QDoubleSpinBox;
class QFormLayout;
class QLabel;
class QLineEdit;

namespace cadnext::gui {

// Inspector/editor for the current selection. Bodies expose an editable
// name, transform (position / rotation / scale; rotation shown — and
// stored — in degrees) and primitive dimensions. Sketches and sketch
// entities expose an editable name; their geometry parameters are
// read-only in CADNext 0.5 (parameter editing arrives with dimensions
// in 0.6).
class PropertyPanel : public QWidget {
    Q_OBJECT

public:
    explicit PropertyPanel(QWidget* parent = nullptr);

    void showObject(const Object& object);
    void showWorkPlane(const WorkPlane& plane);
    void showSketch(const Sketch& sketch);
    void showSketchEntity(const Sketch& sketch, const SketchEntity& entity);
    void clearObject();

signals:
    void nameEdited(const QString& objectId, const QString& newName);
    void sketchNameEdited(const QString& sketchId, const QString& newName);
    void entityNameEdited(const QString& sketchId, const QString& entityId,
                          const QString& newName);
    void transformEdited(const QString& objectId, const cadnext::Transform& transform);
    void primitiveEdited(const QString& objectId,
                         const cadnext::PrimitiveParameters& parameters);

private:
    enum class Mode { None, Object, Sketch, Entity };

    QDoubleSpinBox* makeSpinBox(double minimum, double step, int decimals);
    QWidget* makeVectorRow(QDoubleSpinBox*& x, QDoubleSpinBox*& y, QDoubleSpinBox*& z,
                           double minimum, double step, int decimals);
    void connectTransformBox(QDoubleSpinBox* box);
    void connectDimensionBox(QDoubleSpinBox* box);
    void emitTransform();
    void emitPrimitive();
    void updateDimensionVisibility(const Object& object);
    void setObjectRowsVisible(bool visible);
    void hideDimensionRows();

    bool updating_ = false;
    Mode mode_ = Mode::None;
    QString currentObjectId_;  // body id, sketch id, or entity id by mode
    QString currentSketchId_;  // owner sketch id in Entity mode
    QString currentName_;
    PrimitiveKind currentKind_ = PrimitiveKind::None;

    QFormLayout* form_ = nullptr;

    QLabel* idLabel_ = nullptr;
    QLineEdit* nameEdit_ = nullptr;
    QLabel* typeLabel_ = nullptr;
    QLabel* kindLabel_ = nullptr;

    QDoubleSpinBox* positionX_ = nullptr;
    QDoubleSpinBox* positionY_ = nullptr;
    QDoubleSpinBox* positionZ_ = nullptr;
    QDoubleSpinBox* rotationX_ = nullptr;
    QDoubleSpinBox* rotationY_ = nullptr;
    QDoubleSpinBox* rotationZ_ = nullptr;
    QDoubleSpinBox* scaleX_ = nullptr;
    QDoubleSpinBox* scaleY_ = nullptr;
    QDoubleSpinBox* scaleZ_ = nullptr;

    QDoubleSpinBox* dimensionWidth_ = nullptr;
    QDoubleSpinBox* dimensionHeight_ = nullptr;
    QDoubleSpinBox* dimensionDepth_ = nullptr;
    QDoubleSpinBox* dimensionRadius_ = nullptr;

    QWidget* positionRow_ = nullptr;
    QWidget* rotationRow_ = nullptr;
    QWidget* scaleRow_ = nullptr;
    QLabel* detailsLabel_ = nullptr; // read-only sketch / entity geometry
};

} // namespace cadnext::gui
