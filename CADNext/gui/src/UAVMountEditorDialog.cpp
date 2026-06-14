#include "cadnext/gui/UAVMountEditorDialog.hpp"
#include "cadnext/gui/UAVBodySceneBuilder.hpp"
#include "cadnext/gui/UAVMountPairValidator.hpp"

#include <QDateTime>
#include <QDebug>
#include <QDoubleSpinBox>
#include <QDir>
#include <QFile>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QListWidget>
#include <QMessageBox>
#include <QPushButton>
#include <QSizePolicy>
#include <QVBoxLayout>
#include <QWidget>

#include <Inventor/Qt/viewers/SoQtExaminerViewer.h>
#include <Inventor/SbColor.h>
#include <Inventor/SbRotation.h>
#include <Inventor/SbVec3f.h>
#include <Inventor/nodes/SoCoordinate3.h>
#include <Inventor/nodes/SoCube.h>
#include <Inventor/nodes/SoCylinder.h>
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoLineSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoSphere.h>
#include <Inventor/nodes/SoTransform.h>

#include <cmath>
#include <limits>

namespace cadnext::gui {

namespace {

static constexpr float kPi = 3.14159265f;
static constexpr float kPlacementEpsilon = 1.0e-4f; // 0.1 mm

// Thin cylinder drawn between two 3D points — used for debug axis arrows.
SoSeparator* debugBeam(SbVec3f from, SbVec3f to, float r, float g, float b)
{
    SbVec3f delta = to - from;
    float len = delta.length();
    if (len < 1e-5f) return new SoSeparator;
    SbVec3f dir = delta / len;
    SbVec3f mid = (from + to) * 0.5f;

    static const SbVec3f kY(0,1,0);
    float dot = dir.dot(kY);
    SbRotation rot;
    if (dot > 1.0f - 1e-4f)       rot = SbRotation(SbVec3f(0,0,1), 0.0f);
    else if (dot < -1.0f + 1e-4f)  rot = SbRotation(SbVec3f(1,0,0), kPi);
    else                            rot = SbRotation(kY, dir);

    auto* sep = new SoSeparator;
    auto* mat = new SoMaterial;
    mat->diffuseColor.setValue(r, g, b);
    mat->emissiveColor.setValue(r * 0.55f, g * 0.55f, b * 0.55f);
    sep->addChild(mat);
    auto* xf = new SoTransform;
    xf->translation.setValue(mid);
    xf->rotation.setValue(rot);
    sep->addChild(xf);
    auto* cyl = new SoCylinder;
    cyl->radius = 0.0025f; // 2.5 mm
    cyl->height = len;
    sep->addChild(cyl);
    return sep;
}

void parseHexColor(const std::string& hex, float& r, float& g, float& b)
{
    r = 0.55f; g = 0.65f; b = 0.75f;
    if (hex.size() < 7 || hex[0] != '#') return;
    try {
        r = std::stoi(hex.substr(1, 2), nullptr, 16) / 255.0f;
        g = std::stoi(hex.substr(3, 2), nullptr, 16) / 255.0f;
        b = std::stoi(hex.substr(5, 2), nullptr, 16) / 255.0f;
    } catch (...) {}
}

QString vehicleTypeRu(UAVPreviewVehicleType t)
{
    switch (t) {
    case UAVPreviewVehicleType::multicopter: return QObject::tr("Мультикоптер");
    case UAVPreviewVehicleType::fixedWing:   return QObject::tr("Самолётного типа");
    case UAVPreviewVehicleType::hybridVTOL:  return QObject::tr("Гибрид VTOL");
    case UAVPreviewVehicleType::helicopter:  return QObject::tr("Вертолёт");
    case UAVPreviewVehicleType::custom:      return QObject::tr("Прочий");
    }
    return QObject::tr("Неизвестный");
}

SbVec3f toSbVec3f(const UAVVec3& v)
{
    return SbVec3f(static_cast<float>(v.x),
                   static_cast<float>(v.y),
                   static_cast<float>(v.z));
}

SbVec3f toSbVec3f(const Vector3& v)
{
    return SbVec3f(static_cast<float>(v.x),
                   static_cast<float>(v.y),
                   static_cast<float>(v.z));
}

SbRotation eulerXYZRotation(float degreesX, float degreesY, float degreesZ)
{
    const float toRad = kPi / 180.0f;
    const SbRotation rx(SbVec3f(1,0,0), degreesX * toRad);
    const SbRotation ry(SbVec3f(0,1,0), degreesY * toRad);
    const SbRotation rz(SbVec3f(0,0,1), degreesZ * toRad);
    return rx * ry * rz;
}

SbRotation eulerXYZRotation(const UAVVec3& degrees)
{
    return eulerXYZRotation(static_cast<float>(degrees.x),
                            static_cast<float>(degrees.y),
                            static_cast<float>(degrees.z));
}

SbRotation eulerXYZRotation(const Vector3& degrees)
{
    return eulerXYZRotation(static_cast<float>(degrees.x),
                            static_cast<float>(degrees.y),
                            static_cast<float>(degrees.z));
}

bool hasExplicitRotation(const UAVVec3& degrees)
{
    return std::fabs(degrees.x) > 1.0e-6
        || std::fabs(degrees.y) > 1.0e-6
        || std::fabs(degrees.z) > 1.0e-6;
}

SbRotation rotationFromYToDirection(SbVec3f direction)
{
    if (direction.length() < 1.0e-6f) {
        return SbRotation::identity();
    }
    direction.normalize();

    static const SbVec3f kY(0.0f, 1.0f, 0.0f);
    const float dot = kY.dot(direction);
    if (dot > 1.0f - 1.0e-4f) {
        return SbRotation::identity();
    }
    if (dot < -1.0f + 1.0e-4f) {
        return SbRotation(SbVec3f(1.0f, 0.0f, 0.0f), kPi);
    }
    return SbRotation(kY, direction);
}

SbRotation mountPointRotation(const UAVMountPointPreview& uavPt)
{
    if (hasExplicitRotation(uavPt.localRotation)) {
        return eulerXYZRotation(uavPt.localRotation);
    }
    return rotationFromYToDirection(toSbVec3f(uavPt.mountNormal));
}

SbRotation attachmentPointRotation(
    const bridge::UAVPartAttachmentPoint& partPt,
    const UAVPartPreflightData& partData)
{
    if (hasExplicitRotation({partPt.localRotation.x,
                             partPt.localRotation.y,
                             partPt.localRotation.z})) {
        return eulerXYZRotation(partPt.localRotation);
    }

    const SbVec3f boundsCenter(
        static_cast<float>((partData.partBoundingBoxMin.x + partData.partBoundingBoxMax.x) * 0.5),
        static_cast<float>((partData.partBoundingBoxMin.y + partData.partBoundingBoxMax.y) * 0.5),
        static_cast<float>((partData.partBoundingBoxMin.z + partData.partBoundingBoxMax.z) * 0.5));
    const SbVec3f bodySideDirection = boundsCenter - toSbVec3f(partPt.localPosition);
    if (bodySideDirection.length() < 1.0e-6f) {
        return SbRotation::identity();
    }
    return rotationFromYToDirection(bodySideDirection);
}

struct GhostPlacement {
    SbRotation finalRotation = SbRotation::identity();
    SbVec3f finalPosition;
    SbVec3f mountPosition;
    SbVec3f attachmentWorldPosition;
    float snapError = 0.0f;

