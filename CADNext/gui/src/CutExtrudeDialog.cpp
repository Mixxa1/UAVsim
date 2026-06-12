#include "cadnext/gui/CutExtrudeDialog.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QVBoxLayout>

namespace cadnext::gui {

namespace {

constexpr double kMinDistance = 0.001;
constexpr double kMaxDistance = 1.0e6;

} // namespace

CutExtrudeDialog::CutExtrudeDialog(QWidget* parent)
    : QDialog(parent) {
    setWindowTitle(tr("Cut Extrude"));
    setModal(false);

    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    targetCombo_ = new QComboBox(this);
    form->addRow(tr("Target body"), targetCombo_);

    profileCombo_ = new QComboBox(this);
    form->addRow(tr("Profile"), profileCombo_);

    operationCombo_ = new QComboBox(this);
    operationCombo_->addItem(tr("Cut"));
    operationCombo_->setEnabled(false);
    form->addRow(tr("Operation"), operationCombo_);

    depthModeCombo_ = new QComboBox(this);
    depthModeCombo_->addItem(tr("Distance"));
    depthModeCombo_->addItem(tr("Through All"));
    depthModeCombo_->addItem(tr("To Object"));
    form->addRow(tr("Depth mode"), depthModeCombo_);

    directionCombo_ = new QComboBox(this);
    directionCombo_->addItem(tr("Positive"));
    directionCombo_->addItem(tr("Negative"));
    directionCombo_->addItem(tr("Symmetric"));
    form->addRow(tr("Direction"), directionCombo_);

    distanceSpin_ = new QDoubleSpinBox(this);
    distanceSpin_->setRange(kMinDistance, kMaxDistance);
    distanceSpin_->setDecimals(3);
    distanceSpin_->setSingleStep(0.1);
    distanceSpin_->setValue(1.0);
    distanceSpin_->setKeyboardTracking(false);
    form->addRow(tr("Distance"), distanceSpin_);

    limitCombo_ = new QComboBox(this);
    form->addRow(tr("Limit object"), limitCombo_);

    previewCheck_ = new QCheckBox(tr("Preview"), this);
    previewCheck_->setChecked(true);
    form->addRow(QString(), previewCheck_);

    layout->addLayout(form);

    auto* buttons = new QHBoxLayout;
    buttons->addStretch();
    applyButton_ = new QPushButton(tr("Apply"), this);
    applyButton_->setDefault(true);
    cancelButton_ = new QPushButton(tr("Cancel"), this);
    buttons->addWidget(applyButton_);
    buttons->addWidget(cancelButton_);
    layout->addLayout(buttons);

    const auto emitChanged = [this]() {
        if (updating_) {
            return;
        }
        updateFieldEnablement();
        emit parametersChanged();
    };
    connect(targetCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(profileCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(depthModeCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(directionCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(distanceSpin_, &QDoubleSpinBox::valueChanged, this, emitChanged);
    connect(limitCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(previewCheck_, &QCheckBox::toggled, this, emitChanged);

    connect(applyButton_, &QPushButton::clicked, this, [this]() { emit applyRequested(); });
    connect(cancelButton_, &QPushButton::clicked, this, &QDialog::reject);
    connect(this, &QDialog::rejected, this, [this]() { emit cancelRequested(); });

    updateFieldEnablement();
}

void CutExtrudeDialog::updateFieldEnablement() {
    const cadnext::CutDepthMode mode = depthMode();
    distanceSpin_->setEnabled(mode == cadnext::CutDepthMode::Distance);
    limitCombo_->setEnabled(mode == cadnext::CutDepthMode::ToObject);
    // To Object has no symmetric variant in v1.
    if (mode == cadnext::CutDepthMode::ToObject && directionCombo_->currentIndex() == 2) {
        const bool wasUpdating = updating_;
        updating_ = true;
        directionCombo_->setCurrentIndex(0);
        updating_ = wasUpdating;
    }
    applyButton_->setEnabled(targetCombo_->count() > 0 && profileCombo_->count() > 0);
}

void CutExtrudeDialog::selectComboId(QComboBox* combo, const QString& selectedId) {
    int index = combo->count() > 0 ? 0 : -1;
    for (int i = 0; i < combo->count(); ++i) {
        if (combo->itemData(i).toString() == selectedId) {
            index = i;
            break;
        }
    }
    combo->setCurrentIndex(index);
}

void CutExtrudeDialog::setTargetBodies(const QList<CutBodyItem>& bodies,
                                       const QString& selectedId) {
    updating_ = true;
    targetCombo_->clear();
    for (const CutBodyItem& body : bodies) {
        targetCombo_->addItem(body.label, body.id);
    }
    selectComboId(targetCombo_, selectedId);
    updating_ = false;
    updateFieldEnablement();
}

void CutExtrudeDialog::setProfiles(const QList<ExtrudeProfileItem>& profiles,
                                   const QString& selectedId) {
    updating_ = true;
    profileCombo_->clear();
    for (const ExtrudeProfileItem& profile : profiles) {
        profileCombo_->addItem(profile.label, profile.id);
    }
    selectComboId(profileCombo_, selectedId);
    updating_ = false;
    updateFieldEnablement();
}

void CutExtrudeDialog::setLimitObjects(const QList<CutBodyItem>& objects,
                                       const QString& selectedId) {
    updating_ = true;
    limitCombo_->clear();
    for (const CutBodyItem& object : objects) {
        limitCombo_->addItem(object.label, object.id);
    }
    selectComboId(limitCombo_, selectedId);
    updating_ = false;
}

void CutExtrudeDialog::setDepthMode(cadnext::CutDepthMode mode) {
    const bool wasUpdating = updating_;
    updating_ = true;
    switch (mode) {
    case cadnext::CutDepthMode::ThroughAll:
        depthModeCombo_->setCurrentIndex(1);
        break;
    case cadnext::CutDepthMode::ToObject:
        depthModeCombo_->setCurrentIndex(2);
        break;
    case cadnext::CutDepthMode::Distance:
        depthModeCombo_->setCurrentIndex(0);
        break;
    }
    updating_ = wasUpdating;
    updateFieldEnablement();
}

void CutExtrudeDialog::setDirection(cadnext::CutDirection direction) {
    const bool wasUpdating = updating_;
    updating_ = true;
    switch (direction) {
    case cadnext::CutDirection::Negative:
        directionCombo_->setCurrentIndex(1);
        break;
    case cadnext::CutDirection::Symmetric:
        directionCombo_->setCurrentIndex(2);
        break;
    case cadnext::CutDirection::Positive:
        directionCombo_->setCurrentIndex(0);
        break;
    }
    updating_ = wasUpdating;
    updateFieldEnablement();
}

void CutExtrudeDialog::setDistance(double distance) {
    const bool wasUpdating = updating_;
    updating_ = true;
    distanceSpin_->setValue(distance);
    updating_ = wasUpdating;
    updateFieldEnablement();
}

QString CutExtrudeDialog::targetBodyId() const {
    return targetCombo_->currentData().toString();
}

QString CutExtrudeDialog::selectedProfileId() const {
    return profileCombo_->currentData().toString();
}

QString CutExtrudeDialog::limitObjectId() const {
    return limitCombo_->currentData().toString();
}

cadnext::CutDepthMode CutExtrudeDialog::depthMode() const {
    switch (depthModeCombo_->currentIndex()) {
    case 1: return cadnext::CutDepthMode::ThroughAll;
    case 2: return cadnext::CutDepthMode::ToObject;
    default: return cadnext::CutDepthMode::Distance;
    }
}

cadnext::CutDirection CutExtrudeDialog::direction() const {
    switch (directionCombo_->currentIndex()) {
    case 1: return cadnext::CutDirection::Negative;
    case 2: return cadnext::CutDirection::Symmetric;
    default: return cadnext::CutDirection::Positive;
    }
}

double CutExtrudeDialog::distance() const {
    return distanceSpin_->value();
}

bool CutExtrudeDialog::previewEnabled() const {
    return previewCheck_->isChecked();
}

} // namespace cadnext::gui
