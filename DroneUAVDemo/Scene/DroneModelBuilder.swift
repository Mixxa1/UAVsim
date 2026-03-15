import AppKit
import SceneKit

struct DroneVisualModel {
    let rootNode: SCNNode
    let propellerNodes: [SCNNode]
    let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]
    let fpvAnchorNode: SCNNode
}

enum DroneModelBuilder {
    static func build(profile: DroneModelProfile) -> DroneVisualModel {
        switch profile.visualClass {
        case .miniCompact:
            return buildMini(profile: profile)
        case .vectorMidDual:
            return buildVector(profile: profile)
        case .atlasProTriple:
            return buildAtlas(profile: profile)
        case .abstract:
            return buildAbstract(profile: profile)
        case .fixedWingRectangular:
            return buildFixedWing(profile: profile, family: .rectangular)
        case .fixedWingDelta:
            return buildFixedWing(profile: profile, family: .delta)
        case .fixedWingSwept:
            return buildFixedWing(profile: profile, family: .swept)
        }
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

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvMount
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
        case .rectangular:
            fuselageLength = 0.62
            fuselageRadius = 0.042
        case .delta:
            fuselageLength = 0.56
            fuselageRadius = 0.036
        case .swept:
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
        case .rectangular:
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

        case .delta:
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

        case .swept:
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

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [propeller],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor
        )
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