    bool isSnapped() const { return snapError <= kPlacementEpsilon; }
};

GhostPlacement computeGhostPlacement(
    const UAVMountPointPreview& uavPt,
    const bridge::UAVPartAttachmentPoint& partPt,
    const UAVPartPreflightData& partData,
    float userRx, float userRy, float userRz)
{
    const SbVec3f mountPosition = toSbVec3f(uavPt.localPosition);
    const SbVec3f attachmentLocalPosition = toSbVec3f(partPt.localPosition);

    const SbRotation uavMountLocalRotation = mountPointRotation(uavPt);
    const SbRotation userRotationOffset = eulerXYZRotation(userRx, userRy, userRz);
    const SbRotation partAttachmentLocalRotation = attachmentPointRotation(partPt, partData);

    GhostPlacement placement;
    placement.finalRotation =
        uavMountLocalRotation * userRotationOffset * partAttachmentLocalRotation.inverse();

    SbVec3f rotatedAttachment;
    placement.finalRotation.multVec(attachmentLocalPosition, rotatedAttachment);
    placement.finalPosition = mountPosition - rotatedAttachment;
    placement.mountPosition = mountPosition;
    placement.attachmentWorldPosition = placement.finalPosition + rotatedAttachment;
    placement.snapError = (placement.attachmentWorldPosition - mountPosition).length();
    return placement;
}

QJsonObject jsonVec3(double x, double y, double z)
{
    QJsonObject obj;
    obj.insert(QStringLiteral("x"), x);
    obj.insert(QStringLiteral("y"), y);
    obj.insert(QStringLiteral("z"), z);
    return obj;
}

QJsonObject jsonVec3(const UAVVec3& v)
{
    return jsonVec3(v.x, v.y, v.z);
}

QJsonObject jsonVec3(const Vector3& v)
{
    return jsonVec3(v.x, v.y, v.z);
}

QJsonArray jsonFloatArray(const std::vector<float>& values)
{
    QJsonArray arr;
    for (float value : values) {
        arr.append(static_cast<double>(value));
    }
    return arr;
}

QJsonArray jsonUIntArray(const std::vector<uint32_t>& values)
{
    QJsonArray arr;
    for (uint32_t value : values) {
        arr.append(static_cast<double>(value));
    }
    return arr;
}

bool isFinitePlacement(const GhostPlacement& placement)
{
    const auto finiteVec = [](const SbVec3f& v) {
        return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
    };
    SbVec3f axis;
    float angle = 0.0f;
    placement.finalRotation.getValue(axis, angle);
    return finiteVec(placement.finalPosition)
        && finiteVec(placement.attachmentWorldPosition)
        && finiteVec(axis)
        && std::isfinite(angle)
        && std::isfinite(placement.snapError);
}

QString cadPayloadHandoffPath()
{
    return QDir::temp().filePath(QStringLiteral("uavsim_cad_payload_handoff.json"));
}

bool writeSimulationHandoff(
    const UAVPartPreflightData& partData,
    const UAVCatalogPreviewItem& uav,
    const UAVPayloadCompatibilityResult& compat,
    const bridge::UAVPartAttachmentPoint& partPt,
    const UAVMountPointPreview& uavPt,
    const MountPairValidationResult& mountValidation,
    const GhostPlacement& placement,
    double userRotX,
    double userRotY,
    double userRotZ,
    const QString& createdAt,
    QString* outPath,
    QString* outError)
{
    if (!partData.massValid || partData.massKg <= 0.0) {
        if (outError) *outError = QObject::tr("Файл .uavpart поврежден или massProperties invalid");
        return false;
    }
    if (!partData.boundsValid) {
        if (outError) *outError = QObject::tr("Габариты CAD-детали повреждены");
        return false;
    }
    if (!isFinitePlacement(placement)) {
        if (outError) *outError = QObject::tr("Ошибка положения детали: точки крепления не совпадают");
        return false;
    }
    if (!placement.isSnapped()) {
        if (outError) *outError = QObject::tr("Не удалось корректно совместить точки крепления");
        return false;
    }
    if (compat.payloadMassKg > compat.maxPayloadMassKg + 1.0e-6) {
        if (outError) *outError = QObject::tr("Масса детали превышает допустимую нагрузку БЛА");
        return false;
    }
    if (compat.totalMassKg > compat.maxTakeoffMassKg + 1.0e-6) {
        if (outError) *outError = QObject::tr("Превышена максимальная взлетная масса");
        return false;
    }
    if (mountValidation.status == MountPairValidationResult::Status::blocked) {
        if (outError) *outError = QObject::tr("Не удалось корректно совместить точки крепления");
        return false;
    }

    const QString payloadId = QStringLiteral("cad-payload-%1")
        .arg(QDateTime::currentMSecsSinceEpoch());

    QJsonObject collisionProxy;
    collisionProxy.insert(QStringLiteral("type"),
                          QString::fromStdString(partData.collisionProxy.type));
    collisionProxy.insert(QStringLiteral("center"), jsonVec3(partData.collisionProxy.center));
    collisionProxy.insert(QStringLiteral("size"), jsonVec3(partData.collisionProxy.size));
    collisionProxy.insert(QStringLiteral("source"),
                          QString::fromStdString(partData.collisionProxy.source));
    collisionProxy.insert(QStringLiteral("valid"), partData.collisionProxy.valid);

    QJsonArray validationErrors;
    for (const auto& err : mountValidation.errors) {
        validationErrors.append(QString::fromStdString(err));
    }
    QJsonArray validationWarnings;
    for (const auto& warning : mountValidation.warnings) {
        validationWarnings.append(QString::fromStdString(warning));
    }
    for (const auto& warning : compat.warnings) {
        validationWarnings.append(QString::fromStdString(warning));
    }

    SbVec3f finalAxis;
    float finalAngleRad = 0.0f;
    placement.finalRotation.getValue(finalAxis, finalAngleRad);

    QJsonObject visualMesh;
    visualMesh.insert(QStringLiteral("valid"), partData.hasMesh && !partData.meshVertices.empty());
    visualMesh.insert(QStringLiteral("vertices"), jsonFloatArray(partData.meshVertices));
    visualMesh.insert(QStringLiteral("indices"), jsonUIntArray(partData.meshIndices));

    QJsonObject mountedPayload;
    mountedPayload.insert(QStringLiteral("id"), payloadId);
    mountedPayload.insert(QStringLiteral("partID"), QString::fromStdString(partData.partId));
    mountedPayload.insert(QStringLiteral("partFileURL"), QString::fromStdString(partData.partFilePath));
    mountedPayload.insert(QStringLiteral("partName"),
                          QString::fromStdString(partData.partDisplayName.empty()
                              ? partData.partId
                              : partData.partDisplayName));
    mountedPayload.insert(QStringLiteral("sourceUAVPartManifestID"), QString::fromStdString(partData.partId));
    mountedPayload.insert(QStringLiteral("massKg"), partData.massKg);
    mountedPayload.insert(QStringLiteral("centerOfMassLocal"), jsonVec3(partData.partCenterOfMass));
    mountedPayload.insert(QStringLiteral("boundingWidth"), partData.boundingWidth);
    mountedPayload.insert(QStringLiteral("boundingHeight"), partData.boundingHeight);
    mountedPayload.insert(QStringLiteral("boundingDepth"), partData.boundingDepth);
    mountedPayload.insert(QStringLiteral("boundingBoxMin"), jsonVec3(partData.partBoundingBoxMin));
    mountedPayload.insert(QStringLiteral("boundingBoxMax"), jsonVec3(partData.partBoundingBoxMax));
    mountedPayload.insert(QStringLiteral("dragPenalty"), partData.dragPenalty);
    mountedPayload.insert(QStringLiteral("structuralRating"), partData.structuralRating);
    mountedPayload.insert(QStringLiteral("materialID"), QString::fromStdString(partData.materialId));
    mountedPayload.insert(QStringLiteral("materialPreviewColor"), QString::fromStdString(partData.materialPreviewColor));
    mountedPayload.insert(QStringLiteral("payloadAttachmentPointID"), QString::fromStdString(partPt.id));
    mountedPayload.insert(QStringLiteral("payloadAttachmentPointName"), QString::fromStdString(partPt.name));
    mountedPayload.insert(QStringLiteral("uavMountPointID"), QString::fromStdString(uavPt.id));
    mountedPayload.insert(QStringLiteral("uavMountPointName"), QString::fromStdString(uavPt.name));
    mountedPayload.insert(QStringLiteral("localPositionOnUAV"),
                          jsonVec3(placement.finalPosition[0],
                                   placement.finalPosition[1],
                                   placement.finalPosition[2]));
    mountedPayload.insert(QStringLiteral("localRotationOnUAV"),
                          QJsonObject{
                              {QStringLiteral("axisX"), finalAxis[0]},
                              {QStringLiteral("axisY"), finalAxis[1]},
                              {QStringLiteral("axisZ"), finalAxis[2]},
                              {QStringLiteral("angleRad"), finalAngleRad}
                          });
    mountedPayload.insert(QStringLiteral("userRotationOffset"), jsonVec3(userRotX, userRotY, userRotZ));
    mountedPayload.insert(QStringLiteral("userPositionOffset"), jsonVec3(0.0, 0.0, 0.0));
    mountedPayload.insert(QStringLiteral("visualPreviewMode"),
                          partData.hasMesh ? QStringLiteral("visualMesh") : QStringLiteral("boundsProxy"));
    mountedPayload.insert(QStringLiteral("visualMesh"), visualMesh);
    mountedPayload.insert(QStringLiteral("collisionProxy"), collisionProxy);
    mountedPayload.insert(QStringLiteral("mountValidationResult"),
                          QJsonObject{
                              {QStringLiteral("isValid"), true},
                              {QStringLiteral("snapError"), placement.snapError},
                              {QStringLiteral("errors"), validationErrors},
                              {QStringLiteral("warnings"), validationWarnings}
                          });
    mountedPayload.insert(QStringLiteral("createdAt"), createdAt);

    QJsonObject config;
    config.insert(QStringLiteral("schemaVersion"), 1);
    config.insert(QStringLiteral("selectedUAVProfile"), QString::fromStdString(uav.id));
    config.insert(QStringLiteral("selectedMapProfile"), QStringLiteral("default"));
    config.insert(QStringLiteral("mountedCADPayload"), mountedPayload);
    config.insert(QStringLiteral("launchSource"), QStringLiteral("cadPayloadTest"));
    config.insert(QStringLiteral("initialPayloadState"), QStringLiteral("mounted"));

    const QString path = cadPayloadHandoffPath();
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        if (outError) *outError = file.errorString();
        return false;
    }
    file.write(QJsonDocument(config).toJson(QJsonDocument::Indented));
    file.close();
    if (outPath) *outPath = path;
    return true;
}

void addDebugSphere(SoSeparator* root, const SbVec3f& position, float radius,
                    float r, float g, float b, float transparency = 0.0f)
{
    auto* sep = new SoSeparator;
    auto* mat = new SoMaterial;
    mat->diffuseColor.setValue(r, g, b);
    mat->emissiveColor.setValue(r * 0.35f, g * 0.35f, b * 0.35f);
    mat->transparency.setValue(transparency);
    sep->addChild(mat);

    auto* xf = new SoTransform;
    xf->translation.setValue(position);
    sep->addChild(xf);

    auto* sp = new SoSphere;
    sp->radius = radius;
    sep->addChild(sp);
    root->addChild(sep);
}

void addRotationAxes(SoSeparator* root, const SbVec3f& origin,
                     const SbRotation& rotation, float length)
{
    SbVec3f xAxis;
    SbVec3f yAxis;
    SbVec3f zAxis;
    rotation.multVec(SbVec3f(1,0,0), xAxis);
    rotation.multVec(SbVec3f(0,1,0), yAxis);
    rotation.multVec(SbVec3f(0,0,1), zAxis);

    root->addChild(debugBeam(origin, origin + xAxis * length, 1.0f, 0.20f, 0.20f));
    root->addChild(debugBeam(origin, origin + yAxis * length, 0.20f, 1.0f, 0.20f));
    root->addChild(debugBeam(origin, origin + zAxis * length, 0.20f, 0.45f, 1.0f));
}

void addGhostAttachmentMarker(SoSeparator* root, const SbVec3f& localPosition)
{
    auto* markerSep = new SoSeparator;

    auto* markerMat = new SoMaterial;
    markerMat->diffuseColor.setValue(1.0f, 0.18f, 0.85f);
    markerMat->emissiveColor.setValue(0.45f, 0.02f, 0.35f);
    markerMat->specularColor.setValue(0.65f, 0.65f, 0.65f);
    markerMat->shininess.setValue(0.65f);
    markerSep->addChild(markerMat);

    auto* markerXf = new SoTransform;
    markerXf->translation.setValue(localPosition);
    markerSep->addChild(markerXf);

    auto* marker = new SoSphere;
    marker->radius = 0.018f;
    markerSep->addChild(marker);

    root->addChild(markerSep);
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
UAVMountEditorDialog::UAVMountEditorDialog(
    const UAVPartPreflightData&         partData,
    const UAVCatalogPreviewItem&        uav,
    const UAVPayloadCompatibilityResult& compat,
    QWidget*                            parent)
    : QDialog(parent)
    , partData_(partData)
    , uav_(uav)
    , compat_(compat)
{
    setWindowTitle(tr("Крепление детали на БЛА: %1")
                   .arg(QString::fromStdString(uav.name)));
    setMinimumSize(1050, 680);
    resize(1120, 730);

    // ── Scene graph setup ────────────────────────────────────────────────────
    sceneRoot_   = new SoSeparator; sceneRoot_->ref();
    markersRoot_ = new SoSeparator; markersRoot_->ref();
    ghostRoot_   = new SoSeparator; ghostRoot_->ref();
    debugRoot_   = new SoSeparator; debugRoot_->ref();

    SoSeparator* bodyRoot = UAVBodySceneBuilder::buildScene(
        uav.id, uav.vehicleType, uav.massCategory);

    sceneRoot_->addChild(bodyRoot);
    sceneRoot_->addChild(markersRoot_);
    sceneRoot_->addChild(ghostRoot_);
    sceneRoot_->addChild(debugRoot_);

    rebuildMarkersScene();

    // ── 3D viewer ────────────────────────────────────────────────────────────
    auto* viewerContainer = new QWidget;
    viewerContainer->setMinimumSize(580, 460);
    viewerContainer->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);

    viewer_ = new SoQtExaminerViewer(viewerContainer);
    viewer_->setSceneGraph(sceneRoot_);
    viewer_->setBackgroundColor(SbColor(0.12f, 0.12f, 0.14f));
    viewer_->setDecoration(false);
    viewer_->viewAll();
    viewer_->show();

    // ── Right panel ──────────────────────────────────────────────────────────
    auto* rightWidget = new QWidget;
    rightWidget->setMinimumWidth(380);
    rightWidget->setMaximumWidth(440);
    auto* rightLayout = new QVBoxLayout(rightWidget);
    rightLayout->setContentsMargins(6, 6, 6, 6);
    rightLayout->setSpacing(6);

    // UAV info summary
    {
        auto* grp  = new QGroupBox(tr("Характеристики БЛА"));
        auto* form = new QFormLayout(grp);
        form->setContentsMargins(4, 4, 4, 4);
        form->setSpacing(2);

        auto addRow = [&](const QString& label, const QString& value) {
            auto* lbl = new QLabel(value);
            lbl->setWordWrap(true);
            form->addRow(label, lbl);
        };
        addRow(tr("Тип:"),        vehicleTypeRu(uav.vehicleType));
        addRow(tr("Страна:"),     QString::fromStdString(uav.country));
        addRow(tr("Масса БЛА:"),  QString("%1 кг").arg(uav.emptyMassKg,      0,'f',2));
        addRow(tr("Макс. нагр.:"),QString("%1 кг").arg(uav.maxPayloadMassKg, 0,'f',2));
        addRow(tr("MTOW:"),       QString("%1 кг").arg(uav.maxTakeoffMassKg, 0,'f',1));
        // Model source: always procedural for now; updated when sim model is wired in.
        addRow(tr("Источник модели:"), tr("Используется резервная модель БЛА"));
        rightLayout->addWidget(grp);
    }

    // Part attachment points list
    {
        auto* grp = new QGroupBox(tr("Точки крепления детали"));
        auto* vb  = new QVBoxLayout(grp);
        vb->setContentsMargins(4, 4, 4, 4);
        partPtList_ = new QListWidget;
        partPtList_->setMaximumHeight(110);
        for (const auto& pt : partData_.attachmentPoints) {
            partPtList_->addItem(
                QString::fromStdString(pt.name + "  [" + pt.role + "]"));
        }
        vb->addWidget(partPtList_);
        rightLayout->addWidget(grp);
    }

    // UAV mount points list
    {
        auto* grp = new QGroupBox(tr("Точки крепления БЛА"));
        auto* vb  = new QVBoxLayout(grp);
        vb->setContentsMargins(4, 4, 4, 4);
        uavPtList_ = new QListWidget;
        uavPtList_->setMaximumHeight(130);
        for (const auto& mp : uav_.mountPoints) {
            const QString suf = mp.isEnabled ? "" : tr("  (откл.)");
            uavPtList_->addItem(
                QString::fromStdString(mp.name + "  [" + mp.role + "]") + suf);
        }
        vb->addWidget(uavPtList_);
        rightLayout->addWidget(grp);
    }

    // Rotation controls
    {
        auto* grp  = new QGroupBox(tr("Вращение детали"));
        auto* form = new QFormLayout(grp);
        form->setContentsMargins(4, 4, 4, 4);

        auto makeSpin = []() {
            auto* sp = new QDoubleSpinBox;
            sp->setRange(-360.0, 360.0);
            sp->setSingleStep(1.0);
            sp->setDecimals(1);
            sp->setSuffix("°");
            return sp;
        };
        spinRotX_ = makeSpin();
        spinRotY_ = makeSpin();
        spinRotZ_ = makeSpin();

        form->addRow(tr("Крен (X):"),     spinRotX_);
        form->addRow(tr("Тангаж (Y):"),   spinRotY_);
        form->addRow(tr("Рысканье (Z):"), spinRotZ_);

        auto* btnRow    = new QHBoxLayout;
        auto* resetBtn  = new QPushButton(tr("Сбросить"));
        auto* flipBtn   = new QPushButton(tr("Перевернуть 180°"));
        btnRow->addWidget(resetBtn);
        btnRow->addWidget(flipBtn);
        form->addRow(btnRow);
        rightLayout->addWidget(grp);

        connect(resetBtn, &QPushButton::clicked, this, [this]() {
            spinRotX_->setValue(0.0);
            spinRotY_->setValue(0.0);
            spinRotZ_->setValue(0.0);
        });
        connect(flipBtn, &QPushButton::clicked, this, [this]() {
            spinRotY_->setValue(spinRotY_->value() + 180.0);
        });
        for (auto* sp : {spinRotX_, spinRotY_, spinRotZ_}) {
            connect(sp, &QDoubleSpinBox::valueChanged, this, [this](double) {
                rebuildGhostPreview();
                runValidation();
            });
        }
    }

    // Validation panel
    {
        auto* grp = new QGroupBox(tr("Статус монтажа"));
        auto* vb  = new QVBoxLayout(grp);
        vb->setContentsMargins(4, 4, 4, 4);
        valStatus_   = new QLabel(tr("Выберите точки крепления"));
        valErrors_   = new QLabel;
        valWarnings_ = new QLabel;
        valErrors_->setWordWrap(true);
        valWarnings_->setWordWrap(true);
        valStatus_->setStyleSheet("font-weight: bold;");
        vb->addWidget(valStatus_);
        vb->addWidget(valErrors_);
        vb->addWidget(valWarnings_);
        rightLayout->addWidget(grp);
    }

    rightLayout->addStretch();

    // ── Root layout ──────────────────────────────────────────────────────────
    auto* contentRow = new QHBoxLayout;
    contentRow->setSpacing(8);
    contentRow->addWidget(viewerContainer, 3);
    contentRow->addWidget(rightWidget, 0);

    auto* btnRow   = new QHBoxLayout;
    auto* backBtn  = new QPushButton(tr("Назад к выбору БЛА"));
    confirmBtn_    = new QPushButton(tr("Подтвердить и запустить симуляцию"));
    auto* closeBtn = new QPushButton(tr("Закрыть"));
    confirmBtn_->setEnabled(false);
    confirmBtn_->setToolTip(tr("Выберите точку крепления детали"));
    closeBtn->setDefault(true);

    btnRow->addWidget(backBtn);
    btnRow->addStretch();
    btnRow->addWidget(confirmBtn_);
    btnRow->addWidget(closeBtn);

    auto* root = new QVBoxLayout(this);
    root->setContentsMargins(12, 12, 12, 12);
    root->setSpacing(8);
    root->addLayout(contentRow, 1);
    root->addLayout(btnRow);

    connect(backBtn,  &QPushButton::clicked, this, [this]() {
        wentBack_ = true;
        reject();
    });
    connect(closeBtn, &QPushButton::clicked, this, &QDialog::reject);
    connect(confirmBtn_, &QPushButton::clicked, this, &UAVMountEditorDialog::onConfirm);

    connect(partPtList_, &QListWidget::currentRowChanged,
            this, [this](int row) {
                selectedPartPtIdx_ = row;
                rebuildGhostPreview();
                runValidation();
            });
    connect(uavPtList_, &QListWidget::currentRowChanged,
            this, [this](int row) {
                selectedUAVPtIdx_ = row;
                rebuildMarkersScene();
                rebuildGhostPreview();
                runValidation();
            });
}

UAVMountEditorDialog::~UAVMountEditorDialog()
{
    delete viewer_;
    viewer_ = nullptr;
    sceneRoot_->unref();
    markersRoot_->unref();
    ghostRoot_->unref();
    debugRoot_->unref();
}

// ─────────────────────────────────────────────────────────────────────────────
void UAVMountEditorDialog::rebuildMarkersScene()
{
    markersRoot_->removeAllChildren();

    for (int i = 0; i < static_cast<int>(uav_.mountPoints.size()); ++i) {
        const auto& mp        = uav_.mountPoints[i];
        const bool  selected  = (i == selectedUAVPtIdx_);

        auto* sep = new SoSeparator;

        auto* mat = new SoMaterial;
        if (!mp.isEnabled) {
            mat->diffuseColor.setValue(0.35f, 0.35f, 0.35f);
            mat->transparency.setValue(0.5f);
        } else if (selected) {
            mat->diffuseColor.setValue(0.15f, 0.90f, 0.15f);
            mat->transparency.setValue(0.0f);
        } else {
            mat->diffuseColor.setValue(0.90f, 0.55f, 0.10f);
            mat->transparency.setValue(0.25f);
        }
        sep->addChild(mat);

        auto* xf = new SoTransform;
        xf->translation.setValue(
            static_cast<float>(mp.localPosition.x),
            static_cast<float>(mp.localPosition.y),
            static_cast<float>(mp.localPosition.z));
        sep->addChild(xf);

        auto* sp = new SoSphere;
        sp->radius = 0.015f;
        sep->addChild(sp);

        markersRoot_->addChild(sep);
    }

    rebuildDebugOverlay();
}

void UAVMountEditorDialog::rebuildGhostPreview()
{
    ghostRoot_->removeAllChildren();

    if (selectedPartPtIdx_ < 0 || selectedUAVPtIdx_ < 0) {
        rebuildDebugOverlay();
        return;
    }
    if (selectedPartPtIdx_ >= static_cast<int>(partData_.attachmentPoints.size())
     || selectedUAVPtIdx_  >= static_cast<int>(uav_.mountPoints.size())) {
        rebuildDebugOverlay();
        return;
    }

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];

