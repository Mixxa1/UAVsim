#pragma once

#include <QDialog>

#include "cadnext/AttachmentPoint.hpp"

class QCheckBox;
class QComboBox;
class QLabel;
class QLineEdit;

namespace cadnext::gui {

// Dialog for creating or editing a single attachment point (UAVPart v1.1).
// Shown after a face click (create) or when an existing marker is selected
// and the user requests editing. The caller gets the edited data via data().
class AttachmentPointDialog : public QDialog {
    Q_OBJECT

public:
    struct Data {
        std::string name;
        AttachmentRole role = AttachmentRole::Payload;
        bool isEnabled = true;
    };

    // isEdit = true shows a "Удалить точку" button and uses "Изменить" as
    // accept label; false shows only "Сохранить точку" / "Отмена".
    // isSystem = true disables the delete button with a tooltip.
    explicit AttachmentPointDialog(const Data& initial,
                                   bool isEdit = false,
                                   bool isSystem = false,
                                   QWidget* parent = nullptr);

    Data data() const;
    bool deleteRequested() const { return deleteRequested_; }

private:
    static AttachmentRole roleFromIndex(int index);
    static int indexFromRole(AttachmentRole role);

    QLineEdit* nameEdit_ = nullptr;
    QComboBox* roleCombo_ = nullptr;
    QCheckBox* enabledCheck_ = nullptr;
    bool deleteRequested_ = false;
};

} // namespace cadnext::gui
