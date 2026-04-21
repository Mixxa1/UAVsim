import AppKit
import SceneKit

struct DroneVisualModel {
    let rootNode: SCNNode
    let visualRootNode: SCNNode
    let cameraAnchorNode: SCNNode
    let groundReferenceNode: SCNNode
    let propellerNodes: [SCNNode]
    let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]
    let fpvAnchorNode: SCNNode
    let payloadMountNode: SCNNode
    let visualBoundsCenter: SIMD3<Float>
    let visualBoundsSize: SIMD3<Float>
    let subjectScale: Float

    init(
        rootNode: SCNNode,
        visualRootNode: SCNNode = SCNNode(),
        cameraAnchorNode: SCNNode = SCNNode(),
        groundReferenceNode: SCNNode = SCNNode(),
        propellerNodes: [SCNNode],
        propellerSpinDirections: [Float],
        componentNodes: [DamageComponent: [SCNNode]],
        fpvAnchorNode: SCNNode,
        payloadMountNode: SCNNode,
        visualBoundsCenter: SIMD3<Float> = .zero,
        visualBoundsSize: SIMD3<Float> = SIMD3<Float>(repeating: 0.36),
        subjectScale: Float = 0.36
    ) {
        self.rootNode = rootNode
        self.visualRootNode = visualRootNode
        self.cameraAnchorNode = cameraAnchorNode
        self.groundReferenceNode = groundReferenceNode
        self.propellerNodes = propellerNodes
        self.propellerSpinDirections = propellerSpinDirections
        self.componentNodes = componentNodes
        self.fpvAnchorNode = fpvAnchorNode
        self.payloadMountNode = payloadMountNode
        self.visualBoundsCenter = visualBoundsCenter
        self.visualBoundsSize = visualBoundsSize
        self.subjectScale = subjectScale
    }
}

enum DroneModelBuilder {
    static func build(profile: DroneModelProfile) -> DroneVisualModel {
        let rawModel: DroneVisualModel
        if let uavProfile = profile.resolvedUAVProfile {
            rawModel = UAVVisualFactory.build(profile: uavProfile)
            if profile.airframeClass == .multirotor {
                // Keep new real-world rotorcraft aligned with the legacy chase-camera frame.
                rawModel.rootNode.eulerAngles.y = CGFloat(Float.pi)
            }
        } else {
            switch profile.visualClass {
            case .miniCompact:
                rawModel = buildMini(profile: profile)
            case .vectorMidDual:
                rawModel = buildVector(profile: profile)
            case .atlasProTriple:
                rawModel = buildAtlas(profile: profile)
            case .abstract:
                rawModel = buildAbstract(profile: profile)
            case .fixedWingRectangular:
                rawModel = buildFixedWing(profile: profile, family: .rectangular)
            case .fixedWingDelta:
                rawModel = buildFixedWing(profile: profile, family: .delta)
            case .fixedWingSwept:
                rawModel = buildFixedWing(profile: profile, family: .swept)
            case .ebeeClass:
                rawModel = buildEBeeClass(profile: profile)
            case .delairUX11Class:
                rawModel = buildUX11Class(profile: profile)
            case .wingtraClass:
                rawModel = buildWingtraClass(profile: profile)
            case .trinityClass:
                rawModel = buildTrinityClass(profile: profile)
            }
        }
        if profile.airframeClass == .fixedWing {
            rawModel.rootNode.eulerAngles.y = CGFloat(Float.pi)
        }
        return wrapVisualModel(rawModel, for: profile)
    }