    const GhostPlacement placement = computeGhostPlacement(
        uavPt, partPt, partData_,
        static_cast<float>(spinRotX_->value()),
        static_cast<float>(spinRotY_->value()),
        static_cast<float>(spinRotZ_->value()));
    const SbVec3f partAttachmentLocal = toSbVec3f(partPt.localPosition);

    auto* ghostSep = new SoSeparator;

    auto* ghostMat = new SoMaterial;
    float r = 0.55f, g = 0.65f, b = 0.75f;
    parseHexColor(partData_.materialPreviewColor, r, g, b);
    ghostMat->diffuseColor.setValue(r, g, b);
    ghostMat->transparency.setValue(0.50f);
    ghostSep->addChild(ghostMat);

    auto* hints = new SoShapeHints;
    hints->vertexOrdering = SoShapeHints::COUNTERCLOCKWISE;
    hints->shapeType      = SoShapeHints::UNKNOWN_SHAPE_TYPE;
    ghostSep->addChild(hints);

    auto* xf = new SoTransform;
    xf->translation.setValue(placement.finalPosition);
    xf->rotation.setValue(placement.finalRotation);
    ghostSep->addChild(xf);

    if (partData_.hasMesh && !partData_.meshVertices.empty()) {
        const int nVerts = static_cast<int>(partData_.meshVertices.size()) / 3;
        auto* coords = new SoCoordinate3;
        coords->point.setNum(nVerts);
        for (int vi = 0; vi < nVerts; ++vi) {
            coords->point.set1Value(vi,
                SbVec3f(partData_.meshVertices[vi*3+0],
                        partData_.meshVertices[vi*3+1],
                        partData_.meshVertices[vi*3+2]));
        }
        ghostSep->addChild(coords);

        const int nTri = static_cast<int>(partData_.meshIndices.size()) / 3;
        auto* ifs = new SoIndexedFaceSet;
        ifs->coordIndex.setNum(nTri * 4);
        for (int ti = 0; ti < nTri; ++ti) {
            ifs->coordIndex.set1Value(ti*4+0, static_cast<int>(partData_.meshIndices[ti*3+0]));
            ifs->coordIndex.set1Value(ti*4+1, static_cast<int>(partData_.meshIndices[ti*3+1]));
            ifs->coordIndex.set1Value(ti*4+2, static_cast<int>(partData_.meshIndices[ti*3+2]));
            ifs->coordIndex.set1Value(ti*4+3, SO_END_FACE_INDEX);
        }
        ghostSep->addChild(ifs);
    } else {
        auto* boundsSep = new SoSeparator;
        auto* boundsXf = new SoTransform;
        boundsXf->translation.setValue(
            static_cast<float>((partData_.partBoundingBoxMin.x + partData_.partBoundingBoxMax.x) * 0.5),
            static_cast<float>((partData_.partBoundingBoxMin.y + partData_.partBoundingBoxMax.y) * 0.5),
            static_cast<float>((partData_.partBoundingBoxMin.z + partData_.partBoundingBoxMax.z) * 0.5));
        boundsSep->addChild(boundsXf);

        auto* box = new SoCube;
        box->width  = static_cast<float>(partData_.boundingWidth);
        box->height = static_cast<float>(partData_.boundingHeight);
        box->depth  = static_cast<float>(partData_.boundingDepth);
        boundsSep->addChild(box);
        ghostSep->addChild(boundsSep);
    }

