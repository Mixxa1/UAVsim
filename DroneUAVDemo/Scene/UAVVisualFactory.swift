import AppKit
import SceneKit
import simd

enum UAVVisualFactory {
    static func build(profile: UAVProfile) -> DroneVisualModel {
        build(preset: profile.visualPreset, payloadMountOffset: profile.payloadMountOffset)
    }

    static func build(preset: UAVVisualPreset, payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        switch preset {
        case .abstractCustom:
            return buildAbstractCustom(payloadMountOffset: payloadMountOffset)
        case .djiMatrice350RTK:
            return buildDJIMatrice350RTK(payloadMountOffset: payloadMountOffset)
        case .djiMavic4Pro:
            return buildDJIMavic4Pro(payloadMountOffset: payloadMountOffset)
        case .djiNeo:
            return buildDJINeo(payloadMountOffset: payloadMountOffset)
        case .djiPhantom3Standard:
            return buildDJIPhantom3Standard(payloadMountOffset: payloadMountOffset)
        case .freeflyAltaX:
            return buildFreeflyAltaX(payloadMountOffset: payloadMountOffset)
        case .wingtraOneGenII:
            return buildWingtraOneGenII(payloadMountOffset: payloadMountOffset)
        case .quantumSystemsTrinityPro:
            return buildQuantumSystemsTrinityPro(payloadMountOffset: payloadMountOffset)
        case .djiFlyCart30:
            return buildDJIFlyCart30(payloadMountOffset: payloadMountOffset)
        case .griff30:
            return buildGriff30(payloadMountOffset: payloadMountOffset)
        case .griff60:
            return buildGriff60(payloadMountOffset: payloadMountOffset)
        case .avidrone490TL:
            return buildAvidrone490TL(payloadMountOffset: payloadMountOffset)
        case .mq9bSkyGuardian:
            return buildMQ9BSkyGuardian(payloadMountOffset: payloadMountOffset)
        case .hermes900:
            return buildHermes900(payloadMountOffset: payloadMountOffset)
        case .ft5Los:
            return buildFT5Los(payloadMountOffset: payloadMountOffset)
        case .flyEye:
            return buildFlyEye(payloadMountOffset: payloadMountOffset)
        }
    }

