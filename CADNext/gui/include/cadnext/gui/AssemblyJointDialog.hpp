#pragma once

#include <QDialog>

#include "cadnext/assembly/AssemblyModel.hpp"

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QLabel;

namespace cadnext::gui {

// Joint parameters dialog (Assembly workbench): aligned/opposed, offset,
// angle and lock-rotation for the joint type being created. Emits
// parametersChanged on every edit so the window can live-update the
// ghost preview of the child component.
class AssemblyJointDialog : public QDialog {
    Q_OBJECT

public:
    AssemblyJointDialog(assembly::JointType type, const QString& firstLabel,
                        const QString& secondLabel, QWidget* parent = nullptr);

    assembly::JointAlignment alignment() const;
    double offsetMeters() const;
    double angleRadians() const;
    bool lockRotation() const;

signals:
    void parametersChanged();

private:
    assembly::JointType type_;
    QComboBox* alignmentCombo_ = nullptr;
    QDoubleSpinBox* offsetSpin_ = nullptr;
    QDoubleSpinBox* angleSpin_ = nullptr;
    QCheckBox* lockRotationCheck_ = nullptr;
};

} // namespace cadnext::gui