    addGhostAttachmentMarker(ghostSep, partAttachmentLocal);

    ghostRoot_->addChild(ghostSep);

    rebuildDebugOverlay();
}

// ─────────────────────────────────────────────────────────────────────────────
void UAVMountEditorDialog::rebuildDebugOverlay()
{
    debugRoot_->removeAllChildren();

    if (selectedUAVPtIdx_ < 0
     || selectedUAVPtIdx_ >= static_cast<int>(uav_.mountPoints.size()))
        return;

    const auto& uavPt = uav_.mountPoints[selectedUAVPtIdx_];
    const SbVec3f mountPt = toSbVec3f(uavPt.localPosition);
    const SbRotation mountRotation = mountPointRotation(uavPt);

    const float axLen = 0.06f; // 6 cm axes

    // Local axes at the selected UAV mount point (X=red, Y=green, Z=blue).
    addRotationAxes(debugRoot_, mountPt, mountRotation, axLen);

    // UAV model origin marker.
    addDebugSphere(debugRoot_, SbVec3f(0,0,0), 0.010f, 0.55f, 0.55f, 0.55f, 0.45f);

    // Part-attachment section — only when a part point is also selected.
    if (selectedPartPtIdx_ < 0
     || selectedPartPtIdx_ >= static_cast<int>(partData_.attachmentPoints.size()))
        return;

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const GhostPlacement placement = computeGhostPlacement(
        uavPt, partPt, partData_,
        static_cast<float>(spinRotX_->value()),
        static_cast<float>(spinRotY_->value()),
        static_cast<float>(spinRotZ_->value()));

    // Selected part attachment marker after placement. It must coincide with
    // the selected UAV mount marker; do not show part origin here.
    addDebugSphere(debugRoot_, placement.attachmentWorldPosition, 0.010f, 1.00f, 0.20f, 0.90f);

    // Local axes at the selected part attachment point after placement.
    addRotationAxes(debugRoot_,
                    placement.attachmentWorldPosition,
                    placement.finalRotation * eulerXYZRotation(partPt.localRotation),
                    axLen * 0.75f);

    // Error vector between placed attachment point and UAV mount point.
    debugRoot_->addChild(debugBeam(placement.attachmentWorldPosition, mountPt,
                                   1.0f, 0.10f, 0.10f));
}

