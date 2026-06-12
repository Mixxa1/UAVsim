#include "cadnext/gui/PropertyPanel.hpp"

#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>

namespace cadnext::gui {

namespace {

constexpr double kTransformLimit = 1.0e9;
constexpr double kMinScale = 0.001;
constexpr double kMinDimension = 0.001;

QString objectTypeText(ObjectType type) {
    switch (type) {
    case ObjectType::Body: return QStringLiteral("Body");
    case ObjectType::Sketch: return QStringLiteral("Sketch");
    case ObjectType::Assembly: return QStringLiteral("Assembly");
    case ObjectType::ReferencePlane: return QStringLiteral("Reference Plane");
    case ObjectType::Unknown: break;
    }
    return QStringLiteral("Unknown");
}

QString workPlaneTypeText(WorkPlaneKind kind) {
    switch (kind) {
    case WorkPlaneKind::XY: return QStringLiteral("XY");
    case WorkPlaneKind::XZ: return QStringLiteral("XZ");
    case WorkPlaneKind::YZ: return QStringLiteral("YZ");
    case WorkPlaneKind::ObjectPlane: return QStringLiteral("Reference Plane");
    case WorkPlaneKind::FacePlane: return QStringLiteral("Face Plane");
    }
    return QStringLiteral("Work Plane");
}

QString faceKindText(kernel::FaceKind kind) {
    switch (kind) {
    case kernel::FaceKind::Planar: return QStringLiteral("Planar");
    case kernel::FaceKind::Cylindrical: return QStringLiteral("Cylindrical");
    case kernel::FaceKind::Conical: return QStringLiteral("Conical");
    case kernel::FaceKind::Spherical: return QStringLiteral("Spherical");
    case kernel::FaceKind::Other: break;
    }
    return QStringLiteral("Other");
}

QString vectorText(const Vector3& v) {
    return QStringLiteral("%1, %2, %3")
        .arg(v.x, 0, 'f', 3)
        .arg(v.y, 0, 'f', 3)
        .arg(v.z, 0, 'f', 3);
}

void setVector(QDoubleSpinBox* x, QDoubleSpinBox* y, QDoubleSpinBox* z, const Vector3& v) {
    x->setValue(v.x);
    y->setValue(v.y);
    z->setValue(v.z);
}

} // namespace

PropertyPanel::PropertyPanel(QWidget* parent)
    : QWidget(parent) {
    form_ = new QFormLayout(this);

    idLabel_ = new QLabel(this);
    nameEdit_ = new QLineEdit(this);
    typeLabel_ = new QLabel(this);
    kindLabel_ = new QLabel(this);

    form_->addRow(tr("ID"), idLabel_);
    form_->addRow(tr("Name"), nameEdit_);
    form_->addRow(tr("Type"), typeLabel_);
    form_->addRow(tr("Primitive"), kindLabel_);

    positionRow_ = makeVectorRow(positionX_, positionY_, positionZ_, -kTransformLimit, 0.1, 3);
    form_->addRow(tr("Position"), positionRow_);
    // Rotation values are degrees (also stored as degrees in the model).
    rotationRow_ = makeVectorRow(rotationX_, rotationY_, rotationZ_, -kTransformLimit, 5.0, 2);
    form_->addRow(tr("Rotation °"), rotationRow_);
    scaleRow_ = makeVectorRow(scaleX_, scaleY_, scaleZ_, kMinScale, 0.1, 3);
    form_->addRow(tr("Scale"), scaleRow_);

    dimensionWidth_ = makeSpinBox(kMinDimension, 0.1, 3);
    dimensionHeight_ = makeSpinBox(kMinDimension, 0.1, 3);
    dimensionDepth_ = makeSpinBox(kMinDimension, 0.1, 3);
    dimensionRadius_ = makeSpinBox(kMinDimension, 0.1, 3);

    form_->addRow(tr("Width"), dimensionWidth_);
    form_->addRow(tr("Height"), dimensionHeight_);
    form_->addRow(tr("Depth"), dimensionDepth_);
    form_->addRow(tr("Radius"), dimensionRadius_);

    detailsLabel_ = new QLabel(this);
    detailsLabel_->setTextFormat(Qt::PlainText);
    form_->addRow(tr("Details"), detailsLabel_);

    for (QDoubleSpinBox* box : {positionX_, positionY_, positionZ_, rotationX_, rotationY_,
                                rotationZ_, scaleX_, scaleY_, scaleZ_}) {
        connectTransformBox(box);
    }
    for (QDoubleSpinBox* box :
         {dimensionWidth_, dimensionHeight_, dimensionDepth_, dimensionRadius_}) {
        connectDimensionBox(box);
    }

    connect(nameEdit_, &QLineEdit::editingFinished, this, [this]() {
        if (updating_ || currentObjectId_.isEmpty()) {
            return;
        }
        const QString newName = nameEdit_->text().trimmed();
        if (newName.isEmpty()) {
            // Empty names are not allowed: restore the previous one.
            nameEdit_->setText(currentName_);
            return;
        }
        if (newName == currentName_) {
            return;
        }
        currentName_ = newName;
        switch (mode_) {
        case Mode::Object:
            emit nameEdited(currentObjectId_, newName);
            break;
        case Mode::Sketch:
            emit sketchNameEdited(currentObjectId_, newName);
            break;
        case Mode::Entity:
            emit entityNameEdited(currentSketchId_, currentObjectId_, newName);
            break;
        case Mode::None:
            break;
        }
    });

    clearObject();
}

QDoubleSpinBox* PropertyPanel::makeSpinBox(double minimum, double step, int decimals) {
    auto* box = new QDoubleSpinBox(this);
    box->setRange(minimum, kTransformLimit);
    box->setSingleStep(step);
    box->setDecimals(decimals);
    // Emit valueChanged on Enter/focus-out/arrows, not on every keystroke.
    box->setKeyboardTracking(false);
    return box;
}

QWidget* PropertyPanel::makeVectorRow(QDoubleSpinBox*& x, QDoubleSpinBox*& y, QDoubleSpinBox*& z,
                                      double minimum, double step, int decimals) {
    auto* row = new QWidget(this);
    auto* layout = new QHBoxLayout(row);
    layout->setContentsMargins(0, 0, 0, 0);
    x = makeSpinBox(minimum, step, decimals);
    y = makeSpinBox(minimum, step, decimals);
    z = makeSpinBox(minimum, step, decimals);
    layout->addWidget(x);
    layout->addWidget(y);
    layout->addWidget(z);
    return row;
}

void PropertyPanel::connectTransformBox(QDoubleSpinBox* box) {
    connect(box, &QDoubleSpinBox::valueChanged, this, [this](double) { emitTransform(); });
}

void PropertyPanel::connectDimensionBox(QDoubleSpinBox* box) {
    connect(box, &QDoubleSpinBox::valueChanged, this, [this](double) { emitPrimitive(); });
}

void PropertyPanel::emitTransform() {
    if (updating_ || currentObjectId_.isEmpty()) {
        return;
    }
    Transform transform;
    transform.position = {positionX_->value(), positionY_->value(), positionZ_->value()};
    transform.rotationEuler = {rotationX_->value(), rotationY_->value(), rotationZ_->value()};
    transform.scale = {scaleX_->value(), scaleY_->value(), scaleZ_->value()};
    emit transformEdited(currentObjectId_, transform);
}

void PropertyPanel::emitPrimitive() {
    if (updating_ || currentObjectId_.isEmpty()) {
        return;
    }
    PrimitiveParameters parameters;
    parameters.kind = currentKind_;
    parameters.width = dimensionWidth_->value();
    parameters.height = dimensionHeight_->value();
    parameters.depth = dimensionDepth_->value();
    parameters.radius = dimensionRadius_->value();
    emit primitiveEdited(currentObjectId_, parameters);
}

void PropertyPanel::updateDimensionVisibility(const Object& object) {
    bool width = false;
    bool height = false;
    bool depth = false;
    bool radius = false;

    if (object.type == ObjectType::ReferencePlane) {
        width = true;
        height = true;
    } else {
        switch (object.primitive.kind) {
        case PrimitiveKind::Box:
            width = height = depth = true;
            break;
        case PrimitiveKind::Cylinder:
        case PrimitiveKind::Cone:
            radius = height = true;
            break;
        case PrimitiveKind::Sphere:
            radius = true;
            break;
        case PrimitiveKind::None:
            break;
        }
    }

    form_->setRowVisible(dimensionWidth_, width);
    form_->setRowVisible(dimensionHeight_, height);
    form_->setRowVisible(dimensionDepth_, depth);
    form_->setRowVisible(dimensionRadius_, radius);
}

void PropertyPanel::setObjectRowsVisible(bool visible) {
    form_->setRowVisible(positionRow_, visible);
    form_->setRowVisible(rotationRow_, visible);
    form_->setRowVisible(scaleRow_, visible);
    form_->setRowVisible(detailsLabel_, !visible);
}

void PropertyPanel::hideDimensionRows() {
    form_->setRowVisible(dimensionWidth_, false);
    form_->setRowVisible(dimensionHeight_, false);
    form_->setRowVisible(dimensionDepth_, false);
    form_->setRowVisible(dimensionRadius_, false);
}

void PropertyPanel::showObject(const Object& object) {
    updating_ = true;
    mode_ = Mode::Object;

    currentObjectId_ = QString::fromStdString(object.id);
    currentSketchId_.clear();
    currentName_ = QString::fromStdString(object.name);
    currentKind_ = object.primitive.kind;

    idLabel_->setText(currentObjectId_);
    nameEdit_->setText(currentName_);
    nameEdit_->setEnabled(true);
    typeLabel_->setText(objectTypeText(object.type));
    kindLabel_->setText(QString::fromUtf8(primitiveKindName(object.primitive.kind)));

    setVector(positionX_, positionY_, positionZ_, object.transform.position);
    setVector(rotationX_, rotationY_, rotationZ_, object.transform.rotationEuler);
    setVector(scaleX_, scaleY_, scaleZ_, object.transform.scale);

    dimensionWidth_->setValue(object.primitive.width);
    dimensionHeight_->setValue(object.primitive.height);
    dimensionDepth_->setValue(object.primitive.depth);
    dimensionRadius_->setValue(object.primitive.radius);

    setObjectRowsVisible(true);
    updateDimensionVisibility(object);

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::showWorkPlane(const WorkPlane& plane) {
    updating_ = true;
    mode_ = Mode::None;

    currentObjectId_ = QString::fromStdString(plane.id);
    currentSketchId_.clear();
    currentName_ = QString::fromStdString(plane.name);
    currentKind_ = PrimitiveKind::None;

    idLabel_->setText(currentObjectId_);
    nameEdit_->setText(currentName_);
    nameEdit_->setEnabled(false);
    typeLabel_->setText(tr("Work Plane"));
    kindLabel_->setText(workPlaneTypeText(plane.kind));
    detailsLabel_->setText(tr("Origin: %1\nU Axis: %2\nV Axis: %3\nNormal: %4\nWidth: %5\nHeight: %6")
                               .arg(vectorText(plane.origin))
                               .arg(vectorText(plane.uAxis))
                               .arg(vectorText(plane.vAxis))
                               .arg(vectorText(plane.normal))
                               .arg(plane.width, 0, 'f', 3)
                               .arg(plane.height, 0, 'f', 3));

    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::showSketch(const Sketch& sketch) {
    updating_ = true;
    mode_ = Mode::Sketch;

    currentObjectId_ = QString::fromStdString(sketch.id);
    currentSketchId_.clear();
    currentName_ = QString::fromStdString(sketch.name);
    currentKind_ = PrimitiveKind::None;

    idLabel_->setText(currentObjectId_);
    nameEdit_->setText(currentName_);
    nameEdit_->setEnabled(true);
    typeLabel_->setText(tr("Sketch"));
    kindLabel_->setText(QString::fromUtf8(sketchPlaneName(sketch.plane)));
    detailsLabel_->setText(tr("Plane: %1\nEntities: %2")
                               .arg(QString::fromUtf8(sketchPlaneName(sketch.plane)))
                               .arg(sketch.entities.size()));

    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::showSketchEntity(const Sketch& sketch, const SketchEntity& entity) {
    updating_ = true;
    mode_ = Mode::Entity;

    currentObjectId_ = QString::fromStdString(entity.id);
    currentSketchId_ = QString::fromStdString(sketch.id);
    currentName_ = QString::fromStdString(entity.name);
    currentKind_ = PrimitiveKind::None;

    idLabel_->setText(currentObjectId_);
    nameEdit_->setText(currentName_);
    nameEdit_->setEnabled(true);
    typeLabel_->setText(tr("Sketch Entity"));
    kindLabel_->setText(QString::fromUtf8(sketchEntityTypeName(entity.type)));

    // Geometry parameters are read-only in CADNext 0.5; editing arrives
    // with sketch dimensions in 0.6.
    QString details;
    switch (entity.type) {
    case SketchEntityType::Line:
        details = tr("Start U/V: %1, %2\nEnd U/V: %3, %4")
                      .arg(entity.line.start.u, 0, 'f', 3)
                      .arg(entity.line.start.v, 0, 'f', 3)
                      .arg(entity.line.end.u, 0, 'f', 3)
                      .arg(entity.line.end.v, 0, 'f', 3);
        break;
    case SketchEntityType::Rectangle:
        details = tr("Origin U/V: %1, %2\nWidth: %3\nHeight: %4")
                      .arg(entity.rectangle.origin.u, 0, 'f', 3)
                      .arg(entity.rectangle.origin.v, 0, 'f', 3)
                      .arg(entity.rectangle.width, 0, 'f', 3)
                      .arg(entity.rectangle.height, 0, 'f', 3);
        break;
    case SketchEntityType::Circle:
        details = tr("Center U/V: %1, %2\nRadius: %3")
                      .arg(entity.circle.center.u, 0, 'f', 3)
                      .arg(entity.circle.center.v, 0, 'f', 3)
                      .arg(entity.circle.radius, 0, 'f', 3);
        break;
    }
    detailsLabel_->setText(details);

    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::showBodyFace(const QString& bodyName, const kernel::FaceReference& face) {
    updating_ = true;
    mode_ = Mode::None;

    currentObjectId_.clear();
    currentSketchId_.clear();
    currentName_.clear();
    currentKind_ = PrimitiveKind::None;

    idLabel_->setText(QString::fromStdString(face.faceId));
    nameEdit_->setText(bodyName);
    nameEdit_->setEnabled(false);
    typeLabel_->setText(tr("Body Face"));
    kindLabel_->setText(faceKindText(face.kind));
    detailsLabel_->setText(
        tr("Body: %1\nKind: %2\nOrigin: %3\nU Axis: %4\nV Axis: %5\nNormal: %6\n"
           "Size: %7 x %8\nArea: %9\nSketchable: %10")
            .arg(bodyName)
            .arg(faceKindText(face.kind))
            .arg(vectorText(face.origin))
            .arg(vectorText(face.uAxis))
            .arg(vectorText(face.vAxis))
            .arg(vectorText(face.normal))
            .arg(face.width, 0, 'f', 3)
            .arg(face.height, 0, 'f', 3)
            .arg(face.area, 0, 'f', 3)
            .arg(face.isSketchable ? tr("Yes") : tr("No")));

    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::clearObject() {
    updating_ = true;
    mode_ = Mode::None;

    currentObjectId_.clear();
    currentSketchId_.clear();
    currentName_.clear();
    currentKind_ = PrimitiveKind::None;

    const QString placeholder = QStringLiteral("—");
    idLabel_->setText(placeholder);
    nameEdit_->clear();
    nameEdit_->setEnabled(false);
    typeLabel_->setText(placeholder);
    kindLabel_->setText(placeholder);

    for (QDoubleSpinBox* box : {positionX_, positionY_, positionZ_, rotationX_, rotationY_,
                                rotationZ_, dimensionWidth_, dimensionHeight_, dimensionDepth_,
                                dimensionRadius_}) {
        box->setValue(box->minimum() > 0.0 ? box->minimum() : 0.0);
    }
    for (QDoubleSpinBox* box : {scaleX_, scaleY_, scaleZ_}) {
        box->setValue(1.0);
    }
    detailsLabel_->setText(tr("No selection"));

    // Compact empty state: no transform/dimension rows, just the details
    // row reading "No selection" — the inspector dock keeps its size so
    // nothing jumps when objects are created or deselected.
    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(false);
}

} // namespace cadnext::gui
