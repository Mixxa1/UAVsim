import AppKit
import SceneKit

enum OnlineTrialVehiclePlaceholderNodeFactory {
    static func makeNode(for slot: OnlineTrialVehicleSlot) -> SCNNode {
        let root = SCNNode()
        root.name = "online_trial_vehicle_placeholder_\(slot.vehicleID.uuidString)"
        root.simdPosition = OnlineTrialSpawnLayout.position(for: slot.spawnIndex)

        let marker = SCNNode(geometry: SCNPyramid(width: 0.70, height: 0.28, length: 0.92))
        marker.name = "online_trial_vehicle_marker"
        marker.simdPosition = SIMD3<Float>(0.0, 0.46, 0.0)
        marker.eulerAngles.y = .pi
        marker.geometry?.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.46)
        marker.geometry?.firstMaterial?.emission.contents = NSColor.systemCyan.withAlphaComponent(0.22)
        marker.geometry?.firstMaterial?.lightingModel = .constant
        root.addChildNode(marker)

        let stem = SCNNode(geometry: SCNCylinder(radius: 0.025, height: 0.72))
        stem.name = "online_trial_vehicle_stem"
        stem.simdPosition = SIMD3<Float>(0.0, 0.18, 0.0)
        stem.geometry?.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.34)
        stem.geometry?.firstMaterial?.lightingModel = .constant
        root.addChildNode(stem)

        let disk = SCNNode(geometry: SCNCylinder(radius: 0.34, height: 0.018))
        disk.name = "online_trial_vehicle_shadow"
        disk.simdPosition = SIMD3<Float>(0.0, 0.012, 0.0)
        disk.geometry?.firstMaterial?.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.18)
        disk.geometry?.firstMaterial?.lightingModel = .constant
        root.addChildNode(disk)

        let label = SCNNode(geometry: labelGeometry(slot.participantName))
        label.name = "online_trial_vehicle_label"
        label.simdPosition = SIMD3<Float>(-0.55, 0.92, 0.0)
        label.scale = SCNVector3(0.010, 0.010, 0.010)
        root.addChildNode(label)

        return root
    }

    private static func labelGeometry(_ text: String) -> SCNText {
        let geometry = SCNText(string: text, extrusionDepth: 0.01)
        geometry.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        geometry.alignmentMode = "left"
        geometry.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(0.84)
        geometry.firstMaterial?.emission.contents = NSColor.white.withAlphaComponent(0.20)
        geometry.firstMaterial?.lightingModel = .constant
        return geometry
    }
}
