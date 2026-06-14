#include "cadnext/gui/UAVPayloadCompatibilityChecker.hpp"

#include <algorithm>
#include <cmath>

namespace cadnext::gui {

UAVPartPreflightData UAVPayloadCompatibilityChecker::buildPreflightData(
    const bridge::UAVPartDescriptor& part)
{
    UAVPartPreflightData data;
    const auto& mass     = part.mass;
    const auto& manifest = part.manifest;

    data.massKg    = mass.massKg;
    data.massValid = mass.valid && manifest.massComputed && mass.massKg > 0.0;

    data.boundingWidth  = mass.boundingWidth;
    data.boundingHeight = mass.boundingHeight;
    data.boundingDepth  = mass.boundingDepth;
    data.partBoundingBoxMin = {
        mass.boundingBoxMin.x,
        mass.boundingBoxMin.y,
        mass.boundingBoxMin.z
    };
    data.partBoundingBoxMax = {
        mass.boundingBoxMax.x,
        mass.boundingBoxMax.y,
        mass.boundingBoxMax.z
    };
    data.boundsValid    = mass.valid
                       && mass.boundingWidth  > 0.0
                       && mass.boundingHeight > 0.0
                       && mass.boundingDepth  > 0.0;

    data.partId = manifest.id;
    data.partDisplayName = manifest.displayName.empty()
                         ? manifest.name
                         : manifest.displayName;
    data.partCenterOfMass = {
        part.mass.centerOfMass.x,
        part.mass.centerOfMass.y,
        part.mass.centerOfMass.z
    };
    data.dragPenalty = part.mass.dragPenalty;
    data.structuralRating = part.mass.structuralRating;
    data.materialId = part.material.materialId;
    data.collisionProxy = part.simulationProxy;

    for (const auto& pt : part.attachmentPoints) {
        if (pt.isEnabled) {
            data.hasEnabledAttachmentPoint = true;
            data.enabledAttachmentRoles.push_back(pt.role);
            data.attachmentPoints.push_back(pt);
        }
    }

    if (part.visualMesh.valid && !part.visualMesh.vertices.empty()) {
        data.meshVertices = part.visualMesh.vertices;
        data.meshIndices  = part.visualMesh.indices;
        data.hasMesh      = true;
    }

    data.materialPreviewColor = part.material.previewColor;

    // Hard preflight failures — block UAV selection.
    if (!data.massValid) {
        data.preflightError = "Масса детали не рассчитана";
        return data;
    }
    if (!data.boundsValid) {
        data.preflightError = "Габариты детали повреждены";
        return data;
    }
    if (!data.hasEnabledAttachmentPoint) {
        data.preflightError = "Добавьте хотя бы одну точку крепления";
        return data;
    }

    // Non-blocking warnings shown in the UI.
    if (mass.massKg > 100.0) {
        data.preflightWarnings.push_back(
            "Масса детали превышает 100 кг — проверьте материал и геометрию");
    }
    const double maxDim = std::max({mass.boundingWidth,
                                    mass.boundingHeight,
                                    mass.boundingDepth});
    if (maxDim >= 1.0) {
        data.preflightWarnings.push_back(
            "Габарит детали превышает 1 м — проверьте единицы измерения");
    }

    return data;
}

UAVPayloadCompatibilityResult UAVPayloadCompatibilityChecker::checkCompatibility(
    const UAVPartPreflightData& partData,
    const UAVCatalogPreviewItem& uav)
{
    UAVPayloadCompatibilityResult result;
    result.payloadMassKg    = partData.massKg;
    result.emptyMassKg      = uav.emptyMassKg;
    result.totalMassKg      = uav.emptyMassKg + partData.massKg;
    result.maxPayloadMassKg = uav.maxPayloadMassKg;
    result.maxTakeoffMassKg = uav.maxTakeoffMassKg;

    if (uav.maxPayloadMassKg <= 0.0 || uav.maxTakeoffMassKg <= 0.0) {
        result.status = PayloadUAVCompatibilityStatus::unknown;
        result.warnings.push_back("Недостаточно данных о характеристиках аппарата");
        return result;
    }

    bool hasError = false;

    // Check 1: payload mass vs max payload
    if (partData.massKg > uav.maxPayloadMassKg) {
        result.errors.push_back("Масса детали превышает допустимую полезную нагрузку");
        hasError = true;
    }

    // Check 2: total mass vs MTOW
    if (result.totalMassKg > uav.maxTakeoffMassKg) {
        result.errors.push_back("Превышена максимальная взлётная масса");
        hasError = true;
    }

    // Check 3: UAV must have at least one enabled payload or generic mount point
    bool uavHasPayloadMount = false;
    for (const auto& mp : uav.mountPoints) {
        if (mp.isEnabled && (mp.role == "payload" || mp.role == "generic")) {
            uavHasPayloadMount = true;
            break;
        }
    }
    if (!uavHasPayloadMount) {
        result.errors.push_back("У аппарата нет доступной точки крепления полезной нагрузки");
        hasError = true;
    }

    if (hasError) {
        result.status = PayloadUAVCompatibilityStatus::incompatible;
        return result;
    }

    bool hasWarning = false;

    // Warning: part uses > 80 % of payload budget
    if (partData.massKg / uav.maxPayloadMassKg > 0.8) {
        result.warnings.push_back("Деталь занимает более 80% допустимой полезной нагрузки");
        hasWarning = true;
    }

    // Warning: part mass > 100 kg
    if (partData.massKg > 100.0) {
        result.warnings.push_back(
            "Масса детали превышает 100 кг — проверьте материал и геометрию");
        hasWarning = true;
    }

    // Warning: any dimension >= 1 m
    const double maxDim = std::max({partData.boundingWidth,
                                    partData.boundingHeight,
                                    partData.boundingDepth});
    if (maxDim >= 1.0) {
        result.warnings.push_back(
            "Габарит детали превышает 1 м — проверьте масштаб модели");
        hasWarning = true;
    }

    // Dimensional envelope check (if UAV publishes envelope data)
    if (uav.maxPayloadWidthM || uav.maxPayloadHeightM || uav.maxPayloadDepthM) {
        bool dimExceeded = false;
        if (uav.maxPayloadWidthM  && partData.boundingWidth  > *uav.maxPayloadWidthM)
            dimExceeded = true;
        if (uav.maxPayloadHeightM && partData.boundingHeight > *uav.maxPayloadHeightM)
            dimExceeded = true;
        if (uav.maxPayloadDepthM  && partData.boundingDepth  > *uav.maxPayloadDepthM)
            dimExceeded = true;
        if (dimExceeded) {
            result.warnings.push_back(
                "Габариты детали превышают допустимый объём полезной нагрузки аппарата");
            hasWarning = true;
        }
    } else {
        result.warnings.push_back(
            "Габаритная проверка ограничена: у БЛА нет данных о допустимом объёме нагрузки");
        // Informational only — not treated as a blocking warning for hasWarning
    }

    // Unverified data notice
    if (!uav.hasVerifiedData) {
        result.warnings.push_back(
            "Характеристики аппарата получены из оценочных данных");
        hasWarning = true;
    }

    result.status = hasWarning
        ? PayloadUAVCompatibilityStatus::limited
        : PayloadUAVCompatibilityStatus::compatible;
    return result;
}

std::string UAVPayloadCompatibilityChecker::statusText(PayloadUAVCompatibilityStatus s)
{
    switch (s) {
    case PayloadUAVCompatibilityStatus::compatible:   return "Совместим";
    case PayloadUAVCompatibilityStatus::limited:      return "Ограниченно совместим";
    case PayloadUAVCompatibilityStatus::incompatible: return "Несовместим";
    case PayloadUAVCompatibilityStatus::unknown:      return "Недостаточно данных";
    }
    return "—";
}

std::string UAVPayloadCompatibilityChecker::vehicleTypeText(UAVPreviewVehicleType t)
{
    switch (t) {
    case UAVPreviewVehicleType::multicopter: return "Мультикоптер";
    case UAVPreviewVehicleType::fixedWing:   return "Самолёт";
    case UAVPreviewVehicleType::hybridVTOL:  return "Гибрид VTOL";
    case UAVPreviewVehicleType::helicopter:  return "Вертолёт";
    case UAVPreviewVehicleType::custom:      return "Пользовательский";
    }
    return "—";
}

std::string UAVPayloadCompatibilityChecker::massCategoryText(UAVPreviewMassCategory c)
{
    switch (c) {
    case UAVPreviewMassCategory::nano:   return "нано";
    case UAVPreviewMassCategory::micro:  return "микро";
    case UAVPreviewMassCategory::light:  return "лёгкий";
    case UAVPreviewMassCategory::medium: return "средний";
    case UAVPreviewMassCategory::heavy:  return "тяжёлый";
    }
    return "—";
}

} // namespace cadnext::gui
