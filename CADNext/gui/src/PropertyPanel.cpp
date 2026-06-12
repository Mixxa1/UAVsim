#include "cadnext/gui/PropertyPanel.hpp"

#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>

#include "cadnext/SketchMeasure.hpp"
#include "cadnext/Units.hpp"

namespace cadnext::gui {

namespace {

constexpr double kTransformLimit = 1.0e9;
constexpr double kMinScale = 0.001;
constexpr double kMinDimension = 0.001; // model units; 1 mm

QString objectTypeText(ObjectType type) {
    switch (type) {
    case ObjectType::Body: return QStringLiteral("Тело");
    case ObjectType::Sketch: return QStringLiteral("Эскиз");
    case ObjectType::Assembly: return QStringLiteral("Сборка");
    case ObjectType::ReferencePlane: return QStringLiteral("Опорная плоскость");
    case ObjectType::Unknown: break;
    }
    return QStringLiteral("Неизвестно");
}

QString workPlaneTypeText(WorkPlaneKind kind) {
    switch (kind) {
    case WorkPlaneKind::XY: return QStringLiteral("XY");
    case WorkPlaneKind::XZ: return QStringLiteral("XZ");
    case WorkPlaneKind::YZ: return QStringLiteral("YZ");
    case WorkPlaneKind::ObjectPlane: return QStringLiteral("Опорная плоскость");
    case WorkPlaneKind::FacePlane: return QStringLiteral("Плоскость по грани");
    }
    return QStringLiteral("Рабочая плоскость");
}

QString primitiveKindText(PrimitiveKind kind) {
    switch (kind) {
    case PrimitiveKind::Box: return QStringLiteral("Брусок");
    case PrimitiveKind::Cylinder: return QStringLiteral("Цилиндр");
    case PrimitiveKind::Sphere: return QStringLiteral("Сфера");
    case PrimitiveKind::Cone: return QStringLiteral("Конус");
    case PrimitiveKind::None: break;
    }
    return QStringLiteral("—");
}

QString sketchEntityTypeText(SketchEntityType type) {
    switch (type) {
    case SketchEntityType::Line: return QStringLiteral("Линия");
    case SketchEntityType::Rectangle: return QStringLiteral("Прямоугольник");
    case SketchEntityType::Circle: return QStringLiteral("Окружность");
    }
    return QStringLiteral("—");
}

QString faceKindText(kernel::FaceKind kind) {
    switch (kind) {
    case kernel::FaceKind::Planar: return QStringLiteral("Плоская");
    case kernel::FaceKind::Cylindrical: return QStringLiteral("Цилиндрическая");
    case kernel::FaceKind::Conical: return QStringLiteral("Коническая");
    case kernel::FaceKind::Spherical: return QStringLiteral("Сферическая");
    case kernel::FaceKind::Other: break;
    }
    return QStringLiteral("Другая");
}

QString edgeKindText(kernel::EdgeKind kind) {
    switch (kind) {
    case kernel::EdgeKind::Line: return QStringLiteral("Линия");
    case kernel::EdgeKind::Circle: return QStringLiteral("Окружность");
    case kernel::EdgeKind::Ellipse: return QStringLiteral("Эллипс");
    case kernel::EdgeKind::BSpline: return QStringLiteral("B-сплайн");
    case kernel::EdgeKind::Other: break;
    }
    return QStringLiteral("Другое");
}

QString vectorText(const Vector3& v) {
    return QStringLiteral("%1, %2, %3")
        .arg(v.x, 0, 'f', 3)
        .arg(v.y, 0, 'f', 3)
        .arg(v.z, 0, 'f', 3);
}

QString mmText(double modelLength) {
    return QString::fromStdString(formatMillimeters(modelLength));
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
    form_->addRow(tr("Имя"), nameEdit_);
    form_->addRow(tr("Тип"), typeLabel_);
    form_->addRow(tr("Примитив"), kindLabel_);

    positionRow_ = makeVectorRow(positionX_, positionY_, positionZ_, -kTransformLimit, 0.1, 3);
    form_->addRow(tr("Положение"), positionRow_);
    // Rotation values are degrees (also stored as degrees in the model).
    rotationRow_ = makeVectorRow(rotationX_, rotationY_, rotationZ_, -kTransformLimit, 5.0, 2);
    form_->addRow(tr("Поворот, °"), rotationRow_);
    scaleRow_ = makeVectorRow(scaleX_, scaleY_, scaleZ_, kMinScale, 0.1, 3);
    form_->addRow(tr("Масштаб"), scaleRow_);

    // Dimension boxes edit millimeters; the model keeps model units, so
    // emitPrimitive()/showObject() convert at this boundary.
    dimensionWidth_ = makeSpinBox(toMillimeters(kMinDimension), 10.0, 3);
    dimensionHeight_ = makeSpinBox(toMillimeters(kMinDimension), 10.0, 3);
    dimensionDepth_ = makeSpinBox(toMillimeters(kMinDimension), 10.0, 3);
    dimensionRadius_ = makeSpinBox(toMillimeters(kMinDimension), 10.0, 3);
    for (QDoubleSpinBox* box :
         {dimensionWidth_, dimensionHeight_, dimensionDepth_, dimensionRadius_}) {
        box->setSuffix(tr(" мм"));
    }

    form_->addRow(tr("Ширина"), dimensionWidth_);
    form_->addRow(tr("Высота"), dimensionHeight_);
    form_->addRow(tr("Глубина"), dimensionDepth_);
    form_->addRow(tr("Радиус"), dimensionRadius_);

    detailsLabel_ = new QLabel(this);
    detailsLabel_->setTextFormat(Qt::PlainText);
    form_->addRow(tr("Сведения"), detailsLabel_);

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
    parameters.width = fromMillimeters(dimensionWidth_->value());
    parameters.height = fromMillimeters(dimensionHeight_->value());
    parameters.depth = fromMillimeters(dimensionDepth_->value());
    parameters.radius = fromMillimeters(dimensionRadius_->value());
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
    kindLabel_->setText(primitiveKindText(object.primitive.kind));

    setVector(positionX_, positionY_, positionZ_, object.transform.position);
    setVector(rotationX_, rotationY_, rotationZ_, object.transform.rotationEuler);
    setVector(scaleX_, scaleY_, scaleZ_, object.transform.scale);

    dimensionWidth_->setValue(toMillimeters(object.primitive.width));
    dimensionHeight_->setValue(toMillimeters(object.primitive.height));
    dimensionDepth_->setValue(toMillimeters(object.primitive.depth));
    dimensionRadius_->setValue(toMillimeters(object.primitive.radius));

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
    typeLabel_->setText(tr("Рабочая плоскость"));
    kindLabel_->setText(workPlaneTypeText(plane.kind));
    detailsLabel_->setText(
        tr("Начало: %1\nОсь U: %2\nОсь V: %3\nНормаль: %4\nШирина: %5\nВысота: %6")
            .arg(vectorText(plane.origin))
            .arg(vectorText(plane.uAxis))
            .arg(vectorText(plane.vAxis))
            .arg(vectorText(plane.normal))
            .arg(mmText(plane.width))
            .arg(mmText(plane.height)));

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
    typeLabel_->setText(tr("Эскиз"));
    kindLabel_->setText(QString::fromUtf8(sketchPlaneName(sketch.plane)));
    detailsLabel_->setText(tr("Плоскость: %1\nЭлементов: %2")
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
    typeLabel_->setText(tr("Элемент эскиза"));
    kindLabel_->setText(sketchEntityTypeText(entity.type));

    // Geometry parameters are read-only here; all linear dimensions are
    // presented in millimeters.
    QString details;
    switch (entity.type) {
    case SketchEntityType::Line:
        details = tr("Длина: %1\nНачало U/V: %2, %3\nКонец U/V: %4, %5")
                      .arg(mmText(sketchLineLength(entity.line)))
                      .arg(mmText(entity.line.start.u))
                      .arg(mmText(entity.line.start.v))
                      .arg(mmText(entity.line.end.u))
                      .arg(mmText(entity.line.end.v));
        break;
    case SketchEntityType::Rectangle:
        details = tr("Ширина: %1\nВысота: %2\nНачало U/V: %3, %4")
                      .arg(mmText(sketchRectangleWidth(entity.rectangle)))
                      .arg(mmText(sketchRectangleHeight(entity.rectangle)))
                      .arg(mmText(entity.rectangle.origin.u))
                      .arg(mmText(entity.rectangle.origin.v));
        break;
    case SketchEntityType::Circle:
        details = tr("Радиус: %1\nДиаметр: %2\nЦентр U/V: %3, %4")
                      .arg(mmText(sketchCircleRadius(entity.circle)))
                      .arg(mmText(sketchCircleDiameter(entity.circle)))
                      .arg(mmText(entity.circle.center.u))
                      .arg(mmText(entity.circle.center.v));
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
    typeLabel_->setText(tr("Грань тела"));
    kindLabel_->setText(faceKindText(face.kind));
    detailsLabel_->setText(
        tr("Тело: %1\nВид: %2\nНачало: %3\nОсь U: %4\nОсь V: %5\nНормаль: %6\n"
           "Размер: %7 × %8\nПлощадь: %9\nЭскиз возможен: %10")
            .arg(bodyName)
            .arg(faceKindText(face.kind))
            .arg(vectorText(face.origin))
            .arg(vectorText(face.uAxis))
            .arg(vectorText(face.vAxis))
            .arg(vectorText(face.normal))
            .arg(mmText(face.width))
            .arg(mmText(face.height))
            .arg(face.area, 0, 'f', 3)
            .arg(face.isSketchable ? tr("Да") : tr("Нет")));

    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(true);
}

void PropertyPanel::showBodyEdge(const QString& bodyName, const kernel::EdgeReference& edge) {
    updating_ = true;
    mode_ = Mode::None;

    currentObjectId_.clear();
    currentSketchId_.clear();
    currentName_.clear();
    currentKind_ = PrimitiveKind::None;

    idLabel_->setText(QString::fromStdString(edge.edgeId));
    nameEdit_->setText(bodyName);
    nameEdit_->setEnabled(false);
    typeLabel_->setText(tr("Ребро тела"));
    kindLabel_->setText(edgeKindText(edge.kind));
    detailsLabel_->setText(
        tr("Тело: %1\nID ребра: %2\nВид: %3\nДлина: %4\nФаска возможна: %5\n"
           "Скругление возможно: %6\nНачало: %7\nКонец: %8\nЦентр: %9")
            .arg(bodyName)
            .arg(QString::fromStdString(edge.edgeId))
            .arg(edgeKindText(edge.kind))
            .arg(mmText(edge.length))
            .arg(edge.isChamferable ? tr("Да") : tr("Нет"))
            .arg(edge.isFilletable ? tr("Да") : tr("Нет"))
            .arg(vectorText(edge.start))
            .arg(vectorText(edge.end))
            .arg(vectorText(edge.center)));

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
    detailsLabel_->setText(tr("Нет выбора"));

    // Compact empty state: no transform/dimension rows, just the details
    // row reading "Нет выбора" — the inspector dock keeps its size so
    // nothing jumps when objects are created or deselected.
    setObjectRowsVisible(false);
    hideDimensionRows();

    updating_ = false;
    setEnabled(false);
}

} // namespace cadnext::gui
