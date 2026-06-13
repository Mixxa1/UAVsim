#include "cadnext/gui/UAVMountEditorDialog.hpp"
#include "cadnext/gui/UAVBodySceneBuilder.hpp"
#include "cadnext/gui/UAVMountPairValidator.hpp"

#include <QDateTime>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QGroupBox>
#include <QHBoxLayout>
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
#include <Inventor/nodes/SoIndexedFaceSet.h>
#include <Inventor/nodes/SoMaterial.h>
#include <Inventor/nodes/SoSeparator.h>
#include <Inventor/nodes/SoShapeHints.h>
#include <Inventor/nodes/SoSphere.h>
#include <Inventor/nodes/SoTransform.h>

namespace cadnext::gui {

namespace {

static constexpr float kPi = 3.14159265f;

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

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
UAVMountEditorDialog::UAVMountEditorDialog(
    const UAVPartPreflightData&         partData,
    const UAVCatalogPreviewItem&        uav,
    const UAVPayloadCompatibilityResult& /*compat*/,
    QWidget*                            parent)
    : QDialog(parent)
    , partData_(partData)
    , uav_(uav)
{
    setWindowTitle(tr("Крепление детали на БЛА: %1")
                   .arg(QString::fromStdString(uav.name)));
    setMinimumSize(1050, 680);
    resize(1120, 730);

    // ── Scene graph setup ────────────────────────────────────────────────────
    sceneRoot_   = new SoSeparator; sceneRoot_->ref();
    markersRoot_ = new SoSeparator; markersRoot_->ref();
    ghostRoot_   = new SoSeparator; ghostRoot_->ref();

    SoSeparator* bodyRoot = UAVBodySceneBuilder::buildScene(
        uav.id, uav.vehicleType, uav.massCategory);

    sceneRoot_->addChild(bodyRoot);
    sceneRoot_->addChild(markersRoot_);
    sceneRoot_->addChild(ghostRoot_);

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
    auto* backBtn  = new QPushButton(tr("Назад"));
    confirmBtn_    = new QPushButton(tr("Подтвердить крепление"));
    auto* closeBtn = new QPushButton(tr("Закрыть"));
    confirmBtn_->setEnabled(false);
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

    connect(backBtn,     &QPushButton::clicked, this, &QDialog::reject);
    connect(closeBtn,    &QPushButton::clicked, this, &QDialog::reject);
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
}

void UAVMountEditorDialog::rebuildGhostPreview()
{
    ghostRoot_->removeAllChildren();

    if (selectedPartPtIdx_ < 0 || selectedUAVPtIdx_ < 0) return;
    if (selectedPartPtIdx_ >= static_cast<int>(partData_.attachmentPoints.size())) return;
    if (selectedUAVPtIdx_  >= static_cast<int>(uav_.mountPoints.size()))           return;

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];

    // Build rotation (ZYX extrinsic order = XYZ intrinsic)
    const float toRad = kPi / 180.0f;
    SbRotation rx(SbVec3f(1,0,0), static_cast<float>(spinRotX_->value()) * toRad);
    SbRotation ry(SbVec3f(0,1,0), static_cast<float>(spinRotY_->value()) * toRad);
    SbRotation rz(SbVec3f(0,0,1), static_cast<float>(spinRotZ_->value()) * toRad);
    SbRotation combined = rz * ry * rx;

    // Ghost position: UAV mount pt − R * part attach pt
    SbVec3f uavPtPos(
        static_cast<float>(uavPt.localPosition.x),
        static_cast<float>(uavPt.localPosition.y),
        static_cast<float>(uavPt.localPosition.z));
    SbVec3f partPtPos(
        static_cast<float>(partPt.localPosition.x),
        static_cast<float>(partPt.localPosition.y),
        static_cast<float>(partPt.localPosition.z));
    SbVec3f rotatedPartPt;
    combined.multVec(partPtPos, rotatedPartPt);
    SbVec3f ghostTrans = uavPtPos - rotatedPartPt;

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
    xf->translation.setValue(ghostTrans);
    xf->rotation.setValue(combined);
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
        // Bounding-box placeholder when no mesh is available
        auto* box   = new SoCube;
        box->width  = static_cast<float>(partData_.boundingWidth);
        box->height = static_cast<float>(partData_.boundingHeight);
        box->depth  = static_cast<float>(partData_.boundingDepth);
        ghostSep->addChild(box);
    }

    ghostRoot_->addChild(ghostSep);
}

