#pragma once

#include <QDialog>
#include <QString>

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

class EdgeOperationDialog : public QDialog {
    Q_OBJECT

public:
    explicit EdgeOperationDialog(QWidget* parent = nullptr);

    void configure(EdgeOperationDialogKind kind);
    void setTarget(const QString& bodyName, const QString& bodyId, int edgeCount);
    QString targetBodyId() const;
    double value() const;
    bool previewEnabled() const;
    EdgeOperationDialogKind kind() const;

signals:
    void parametersChanged();
    void applyRequested();
    void cancelRequested();

private:
    void updateLabels();

    EdgeOperationDialogKind kind_ = EdgeOperationDialogKind::Chamfer;
    QLabel* targetLabel_ = nullptr;
    QLabel* edgeCountLabel_ = nullptr;
    QLabel* valueLabel_ = nullptr;
    QComboBox* modeCombo_ = nullptr;
    QDoubleSpinBox* valueSpin_ = nullptr;
    QCheckBox* previewCheck_ = nullptr;
    QPushButton* applyButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    QString targetBodyId_;
    bool updating_ = false;
};

} // namespace cadnext::gui
