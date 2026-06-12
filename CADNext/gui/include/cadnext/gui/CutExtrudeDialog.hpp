#pragma once

#include <QDialog>
#include <QList>
#include <QString>

#include "cadnext/ExtrudeCut.hpp"
#include "cadnext/gui/ExtrudeDialog.hpp" // ExtrudeProfileItem

class QCheckBox;
class QComboBox;
class QDoubleSpinBox;
class QPushButton;

namespace cadnext::gui {

// One entry of the target body / limit object selectors.
struct CutBodyItem {
    QString id;
    QString label;
};

// Modeless Cut Extrude dialog (CADNext 0.7 v1): target body, profile,
// Distance / Through All / To Object depth modes, direction and a cutter
// preview toggle. The Distance field is enabled only in Distance mode,
// the limit object selector only in To Object mode; To Object does not
// offer Symmetric.
class CutExtrudeDialog : public QDialog {
    Q_OBJECT

public:
    explicit CutExtrudeDialog(QWidget* parent = nullptr);

    void setTargetBodies(const QList<CutBodyItem>& bodies, const QString& selectedId);
    void setProfiles(const QList<ExtrudeProfileItem>& profiles, const QString& selectedId);
    void setLimitObjects(const QList<CutBodyItem>& objects, const QString& selectedId);

    QString targetBodyId() const;
    QString selectedProfileId() const;
    QString limitObjectId() const;
    cadnext::CutDepthMode depthMode() const;
    cadnext::CutDirection direction() const;
    double distance() const;
    bool previewEnabled() const;

signals:
    void parametersChanged();
    void applyRequested();
    void cancelRequested();

private:
    void updateFieldEnablement();
    void selectComboId(QComboBox* combo, const QString& selectedId);

    QComboBox* targetCombo_ = nullptr;
    QComboBox* profileCombo_ = nullptr;
    QComboBox* operationCombo_ = nullptr;
    QComboBox* depthModeCombo_ = nullptr;
    QComboBox* directionCombo_ = nullptr;
    QDoubleSpinBox* distanceSpin_ = nullptr;
    QComboBox* limitCombo_ = nullptr;
    QCheckBox* previewCheck_ = nullptr;
    QPushButton* applyButton_ = nullptr;
    QPushButton* cancelButton_ = nullptr;
    bool updating_ = false;
};

} // namespace cadnext::gui