void UAVMountEditorDialog::runValidation()
{
    if (selectedPartPtIdx_ < 0 || selectedUAVPtIdx_ < 0
        || selectedPartPtIdx_ >= static_cast<int>(partData_.attachmentPoints.size())
        || selectedUAVPtIdx_  >= static_cast<int>(uav_.mountPoints.size()))
    {
        valStatus_->setText(tr("Выберите точки крепления"));
        valStatus_->setStyleSheet("font-weight: bold;");
        valErrors_->clear();
        valWarnings_->clear();
        confirmBtn_->setEnabled(false);
        return;
    }

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];

    const MountPairValidationResult res = UAVMountPairValidator::validate(
        partPt, uavPt,
        partData_.massKg,
        partData_.boundingWidth,
        partData_.boundingHeight,
        partData_.boundingDepth,
        partData_.partCenterOfMass.y,
        uav_.emptyMassKg);

    valStatus_->setText(
        QString::fromStdString(UAVMountPairValidator::statusText(res.status)));

    QString errText;
    for (const auto& e : res.errors)
        errText += "• " + QString::fromStdString(e) + "\n";
    valErrors_->setText(errText.trimmed());
    valErrors_->setStyleSheet(res.errors.empty() ? "" : "color: #e05555;");

    QString warnText;
    for (const auto& w : res.warnings)
        warnText += "⚠ " + QString::fromStdString(w) + "\n";
    valWarnings_->setText(warnText.trimmed());
    valWarnings_->setStyleSheet(res.warnings.empty() ? "" : "color: #d0a020;");

    switch (res.status) {
    case MountPairValidationResult::Status::ready:
        valStatus_->setStyleSheet("font-weight: bold; color: #44cc44;");
        confirmBtn_->setEnabled(true);
        break;
    case MountPairValidationResult::Status::attention:
        valStatus_->setStyleSheet("font-weight: bold; color: #d0a020;");
        confirmBtn_->setEnabled(true);
        break;
    case MountPairValidationResult::Status::blocked:
        valStatus_->setStyleSheet("font-weight: bold; color: #e05555;");
        confirmBtn_->setEnabled(false);
        break;
    }
}

void UAVMountEditorDialog::onConfirm()
{
    if (selectedPartPtIdx_ < 0 || selectedUAVPtIdx_ < 0) return;

    const auto& partPt = partData_.attachmentPoints[selectedPartPtIdx_];
    const auto& uavPt  = uav_.mountPoints[selectedUAVPtIdx_];

    // Recompute ghost translation for the result record
    const float toRad = kPi / 180.0f;
    SbRotation rx(SbVec3f(1,0,0), static_cast<float>(spinRotX_->value()) * toRad);
    SbRotation ry(SbVec3f(0,1,0), static_cast<float>(spinRotY_->value()) * toRad);
    SbRotation rz(SbVec3f(0,0,1), static_cast<float>(spinRotZ_->value()) * toRad);
    SbRotation combined = rz * ry * rx;

    SbVec3f uavPtPos(static_cast<float>(uavPt.localPosition.x),
                     static_cast<float>(uavPt.localPosition.y),
                     static_cast<float>(uavPt.localPosition.z));
    SbVec3f partPtPos(static_cast<float>(partPt.localPosition.x),
                      static_cast<float>(partPt.localPosition.y),
                      static_cast<float>(partPt.localPosition.z));
    SbVec3f rotatedPt;
    combined.multVec(partPtPos, rotatedPt);
    SbVec3f ghostTrans = uavPtPos - rotatedPt;

    MountEditorResult res;
    res.partId                    = partData_.partId;
    res.uavId                     = uav_.id;
    res.payloadAttachmentPointId  = partPt.id;
    res.uavMountPointId           = uavPt.id;
    res.translateX                = ghostTrans[0];
    res.translateY                = ghostTrans[1];
    res.translateZ                = ghostTrans[2];
    res.rotateX                   = spinRotX_->value();
    res.rotateY                   = spinRotY_->value();
    res.rotateZ                   = spinRotZ_->value();
    res.isValid                   = true;
    res.timestamp                 = QDateTime::currentDateTime()
                                        .toString(Qt::ISODate)
                                        .toStdString();
    result_ = res;

    const QString partName = QString::fromStdString(
        partData_.partDisplayName.empty() ? partData_.partId : partData_.partDisplayName);

    QMessageBox::information(
        this,
        tr("Крепление подтверждено"),
        tr("Деталь «%1» закреплена на БЛА «%2».\n\n"
           "Точка детали: %3\n"
           "Точка БЛА: %4\n\n"
           "Конфигурация сохранена в памяти.\n"
           "Запуск симуляции будет добавлен в следующем обновлении.")
        .arg(partName)
        .arg(QString::fromStdString(uav_.name))
        .arg(QString::fromStdString(partPt.name))
        .arg(QString::fromStdString(uavPt.name)));

    accept();
}

} // namespace cadnext::gui
