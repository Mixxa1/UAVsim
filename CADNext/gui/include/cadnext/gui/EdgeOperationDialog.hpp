#pragma once

#include <QDialog>
#include <QString>

#include "cadnext/Chamfer.hpp"

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QLabel;
class QPushButton;

namespace cadnext::gui {

enum class EdgeOperationDialogKind {
    Chamfer,
    Fillet
};

// Chamfer / Fillet dialog. All linear values are entered in millimeters,
// the chamfer angle in degrees; the chamfer additionally offers the
// distance+angle (default) and equal-distance modes.
class EdgeOperationDialog : public QDialog {
    Q_OBJECT

public:
    explicit EdgeOperationDialog(QWidget* parent = nullptr);

    void configure(EdgeOperationDialogKind kind);
    void setTarget(const QString& bodyName, const QString& bodyId, int edgeCount);
    void setValueMm(double valueMm);
    QString targetBodyId() const;
    // Distance (chamfer) or radius (fillet) in millimeters.
    double valueMm();
    double angleDeg();
    cadnext::ChamferMode chamferMode() const;
    bool previewEnabled() const;
    EdgeOperationDialogKind kind() const;

signals:
    void parametersChanged();
    void applyRequested();
    void cancelRequested();

private:
    void commitPendingEdits();
    void updateLabels();
    void updateModeRows();

    EdgeOperationDialogKind kind_ = EdgeOperationDialogKind::Chamfer;
    QLabel* targetLabel_ = nullptr;
    QLabel* edgeCountLabel_ = nullptr;
    QLabel* valueLabel_ = nullptr;
    QLabel* modeLabel_ = nullptr;
    QLabel* angleLabel_ = nullptr;
    QComboBox* modeCombo_ = nullptr;
    QDoubleSpinBox* valueSpin_ = nullptr;
    QDoubleSpinBox* angleSpin_ = nullptr;
    QCheckBox* previewCheck_ = nullptr;
    QPushButton* applyButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    QString targetBodyId_;
    bool updating_ = false;
};

} // namespace cadnext::gui
