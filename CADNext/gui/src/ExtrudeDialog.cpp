#include "cadnext/gui/ExtrudeDialog.hpp"

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

ExtrudeDialog::ExtrudeDialog(QWidget* parent)
    : QDialog(parent) {
    setWindowTitle(tr("Extrude"));
    setModal(false);

    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    profileCombo_ = new QComboBox(this);
    form->addRow(tr("Profile"), profileCombo_);

    // Fixed in v1; disabled selectors keep the layout stable for later
    // stages (Cut / Through All / ...).
    operationCombo_ = new QComboBox(this);
    operationCombo_->addItem(tr("New Body"));
    operationCombo_->setEnabled(false);
    form->addRow(tr("Operation"), operationCombo_);

    depthModeCombo_ = new QComboBox(this);
    depthModeCombo_->addItem(tr("Distance"));
    depthModeCombo_->setEnabled(false);
    form->addRow(tr("Depth mode"), depthModeCombo_);

    distanceSpin_ = new QDoubleSpinBox(this);
    distanceSpin_->setRange(kMinDistance, kMaxDistance);
    distanceSpin_->setDecimals(3);
    distanceSpin_->setSingleStep(0.1);
    distanceSpin_->setValue(1.0);
    distanceSpin_->setKeyboardTracking(false);
    form->addRow(tr("Distance"), distanceSpin_);

    directionCombo_ = new QComboBox(this);
    directionCombo_->addItem(tr("Positive"));
    directionCombo_->addItem(tr("Negative"));
    directionCombo_->addItem(tr("Symmetric"));
    form->addRow(tr("Direction"), directionCombo_);

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
        if (!updating_) {
            emit parametersChanged();
        }
    };
    connect(profileCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(distanceSpin_, &QDoubleSpinBox::valueChanged, this, emitChanged);
    connect(directionCombo_, &QComboBox::currentIndexChanged, this, emitChanged);
    connect(previewCheck_, &QCheckBox::toggled, this, emitChanged);

    connect(applyButton_, &QPushButton::clicked, this, [this]() { emit applyRequested(); });
    connect(cancelButton_, &QPushButton::clicked, this, &QDialog::reject);
    connect(this, &QDialog::rejected, this, [this]() { emit cancelRequested(); });
}

void ExtrudeDialog::setProfiles(const QList<ExtrudeProfileItem>& profiles,
                                const QString& selectedId) {
    updating_ = true;
    profileCombo_->clear();
    int selectedIndex = 0;
    for (int i = 0; i < profiles.size(); ++i) {
        profileCombo_->addItem(profiles[i].label, profiles[i].id);
        if (profiles[i].id == selectedId) {
            selectedIndex = i;
        }
    }
    profileCombo_->setCurrentIndex(profileCombo_->count() > 0 ? selectedIndex : -1);
    applyButton_->setEnabled(profileCombo_->count() > 0);
    updating_ = false;
}

QString ExtrudeDialog::selectedProfileId() const {
    return profileCombo_->currentData().toString();
}

double ExtrudeDialog::distance() const {
    return distanceSpin_->value();
}

cadnext::ExtrudeDirection ExtrudeDialog::direction() const {
    switch (directionCombo_->currentIndex()) {
    case 1: return cadnext::ExtrudeDirection::Negative;
    case 2: return cadnext::ExtrudeDirection::Symmetric;
    default: return cadnext::ExtrudeDirection::Positive;
    }
}

bool ExtrudeDialog::previewEnabled() const {
    return previewCheck_->isChecked();
}

} // namespace cadnext::gui
