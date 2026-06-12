#include "cadnext/gui/EdgeOperationDialog.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QPushButton>
#include <QVBoxLayout>

namespace cadnext::gui {

namespace {

constexpr double kMinValueMm = 0.01;
constexpr double kMaxValueMm = 1.0e6;
constexpr double kDefaultValueMm = 1.0;
constexpr double kDefaultAngleDeg = 45.0;

} // namespace

EdgeOperationDialog::EdgeOperationDialog(QWidget* parent)
    : QDialog(parent) {
    setModal(false);

    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    targetLabel_ = new QLabel(this);
    form->addRow(tr("Целевое тело"), targetLabel_);

    edgeCountLabel_ = new QLabel(this);
    form->addRow(tr("Ребра"), edgeCountLabel_);

    modeCombo_ = new QComboBox(this);
    modeCombo_->addItem(tr("Расстояние и угол"));
    modeCombo_->addItem(tr("Равные отступы"));
    modeLabel_ = new QLabel(tr("Режим"), this);
    form->addRow(modeLabel_, modeCombo_);

    valueSpin_ = new QDoubleSpinBox(this);
    valueSpin_->setRange(kMinValueMm, kMaxValueMm);
    valueSpin_->setDecimals(3);
    valueSpin_->setSingleStep(1.0);
    valueSpin_->setValue(kDefaultValueMm);
    valueSpin_->setSuffix(tr(" мм"));
    valueSpin_->setKeyboardTracking(false);
    valueLabel_ = new QLabel(this);
    form->addRow(valueLabel_, valueSpin_);

    angleSpin_ = new QDoubleSpinBox(this);
    angleSpin_->setRange(1.0, 89.0);
    angleSpin_->setDecimals(1);
    angleSpin_->setSingleStep(5.0);
    angleSpin_->setValue(kDefaultAngleDeg);
    angleSpin_->setSuffix(tr(" °"));
    angleSpin_->setKeyboardTracking(false);
    angleLabel_ = new QLabel(tr("Угол, °"), this);
    form->addRow(angleLabel_, angleSpin_);

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
    connect(modeCombo_, &QComboBox::currentIndexChanged, this, [this, emitChanged]() {
        updateModeRows();
        emitChanged();
    });
    connect(valueSpin_, &QDoubleSpinBox::valueChanged, this, emitChanged);
    connect(angleSpin_, &QDoubleSpinBox::valueChanged, this, emitChanged);
    connect(previewCheck_, &QCheckBox::toggled, this, emitChanged);
    connect(applyButton_, &QPushButton::clicked, this, [this]() { emit applyRequested(); });
    connect(cancelButton_, &QPushButton::clicked, this, &QDialog::reject);
    connect(this, &QDialog::rejected, this, [this]() { emit cancelRequested(); });

    configure(EdgeOperationDialogKind::Chamfer);
}

void EdgeOperationDialog::configure(EdgeOperationDialogKind kind) {
    updating_ = true;
    kind_ = kind;
    modeCombo_->setCurrentIndex(0); // "Расстояние и угол" is the default
    angleSpin_->setValue(kDefaultAngleDeg);
    updateLabels();
    updateModeRows();
    updating_ = false;
}

void EdgeOperationDialog::setTarget(const QString& bodyName, const QString& bodyId,
                                    int edgeCount) {
    updating_ = true;
    targetBodyId_ = bodyId;
    targetLabel_->setText(bodyName);
    edgeCountLabel_->setText(QString::number(edgeCount));
    applyButton_->setEnabled(!targetBodyId_.isEmpty() && edgeCount > 0);
    updating_ = false;
}

QString EdgeOperationDialog::targetBodyId() const {
    return targetBodyId_;
}

double EdgeOperationDialog::valueMm() const {
    return valueSpin_->value();
}

double EdgeOperationDialog::angleDeg() const {
    return angleSpin_->value();
}

cadnext::ChamferMode EdgeOperationDialog::chamferMode() const {
    return modeCombo_->currentIndex() == 1 ? cadnext::ChamferMode::EqualDistance
                                           : cadnext::ChamferMode::DistanceAngle;
}

bool EdgeOperationDialog::previewEnabled() const {
    return previewCheck_->isChecked();
}

EdgeOperationDialogKind EdgeOperationDialog::kind() const {
    return kind_;
}

void EdgeOperationDialog::updateLabels() {
    if (kind_ == EdgeOperationDialogKind::Chamfer) {
        setWindowTitle(tr("Фаска"));
        valueLabel_->setText(tr("Расстояние, мм"));
        valueSpin_->setToolTip(tr("Линейный размер фаски в миллиметрах"));
        return;
    }
    setWindowTitle(tr("Скругление"));
    valueLabel_->setText(tr("Радиус, мм"));
    valueSpin_->setToolTip(tr("Радиус скругления в миллиметрах"));
}

void EdgeOperationDialog::updateModeRows() {
    const bool chamfer = kind_ == EdgeOperationDialogKind::Chamfer;
    modeLabel_->setVisible(chamfer);
    modeCombo_->setVisible(chamfer);
    const bool angle = chamfer && chamferMode() == cadnext::ChamferMode::DistanceAngle;
    angleLabel_->setVisible(chamfer);
    angleSpin_->setVisible(chamfer);
    angleSpin_->setEnabled(angle);
}

} // namespace cadnext::gui
