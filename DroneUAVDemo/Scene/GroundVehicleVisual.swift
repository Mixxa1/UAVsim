import AppKit
import SceneKit
import simd

/// The transport USDZ assets use baked mesh coordinates and face +Z. Physics faces -Z.
/// Wheel meshes are reparented around their axle centres before they are articulated.
final class GroundVehicleVisual {
    let rootNode = SCNNode()
    private let contactShadows = GroundVehicleContactShadows()
    private var wheels: [GroundVehiclePart: SCNNode] = [:]
    private var wheelSpins: [GroundVehiclePart: SCNNode] = [:]
    private let content: SCNNode
    private var axleCentres: [GroundVehiclePart: SIMD3<Float>] = [:]
    private var suspensionPitch: Float = 0
    private var suspensionRoll: Float = 0
    private var lastUpdateTime: TimeInterval = 0
    private struct BodyworkMesh {
        let node: SCNNode
        let rest: SCNGeometry
        let toBody: simd_float4x4
        let glass: Bool
    }
    private var bodywork: [BodyworkMesh] = []
    private var bodyworkSignature: [Int] = []
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
        rootNode.addChildNode(contactShadows.node)
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
            node.castsShadow = true
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
                node.geometry?.materials.forEach { $0.multiply.contents = NSColor.white }
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
            let shed = ["door-", "hood", "mirror-", "FrontFender_", "FrontBumper_"].contains(where: name.hasPrefix)
            let glass = group.allSatisfy { $0.name?.contains("Glass") == true || $0.name?.hasPrefix("Windshield_") == true }
            panels.append(Panel(node: pivot, meshes: group, centre: physicsCentre, halfSize: (high - low) * 0.5, restPosition: centre,
                                canShed: shed, isGlass: glass))
            for mesh in group {
                let name = mesh.name ?? ""
                let isGlass = name.hasPrefix("Windshield_") || name.hasPrefix("SideWindow_") || name.contains("Glass_")
                let isSkin = isGlass || ["CabUpper", "CabLower", "CabRoof", "DoorPanel", "Bonnet_", "Fender",
                    "Mudguard", "Toolbox", "FrontBumper", "BedSide", "Tailgate"].contains(where: name.contains)
                if isSkin, let geometry = mesh.geometry {
                    let facing = simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)))
                    bodywork.append(BodyworkMesh(node: mesh, rest: geometry,
                        toBody: facing * content.simdConvertTransform(mesh.simdTransform, from: mesh.parent), glass: isGlass))
                }
            }
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
        updateBodywork(runtime.damage.sites)
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
                torn = torn || (site.tearsPanels && distance < 0.65 && site.severity > 0.97)
            }
            if let firePoint = runtime.damage.firePoint {
                let distance = simd_length(simd_max(abs(firePoint - panel.centre) - panel.halfSize, .zero))
                soot = max(soot, min(1, Float(runtime.burnAge / 32)) * max(0, 1 - distance / 4.2))
            }
            if dent > panel.damage + 0.02 {
                panel.damage = dent
                if !panel.meshes.contains(where: { $0.geometry?.name?.hasPrefix("bodywork.deformed") == true }) {
                let outward = SIMD3<Float>(panel.centre.x < 0 ? -1 : 1, 0, panel.centre.z < 0 ? -1 : 1)
                // Bend around the panel's own centre, never the baked model's origin.
                let offset = outward * dent * 0.16
                panel.node.simdPosition = panel.restPosition + SIMD3<Float>(offset.x, -dent * 0.10, offset.z)
                panel.node.simdOrientation = simd_quatf(angle: dent * (panel.centre.x < 0 ? -0.20 : 0.20),
                    axis: SIMD3<Float>(0, 0, 1))
                panel.node.simdScale = SIMD3<Float>(1, 1 - dent * 0.14, 1 - dent * 0.06)
                }
                // Glass loses local triangles instead of vanishing as a whole pane.
            }
            if soot > panel.soot + 0.025 || panel.damage > panel.tintDamage + 0.02 {
                panel.soot = max(panel.soot, soot)
                panel.tintDamage = panel.damage
                let grey = CGFloat(max(0.10, 1 - panel.soot * 0.85 - panel.damage * 0.12))
                for mesh in panel.meshes {
                    for material in mesh.geometry?.materials ?? [] {
                        let shade = material.name == "bodywork.bare-metal" ? CGFloat(max(0.55, 1 - panel.soot * 0.4)) : grey
                        material.multiply.contents = NSColor(calibratedRed: shade, green: shade * 0.96, blue: shade * 0.92, alpha: 1)
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

    private func updateBodywork(_ sites: [GroundVehicleDamageSite]) {
        let signature = sites.flatMap { [Int(($0.severity * 100).rounded()), $0.tearsPanels ? 1 : 0] }
        guard signature != bodyworkSignature else { return }
        bodyworkSignature = signature
        var triangleBudget = 16_000
        for mesh in bodywork {
            guard !mesh.node.isHidden, triangleBudget > 0 else { continue }
            if let geometry = VehicleBodyworkDeformation.deform(mesh.rest, toBody: mesh.toBody,
                sites: sites, glass: mesh.glass, triangleBudget: &triangleBudget) {
                mesh.node.geometry = geometry
            }
        }
    }

    func updateGroundContact(_ runtime: GroundVehicleRuntime, ground: (SIMD3<Float>, Float) -> Float) {
        contactShadows.update(runtime, ground: ground)
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

/// Terrain-fitted contact occlusion complements the scene's actual sun shadow. It disappears
/// when the wheels lose support, and remains a compact pose delta in a replay.
final class GroundVehicleContactShadows {
    let node = SCNNode()
    private var shadows: [SCNNode] = []
    init() {
        node.name = "vehicle.contact-shadows"
        for i in 0..<7 {
            let plane = SCNPlane(width: i == 0 ? 2.5 : 0.7, height: i == 0 ? 7.6 : 0.8)
            let material = SCNMaterial(); material.diffuse.contents = GroundVehicleSurfaceTextures.shadow
            material.lightingModel = .constant; material.blendMode = .alpha; material.transparencyMode = .aOne
            material.readsFromDepthBuffer = true; material.writesToDepthBuffer = false; material.isDoubleSided = true
            plane.firstMaterial = material
            let shadow = SCNNode(geometry: plane); shadow.name = "vehicle.contact-shadow.\(i)"
            shadow.castsShadow = false; shadow.isHidden = true
            node.addChildNode(shadow); shadows.append(shadow)
        }
    }
    func update(_ road: GroundVehicleRuntime, ground: (SIMD3<Float>, Float) -> Float) {
        let wheels = GroundVehiclePart.allCases.filter(\.isWheel)
        for (i, shadow) in shadows.enumerated() {
            let offset = i == 0 ? SIMD3<Float>.zero : wheels[i - 1].position(in: road.profile)
            let p = road.state.position + simd_act(road.state.attitudeQuat, offset)
            let height = ground(p + SIMD3<Float>(0, 0.1, 0), 0.15)
            let gap = i == 0 ? road.state.position.y - height : p.y - road.profile.wheelRadius - height
            let missingWheel = i > 0 && (road.damage.condition(wheels[i - 1]) < 0.12 || road.damage.rolledOver)
            guard height.isFinite, gap < 1.2, !missingWheel else { shadow.isHidden = true; continue }
            let x0 = ground(p + SIMD3<Float>(-0.3, 0.3, 0), 0.1), x1 = ground(p + SIMD3<Float>(0.3, 0.3, 0), 0.1)
            let z0 = ground(p + SIMD3<Float>(0, 0.3, -0.3), 0.1), z1 = ground(p + SIMD3<Float>(0, 0.3, 0.3), 0.1)
            let normal = [x0, x1, z0, z1].allSatisfy(\.isFinite)
                ? simd_normalize(SIMD3<Float>((x0 - x1) / 0.6, 1, (z0 - z1) / 0.6)) : SIMD3<Float>(0, 1, 0)
            let yaw = road.state.orientation.z
            shadow.simdWorldPosition = SIMD3<Float>(p.x, height + 0.022, p.z)
            shadow.simdWorldOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: normal)
                * simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
                * simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            shadow.opacity = CGFloat((i == 0 ? 0.18 : 0.36) * max(0, 1 - max(0, gap) / 1.2))
            shadow.isHidden = false
        }
    }
}

/// One bounded ribbon mesh, rebuilt only on a new tyre sample. Four projected corners are
/// recorded directly, so playback needs neither wheel physics nor terrain raycasts.
final class GroundVehicleTrackVisuals {
    let node = SCNNode()
    private(set) var samples: [MissionReplayWheelTrack] = []
    private var last: [String: (point: SIMD3<Float>, roll: Double)] = [:]
    private var renderedIDs: [UUID] = []
    init() { node.name = "vehicle.tyre-tracks"; node.castsShadow = false }
    func clear() { samples.removeAll(); last.removeAll(); renderedIDs.removeAll(); node.geometry = nil }
    func record(_ road: GroundVehicleRuntime, ground: (SIMD3<Float>, Float) -> Float) {
        var changed = false
        let forward = simd_act(road.state.attitudeQuat, SIMD3<Float>(0, 0, -1))
        let sideways = simd_length(road.state.velocity - forward * simd_dot(road.state.velocity, forward))
        for part in GroundVehiclePart.allCases where part.isWheel {
            let key = "\(road.vehicleID)/\(part.rawValue)"
            let p = road.state.position + simd_act(road.state.attitudeQuat, part.position(in: road.profile))
            let y = ground(p + SIMD3<Float>(0, 0.1, 0), 0.15)
            guard y.isFinite, !road.damage.rolledOver, road.damage.condition(part) >= 0.12,
                  abs(p.y - road.profile.wheelRadius - y) < 0.3 else { last.removeValue(forKey: key); continue }
            let point = SIMD3<Float>(p.x, y + 0.025, p.z)
            guard let previous = last[key] else { last[key] = (point, road.wheelRoll); continue }
            let planarDistance = simd_distance(SIMD2<Float>(point.x, point.z), SIMD2<Float>(previous.point.x, previous.point.z))
            let distance = simd_distance(previous.point, point)
            if distance > 3 { last[key] = (point, road.wheelRoll); continue } // teleport/gap, never a connecting streak
            guard planarDistance >= 0.35 else { continue }
            let rollDistance = Float(abs(road.wheelRoll - previous.roll)) * road.profile.wheelRadius
            let slip = min(1, abs(rollDistance - distance) / max(0.15, distance) + sideways / 8)
            let direction = simd_normalize(point - previous.point)
            let right = simd_normalize(simd_cross(direction, SIMD3<Float>(0, 1, 0))) * 0.145
            var corners = [previous.point - right, previous.point + right, point - right, point + right]
            var valid = true
            for i in corners.indices {
                let h = ground(corners[i] + SIMD3<Float>(0, 0.3, 0), 0.08)
                if !h.isFinite { valid = false; break }
                corners[i].y = h + 0.025
            }
            if valid {
                samples.append(MissionReplayWheelTrack(id: UUID(), corners: corners, length: distance, opacity: 0.12 + slip * 0.25))
                changed = true
            }
            last[key] = (point, road.wheelRoll)
        }
        if samples.count > 768 { samples.removeFirst(samples.count - 768) }
        if changed { update(samples) }
    }
    func update(_ values: [MissionReplayWheelTrack]) {
        let ids = values.map(\.id)
        guard ids != renderedIDs else { return }
        renderedIDs = ids
        guard !values.isEmpty else { node.geometry = nil; return }
        var vertices: [SCNVector3] = [], uv: [CGPoint] = []
        var indices = [[UInt32](), [UInt32]()]
        for value in values where value.corners.count == 4 {
            let base = UInt32(vertices.count)
            vertices += value.corners.map { SCNVector3($0) }
            uv += [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: CGFloat(value.length * 4)), CGPoint(x: 1, y: CGFloat(value.length * 4))]
            indices[value.opacity > 0.25 ? 1 : 0] += [base, base + 2, base + 1, base + 1, base + 2, base + 3]
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uv)],
            elements: indices.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) })
        geometry.materials = [CGFloat(0.15), 0.34].map { opacity in
            let material = SCNMaterial(); material.diffuse.contents = GroundVehicleSurfaceTextures.tread
            material.diffuse.wrapT = .repeat; material.diffuse.wrapS = .clamp
            material.lightingModel = .constant; material.blendMode = .alpha; material.transparencyMode = .aOne
            material.transparency = opacity; material.readsFromDepthBuffer = true; material.writesToDepthBuffer = false
            material.isDoubleSided = true
            return material
        }
        node.geometry = geometry
    }
}

