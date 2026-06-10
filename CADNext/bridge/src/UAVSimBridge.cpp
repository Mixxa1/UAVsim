#include "cadnext/bridge/UAVSimBridge.hpp"

namespace cadnext::bridge {

namespace {

std::string roleName(AttachmentRole role) {
    switch (role) {
    case AttachmentRole::Frame:
        return "frame";
    case AttachmentRole::Wing:
        return "wing";
    case AttachmentRole::Payload:
        return "payload";
    case AttachmentRole::Camera:
        return "camera";
    case AttachmentRole::Sensor:
        return "sensor";
    case AttachmentRole::LandingGear:
        return "landingGear";
    case AttachmentRole::Motor:
        return "motor";
    case AttachmentRole::Battery:
        return "battery";
    case AttachmentRole::Antenna:
        return "antenna";
    case AttachmentRole::Generic:
        return "generic";
    }
    return "generic";
}

} // namespace

ExportPackage UAVSimBridge::makeExportPackage(const Document& document) const {
    ExportPackage package;
    package.id = document.id();
    package.name = document.name();

    for (const auto& object : document.objects()) {
        for (const auto& point : object.attachmentPoints) {
            package.attachments.push_back(AttachmentExport{
                point.id,
                point.name,
                roleName(point.role),
                point.localPosition,
                point.localRotation
            });
        }
    }

    return package;
}

} // namespace cadnext::bridge