    private static func buildMini(profile: DroneModelProfile) -> DroneVisualModel {
        let config = BuildConfig(
            body: SIMD3<Float>(0.16, 0.045, 0.125),
            armReach: 0.175,
            armThickness: 0.012,
            motorRadius: 0.016,
            motorHeight: 0.012,
            propellerRadius: 0.042,
            cameraBlock: SIMD3<Float>(0.042, 0.026, 0.036),
            noseOffset: SIMD3<Float>(0.0, 0.001, -0.073),
            legHeight: 0.010,
            colorBody: NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.84, alpha: 1.0),
            colorArms: NSColor(calibratedRed: 0.72, green: 0.74, blue: 0.78, alpha: 1.0),
            colorAccent: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.28, alpha: 1.0)
        )
        return buildQuadcopter(profile: profile, config: config, cameraLenses: 1)
    }

    private static func buildVector(profile: DroneModelProfile) -> DroneVisualModel {
        let config = BuildConfig(
            body: SIMD3<Float>(0.22, 0.060, 0.160),
            armReach: 0.225,
            armThickness: 0.016,
            motorRadius: 0.020,
            motorHeight: 0.014,
            propellerRadius: 0.050,
            cameraBlock: SIMD3<Float>(0.064, 0.030, 0.044),
            noseOffset: SIMD3<Float>(0.0, 0.002, -0.098),
            legHeight: 0.018,
            colorBody: NSColor(calibratedRed: 0.54, green: 0.57, blue: 0.62, alpha: 1.0),
            colorArms: NSColor(calibratedRed: 0.40, green: 0.43, blue: 0.48, alpha: 1.0),
            colorAccent: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1.0)
        )
        return buildQuadcopter(profile: profile, config: config, cameraLenses: 2)
    }

    private static func buildAtlas(profile: DroneModelProfile) -> DroneVisualModel {
        let config = BuildConfig(
            body: SIMD3<Float>(0.255, 0.074, 0.188),
            armReach: 0.255,
            armThickness: 0.020,
            motorRadius: 0.024,
            motorHeight: 0.016,
            propellerRadius: 0.058,
            cameraBlock: SIMD3<Float>(0.082, 0.038, 0.054),
            noseOffset: SIMD3<Float>(0.0, 0.003, -0.116),
            legHeight: 0.030,
            colorBody: NSColor(calibratedRed: 0.36, green: 0.39, blue: 0.44, alpha: 1.0),
            colorArms: NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.31, alpha: 1.0),
            colorAccent: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1.0)
        )
        return buildQuadcopter(profile: profile, config: config, cameraLenses: 3)
    }

    private static func buildAbstract(profile: DroneModelProfile) -> DroneVisualModel {
        let dim = profile.dimensions
        let span = max(0.20, min(0.55, max(dim.widthM, dim.lengthM)))
        let config = BuildConfig(
            body: SIMD3<Float>(span * 0.58, dim.heightM * 0.55, span * 0.42),
            armReach: span * 0.68,
            armThickness: max(0.012, span * 0.05),
            motorRadius: max(0.016, span * 0.07),
            motorHeight: max(0.012, dim.heightM * 0.16),
            propellerRadius: max(0.040, span * 0.16),
            cameraBlock: SIMD3<Float>(span * 0.2, dim.heightM * 0.30, span * 0.14),
            noseOffset: SIMD3<Float>(0.0, 0.003, -span * 0.30),
            legHeight: max(0.012, dim.heightM * 0.16),
            colorBody: NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.47, alpha: 1.0),
            colorArms: NSColor(calibratedRed: 0.21, green: 0.27, blue: 0.31, alpha: 1.0),
            colorAccent: NSColor(calibratedRed: 0.82, green: 0.44, blue: 0.22, alpha: 1.0)
        )
        return buildQuadcopter(profile: profile, config: config, cameraLenses: 2)
    }

    private static func buildQuadcopter(profile: DroneModelProfile, config: BuildConfig, cameraLenses: Int) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(diffuse: config.colorBody, roughness: 0.33, metalness: 0.48)
        let armMaterial = material(diffuse: config.colorArms, roughness: 0.5, metalness: 0.38)
        let accentMaterial = material(diffuse: config.colorAccent, roughness: 0.36, metalness: 0.12)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.78), roughness: 0.28, metalness: 0.04)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let body = SCNNode(geometry: SCNBox(
            width: CGFloat(config.body.x),
            height: CGFloat(config.body.y),
            length: CGFloat(config.body.z),
            chamferRadius: CGFloat(config.body.y * 0.3)
        ))
        body.geometry?.materials = [bodyMaterial]
        root.addChildNode(body)
        componentNodes[.flightControllerCore, default: []].append(body)

        let escBlock = SCNNode(geometry: SCNBox(
            width: CGFloat(config.body.x * 0.5),
            height: CGFloat(config.body.y * 0.28),
            length: CGFloat(config.body.z * 0.52),
            chamferRadius: CGFloat(config.body.y * 0.08)
        ))
        escBlock.position = SCNVector3(0, -config.body.y * 0.34, -config.body.z * 0.05)
        escBlock.geometry?.materials = [material(diffuse: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.19, alpha: 1.0), roughness: 0.4, metalness: 0.28)]
        root.addChildNode(escBlock)
        componentNodes[.escPower, default: []].append(escBlock)

        let batteryPack = SCNNode(geometry: SCNBox(
            width: CGFloat(config.body.x * 0.56),
            height: CGFloat(config.body.y * 0.35),
            length: CGFloat(config.body.z * 0.45),
            chamferRadius: CGFloat(config.body.y * 0.08)
        ))
        batteryPack.position = SCNVector3(0, -config.body.y * 0.02, -config.body.z * 0.18)
        batteryPack.geometry?.materials = [material(diffuse: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0), roughness: 0.42, metalness: 0.21)]
        root.addChildNode(batteryPack)
        componentNodes[.battery, default: []].append(batteryPack)

        let cameraRig = SCNNode()
        cameraRig.name = "fpvCameraAnchor"
        cameraRig.position = SCNVector3(config.noseOffset.x, config.noseOffset.y, config.noseOffset.z)

        let cameraModule = SCNNode(geometry: SCNBox(
            width: CGFloat(config.cameraBlock.x),
            height: CGFloat(config.cameraBlock.y),
            length: CGFloat(config.cameraBlock.z),
            chamferRadius: CGFloat(config.cameraBlock.y * 0.25)
        ))
        cameraModule.geometry?.materials = [accentMaterial]
        cameraModule.position = SCNVector3(0, -config.cameraBlock.y * 0.05, 0)
        cameraRig.addChildNode(cameraModule)

        addLenses(to: cameraRig, count: cameraLenses, config: config)

        // Dedicated mount point keeps the FPV camera outside the shell, aligned with the visible nose module.
        let fpvMount = SCNNode()
        fpvMount.name = "fpvMountAnchor"
        fpvMount.position = SCNVector3(0, config.cameraBlock.y * 0.04, -config.cameraBlock.z * 0.62)
        cameraRig.addChildNode(fpvMount)

        root.addChildNode(cameraRig)
        componentNodes[.frontCameraGimbal, default: []].append(cameraRig)

        let armOffsets: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-config.body.x * 0.36, 0.0, config.body.z * 0.25), SIMD3<Float>(-config.armReach, 0.0, config.armReach)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(config.body.x * 0.36, 0.0, config.body.z * 0.25), SIMD3<Float>(config.armReach, 0.0, config.armReach)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-config.body.x * 0.33, 0.0, -config.body.z * 0.24), SIMD3<Float>(-config.armReach, 0.0, -config.armReach)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(config.body.x * 0.33, 0.0, -config.body.z * 0.24), SIMD3<Float>(config.armReach, 0.0, -config.armReach))
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0]

        for (index, armData) in armOffsets.enumerated() {
            let armNode = buildArm(
                rootOffset: armData.3,
                tip: armData.4,
                thickness: config.armThickness,
                material: armMaterial
            )
            root.addChildNode(armNode)
            componentNodes[armData.0, default: []].append(armNode)

            let motorPosition = armData.4
            let motorNode = SCNNode(geometry: SCNCylinder(radius: CGFloat(config.motorRadius), height: CGFloat(config.motorHeight)))
            motorNode.position = SCNVector3(motorPosition.x, config.motorHeight * 0.52, motorPosition.z)
            motorNode.geometry?.materials = [armMaterial]
            root.addChildNode(motorNode)
            componentNodes[armData.1, default: []].append(motorNode)

            let propeller = makePropellerNode(material: rotorMaterial, radius: config.propellerRadius)
            propeller.position = SCNVector3(motorPosition.x, config.motorHeight * 1.1, motorPosition.z)
            propeller.name = "propeller_\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            componentNodes[armData.2, default: []].append(propeller)

            let leg = SCNNode(geometry: SCNBox(
                width: CGFloat(config.armThickness * 0.7),
                height: CGFloat(config.legHeight),
                length: CGFloat(config.armThickness * 0.7),
                chamferRadius: CGFloat(config.armThickness * 0.1)
            ))
            leg.position = SCNVector3(motorPosition.x * 0.8, -config.body.y * 0.56 - config.legHeight * 0.5, motorPosition.z * 0.8)
            leg.geometry?.materials = [armMaterial]
            root.addChildNode(leg)
            componentNodes[armData.0, default: []].append(leg)
        }

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -config.body.y * 0.78, -config.body.z * 0.04)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvMount,
            payloadMountNode: payloadMount
        )
    }

    private static func addLenses(to parent: SCNNode, count: Int, config: BuildConfig) {
        let lensRadius = CGFloat(max(0.004, config.cameraBlock.y * 0.16))
        let spacing = CGFloat(max(0.010, config.cameraBlock.x * 0.28))

        let start: CGFloat
        if count == 1 {
            start = 0
        } else {
            start = -spacing * CGFloat(count - 1) * 0.5
        }

        for index in 0..<count {
            let lens = SCNNode(geometry: SCNCylinder(radius: lensRadius, height: CGFloat(config.cameraBlock.z * 0.18)))
            lens.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            lens.position = SCNVector3(
                start + spacing * CGFloat(index),
                -CGFloat(config.cameraBlock.y * 0.05),
                -CGFloat(config.cameraBlock.z * 0.42)
            )
            lens.geometry?.materials = [material(diffuse: NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.08, alpha: 1.0), roughness: 0.12, metalness: 0.88)]
            parent.addChildNode(lens)
        }
    }

    private static func buildArm(rootOffset: SIMD3<Float>, tip: SIMD3<Float>, thickness: Float, material: SCNMaterial) -> SCNNode {
        let delta = tip - rootOffset
        let length = simd_length(delta)
        let arm = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(thickness * 0.5), height: CGFloat(max(thickness * 2.0, length))))
        arm.geometry?.materials = [material]
        arm.position = SCNVector3((rootOffset.x + tip.x) * 0.5, 0.0, (rootOffset.z + tip.z) * 0.5)

        let yaw = atan2(delta.x, delta.z)
        let pitch = atan2(0.0, max(0.0001, sqrt(delta.x * delta.x + delta.z * delta.z)))
        arm.eulerAngles = SCNVector3(pitch, -yaw, Float.pi / 2)
        return arm
    }

    private static func makePropellerNode(material: SCNMaterial, radius: Float) -> SCNNode {
        let node = SCNNode()

        let hub = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius * 0.13), height: CGFloat(radius * 0.08)))
        hub.geometry?.materials = [material]
        node.addChildNode(hub)

        let bladeGeometry = SCNBox(
            width: CGFloat(radius * 2.0),
            height: CGFloat(radius * 0.06),
            length: CGFloat(radius * 0.18),
            chamferRadius: CGFloat(radius * 0.03)
        )
        bladeGeometry.materials = [material]

        let bladeA = SCNNode(geometry: bladeGeometry)
        bladeA.position = SCNVector3(0, radius * 0.04, 0)

        let bladeB = SCNNode(geometry: bladeGeometry)
        bladeB.position = SCNVector3(0, radius * 0.04, 0)
        bladeB.eulerAngles = SCNVector3(0, Float.pi / 2, 0)

        node.addChildNode(bladeA)
        node.addChildNode(bladeB)

        return node
    }

    private static func buildFixedWing(profile: DroneModelProfile, family: FixedWingFamily) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(
            diffuse: NSColor(calibratedRed: 0.52, green: 0.56, blue: 0.62, alpha: 1.0),
            roughness: 0.36,
            metalness: 0.44
        )
        let wingMaterial = material(
            diffuse: NSColor(calibratedRed: 0.34, green: 0.38, blue: 0.44, alpha: 1.0),
            roughness: 0.42,
            metalness: 0.28
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.22, alpha: 1.0),
            roughness: 0.30,
            metalness: 0.40
        )

        let fuselageLength: Float
        let fuselageRadius: Float
        switch family {
        case .rectangular, .conventionalSurvey:
            fuselageLength = 0.62
            fuselageRadius = 0.042
        case .delta, .flyingWing:
            fuselageLength = 0.56
            fuselageRadius = 0.036
        case .swept, .tailsitterVTOL, .surveyEVTOL:
            fuselageLength = 0.72
            fuselageRadius = 0.048
        }

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(fuselageRadius), height: CGFloat(fuselageLength)))
        fuselage.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        fuselage.geometry?.materials = [bodyMaterial]
        root.addChildNode(fuselage)
        componentNodes[.flightControllerCore, default: []].append(fuselage)

        let batteryPack = SCNNode(geometry: SCNBox(
            width: CGFloat(fuselageRadius * 1.5),
            height: CGFloat(fuselageRadius * 1.2),
            length: CGFloat(fuselageLength * 0.28),
            chamferRadius: CGFloat(fuselageRadius * 0.2)
        ))
        batteryPack.position = SCNVector3(0, -fuselageRadius * 0.2, -fuselageLength * 0.10)
        batteryPack.geometry?.materials = [accentMaterial]
        root.addChildNode(batteryPack)
        componentNodes[.battery, default: []].append(batteryPack)

        let esc = SCNNode(geometry: SCNBox(
            width: CGFloat(fuselageRadius * 1.2),
            height: CGFloat(fuselageRadius * 0.6),
            length: CGFloat(fuselageLength * 0.16),
            chamferRadius: CGFloat(fuselageRadius * 0.12)
        ))
        esc.position = SCNVector3(0, -fuselageRadius * 0.48, -fuselageLength * 0.18)
        esc.geometry?.materials = [accentMaterial]
        root.addChildNode(esc)
        componentNodes[.escPower, default: []].append(esc)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0, 0.0, fuselageLength * 0.23)

        let camera = SCNNode(geometry: SCNBox(
            width: CGFloat(fuselageRadius * 1.1),
            height: CGFloat(fuselageRadius * 0.9),
            length: CGFloat(fuselageRadius * 1.1),
            chamferRadius: CGFloat(fuselageRadius * 0.2)
        ))
        camera.geometry?.materials = [accentMaterial]
        fpvAnchor.addChildNode(camera)
        root.addChildNode(fpvAnchor)
        componentNodes[.frontCameraGimbal, default: []].append(fpvAnchor)

        switch family {
        case .rectangular, .conventionalSurvey:
            let wing = SCNNode(geometry: SCNBox(
                width: 0.98,
                height: CGFloat(fuselageRadius * 0.32),
                length: CGFloat(fuselageRadius * 1.55),
                chamferRadius: CGFloat(fuselageRadius * 0.08)
            ))
            wing.position = SCNVector3(0, 0, -fuselageLength * 0.02)
            wing.geometry?.materials = [wingMaterial]
            root.addChildNode(wing)
            componentNodes[.armFL, default: []].append(wing)
            componentNodes[.armFR, default: []].append(wing)

        case .delta, .flyingWing:
            let wing = SCNNode(geometry: SCNPyramid(
                width: 0.90,
                height: CGFloat(fuselageRadius * 0.26),
                length: 0.55
            ))
            wing.position = SCNVector3(0, -fuselageRadius * 0.02, -fuselageLength * 0.01)
            wing.eulerAngles = SCNVector3(0, Float.pi, 0)
            wing.geometry?.materials = [wingMaterial]
            root.addChildNode(wing)
            componentNodes[.armFL, default: []].append(wing)
            componentNodes[.armFR, default: []].append(wing)

        case .swept, .tailsitterVTOL, .surveyEVTOL:
            let centerWing = SCNNode(geometry: SCNBox(
                width: 0.38,
                height: CGFloat(fuselageRadius * 0.28),
                length: CGFloat(fuselageRadius * 1.30),
                chamferRadius: CGFloat(fuselageRadius * 0.08)
            ))
            centerWing.geometry?.materials = [wingMaterial]
            root.addChildNode(centerWing)

            let leftWing = SCNNode(geometry: SCNBox(
                width: 0.46,
                height: CGFloat(fuselageRadius * 0.24),
                length: CGFloat(fuselageRadius * 1.15),
                chamferRadius: CGFloat(fuselageRadius * 0.06)
            ))
            leftWing.position = SCNVector3(-0.34, 0.0, -0.03)
            leftWing.eulerAngles = SCNVector3(0, 0.32, 0)
            leftWing.geometry?.materials = [wingMaterial]
            root.addChildNode(leftWing)

            let rightWing = SCNNode(geometry: SCNBox(
                width: 0.46,
                height: CGFloat(fuselageRadius * 0.24),
                length: CGFloat(fuselageRadius * 1.15),
                chamferRadius: CGFloat(fuselageRadius * 0.06)
            ))
            rightWing.position = SCNVector3(0.34, 0.0, -0.03)
            rightWing.eulerAngles = SCNVector3(0, -0.32, 0)
            rightWing.geometry?.materials = [wingMaterial]
            root.addChildNode(rightWing)

            componentNodes[.armFL, default: []].append(leftWing)
            componentNodes[.armFR, default: []].append(rightWing)
        }

        let stabilizer = SCNNode(geometry: SCNBox(
            width: 0.28,
            height: CGFloat(fuselageRadius * 0.24),
            length: CGFloat(fuselageRadius * 0.72),
            chamferRadius: CGFloat(fuselageRadius * 0.06)
        ))
        stabilizer.position = SCNVector3(0, 0.05, -fuselageLength * 0.24)
        stabilizer.geometry?.materials = [wingMaterial]
        root.addChildNode(stabilizer)
        componentNodes[.armRL, default: []].append(stabilizer)
        componentNodes[.armRR, default: []].append(stabilizer)

        let propellerMaterial = material(
            diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.82),
            roughness: 0.26,
            metalness: 0.08
        )

        let motor = SCNNode(geometry: SCNCylinder(radius: CGFloat(fuselageRadius * 0.42), height: CGFloat(fuselageRadius * 0.50)))
        motor.position = SCNVector3(0, 0, fuselageLength * 0.30)
        motor.geometry?.materials = [accentMaterial]
        root.addChildNode(motor)
        componentNodes[.motorFL, default: []].append(motor)

        let propeller = makePropellerNode(material: propellerMaterial, radius: max(0.065, fuselageRadius * 2.3))
        propeller.position = SCNVector3(0, 0, fuselageLength * 0.34)
        root.addChildNode(propeller)
        componentNodes[.propellerFL, default: []].append(propeller)

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -fuselageRadius * 0.95, -fuselageLength * 0.04)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [propeller],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount
        )
    }

    private static func buildEBeeClass(profile: DroneModelProfile) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(
            diffuse: NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.95, alpha: 1.0),
            roughness: 0.40,
            metalness: 0.16
        )
        let wingMaterial = material(
            diffuse: NSColor(calibratedRed: 0.34, green: 0.39, blue: 0.46, alpha: 1.0),
            roughness: 0.44,
            metalness: 0.24
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.16, green: 0.19, blue: 0.24, alpha: 1.0),
            roughness: 0.28,
            metalness: 0.42
        )

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let wing = makePlanformNode(
            points: [
                CGPoint(x: 0.00, y: 0.34),
                CGPoint(x: 0.21, y: 0.27),
                CGPoint(x: 0.58, y: 0.03),
                CGPoint(x: 0.49, y: -0.12),
                CGPoint(x: 0.16, y: -0.11),
                CGPoint(x: 0.00, y: -0.02),
                CGPoint(x: -0.16, y: -0.11),
                CGPoint(x: -0.49, y: -0.12),
                CGPoint(x: -0.58, y: 0.03),
                CGPoint(x: -0.21, y: 0.27)
            ],
            thickness: 0.024,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.02, 0.0)
        root.addChildNode(wing)
        componentNodes[.armFL, default: []].append(wing)
        componentNodes[.armFR, default: []].append(wing)

        let centerBody = SCNNode()
        let fuselage = horizontalCapsule(length: 0.40, radius: 0.040, material: bodyMaterial)
        centerBody.addChildNode(fuselage)

        let canopy = SCNNode(geometry: SCNSphere(radius: 0.042))
        canopy.position = SCNVector3(0.0, 0.016, 0.11)
        canopy.scale = SCNVector3(1.0, 0.55, 1.25)
        canopy.geometry?.materials = [accentMaterial]
        centerBody.addChildNode(canopy)

        let noseCone = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.040, height: 0.11))
        noseCone.position = SCNVector3(0.0, 0.0, 0.22)
        noseCone.eulerAngles = SCNVector3(-Float.pi / 2, 0.0, 0.0)
        noseCone.geometry?.materials = [bodyMaterial]
        centerBody.addChildNode(noseCone)

        let keel = SCNNode(geometry: SCNBox(width: 0.10, height: 0.030, length: 0.16, chamferRadius: 0.008))
        keel.position = SCNVector3(0.0, -0.020, 0.02)
        keel.geometry?.materials = [accentMaterial]
        centerBody.addChildNode(keel)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.010, 0.23)
        centerBody.addChildNode(fpvAnchor)
        componentNodes[.frontCameraGimbal, default: []].append(fpvAnchor)

        root.addChildNode(centerBody)
        componentNodes[.flightControllerCore, default: []].append(centerBody)
        componentNodes[.battery, default: []].append(keel)

        let rearPylon = SCNNode(geometry: SCNBox(width: 0.035, height: 0.070, length: 0.055, chamferRadius: 0.006))
        rearPylon.position = SCNVector3(0.0, 0.018, -0.13)
        rearPylon.geometry?.materials = [accentMaterial]
        root.addChildNode(rearPylon)
        componentNodes[.escPower, default: []].append(rearPylon)

        let motor = forwardMotorNode(radius: 0.016, length: 0.042, material: accentMaterial)
        motor.position = SCNVector3(0.0, 0.025, -0.17)
        root.addChildNode(motor)
        componentNodes[.motorFL, default: []].append(motor)

        let propeller = forwardPropellerNode(material: material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.82), roughness: 0.24, metalness: 0.08), radius: 0.085)
        propeller.position = SCNVector3(0.0, 0.025, -0.205)
        root.addChildNode(propeller)
        componentNodes[.propellerFL, default: []].append(propeller)

        let leftWinglet = makeVerticalSurfaceNode(
            points: [
                CGPoint(x: -0.02, y: 0.0),
                CGPoint(x: 0.06, y: 0.0),
                CGPoint(x: 0.03, y: 0.12),
                CGPoint(x: -0.01, y: 0.10)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        leftWinglet.position = SCNVector3(-0.50, 0.018, -0.06)
        root.addChildNode(leftWinglet)
        componentNodes[.armRL, default: []].append(leftWinglet)

        let rightWinglet = leftWinglet.clone()
        rightWinglet.position.x = 0.50
        root.addChildNode(rightWinglet)
        componentNodes[.armRR, default: []].append(rightWinglet)

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -0.055, 0.02)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [propeller],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount
        )
    }

    private static func buildUX11Class(profile: DroneModelProfile) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(
            diffuse: NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.90, alpha: 1.0),
            roughness: 0.38,
            metalness: 0.18
        )
        let wingMaterial = material(
            diffuse: NSColor(calibratedRed: 0.33, green: 0.36, blue: 0.41, alpha: 1.0),
            roughness: 0.42,
            metalness: 0.26
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.18, green: 0.21, blue: 0.25, alpha: 1.0),
            roughness: 0.28,
            metalness: 0.40
        )

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.66, radius: 0.028, material: bodyMaterial)
        root.addChildNode(fuselage)
        componentNodes[.flightControllerCore, default: []].append(fuselage)

        let noseCone = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.030, height: 0.11))
        noseCone.position = SCNVector3(0.0, 0.0, 0.36)
        noseCone.eulerAngles = SCNVector3(-Float.pi / 2, 0.0, 0.0)
        noseCone.geometry?.materials = [bodyMaterial]
        root.addChildNode(noseCone)

        let payloadNose = SCNNode(geometry: SCNSphere(radius: 0.030))
        payloadNose.position = SCNVector3(0.0, -0.010, 0.29)
        payloadNose.scale = SCNVector3(1.0, 0.68, 1.22)
        payloadNose.geometry?.materials = [accentMaterial]
        root.addChildNode(payloadNose)
        componentNodes[.frontCameraGimbal, default: []].append(payloadNose)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.002, 0.34)
        root.addChildNode(fpvAnchor)

        let wing = makePlanformNode(
            points: [
                CGPoint(x: -0.60, y: 0.05),
                CGPoint(x: -0.16, y: 0.14),
                CGPoint(x: 0.16, y: 0.14),
                CGPoint(x: 0.60, y: 0.05),
                CGPoint(x: 0.54, y: -0.11),
                CGPoint(x: -0.54, y: -0.11)
            ],
            thickness: 0.020,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.018, 0.03)
        root.addChildNode(wing)
        componentNodes[.armFL, default: []].append(wing)
        componentNodes[.armFR, default: []].append(wing)

        let tailPlane = makePlanformNode(
            points: [
                CGPoint(x: -0.20, y: 0.03),
                CGPoint(x: 0.20, y: 0.03),
                CGPoint(x: 0.16, y: -0.07),
                CGPoint(x: -0.16, y: -0.07)
            ],
            thickness: 0.014,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.050, -0.28)
        root.addChildNode(tailPlane)
        componentNodes[.armRL, default: []].append(tailPlane)
        componentNodes[.armRR, default: []].append(tailPlane)

        let fin = makeVerticalSurfaceNode(
            points: [
                CGPoint(x: -0.02, y: 0.0),
                CGPoint(x: 0.09, y: 0.0),
                CGPoint(x: 0.03, y: 0.15),
                CGPoint(x: -0.01, y: 0.12)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        fin.position = SCNVector3(0.0, 0.054, -0.30)
        root.addChildNode(fin)
        componentNodes[.armRR, default: []].append(fin)

        let pylon = SCNNode(geometry: SCNBox(width: 0.030, height: 0.075, length: 0.040, chamferRadius: 0.005))
        pylon.position = SCNVector3(0.0, 0.062, -0.16)
        pylon.geometry?.materials = [accentMaterial]
        root.addChildNode(pylon)
        componentNodes[.escPower, default: []].append(pylon)

        let batteryPack = SCNNode(geometry: SCNBox(width: 0.060, height: 0.030, length: 0.18, chamferRadius: 0.006))
        batteryPack.position = SCNVector3(0.0, -0.012, -0.02)
        batteryPack.geometry?.materials = [accentMaterial]
        root.addChildNode(batteryPack)
        componentNodes[.battery, default: []].append(batteryPack)

        let motor = forwardMotorNode(radius: 0.015, length: 0.038, material: accentMaterial)
        motor.position = SCNVector3(0.0, 0.066, -0.20)
        root.addChildNode(motor)
        componentNodes[.motorFL, default: []].append(motor)

        let propeller = forwardPropellerNode(material: material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.82), roughness: 0.24, metalness: 0.08), radius: 0.095)
        propeller.position = SCNVector3(0.0, 0.066, -0.235)
        root.addChildNode(propeller)
        componentNodes[.propellerFL, default: []].append(propeller)

        let bellySkid = SCNNode(geometry: SCNBox(width: 0.10, height: 0.018, length: 0.30, chamferRadius: 0.006))
        bellySkid.position = SCNVector3(0.0, -0.040, 0.02)
        bellySkid.geometry?.materials = [accentMaterial]
        root.addChildNode(bellySkid)

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -0.055, 0.10)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [propeller],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount
        )
    }

    private static func buildWingtraClass(profile: DroneModelProfile) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(
            diffuse: NSColor(calibratedRed: 0.83, green: 0.85, blue: 0.88, alpha: 1.0),
            roughness: 0.36,
            metalness: 0.18
        )
        let wingMaterial = material(
            diffuse: NSColor(calibratedRed: 0.28, green: 0.32, blue: 0.38, alpha: 1.0),
            roughness: 0.44,
            metalness: 0.24
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.24, alpha: 1.0),
            roughness: 0.30,
            metalness: 0.42
        )

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.74, radius: 0.035, material: bodyMaterial)
        root.addChildNode(fuselage)
        componentNodes[.flightControllerCore, default: []].append(fuselage)

        let bodySkid = SCNNode(geometry: SCNBox(width: 0.085, height: 0.026, length: 0.24, chamferRadius: 0.006))
        bodySkid.position = SCNVector3(0.0, -0.020, -0.02)
        bodySkid.geometry?.materials = [accentMaterial]
        root.addChildNode(bodySkid)
        componentNodes[.battery, default: []].append(bodySkid)

        let noseCone = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.038, height: 0.12))
        noseCone.position = SCNVector3(0.0, 0.0, 0.40)
        noseCone.eulerAngles = SCNVector3(-Float.pi / 2, 0.0, 0.0)
        noseCone.geometry?.materials = [bodyMaterial]
        root.addChildNode(noseCone)

        let wing = makePlanformNode(
            points: [
                CGPoint(x: -0.625, y: 0.05),
                CGPoint(x: -0.18, y: 0.15),
                CGPoint(x: 0.18, y: 0.15),
                CGPoint(x: 0.625, y: 0.05),
                CGPoint(x: 0.48, y: -0.14),
                CGPoint(x: -0.48, y: -0.14)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.018, 0.02)
        root.addChildNode(wing)
        componentNodes[.armFL, default: []].append(wing)
        componentNodes[.armFR, default: []].append(wing)

        let leftFin = makeVerticalSurfaceNode(
            points: [
                CGPoint(x: -0.03, y: 0.0),
                CGPoint(x: 0.11, y: 0.0),
                CGPoint(x: 0.04, y: 0.18),
                CGPoint(x: -0.02, y: 0.15)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.43, 0.015, -0.18)
        root.addChildNode(leftFin)
        componentNodes[.armRL, default: []].append(leftFin)

        let rightFin = leftFin.clone()
        rightFin.position.x = 0.43
        root.addChildNode(rightFin)
        componentNodes[.armRR, default: []].append(rightFin)

        let tailSkid = SCNNode(geometry: SCNBox(width: 0.05, height: 0.11, length: 0.018, chamferRadius: 0.004))
        tailSkid.position = SCNVector3(0.0, -0.005, -0.31)
        tailSkid.geometry?.materials = [accentMaterial]
        root.addChildNode(tailSkid)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.006, 0.37)
        root.addChildNode(fpvAnchor)
        componentNodes[.frontCameraGimbal, default: []].append(fpvAnchor)

        let leftPylon = SCNNode(geometry: SCNBox(width: 0.032, height: 0.090, length: 0.036, chamferRadius: 0.005))
        leftPylon.position = SCNVector3(-0.30, 0.054, 0.06)
        leftPylon.geometry?.materials = [accentMaterial]
        root.addChildNode(leftPylon)

        let rightPylon = leftPylon.clone()
        rightPylon.position.x = 0.30
        root.addChildNode(rightPylon)
        componentNodes[.escPower, default: []].append(leftPylon)
        componentNodes[.escPower, default: []].append(rightPylon)

        let leftMotor = forwardMotorNode(radius: 0.018, length: 0.044, material: accentMaterial)
        leftMotor.position = SCNVector3(-0.30, 0.060, 0.09)
        root.addChildNode(leftMotor)
        componentNodes[.motorFL, default: []].append(leftMotor)

        let rightMotor = forwardMotorNode(radius: 0.018, length: 0.044, material: accentMaterial)
        rightMotor.position = SCNVector3(0.30, 0.060, 0.09)
        root.addChildNode(rightMotor)
        componentNodes[.motorFR, default: []].append(rightMotor)

        let leftProp = forwardPropellerNode(material: material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.24, metalness: 0.08), radius: 0.115)
        leftProp.position = SCNVector3(-0.30, 0.060, 0.13)
        root.addChildNode(leftProp)
        componentNodes[.propellerFL, default: []].append(leftProp)

        let rightProp = forwardPropellerNode(material: material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.24, metalness: 0.08), radius: 0.115)
        rightProp.position = SCNVector3(0.30, 0.060, 0.13)
        root.addChildNode(rightProp)
        componentNodes[.propellerFR, default: []].append(rightProp)

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -0.060, 0.05)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [leftProp, rightProp],
            propellerSpinDirections: [1.0, -1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount
        )
    }

    private static func buildTrinityClass(profile: DroneModelProfile) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "droneRoot"

        let bodyMaterial = material(
            diffuse: NSColor(calibratedRed: 0.88, green: 0.89, blue: 0.91, alpha: 1.0),
            roughness: 0.34,
            metalness: 0.20
        )
        let wingMaterial = material(
            diffuse: NSColor(calibratedRed: 0.26, green: 0.30, blue: 0.35, alpha: 1.0),
            roughness: 0.42,
            metalness: 0.26
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1.0),
            roughness: 0.30,
            metalness: 0.44
        )

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.04, radius: 0.048, material: bodyMaterial)
        root.addChildNode(fuselage)
        componentNodes[.flightControllerCore, default: []].append(fuselage)

        let payloadBay = SCNNode(geometry: SCNBox(width: 0.12, height: 0.055, length: 0.30, chamferRadius: 0.010))
        payloadBay.position = SCNVector3(0.0, -0.020, 0.10)
        payloadBay.geometry?.materials = [accentMaterial]
        root.addChildNode(payloadBay)
        componentNodes[.battery, default: []].append(payloadBay)

        let noseCone = SCNNode(geometry: SCNCone(topRadius: 0.0, bottomRadius: 0.050, height: 0.18))
        noseCone.position = SCNVector3(0.0, 0.0, 0.58)
        noseCone.eulerAngles = SCNVector3(-Float.pi / 2, 0.0, 0.0)
        noseCone.geometry?.materials = [bodyMaterial]
        root.addChildNode(noseCone)

        let wing = makePlanformNode(
            points: [
                CGPoint(x: -1.20, y: 0.10),
                CGPoint(x: -0.34, y: 0.22),
                CGPoint(x: 0.34, y: 0.22),
                CGPoint(x: 1.20, y: 0.10),
                CGPoint(x: 1.02, y: -0.18),
                CGPoint(x: -1.02, y: -0.18)
            ],
            thickness: 0.028,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.024, 0.02)
        root.addChildNode(wing)
        componentNodes[.armFL, default: []].append(wing)
        componentNodes[.armFR, default: []].append(wing)

        let leftBoom = horizontalCapsule(length: 0.70, radius: 0.022, material: accentMaterial)
        leftBoom.position = SCNVector3(-0.32, 0.010, -0.18)
        root.addChildNode(leftBoom)
        componentNodes[.armRL, default: []].append(leftBoom)

        let rightBoom = horizontalCapsule(length: 0.70, radius: 0.022, material: accentMaterial)
        rightBoom.position = SCNVector3(0.32, 0.010, -0.18)
        root.addChildNode(rightBoom)
        componentNodes[.armRR, default: []].append(rightBoom)

        let tailPlane = makePlanformNode(
            points: [
                CGPoint(x: -0.32, y: 0.04),
                CGPoint(x: 0.32, y: 0.04),
                CGPoint(x: 0.26, y: -0.08),
                CGPoint(x: -0.26, y: -0.08)
            ],
            thickness: 0.018,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.070, -0.52)
        root.addChildNode(tailPlane)
        componentNodes[.armRL, default: []].append(tailPlane)
        componentNodes[.armRR, default: []].append(tailPlane)

        let leftFin = makeVerticalSurfaceNode(
            points: [
                CGPoint(x: -0.03, y: 0.0),
                CGPoint(x: 0.13, y: 0.0),
                CGPoint(x: 0.05, y: 0.22),
                CGPoint(x: -0.02, y: 0.18)
            ],
            thickness: 0.014,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.32, 0.070, -0.56)
        root.addChildNode(leftFin)

        let rightFin = leftFin.clone()
        rightFin.position.x = 0.32
        root.addChildNode(rightFin)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.008, 0.54)
        root.addChildNode(fpvAnchor)
        componentNodes[.frontCameraGimbal, default: []].append(fpvAnchor)

        let rotorMaterial = material(
            diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84),
            roughness: 0.24,
            metalness: 0.08
        )

        let podPositions: [(SIMD3<Float>, DamageComponent, DamageComponent)] = [
            (SIMD3<Float>(-0.52, 0.095, 0.12), .motorFL, .propellerFL),
            (SIMD3<Float>(0.52, 0.095, 0.12), .motorFR, .propellerFR),
            (SIMD3<Float>(-0.52, 0.095, -0.14), .motorRL, .propellerRL),
            (SIMD3<Float>(0.52, 0.095, -0.14), .motorRR, .propellerRR)
        ]

        var props: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0]

        for (index, pod) in podPositions.enumerated() {
            let mast = SCNNode(geometry: SCNBox(width: 0.030, height: 0.090, length: 0.030, chamferRadius: 0.005))
            mast.position = SCNVector3(pod.0.x, 0.050, pod.0.z)
            mast.geometry?.materials = [accentMaterial]
            root.addChildNode(mast)

            let motor = SCNNode(geometry: SCNCylinder(radius: 0.020, height: 0.022))
            motor.position = SCNVector3(pod.0.x, pod.0.y, pod.0.z)
            motor.geometry?.materials = [accentMaterial]
            root.addChildNode(motor)
            componentNodes[pod.1, default: []].append(motor)

            let propeller = makePropellerNode(material: rotorMaterial, radius: 0.12)
            propeller.position = SCNVector3(pod.0.x, pod.0.y + 0.020, pod.0.z)
            propeller.name = "trinity_vtol_prop_\(index)"
            root.addChildNode(propeller)
            props.append(propeller)
            componentNodes[pod.2, default: []].append(propeller)
        }

        let cruiseNose = SCNNode(geometry: SCNBox(width: 0.038, height: 0.038, length: 0.075, chamferRadius: 0.010))
        cruiseNose.position = SCNVector3(0.0, 0.0, 0.45)
        cruiseNose.geometry?.materials = [accentMaterial]
        root.addChildNode(cruiseNose)
        componentNodes[.escPower, default: []].append(cruiseNose)

        let payloadMount = SCNNode()
        payloadMount.name = "payloadMountNode"
        payloadMount.position = SCNVector3(0.0, -0.090, 0.12)
        root.addChildNode(payloadMount)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: props,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMount
        )
    }

    private static func makePlanformNode(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNNode {
        let shape = makeExtrudedShape(points: points, thickness: thickness, material: material)
        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(0.0, 0.0, CGFloat(thickness * 0.5))
        node.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func makeVerticalSurfaceNode(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNNode {
        let shape = makeExtrudedShape(points: points, thickness: thickness, material: material)
        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(0.0, 0.0, CGFloat(thickness * 0.5))
        node.eulerAngles = SCNVector3(0.0, Float.pi / 2.0, 0.0)
        return node
    }

    private static func makeExtrudedShape(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNShape {
        let path = NSBezierPath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() {
                path.line(to: point)
            }
            path.close()
        }

        let shape = SCNShape(path: path, extrusionDepth: CGFloat(thickness))
        shape.chamferRadius = CGFloat(thickness * 0.18)
        shape.materials = [material]
        return shape
    }

    private static func horizontalCapsule(length: Float, radius: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(length)))
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        node.geometry?.materials = [material]
        return node
    }

    private static func forwardMotorNode(radius: Float, length: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: CGFloat(length)))
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        node.geometry?.materials = [material]
        return node
    }

    private static func forwardPropellerNode(material: SCNMaterial, radius: Float) -> SCNNode {
        let node = makePropellerNode(material: material, radius: radius)
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func wrapVisualModel(_ rawModel: DroneVisualModel, for profile: DroneModelProfile) -> DroneVisualModel {
        let bounds = measureStaticVisualBounds(of: rawModel.rootNode)
        let groundLift = max(0.0, -bounds.min.y)
        let adjustedMin = bounds.min + SIMD3<Float>(0.0, groundLift, 0.0)
        let adjustedMax = bounds.max + SIMD3<Float>(0.0, groundLift, 0.0)
        let adjustedCenter = (adjustedMin + adjustedMax) * 0.5
        let adjustedSize = simd_max(adjustedMax - adjustedMin, SIMD3<Float>(repeating: 0.001))
        let subjectScale = max(
            0.36,
            adjustedSize.x,
            adjustedSize.z,
            adjustedSize.y * 1.4,
            profile.collisionRadius * 2.0
        )

        let flightRoot = SCNNode()
        flightRoot.name = "droneFlightRoot"

        let visualRoot = SCNNode()
        visualRoot.name = "droneVisualRoot"

        let groundReferenceNode = SCNNode()
        groundReferenceNode.name = "groundReferenceNode"

        let cameraAnchorNode = SCNNode()
        cameraAnchorNode.name = "cameraAnchorNode"
        cameraAnchorNode.simdPosition = stableCameraAnchorPosition(
            center: adjustedCenter,
            size: adjustedSize,
            profile: profile
        )

        rawModel.rootNode.removeFromParentNode()
        rawModel.rootNode.simdPosition += SIMD3<Float>(0.0, groundLift, 0.0)
        visualRoot.addChildNode(rawModel.rootNode)

        flightRoot.addChildNode(groundReferenceNode)
        flightRoot.addChildNode(visualRoot)
        flightRoot.addChildNode(cameraAnchorNode)

        return DroneVisualModel(
            rootNode: flightRoot,
            visualRootNode: visualRoot,
            cameraAnchorNode: cameraAnchorNode,
            groundReferenceNode: groundReferenceNode,
            propellerNodes: rawModel.propellerNodes,
            propellerSpinDirections: rawModel.propellerSpinDirections,
            componentNodes: rawModel.componentNodes,
            fpvAnchorNode: rawModel.fpvAnchorNode,
            payloadMountNode: rawModel.payloadMountNode,
            visualBoundsCenter: adjustedCenter,
            visualBoundsSize: adjustedSize,
            subjectScale: subjectScale
        )
    }

    private static func stableCameraAnchorPosition(
        center: SIMD3<Float>,
        size: SIMD3<Float>,
        profile: DroneModelProfile
    ) -> SIMD3<Float> {
        let topY = max(size.y, center.y + size.y * 0.5)
        let lowerBias = center.y + size.y * (profile.airframeClass == .fixedWing ? 0.10 : 0.08)
        let upperBias = topY - max(0.06, size.y * 0.14)
        let anchorY = max(0.08, min(upperBias, lowerBias))
        return SIMD3<Float>(center.x, anchorY, center.z)
    }

    private static func measureStaticVisualBounds(of rootNode: SCNNode) -> StaticVisualBounds {
        var boundsMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var boundsMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var foundGeometry = false

        accumulateStaticVisualBounds(
            from: rootNode,
            rootNode: rootNode,
            boundsMin: &boundsMin,
            boundsMax: &boundsMax,
            foundGeometry: &foundGeometry
        )

        guard foundGeometry else {
            return StaticVisualBounds(
                min: SIMD3<Float>(0.0, 0.0, 0.0),
                max: SIMD3<Float>(0.36, 0.36, 0.36)
            )
        }

        return StaticVisualBounds(min: boundsMin, max: boundsMax)
    }

    private static func accumulateStaticVisualBounds(
        from node: SCNNode,
        rootNode: SCNNode,
        boundsMin: inout SIMD3<Float>,
        boundsMax: inout SIMD3<Float>,
        foundGeometry: inout Bool
    ) {
        if node.geometry != nil {
            let box = node.boundingBox
            let localMin = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let localMax = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))

            for corner in boundingBoxCorners(min: localMin, max: localMax) {
                let converted = rootNode.simdConvertPosition(corner, from: node)
                boundsMin = simd_min(boundsMin, converted)
                boundsMax = simd_max(boundsMax, converted)
            }
            foundGeometry = true
        }

        for child in node.childNodes {
            accumulateStaticVisualBounds(
                from: child,
                rootNode: rootNode,
                boundsMin: &boundsMin,
                boundsMax: &boundsMax,
                foundGeometry: &foundGeometry
            )
        }
    }

    private static func boundingBoxCorners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(min.x, min.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, min.z),
            SIMD3<Float>(min.x, max.y, max.z),
            SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(max.x, max.y, max.z)
        ]
    }

    private static func material(diffuse: NSColor, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        material.lightingModel = .physicallyBased
        return material
    }
}

private struct BuildConfig {
    let body: SIMD3<Float>
    let armReach: Float
    let armThickness: Float
    let motorRadius: Float
    let motorHeight: Float
    let propellerRadius: Float
    let cameraBlock: SIMD3<Float>
    let noseOffset: SIMD3<Float>
    let legHeight: Float
    let colorBody: NSColor
    let colorArms: NSColor
    let colorAccent: NSColor
}

private struct StaticVisualBounds {
    let min: SIMD3<Float>
    let max: SIMD3<Float>
}