private enum GroundVehicleSurfaceTextures {
    static let shadow = image(width: 64, height: 128, tread: false)
    static let tread = image(width: 32, height: 64, tread: true)
    private static func image(width: Int, height: Int, tread: Bool) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let u = Float(x) / Float(width - 1) * 2 - 1, v = Float(y) / Float(height - 1) * 2 - 1
            let alpha: Float
            if tread {
                let edge = max(0, 1 - pow(abs(u), 6))
                let tooth = (y + Int(abs(u) * 8)) % 12 < 6 ? Float(0.75) : 0.25
                alpha = edge * tooth
            } else { alpha = pow(max(0, 1 - u * u - v * v), 2) }
            pixels[(y * width + x) * 4 + 3] = UInt8(min(255, max(0, alpha * 255)))
        } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}

/// A local, bounded mesh operation on authored bodywork, not an overlay or a whole-panel
/// scale. Subdivision preserves UVs; holes remove triangles, with folded bare metal at the rim.
/// Rebuilt from the rest mesh only when damage changes, never at rendering cadence.
enum VehicleBodyworkDeformation {
    private struct Vertex {
        let p: SIMD3<Float>
        let uv: SIMD2<Float>
        func midpoint(_ other: Vertex) -> Vertex { Vertex(p: (p + other.p) * 0.5, uv: (uv + other.uv) * 0.5) }
    }
    private struct Hit {
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
        let severity: Float
        let radius: Float
        let opens: Bool
        func sample(_ p: SIMD3<Float>) -> (distance: Float, radius: Float, angle: Float, depth: Float) {
            let delta = p - point, depth = simd_dot(delta, normal)
            let u = simd_normalize(simd_cross(normal, abs(normal.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)))
            let v = simd_cross(normal, u)
            let x = simd_dot(delta, u), y = simd_dot(delta, v)
            let angle = atan2(y, x)
            let jag = 1 + 0.12 * sin(angle * 7 + point.x * 3) + 0.08 * sin(angle * 13 + point.z * 5)
            return (sqrt(x * x + y * y), radius * jag, angle, depth)
        }
    }

