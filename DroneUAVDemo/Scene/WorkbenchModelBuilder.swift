import AppKit
import SceneKit
import simd

/// Shared 3D factory for the assembled drone and every catalog thumbnail.
/// Built-in parts are deliberately recognizable procedural models; CADNext
/// imports use their exact triangle mesh (or the explicit legacy proxy).
enum WorkbenchModelBuilder {
    static let slotNodePrefix = "workbench.slot."
    static let hotspotNodePrefix = "workbench.hotspot."
    static let frameNodeName = "workbench.frame"

    static func aircraftNode(
        for build: WorkbenchBuild,
        selectedCategory: WorkbenchCategory? = nil,
        showsHotspots: Bool = true
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "workbench.aircraft"
        let frame = build.resolvedFrame

        let frameRoot = frameNode(frame)
        frameRoot.name = frameNodeName
        applySelection(selectedCategory == .frame, to: frameRoot)
        root.addChildNode(frameRoot)

        if let motor = build.spec(for: .motor) {
            for (index, mount) in frame.motorMounts.enumerated() {
                let node = componentNode(motor)
                node.simdPosition = mount + SIMD3<Float>(0, 0.012, 0)
                node.name = "\(slotNodePrefix)motor.\(index)"
                applySelection(selectedCategory == .slot(.motor), to: node)
                root.addChildNode(node)
            }
        }
        if let propeller = build.spec(for: .propeller) {
            for (index, mount) in frame.motorMounts.enumerated() {
                let node = componentNode(propeller)
                node.simdPosition = mount + SIMD3<Float>(0, 0.033, 0)
                node.name = "\(slotNodePrefix)propeller.\(index)"
                node.eulerAngles.y = index.isMultiple(of: 2) ? 0.18 : -0.18
                applySelection(selectedCategory == .slot(.propeller), to: node)
                root.addChildNode(node)
            }
        }

        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard let spec = build.spec(for: kind) else { continue }
            let node = componentNode(spec)
            node.simdPosition = WorkbenchBuildAnalyzer.slotPosition(kind, frame: frame)
            node.name = "\(slotNodePrefix)\(kind.rawValue)"
            applySelection(selectedCategory == .slot(kind), to: node)
            root.addChildNode(node)
        }

