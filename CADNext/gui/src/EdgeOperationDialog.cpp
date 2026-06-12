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

constexpr double kMinValue = 0.001;
constexpr double kMaxValue = 1.0e6;

} // namespace

EdgeOperationDialog::EdgeOperationDialog(QWidget* parent)
    : QDialog(parent) {
    setModal(false);

    auto* layout = new QVBoxLayout(this);
    auto* form = new QFormLayout;

    targetLabel_ = new QLabel(this);
    form->addRow(tr("Target body"), targetLabel_);

    edgeCountLabel_ = new QLabel(this);
    form->addRow(tr("Edges"), edgeCountLabel_);

    modeCombo_ = new QComboBox(this);
    modeCombo_->addItem(tr("Equal distance"));
    modeCombo_->setEnabled(false);
    form->addRow(tr("Mode"), modeCombo_);

    valueSpin_ = new QDoubleSpinBox(this);
    valueSpin_->setRange(kMinValue, kMaxValue);
    valueSpin_->setDecimals(3);
    valueSpin_->setSingleStep(0.05);
    valueSpin_->setValue(0.1);
    valueSpin_->setKeyboardTracking(false);
    valueLabel_ = new QLabel(this);
    form->addRow(valueLabel_, valueSpin_);

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
    connect(valueSpin_, &QDoubleSpinBox::valueChanged, this, emitChanged);
    connect(previewCheck_, &QCheckBox::toggled, this, emitChanged);
    connect(applyButton_, &QPushButton::clicked, this, [this]() { emit applyRequested(); });
    connect(cancelButton_, &QPushButton::clicked, this, &QDialog::reject);
    connect(this, &QDialog::rejected, this, [this]() { emit cancelRequested(); });

    configure(EdgeOperationDialogKind::Chamfer);
}

void EdgeOperationDialog::configure(EdgeOperationDialogKind kind) {
    updating_ = true;
    kind_ = kind;
    updateLabels();
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

double EdgeOperationDialog::value() const {
    return valueSpin_->value();
}

bool EdgeOperationDialog::previewEnabled() const {
    return previewCheck_->isChecked();
}

EdgeOperationDialogKind EdgeOperationDialog::kind() const {
    return kind_;
}

void EdgeOperationDialog::updateLabels() {
    if (kind_ == EdgeOperationDialogKind::Chamfer) {
        setWindowTitle(tr("Chamfer"));
        valueLabel_->setText(tr("Distance"));
        valueSpin_->setToolTip(tr("Equal chamfer distance"));
        return;
    }
    setWindowTitle(tr("Fillet"));
    valueLabel_->setText(tr("Radius"));
    valueSpin_->setToolTip(tr("Fillet radius"));
}

} // namespace cadnext::gui
