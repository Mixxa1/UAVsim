#include "cadnext/gui/ExtrudeDialog.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QVBoxLayout>

#include "cadnext/Units.hpp"

namespace cadnext::gui {

namespace {

constexpr double kMinDistanceMm = 0.01;
constexpr double kMaxDistanceMm = 1.0e9;

} // namespace

ExtrudeDialog::ExtrudeDialog(QWidget* parent)
    : QDialog(parent) {
    setWindowTitle(tr("Выдавливание"));
    setModal(false);

    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    profileCombo_ = new QComboBox(this);
    form->addRow(tr("Тело / профиль"), profileCombo_);

    // Fixed in v1; disabled selectors keep the layout stable for later
    // stages (Cut / Through All / ...).
    operationCombo_ = new QComboBox(this);
    operationCombo_->addItem(tr("Новое тело"));
    operationCombo_->setEnabled(false);
    form->addRow(tr("Операция"), operationCombo_);

    depthModeCombo_ = new QComboBox(this);
    depthModeCombo_->addItem(tr("На расстояние"));
    depthModeCombo_->setEnabled(false);
    form->addRow(tr("Режим глубины"), depthModeCombo_);

    distanceSpin_ = new QDoubleSpinBox(this);
    distanceSpin_->setRange(kMinDistanceMm, kMaxDistanceMm);
    distanceSpin_->setDecimals(3);
    distanceSpin_->setSingleStep(10.0);
    distanceSpin_->setValue(1000.0);
    distanceSpin_->setSuffix(tr(" мм"));
    distanceSpin_->setKeyboardTracking(false);
    form->addRow(tr("Расстояние, мм"), distanceSpin_);

    directionCombo_ = new QComboBox(this);
    directionCombo_->addItem(tr("Положительное"));
    directionCombo_->addItem(tr("Отрицательное"));
    directionCombo_->addItem(tr("Симметрично"));
    form->addRow(tr("Направление"), directionCombo_);

    previewCheck_ = new QCheckBox(tr("Предпросмотр"), this);
    previewCheck_->setChecked(true);
    form->addRow(QString(), previewCheck_);

    layout->addLayout(form);

    auto* buttons = new QHBoxLayout;
    buttons->addStretch();
    applyButton_ = new QPushButton(tr("Применить"), this);
    applyButton_->setDefault(true);
    cancelButton_ = new QPushButton(tr("Отмена"), this);
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
    // The spin box edits millimeters; the model works in model units.
    return cadnext::fromMillimeters(distanceSpin_->value());
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