    private static func buildDJIMatrice350RTK(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.djiMatrice350RTK"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.39, alpha: 1.0), roughness: 0.34, metalness: 0.46)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.26, alpha: 1.0), roughness: 0.42, metalness: 0.28)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.78, green: 0.81, blue: 0.84, alpha: 1.0), roughness: 0.28, metalness: 0.16)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let upperBody = boxNode(size: SIMD3<Float>(0.22, 0.07, 0.16), chamfer: 0.018, material: bodyMaterial)
        upperBody.position = SCNVector3(0.0, 0.02, 0.0)
        root.addChildNode(upperBody)
        append(upperBody, to: .flightControllerCore, componentNodes: &componentNodes)

        let batteryBridge = boxNode(size: SIMD3<Float>(0.15, 0.10, 0.10), chamfer: 0.012, material: accentMaterial)
        batteryBridge.position = SCNVector3(0.0, 0.06, -0.01)
        root.addChildNode(batteryBridge)
        append(batteryBridge, to: .battery, componentNodes: &componentNodes)

        let undercarriage = boxNode(size: SIMD3<Float>(0.17, 0.045, 0.14), chamfer: 0.012, material: armMaterial)
        undercarriage.position = SCNVector3(0.0, -0.03, -0.01)
        root.addChildNode(undercarriage)
        append(undercarriage, to: .escPower, componentNodes: &componentNodes)

        let gimbalBay = boxNode(size: SIMD3<Float>(0.12, 0.07, 0.10), chamfer: 0.012, material: accentMaterial)
        gimbalBay.position = SCNVector3(0.0, -0.08, 0.03)
        root.addChildNode(gimbalBay)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.02, 0.12)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let armOffsets: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.06, 0.03, 0.04), SIMD3<Float>(-0.31, 0.05, 0.23)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.06, 0.03, 0.04), SIMD3<Float>(0.31, 0.05, 0.23)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.06, 0.03, -0.04), SIMD3<Float>(-0.31, 0.05, -0.23)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.06, 0.03, -0.04), SIMD3<Float>(0.31, 0.05, -0.23))
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0]

        for (index, armData) in armOffsets.enumerated() {
            let arm = beamNode(start: armData.3, end: armData.4, radius: 0.016, material: armMaterial)
            root.addChildNode(arm)
            append(arm, to: armData.0, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.030, height: 0.030, material: armMaterial)
            motor.position = SCNVector3(armData.4.x, armData.4.y, armData.4.z)
            root.addChildNode(motor)
            append(motor, to: armData.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.12)
            propeller.position = SCNVector3(armData.4.x, armData.4.y + 0.026, armData.4.z)
            propeller.name = "propeller.m350.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: armData.2, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let legOuter = beamNode(
                start: SIMD3<Float>(0.18 * side, -0.01, 0.10),
                end: SIMD3<Float>(0.22 * side, -0.19, 0.10),
                radius: 0.010,
                material: accentMaterial
            )
            let legInner = beamNode(
                start: SIMD3<Float>(0.12 * side, -0.01, -0.08),
                end: SIMD3<Float>(0.16 * side, -0.19, -0.08),
                radius: 0.010,
                material: accentMaterial
            )
            let foot = beamNode(
                start: SIMD3<Float>(0.22 * side, -0.19, -0.10),
                end: SIMD3<Float>(0.22 * side, -0.19, 0.12),
                radius: 0.009,
                material: accentMaterial
            )
            root.addChildNode(legOuter)
            root.addChildNode(legInner)
            root.addChildNode(foot)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildAbstractCustom(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.abstractCustom"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.36, green: 0.43, blue: 0.49, alpha: 1.0), roughness: 0.34, metalness: 0.42)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.19, green: 0.24, blue: 0.28, alpha: 1.0), roughness: 0.44, metalness: 0.28)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.86, green: 0.44, blue: 0.21, alpha: 1.0), roughness: 0.26, metalness: 0.16)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.82), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let body = boxNode(size: SIMD3<Float>(0.18, 0.06, 0.12), chamfer: 0.014, material: bodyMaterial)
        body.position = SCNVector3(0.0, 0.01, 0.0)
        root.addChildNode(body)
        append(body, to: .flightControllerCore, componentNodes: &componentNodes)

        let batteryPod = boxNode(size: SIMD3<Float>(0.12, 0.05, 0.08), chamfer: 0.010, material: accentMaterial)
        batteryPod.position = SCNVector3(0.0, 0.05, -0.01)
        root.addChildNode(batteryPod)
        append(batteryPod, to: .battery, componentNodes: &componentNodes)

        let bellyModule = boxNode(size: SIMD3<Float>(0.10, 0.04, 0.08), chamfer: 0.008, material: armMaterial)
        bellyModule.position = SCNVector3(0.0, -0.06, 0.0)
        root.addChildNode(bellyModule)
        append(bellyModule, to: .escPower, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.01, 0.10)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let armOffsets: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.20, 0.03, 0.17)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.20, 0.03, 0.17)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.20, 0.03, -0.17)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.20, 0.03, -0.17))
        ]

        var propellers: [SCNNode] = []
        for (index, armData) in armOffsets.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.01, 0.0), end: armData.3, radius: 0.013, material: armMaterial)
            root.addChildNode(arm)
            append(arm, to: armData.0, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.020, height: 0.018, material: armMaterial)
            motor.position = SCNVector3(armData.3.x, armData.3.y, armData.3.z)
            root.addChildNode(motor)
            append(motor, to: armData.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.080)
            propeller.position = SCNVector3(armData.3.x, armData.3.y + 0.015, armData.3.z)
            propeller.name = "propeller.abstract.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: armData.2, componentNodes: &componentNodes)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: [1.0, -1.0, -1.0, 1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildDJIMavic4Pro(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.djiMavic4Pro"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.56, green: 0.58, blue: 0.61, alpha: 1.0), roughness: 0.34, metalness: 0.38)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.38, green: 0.40, blue: 0.43, alpha: 1.0), roughness: 0.40, metalness: 0.28)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.22, alpha: 1.0), roughness: 0.26, metalness: 0.52)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.95, alpha: 0.80), roughness: 0.24, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let body = boxNode(size: SIMD3<Float>(0.19, 0.050, 0.12), chamfer: 0.016, material: bodyMaterial)
        body.position = SCNVector3(0.0, 0.012, 0.0)
        root.addChildNode(body)
        append(body, to: .flightControllerCore, componentNodes: &componentNodes)

        let batteryBlock = boxNode(size: SIMD3<Float>(0.12, 0.046, 0.08), chamfer: 0.010, material: armMaterial)
        batteryBlock.position = SCNVector3(0.0, 0.046, -0.02)
        root.addChildNode(batteryBlock)
        append(batteryBlock, to: .battery, componentNodes: &componentNodes)

        let noseSensor = boxNode(size: SIMD3<Float>(0.08, 0.032, 0.05), chamfer: 0.010, material: accentMaterial)
        noseSensor.position = SCNVector3(0.0, -0.010, 0.082)
        root.addChildNode(noseSensor)
        append(noseSensor, to: .escPower, componentNodes: &componentNodes)

        let gimbalBody = sphereNode(radius: 0.026, material: accentMaterial)
        gimbalBody.scale = SCNVector3(1.0, 0.85, 1.05)
        gimbalBody.position = SCNVector3(0.0, -0.040, 0.090)
        root.addChildNode(gimbalBody)
        append(gimbalBody, to: .frontCameraGimbal, componentNodes: &componentNodes)

        for offsetX in [-0.015 as Float, 0.015] {
            let lens = cylinderNode(radius: 0.008, height: 0.012, material: accentMaterial)
            lens.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            lens.position = SCNVector3(offsetX, -0.040, 0.110)
            root.addChildNode(lens)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.036, 0.118)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let armTips: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.06, 0.012, 0.028), SIMD3<Float>(-0.21, 0.018, 0.18)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.06, 0.012, 0.028), SIMD3<Float>(0.21, 0.018, 0.18)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.05, 0.012, -0.030), SIMD3<Float>(-0.23, 0.012, -0.17)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.05, 0.012, -0.030), SIMD3<Float>(0.23, 0.012, -0.17))
        ]

        var propellers: [SCNNode] = []
        for (index, arm) in armTips.enumerated() {
            let beam = beamNode(start: arm.3, end: arm.4, radius: 0.010, material: armMaterial)
            root.addChildNode(beam)
            append(beam, to: arm.0, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.018, height: 0.016, material: armMaterial)
            motor.position = SCNVector3(arm.4.x, arm.4.y, arm.4.z)
            root.addChildNode(motor)
            append(motor, to: arm.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.085)
            propeller.position = SCNVector3(arm.4.x, arm.4.y + 0.014, arm.4.z)
            propeller.name = "propeller.mavic4.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: arm.2, componentNodes: &componentNodes)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: [1.0, -1.0, -1.0, 1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildDJINeo(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.djiNeo"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.72, green: 0.73, blue: 0.75, alpha: 1.0), roughness: 0.34, metalness: 0.20)
        let guardMaterial = material(diffuse: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0), roughness: 0.46, metalness: 0.18)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0), roughness: 0.24, metalness: 0.56)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.80), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let body = boxNode(size: SIMD3<Float>(0.11, 0.034, 0.085), chamfer: 0.012, material: bodyMaterial)
        body.position = SCNVector3(0.0, 0.0, 0.0)
        root.addChildNode(body)
        append(body, to: .flightControllerCore, componentNodes: &componentNodes)

        let topModule = boxNode(size: SIMD3<Float>(0.07, 0.020, 0.05), chamfer: 0.008, material: accentMaterial)
        topModule.position = SCNVector3(0.0, 0.022, -0.01)
        root.addChildNode(topModule)
        append(topModule, to: .battery, componentNodes: &componentNodes)

        let cameraBlock = boxNode(size: SIMD3<Float>(0.055, 0.022, 0.038), chamfer: 0.008, material: accentMaterial)
        cameraBlock.position = SCNVector3(0.0, -0.016, 0.050)
        root.addChildNode(cameraBlock)
        append(cameraBlock, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.015, 0.074)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let ringPositions: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.085, 0.0, 0.060)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.085, 0.0, 0.060)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.085, 0.0, -0.060)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.085, 0.0, -0.060))
        ]

        var propellers: [SCNNode] = []
        for (index, ringData) in ringPositions.enumerated() {
            let support = beamNode(start: SIMD3<Float>(0.0, 0.0, 0.0), end: ringData.3, radius: 0.008, material: guardMaterial)
            root.addChildNode(support)
            append(support, to: ringData.0, componentNodes: &componentNodes)

            let guardRing = torusNode(ringRadius: 0.052, pipeRadius: 0.006, material: guardMaterial)
            guardRing.position = SCNVector3(ringData.3.x, ringData.3.y, ringData.3.z)
            root.addChildNode(guardRing)
            append(guardRing, to: ringData.0, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.013, height: 0.014, material: accentMaterial)
            motor.position = SCNVector3(ringData.3.x, 0.0, ringData.3.z)
            root.addChildNode(motor)
            append(motor, to: ringData.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.042)
            propeller.position = SCNVector3(ringData.3.x, 0.010, ringData.3.z)
            propeller.name = "propeller.neo.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: ringData.2, componentNodes: &componentNodes)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: [1.0, -1.0, -1.0, 1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildDJIPhantom3Standard(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.djiPhantom3Standard"

        let shellMaterial = material(diffuse: NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0), roughness: 0.28, metalness: 0.08)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.85, green: 0.87, blue: 0.90, alpha: 1.0), roughness: 0.30, metalness: 0.10)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.15, green: 0.18, blue: 0.22, alpha: 1.0), roughness: 0.24, metalness: 0.50)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.95, alpha: 0.82), roughness: 0.24, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let body = sphereNode(radius: 0.085, material: shellMaterial)
        body.scale = SCNVector3(1.05, 0.48, 1.00)
        body.position = SCNVector3(0.0, 0.02, 0.0)
        root.addChildNode(body)
        append(body, to: .flightControllerCore, componentNodes: &componentNodes)

        let topShell = boxNode(size: SIMD3<Float>(0.12, 0.032, 0.09), chamfer: 0.012, material: shellMaterial)
        topShell.position = SCNVector3(0.0, 0.056, -0.015)
        root.addChildNode(topShell)
        append(topShell, to: .battery, componentNodes: &componentNodes)

        let cameraFrame = boxNode(size: SIMD3<Float>(0.060, 0.032, 0.040), chamfer: 0.008, material: accentMaterial)
        cameraFrame.position = SCNVector3(0.0, -0.080, 0.075)
        root.addChildNode(cameraFrame)
        append(cameraFrame, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let cameraLens = sphereNode(radius: 0.018, material: accentMaterial)
        cameraLens.scale = SCNVector3(1.0, 0.9, 1.1)
        cameraLens.position = SCNVector3(0.0, -0.086, 0.102)
        root.addChildNode(cameraLens)
        append(cameraLens, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.082, 0.115)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let armTips: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.22, 0.045, 0.18)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.22, 0.045, 0.18)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.22, 0.045, -0.18)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.22, 0.045, -0.18))
        ]

        var propellers: [SCNNode] = []
        for (index, arm) in armTips.enumerated() {
            let beam = beamNode(start: SIMD3<Float>(0.0, 0.032, 0.0), end: arm.3, radius: 0.012, material: armMaterial)
            root.addChildNode(beam)
            append(beam, to: arm.0, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.020, height: 0.018, material: armMaterial)
            motor.position = SCNVector3(arm.3.x, arm.3.y, arm.3.z)
            root.addChildNode(motor)
            append(motor, to: arm.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.095)
            propeller.position = SCNVector3(arm.3.x, arm.3.y + 0.014, arm.3.z)
            propeller.name = "propeller.phantom3.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: arm.2, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let frontLeg = beamNode(
                start: SIMD3<Float>(0.12 * side, -0.01, 0.08),
                end: SIMD3<Float>(0.16 * side, -0.22, 0.10),
                radius: 0.010,
                material: armMaterial
            )
            let rearLeg = beamNode(
                start: SIMD3<Float>(0.10 * side, -0.01, -0.04),
                end: SIMD3<Float>(0.14 * side, -0.22, -0.02),
                radius: 0.010,
                material: armMaterial
            )
            let skid = beamNode(
                start: SIMD3<Float>(0.16 * side, -0.22, -0.06),
                end: SIMD3<Float>(0.16 * side, -0.22, 0.14),
                radius: 0.008,
                material: armMaterial
            )
            root.addChildNode(frontLeg)
            root.addChildNode(rearLeg)
            root.addChildNode(skid)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: [1.0, -1.0, -1.0, 1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildFreeflyAltaX(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.freeflyAltaX"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0), roughness: 0.44, metalness: 0.34)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.31, alpha: 1.0), roughness: 0.36, metalness: 0.42)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.89, green: 0.35, blue: 0.12, alpha: 1.0), roughness: 0.28, metalness: 0.16)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let centerPlate = cylinderNode(radius: 0.16, height: 0.030, material: frameMaterial)
        centerPlate.position = SCNVector3(0.0, 0.04, 0.0)
        root.addChildNode(centerPlate)
        append(centerPlate, to: .flightControllerCore, componentNodes: &componentNodes)

        let centerSpine = boxNode(size: SIMD3<Float>(0.18, 0.11, 0.18), chamfer: 0.012, material: carbonMaterial)
        centerSpine.position = SCNVector3(0.0, -0.01, 0.0)
        root.addChildNode(centerSpine)
        append(centerSpine, to: .battery, componentNodes: &componentNodes)

        let lowerCradle = boxNode(size: SIMD3<Float>(0.22, 0.04, 0.22), chamfer: 0.010, material: accentMaterial)
        lowerCradle.position = SCNVector3(0.0, -0.13, 0.0)
        root.addChildNode(lowerCradle)
        append(lowerCradle, to: .escPower, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.03, 0.16)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let armTips: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.58, 0.08, 0.58)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.58, 0.08, 0.58)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.58, 0.08, -0.58)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.58, 0.08, -0.58))
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0]

        for (index, armTip) in armTips.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.04, 0.0), end: armTip.3, radius: 0.024, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: armTip.0, componentNodes: &componentNodes)

            let knuckle = sphereNode(radius: 0.040, material: frameMaterial)
            knuckle.position = SCNVector3(armTip.3.x * 0.72, armTip.3.y * 0.72, armTip.3.z * 0.72)
            root.addChildNode(knuckle)

            let upperMotor = cylinderNode(radius: 0.046, height: 0.034, material: frameMaterial)
            upperMotor.position = SCNVector3(armTip.3.x, armTip.3.y + 0.040, armTip.3.z)
            root.addChildNode(upperMotor)
            append(upperMotor, to: armTip.1, componentNodes: &componentNodes)

            let lowerMotor = cylinderNode(radius: 0.046, height: 0.034, material: frameMaterial)
            lowerMotor.position = SCNVector3(armTip.3.x, armTip.3.y - 0.010, armTip.3.z)
            root.addChildNode(lowerMotor)
            append(lowerMotor, to: armTip.1, componentNodes: &componentNodes)

            let upperPropeller = topPropellerNode(material: rotorMaterial, radius: 0.17)
            upperPropeller.position = SCNVector3(armTip.3.x, armTip.3.y + 0.072, armTip.3.z)
            upperPropeller.name = "propeller.altax.upper.\(index)"
            root.addChildNode(upperPropeller)
            propellers.append(upperPropeller)
            append(upperPropeller, to: armTip.2, componentNodes: &componentNodes)

            let lowerPropeller = topPropellerNode(material: rotorMaterial, radius: 0.17)
            lowerPropeller.position = SCNVector3(armTip.3.x, armTip.3.y - 0.040, armTip.3.z)
            lowerPropeller.name = "propeller.altax.lower.\(index)"
            root.addChildNode(lowerPropeller)
            propellers.append(lowerPropeller)
            append(lowerPropeller, to: armTip.2, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let skidFront = beamNode(
                start: SIMD3<Float>(0.30 * side, -0.04, 0.20),
                end: SIMD3<Float>(0.44 * side, -0.28, 0.20),
                radius: 0.014,
                material: accentMaterial
            )
            let skidRear = beamNode(
                start: SIMD3<Float>(0.30 * side, -0.04, -0.20),
                end: SIMD3<Float>(0.44 * side, -0.28, -0.20),
                radius: 0.014,
                material: accentMaterial
            )
            let rail = beamNode(
                start: SIMD3<Float>(0.44 * side, -0.28, -0.24),
                end: SIMD3<Float>(0.44 * side, -0.28, 0.24),
                radius: 0.012,
                material: accentMaterial
            )
            root.addChildNode(skidFront)
            root.addChildNode(skidRear)
            root.addChildNode(rail)
        }

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildWingtraOneGenII(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.wingtraOneGenII"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.86, green: 0.87, blue: 0.89, alpha: 1.0), roughness: 0.34, metalness: 0.18)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.33, alpha: 1.0), roughness: 0.42, metalness: 0.26)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.24, alpha: 1.0), roughness: 0.30, metalness: 0.40)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.78, radius: 0.036, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let canopy = sphereNode(radius: 0.050, material: accentMaterial)
        canopy.scale = SCNVector3(1.0, 0.42, 1.8)
        canopy.position = SCNVector3(0.0, 0.014, 0.12)
        root.addChildNode(canopy)

        let wing = planformNode(
            points: [
                CGPoint(x: -0.64, y: 0.06),
                CGPoint(x: -0.20, y: 0.15),
                CGPoint(x: 0.20, y: 0.15),
                CGPoint(x: 0.64, y: 0.06),
                CGPoint(x: 0.50, y: -0.16),
                CGPoint(x: -0.50, y: -0.16)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.018, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let leftFin = verticalSurfaceNode(
            points: [
                CGPoint(x: -0.02, y: 0.0),
                CGPoint(x: 0.08, y: 0.0),
                CGPoint(x: 0.03, y: 0.18),
                CGPoint(x: -0.01, y: 0.16)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.40, 0.02, -0.24)
        root.addChildNode(leftFin)
        append(leftFin, to: .armRL, componentNodes: &componentNodes)

        let rightFin = leftFin.clone()
        rightFin.position.x = 0.40
        root.addChildNode(rightFin)
        append(rightFin, to: .armRR, componentNodes: &componentNodes)

        let bellyPod = boxNode(size: SIMD3<Float>(0.11, 0.05, 0.24), chamfer: 0.010, material: accentMaterial)
        bellyPod.position = SCNVector3(0.0, -0.035, 0.05)
        root.addChildNode(bellyPod)
        append(bellyPod, to: .battery, componentNodes: &componentNodes)

        let leftPylon = boxNode(size: SIMD3<Float>(0.028, 0.10, 0.032), chamfer: 0.006, material: accentMaterial)
        leftPylon.position = SCNVector3(-0.29, 0.056, 0.10)
        root.addChildNode(leftPylon)
        append(leftPylon, to: .escPower, componentNodes: &componentNodes)

        let rightPylon = leftPylon.clone()
        rightPylon.position.x = 0.29
        root.addChildNode(rightPylon)
        append(rightPylon, to: .escPower, componentNodes: &componentNodes)

        let leftMotor = forwardMotorNode(radius: 0.020, length: 0.050, material: accentMaterial)
        leftMotor.position = SCNVector3(-0.29, 0.060, 0.14)
        root.addChildNode(leftMotor)
        append(leftMotor, to: .motorFL, componentNodes: &componentNodes)

        let rightMotor = forwardMotorNode(radius: 0.020, length: 0.050, material: accentMaterial)
        rightMotor.position = SCNVector3(0.29, 0.060, 0.14)
        root.addChildNode(rightMotor)
        append(rightMotor, to: .motorFR, componentNodes: &componentNodes)

        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)
        let leftProp = forwardPropellerNode(material: rotorMaterial, radius: 0.13)
        leftProp.position = SCNVector3(-0.29, 0.060, 0.18)
        root.addChildNode(leftProp)
        append(leftProp, to: .propellerFL, componentNodes: &componentNodes)

        let rightProp = forwardPropellerNode(material: rotorMaterial, radius: 0.13)
        rightProp.position = SCNVector3(0.29, 0.060, 0.18)
        root.addChildNode(rightProp)
        append(rightProp, to: .propellerFR, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.0, 0.39)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [leftProp, rightProp],
            propellerSpinDirections: [1.0, -1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildQuantumSystemsTrinityPro(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.quantumSystemsTrinityPro"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.87, green: 0.88, blue: 0.90, alpha: 1.0), roughness: 0.34, metalness: 0.18)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.20, green: 0.24, blue: 0.30, alpha: 1.0), roughness: 0.42, metalness: 0.28)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.14, green: 0.17, blue: 0.21, alpha: 1.0), roughness: 0.30, metalness: 0.44)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.08, radius: 0.050, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let noseCompartment = boxNode(size: SIMD3<Float>(0.16, 0.08, 0.34), chamfer: 0.012, material: accentMaterial)
        noseCompartment.position = SCNVector3(0.0, -0.03, 0.12)
        root.addChildNode(noseCompartment)
        append(noseCompartment, to: .battery, componentNodes: &componentNodes)

        let wing = planformNode(
            points: [
                CGPoint(x: -1.18, y: 0.10),
                CGPoint(x: -0.34, y: 0.22),
                CGPoint(x: 0.34, y: 0.22),
                CGPoint(x: 1.18, y: 0.10),
                CGPoint(x: 0.98, y: -0.18),
                CGPoint(x: -0.98, y: -0.18)
            ],
            thickness: 0.028,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.024, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let leftBoom = horizontalCapsule(length: 0.72, radius: 0.022, material: accentMaterial)
        leftBoom.position = SCNVector3(-0.34, 0.012, -0.18)
        root.addChildNode(leftBoom)
        append(leftBoom, to: .armRL, componentNodes: &componentNodes)

        let rightBoom = horizontalCapsule(length: 0.72, radius: 0.022, material: accentMaterial)
        rightBoom.position = SCNVector3(0.34, 0.012, -0.18)
        root.addChildNode(rightBoom)
        append(rightBoom, to: .armRR, componentNodes: &componentNodes)

        let tailPlane = planformNode(
            points: [
                CGPoint(x: -0.34, y: 0.04),
                CGPoint(x: 0.34, y: 0.04),
                CGPoint(x: 0.28, y: -0.08),
                CGPoint(x: -0.28, y: -0.08)
            ],
            thickness: 0.018,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.072, -0.54)
        root.addChildNode(tailPlane)

        let leftFin = verticalSurfaceNode(
            points: [
                CGPoint(x: -0.02, y: 0.0),
                CGPoint(x: 0.12, y: 0.0),
                CGPoint(x: 0.04, y: 0.22),
                CGPoint(x: -0.01, y: 0.18)
            ],
            thickness: 0.014,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.34, 0.072, -0.58)
        root.addChildNode(leftFin)

        let rightFin = leftFin.clone()
        rightFin.position.x = 0.34
        root.addChildNode(rightFin)

        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)
        let podPositions: [(SIMD3<Float>, DamageComponent, DamageComponent)] = [
            (SIMD3<Float>(-0.56, 0.10, 0.13), .motorFL, .propellerFL),
            (SIMD3<Float>(0.56, 0.10, 0.13), .motorFR, .propellerFR),
            (SIMD3<Float>(-0.56, 0.10, -0.15), .motorRL, .propellerRL),
            (SIMD3<Float>(0.56, 0.10, -0.15), .motorRR, .propellerRR)
        ]

        var props: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0]

        for (index, pod) in podPositions.enumerated() {
            let mast = boxNode(size: SIMD3<Float>(0.034, 0.10, 0.034), chamfer: 0.006, material: accentMaterial)
            mast.position = SCNVector3(pod.0.x, 0.054, pod.0.z)
            root.addChildNode(mast)

            let motor = cylinderNode(radius: 0.022, height: 0.026, material: accentMaterial)
            motor.position = SCNVector3(pod.0.x, pod.0.y, pod.0.z)
            root.addChildNode(motor)
            append(motor, to: pod.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.13)
            propeller.position = SCNVector3(pod.0.x, pod.0.y + 0.020, pod.0.z)
            propeller.name = "propeller.trinity.\(index)"
            root.addChildNode(propeller)
            props.append(propeller)
            append(propeller, to: pod.2, componentNodes: &componentNodes)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.0, 0.56)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: props,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildDJIFlyCart30(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.djiFlyCart30"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.33, alpha: 1.0), roughness: 0.36, metalness: 0.44)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.16, alpha: 1.0), roughness: 0.44, metalness: 0.32)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.82, green: 0.58, blue: 0.14, alpha: 1.0), roughness: 0.28, metalness: 0.18)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let coreBody = boxNode(size: SIMD3<Float>(0.46, 0.16, 0.32), chamfer: 0.020, material: bodyMaterial)
        coreBody.position = SCNVector3(0.0, 0.04, 0.0)
        root.addChildNode(coreBody)
        append(coreBody, to: .flightControllerCore, componentNodes: &componentNodes)

        let batterySection = boxNode(size: SIMD3<Float>(0.36, 0.12, 0.24), chamfer: 0.016, material: accentMaterial)
        batterySection.position = SCNVector3(0.0, 0.14, -0.02)
        root.addChildNode(batterySection)
        append(batterySection, to: .battery, componentNodes: &componentNodes)

        let cargoBay = boxNode(size: SIMD3<Float>(0.30, 0.14, 0.28), chamfer: 0.012, material: armMaterial)
        cargoBay.position = SCNVector3(0.0, -0.14, 0.0)
        root.addChildNode(cargoBay)
        append(cargoBay, to: .escPower, componentNodes: &componentNodes)

        let frontBulkhead = boxNode(size: SIMD3<Float>(0.30, 0.03, 0.02), chamfer: 0.006, material: accentMaterial)
        frontBulkhead.position = SCNVector3(0.0, -0.20, 0.14)
        root.addChildNode(frontBulkhead)

        let rearBulkhead = frontBulkhead.clone()
        rearBulkhead.position.z = -0.14
        root.addChildNode(rearBulkhead)

        let armTips: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.58, 0.14, 0.40)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.58, 0.14, 0.40)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.58, 0.14, -0.40)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.58, 0.14, -0.40))
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0]

        for (index, armTip) in armTips.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.08, 0.0), end: armTip.3, radius: 0.026, material: armMaterial)
            root.addChildNode(arm)
            append(arm, to: armTip.0, componentNodes: &componentNodes)

            let upperMotor = cylinderNode(radius: 0.048, height: 0.040, material: armMaterial)
            upperMotor.position = SCNVector3(armTip.3.x, armTip.3.y + 0.06, armTip.3.z)
            root.addChildNode(upperMotor)
            append(upperMotor, to: armTip.1, componentNodes: &componentNodes)

            let lowerMotor = cylinderNode(radius: 0.048, height: 0.040, material: armMaterial)
            lowerMotor.position = SCNVector3(armTip.3.x, armTip.3.y, armTip.3.z)
            root.addChildNode(lowerMotor)
            append(lowerMotor, to: armTip.1, componentNodes: &componentNodes)

            let upperProp = topPropellerNode(material: rotorMaterial, radius: 0.22)
            upperProp.position = SCNVector3(armTip.3.x, armTip.3.y + 0.094, armTip.3.z)
            upperProp.name = "propeller.flycart.upper.\(index)"
            root.addChildNode(upperProp)
            propellers.append(upperProp)
            append(upperProp, to: armTip.2, componentNodes: &componentNodes)

            let lowerProp = topPropellerNode(material: rotorMaterial, radius: 0.22)
            lowerProp.position = SCNVector3(armTip.3.x, armTip.3.y - 0.022, armTip.3.z)
            lowerProp.name = "propeller.flycart.lower.\(index)"
            root.addChildNode(lowerProp)
            propellers.append(lowerProp)
            append(lowerProp, to: armTip.2, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let forwardLeg = beamNode(
                start: SIMD3<Float>(0.26 * side, -0.02, 0.20),
                end: SIMD3<Float>(0.36 * side, -0.34, 0.20),
                radius: 0.018,
                material: accentMaterial
            )
            let aftLeg = beamNode(
                start: SIMD3<Float>(0.26 * side, -0.02, -0.20),
                end: SIMD3<Float>(0.36 * side, -0.34, -0.20),
                radius: 0.018,
                material: accentMaterial
            )
            let skid = beamNode(
                start: SIMD3<Float>(0.36 * side, -0.34, -0.26),
                end: SIMD3<Float>(0.36 * side, -0.34, 0.26),
                radius: 0.016,
                material: accentMaterial
            )
            root.addChildNode(forwardLeg)
            root.addChildNode(aftLeg)
            root.addChildNode(skid)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.03, 0.22)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildGriff30(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.griff30"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0), roughness: 0.44, metalness: 0.34)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.33, green: 0.34, blue: 0.36, alpha: 1.0), roughness: 0.36, metalness: 0.42)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.75, green: 0.14, blue: 0.12, alpha: 1.0), roughness: 0.30, metalness: 0.18)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let topFrame = torusNode(ringRadius: 0.24, pipeRadius: 0.020, material: frameMaterial)
        topFrame.position = SCNVector3(0.0, 0.06, 0.0)
        root.addChildNode(topFrame)
        append(topFrame, to: .flightControllerCore, componentNodes: &componentNodes)

        let centerSection = boxNode(size: SIMD3<Float>(0.22, 0.12, 0.22), chamfer: 0.012, material: carbonMaterial)
        centerSection.position = SCNVector3(0.0, 0.0, 0.0)
        root.addChildNode(centerSection)
        append(centerSection, to: .battery, componentNodes: &componentNodes)

        let loadDeck = boxNode(size: SIMD3<Float>(0.26, 0.05, 0.26), chamfer: 0.010, material: accentMaterial)
        loadDeck.position = SCNVector3(0.0, -0.14, 0.0)
        root.addChildNode(loadDeck)
        append(loadDeck, to: .escPower, componentNodes: &componentNodes)

        let rotorPoints: [(SIMD3<Float>, DamageComponent, DamageComponent, DamageComponent)] = [
            (SIMD3<Float>(0.00, 0.12, 0.72), .armFL, .motorFL, .propellerFL),
            (SIMD3<Float>(0.51, 0.12, 0.51), .armFR, .motorFR, .propellerFR),
            (SIMD3<Float>(0.72, 0.12, 0.00), .armFR, .motorFR, .propellerFR),
            (SIMD3<Float>(0.51, 0.12, -0.51), .armRR, .motorRR, .propellerRR),
            (SIMD3<Float>(0.00, 0.12, -0.72), .armRR, .motorRR, .propellerRR),
            (SIMD3<Float>(-0.51, 0.12, -0.51), .armRL, .motorRL, .propellerRL),
            (SIMD3<Float>(-0.72, 0.12, 0.00), .armRL, .motorRL, .propellerRL),
            (SIMD3<Float>(-0.51, 0.12, 0.51), .armFL, .motorFL, .propellerFL)
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0]

        for (index, rotor) in rotorPoints.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.04, 0.0), end: rotor.0, radius: 0.020, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: rotor.1, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.044, height: 0.036, material: frameMaterial)
            motor.position = SCNVector3(rotor.0.x, rotor.0.y, rotor.0.z)
            root.addChildNode(motor)
            append(motor, to: rotor.2, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.19)
            propeller.position = SCNVector3(rotor.0.x, rotor.0.y + 0.030, rotor.0.z)
            propeller.name = "propeller.griff30.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: rotor.3, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let leftRail = beamNode(
                start: SIMD3<Float>(0.34 * side, -0.02, 0.24),
                end: SIMD3<Float>(0.46 * side, -0.30, 0.24),
                radius: 0.015,
                material: accentMaterial
            )
            let rightRail = beamNode(
                start: SIMD3<Float>(0.34 * side, -0.02, -0.24),
                end: SIMD3<Float>(0.46 * side, -0.30, -0.24),
                radius: 0.015,
                material: accentMaterial
            )
            let crossRail = beamNode(
                start: SIMD3<Float>(0.46 * side, -0.30, -0.28),
                end: SIMD3<Float>(0.46 * side, -0.30, 0.28),
                radius: 0.013,
                material: accentMaterial
            )
            root.addChildNode(leftRail)
            root.addChildNode(rightRail)
            root.addChildNode(crossRail)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.03, 0.20)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildGriff60(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.griff60"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0), roughness: 0.46, metalness: 0.34)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.31, alpha: 1.0), roughness: 0.36, metalness: 0.40)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.79, green: 0.18, blue: 0.14, alpha: 1.0), roughness: 0.30, metalness: 0.18)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let upperRing = torusNode(ringRadius: 0.34, pipeRadius: 0.026, material: frameMaterial)
        upperRing.position = SCNVector3(0.0, 0.10, 0.0)
        root.addChildNode(upperRing)
        append(upperRing, to: .flightControllerCore, componentNodes: &componentNodes)

        let lowerRing = torusNode(ringRadius: 0.24, pipeRadius: 0.022, material: carbonMaterial)
        lowerRing.position = SCNVector3(0.0, -0.02, 0.0)
        root.addChildNode(lowerRing)
        append(lowerRing, to: .battery, componentNodes: &componentNodes)

        let centerSection = boxNode(size: SIMD3<Float>(0.30, 0.18, 0.30), chamfer: 0.016, material: carbonMaterial)
        centerSection.position = SCNVector3(0.0, 0.02, 0.0)
        root.addChildNode(centerSection)
        append(centerSection, to: .battery, componentNodes: &componentNodes)

        let cargoDeck = boxNode(size: SIMD3<Float>(0.34, 0.08, 0.34), chamfer: 0.012, material: accentMaterial)
        cargoDeck.position = SCNVector3(0.0, -0.20, 0.0)
        root.addChildNode(cargoDeck)
        append(cargoDeck, to: .escPower, componentNodes: &componentNodes)

        let rotorPoints: [(SIMD3<Float>, DamageComponent, DamageComponent, DamageComponent)] = [
            (SIMD3<Float>(0.00, 0.16, 0.96), .armFL, .motorFL, .propellerFL),
            (SIMD3<Float>(0.68, 0.16, 0.68), .armFR, .motorFR, .propellerFR),
            (SIMD3<Float>(0.96, 0.16, 0.00), .armFR, .motorFR, .propellerFR),
            (SIMD3<Float>(0.68, 0.16, -0.68), .armRR, .motorRR, .propellerRR),
            (SIMD3<Float>(0.00, 0.16, -0.96), .armRR, .motorRR, .propellerRR),
            (SIMD3<Float>(-0.68, 0.16, -0.68), .armRL, .motorRL, .propellerRL),
            (SIMD3<Float>(-0.96, 0.16, 0.00), .armRL, .motorRL, .propellerRL),
            (SIMD3<Float>(-0.68, 0.16, 0.68), .armFL, .motorFL, .propellerFL)
        ]

        var propellers: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0]

        for (index, rotor) in rotorPoints.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.06, 0.0), end: rotor.0, radius: 0.024, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: rotor.1, componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.054, height: 0.042, material: frameMaterial)
            motor.position = SCNVector3(rotor.0.x, rotor.0.y, rotor.0.z)
            root.addChildNode(motor)
            append(motor, to: rotor.2, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.24)
            propeller.position = SCNVector3(rotor.0.x, rotor.0.y + 0.034, rotor.0.z)
            propeller.name = "propeller.griff60.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            append(propeller, to: rotor.3, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let outerFront = beamNode(
                start: SIMD3<Float>(0.40 * side, -0.02, 0.28),
                end: SIMD3<Float>(0.58 * side, -0.38, 0.30),
                radius: 0.018,
                material: accentMaterial
            )
            let outerRear = beamNode(
                start: SIMD3<Float>(0.40 * side, -0.02, -0.28),
                end: SIMD3<Float>(0.58 * side, -0.38, -0.30),
                radius: 0.018,
                material: accentMaterial
            )
            let skid = beamNode(
                start: SIMD3<Float>(0.58 * side, -0.38, -0.36),
                end: SIMD3<Float>(0.58 * side, -0.38, 0.36),
                radius: 0.016,
                material: accentMaterial
            )
            root.addChildNode(outerFront)
            root.addChildNode(outerRear)
            root.addChildNode(skid)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.04, 0.24)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellers,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildAvidrone490TL(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.avidrone490TL"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.39, alpha: 1.0), roughness: 0.36, metalness: 0.44)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1.0), roughness: 0.42, metalness: 0.30)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.82, green: 0.31, blue: 0.12, alpha: 1.0), roughness: 0.28, metalness: 0.18)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = boxNode(size: SIMD3<Float>(0.20, 0.12, 0.92), chamfer: 0.018, material: bodyMaterial)
        fuselage.position = SCNVector3(0.0, -0.02, 0.0)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let upperSpine = boxNode(size: SIMD3<Float>(0.12, 0.10, 0.78), chamfer: 0.012, material: armMaterial)
        upperSpine.position = SCNVector3(0.0, 0.07, 0.0)
        root.addChildNode(upperSpine)
        append(upperSpine, to: .battery, componentNodes: &componentNodes)

        let cargoPod = boxNode(size: SIMD3<Float>(0.18, 0.10, 0.28), chamfer: 0.012, material: accentMaterial)
        cargoPod.position = SCNVector3(0.0, -0.15, 0.04)
        root.addChildNode(cargoPod)
        append(cargoPod, to: .escPower, componentNodes: &componentNodes)

        let frontMast = boxNode(size: SIMD3<Float>(0.08, 0.18, 0.10), chamfer: 0.008, material: armMaterial)
        frontMast.position = SCNVector3(0.0, 0.18, 0.34)
        root.addChildNode(frontMast)
        append(frontMast, to: .armFL, componentNodes: &componentNodes)

        let rearMast = boxNode(size: SIMD3<Float>(0.08, 0.18, 0.10), chamfer: 0.008, material: armMaterial)
        rearMast.position = SCNVector3(0.0, 0.18, -0.34)
        root.addChildNode(rearMast)
        append(rearMast, to: .armRR, componentNodes: &componentNodes)

        let frontHead = cylinderNode(radius: 0.12, height: 0.040, material: armMaterial)
        frontHead.position = SCNVector3(0.0, 0.28, 0.34)
        root.addChildNode(frontHead)
        append(frontHead, to: .motorFL, componentNodes: &componentNodes)

        let rearHead = cylinderNode(radius: 0.12, height: 0.040, material: armMaterial)
        rearHead.position = SCNVector3(0.0, 0.28, -0.34)
        root.addChildNode(rearHead)
        append(rearHead, to: .motorRR, componentNodes: &componentNodes)

        let frontRotor = topPropellerNode(material: rotorMaterial, radius: 0.28)
        frontRotor.position = SCNVector3(0.0, 0.31, 0.34)
        frontRotor.name = "propeller.avidrone.front"
        root.addChildNode(frontRotor)
        append(frontRotor, to: .propellerFL, componentNodes: &componentNodes)

        let rearRotor = topPropellerNode(material: rotorMaterial, radius: 0.28)
        rearRotor.position = SCNVector3(0.0, 0.31, -0.34)
        rearRotor.name = "propeller.avidrone.rear"
        root.addChildNode(rearRotor)
        append(rearRotor, to: .propellerRR, componentNodes: &componentNodes)

        for side: Float in [-1.0, 1.0] {
            let foreLeg = beamNode(
                start: SIMD3<Float>(0.08 * side, -0.02, 0.18),
                end: SIMD3<Float>(0.18 * side, -0.24, 0.18),
                radius: 0.014,
                material: accentMaterial
            )
            let aftLeg = beamNode(
                start: SIMD3<Float>(0.08 * side, -0.02, -0.18),
                end: SIMD3<Float>(0.18 * side, -0.24, -0.18),
                radius: 0.014,
                material: accentMaterial
            )
            let skid = beamNode(
                start: SIMD3<Float>(0.18 * side, -0.24, -0.28),
                end: SIMD3<Float>(0.18 * side, -0.24, 0.28),
                radius: 0.012,
                material: accentMaterial
            )
            root.addChildNode(foreLeg)
            root.addChildNode(aftLeg)
            root.addChildNode(skid)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.03, 0.42)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [frontRotor, rearRotor],
            propellerSpinDirections: [1.0, -1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildMQ9BSkyGuardian(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.mq9bSkyGuardian"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.83, alpha: 1.0), roughness: 0.32, metalness: 0.16)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.45, green: 0.49, blue: 0.54, alpha: 1.0), roughness: 0.40, metalness: 0.28)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.18, green: 0.21, blue: 0.25, alpha: 1.0), roughness: 0.28, metalness: 0.46)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.80), roughness: 0.20, metalness: 0.10)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.52, radius: 0.060, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let noseCone = sphereNode(radius: 0.064, material: bodyMaterial)
        noseCone.scale = SCNVector3(1.0, 0.9, 1.5)
        noseCone.position = SCNVector3(0.0, 0.0, 0.70)
        root.addChildNode(noseCone)

        let wing = planformNode(
            points: [
                CGPoint(x: -1.40, y: 0.06),
                CGPoint(x: -0.46, y: 0.18),
                CGPoint(x: 0.46, y: 0.18),
                CGPoint(x: 1.40, y: 0.06),
                CGPoint(x: 1.18, y: -0.10),
                CGPoint(x: -1.18, y: -0.10)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.032, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let rearSpine = horizontalCapsule(length: 0.38, radius: 0.032, material: accentMaterial)
        rearSpine.position = SCNVector3(0.0, 0.04, -0.64)
        root.addChildNode(rearSpine)
        append(rearSpine, to: .battery, componentNodes: &componentNodes)

        let leftTail = SCNNode()
        leftTail.position = SCNVector3(-0.16, 0.12, -0.78)
        leftTail.eulerAngles = SCNVector3(-Float.pi / 6.0, 0.0, -Float.pi / 6.5)
        leftTail.addChildNode(verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.28, y: 0.0),
                CGPoint(x: 0.10, y: 0.26)
            ],
            thickness: 0.012,
            material: wingMaterial
        ))
        root.addChildNode(leftTail)
        append(leftTail, to: .armRL, componentNodes: &componentNodes)

        let rightTail = SCNNode()
        rightTail.position = SCNVector3(0.16, 0.12, -0.78)
        rightTail.eulerAngles = SCNVector3(Float.pi / 6.0, Float.pi, -Float.pi / 6.5)
        rightTail.addChildNode(verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.28, y: 0.0),
                CGPoint(x: 0.10, y: 0.26)
            ],
            thickness: 0.012,
            material: wingMaterial
        ))
        root.addChildNode(rightTail)
        append(rightTail, to: .armRR, componentNodes: &componentNodes)

        let sensorBall = sphereNode(radius: 0.055, material: accentMaterial)
        sensorBall.scale = SCNVector3(1.0, 0.92, 1.0)
        sensorBall.position = SCNVector3(0.0, -0.085, 0.34)
        root.addChildNode(sensorBall)
        append(sensorBall, to: .escPower, componentNodes: &componentNodes)

        let rearMotor = forwardMotorNode(radius: 0.030, length: 0.080, material: accentMaterial)
        rearMotor.position = SCNVector3(0.0, 0.04, -0.80)
        root.addChildNode(rearMotor)
        append(rearMotor, to: .motorRR, componentNodes: &componentNodes)

        let rearProp = forwardPropellerNode(material: rotorMaterial, radius: 0.18)
        rearProp.position = SCNVector3(0.0, 0.04, -0.86)
        rearProp.name = "propeller.mq9b.rear"
        root.addChildNode(rearProp)
        append(rearProp, to: .propellerRR, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.03, 0.72)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [rearProp],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildHermes900(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.hermes900"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.84, alpha: 1.0), roughness: 0.32, metalness: 0.14)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.34, green: 0.38, blue: 0.43, alpha: 1.0), roughness: 0.42, metalness: 0.24)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.21, alpha: 1.0), roughness: 0.30, metalness: 0.46)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.80), roughness: 0.20, metalness: 0.10)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.12, radius: 0.050, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let wing = planformNode(
            points: [
                CGPoint(x: -1.10, y: 0.04),
                CGPoint(x: -0.34, y: 0.12),
                CGPoint(x: 0.34, y: 0.12),
                CGPoint(x: 1.10, y: 0.04),
                CGPoint(x: 0.94, y: -0.08),
                CGPoint(x: -0.94, y: -0.08)
            ],
            thickness: 0.020,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.035, 0.05)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let leftBoom = horizontalCapsule(length: 0.84, radius: 0.020, material: accentMaterial)
        leftBoom.position = SCNVector3(-0.28, 0.02, -0.24)
        root.addChildNode(leftBoom)
        append(leftBoom, to: .armRL, componentNodes: &componentNodes)

        let rightBoom = horizontalCapsule(length: 0.84, radius: 0.020, material: accentMaterial)
        rightBoom.position = SCNVector3(0.28, 0.02, -0.24)
        root.addChildNode(rightBoom)
        append(rightBoom, to: .armRR, componentNodes: &componentNodes)

        let tailPlane = planformNode(
            points: [
                CGPoint(x: -0.38, y: 0.02),
                CGPoint(x: 0.38, y: 0.02),
                CGPoint(x: 0.30, y: -0.08),
                CGPoint(x: -0.30, y: -0.08)
            ],
            thickness: 0.016,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.05, -0.66)
        root.addChildNode(tailPlane)

        let leftFin = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.18, y: 0.0),
                CGPoint(x: 0.06, y: 0.24)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.28, 0.05, -0.70)
        root.addChildNode(leftFin)

        let rightFin = SCNNode()
        rightFin.position = SCNVector3(0.28, 0.05, -0.70)
        rightFin.eulerAngles = SCNVector3(0.0, Float.pi, 0.0)
        rightFin.addChildNode(verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.18, y: 0.0),
                CGPoint(x: 0.06, y: 0.24)
            ],
            thickness: 0.012,
            material: wingMaterial
        ))
        root.addChildNode(rightFin)

        let noseSensor = sphereNode(radius: 0.042, material: accentMaterial)
        noseSensor.position = SCNVector3(0.0, -0.06, 0.28)
        root.addChildNode(noseSensor)
        append(noseSensor, to: .escPower, componentNodes: &componentNodes)

        let bellySensor = boxNode(size: SIMD3<Float>(0.12, 0.05, 0.08), chamfer: 0.010, material: accentMaterial)
        bellySensor.position = SCNVector3(0.0, -0.07, 0.06)
        root.addChildNode(bellySensor)
        append(bellySensor, to: .battery, componentNodes: &componentNodes)

        let rearMotor = forwardMotorNode(radius: 0.026, length: 0.070, material: accentMaterial)
        rearMotor.position = SCNVector3(0.0, 0.03, -0.40)
        root.addChildNode(rearMotor)
        append(rearMotor, to: .motorRR, componentNodes: &componentNodes)

        let rearProp = forwardPropellerNode(material: rotorMaterial, radius: 0.14)
        rearProp.position = SCNVector3(0.0, 0.03, -0.46)
        rearProp.name = "propeller.hermes900.rear"
        root.addChildNode(rearProp)
        append(rearProp, to: .propellerRR, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.02, 0.50)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [rearProp],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildFT5Los(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.ft5Los"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.71, green: 0.74, blue: 0.78, alpha: 1.0), roughness: 0.34, metalness: 0.16)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.40, alpha: 1.0), roughness: 0.42, metalness: 0.24)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.24, alpha: 1.0), roughness: 0.28, metalness: 0.46)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.80), roughness: 0.20, metalness: 0.10)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.86, radius: 0.045, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let wing = planformNode(
            points: [
                CGPoint(x: -1.00, y: 0.08),
                CGPoint(x: -0.26, y: 0.16),
                CGPoint(x: 0.26, y: 0.16),
                CGPoint(x: 1.00, y: 0.08),
                CGPoint(x: 0.86, y: -0.12),
                CGPoint(x: -0.86, y: -0.12)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.025, 0.04)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let leftEngine = forwardMotorNode(radius: 0.024, length: 0.070, material: accentMaterial)
        leftEngine.position = SCNVector3(-0.34, 0.01, 0.10)
        root.addChildNode(leftEngine)
        append(leftEngine, to: .motorFL, componentNodes: &componentNodes)

        let rightEngine = forwardMotorNode(radius: 0.024, length: 0.070, material: accentMaterial)
        rightEngine.position = SCNVector3(0.34, 0.01, 0.10)
        root.addChildNode(rightEngine)
        append(rightEngine, to: .motorFR, componentNodes: &componentNodes)

        let leftProp = forwardPropellerNode(material: rotorMaterial, radius: 0.12)
        leftProp.position = SCNVector3(-0.34, 0.01, 0.16)
        leftProp.name = "propeller.ft5.left"
        root.addChildNode(leftProp)
        append(leftProp, to: .propellerFL, componentNodes: &componentNodes)

        let rightProp = forwardPropellerNode(material: rotorMaterial, radius: 0.12)
        rightProp.position = SCNVector3(0.34, 0.01, 0.16)
        rightProp.name = "propeller.ft5.right"
        root.addChildNode(rightProp)
        append(rightProp, to: .propellerFR, componentNodes: &componentNodes)

        let tailPlane = planformNode(
            points: [
                CGPoint(x: -0.26, y: 0.03),
                CGPoint(x: 0.26, y: 0.03),
                CGPoint(x: 0.20, y: -0.06),
                CGPoint(x: -0.20, y: -0.06)
            ],
            thickness: 0.016,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.06, -0.42)
        root.addChildNode(tailPlane)
        append(tailPlane, to: .armRR, componentNodes: &componentNodes)

        let fin = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.16, y: 0.0),
                CGPoint(x: 0.05, y: 0.22)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        fin.position = SCNVector3(0.0, 0.06, -0.46)
        root.addChildNode(fin)
        append(fin, to: .armRL, componentNodes: &componentNodes)

        let payloadBay = boxNode(size: SIMD3<Float>(0.12, 0.05, 0.10), chamfer: 0.010, material: accentMaterial)
        payloadBay.position = SCNVector3(0.0, -0.06, 0.10)
        root.addChildNode(payloadBay)
        append(payloadBay, to: .escPower, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.01, 0.42)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [leftProp, rightProp],
            propellerSpinDirections: [1.0, -1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func buildFlyEye(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.flyEye"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.66, green: 0.69, blue: 0.73, alpha: 1.0), roughness: 0.34, metalness: 0.14)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.26, green: 0.30, blue: 0.34, alpha: 1.0), roughness: 0.42, metalness: 0.22)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.19, alpha: 1.0), roughness: 0.28, metalness: 0.44)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.80), roughness: 0.20, metalness: 0.10)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.58, radius: 0.030, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let wing = planformNode(
            points: [
                CGPoint(x: -0.82, y: 0.06),
                CGPoint(x: -0.18, y: 0.12),
                CGPoint(x: 0.18, y: 0.12),
                CGPoint(x: 0.82, y: 0.06),
                CGPoint(x: 0.70, y: -0.08),
                CGPoint(x: -0.70, y: -0.08)
            ],
            thickness: 0.018,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.016, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let leftBoom = beamNode(start: SIMD3<Float>(-0.24, 0.01, -0.02), end: SIMD3<Float>(-0.14, 0.06, -0.28), radius: 0.010, material: accentMaterial)
        root.addChildNode(leftBoom)
        append(leftBoom, to: .armRL, componentNodes: &componentNodes)

        let rightBoom = beamNode(start: SIMD3<Float>(0.24, 0.01, -0.02), end: SIMD3<Float>(0.14, 0.06, -0.28), radius: 0.010, material: accentMaterial)
        root.addChildNode(rightBoom)
        append(rightBoom, to: .armRR, componentNodes: &componentNodes)

        let tailPlane = planformNode(
            points: [
                CGPoint(x: -0.18, y: 0.02),
                CGPoint(x: 0.18, y: 0.02),
                CGPoint(x: 0.14, y: -0.05),
                CGPoint(x: -0.14, y: -0.05)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.06, -0.32)
        root.addChildNode(tailPlane)

        let leftFin = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.10, y: 0.0),
                CGPoint(x: 0.03, y: 0.14)
            ],
            thickness: 0.010,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.14, 0.06, -0.34)
        root.addChildNode(leftFin)

        let rightFin = SCNNode()
        rightFin.position = SCNVector3(0.14, 0.06, -0.34)
        rightFin.eulerAngles = SCNVector3(0.0, Float.pi, 0.0)
        rightFin.addChildNode(verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.10, y: 0.0),
                CGPoint(x: 0.03, y: 0.14)
            ],
            thickness: 0.010,
            material: wingMaterial
        ))
        root.addChildNode(rightFin)

        let sensorPod = boxNode(size: SIMD3<Float>(0.08, 0.04, 0.07), chamfer: 0.008, material: accentMaterial)
        sensorPod.position = SCNVector3(0.0, -0.045, 0.10)
        root.addChildNode(sensorPod)
        append(sensorPod, to: .escPower, componentNodes: &componentNodes)

        let rearMotor = forwardMotorNode(radius: 0.018, length: 0.050, material: accentMaterial)
        rearMotor.position = SCNVector3(0.0, 0.02, -0.18)
        root.addChildNode(rearMotor)
        append(rearMotor, to: .motorRR, componentNodes: &componentNodes)

        let rearProp = forwardPropellerNode(material: rotorMaterial, radius: 0.09)
        rearProp.position = SCNVector3(0.0, 0.02, -0.24)
        rearProp.name = "propeller.flyeye.rear"
        root.addChildNode(rearProp)
        append(rearProp, to: .propellerRR, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.01, 0.26)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [rearProp],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func append(_ node: SCNNode, to component: DamageComponent, componentNodes: inout [DamageComponent: [SCNNode]]) {
        componentNodes[component, default: []].append(node)
    }

    private static func makePayloadMountNode(offset: SIMD3<Float>) -> SCNNode {
        let node = SCNNode()
        node.name = "payloadMountNode"
        node.position = SCNVector3(offset.x, offset.y, offset.z)
        return node
    }

    private static func boxNode(size: SIMD3<Float>, chamfer: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: CGFloat(chamfer)
        ))
        node.geometry?.materials = [material]
        return node
    }

    private static func cylinderNode(radius: Float, height: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: CGFloat(height)))
        node.geometry?.materials = [material]
        return node
    }

    private static func sphereNode(radius: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNSphere(radius: CGFloat(radius)))
        node.geometry?.materials = [material]
        return node
    }

    private static func torusNode(ringRadius: Float, pipeRadius: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNTorus(ringRadius: CGFloat(ringRadius), pipeRadius: CGFloat(pipeRadius)))
        node.geometry?.materials = [material]
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func beamNode(start: SIMD3<Float>, end: SIMD3<Float>, radius: Float, material: SCNMaterial) -> SCNNode {
        let delta = end - start
        let length = max(radius * 2.0, simd_length(delta))
        let node = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(length)))
        node.geometry?.materials = [material]
        node.position = SCNVector3((start.x + end.x) * 0.5, (start.y + end.y) * 0.5, (start.z + end.z) * 0.5)

        let yaw = atan2(delta.x, delta.z)
        let pitch = atan2(delta.y, max(0.0001, sqrt(delta.x * delta.x + delta.z * delta.z)))
        node.eulerAngles = SCNVector3(-pitch, -yaw, Float.pi / 2.0)
        return node
    }

    private static func topPropellerNode(material: SCNMaterial, radius: Float) -> SCNNode {
        let node = SCNNode()

        let hub = cylinderNode(radius: radius * 0.12, height: radius * 0.08, material: material)
        node.addChildNode(hub)

        let bladeGeometry = SCNBox(
            width: CGFloat(radius * 2.0),
            height: CGFloat(radius * 0.05),
            length: CGFloat(radius * 0.16),
            chamferRadius: CGFloat(radius * 0.02)
        )
        bladeGeometry.materials = [material]

        let bladeA = SCNNode(geometry: bladeGeometry)
        bladeA.position = SCNVector3(0.0, radius * 0.03, 0.0)
        node.addChildNode(bladeA)

        let bladeB = SCNNode(geometry: bladeGeometry)
        bladeB.position = SCNVector3(0.0, radius * 0.03, 0.0)
        bladeB.eulerAngles = SCNVector3(0.0, Float.pi / 2.0, 0.0)
        node.addChildNode(bladeB)

        return node
    }

    private static func forwardMotorNode(radius: Float, length: Float, material: SCNMaterial) -> SCNNode {
        let node = cylinderNode(radius: radius, height: length, material: material)
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func forwardPropellerNode(material: SCNMaterial, radius: Float) -> SCNNode {
        let node = topPropellerNode(material: material, radius: radius)
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func horizontalCapsule(length: Float, radius: Float, material: SCNMaterial) -> SCNNode {
        let node = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(length)))
        node.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        node.geometry?.materials = [material]
        return node
    }

    private static func planformNode(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNNode {
        let shape = extrudedShape(points: points, thickness: thickness, material: material)
        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(0.0, 0.0, CGFloat(thickness * 0.5))
        node.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
        return node
    }

    private static func verticalSurfaceNode(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNNode {
        let shape = extrudedShape(points: points, thickness: thickness, material: material)
        let node = SCNNode(geometry: shape)
        node.pivot = SCNMatrix4MakeTranslation(0.0, 0.0, CGFloat(thickness * 0.5))
        node.eulerAngles = SCNVector3(0.0, Float.pi / 2.0, 0.0)
        return node
    }

    private static func extrudedShape(points: [CGPoint], thickness: Float, material: SCNMaterial) -> SCNShape {
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

    private static func material(diffuse: NSColor, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        material.lightingModel = .physicallyBased
        return material
    }
}
