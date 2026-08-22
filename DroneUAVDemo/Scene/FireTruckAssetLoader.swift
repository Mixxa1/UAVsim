import SceneKit

private enum FireTruckAssetConstants {
    static let resourceName = "Fire_Truck"
    static let resourceExtension = "usdz"
    static let nodeName = "scenario.fire_truck"
    static let defaultHeightMeters: Float = 3.0
}

/// Loads `Fire_Truck.usdz` as the ground anchor and water source for the fire-response scenario.
/// The flexible hose visual is managed by `DroneSceneController`, while the UAV carries its
/// working end and nozzle assembly. Mirrors `ManAssetLoader`/`PineTreeAssetLoader`: lazy-cached template,
/// height normalization, graceful procedural fallback when the asset is missing.
final class FireTruckAssetLoader {
    static let shared = FireTruckAssetLoader()
    static let pumpOutletAnchorNodeName = "fire_truck.pump_outlet_anchor"

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var modelNativeMinY: Float = 0.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makeTruckNode(
        targetHeightMeters: Float = FireTruckAssetConstants.defaultHeightMeters,
        yaw: Float = 0.0
    ) -> SCNNode {
        let height = max(0.5, targetHeightMeters)
        guard let template = loadTemplate() else {
            warnOnce()
            return makeProceduralTruck(targetHeightMeters: height, yaw: yaw)
        }

        let scale = height / max(modelNativeHeight, 0.001)
        let model = template.clone()
        model.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(0, -modelNativeMinY * scale, 0)

        let wrapper = SCNNode()
        wrapper.name = FireTruckAssetConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)
        wrapper.addChildNode(model)
        installPumpOutlet(on: wrapper, truckHeightMeters: height)
        enableShadowsRecursively(wrapper)
        return wrapper
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: FireTruckAssetConstants.resourceName,
            withExtension: FireTruckAssetConstants.resourceExtension
        ) else {
            return nil
        }

        guard let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let root = SCNNode()
        root.name = "fire_truck_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        enableShadowsRecursively(root)

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        modelNativeMinY = Float(minBB.y)
        print("[Scenario] Fire_Truck.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    /// Minimal stand-in so the fire zone still reads as "responded to" when the USDZ asset is
    /// unavailable — a plain red box body on four dark wheels, purely cosmetic.
    private func makeProceduralTruck(targetHeightMeters: Float, yaw: Float) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = FireTruckAssetConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)

        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.10, blue: 0.08, alpha: 1.0)
        bodyMaterial.roughness.contents = 0.5

        let bodyHeight = targetHeightMeters * 0.55
        let body = SCNBox(
            width: CGFloat(targetHeightMeters * 1.9),
            height: CGFloat(bodyHeight),
            length: CGFloat(targetHeightMeters * 0.75),
            chamferRadius: 0.05
        )
        body.firstMaterial = bodyMaterial
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, targetHeightMeters * 0.32, 0)
        wrapper.addChildNode(bodyNode)

        let wheelMaterial = SCNMaterial()
        wheelMaterial.diffuse.contents = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let wheelRadius = targetHeightMeters * 0.14
        for xSign: Float in [-1.0, 1.0] {
            for zOffset: Float in [-0.65, 0.65] {
                let wheel = SCNCylinder(radius: CGFloat(wheelRadius), height: CGFloat(wheelRadius * 0.5))
                wheel.firstMaterial = wheelMaterial
                let wheelNode = SCNNode(geometry: wheel)
                wheelNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2.0)
                wheelNode.position = SCNVector3(
                    xSign * targetHeightMeters * 0.95,
                    wheelRadius,
                    zOffset * targetHeightMeters * 0.6
                )
                wrapper.addChildNode(wheelNode)
            }
        }

        installPumpOutlet(on: wrapper, truckHeightMeters: targetHeightMeters)
        enableShadowsRecursively(wrapper)
        return wrapper
    }

    /// Adds a real, visible pump coupling to the side panel and exposes its mouth as the hose's
    /// fixed simulation anchor. The USDZ has no semantic outlet node of its own; anchoring the
    /// line to an estimated point beside the truck left a visible air gap. This plate deliberately
    /// intersects the body skin by a few centimetres, so the coupling cannot read as a floating
    /// prop even with small asset/scale variations.
    private func installPumpOutlet(on truck: SCNNode, truckHeightMeters: Float) {
        let scale = max(0.5, truckHeightMeters) / FireTruckAssetConstants.defaultHeightMeters
        let root = SCNNode()
        root.name = "fire_truck.pump_outlet"
        root.position = SCNVector3(-1.79 * scale, 0.96 * scale, 0.92 * scale)

        let plateMaterial = SCNMaterial()
        plateMaterial.lightingModel = .physicallyBased
        plateMaterial.diffuse.contents = NSColor(calibratedWhite: 0.16, alpha: 1.0)
        plateMaterial.metalness.contents = 0.72
        plateMaterial.roughness.contents = 0.38

        let couplingMaterial = SCNMaterial()
        couplingMaterial.lightingModel = .physicallyBased
        couplingMaterial.diffuse.contents = NSColor(calibratedWhite: 0.58, alpha: 1.0)
        couplingMaterial.metalness.contents = 0.82
        couplingMaterial.roughness.contents = 0.28

        let rubberMaterial = SCNMaterial()
        rubberMaterial.lightingModel = .physicallyBased
        rubberMaterial.diffuse.contents = NSColor(calibratedWhite: 0.035, alpha: 1.0)
        rubberMaterial.roughness.contents = 0.88

        let plate = SCNBox(
            width: CGFloat(0.055 * scale),
            height: CGFloat(0.32 * scale),
            length: CGFloat(0.34 * scale),
            chamferRadius: CGFloat(0.025 * scale)
        )
        plate.firstMaterial = plateMaterial
        let plateNode = SCNNode(geometry: plate)
        root.addChildNode(plateNode)

        let socket = SCNCylinder(radius: CGFloat(0.105 * scale), height: CGFloat(0.18 * scale))
        socket.radialSegmentCount = 32
        socket.firstMaterial = couplingMaterial
        let socketNode = SCNNode(geometry: socket)
        socketNode.eulerAngles.z = .pi / 2.0
        socketNode.position.x = CGFloat(-0.105 * scale)
        root.addChildNode(socketNode)

        let collar = SCNTorus(
            ringRadius: CGFloat(0.096 * scale),
            pipeRadius: CGFloat(0.018 * scale)
        )
        collar.ringSegmentCount = 40
        collar.pipeSegmentCount = 12
        collar.firstMaterial = couplingMaterial
        let collarNode = SCNNode(geometry: collar)
        collarNode.eulerAngles.z = .pi / 2.0
        collarNode.position.x = CGFloat(-0.198 * scale)
        root.addChildNode(collarNode)

        let mouth = SCNCylinder(radius: CGFloat(0.076 * scale), height: CGFloat(0.014 * scale))
        mouth.radialSegmentCount = 32
        mouth.firstMaterial = rubberMaterial
        let mouthNode = SCNNode(geometry: mouth)
        mouthNode.eulerAngles.z = .pi / 2.0
        mouthNode.position.x = CGFloat(-0.210 * scale)
        root.addChildNode(mouthNode)

        for y: Float in [-0.12, 0.12] {
            for z: Float in [-0.125, 0.125] {
                let bolt = SCNCylinder(radius: CGFloat(0.012 * scale), height: CGFloat(0.065 * scale))
                bolt.radialSegmentCount = 12
                bolt.firstMaterial = couplingMaterial
                let boltNode = SCNNode(geometry: bolt)
                boltNode.eulerAngles.z = .pi / 2.0
                boltNode.position = SCNVector3(-0.036 * scale, y * scale, z * scale)
                root.addChildNode(boltNode)
            }
        }

        let anchor = SCNNode()
        anchor.name = Self.pumpOutletAnchorNodeName
        anchor.position.x = CGFloat(-0.222 * scale)
        root.addChildNode(anchor)
        truck.addChildNode(root)
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Scenario] Fire_Truck asset unavailable; using procedural truck fallback")
    }

    private func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        for child in node.childNodes {
            enableShadowsRecursively(child)
        }
    }
}
