#include "cadnext/bridge/UAVPartFormat.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

namespace cadnext::bridge {

namespace {

std::array<std::uint32_t, 256> makeCrc32Table() {
    std::array<std::uint32_t, 256> table{};
    for (std::uint32_t i = 0; i < 256; ++i) {
        std::uint32_t value = i;
        for (int bit = 0; bit < 8; ++bit) {
            value = (value & 1u) ? (0xEDB88320u ^ (value >> 1)) : (value >> 1);
        }
        table[i] = value;
    }
    return table;
}

bool isFiniteVector(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

} // namespace

bool UAVPartHeader::magicMatches() const {
    return std::memcmp(magic, kUAVPartMagic, sizeof(kUAVPartMagic)) == 0;
}

std::uint32_t uavpartCrc32(const std::uint8_t* data, std::size_t length, std::uint32_t seed) {
    static const std::array<std::uint32_t, 256> table = makeCrc32Table();
    std::uint32_t crc = seed ^ 0xFFFFFFFFu;
    for (std::size_t i = 0; i < length; ++i) {
        crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

UAVPartMaterial uavpartDefaultMaterial() {
    UAVPartMaterial material;
    material.materialId = "default_abs";
    material.displayName = "ABS-пластик (по умолчанию)";
    material.densityKgPerM3 = 1050.0;
    material.previewColor = "#B0B0B0";
    material.source = "default";
    return material;
}

std::string uavpartAttachmentRoleName(AttachmentRole role) {
    switch (role) {
    case AttachmentRole::Frame: return "frame";
    case AttachmentRole::Wing: return "wing";
    case AttachmentRole::Payload: return "payload";
    case AttachmentRole::Camera: return "camera";
    case AttachmentRole::Sensor: return "sensor";
    case AttachmentRole::LandingGear: return "landingGear";
    case AttachmentRole::Motor: return "motor";
    case AttachmentRole::Battery: return "battery";
    case AttachmentRole::Antenna: return "antenna";
    case AttachmentRole::Generic: return "generic";
    }
    return "generic";
}

std::string uavpartReadinessIssueText(const std::string& issueCode) {
    if (issueCode == kIssueNoAttachmentPoints) {
        return "Для тестирования на БЛА добавьте хотя бы одну точку крепления";
    }
    if (issueCode == kIssueMassNotComputed) {
        return "Масса детали не рассчитана";
    }
    if (issueCode == kIssueInvalidBounds) {
        return "Габариты детали не определены";
    }
    if (issueCode == kIssueNoSimulationProxy) {
        return "Не сформирован упрощённый объём детали для симуляции";
    }
    return issueCode;
}

void uavpartFinalizeDescriptor(UAVPartDescriptor& descriptor) {
    UAVPartMassProperties& mass = descriptor.mass;

    mass.boundingWidth = mass.boundingBoxMax.x - mass.boundingBoxMin.x;
    mass.boundingDepth = mass.boundingBoxMax.y - mass.boundingBoxMin.y;
    mass.boundingHeight = mass.boundingBoxMax.z - mass.boundingBoxMin.z;

    const bool boundsValid = isFiniteVector(mass.boundingBoxMin) &&
                             isFiniteVector(mass.boundingBoxMax) &&
                             mass.boundingWidth > 0.0 && mass.boundingDepth > 0.0 &&
                             mass.boundingHeight > 0.0;

    const bool massValid = mass.valid && std::isfinite(mass.volumeM3) &&
                           mass.volumeM3 > 0.0 && std::isfinite(mass.massKg) &&
                           mass.massKg > 0.0 && isFiniteVector(mass.centerOfMass);
    mass.valid = massValid;

    // Консервативная оценка лобового сопротивления по габаритам: площадь
    // наибольшей грани габаритного бокса (м²). Не аэродинамика — только
    // metadata для будущей симуляции.
    if (boundsValid) {
        const double areaXY = mass.boundingWidth * mass.boundingDepth;
        const double areaXZ = mass.boundingWidth * mass.boundingHeight;
        const double areaYZ = mass.boundingDepth * mass.boundingHeight;
        mass.dragPenalty = std::max({areaXY, areaXZ, areaYZ});
    } else {
        mass.dragPenalty = 0.0;
    }
    if (!std::isfinite(mass.dragPenalty) || mass.dragPenalty < 0.0) {
        mass.dragPenalty = 0.0;
    }
    if (!std::isfinite(mass.structuralRating) || mass.structuralRating <= 0.0) {
        mass.structuralRating = 1.0;
    }

    // Box proxy строится из габаритов mass properties.
    UAVPartSimulationProxy& proxy = descriptor.simulationProxy;
    proxy.type = "box";
    proxy.source = "mass_properties_bounds";
    if (boundsValid) {
        proxy.center = {(mass.boundingBoxMin.x + mass.boundingBoxMax.x) / 2.0,
                        (mass.boundingBoxMin.y + mass.boundingBoxMax.y) / 2.0,
                        (mass.boundingBoxMin.z + mass.boundingBoxMax.z) / 2.0};
        proxy.size = {mass.boundingWidth, mass.boundingDepth, mass.boundingHeight};
        proxy.valid = true;
    } else {
        proxy.center = {};
        proxy.size = {};
        proxy.valid = false;
    }

    const bool hasEnabledAttachment =
        std::any_of(descriptor.attachmentPoints.begin(), descriptor.attachmentPoints.end(),
                    [](const UAVPartAttachmentPoint& point) { return point.isEnabled; });

    UAVPartManifest& manifest = descriptor.manifest;
    manifest.formatVersion = kUAVPartFormatVersion;
    manifest.massComputed = massValid;
    manifest.attachmentPointsDefined = hasEnabledAttachment;
    manifest.readinessIssues.clear();
    if (!massValid) {
        manifest.readinessIssues.push_back(kIssueMassNotComputed);
    }
    if (!boundsValid) {
        manifest.readinessIssues.push_back(kIssueInvalidBounds);
    }
    if (!hasEnabledAttachment) {
        manifest.readinessIssues.push_back(kIssueNoAttachmentPoints);
    }
    if (!proxy.valid) {
        manifest.readinessIssues.push_back(kIssueNoSimulationProxy);
    }
    manifest.simulationReady = manifest.readinessIssues.empty();
}

} // namespace cadnext::bridge