    static func deform(_ source: SCNGeometry, toBody: simd_float4x4,
                       sites: [GroundVehicleDamageSite], glass: Bool,
                       triangleBudget: inout Int, exposedMaterial: SCNMaterial? = nil) -> SCNGeometry? {
        guard !sites.isEmpty, triangleBudget > 0,
              let positions = source.sources(for: .vertex).first,
              positions.usesFloatComponents, positions.bytesPerComponent == 4,
              positions.componentsPerVector >= 3, positions.vectorCount <= 30_000,
              source.elements.allSatisfy({ $0.primitiveType == .triangles }) else { return nil }
        func component(_ s: SCNGeometrySource, _ i: Int, _ c: Int) -> Float {
            let offset = s.dataOffset + i * s.dataStride + c * s.bytesPerComponent
            guard offset >= 0, offset + 4 <= s.data.count else { return 0 }
            return s.data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
        }
        let tex = source.sources(for: .texcoord).first
        // SceneKit's parametric meshes can expose unit-sized source vertices even when the
        // displayed box/cylinder has other dimensions. Bake those before making generic mesh.
        var rawLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude), rawHigh = -rawLow
        for i in 0..<positions.vectorCount {
            let p = SIMD3<Float>(component(positions, i, 0), component(positions, i, 1), component(positions, i, 2))
            rawLow = simd_min(rawLow, p); rawHigh = simd_max(rawHigh, p)
        }
        var dimensions: SIMD3<Float>?
        if let box = source as? SCNBox { dimensions = SIMD3<Float>(Float(box.width), Float(box.height), Float(box.length)) }
        if let cylinder = source as? SCNCylinder {
            dimensions = SIMD3<Float>(Float(cylinder.radius * 2), Float(cylinder.height), Float(cylinder.radius * 2))
        }
        let rawSize = rawHigh - rawLow
        let bake = dimensions.map { simd_max($0, SIMD3<Float>(repeating: 0.0001)) / simd_max(rawSize, SIMD3<Float>(repeating: 0.0001)) }
        var vertices: [Vertex] = [], low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for i in 0..<positions.vectorCount {
            var local = SIMD3<Float>(component(positions, i, 0), component(positions, i, 1), component(positions, i, 2))
            if let bake { local = (local - (rawLow + rawHigh) * 0.5) * bake }
            let q = toBody * SIMD4<Float>(local, 1), p = SIMD3<Float>(q.x, q.y, q.z)
            guard p.x.isFinite && p.y.isFinite && p.z.isFinite else { return nil }
            let uv = tex.map { $0.bytesPerComponent == 4 && $0.vectorCount > i
                ? SIMD2<Float>(component($0, i, 0), component($0, i, 1)) : .zero } ?? .zero
            vertices.append(Vertex(p: p, uv: uv)); low = simd_min(low, p); high = simd_max(high, p)
        }
        guard !vertices.isEmpty else { return nil }
        let centre = (low + high) * 0.5
        let hits: [Hit] = sites.compactMap { site in
            let outside = simd_length(simd_max(abs(site.point - centre) - (high - low) * 0.5, .zero))
            guard outside < 1.1, site.severity > 0.08 else { return nil }
            let candidate = site.normal ?? (site.point - centre)
            let normal = simd_length_squared(candidate) > 0.0001 && candidate.x.isFinite && candidate.y.isFinite && candidate.z.isFinite
                ? simd_normalize(candidate) : SIMD3<Float>(0, 1, 0)
            return Hit(point: site.point, normal: normal, severity: site.severity,
                radius: glass ? 0.08 + site.severity * 0.32 : 0.08 + site.severity * 0.42,
                opens: glass ? site.severity > 0.4 : site.tearsPanels && site.severity > 0.55)
        }
        guard !hits.isEmpty else { return nil }
        let inverse = toBody.inverse
        var points: [SCNVector3] = [], normals: [SCNVector3] = [], uv: [CGPoint] = []
        var indices = Array(repeating: [UInt32](), count: max(1, source.elements.count) + 1)
        var removed = 0, changed = false, terminals = 0
        let maxTriangles = min(4_000, triangleBudget)
        func displaced(_ p: SIMD3<Float>) -> SIMD3<Float> {
            var result = p
            for hit in hits {
                let s = hit.sample(p)
                guard abs(s.depth) < 0.35 else { continue }
                let influence = max(0, 1 - s.distance / (hit.radius + 0.7))
                result -= hit.normal * influence * influence * hit.severity * (glass ? 0.012 : 0.22)
                if hit.opens && !glass {
                    let rim = max(0, 1 - abs(s.distance - s.radius * 1.12) / 0.18)
                    result += hit.normal * rim * hit.severity * (0.12 + 0.10 * sin(s.angle * 9))
                }
            }
            return result
        }
        func emit(_ a: Vertex, _ b: Vertex, _ c: Vertex, slot: Int) {
            terminals += 1
            let mid = (a.p + b.p + c.p) / 3
            var rim = false
            for hit in hits {
                let s = hit.sample(mid)
                guard abs(s.depth) < 0.26 else { continue }
                if hit.opens && s.distance < s.radius { removed += 1; changed = true; return }
                rim = rim || (hit.opens && abs(s.distance - s.radius) < 0.075)
                if glass && s.distance < hit.radius * 2.4 && abs(sin(s.angle * 7)) < 0.10 { rim = true }
            }
            let original = [a, b, c]
            let local: [SIMD3<Float>] = original.map {
                let p = displaced($0.p)
                if simd_distance(p, $0.p) > 0.001 { changed = true }
                let v = inverse * SIMD4<Float>(p, 1); return SIMD3<Float>(v.x, v.y, v.z)
            }
            let cross = simd_cross(local[1] - local[0], local[2] - local[0])
            guard simd_length_squared(cross) > 1e-12 else { return }
            let normal = SCNVector3(simd_normalize(cross)), base = UInt32(points.count)
            points += local.map { SCNVector3($0) }; normals += [normal, normal, normal]
            uv += original.map { CGPoint(x: CGFloat($0.uv.x), y: CGFloat($0.uv.y)) }
            let destination = rim ? indices.count - 1 : slot
            indices[destination] += [base, base + 1, base + 2]
        }
        func subdivide(_ a: Vertex, _ b: Vertex, _ c: Vertex, slot: Int, depth: Int) {
            let l = simd_min(a.p, simd_min(b.p, c.p)), h = simd_max(a.p, simd_max(b.p, c.p))
            let near = hits.contains {
                simd_length(simd_max(abs($0.point - (l + h) * 0.5) - (h - l) * 0.5, .zero)) < $0.radius + 0.65
            }
            let ab = simd_distance(a.p, b.p), bc = simd_distance(b.p, c.p), ca = simd_distance(c.p, a.p)
            if near && depth < 7 && max(ab, max(bc, ca)) > 0.18 && terminals + 2 < maxTriangles {
                if ab >= bc && ab >= ca {
                    let m = a.midpoint(b); subdivide(a, m, c, slot: slot, depth: depth + 1); subdivide(m, b, c, slot: slot, depth: depth + 1)
                } else if bc >= ca {
                    let m = b.midpoint(c); subdivide(a, b, m, slot: slot, depth: depth + 1); subdivide(a, m, c, slot: slot, depth: depth + 1)
                } else {
                    let m = c.midpoint(a); subdivide(a, b, m, slot: slot, depth: depth + 1); subdivide(m, b, c, slot: slot, depth: depth + 1)
                }
            } else { emit(a, b, c, slot: slot) }
        }
        for (slot, element) in source.elements.enumerated() {
            guard [1, 2, 4].contains(element.bytesPerIndex),
                  element.data.count >= element.primitiveCount * 3 * element.bytesPerIndex else { return nil }
            element.data.withUnsafeBytes { data in
                func index(_ n: Int) -> Int {
                    let offset = n * element.bytesPerIndex
                    switch element.bytesPerIndex {
                    case 1: return Int(data.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    case 2: return Int(data.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    default: return Int(data.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    }
                }
                for t in 0..<element.primitiveCount {
                    let a = index(t * 3), b = index(t * 3 + 1), c = index(t * 3 + 2)
                    if max(a, max(b, c)) < vertices.count {
                        subdivide(vertices[a], vertices[b], vertices[c], slot: slot, depth: 0)
                    }
                }
            }
        }
        guard changed else { return nil }
        triangleBudget -= min(triangleBudget, terminals)
        let elements = indices.map { SCNGeometryElement(indices: $0, primitiveType: .triangles) }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: points), SCNGeometrySource(normals: normals),
            SCNGeometrySource(textureCoordinates: uv)], elements: elements)
        var materials = source.elements.indices.map { index -> SCNMaterial in
            let material = source.materials.isEmpty ? SCNMaterial() : source.materials[index % source.materials.count].copy() as! SCNMaterial
            material.isDoubleSided = true
            return material
        }
        let rim = exposedMaterial ?? SCNMaterial(); rim.name = exposedMaterial?.name ?? (glass ? "bodywork.fractured-glass" : "bodywork.bare-metal")
        if exposedMaterial == nil {
        rim.diffuse.contents = glass ? NSColor(calibratedWhite: 0.7, alpha: 0.55) : NSColor(calibratedWhite: 0.55, alpha: 1)
        rim.metalness.contents = glass ? 0 : 0.65; rim.roughness.contents = 0.7; rim.isDoubleSided = true
        rim.lightingModel = source.materials.first?.lightingModel ?? .physicallyBased
        }
        materials.append(rim); geometry.materials = materials
        geometry.name = "bodywork.deformed.cut-\(removed)"
        return geometry
    }
}