void UAVMountEditorDialog::runValidation()
{
    if (selectedPartPtIdx_ < 0 || selectedPartPtIdx_ >= static_cast<int>(partData_.attachmentPoints.size()))
    {
        valStatus_->setText(tr("Выберите точку крепления детали"));
        valStatus_->setStyleSheet("font-weight: bold;");
        valErrors_->clear();
        valWarnings_->clear();
        confirmBtn_->setEnabled(false);
        confirmBtn_->setToolTip(tr("Выберите точку крепления детали"));
        return;
    }
    if (selectedUAVPtIdx_ < 0 || selectedUAVPtIdx_ >= static_cast<int>(uav_.mountPoints.size()))
    {
        valStatus_->setText(tr("Выберите точку крепления БЛА"));
        valStatus_->setStyleSheet("font-weight: bold;");
        valErrors_->clear();
        valWarnings_->clear();
        confirmBtn_->setEnabled(false);
        confirmBtn_->setToolTip(tr("Выберите точку крепления БЛА"));
        return;
    }

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];
    const GhostPlacement placement = computeGhostPlacement(
        uavPt, partPt, partData_,
        static_cast<float>(spinRotX_->value()),
        static_cast<float>(spinRotY_->value()),
        static_cast<float>(spinRotZ_->value()));

    const MountPairValidationResult res = UAVMountPairValidator::validate(
        partPt, uavPt,
        partData_.massKg,
        partData_.boundingWidth,
        partData_.boundingHeight,
        partData_.boundingDepth,
        partData_.partCenterOfMass.y,
        uav_.emptyMassKg);

    const QString statusStr = QString::fromStdString(UAVMountPairValidator::statusText(res.status));

    QString errText;
    for (const auto& e : res.errors)
        errText += "• " + QString::fromStdString(e) + "\n";
    valErrors_->setText(errText.trimmed());
    valErrors_->setStyleSheet(res.errors.empty() ? "" : "color: #e05555;");

    QString warnText;
    for (const auto& w : res.warnings)
        warnText += "⚠ " + QString::fromStdString(w) + "\n";