        if showsHotspots {
            addHotspots(to: root, build: build, selectedCategory: selectedCategory)
        }
        return root
    }

    static func previewNode(for frame: WorkbenchFrameSpec) -> SCNNode {
        frameNode(WorkbenchFrameSource.library(id: frame.id).resolve())
    }

    static func previewNode(for spec: WorkbenchComponentSpec) -> SCNNode {
        componentNode(spec)
    }

    // MARK: Frame

    static func frameNode(_ frame: WorkbenchResolvedFrame) -> SCNNode {
        let root = SCNNode()
        if let mesh = frame.importedMesh, let geometry = geometry(from: mesh, convertsCADCoordinates: true) {
            geometry.materials = [material("#7E8895", metalness: 0.45, roughness: 0.38)]
            root.addChildNode(SCNNode(geometry: geometry))
            return root
        }

        let carbon = material("#252A30", metalness: 0.16, roughness: 0.50)
        let edge = material("#69727C", metalness: 0.42, roughness: 0.36)
        let plate = SCNBox(width: 0.062, height: 0.006, length: 0.072, chamferRadius: 0.006)
        plate.materials = [carbon]
        root.addChildNode(SCNNode(geometry: plate))
        let top = SCNBox(width: 0.048, height: 0.004, length: 0.058, chamferRadius: 0.004)
        top.materials = [edge]
        let topNode = SCNNode(geometry: top)
        topNode.simdPosition.y = 0.012
        root.addChildNode(topNode)

        for mount in frame.motorMounts {
            root.addChildNode(beamNode(from: SIMD3<Float>(0, 0, 0), to: mount,
                                       radius: max(0.0045, Float(frame.armLengthM) * 0.045),
                                       material: carbon))
            let pad = SCNCylinder(radius: max(0.011, CGFloat(frame.motorStatorMaxMm / 2000)),
                                  height: 0.004)
            pad.materials = [carbon]
            let padNode = SCNNode(geometry: pad)
            padNode.simdPosition = mount
            root.addChildNode(padNode)
        }

        // Camera cage and battery strap make the silhouette read as a real FPV frame.
        for x: Float in [-0.021, 0.021] {
            let post = SCNCylinder(radius: 0.0018, height: 0.036)
            post.materials = [edge]
            let postNode = SCNNode(geometry: post)
            postNode.simdPosition = SIMD3<Float>(x, 0.018, 0.025)
            root.addChildNode(postNode)
        }
        let strap = SCNBox(width: 0.052, height: 0.002, length: 0.014, chamferRadius: 0.002)
        strap.materials = [material("#48B79B", metalness: 0.05, roughness: 0.55)]
        let strapNode = SCNNode(geometry: strap)
        strapNode.simdPosition = frame.batteryTray + SIMD3<Float>(0, 0.003, 0)
        root.addChildNode(strapNode)
        return root
    }

    // MARK: Components

    static func componentNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        if let mesh = spec.importedMesh,
           let geometry = geometry(from: mesh, convertsCADCoordinates: true) {
            geometry.materials = [material(spec.proxy.colorHex, metalness: 0.35, roughness: 0.38)]
            return SCNNode(geometry: geometry)
        }
        switch spec.kind {
        case .motor: return motorNode(spec)
        case .propeller: return propellerNode(spec)
        case .battery: return batteryNode(spec)
        case .esc: return circuitBoardNode(spec, boardColor: "#252A30", accent: "#D7A43B")
        case .flightController: return circuitBoardNode(spec, boardColor: "#0D5068", accent: "#79D9E8")
        case .receiver: return receiverNode(spec)
        case .camera: return cameraNode(spec)
        case .gps: return gpsNode(spec)
        case .sensor: return sensorNode(spec)
        case .payload: return payloadNode(spec)
        case .landingGear: return landingGearNode(spec)
        case .servo: return servoNode(spec)
        }
    }

    static func motorNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let diameter = CGFloat(spec.proxy.size.x)
        let height = CGFloat(spec.proxy.size.y)
        let base = SCNCylinder(radius: diameter * 0.52, height: max(height * 0.28, 0.004))
        base.materials = [material("#171A1E", metalness: 0.78, roughness: 0.25)]
        root.addChildNode(SCNNode(geometry: base))
        let bell = SCNCylinder(radius: diameter * 0.48, height: max(height * 0.70, 0.008))
        bell.materials = [material(spec.proxy.colorHex, metalness: 0.72, roughness: 0.24)]
        let bellNode = SCNNode(geometry: bell)
        bellNode.simdPosition.y = Float(height * 0.36)
        root.addChildNode(bellNode)
        let cap = SCNCylinder(radius: diameter * 0.34, height: 0.002)
        cap.materials = [material("#8F99A5", metalness: 0.88, roughness: 0.18)]
        let capNode = SCNNode(geometry: cap)
        capNode.simdPosition.y = Float(height * 0.72)
        root.addChildNode(capNode)
        let shaft = SCNCylinder(radius: max(0.0012, diameter * 0.075), height: 0.012)
        shaft.materials = [material("#C9CDD1", metalness: 0.9, roughness: 0.15)]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition.y = Float(height * 0.75 + 0.005)
        root.addChildNode(shaftNode)
        return root
    }

    static func propellerNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let diameterInch = spec.param(WorkbenchComponentSpec.ParamKey.propDiameterInch) ?? 5
        let bladeCount = max(2, Int(spec.param(WorkbenchComponentSpec.ParamKey.propBladeCount) ?? 2))
        let radius = Float(diameterInch) * 0.0254 * 0.5
        let hub = SCNCylinder(radius: CGFloat(max(0.003, radius * 0.075)), height: 0.005)
        hub.materials = [material("#101216", metalness: 0.25, roughness: 0.42)]
        root.addChildNode(SCNNode(geometry: hub))
        for index in 0..<bladeCount {
            let blade = SCNBox(
                width: CGFloat(radius * 0.92), height: 0.0016,
                length: CGFloat(max(radius * 0.16, 0.006)),
                chamferRadius: CGFloat(max(radius * 0.06, 0.0015)))
            blade.materials = [material(spec.proxy.colorHex, metalness: 0.08, roughness: 0.50)]
            let bladeNode = SCNNode(geometry: blade)
            bladeNode.simdPosition.x = radius * 0.48
            bladeNode.eulerAngles.z = 0.07
            let pivot = SCNNode()
            let fullTurn = Float.pi * 2
            let bladeAngle = fullTurn / Float(bladeCount)
            pivot.eulerAngles.y = CGFloat(Float(index) * bladeAngle)
            pivot.addChildNode(bladeNode)
            root.addChildNode(pivot)
        }
        return root
    }

    static func batteryNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.004)
        let s = spec.proxy.size.simdFloat
        for z: Float in [-s.z * 0.28, s.z * 0.28] {
            let strap = SCNBox(width: CGFloat(s.x * 1.04), height: 0.0018,
                               length: CGFloat(max(s.z * 0.13, 0.004)), chamferRadius: 0.001)
            strap.materials = [material("#17191D", metalness: 0.05, roughness: 0.68)]
            let node = SCNNode(geometry: strap)
            node.simdPosition = SIMD3<Float>(0, s.y * 0.52, z)
            root.addChildNode(node)
        }
        let lead = SCNCylinder(radius: 0.0016, height: CGFloat(max(s.z * 0.55, 0.018)))
        lead.materials = [material("#D95050", metalness: 0.05, roughness: 0.48)]
        let leadNode = SCNNode(geometry: lead)
        leadNode.eulerAngles.x = .pi / 2
        leadNode.simdPosition = SIMD3<Float>(s.x * 0.34, s.y * 0.36, -s.z * 0.65)
        root.addChildNode(leadNode)
        return root
    }

    private static func circuitBoardNode(
        _ spec: WorkbenchComponentSpec,
        boardColor: String,
        accent: String
    ) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: boardColor, radius: 0.001)
        let s = spec.proxy.size.simdFloat
        let chip = SCNBox(width: CGFloat(s.x * 0.34), height: 0.003,
                          length: CGFloat(s.z * 0.34), chamferRadius: 0.001)
        chip.materials = [material("#111317", metalness: 0.35, roughness: 0.36)]
        let chipNode = SCNNode(geometry: chip)
        chipNode.simdPosition.y = s.y * 0.62
        root.addChildNode(chipNode)
        for x: Float in [-s.x * 0.34, s.x * 0.34] {
            for z: Float in [-s.z * 0.34, s.z * 0.34] {
                let pad = SCNCylinder(radius: CGFloat(max(min(s.x, s.z) * 0.045, 0.001)), height: 0.001)
                pad.materials = [material(accent, metalness: 0.68, roughness: 0.22)]
                let node = SCNNode(geometry: pad)
                node.simdPosition = SIMD3<Float>(x, s.y * 0.62, z)
                root.addChildNode(node)
            }
        }
        return root
    }

    static func receiverNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.001)
        let s = spec.proxy.size.simdFloat
        for x: Float in [-s.x * 0.32, s.x * 0.32] {
            let antenna = SCNCylinder(radius: 0.00055, height: CGFloat(max(s.z * 1.45, 0.026)))
            antenna.materials = [material("#303338", metalness: 0.12, roughness: 0.55)]
            let node = SCNNode(geometry: antenna)
            node.eulerAngles.x = .pi / 2
            node.eulerAngles.z = x < 0 ? -0.28 : 0.28
            node.simdPosition = SIMD3<Float>(x, 0.002, -s.z * 0.70)
            root.addChildNode(node)
        }
        return root
    }

    static func cameraNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.003)
        let s = spec.proxy.size.simdFloat
        let barrel = SCNCylinder(radius: CGFloat(max(min(s.x, s.y) * 0.28, 0.004)),
                                 height: CGFloat(max(s.z * 0.38, 0.006)))
        barrel.materials = [material("#111419", metalness: 0.55, roughness: 0.28)]
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.eulerAngles.x = .pi / 2
        barrelNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.61)
        root.addChildNode(barrelNode)
        let lens = SCNSphere(radius: CGFloat(max(min(s.x, s.y) * 0.19, 0.003)))
        lens.materials = [glassMaterial()]
        let lensNode = SCNNode(geometry: lens)
        lensNode.simdScale.z = 0.34
        lensNode.simdPosition = SIMD3<Float>(0, 0, s.z * 0.84)
        root.addChildNode(lensNode)
        root.eulerAngles.x = -0.25
        return root
    }

    static func gpsNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root: SCNNode
        if spec.proxy.shape == .cylinder {
            root = proxyNode(spec.proxy)
        } else {
            root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.003)
        }
        let antenna = SCNCylinder(radius: CGFloat(spec.proxy.size.x * 0.32), height: 0.002)
        antenna.materials = [material("#E8DEC2", metalness: 0.18, roughness: 0.38)]
        let node = SCNNode(geometry: antenna)
        node.simdPosition.y = Float(spec.proxy.size.y * 0.56)
        root.addChildNode(node)
        return root
    }

    static func sensorNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.002)
        let s = spec.proxy.size.simdFloat
        for x: Float in [-s.x * 0.22, s.x * 0.22] {
            let eye = SCNSphere(radius: CGFloat(max(s.y * 0.18, 0.002)))
            eye.materials = [glassMaterial()]
            let eyeNode = SCNNode(geometry: eye)
            eyeNode.simdPosition = SIMD3<Float>(x, 0, s.z * 0.52)
            root.addChildNode(eyeNode)
        }
        return root
    }

    static func payloadNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let radius = CGFloat(max(spec.proxy.size.x * 0.50, 0.016))
        let yoke = SCNTorus(ringRadius: radius * 0.82, pipeRadius: max(0.0015, radius * 0.09))
        yoke.materials = [material("#69727D", metalness: 0.48, roughness: 0.34)]
        let yokeNode = SCNNode(geometry: yoke)
        yokeNode.eulerAngles.x = .pi / 2
        root.addChildNode(yokeNode)
        let camera = SCNSphere(radius: radius * 0.62)
        camera.materials = [material(spec.proxy.colorHex, metalness: 0.32, roughness: 0.32)]
        root.addChildNode(SCNNode(geometry: camera))
        let lens = SCNSphere(radius: radius * 0.23)
        lens.materials = [glassMaterial()]
        let lensNode = SCNNode(geometry: lens)
        lensNode.simdPosition.z = Float(radius * 0.56)
        root.addChildNode(lensNode)
        return root
    }

    static func landingGearNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = SCNNode()
        let s = spec.proxy.size.simdFloat
        for x: Float in [-s.x * 0.34, s.x * 0.34] {
            let front = SIMD3<Float>(x, s.y * 0.45, s.z * 0.28)
            let rear = SIMD3<Float>(x, -s.y * 0.28, s.z * 0.34)
            root.addChildNode(beamNode(from: front, to: rear, radius: 0.0023,
                                       material: material(spec.proxy.colorHex)))
            let skid = SCNCapsule(capRadius: 0.0025, height: CGFloat(max(s.z * 0.85, 0.055)))
            skid.materials = [material(spec.proxy.colorHex)]
            let node = SCNNode(geometry: skid)
            node.eulerAngles.x = .pi / 2
            node.simdPosition = SIMD3<Float>(x, -s.y * 0.30, 0)
            root.addChildNode(node)
        }
        return root
    }

    static func servoNode(_ spec: WorkbenchComponentSpec) -> SCNNode {
        let root = roundedBoxNode(spec.proxy.size, color: spec.proxy.colorHex, radius: 0.002)
        let s = spec.proxy.size.simdFloat
        let horn = SCNBox(width: CGFloat(s.x * 1.1), height: 0.0015,
                          length: 0.003, chamferRadius: 0.001)
        horn.materials = [material("#E6E8EA", metalness: 0.10, roughness: 0.40)]
        let node = SCNNode(geometry: horn)
        node.simdPosition.y = s.y * 0.56
        root.addChildNode(node)
        return root
    }

    // MARK: Hotspots

    private static func addHotspots(
        to root: SCNNode,
        build: WorkbenchBuild,
        selectedCategory: WorkbenchCategory?
    ) {
        addHotspot(position: SIMD3<Float>(0, 0.022, 0), key: "frame",
                   selected: selectedCategory == .frame, to: root)
        let frame = build.resolvedFrame
        if build.spec(for: .motor) != nil {
            for (index, position) in frame.motorMounts.enumerated() {
                addHotspot(position: position + SIMD3<Float>(0, 0.018, 0),
                           key: "motor.\(index)", selected: selectedCategory == .slot(.motor), to: root)
            }
        }
        for kind in WorkbenchBuild.slotKinds where kind != .motor && kind != .propeller {
            guard build.spec(for: kind) != nil else { continue }
            addHotspot(position: WorkbenchBuildAnalyzer.slotPosition(kind, frame: frame)
                + SIMD3<Float>(0, 0.018, 0),
                       key: kind.rawValue, selected: selectedCategory == .slot(kind), to: root)
        }
    }

    private static func addHotspot(
        position: SIMD3<Float>, key: String, selected: Bool, to root: SCNNode
    ) {
        let marker = SCNTorus(ringRadius: selected ? 0.0068 : 0.0052,
                              pipeRadius: selected ? 0.00135 : 0.00105)
        let markerMaterial = SCNMaterial()
        let color = selected
            ? NSColor(deviceRed: 0.23, green: 0.59, blue: 0.94, alpha: 1)
            : NSColor(deviceWhite: 0.84, alpha: 0.82)
        markerMaterial.diffuse.contents = color
        markerMaterial.lightingModel = .constant
        marker.materials = [markerMaterial]
        let node = SCNNode(geometry: marker)
        node.name = hotspotNodePrefix + key
        node.simdPosition = position
        node.eulerAngles.x = .pi / 2
        root.addChildNode(node)
    }

    // MARK: Geometry helpers

    static func geometry(
        from mesh: WorkbenchConstruction.Mesh,
        convertsCADCoordinates: Bool
    ) -> SCNGeometry? {
        let count = mesh.vertices.count / 3
        guard count > 0 else { return nil }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(count)
        for index in 0..<count {
            let x = mesh.vertices[index * 3]
            let y = mesh.vertices[index * 3 + 1]
            let z = mesh.vertices[index * 3 + 2]
            vertices.append(convertsCADCoordinates
                ? SCNVector3(x, z, -y)
                : SCNVector3(x, y, z))
        }
        let source = SCNGeometrySource(vertices: vertices)
        let indexData = mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData, primitiveType: .triangles,
            primitiveCount: mesh.indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.stride)
        return SCNGeometry(sources: [source], elements: [element])
    }

    static func material(
        _ hex: String,
        metalness: CGFloat = 0.16,
        roughness: CGFloat = 0.48
    ) -> SCNMaterial {
        let result = SCNMaterial()
        result.diffuse.contents = color(hex: hex) ?? NSColor.gray
        result.lightingModel = .physicallyBased
        result.diffuse.intensity = 1
        result.roughness.contents = NSNumber(value: Double(roughness))
        result.metalness.contents = NSNumber(value: Double(metalness))
        result.isDoubleSided = true
        return result
    }

    static func color(hex: String) -> NSColor? {
        var string = hex.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("#") { string.removeFirst() }
        if string.count == 3 { string = string.map { "\($0)\($0)" }.joined() }
        guard string.count == 6, let value = Int(string, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func glassMaterial() -> SCNMaterial {
        let result = material("#315F82", metalness: 0.22, roughness: 0.16)
        result.specular.contents = NSColor(deviceWhite: 0.92, alpha: 1)
        return result
    }

    private static func roundedBoxNode(
        _ size: CodableVector3D,
        color: String,
        radius: CGFloat
    ) -> SCNNode {
        let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y),
                         length: CGFloat(size.z), chamferRadius: radius)
        box.materials = [material(color, metalness: 0.20, roughness: 0.44)]
        return SCNNode(geometry: box)
    }

    private static func proxyNode(_ proxy: WorkbenchComponentProxy) -> SCNNode {
        let geometry: SCNGeometry
        switch proxy.shape {
        case .box:
            geometry = SCNBox(width: CGFloat(proxy.size.x), height: CGFloat(proxy.size.y),
                              length: CGFloat(proxy.size.z), chamferRadius: 0.002)
        case .cylinder:
            geometry = SCNCylinder(radius: CGFloat(proxy.size.x * 0.5),
                                   height: CGFloat(proxy.size.y))
        case .sphere:
            geometry = SCNSphere(radius: CGFloat(max(proxy.size.x, proxy.size.y, proxy.size.z) * 0.5))
        }
        geometry.materials = [material(proxy.colorHex)]
        return SCNNode(geometry: geometry)
    }

    private static func beamNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }
        let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        cylinder.materials = [material]
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) * 0.5
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        return node
    }

    private static func applySelection(_ selected: Bool, to node: SCNNode) {
        guard selected else { return }
        let tint = NSColor(deviceRed: 0.82, green: 0.91, blue: 1.0, alpha: 1)
        node.enumerateChildNodes { child, _ in
            child.geometry?.materials.forEach {
                $0.multiply.contents = tint
            }
        }
        node.geometry?.materials.forEach {
            $0.multiply.contents = tint
        }
    }
}
