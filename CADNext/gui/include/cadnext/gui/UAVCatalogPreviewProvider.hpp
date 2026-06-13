#pragma once

#include <optional>
#include <string>
#include <vector>

namespace cadnext::gui {

enum class UAVPreviewVehicleType { multicopter, fixedWing, hybridVTOL, helicopter, custom };
enum class UAVPreviewMassCategory { nano, micro, light, medium, heavy };

struct UAVVec3 { double x = 0.0, y = 0.0, z = 0.0; };

struct UAVMountPointPreview {
    std::string id;
    std::string name;
    std::string role; // "payload", "camera", "sensor", "generic"
    UAVVec3 localPosition;         // body-frame, metres (Y = up)
    UAVVec3 localRotation;         // Euler angles, degrees
    bool isEnabled = true;
    std::optional<double> maxPayloadMassKg;
    std::optional<double> maxWidthM;
    std::optional<double> maxHeightM;
    std::optional<double> maxDepthM;
};

// One entry in the local UAV catalog used for .uavpart preflight compatibility.
// Data is adapted from UAVReferenceCatalog in the Swift runtime layer.
// emptyMassKg: airframe + batteries.
// maxPayloadMassKg: practical capacity = maxTakeoffMassKg - emptyMassKg.
struct UAVCatalogPreviewItem {
    std::string id;
    std::string name;
    std::string country;
    UAVPreviewVehicleType  vehicleType  = UAVPreviewVehicleType::multicopter;
    UAVPreviewMassCategory massCategory = UAVPreviewMassCategory::light;
    double emptyMassKg      = 0.0;
    double maxPayloadMassKg = 0.0;
    double maxTakeoffMassKg = 0.0;
    bool   hasVerifiedData  = false;
    std::vector<UAVMountPointPreview> mountPoints;
    std::optional<double> maxPayloadWidthM;
    std::optional<double> maxPayloadHeightM;
    std::optional<double> maxPayloadDepthM;
};

// Read-only snapshot of the UAV reference catalog for .uavpart pre-flight
// compatibility checks. Adapted from the Swift-side UAVReferenceCatalog.
class UAVCatalogPreviewProvider {
public:
    static const std::vector<UAVCatalogPreviewItem>& catalog();
};

} // namespace cadnext::gui
