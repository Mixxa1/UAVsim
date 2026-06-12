#include "cadnext/bridge/UAVPartValidator.hpp"

#include <cmath>

namespace cadnext::bridge {

namespace {

bool isFiniteVector(const Vector3& v) {
    return std::isfinite(v.x) && std::isfinite(v.y) && std::isfinite(v.z);
}

// Все числовые поля payload'ов: NaN/Infinity запрещены форматом.
bool descriptorNumbersFinite(const UAVPartDescriptor& descriptor) {
    const UAVPartMassProperties& mass = descriptor.mass;
    if (!std::isfinite(mass.volumeM3) || !std::isfinite(mass.massKg) ||
        !isFiniteVector(mass.centerOfMass) || !isFiniteVector(mass.boundingBoxMin) ||
        !isFiniteVector(mass.boundingBoxMax) || !std::isfinite(mass.boundingWidth) ||
        !std::isfinite(mass.boundingDepth) || !std::isfinite(mass.boundingHeight) ||
        !std::isfinite(mass.dragPenalty) || !std::isfinite(mass.structuralRating) ||
        !std::isfinite(mass.densityKgPerM3)) {
        return false;
    }
    if (!std::isfinite(descriptor.material.densityKgPerM3)) {
        return false;
    }
    if (!isFiniteVector(descriptor.simulationProxy.center) ||
        !isFiniteVector(descriptor.simulationProxy.size)) {
        return false;
    }
    for (const UAVPartAttachmentPoint& point : descriptor.attachmentPoints) {
        if (!isFiniteVector(point.localPosition) || !isFiniteVector(point.localRotation)) {
            return false;
        }
    }
    if (descriptor.compatibility.maxRecommendedSpeedMps &&
        !std::isfinite(*descriptor.compatibility.maxRecommendedSpeedMps)) {
        return false;
    }
    return true;
}

bool boundsValid(const UAVPartMassProperties& mass) {
    return isFiniteVector(mass.boundingBoxMin) && isFiniteVector(mass.boundingBoxMax) &&
           mass.boundingWidth > 0.0 && mass.boundingDepth > 0.0 && mass.boundingHeight > 0.0;
}

} // namespace

UAVPartValidationResult UAVPartValidator::validateForWrite(
    const UAVPartDescriptor& descriptor) const {
    UAVPartValidationResult result;

    if (descriptor.manifest.id.empty()) {
        result.errors.push_back("Не выбрана деталь для сохранения");
    }
    if (!descriptorNumbersFinite(descriptor)) {
        result.errors.push_back(
            "Данные детали содержат некорректные числа (NaN или бесконечность)");
        return result;
    }

    const UAVPartMaterial& material = descriptor.material;
    if (!(material.densityKgPerM3 > 0.0)) {
        result.errors.push_back(
            "Материал детали не содержит плотность — невозможно рассчитать массу");
    }

    const UAVPartMassProperties& mass = descriptor.mass;
    if (!mass.valid || !(mass.volumeM3 > 0.0) || !(mass.massKg > 0.0)) {
        result.errors.push_back(
            "Невозможно рассчитать массу: отсутствует точная геометрия детали");
    }
    if (!boundsValid(mass)) {
        result.errors.push_back("Габариты детали не определены или некорректны");
    }

    if (material.source == "default") {
        result.warnings.push_back(
            "Материал не выбран — использован материал по умолчанию (" +
            material.displayName + ")");
    }
    if (!descriptor.manifest.attachmentPointsDefined) {
        result.warnings.push_back(
            uavpartReadinessIssueText(kIssueNoAttachmentPoints));
    }
    if (!descriptor.simulationProxy.valid) {
        result.warnings.push_back(uavpartReadinessIssueText(kIssueNoSimulationProxy));
    }

    return result;
}

UAVPartValidationResult UAVPartValidator::validateSavedPart(
    const UAVPartReadResult& readResult) const {
    UAVPartValidationResult result;

    if (!readResult.header.magicMatches() ||
        readResult.header.formatVersion != kUAVPartFormatVersion) {
        result.errors.push_back(
            "Файл детали повреждён или имеет неподдерживаемый формат");
        return result;
    }
    if (readResult.part.manifest.id.empty()) {
        result.errors.push_back("В сохранённом файле отсутствует манифест детали");
    }
    const UAVPartMassProperties& mass = readResult.part.mass;
    if (!(mass.massKg > 0.0) || !std::isfinite(mass.massKg)) {
        result.errors.push_back("В сохранённом файле некорректная масса детали");
    }
    if (!boundsValid(mass)) {
        result.errors.push_back("В сохранённом файле некорректные габариты детали");
    }
    return result;
}

} // namespace cadnext::bridge
