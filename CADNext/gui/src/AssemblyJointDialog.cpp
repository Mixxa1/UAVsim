#include "cadnext/gui/AssemblyJointDialog.hpp"

#include <cmath>

#include <QCheckBox>
#include <QComboBox>
#include <QCoreApplication>
#include <QDialogButtonBox>
#include <QDoubleSpinBox>
#include <QFormLayout>
#include <QLabel>
#include <QVBoxLayout>

#include "cadnext/Units.hpp"

namespace cadnext::gui {

namespace {

QString dialogTitle(assembly::JointType type) {
    switch (type) {
    case assembly::JointType::Coincident:
        return QCoreApplication::translate("AssemblyJointDialog", "Совпадение");
    case assembly::JointType::Parallel:
        return QCoreApplication::translate("AssemblyJointDialog", "Параллельность");
    case assembly::JointType::Perpendicular:
        return QCoreApplication::translate("AssemblyJointDialog", "Перпендикулярность");
    case assembly::JointType::Concentric:
        return QCoreApplication::translate("AssemblyJointDialog", "Соосность");
    case assembly::JointType::Distance:
        return QCoreApplication::translate("AssemblyJointDialog", "Расстояние");
    case assembly::JointType::Angle:
        return QCoreApplication::translate("AssemblyJointDialog", "Угол");
    case assembly::JointType::Rigid:
        return QCoreApplication::translate("AssemblyJointDialog", "Жёсткое соединение");
    }
    return QString();
}

bool typeUsesAlignment(assembly::JointType type) {
    return type != assembly::JointType::Perpendicular &&
           type != assembly::JointType::Angle;
}

bool typeUsesOffset(assembly::JointType type) {
    switch (type) {
    case assembly::JointType::Coincident:
    case assembly::JointType::Concentric:
    case assembly::JointType::Distance:
    case assembly::JointType::Rigid:
        return true;
    default:
        return false;
    }
}

bool typeUsesAngle(assembly::JointType type) {
    switch (type) {
    case assembly::JointType::Coincident:
    case assembly::JointType::Distance:
    case assembly::JointType::Angle:
    case assembly::JointType::Rigid:
        return true;
    default:
        return false;
    }
}

bool typeUsesLockRotation(assembly::JointType type) {
    return type == assembly::JointType::Concentric;
}

} // namespace

AssemblyJointDialog::AssemblyJointDialog(assembly::JointType type,
                                         const QString& firstLabel,
                                         const QString& secondLabel, QWidget* parent)
    : QDialog(parent), type_(type) {
    setWindowTitle(dialogTitle(type));
    setModal(true);

    auto* layout = new QVBoxLayout(this);

    auto* selectionLabel =
        new QLabel(tr("1: %1\n2: %2").arg(firstLabel, secondLabel), this);
    selectionLabel->setWordWrap(true);
    layout->addWidget(selectionLabel);

    auto* form = new QFormLayout();
    layout->addLayout(form);

    if (typeUsesAlignment(type_)) {
        alignmentCombo_ = new QComboBox(this);
        alignmentCombo_->addItem(tr("Сонаправленно"),
                                 QString::fromLatin1(assembly::jointAlignmentName(
                                     assembly::JointAlignment::Aligned)));
        alignmentCombo_->addItem(tr("Встречно"),
                                 QString::fromLatin1(assembly::jointAlignmentName(
                                     assembly::JointAlignment::Opposed)));
        // Mating two outward-facing surfaces usually means "opposed".
        if (type_ == assembly::JointType::Coincident ||
            type_ == assembly::JointType::Distance) {
            alignmentCombo_->setCurrentIndex(1);
        }
        form->addRow(tr("Ориентация"), alignmentCombo_);
        connect(alignmentCombo_, &QComboBox::currentIndexChanged, this,
                [this]() { emit parametersChanged(); });
    }
    if (typeUsesOffset(type_)) {
        // Model units are meters; the UI is millimeters everywhere (Units.hpp).
        offsetSpin_ = new QDoubleSpinBox(this);
        offsetSpin_->setRange(-100000.0, 100000.0);
        offsetSpin_->setDecimals(3);
        offsetSpin_->setSingleStep(1.0);
        offsetSpin_->setSuffix(tr(" мм"));
        form->addRow(tr("Смещение"), offsetSpin_);
        connect(offsetSpin_, &QDoubleSpinBox::valueChanged, this,
                [this]() { emit parametersChanged(); });
    }
    if (typeUsesAngle(type_)) {
        angleSpin_ = new QDoubleSpinBox(this);
        angleSpin_->setRange(-360.0, 360.0);
        angleSpin_->setDecimals(2);
        angleSpin_->setSingleStep(5.0);
        angleSpin_->setSuffix(tr(" °"));
        form->addRow(tr("Угол"), angleSpin_);
        connect(angleSpin_, &QDoubleSpinBox::valueChanged, this,
                [this]() { emit parametersChanged(); });
    }
    if (typeUsesLockRotation(type_)) {
        lockRotationCheck_ = new QCheckBox(tr("Заблокировать вращение вокруг оси"), this);
        form->addRow(QString(), lockRotationCheck_);
        connect(lockRotationCheck_, &QCheckBox::toggled, this,
                [this]() { emit parametersChanged(); });
    }

    auto* buttons =
        new QDialogButtonBox(QDialogButtonBox::Ok | QDialogButtonBox::Cancel, this);
    connect(buttons, &QDialogButtonBox::accepted, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);
    layout->addWidget(buttons);
}

assembly::JointAlignment AssemblyJointDialog::alignment() const {
    if (!alignmentCombo_) {
        return assembly::JointAlignment::Aligned;
    }
    return assembly::jointAlignmentFromName(
        alignmentCombo_->currentData().toString().toStdString());
}

double AssemblyJointDialog::offsetMeters() const {
    return offsetSpin_ ? cadnext::fromMillimeters(offsetSpin_->value()) : 0.0;
}

double AssemblyJointDialog::angleRadians() const {
    return angleSpin_ ? angleSpin_->value() * M_PI / 180.0 : 0.0;
}

bool AssemblyJointDialog::lockRotation() const {
    return lockRotationCheck_ && lockRotationCheck_->isChecked();
}

} // namespace cadnext::gui
