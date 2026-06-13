#include "cadnext/gui/AttachmentPointDialog.hpp"

#include <QCheckBox>
#include <QComboBox>
#include <QDialogButtonBox>
#include <QFormLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QVBoxLayout>

namespace cadnext::gui {

AttachmentPointDialog::AttachmentPointDialog(const Data& initial,
                                             bool isEdit,
                                             bool isSystem,
                                             QWidget* parent)
    : QDialog(parent) {
    setWindowTitle(isEdit ? tr("Точка крепления") : tr("Добавить точку крепления"));
    setMinimumWidth(340);

    auto* layout = new QVBoxLayout(this);

    auto* form = new QFormLayout;
    layout->addLayout(form);

    nameEdit_ = new QLineEdit(this);
    nameEdit_->setText(QString::fromStdString(initial.name));
    nameEdit_->setPlaceholderText(tr("Название точки"));
    form->addRow(tr("Название:"), nameEdit_);

    roleCombo_ = new QComboBox(this);
    roleCombo_->addItem(tr("Полезная нагрузка")); // Payload  = 0
    roleCombo_->addItem(tr("Камера"));            // Camera   = 1
    roleCombo_->addItem(tr("Датчик"));            // Sensor   = 2
    roleCombo_->addItem(tr("Универсальная"));     // Generic  = 3
    roleCombo_->setCurrentIndex(indexFromRole(initial.role));
    form->addRow(tr("Роль:"), roleCombo_);

    enabledCheck_ = new QCheckBox(tr("Включена"), this);
    enabledCheck_->setChecked(initial.isEnabled);
    form->addRow(QString(), enabledCheck_);

    auto* buttons = new QDialogButtonBox(this);
    const QString acceptLabel = isEdit ? tr("Изменить") : tr("Сохранить точку");
    QPushButton* acceptBtn = buttons->addButton(acceptLabel, QDialogButtonBox::AcceptRole);
    buttons->addButton(tr("Отмена"), QDialogButtonBox::RejectRole);
    connect(acceptBtn, &QPushButton::clicked, this, &QDialog::accept);
    connect(buttons, &QDialogButtonBox::rejected, this, &QDialog::reject);

    if (isEdit) {
        QPushButton* deleteBtn =
            buttons->addButton(tr("Удалить точку"), QDialogButtonBox::DestructiveRole);
        if (isSystem) {
            deleteBtn->setEnabled(false);
            deleteBtn->setToolTip(tr("Системную точку крепления нельзя удалить"));
        } else {
            connect(deleteBtn, &QPushButton::clicked, this, [this]() {
                deleteRequested_ = true;
                accept();
            });
        }
    }

    layout->addWidget(buttons);
}

AttachmentPointDialog::Data AttachmentPointDialog::data() const {
    Data d;
    d.name = nameEdit_->text().trimmed().toStdString();
    if (d.name.empty()) {
        d.name = "mount_point";
    }
    d.role = roleFromIndex(roleCombo_->currentIndex());
    d.isEnabled = enabledCheck_->isChecked();
    return d;
}

AttachmentRole AttachmentPointDialog::roleFromIndex(int index) {
    switch (index) {
    case 0: return AttachmentRole::Payload;
    case 1: return AttachmentRole::Camera;
    case 2: return AttachmentRole::Sensor;
    case 3: return AttachmentRole::Generic;
    default: return AttachmentRole::Generic;
    }
}

int AttachmentPointDialog::indexFromRole(AttachmentRole role) {
    switch (role) {
    case AttachmentRole::Payload: return 0;
    case AttachmentRole::Camera:  return 1;
    case AttachmentRole::Sensor:  return 2;
    case AttachmentRole::Generic: return 3;
    default: return 0;
    }
}

} // namespace cadnext::gui
