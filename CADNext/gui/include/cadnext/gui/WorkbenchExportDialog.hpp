#pragma once

#include "cadnext/Result.hpp"
#include "cadnext/bridge/ConstructionBuilder.hpp"
#include "cadnext/kernel/ShapeHandle.hpp"

#include <QDialog>

#include <optional>
#include <string>
#include <vector>

class QComboBox;
class QLabel;
class QLineEdit;
class QPushButton;
class QTableWidget;

namespace cadnext::gui {

struct WorkbenchExportBody {
    std::string id;
    QString name;
    kernel::ShapeHandle shape;
    std::optional<std::string> materialId; // preselected only when the part already carries one
};

// «Экспорт в Мастерскую»: which CAD axes are the aircraft's forward and up, and the material of every
// body. The result is the request buildConstruction() turns into a version-2 .uavframe — the
// geometry the Workbench runs its strength calculations on.
//
// Axes default to the convention the Workbench has always imported CADNext frames with: nose along
// −Y, Z up. A model built facing another way must say so here, or the aircraft turns together with
// every load direction. Materials have no default, as in the strength panel.
class WorkbenchExportDialog : public QDialog {
    Q_OBJECT

public:
    WorkbenchExportDialog(std::vector<WorkbenchExportBody> bodies, const QString& name, QWidget* parent = nullptr);

    void setForwardAxis(const QString& axis); // "+x" … "-z"
    void setUpAxis(const QString& axis);
    void setBodyMaterial(int row, const std::string& materialId);
    void setConstructionName(const QString& name);

    // Empty result with the first reason when the choices are not complete.
    Result<bridge::ConstructionBuildRequest> request() const;

private:
    void refresh();

    std::vector<WorkbenchExportBody> bodies_;
    QLineEdit* name_ = nullptr;
    QComboBox* forward_ = nullptr;
    QComboBox* up_ = nullptr;
    QTableWidget* table_ = nullptr;
    QLabel* status_ = nullptr;
    QPushButton* accept_ = nullptr;
};

} // namespace cadnext::gui
