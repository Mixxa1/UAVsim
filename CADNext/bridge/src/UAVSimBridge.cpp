#include "cadnext/bridge/UAVSimBridge.hpp"

#include "cadnext/bridge/UAVPartFormat.hpp"

namespace cadnext::bridge {

ExportPackage UAVSimBridge::makeExportPackage(const Document& document) const {
    ExportPackage package;
    package.id = document.id();
    package.name = document.name();

    for (const auto& object : document.objects()) {
        for (const auto& point : object.attachmentPoints) {
            package.attachments.push_back(AttachmentExport{
                point.id,
                point.name,
                uavpartAttachmentRoleName(point.role),
                point.localPosition,
                point.localRotation
            });
        }
    }

    return package;
}

} // namespace cadnext::bridge
