import Foundation

enum SimulationLaunchSource: String, Codable, Hashable {
    case normalProject
    case cadPayloadTest
}

enum InitialPayloadState: String, Codable, Hashable {
    case mounted
    case disabled
    case failed
}

struct SimulationLaunchConfiguration: Codable, Hashable {
    var schemaVersion: Int
    var selectedUAVProfile: String
    var selectedMapProfile: String?
    var mountedCADPayload: MountedCADPayload?
    var launchSource: SimulationLaunchSource
    var initialPayloadState: InitialPayloadState

    func validationError(activeUAVProfile: UAVProfile?) -> String? {
        guard launchSource == .cadPayloadTest else {
            return nil
        }
        guard initialPayloadState == .mounted else {
            return "cad.mount_editor.launch_failed"
        }
        guard let mountedCADPayload else {
            return "cad.mount_editor.launch_failed"
        }
        guard mountedCADPayload.massKg.isFinite, mountedCADPayload.massKg > 0.0 else {
            return "payload.message.invalid_mass"
        }
        guard selectedUAVProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              activeUAVProfile != nil else {
            return "payload.message.select_uav"
        }
        guard mountedCADPayload.payloadAttachmentPointID.isEmpty == false,
              mountedCADPayload.uavMountPointID.isEmpty == false else {
            return "cad.mount_editor.invalid_transform"
        }
        guard mountedCADPayload.transformIsFinite else {
            return "cad.mount_editor.invalid_transform"
        }
        guard mountedCADPayload.hasRenderableVisual || mountedCADPayload.collisionProxy.hasUsableBounds else {
            return "cad.payload.runtime.visual_missing"
        }
        guard mountedCADPayload.mountValidationResult.isValid else {
            return "cad.mount_editor.invalid_transform"
        }

        return nil
    }
}
