import AppKit
import SceneKit
import simd

/// The transport USDZ assets use baked mesh coordinates and face +Z. Physics faces -Z.
/// Wheel meshes are reparented around their axle centres before they are articulated.
final class GroundVehicleVisual {
    let rootNode = SCNNode()
    private var wheels: [GroundVehiclePart: SCNNode] = [:]
    private var wheelSpins: [GroundVehiclePart: SCNNode] = [:]
    private let content: SCNNode
    private var axleCentres: [GroundVehiclePart: SIMD3<Float>] = [:]
    private var suspensionPitch: Float = 0
    private var suspensionRoll: Float = 0
    private var lastUpdateTime: TimeInterval = 0
    private struct Panel {
        let node: SCNNode
        let meshes: [SCNNode]
        let centre: SIMD3<Float>
        let halfSize: SIMD3<Float>
        let restPosition: SIMD3<Float>
        let canShed: Bool
        let isGlass: Bool
        var damage: Float = 0
        var soot: Float = 0
        var tintDamage: Float = 0
        var separated = false
    }
    private var panels: [Panel] = []
    private var detached: Set<GroundVehiclePart> = []
    private static var templates: [GroundVehicleModel: SCNNode] = [:]

    init(model: GroundVehicleModel, directory: URL? = nil) {
        rootNode.name = "ground-vehicle"
        content = Self.load(model: model, directory: directory)
        content.eulerAngles.y = .pi
        rootNode.addChildNode(content)
        let nativeCentres = [SIMD3<Float>(-1.15, 0.642, -3.1), SIMD3<Float>(1.15, 0.642, -3.1),
                             SIMD3<Float>(-1.15, 0.642, -1.6), SIMD3<Float>(1.15, 0.642, -1.6),
                             SIMD3<Float>(-1.15, 0.642, 3.1), SIMD3<Float>(1.15, 0.642, 3.1)]
        let parts: [GroundVehiclePart] = [.wheelRearRight, .wheelRearLeft, .wheelMiddleRight,
                                        .wheelMiddleLeft, .wheelFrontRight, .wheelFrontLeft]
        var meshes: [SCNNode] = []
        content.enumerateChildNodes { node, _ in if node.geometry != nil { meshes.append(node) } }
        for (index, centre) in nativeCentres.enumerated() {
            let mount = SCNNode(), spin = SCNNode()
            mount.name = "wheel-mount-\(parts[index].rawValue)"
            spin.name = parts[index].rawValue
            mount.simdPosition = centre
            content.addChildNode(mount); mount.addChildNode(spin)
            wheels[parts[index]] = mount; wheelSpins[parts[index]] = spin
            axleCentres[parts[index]] = centre
        }
        var bodyGroups: [String: [SCNNode]] = [:]
        for node in meshes {
            guard let name = node.name else { continue }
            node.setValue(NSMutableDictionary(dictionary: ["thermalClass": name.contains("Glass") || name.contains("Window") ? "glass" : "metal"]), forKey: "userData")
            // The nuts have separate meshes, so grouping by nearest axle also animates them.
            if name.hasPrefix("Tyre_") || name.hasPrefix("WheelHub_") || name.hasPrefix("WheelRim_") || name.hasPrefix("WheelNut_") || name.hasPrefix("TreadBlock_") {
                let bounds = node.boundingBox
                let centre = content.simdConvertPosition((SIMD3<Float>(bounds.min) + SIMD3<Float>(bounds.max)) * 0.5, from: node)
                let nearest = nativeCentres.indices.min { simd_distance(nativeCentres[$0], centre) < simd_distance(nativeCentres[$1], centre) }!
                let old = content.simdConvertTransform(node.simdTransform, from: node.parent)
                node.removeFromParentNode()
                wheelSpins[parts[nearest]]?.addChildNode(node)
                var local = old; local.columns.3 -= SIMD4<Float>(nativeCentres[nearest], 0)
                node.simdTransform = local
            } else {
                let centre = content.simdConvertPosition((SIMD3<Float>(node.boundingBox.min) + SIMD3<Float>(node.boundingBox.max)) * 0.5, from: node)
                let side = centre.x < 0 ? "right" : "left"
                let group: String
                if ["Door", "SideWindow"].contains(where: name.hasPrefix) { group = "door-\(side)" }
                else if ["Bonnet", "Hood"].contains(where: name.hasPrefix) { group = "hood" }
                else if name.hasPrefix("Mirror") { group = "mirror-\(side)" }
                else { group = name }
                bodyGroups[group, default: []].append(node)
            }
        }
        for name in bodyGroups.keys.sorted() {
            let group = bodyGroups[name]!
            var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
            for node in group {
                let bounds = node.boundingBox
                for x in [bounds.min.x, bounds.max.x] {
                    for y in [bounds.min.y, bounds.max.y] {
                        for z in [bounds.min.z, bounds.max.z] {
                            let point = content.simdConvertPosition(SIMD3<Float>(Float(x), Float(y), Float(z)), from: node)
                            low = simd_min(low, point); high = simd_max(high, point)
                        }
                    }
                }
                // USDZ clones share their materials. Isolate this car before any damage tint.
                node.geometry = node.geometry?.copy() as? SCNGeometry
                node.geometry?.materials = node.geometry?.materials.map { $0.copy() as! SCNMaterial } ?? []
            }
            let centre = (low + high) * 0.5
            let pivot = SCNNode()
            pivot.name = "panel-\(name)"; pivot.simdPosition = centre
            content.addChildNode(pivot)
            for node in group {
                var transform = content.simdConvertTransform(node.simdTransform, from: node.parent)
                transform.columns.3 -= SIMD4<Float>(centre, 0)
                node.removeFromParentNode(); pivot.addChildNode(node); node.simdTransform = transform
            }
            let physicsCentre = SIMD3<Float>(-centre.x, centre.y, -centre.z)
            let shed = ["door-", "hood", "mirror-", "FrontFender_", "FrontBumper_", "CabRoof_"].contains(where: name.hasPrefix)
            let glass = group.allSatisfy { $0.name?.contains("Glass") == true || $0.name?.hasPrefix("Windshield_") == true }
            panels.append(Panel(node: pivot, meshes: group, centre: physicsCentre, halfSize: (high - low) * 0.5, restPosition: centre,
                                canShed: shed, isGlass: glass))
        }
    }

