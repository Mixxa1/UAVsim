#pragma once

#include <string>
#include <vector>

#include "cadnext/bridge/UAVPartFormat.hpp"
#include "cadnext/gui/UAVCatalogPreviewProvider.hpp"

namespace cadnext::gui {

enum class PayloadUAVCompatibilityStatus {
    compatible,   // mass + MTOW + mounts all OK, no notable warnings
    limited,      // OK on hard constraints, but warnings present
    incompatible, // at least one hard constraint failed
    unknown       // required UAV data unavailable
};

struct UAVPayloadCompatibilityResult {
    PayloadUAVCompatibilityStatus status = PayloadUAVCompatibilityStatus::unknown;
    std::vector<std::string> errors;   // hard failures
    std::vector<std::string> warnings; // non-blocking issues
    double payloadMassKg    = 0.0;
    double emptyMassKg      = 0.0;
    double totalMassKg      = 0.0;
    double maxPayloadMassKg = 0.0;
    double maxTakeoffMassKg = 0.0;
};

// Summary of the .uavpart data needed for compatibility checking and UI.
// Computed once from UAVPartDescriptor and then passed around.
struct UAVPartPreflightData {
    double massKg        = 0.0;
    double boundingWidth = 0.0;   // metres
    double boundingHeight= 0.0;   // metres
    double boundingDepth = 0.0;   // metres
    bool massValid                 = false;
    bool boundsValid               = false;
    bool hasEnabledAttachmentPoint = false;
    std::vector<std::string> enabledAttachmentRoles;
    // Empty = preflight passed; non-empty = show error and block UAV selection.
    std::string preflightError;
    std::vector<std::string> preflightWarnings;

    // Extended fields populated for the Mount Editor.
    std::string partId;
    std::string partFilePath;
    std::string partDisplayName;
    UAVVec3 partCenterOfMass;
    UAVVec3 partBoundingBoxMin;
    UAVVec3 partBoundingBoxMax;
    double dragPenalty = 0.0;
    double structuralRating = 1.0;
    std::string materialId;
    std::vector<bridge::UAVPartAttachmentPoint> attachmentPoints; // enabled only
    std::vector<float>    meshVertices;  // packed float triples, empty when no mesh
    std::vector<uint32_t> meshIndices;   // triangle index triples
    bool hasMesh = false;
    std::string materialPreviewColor;    // "#RRGGBB" or ""
    bridge::UAVPartSimulationProxy collisionProxy;
};

class UAVPayloadCompatibilityChecker {
public:
    // Build preflight data from a fully-read UAVPartDescriptor.
    // Sets preflightError if the part cannot proceed to UAV selection.
    static UAVPartPreflightData buildPreflightData(
        const bridge::UAVPartDescriptor& part);

    // Check one UAV against already-built preflight data.
    static UAVPayloadCompatibilityResult checkCompatibility(
        const UAVPartPreflightData& partData,
        const UAVCatalogPreviewItem& uav);

    // Localized display strings.
    static std::string statusText(PayloadUAVCompatibilityStatus status);
    static std::string vehicleTypeText(UAVPreviewVehicleType type);
    static std::string massCategoryText(UAVPreviewMassCategory cat);
};

} // namespace cadnext::gui
