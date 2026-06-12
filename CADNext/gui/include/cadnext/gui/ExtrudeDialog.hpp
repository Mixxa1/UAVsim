#pragma once

#include <QDialog>
#include <QList>
#include <QString>

#include "cadnext/Extrude.hpp"

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QPushButton;

namespace cadnext::gui {

// One entry of the profile selector.
struct ExtrudeProfileItem {
    QString id;
    QString label;
};

// Modeless Extrude dialog (CADNext 0.6 v1): profile selector, New Body
// operation, Distance depth mode, Positive/Negative/Symmetric direction
// and a live preview toggle. Operation and depth mode are fixed in v1 and
// shown as disabled selectors so the layout already matches later stages.
class ExtrudeDialog : public QDialog {
    Q_OBJECT

public:
    explicit ExtrudeDialog(QWidget* parent = nullptr);

    void setProfiles(const QList<ExtrudeProfileItem>& profiles, const QString& selectedId);

    QString selectedProfileId() const;
    double distance() const;
    cadnext::ExtrudeDirection direction() const;
    bool previewEnabled() const;

signals:
    // Any input changed (profile / distance / direction / preview toggle).
    void parametersChanged();
    void applyRequested();
    // Cancel button, Esc and the window close button all land here
    // (through QDialog::rejected).
    void cancelRequested();

private:
    QComboBox* profileCombo_ = nullptr;
    QComboBox* operationCombo_ = nullptr;
    QComboBox* depthModeCombo_ = nullptr;
    QDoubleSpinBox* distanceSpin_ = nullptr;
    QComboBox* directionCombo_ = nullptr;
    QCheckBox* previewCheck_ = nullptr;
    QPushButton* applyButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    bool updating_ = false;
};

} // namespace cadnext::gui
