#pragma once

#include <QDialog>
#include <optional>
#include <string>

#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"
#include "cadnext/gui/UAVPayloadCompatibilityChecker.hpp"

class QDoubleSpinBox;
class QGroupBox;
class QLabel;
class QListWidget;
class QPushButton;
class SoQtExaminerViewer;
class SoSeparator;

namespace cadnext::gui {

// Result produced when the user confirms a mount configuration.
// Stored in memory only — does not start simulation and does not create a
// runtime MountedCADPayload.
struct MountEditorResult {
    std::string partId;
    std::string uavId;
    std::string payloadAttachmentPointId;
    std::string uavMountPointId;
    double translateX = 0.0, translateY = 0.0, translateZ = 0.0; // metres
    double rotateX    = 0.0, rotateY    = 0.0, rotateZ    = 0.0; // degrees
    bool isValid = false;
    std::string timestamp; // ISO 8601
};

// Mount Editor dialog.  Shows a 3D viewer (procedural UAV body + mount-point
// markers + translucent part ghost) on the left; attachment-point lists,
// rotation controls, and a live validation panel on the right.
// "Подтвердить крепление" stores a MountEditorResult and closes.
class UAVMountEditorDialog : public QDialog {
    Q_OBJECT

public:
    explicit UAVMountEditorDialog(const UAVPartPreflightData&        partData,
                                   const UAVCatalogPreviewItem&       uav,
                                   const UAVPayloadCompatibilityResult& compat,
                                   QWidget*                           parent = nullptr);
    ~UAVMountEditorDialog() override;

    std::optional<MountEditorResult> result() const { return result_; }

private:
    void rebuildMarkersScene();
    void rebuildGhostPreview();
    void runValidation();
    void onConfirm();

    UAVPartPreflightData  partData_;
    UAVCatalogPreviewItem uav_;

    int selectedPartPtIdx_ = -1;
    int selectedUAVPtIdx_  = -1;
    std::optional<MountEditorResult> result_;

    SoQtExaminerViewer* viewer_      = nullptr;
    SoSeparator*        sceneRoot_   = nullptr;
    SoSeparator*        markersRoot_ = nullptr;
    SoSeparator*        ghostRoot_   = nullptr;

    QListWidget*    partPtList_  = nullptr;
    QListWidget*    uavPtList_   = nullptr;
    QDoubleSpinBox* spinRotX_    = nullptr;
    QDoubleSpinBox* spinRotY_    = nullptr;
    QDoubleSpinBox* spinRotZ_    = nullptr;
    QLabel*         valStatus_   = nullptr;
    QLabel*         valErrors_   = nullptr;
    QLabel*         valWarnings_ = nullptr;
    QPushButton*    confirmBtn_  = nullptr;
};

} // namespace cadnext::gui