#ifndef NDEBUG
    if (!placement.isSnapped()) {
        const QString msg = tr("Ошибка позиционирования: attachment point детали не совпал с mount point БЛА");
        warnText += "⚠ " + msg + QString(" (%1 m)\n").arg(placement.snapError, 0, 'g', 4);
        qWarning() << msg << "error =" << placement.snapError;
    }
#endif
    valWarnings_->setText(warnText.trimmed());
    valWarnings_->setStyleSheet(warnText.trimmed().isEmpty() ? "" : "color: #d0a020;");

    if (!placement.isSnapped()) {
        valStatus_->setText(tr("Ошибка позиционирования: attachment point детали не совпал с mount point БЛА"));
        valStatus_->setStyleSheet("font-weight: bold; color: #e05555;");
        confirmBtn_->setEnabled(false);
        confirmBtn_->setToolTip(tr("Не удалось корректно совместить точки крепления"));
        return;
    }

    switch (res.status) {
    case MountPairValidationResult::Status::ready:
        valStatus_->setText(statusStr + "  —  " + tr("Предпросмотр крепления обновлен"));
        valStatus_->setStyleSheet("font-weight: bold; color: #44cc44;");
        confirmBtn_->setEnabled(true);
        confirmBtn_->setToolTip(QString{});
        break;
    case MountPairValidationResult::Status::attention:
        valStatus_->setText(statusStr + "  —  " + tr("Предпросмотр крепления обновлен"));
        valStatus_->setStyleSheet("font-weight: bold; color: #d0a020;");
        confirmBtn_->setEnabled(true);
        confirmBtn_->setToolTip(QString{});
        break;
    case MountPairValidationResult::Status::blocked:
        valStatus_->setText(statusStr);
        valStatus_->setStyleSheet("font-weight: bold; color: #e05555;");
        confirmBtn_->setEnabled(false);
        confirmBtn_->setToolTip(tr("Не удалось корректно совместить точки крепления"));
        break;
    }
}

