#include "cadnext/gui/UAVMountPairValidator.hpp"

#include <cmath>

namespace cadnext::gui {

namespace {

// Returns true if the roles are physically compatible.
// Sets isWarning = true when compatible but not ideal.
bool rolesCompatible(const std::string& partRole, const std::string& uavRole,
                     bool& isWarning)
{
    isWarning = false;
    if (partRole == "payload") {
        if (uavRole == "payload") return true;
        if (uavRole == "generic") { isWarning = true; return true; }
        return false;
    }
    if (partRole == "camera") {
        if (uavRole == "camera")  return true;
        if (uavRole == "sensor")  return true;
        if (uavRole == "generic") { isWarning = true; return true; }
        return false;
    }
    if (partRole == "sensor") {
        if (uavRole == "sensor")  return true;
        if (uavRole == "payload") { isWarning = true; return true; }
        if (uavRole == "generic") { isWarning = true; return true; }
        return false;
    }
    // partRole == "generic" or unknown
    if (uavRole == "payload") { isWarning = true; return true; }
    if (uavRole == "generic") { isWarning = true; return true; }
    return false;
}

} // namespace

MountPairValidationResult UAVMountPairValidator::validate(
    const bridge::UAVPartAttachmentPoint& partPt,
    const UAVMountPointPreview& uavPt,
    double partMassKg,
    double partWidthM,
    double partHeightM,
    double partDepthM,
    double partCOMy,
    double uavEmptyMassKg)
{
    MountPairValidationResult result;

    if (!partPt.isEnabled)
        result.errors.push_back("Точка крепления детали отключена");
    if (!uavPt.isEnabled)
        result.errors.push_back("Точка крепления БЛА отключена");

    bool roleWarn = false;
    if (!rolesCompatible(partPt.role, uavPt.role, roleWarn)) {
        result.errors.push_back(
            "Несовместимые роли: деталь «" + roleDisplayText(partPt.role)
            + "» → БЛА «" + roleDisplayText(uavPt.role) + "»");
    } else if (roleWarn) {
        result.warnings.push_back(
            "Роли не совпадают идеально: деталь «" + roleDisplayText(partPt.role)
            + "» → БЛА «" + roleDisplayText(uavPt.role) + "»");
    }

    // Per-mount mass limit (if published)
    if (uavPt.maxPayloadMassKg && partMassKg > *uavPt.maxPayloadMassKg) {
        result.errors.push_back(
            "Масса детали превышает лимит точки крепления БЛА");
    }

    // Dimensional envelope (if published)
    bool dimViol = false;
    if (uavPt.maxWidthM  && partWidthM  > *uavPt.maxWidthM)  dimViol = true;
    if (uavPt.maxHeightM && partHeightM > *uavPt.maxHeightM) dimViol = true;
    if (uavPt.maxDepthM  && partDepthM  > *uavPt.maxDepthM)  dimViol = true;
    if (dimViol) {
        result.errors.push_back(
            "Габариты детали превышают допустимый объём точки крепления");
    }

    // COM shift warning: payload mass / UAV empty mass > 0.2
    if (uavEmptyMassKg > 0.0 && partMassKg / uavEmptyMassKg > 0.2) {
        const int pct = static_cast<int>(partMassKg / uavEmptyMassKg * 100.0);
        result.warnings.push_back(
            "Возможно значительное смещение ЦМ: нагрузка составляет "
            + std::to_string(pct) + "% от пустой массы БЛА");
    }

    // Vertical COM offset warning
    if (std::abs(partCOMy) > 0.05) {
        const int mm = static_cast<int>(std::abs(partCOMy) * 1000.0);
        result.warnings.push_back(
            "Центр масс детали смещён вертикально на " + std::to_string(mm)
            + " мм — проверьте устойчивость");
    }

    if (!result.errors.empty())
        result.status = MountPairValidationResult::Status::blocked;
    else if (!result.warnings.empty())
        result.status = MountPairValidationResult::Status::attention;
    else
        result.status = MountPairValidationResult::Status::ready;

    return result;
}

std::string UAVMountPairValidator::statusText(MountPairValidationResult::Status s)
{
    switch (s) {
    case MountPairValidationResult::Status::ready:     return "Готово к монтажу";
    case MountPairValidationResult::Status::attention: return "Требует внимания";
    case MountPairValidationResult::Status::blocked:   return "Невозможно установить";
    }
    return "—";
}

std::string UAVMountPairValidator::roleDisplayText(const std::string& role)
{
    if (role == "payload") return "полезная нагрузка";
    if (role == "camera")  return "камера";
    if (role == "sensor")  return "датчик";
    if (role == "generic") return "общая";
    return role.empty() ? "?" : role;
}

} // namespace cadnext::gui