    /// Returns newly separated wheels and panels in world coordinates; the ballistic runtime owns
    /// their motion from this point, and the recorder captures those same pieces.
    func update(_ runtime: GroundVehicleRuntime) -> [SCNNode] {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        rootNode.simdPosition = runtime.state.position
        rootNode.simdOrientation = runtime.state.attitudeQuat
        // A broken front axle cannot leave the cab hanging at its undamaged ride height.
        // Bend the suspended chassis about the surviving axle; wheels retain their road pose.
        let dt = Float(min(0.1, max(0, runtime.worldTime - lastUpdateTime)))
        lastUpdateTime = runtime.worldTime
        func missing(_ parts: [GroundVehiclePart]) -> Float {
            Float(parts.filter { runtime.damage.condition($0) < 0.12 }.count)
        }
        let front = missing([.wheelFrontLeft, .wheelFrontRight]), rear = missing([.wheelRearLeft, .wheelRearRight])
        let left = missing([.wheelFrontLeft, .wheelMiddleLeft, .wheelRearLeft])
        let right = missing([.wheelFrontRight, .wheelMiddleRight, .wheelRearRight])
        let pitch = (rear - front) * 0.045, roll = (left - right) * 0.02
        suspensionPitch += max(-dt * 0.3, min(dt * 0.3, pitch - suspensionPitch))
        suspensionRoll += max(-dt * 0.3, min(dt * 0.3, roll - suspensionRoll))
        let lean = simd_quatf(angle: suspensionPitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: suspensionRoll, axis: SIMD3<Float>(0, 0, 1))
        let pivot = SIMD3<Float>(left > right ? 1.15 : -1.15, 0, front >= rear ? 3.1 : -3.1)
        var stance = simd_float4x4(lean)
        stance.columns.3 = SIMD4<Float>(pivot - simd_act(lean, pivot), 1)
        let facing = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
        content.simdTransform = stance * facing
        var pieces: [SCNNode] = []
        for (part, mount) in wheels {
            guard !detached.contains(part) else { continue }
            let integrity = runtime.damage.condition(part)
            var axle = matrix_identity_float4x4
            axle.columns.3 = SIMD4<Float>(axleCentres[part]!, 1)
            let steering = part == .wheelFrontLeft || part == .wheelFrontRight ? runtime.steering : 0
            let wobble = sin(runtime.wheelAngle) * (1 - integrity) * 0.10
            let articulation = simd_float4x4(simd_quatf(angle: steering, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: wobble, axis: SIMD3<Float>(0, 0, 1)))
            mount.simdTransform = content.simdTransform.inverse * facing * axle * articulation
            // +X rolls a native +Z-facing wheel forward. The content's half turn then maps
            // both the wheel and the vehicle into the simulation's -Z forward direction.
            wheelSpins[part]?.eulerAngles.x = CGFloat(runtime.wheelAngle)
            wheelSpins[part]?.setValue(NSMutableDictionary(dictionary: ["wheelRoll": runtime.wheelRoll]), forKey: "userData")
            mount.scale.y = CGFloat(0.86 + 0.14 * integrity)
            if integrity < 0.12, detached.insert(part).inserted {
                let copy = mount.clone(); copy.simdTransform = mount.simdWorldTransform
                copy.setValue(NSMutableDictionary(dictionary: ["debrisMass": runtime.profile.massKg * part.massFraction]), forKey: "userData")
                pieces.append(copy); mount.isHidden = true
            }
        }
        for index in panels.indices {
            var panel = panels[index]
            guard !panel.separated else { continue }
            var dent: Float = 0, soot: Float = 0
            var torn = false
            for site in runtime.damage.sites {
                let distance = simd_length(simd_max(abs(site.point - panel.centre) - panel.halfSize, .zero))
                let influence = max(0, 1 - distance / 2.3)
                dent = max(dent, site.severity * influence)
                soot = max(soot, site.heat * max(0, 1 - distance / 3.6))
                torn = torn || (site.tearsPanels && distance < 1.8 && site.severity > 0.8)
            }
            if let firePoint = runtime.damage.firePoint {
                let distance = simd_length(simd_max(abs(firePoint - panel.centre) - panel.halfSize, .zero))
                soot = max(soot, min(1, Float(runtime.burnAge / 32)) * max(0, 1 - distance / 4.2))
            }
            if dent > panel.damage + 0.02 {
                panel.damage = dent
                let outward = SIMD3<Float>(panel.centre.x < 0 ? -1 : 1, 0, panel.centre.z < 0 ? -1 : 1)
                // Bend around the panel's own centre, never the baked model's origin.
                let offset = outward * dent * 0.16
                panel.node.simdPosition = panel.restPosition + SIMD3<Float>(offset.x, -dent * 0.10, offset.z)
                panel.node.simdOrientation = simd_quatf(angle: dent * (panel.centre.x < 0 ? -0.20 : 0.20),
                    axis: SIMD3<Float>(0, 0, 1))
                panel.node.simdScale = SIMD3<Float>(1, 1 - dent * 0.14, 1 - dent * 0.06)
                if panel.isGlass && dent > 0.65 { panel.node.isHidden = true }
            }
            if soot > panel.soot + 0.025 || panel.damage > panel.tintDamage + 0.02 {
                panel.soot = max(panel.soot, soot)
                panel.tintDamage = panel.damage
                let grey = CGFloat(max(0.10, 1 - panel.soot * 0.85 - panel.damage * 0.12))
                for mesh in panel.meshes {
                    for material in mesh.geometry?.materials ?? [] {
                        material.multiply.contents = NSColor(calibratedRed: grey, green: grey * 0.96, blue: grey * 0.92, alpha: 1)
                    }
                }
            }
            if torn && panel.canShed {
                let copy = panel.node.clone(); copy.simdTransform = panel.node.simdWorldTransform
                copy.setValue(NSMutableDictionary(dictionary: ["debrisMass": panel.node.name?.contains("door-") == true ? 65.0 : 25.0]), forKey: "userData")
                pieces.append(copy); panel.node.isHidden = true; panel.separated = true
            }
            panels[index] = panel
        }
        return pieces
    }

