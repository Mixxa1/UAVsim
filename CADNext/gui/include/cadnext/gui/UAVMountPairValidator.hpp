#pragma once

#include <string>
#include <vector>

#include "cadnext/bridge/UAVPartFormat.hpp"
#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"

namespace cadnext::gui {

struct MountPairValidationResult {
    enum class Status { ready, attention, blocked };
    Status status = Status::blocked;
    std::vector<std::string> errors;
    std::vector<std::string> warnings;
};

// Validates a (partAttachmentPoint, uavMountPoint) pair for physical
// compatibility: role matching, mass limits, dimensional limits, COM shift.
class UAVMountPairValidator {
public:
    static MountPairValidationResult validate(
        const bridge::UAVPartAttachmentPoint& partPt,
        const UAVMountPointPreview& uavPt,
        double partMassKg,
        double partWidthM,
        double partHeightM,
        double partDepthM,
        double partCOMy,        // vertical COM offset in part local frame, metres
        double uavEmptyMassKg);

    static std::string statusText(MountPairValidationResult::Status status);
    static std::string roleDisplayText(const std::string& role);
};

} // namespace cadnext::gui
