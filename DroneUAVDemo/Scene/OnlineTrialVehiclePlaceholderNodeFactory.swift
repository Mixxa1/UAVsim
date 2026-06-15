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

    // P2P 0.9: multicopter ghost — visual-only remote vehicle, not a physics body.
    static func makeGhostNode(vehicleID: UUID, participantName: String, spawnIndex: Int?) -> SCNNode {
        let root = SCNNode()
        root.name = "online_trial_vehicle_\(vehicleID.uuidString)"
        if let spawnIndex {
            root.simdPosition = OnlineTrialSpawnLayout.position(for: spawnIndex)
        }

        let ghostMaterial = SCNMaterial()
        ghostMaterial.diffuse.contents = NSColor.systemCyan.withAlphaComponent(0.52)
        ghostMaterial.emission.contents = NSColor.systemCyan.withAlphaComponent(0.18)
        ghostMaterial.lightingModel = .constant
        ghostMaterial.isDoubleSided = true
        ghostMaterial.transparency = 0.52

        let noseMaterial = SCNMaterial()
        noseMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.82)
        noseMaterial.lightingModel = .constant
        noseMaterial.isDoubleSided = true

        func applyGhost(_ node: SCNNode) { node.geometry?.materials = [ghostMaterial] }

        // Central body
        let body = SCNNode(geometry: SCNBox(width: 0.18, height: 0.055, length: 0.18, chamferRadius: 0.008))
        body.simdPosition = SIMD3<Float>(0, 0.028, 0)
        applyGhost(body)
        root.addChildNode(body)

        // 4 arms (+ config, N/S along +Z/-Z, E/W along +X/-X)
        let armNS = SCNCapsule(capRadius: 0.011, height: 0.20)
        let armEW = SCNCapsule(capRadius: 0.011, height: 0.20)
        armNS.materials = [ghostMaterial]
        armEW.materials = [ghostMaterial]

        let armN = SCNNode(geometry: armNS)
        armN.simdPosition = SIMD3<Float>(0, 0.028, 0)
        armN.eulerAngles.x = .pi / 2.0
        root.addChildNode(armN)

        let armE = SCNNode(geometry: armEW)
        armE.simdPosition = SIMD3<Float>(0, 0.028, 0)
        armE.eulerAngles.z = .pi / 2.0
        root.addChildNode(armE)

        // 4 rotor discs at arm tips
        let rotorPositions: [(Float, Float, Float)] = [
            (0, 0.038, +0.105),
            (0, 0.038, -0.105),
            (+0.105, 0.038, 0),
            (-0.105, 0.038, 0)
        ]
        for (rx, ry, rz) in rotorPositions {
            let disc = SCNCylinder(radius: 0.082, height: 0.005)
            disc.materials = [ghostMaterial]
            let discNode = SCNNode(geometry: disc)
            discNode.simdPosition = SIMD3<Float>(rx, ry, rz)
            root.addChildNode(discNode)
        }

        // Nose marker (forward = +Z in local frame)
        let nose = SCNBox(width: 0.032, height: 0.032, length: 0.048, chamferRadius: 0.003)
        nose.materials = [noseMaterial]
        let noseNode = SCNNode(geometry: nose)
        noseNode.simdPosition = SIMD3<Float>(0, 0.038, +0.115)
        root.addChildNode(noseNode)

        // Participant label
        let labelGeo = SCNText(string: participantName, extrusionDepth: 0.01)
        labelGeo.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        labelGeo.alignmentMode = "left"
        labelGeo.materials = [ghostMaterial.copy() as! SCNMaterial]
        labelGeo.firstMaterial?.diffuse.contents = NSColor.white.withAlphaComponent(0.86)
        labelGeo.firstMaterial?.emission.contents = NSColor.systemCyan.withAlphaComponent(0.22)
        let labelNode = SCNNode(geometry: labelGeo)
        labelNode.simdPosition = SIMD3<Float>(-0.18, 0.10, 0)
        labelNode.scale = SCNVector3(0.009, 0.009, 0.009)
        root.addChildNode(labelNode)

        return root
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
