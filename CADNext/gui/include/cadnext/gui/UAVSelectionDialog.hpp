#pragma once

#include <QDialog>
#include <vector>

#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"
#include "cadnext/gui/UAVPayloadCompatibilityChecker.hpp"

class QGroupBox;
class QLabel;
class QListWidget;
class QPushButton;

namespace cadnext::gui {

// Dialog for selecting a UAV to test a .uavpart against.
// Displays the reference UAV catalog, computes mass/MTOW/mount compatibility
// for each entry, and shows a detailed compatibility card on the right.
// The "Продолжить" button is a placeholder for the next-patch Mount Editor.
class UAVSelectionDialog : public QDialog {
    Q_OBJECT

public:
    enum class FilterMode { all, compatible, limited, incompatible };

    explicit UAVSelectionDialog(const UAVPartPreflightData& partData,
                                const QString& partDisplayName,
                                QWidget* parent = nullptr);

private:
    void rebuildList();
    void onUAVSelected(int catalogIdx);
    void applyStatusColor(QLabel* label, PayloadUAVCompatibilityStatus status);

    UAVPartPreflightData partData_;
    std::vector<UAVPayloadCompatibilityResult> results_;
    FilterMode filter_         = FilterMode::all;
    int currentUAVIndex_       = -1;

    QListWidget* uavList_     = nullptr;
    QPushButton* continueBtn_ = nullptr;

    // UAV card
    QGroupBox* cardBox_       = nullptr;
    QLabel*    cardTitle_     = nullptr;
    QLabel*    cardCountry_   = nullptr;
    QLabel*    cardType_      = nullptr;
    QLabel*    cardMassClass_ = nullptr;
    QLabel*    cardMass_      = nullptr;
    QLabel*    cardPayload_   = nullptr;
    QLabel*    cardMTOW_      = nullptr;
    QLabel*    cardMounts_    = nullptr;
    QLabel*    cardStatus_    = nullptr;

    // Compatibility panel
    QGroupBox* compBox_           = nullptr;
    QLabel*    compPayloadMass_   = nullptr;
    QLabel*    compMaxPayload_    = nullptr;
    QLabel*    compTotalMass_     = nullptr;
    QLabel*    compMTOW_          = nullptr;
    QLabel*    compBounds_        = nullptr;
    QLabel*    compStatusLabel_   = nullptr;
    QLabel*    compIssues_        = nullptr;
    QLabel*    compWarnings_      = nullptr;
};

} // namespace cadnext::gui
