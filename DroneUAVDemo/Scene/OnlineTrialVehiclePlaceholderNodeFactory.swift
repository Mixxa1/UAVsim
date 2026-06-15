import AppKit
import SceneKit

enum OnlineTrialVehiclePlaceholderNodeFactory {
    static func makeNode(for slot: OnlineTrialVehicleSlot) -> SCNNode {
        makeNode(
            vehicleID: slot.vehicleID,
            participantName: slot.participantName,
            spawnIndex: slot.spawnIndex
        )
    }

    static func makeNode(for snapshot: OnlineVehicleStateSnapshot, fallbackSpawnIndex: Int) -> SCNNode {
        makeNode(
            vehicleID: snapshot.vehicleID,
            participantName: snapshot.participantName,
            spawnIndex: fallbackSpawnIndex
        )
    }

    // v1.5: remote replica uses the same visual profile as the participant's selected UAV.
    // Falls back to abstract-uav only when the profileID is unknown.
    // Opacity 0.88 + cyan tint lets pilots distinguish replica from their own local UAV.
    static func makeGhostNode(vehicleID: UUID, participantName: String, spawnIndex: Int?, vehicleProfileID: String? = nil) -> SCNNode {
        let profile = resolveProfile(vehicleProfileID)
        let visual = DroneModelBuilder.build(profile: profile)
        let root = visual.rootNode
        root.name = "online_trial_vehicle_\(vehicleID.uuidString)"
        root.opacity = 0.88

        if let spawnIndex {
            root.simdPosition = OnlineTrialSpawnLayout.position(for: spawnIndex)
        }

        // Tint visual root slightly cyan to distinguish from local UAV.
        tintNode(visual.visualRootNode, color: NSColor(red: 0.72, green: 0.90, blue: 1.0, alpha: 1.0))

        // Participant name label above the UAV.
        let label = makeLabelNode(participantName)
        label.simdPosition = SIMD3<Float>(0, 0.28, 0)
        root.addChildNode(label)

        return root
    }

    // Look up a DroneModelProfile by ID; fall back to abstract-uav only when truly unknown.
    private static let profileRepository = LIPODroneModelRepository()
    private static func resolveProfile(_ profileID: String?) -> DroneModelProfile {
        let abstractFallback = LIPODroneModelRepository.abstractProfile(from: AbstractDroneParameters.default)
        guard let profileID else {
            #if DEBUG
            print("[LAN][PROFILE][WARNING] Falling back to abstract replica — profileID is nil")
            #endif
            return abstractFallback
        }
        if let found = profileRepository.allProfiles.first(where: { $0.id == profileID }) {
            #if DEBUG
            print("[LAN][PROFILE] replica factory resolved profileID=\(profileID) → \(found.uiDisplayName)")
            #endif
            return found
        }
        #if DEBUG
        print("[LAN][PROFILE][WARNING] Falling back to abstract replica for profileID=\(profileID) — not found in repository")
        #endif
        return abstractFallback
    }

    private static func makeNode(
        vehicleID: UUID,
        participantName: String,
        spawnIndex: Int
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "online_trial_vehicle_\(vehicleID.uuidString)"
        root.simdPosition = OnlineTrialSpawnLayout.position(for: spawnIndex)

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

        let label = SCNNode(geometry: labelGeometry(participantName))
        label.name = "online_trial_vehicle_label"
        label.simdPosition = SIMD3<Float>(-0.55, 0.92, 0.0)
        label.scale = SCNVector3(0.010, 0.010, 0.010)
        root.addChildNode(label)

        return root
    }

    private static func makeLabelNode(_ text: String) -> SCNNode {
        let label = SCNNode(geometry: labelGeometry(text))
        label.name = "online_trial_vehicle_label"
        label.scale = SCNVector3(0.009, 0.009, 0.009)
        return label
    }

    private static func labelGeometry(_ text: String) -> SCNText {
        let geometry = SCNText(string: text, extrusionDepth: 0.01)
        geometry.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        geometry.alignmentMode = "left"
        geometry.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(0.90)
        geometry.firstMaterial?.emission.contents = NSColor.systemCyan.withAlphaComponent(0.25)
        geometry.firstMaterial?.lightingModel = .constant
        return geometry
    }

    // Apply a subtle color tint to all geometry materials in a subtree.
    private static func tintNode(_ node: SCNNode, color: NSColor) {
        if let mat = node.geometry?.firstMaterial {
            if let existing = mat.diffuse.contents as? NSColor {
                mat.diffuse.contents = existing.blended(withFraction: 0.18, of: color) ?? existing
            }
        }
        node.childNodes.forEach { tintNode($0, color: color) }
    }
}