void UAVMountEditorDialog::onConfirm()
{
    if (selectedPartPtIdx_ < 0 || selectedUAVPtIdx_ < 0) return;

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];

    // Recompute final transform for the result record (mirrors rebuildGhostPreview).
    const GhostPlacement placement = computeGhostPlacement(
        uavPt, partPt, partData_,
        static_cast<float>(spinRotX_->value()),
        static_cast<float>(spinRotY_->value()),
        static_cast<float>(spinRotZ_->value()));
    if (!placement.isSnapped()) {
        QMessageBox::warning(
            this,
            tr("Ошибка позиционирования"),
            tr("Ошибка позиционирования: attachment point детали не совпал с mount point БЛА"));
        return;
    }
    if (!isFinitePlacement(placement)) {
        QMessageBox::warning(
            this,
            tr("Ошибка позиционирования"),
            tr("Ошибка положения детали: точки крепления не совпадают"));
        return;
    }

    const MountPairValidationResult mountValidation = UAVMountPairValidator::validate(
        partPt, uavPt,
        partData_.massKg,
        partData_.boundingWidth,
        partData_.boundingHeight,
        partData_.boundingDepth,
        partData_.partCenterOfMass.y,
        uav_.emptyMassKg);

    if (mountValidation.status == MountPairValidationResult::Status::blocked) {
        QMessageBox::warning(
            this,
            tr("Не удалось запустить симуляцию"),
            tr("Не удалось корректно совместить точки крепления"));
        return;
    }

    if (compat_.status == PayloadUAVCompatibilityStatus::limited) {
        const auto answer = QMessageBox::question(
            this,
            tr("Ограниченная совместимость"),
            tr("Деталь имеет предупреждения совместимости. Продолжить запуск симуляции?"),
            QMessageBox::Yes | QMessageBox::No,
            QMessageBox::No);
        if (answer != QMessageBox::Yes) {
            return;
        }
    }

    MountEditorResult res;
    res.partId                    = partData_.partId;
    res.uavId                     = uav_.id;
    res.payloadAttachmentPointId  = partPt.id;
    res.uavMountPointId           = uavPt.id;
    res.translateX                = placement.finalPosition[0];
    res.translateY                = placement.finalPosition[1];
    res.translateZ                = placement.finalPosition[2];
    res.rotateX                   = spinRotX_->value();
    res.rotateY                   = spinRotY_->value();
    res.rotateZ                   = spinRotZ_->value();
    SbVec3f finalAxis;
    float finalAngleRad = 0.0f;
    placement.finalRotation.getValue(finalAxis, finalAngleRad);
    res.finalRotationAxisX        = finalAxis[0];
    res.finalRotationAxisY        = finalAxis[1];
    res.finalRotationAxisZ        = finalAxis[2];
    res.finalRotationAngleRad     = finalAngleRad;
    res.isValid                   = true;
    const QString createdAt       = QDateTime::currentDateTimeUtc()
                                        .toString(Qt::ISODate);
    res.timestamp                 = createdAt.toStdString();

    QString handoffPath;
    QString handoffError;
    if (!writeSimulationHandoff(
            partData_, uav_, compat_, partPt, uavPt, mountValidation, placement,
            spinRotX_->value(), spinRotY_->value(), spinRotZ_->value(),
            createdAt,
            &handoffPath,
            &handoffError)) {
        QMessageBox::warning(
            this,
            tr("Не удалось запустить симуляцию"),
            handoffError.isEmpty()
                ? tr("Не удалось подготовить runtime-конфигурацию полезной нагрузки")
                : handoffError);
        return;
    }
    res.handoffPath               = handoffPath.toStdString();
    result_ = res;

    const QString partName = QString::fromStdString(
        partData_.partDisplayName.empty() ? partData_.partId : partData_.partDisplayName);

    QMessageBox::information(
        this,
        tr("Крепление подготовлено"),
        tr("Деталь «%1» закреплена на БЛА «%2».\n\n"
           "Точка детали: %3\n"
           "Точка БЛА: %4\n\n"
           "Конфигурация передана в симуляцию.")
        .arg(partName)
        .arg(QString::fromStdString(uav_.name))
        .arg(QString::fromStdString(partPt.name))
        .arg(QString::fromStdString(uavPt.name)));

    accept();
}

} // namespace cadnext::gui