    private static func load(model: GroundVehicleModel, directory: URL?) -> SCNNode {
        if directory == nil, let cached = templates[model] { return cached.clone() }
        let bundle = Bundle.main.resourceURL
        let folders = [directory, bundle?.appendingPathComponent("Vehicles"),
                       bundle?.appendingPathComponent("Models/Vehicles")].compactMap { $0 }
        let url = folders.map { $0.appendingPathComponent(model.rawValue + ".usdz") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let template = SCNNode()
        if let url, let source = SCNSceneSource(url: url, options: nil),
           let scene = source.scene(options: [.animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay]) {
            for child in scene.rootNode.childNodes { template.addChildNode(child) }
        } else {
            // A missing resource remains visibly a ground vehicle, never an aircraft fallback.
            let chassis = SCNNode(geometry: SCNBox(width: 2.3, height: 1, length: 8, chamferRadius: 0.1))
            chassis.simdPosition = SIMD3<Float>(0, 1.4, 0)
            let cab = SCNNode(geometry: SCNBox(width: 2.6, height: 2, length: 2.5, chamferRadius: 0.1))
            cab.simdPosition = SIMD3<Float>(0, 2.2, 2.6)
            template.addChildNode(chassis); template.addChildNode(cab)
        }
        template.enumerateChildNodes { node, _ in node.removeAllAnimations() }
        if directory == nil { templates[model] = template }
        return template.clone()
    }
}
