import AppKit
import SceneKit
import simd

enum UAVVisualFactory {
    private enum AirframeAccent {
        case topPanel(color: NSColor, size: SIMD3<Float>, position: SIMD3<Float>)
        case sideRails(color: NSColor)
        case dockShell
        case fixedWingWinglets(color: NSColor)
        case indoorGuardCage(color: NSColor)
    }

    static func build(profile: UAVProfile) -> DroneVisualModel {
        switch profile.id {
        case "dji-mavic-3t":
            return visualVariant(
                buildDJIMavic4Pro(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.djiMavic3T",
                scale: 0.92,
                accents: [
                    .topPanel(color: NSColor(calibratedWhite: 0.18, alpha: 1.0), size: SIMD3<Float>(0.095, 0.010, 0.070), position: SIMD3<Float>(0.0, 0.078, -0.018))
                ]
            )
        case "dji-matrice-4t":
            return visualVariant(
                buildDJIMavic4Pro(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.djiMatrice4T",
                scale: 1.08,
                accents: [
                    .topPanel(color: NSColor(calibratedRed: 0.72, green: 0.74, blue: 0.76, alpha: 1.0), size: SIMD3<Float>(0.125, 0.012, 0.090), position: SIMD3<Float>(0.0, 0.080, -0.020)),
                    .sideRails(color: NSColor(calibratedWhite: 0.12, alpha: 1.0))
                ]
            )
        case "dji-matrice-30t":
            return visualVariant(
                buildDJIMatrice350RTK(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.djiMatrice30T",
                scale: 0.76,
                accents: [
                    .topPanel(color: NSColor(calibratedWhite: 0.12, alpha: 1.0), size: SIMD3<Float>(0.155, 0.018, 0.120), position: SIMD3<Float>(0.0, 0.120, -0.005))
                ]
            )
        case "dji-matrice-400":
            return visualVariant(
                buildDJIMatrice350RTK(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.djiMatrice400",
                scale: 1.22,
                accents: [
                    .topPanel(color: NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.82, alpha: 1.0), size: SIMD3<Float>(0.210, 0.022, 0.155), position: SIMD3<Float>(0.0, 0.127, -0.010)),
                    .sideRails(color: NSColor(calibratedWhite: 0.08, alpha: 1.0))
                ]
            )
        case "fotokite-sigma":
            return visualVariant(
                buildAbstractCustom(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.fotokiteSigma",
                scale: 0.86
            )
        case "everdrone-first-on-scene":
            return visualVariant(
                buildDJIMatrice350RTK(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.everdroneFirstOnScene",
                scale: 0.70,
                accents: [
                    .topPanel(color: NSColor(calibratedRed: 0.86, green: 0.18, blue: 0.16, alpha: 1.0), size: SIMD3<Float>(0.115, 0.014, 0.090), position: SIMD3<Float>(0.0, 0.116, -0.006))
                ]
            )
        case "zipline-platform-1":
            return visualVariant(
                buildLightFixedWingSurvey(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.ziplinePlatform1",
                scale: 1.18,
                accents: [
                    .fixedWingWinglets(color: NSColor(calibratedRed: 0.88, green: 0.10, blue: 0.08, alpha: 1.0))
                ]
            )
        case "wingcopter-198":
            return visualVariant(
                buildQuantumSystemsTrinityPro(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.wingcopter198",
                scale: 0.95,
                accents: [
                    .fixedWingWinglets(color: NSColor(calibratedWhite: 0.92, alpha: 1.0))
                ]
            )
        case "matternet-m2":
            return visualVariant(
                buildAbstractCustom(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.matternetM2",
                scale: 0.78,
                accents: [
                    .topPanel(color: NSColor(calibratedWhite: 0.92, alpha: 1.0), size: SIMD3<Float>(0.090, 0.012, 0.070), position: SIMD3<Float>(0.0, 0.048, -0.005)),
                    .sideRails(color: NSColor(calibratedWhite: 0.16, alpha: 1.0))
                ]
            )
        case "skydio-x10":
            return visualVariant(
                buildDJIMavic4Pro(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.skydioX10",
                scale: 1.03,
                accents: [
                    .topPanel(color: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0), size: SIMD3<Float>(0.150, 0.014, 0.105), position: SIMD3<Float>(0.0, 0.080, -0.010)),
                    .sideRails(color: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0))
                ]
            )
        case "dji-matrice-4td-dock-3":
            return visualVariant(
                buildDJIMavic4Pro(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.djiMatrice4TDDock3",
                scale: 1.16,
                accents: [
                    .dockShell
                ]
            )
        case "brinc-lemur-2":
            return visualVariant(
                buildDJINeo(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.brincLemur2",
                scale: 1.12,
                accents: [
                    .indoorGuardCage(color: NSColor(calibratedWhite: 0.08, alpha: 1.0))
                ]
            )
        case "mq-9a-reaper":
            // MQ-9B SkyGuardian is a direct derivative of the MQ-9A airframe —
            // same fuselage, same V-tail, same rear pusher. The visible
            // difference is the wing: 20.1 m on the A against 24 m on the B,
            // hence the scale rather than a duplicated planform.
            return visualVariant(
                buildMQ9BSkyGuardian(payloadMountOffset: profile.payloadMountOffset),
                name: "uavRoot.mq9aReaper",
                scale: 0.86
            )
        case "iai-harpy-ng":
            // Harpy NG flies the Harop airframe (delta + canard, Wankel pusher)
            // with the anti-radiation seeker of the original Harpy.
            return visualVariant(
                buildDeltaLoiteringMunition(payloadMountOffset: profile.payloadMountOffset, canards: true, halfSpan: 0.41),
                name: "uavRoot.iaiHarpyNG",
                scale: 1.04
            )
        default:
            break
        }

        return build(preset: profile.visualPreset, payloadMountOffset: profile.payloadMountOffset)
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
        case .lightFixedWingSurvey:
            return buildLightFixedWingSurvey(payloadMountOffset: payloadMountOffset)
        case .wildfireEmber40:
            return buildWildfireEmber40(payloadMountOffset: payloadMountOffset)
        case .pyroliftTalon60:
            return buildPyroliftTalon60(payloadMountOffset: payloadMountOffset)
        case .colossusCA8Vulcan:
            return buildColossusCA8Vulcan(payloadMountOffset: payloadMountOffset)
        case .colossusCA12Atlas:
            return buildColossusCA12Atlas(payloadMountOffset: payloadMountOffset)
        case .agroWingTitanAT40:
            return buildAgroWingTitanAT40(payloadMountOffset: payloadMountOffset)
        case .aerosondeMk47:
            return buildAerosondeMk47(payloadMountOffset: payloadMountOffset)
        case .rq7bShadow:
            return buildRQ7BShadow(payloadMountOffset: payloadMountOffset)
        case .deltaLoiteringMunition:
            return buildDeltaLoiteringMunition(payloadMountOffset: payloadMountOffset, canards: false, halfSpan: 0.27)
        case .canardDeltaLoiteringMunition:
            return buildDeltaLoiteringMunition(payloadMountOffset: payloadMountOffset, canards: true, halfSpan: 0.41)
        case .researchDeltaWing:
            return buildResearchDeltaWing(payloadMountOffset: payloadMountOffset)
        case .blendedWingBodyTestbed:
            return buildBlendedWingBodyTestbed(payloadMountOffset: payloadMountOffset)
        case .jetTargetDrone:
            return buildJetTargetDrone(payloadMountOffset: payloadMountOffset)
        case .bqm34fFirebeeII:
            return buildFirebeeII(payloadMountOffset: payloadMountOffset)
        case .aqm35TargetDrone:
            return buildAQM35(payloadMountOffset: payloadMountOffset)
        case .rockwellHiMAT:
            return buildHiMAT(payloadMountOffset: payloadMountOffset)
        case .hermeusQuarterhorse:
            return buildQuarterhorse(payloadMountOffset: payloadMountOffset)
        case .northAmericanX10:
            return buildX10(payloadMountOffset: payloadMountOffset)
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
        var tiltPivots: [SCNNode] = []
        let spinDirections: [Float] = [1.0, -1.0, -1.0, 1.0]

        for (index, pod) in podPositions.enumerated() {
            let mast = boxNode(size: SIMD3<Float>(0.034, 0.10, 0.034), chamfer: 0.006, material: accentMaterial)
            mast.position = SCNVector3(pod.0.x, 0.054, pod.0.z)
            root.addChildNode(mast)

            // The nacelle (motor + propeller) tilts as a unit around this
            // pivot; the mast (mount stalk) stays fixed, matching a real
            // tilt-rotor where the arm attaches to the wing but the nacelle
            // itself rotates. Rotating +eulerAngles.x by the propulsion
            // unit's tiltAngleRad sweeps local +Y ("up", hover) toward local
            // +Z ("nose" in this file's own pre-flip convention) — verified
            // against the existing noseCone rotation elsewhere in this file.
            // DroneModelBuilder.build(profile:) applies the whole-model 180°
            // yaw flip for .fixedWing/.hybridVTOL that reconciles this
            // local +Z-nose convention with the physics engine's body-frame
            // forward=-Z, so no extra sign flip is needed here.
            let tiltPivot = SCNNode()
            tiltPivot.name = "tiltPivot.trinity.\(index)"
            tiltPivot.position = SCNVector3(pod.0.x, pod.0.y, pod.0.z)
            root.addChildNode(tiltPivot)
            tiltPivots.append(tiltPivot)

            let motor = cylinderNode(radius: 0.022, height: 0.026, material: accentMaterial)
            tiltPivot.addChildNode(motor)
            append(motor, to: pod.1, componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.13)
            propeller.position = SCNVector3(0.0, 0.020, 0.0)
            propeller.name = "propeller.trinity.\(index)"
            tiltPivot.addChildNode(propeller)
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
            payloadMountNode: payloadMountNode,
            tiltPivotNodes: tiltPivots
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

    /// Styled after the real DJI Agras T40 — a low-slung wide tank body, 4 diagonal arms each
    /// carrying a coaxial rotor pair (X8, 8 propellers total), tall thin legs raising the tank
    /// clear of the ground, and a spray boom/nozzle bar beneath the tank. Deliberately distinct
    /// from the boxy cargo-deck octocopter silhouette shared by Griff/Colossus/Wildfire/Pyrolift
    /// above — this airframe's defining features (wide tank, boom, legs) are agricultural, not
    /// cargo-lift.
    private static func buildAgroWingTitanAT40(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.agroWingTitanAT40"

        let shellMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 1.0), roughness: 0.36, metalness: 0.10)
        let armMaterial = material(diffuse: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.16, alpha: 1.0), roughness: 0.42, metalness: 0.30)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.86, green: 0.42, blue: 0.10, alpha: 1.0), roughness: 0.32, metalness: 0.16)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)
        let boomMaterial = material(diffuse: NSColor(calibratedWhite: 0.80, alpha: 1.0), roughness: 0.40, metalness: 0.20)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let tank = boxNode(size: SIMD3<Float>(0.46, 0.16, 0.26), chamfer: 0.05, material: shellMaterial)
        root.addChildNode(tank)
        append(tank, to: .battery, componentNodes: &componentNodes)

        let hub = cylinderNode(radius: 0.10, height: 0.06, material: armMaterial)
        hub.position = SCNVector3(0.0, 0.11, 0.0)
        root.addChildNode(hub)
        append(hub, to: .flightControllerCore, componentNodes: &componentNodes)

        // Forward radar/vision sensor pod — the T40's distinctive nose module.
        let sensorPod = sphereNode(radius: 0.045, material: armMaterial)
        sensorPod.position = SCNVector3(0.0, 0.02, 0.16)
        root.addChildNode(sensorPod)
        append(sensorPod, to: .frontCameraGimbal, componentNodes: &componentNodes)

        // 4 diagonal arms, each a coaxial rotor pair (X8) — the real T40's layout, unlike
        // Griff's true single-plane octocopter spread.
        let armPoints: [(SIMD3<Float>, DamageComponent)] = [
            (SIMD3<Float>(0.62, 0.10, 0.62), .armFR),
            (SIMD3<Float>(0.62, 0.10, -0.62), .armRR),
            (SIMD3<Float>(-0.62, 0.10, -0.62), .armRL),
            (SIMD3<Float>(-0.62, 0.10, 0.62), .armFL)
        ]
        let motorBuckets: [DamageComponent] = [.motorFR, .motorRR, .motorRL, .motorFL]
        let propBuckets: [DamageComponent] = [.propellerFR, .propellerRR, .propellerRL, .propellerFL]

        var propellers: [SCNNode] = []
        var spinDirections: [Float] = []

        for (index, arm) in armPoints.enumerated() {
            let armBeam = beamNode(start: SIMD3<Float>(0.0, 0.09, 0.0), end: arm.0, radius: 0.026, material: armMaterial)
            root.addChildNode(armBeam)
            append(armBeam, to: arm.1, componentNodes: &componentNodes)

            let motorMount = cylinderNode(radius: 0.05, height: 0.10, material: armMaterial)
            motorMount.position = SCNVector3(arm.0.x, arm.0.y + 0.05, arm.0.z)
            root.addChildNode(motorMount)
            append(motorMount, to: motorBuckets[index], componentNodes: &componentNodes)

            let topProp = topPropellerNode(material: rotorMaterial, radius: 0.20)
            topProp.position = SCNVector3(arm.0.x, arm.0.y + 0.11, arm.0.z)
            topProp.name = "propeller.agroWingTitanAT40.\(index).top"
            root.addChildNode(topProp)
            propellers.append(topProp)
            spinDirections.append(index % 2 == 0 ? 1.0 : -1.0)
            append(topProp, to: propBuckets[index], componentNodes: &componentNodes)

            // Bottom rotor of the coaxial pair, counter-rotating against its own top rotor.
            let bottomProp = topPropellerNode(material: rotorMaterial, radius: 0.20)
            bottomProp.position = SCNVector3(arm.0.x, arm.0.y - 0.01, arm.0.z)
            bottomProp.name = "propeller.agroWingTitanAT40.\(index).bottom"
            root.addChildNode(bottomProp)
            propellers.append(bottomProp)
            spinDirections.append(index % 2 == 0 ? -1.0 : 1.0)
            append(bottomProp, to: propBuckets[index], componentNodes: &componentNodes)
        }

        // Tall thin legs — Agras-class drones sit noticeably high off the ground to clear the
        // tank/boom, unlike the low skids on the cargo-lift airframes above.
        let legCorners: [SIMD2<Float>] = [
            SIMD2<Float>(1.0, 1.0), SIMD2<Float>(1.0, -1.0),
            SIMD2<Float>(-1.0, -1.0), SIMD2<Float>(-1.0, 1.0)
        ]
        for corner in legCorners {
            let leg = beamNode(
                start: SIMD3<Float>(0.16 * corner.x, -0.06, 0.10 * corner.y),
                end: SIMD3<Float>(0.20 * corner.x, -0.34, 0.12 * corner.y),
                radius: 0.014,
                material: armMaterial
            )
            root.addChildNode(leg)
        }

        // Spray boom bar with nozzles, slung beneath the tank — wider than the tank itself, the
        // defining agricultural-sprayer detail absent from every other airframe in this file.
        let boom = boxNode(size: SIMD3<Float>(0.62, 0.03, 0.05), chamfer: 0.01, material: boomMaterial)
        boom.position = SCNVector3(0.0, -0.32, 0.0)
        root.addChildNode(boom)
        append(boom, to: .escPower, componentNodes: &componentNodes)

        let nozzleCount = 6
        let nozzleSpacing: Float = 0.62 / Float(nozzleCount - 1)
        let nozzleStartX: Float = -0.31
        for index in 0..<nozzleCount {
            let nozzle = cylinderNode(radius: 0.014, height: 0.05, material: accentMaterial)
            nozzle.position = SCNVector3(nozzleStartX + nozzleSpacing * Float(index), -0.36, 0.0)
            root.addChildNode(nozzle)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.02, 0.20)
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

    private static func buildWildfireEmber40(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.wildfireEmber40"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.10, alpha: 1.0), roughness: 0.42, metalness: 0.30)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.28, alpha: 1.0), roughness: 0.38, metalness: 0.36)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.96, green: 0.78, blue: 0.12, alpha: 1.0), roughness: 0.32, metalness: 0.12)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let hubRing = torusNode(ringRadius: 0.16, pipeRadius: 0.016, material: frameMaterial)
        hubRing.position = SCNVector3(0.0, 0.04, 0.0)
        root.addChildNode(hubRing)
        append(hubRing, to: .flightControllerCore, componentNodes: &componentNodes)

        let centerSection = boxNode(size: SIMD3<Float>(0.16, 0.09, 0.16), chamfer: 0.010, material: carbonMaterial)
        root.addChildNode(centerSection)
        append(centerSection, to: .battery, componentNodes: &componentNodes)

        let reelDrum = cylinderNode(radius: 0.070, height: 0.16, material: accentMaterial)
        reelDrum.eulerAngles = SCNVector3(0.0, 0.0, Float.pi / 2.0)
        reelDrum.position = SCNVector3(0.0, -0.11, 0.0)
        root.addChildNode(reelDrum)
        append(reelDrum, to: .escPower, componentNodes: &componentNodes)

        // Hexagonal spoke ring — 6 arms at 60° increments; the four damage-component quadrant
        // buckets are reused twice each (same convention as buildGriff30's 8-rotor layout).
        let hexRadius: Float = 0.60
        let hexAngles: [Float] = [0, 60, 120, 180, 240, 300].map { $0 * .pi / 180.0 }
        let hexBuckets: [DamageComponent] = [.armFL, .armFR, .armRR, .armRR, .armRL, .armFL]
        let motorBuckets: [DamageComponent] = [.motorFL, .motorFR, .motorRR, .motorRR, .motorRL, .motorFL]
        let propBuckets: [DamageComponent] = [.propellerFL, .propellerFR, .propellerRR, .propellerRR, .propellerRL, .propellerFL]
        let rotorPoints: [SIMD3<Float>] = hexAngles.map { angle in
            SIMD3<Float>(sin(angle) * hexRadius, 0.09, cos(angle) * hexRadius)
        }

        var propellers: [SCNNode] = []
        var spinDirections: [Float] = []

        for (index, point) in rotorPoints.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.03, 0.0), end: point, radius: 0.016, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: hexBuckets[index], componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.036, height: 0.030, material: frameMaterial)
            motor.position = SCNVector3(point.x, point.y, point.z)
            root.addChildNode(motor)
            append(motor, to: motorBuckets[index], componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.15)
            propeller.position = SCNVector3(point.x, point.y + 0.026, point.z)
            propeller.name = "propeller.wildfireEmber40.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            spinDirections.append(index % 2 == 0 ? 1.0 : -1.0)
            append(propeller, to: propBuckets[index], componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let leg = beamNode(
                start: SIMD3<Float>(0.10 * side, -0.02, 0.0),
                end: SIMD3<Float>(0.24 * side, -0.24, 0.0),
                radius: 0.010,
                material: accentMaterial
            )
            root.addChildNode(leg)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.02, 0.15)
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

    private static func buildPyroliftTalon60(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.pyroliftTalon60"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0), roughness: 0.44, metalness: 0.32)
        let frameMaterial = material(diffuse: NSColor(calibratedWhite: 0.86, alpha: 1.0), roughness: 0.34, metalness: 0.24)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.80, green: 0.10, blue: 0.08, alpha: 1.0), roughness: 0.30, metalness: 0.18)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let hubRing = torusNode(ringRadius: 0.24, pipeRadius: 0.022, material: frameMaterial)
        hubRing.position = SCNVector3(0.0, 0.06, 0.0)
        root.addChildNode(hubRing)
        append(hubRing, to: .flightControllerCore, componentNodes: &componentNodes)

        let centerSection = boxNode(size: SIMD3<Float>(0.22, 0.12, 0.22), chamfer: 0.012, material: carbonMaterial)
        root.addChildNode(centerSection)
        append(centerSection, to: .battery, componentNodes: &componentNodes)

        let cargoDeck = boxNode(size: SIMD3<Float>(0.30, 0.09, 0.30), chamfer: 0.012, material: accentMaterial)
        cargoDeck.position = SCNVector3(0.0, -0.16, 0.0)
        root.addChildNode(cargoDeck)
        append(cargoDeck, to: .escPower, componentNodes: &componentNodes)

        let reelDrum = cylinderNode(radius: 0.095, height: 0.22, material: frameMaterial)
        reelDrum.eulerAngles = SCNVector3(0.0, 0.0, Float.pi / 2.0)
        reelDrum.position = SCNVector3(0.0, -0.26, 0.0)
        root.addChildNode(reelDrum)

        let nozzleTurret = cylinderNode(radius: 0.030, height: 0.10, material: accentMaterial)
        nozzleTurret.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        nozzleTurret.position = SCNVector3(0.0, -0.16, 0.22)
        root.addChildNode(nozzleTurret)

        let hexRadius: Float = 0.78
        let hexAngles: [Float] = [0, 60, 120, 180, 240, 300].map { $0 * .pi / 180.0 }
        let hexBuckets: [DamageComponent] = [.armFL, .armFR, .armRR, .armRR, .armRL, .armFL]
        let motorBuckets: [DamageComponent] = [.motorFL, .motorFR, .motorRR, .motorRR, .motorRL, .motorFL]
        let propBuckets: [DamageComponent] = [.propellerFL, .propellerFR, .propellerRR, .propellerRR, .propellerRL, .propellerFL]
        let rotorPoints: [SIMD3<Float>] = hexAngles.map { angle in
            SIMD3<Float>(sin(angle) * hexRadius, 0.13, cos(angle) * hexRadius)
        }

        var propellers: [SCNNode] = []
        var spinDirections: [Float] = []

        for (index, point) in rotorPoints.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.05, 0.0), end: point, radius: 0.022, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: hexBuckets[index], componentNodes: &componentNodes)

            let motor = cylinderNode(radius: 0.050, height: 0.040, material: frameMaterial)
            motor.position = SCNVector3(point.x, point.y, point.z)
            root.addChildNode(motor)
            append(motor, to: motorBuckets[index], componentNodes: &componentNodes)

            let propeller = topPropellerNode(material: rotorMaterial, radius: 0.22)
            propeller.position = SCNVector3(point.x, point.y + 0.032, point.z)
            propeller.name = "propeller.pyroliftTalon60.\(index)"
            root.addChildNode(propeller)
            propellers.append(propeller)
            spinDirections.append(index % 2 == 0 ? 1.0 : -1.0)
            append(propeller, to: propBuckets[index], componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let skid = beamNode(
                start: SIMD3<Float>(0.20 * side, -0.20, -0.26),
                end: SIMD3<Float>(0.20 * side, -0.20, 0.26),
                radius: 0.016,
                material: frameMaterial
            )
            let strut = beamNode(
                start: SIMD3<Float>(0.16 * side, -0.16, 0.0),
                end: SIMD3<Float>(0.20 * side, -0.20, 0.0),
                radius: 0.016,
                material: frameMaterial
            )
            root.addChildNode(skid)
            root.addChildNode(strut)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.04, 0.20)
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

    private static func buildColossusCA8Vulcan(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.colossusCA8Vulcan"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.10, alpha: 1.0), roughness: 0.46, metalness: 0.32)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.26, green: 0.26, blue: 0.27, alpha: 1.0), roughness: 0.38, metalness: 0.44)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.94, green: 0.44, blue: 0.06, alpha: 1.0), roughness: 0.32, metalness: 0.14)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let chassis = boxNode(size: SIMD3<Float>(0.42, 0.20, 0.42), chamfer: 0.020, material: carbonMaterial)
        root.addChildNode(chassis)
        append(chassis, to: .flightControllerCore, componentNodes: &componentNodes)

        let hazardBand = boxNode(size: SIMD3<Float>(0.44, 0.04, 0.44), chamfer: 0.012, material: accentMaterial)
        hazardBand.position = SCNVector3(0.0, 0.06, 0.0)
        root.addChildNode(hazardBand)
        append(hazardBand, to: .battery, componentNodes: &componentNodes)

        let cargoDeck = boxNode(size: SIMD3<Float>(0.46, 0.10, 0.46), chamfer: 0.014, material: frameMaterial)
        cargoDeck.position = SCNVector3(0.0, -0.20, 0.0)
        root.addChildNode(cargoDeck)
        append(cargoDeck, to: .escPower, componentNodes: &componentNodes)

        let reelDrum = cylinderNode(radius: 0.12, height: 0.30, material: accentMaterial)
        reelDrum.eulerAngles = SCNVector3(0.0, 0.0, Float.pi / 2.0)
        reelDrum.position = SCNVector3(0.0, -0.34, 0.0)
        root.addChildNode(reelDrum)

        // 4 arms, each carrying a coaxial (upper+lower) motor/propeller pair — 8 rotors total,
        // distinct from Griff 30/60's true 8-single-motor-arm layout (mirrors buildFreeflyAltaX's
        // coaxial convention, scaled up).
        let armTips: [(DamageComponent, DamageComponent, DamageComponent, SIMD3<Float>)] = [
            (.armFL, .motorFL, .propellerFL, SIMD3<Float>(-0.86, 0.10, 0.86)),
            (.armFR, .motorFR, .propellerFR, SIMD3<Float>(0.86, 0.10, 0.86)),
            (.armRL, .motorRL, .propellerRL, SIMD3<Float>(-0.86, 0.10, -0.86)),
            (.armRR, .motorRR, .propellerRR, SIMD3<Float>(0.86, 0.10, -0.86))
        ]

        var propellers: [SCNNode] = []
        var spinDirections: [Float] = []

        for (index, armTip) in armTips.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.06, 0.0), end: armTip.3, radius: 0.032, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: armTip.0, componentNodes: &componentNodes)

            let knuckle = sphereNode(radius: 0.056, material: frameMaterial)
            knuckle.position = SCNVector3(armTip.3.x * 0.74, armTip.3.y * 0.74, armTip.3.z * 0.74)
            root.addChildNode(knuckle)

            let upperMotor = cylinderNode(radius: 0.062, height: 0.046, material: frameMaterial)
            upperMotor.position = SCNVector3(armTip.3.x, armTip.3.y + 0.052, armTip.3.z)
            root.addChildNode(upperMotor)
            append(upperMotor, to: armTip.1, componentNodes: &componentNodes)

            let lowerMotor = cylinderNode(radius: 0.062, height: 0.046, material: frameMaterial)
            lowerMotor.position = SCNVector3(armTip.3.x, armTip.3.y - 0.014, armTip.3.z)
            root.addChildNode(lowerMotor)
            append(lowerMotor, to: armTip.1, componentNodes: &componentNodes)

            let upperPropeller = topPropellerNode(material: rotorMaterial, radius: 0.26)
            upperPropeller.position = SCNVector3(armTip.3.x, armTip.3.y + 0.092, armTip.3.z)
            upperPropeller.name = "propeller.colossusCA8Vulcan.upper.\(index)"
            root.addChildNode(upperPropeller)
            propellers.append(upperPropeller)
            spinDirections.append(index % 2 == 0 ? 1.0 : -1.0)
            append(upperPropeller, to: armTip.2, componentNodes: &componentNodes)

            let lowerPropeller = topPropellerNode(material: rotorMaterial, radius: 0.26)
            lowerPropeller.position = SCNVector3(armTip.3.x, armTip.3.y - 0.056, armTip.3.z)
            lowerPropeller.name = "propeller.colossusCA8Vulcan.lower.\(index)"
            root.addChildNode(lowerPropeller)
            propellers.append(lowerPropeller)
            spinDirections.append(index % 2 == 0 ? -1.0 : 1.0)
            append(lowerPropeller, to: armTip.2, componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let skidFront = beamNode(
                start: SIMD3<Float>(0.44 * side, -0.06, 0.30),
                end: SIMD3<Float>(0.64 * side, -0.42, 0.30),
                radius: 0.024,
                material: accentMaterial
            )
            let skidRear = beamNode(
                start: SIMD3<Float>(0.44 * side, -0.06, -0.30),
                end: SIMD3<Float>(0.64 * side, -0.42, -0.30),
                radius: 0.024,
                material: accentMaterial
            )
            let rail = beamNode(
                start: SIMD3<Float>(0.64 * side, -0.42, -0.36),
                end: SIMD3<Float>(0.64 * side, -0.42, 0.36),
                radius: 0.020,
                material: accentMaterial
            )
            root.addChildNode(skidFront)
            root.addChildNode(skidRear)
            root.addChildNode(rail)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.06, 0.28)
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

    private static func buildColossusCA12Atlas(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.colossusCA12Atlas"

        let carbonMaterial = material(diffuse: NSColor(calibratedRed: 0.42, green: 0.43, blue: 0.45, alpha: 1.0), roughness: 0.40, metalness: 0.52)
        let frameMaterial = material(diffuse: NSColor(calibratedRed: 0.30, green: 0.31, blue: 0.33, alpha: 1.0), roughness: 0.34, metalness: 0.48)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.96, green: 0.46, blue: 0.05, alpha: 1.0), roughness: 0.30, metalness: 0.16)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.94, alpha: 0.84), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let upperRing = torusNode(ringRadius: 0.40, pipeRadius: 0.032, material: frameMaterial)
        upperRing.position = SCNVector3(0.0, 0.12, 0.0)
        root.addChildNode(upperRing)
        append(upperRing, to: .flightControllerCore, componentNodes: &componentNodes)

        let lowerRing = torusNode(ringRadius: 0.30, pipeRadius: 0.026, material: carbonMaterial)
        lowerRing.position = SCNVector3(0.0, -0.02, 0.0)
        root.addChildNode(lowerRing)
        append(lowerRing, to: .battery, componentNodes: &componentNodes)

        let centerSection = boxNode(size: SIMD3<Float>(0.36, 0.20, 0.36), chamfer: 0.018, material: carbonMaterial)
        root.addChildNode(centerSection)
        append(centerSection, to: .battery, componentNodes: &componentNodes)

        let flatbedDeck = boxNode(size: SIMD3<Float>(0.44, 0.10, 0.44), chamfer: 0.014, material: accentMaterial)
        flatbedDeck.position = SCNVector3(0.0, -0.24, 0.0)
        root.addChildNode(flatbedDeck)
        append(flatbedDeck, to: .escPower, componentNodes: &componentNodes)

        let reelDrum = cylinderNode(radius: 0.14, height: 0.34, material: frameMaterial)
        reelDrum.eulerAngles = SCNVector3(0.0, 0.0, Float.pi / 2.0)
        reelDrum.position = SCNVector3(0.0, -0.40, 0.0)
        root.addChildNode(reelDrum)

        let monitorTurretBase = sphereNode(radius: 0.050, material: accentMaterial)
        monitorTurretBase.position = SCNVector3(0.0, -0.24, 0.30)
        root.addChildNode(monitorTurretBase)

        let monitorNozzle = cylinderNode(radius: 0.026, height: 0.14, material: frameMaterial)
        monitorNozzle.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        monitorNozzle.position = SCNVector3(0.0, -0.24, 0.40)
        root.addChildNode(monitorNozzle)

        // 6 arms, each carrying a coaxial (upper+lower) motor/propeller pair — 12 rotors total,
        // the flagship of the family (mirrors buildFreeflyAltaX's coaxial convention across a
        // hexagonal spread instead of 4 arms).
        let hexRadius: Float = 1.02
        let hexAngles: [Float] = [0, 60, 120, 180, 240, 300].map { $0 * .pi / 180.0 }
        let hexBuckets: [DamageComponent] = [.armFL, .armFR, .armRR, .armRR, .armRL, .armFL]
        let motorBuckets: [DamageComponent] = [.motorFL, .motorFR, .motorRR, .motorRR, .motorRL, .motorFL]
        let propBuckets: [DamageComponent] = [.propellerFL, .propellerFR, .propellerRR, .propellerRR, .propellerRL, .propellerFL]
        let armTips: [SIMD3<Float>] = hexAngles.map { angle in
            SIMD3<Float>(sin(angle) * hexRadius, 0.16, cos(angle) * hexRadius)
        }

        var propellers: [SCNNode] = []
        var spinDirections: [Float] = []

        for (index, tip) in armTips.enumerated() {
            let arm = beamNode(start: SIMD3<Float>(0.0, 0.10, 0.0), end: tip, radius: 0.040, material: carbonMaterial)
            root.addChildNode(arm)
            append(arm, to: hexBuckets[index], componentNodes: &componentNodes)

            let knuckle = sphereNode(radius: 0.066, material: frameMaterial)
            knuckle.position = SCNVector3(tip.x * 0.76, tip.y * 0.76, tip.z * 0.76)
            root.addChildNode(knuckle)

            let upperMotor = cylinderNode(radius: 0.068, height: 0.050, material: frameMaterial)
            upperMotor.position = SCNVector3(tip.x, tip.y + 0.056, tip.z)
            root.addChildNode(upperMotor)
            append(upperMotor, to: motorBuckets[index], componentNodes: &componentNodes)

            let lowerMotor = cylinderNode(radius: 0.068, height: 0.050, material: frameMaterial)
            lowerMotor.position = SCNVector3(tip.x, tip.y - 0.016, tip.z)
            root.addChildNode(lowerMotor)
            append(lowerMotor, to: motorBuckets[index], componentNodes: &componentNodes)

            let upperPropeller = topPropellerNode(material: rotorMaterial, radius: 0.30)
            upperPropeller.position = SCNVector3(tip.x, tip.y + 0.100, tip.z)
            upperPropeller.name = "propeller.colossusCA12Atlas.upper.\(index)"
            root.addChildNode(upperPropeller)
            propellers.append(upperPropeller)
            spinDirections.append(index % 2 == 0 ? 1.0 : -1.0)
            append(upperPropeller, to: propBuckets[index], componentNodes: &componentNodes)

            let lowerPropeller = topPropellerNode(material: rotorMaterial, radius: 0.30)
            lowerPropeller.position = SCNVector3(tip.x, tip.y - 0.062, tip.z)
            lowerPropeller.name = "propeller.colossusCA12Atlas.lower.\(index)"
            root.addChildNode(lowerPropeller)
            propellers.append(lowerPropeller)
            spinDirections.append(index % 2 == 0 ? -1.0 : 1.0)
            append(lowerPropeller, to: propBuckets[index], componentNodes: &componentNodes)
        }

        for side: Float in [-1.0, 1.0] {
            let skidFront = beamNode(
                start: SIMD3<Float>(0.50 * side, -0.08, 0.36),
                end: SIMD3<Float>(0.74 * side, -0.50, 0.36),
                radius: 0.028,
                material: frameMaterial
            )
            let skidRear = beamNode(
                start: SIMD3<Float>(0.50 * side, -0.08, -0.36),
                end: SIMD3<Float>(0.74 * side, -0.50, -0.36),
                radius: 0.028,
                material: frameMaterial
            )
            let rail = beamNode(
                start: SIMD3<Float>(0.74 * side, -0.50, -0.42),
                end: SIMD3<Float>(0.74 * side, -0.50, 0.42),
                radius: 0.024,
                material: frameMaterial
            )
            root.addChildNode(skidFront)
            root.addChildNode(skidRear)
            root.addChildNode(rail)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.08, 0.34)
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

        let enginePylon = beamNode(
            start: SIMD3<Float>(0.0, 0.04, -0.22),
            end: SIMD3<Float>(0.0, 0.09, -0.78),
            radius: 0.026,
            material: accentMaterial
        )
        root.addChildNode(enginePylon)
        append(enginePylon, to: .battery, componentNodes: &componentNodes)

        let leftBoom = beamNode(
            start: SIMD3<Float>(-0.34, 0.03, -0.18),
            end: SIMD3<Float>(-0.26, 0.13, -0.82),
            radius: 0.018,
            material: accentMaterial
        )
        root.addChildNode(leftBoom)
        append(leftBoom, to: .armRL, componentNodes: &componentNodes)

        let rightBoom = beamNode(
            start: SIMD3<Float>(0.34, 0.03, -0.18),
            end: SIMD3<Float>(0.26, 0.13, -0.82),
            radius: 0.018,
            material: accentMaterial
        )
        root.addChildNode(rightBoom)
        append(rightBoom, to: .armRR, componentNodes: &componentNodes)

        let tailPlane = planformNode(
            points: [
                CGPoint(x: -0.42, y: 0.03),
                CGPoint(x: 0.42, y: 0.03),
                CGPoint(x: 0.32, y: -0.08),
                CGPoint(x: -0.32, y: -0.08)
            ],
            thickness: 0.014,
            material: wingMaterial
        )
        tailPlane.position = SCNVector3(0.0, 0.14, -0.86)
        root.addChildNode(tailPlane)
        append(tailPlane, to: .armRL, componentNodes: &componentNodes)
        append(tailPlane, to: .armRR, componentNodes: &componentNodes)

        let leftFin = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.20, y: 0.0),
                CGPoint(x: 0.07, y: 0.26)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        leftFin.position = SCNVector3(-0.28, 0.14, -0.90)
        root.addChildNode(leftFin)

        let rightFin = SCNNode()
        rightFin.position = SCNVector3(0.28, 0.14, -0.90)
        rightFin.eulerAngles = SCNVector3(0.0, Float.pi, 0.0)
        rightFin.addChildNode(verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.20, y: 0.0),
                CGPoint(x: 0.07, y: 0.26)
            ],
            thickness: 0.012,
            material: wingMaterial
        ))
        root.addChildNode(rightFin)

        let sensorBall = sphereNode(radius: 0.055, material: accentMaterial)
        sensorBall.scale = SCNVector3(1.0, 0.92, 1.0)
        sensorBall.position = SCNVector3(0.0, -0.085, 0.34)
        root.addChildNode(sensorBall)
        append(sensorBall, to: .escPower, componentNodes: &componentNodes)

        // Retractable tricycle gear, drawn extended. The nose leg sits ahead of
        // the sensor turret and the mains just behind the wing root, which is
        // where an MQ-9 carries them.
        let landingGear = tricycleLandingGearNode(
            noseZ: 0.50,
            mainZ: -0.06,
            mainTrack: 0.16,
            attachY: -0.045,
            strutDrop: 0.075,
            wheelRadius: 0.030,
            strutMaterial: accentMaterial,
            tyreMaterial: material(diffuse: NSColor(calibratedWhite: 0.10, alpha: 1.0), roughness: 0.92, metalness: 0.02)
        )
        root.addChildNode(landingGear)

        let rearMotor = forwardMotorNode(radius: 0.030, length: 0.080, material: accentMaterial)
        rearMotor.position = SCNVector3(0.0, 0.09, -0.82)
        root.addChildNode(rearMotor)
        append(rearMotor, to: .motorRR, componentNodes: &componentNodes)

        let rearProp = forwardPropellerNode(material: rotorMaterial, radius: 0.18)
        rearProp.position = SCNVector3(0.0, 0.09, -0.90)
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

        // Tricycle undercarriage — the Hermes 900 operates from a runway and has
        // one, and the mains sit outboard of the belly sensor.
        let landingGear = tricycleLandingGearNode(
            noseZ: 0.38,
            mainZ: -0.08,
            mainTrack: 0.14,
            attachY: -0.040,
            strutDrop: 0.060,
            wheelRadius: 0.026,
            strutMaterial: accentMaterial,
            tyreMaterial: material(diffuse: NSColor(calibratedWhite: 0.10, alpha: 1.0), roughness: 0.92, metalness: 0.02)
        )
        root.addChildNode(landingGear)

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

    private static func buildLightFixedWingSurvey(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.lightFixedWingSurvey"

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
        rearProp.name = "propeller.lightFixedWingSurvey.rear"
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

    // MARK: - Fuel-burning and research airframes
    //
    // Every planform below is drawn to the aircraft's published proportions
    // (span-to-length, sweep, tail layout, tractor vs pusher) rather than being
    // a rescaled copy of an existing asset, because these introduce three
    // layouts the catalogue did not have: a boom-mounted inverted-V tail, a
    // tailless/canard delta with a rear pusher, and a blended wing body.
    // Absolute size still comes from the profile, not from these numbers.
    //
    // Two conventions these builders must obey, both easy to get backwards:
    //
    //  1. Assets are authored NOSE TOWARD +Z (DroneModelBuilder yaws the root by
    //     π afterwards). `planformNode` rotates its 2D path by -π/2 about X,
    //     which maps the path's local +y onto world -z — so in a planform point
    //     list **positive y is AFT**, negative y is toward the nose. Getting the
    //     sign wrong puts the wing on backwards while the separately positioned
    //     fuselage, tail and propeller stay put, which reads as parts floating
    //     loose rather than as a mirrored aircraft.
    //
    //  2. `verticalSurfaceNode` and `torusNode` return nodes that ALREADY carry
    //     an eulerAngles of their own. Assigning eulerAngles to the returned node
    //     overwrites that and drops the surface into the wrong plane. To add a
    //     rotation, wrap the node in a parent and rotate the parent — the same
    //     pattern `buildLightFixedWingSurvey` uses for its right-hand fin.

    /// Aerosonde Mk 4.7 — high-wing heavy-fuel pusher on twin booms with an
    /// inverted-V tail, the layout Textron publishes for the Mk 4.7 family.
    private static func buildAerosondeMk47(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.aerosondeMk47"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.74, green: 0.72, blue: 0.66, alpha: 1.0), roughness: 0.44, metalness: 0.10)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.62, green: 0.60, blue: 0.55, alpha: 1.0), roughness: 0.48, metalness: 0.12)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.19, alpha: 1.0), roughness: 0.30, metalness: 0.40)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.90, alpha: 0.82), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.46, radius: 0.042, material: bodyMaterial)
        fuselage.position = SCNVector3(0.0, 0.0, 0.03)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // Fuel bay sits over the wing spar on the real aircraft; drawn as a
        // separate block so the fuel installation is visible on the model.
        let fuelBay = boxNode(size: SIMD3<Float>(0.075, 0.050, 0.130), chamfer: 0.012, material: accentMaterial)
        fuelBay.position = SCNVector3(0.0, 0.034, 0.02)
        root.addChildNode(fuelBay)
        append(fuelBay, to: .battery, componentNodes: &componentNodes)

        // High-mounted constant-chord wing. Leading edge forward (negative y).
        // Half-span 0.75 against a ~0.79 overall length reproduces the published
        // 3.6 m span over 1.9 m length.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.75, y: -0.07),
                CGPoint(x: 0.75, y: -0.07),
                CGPoint(x: 0.75, y: 0.09),
                CGPoint(x: -0.75, y: 0.09)
            ],
            thickness: 0.020,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.052, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        for (side, leftComponent) in [(Float(-1.0), true), (Float(1.0), false)] {
            let boom = beamNode(
                start: SIMD3<Float>(side * 0.20, 0.046, 0.02),
                end: SIMD3<Float>(side * 0.20, 0.046, -0.34),
                radius: 0.011,
                material: accentMaterial
            )
            root.addChildNode(boom)
            append(boom, to: leftComponent ? .armRL : .armRR, componentNodes: &componentNodes)

            // Inverted-V tail: each panel cants downward and outward from the
            // boom tip, which is what distinguishes this family visually. The
            // roll goes on a parent so the panel keeps verticalSurfaceNode's
            // own orientation (see the convention note above).
            let panelPivot = SCNNode()
            panelPivot.position = SCNVector3(side * 0.20, 0.046, -0.36)
            panelPivot.eulerAngles = SCNVector3(0.0, 0.0, side * Float(0.62))
            panelPivot.addChildNode(verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.13, y: 0.0),
                    CGPoint(x: 0.05, y: -0.17)
                ],
                thickness: 0.010,
                material: wingMaterial
            ))
            root.addChildNode(panelPivot)
        }

        let engineBlock = boxNode(size: SIMD3<Float>(0.052, 0.052, 0.075), chamfer: 0.010, material: accentMaterial)
        engineBlock.position = SCNVector3(0.0, 0.012, -0.20)
        root.addChildNode(engineBlock)
        append(engineBlock, to: .motorRR, componentNodes: &componentNodes)

        let prop = forwardPropellerNode(material: rotorMaterial, radius: 0.105)
        prop.position = SCNVector3(0.0, 0.012, -0.25)
        prop.name = "propeller.aerosondeMk47.pusher"
        root.addChildNode(prop)
        append(prop, to: .propellerRR, componentNodes: &componentNodes)

        let sensorPod = sphereNode(radius: 0.038, material: accentMaterial)
        sensorPod.position = SCNVector3(0.0, -0.038, 0.13)
        root.addChildNode(sensorPod)
        append(sensorPod, to: .escPower, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.012, 0.24)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [prop],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// RQ-7B Shadow 200 — mid-wing twin-boom pusher with an inverted-V tail and
    /// the nose sensor ball, launched off a pneumatic rail.
    private static func buildRQ7BShadow(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.rq7bShadow"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.56, green: 0.57, blue: 0.53, alpha: 1.0), roughness: 0.46, metalness: 0.14)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.44, green: 0.46, blue: 0.43, alpha: 1.0), roughness: 0.50, metalness: 0.16)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.15, alpha: 1.0), roughness: 0.30, metalness: 0.42)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.88, alpha: 0.82), roughness: 0.22, metalness: 0.08)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.60, radius: 0.055, material: bodyMaterial)
        fuselage.position = SCNVector3(0.0, 0.0, 0.02)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // The RQ-7B's defining upgrade is the larger wet wing — fuel lives in
        // the wing itself, so it is drawn as an inset panel rather than a bay.
        // Half-span 0.56 against a ~0.90 overall length reproduces the published
        // 4.27 m span over 3.41 m length — the Shadow is a comparatively
        // short-span aircraft, not a high-aspect survey wing.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.56, y: -0.06),
                CGPoint(x: 0.56, y: -0.06),
                CGPoint(x: 0.56, y: 0.11),
                CGPoint(x: 0.20, y: 0.15),
                CGPoint(x: -0.20, y: 0.15),
                CGPoint(x: -0.56, y: 0.11)
            ],
            thickness: 0.024,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.020, 0.01)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        let wetWingPanel = planformNode(
            points: [
                CGPoint(x: -0.42, y: 0.005),
                CGPoint(x: 0.42, y: 0.005),
                CGPoint(x: 0.42, y: 0.032),
                CGPoint(x: -0.42, y: 0.032)
            ],
            thickness: 0.005,
            material: wingMaterial
        )
        wetWingPanel.position = SCNVector3(0.0, 0.034, 0.01)
        root.addChildNode(wetWingPanel)
        append(wetWingPanel, to: .battery, componentNodes: &componentNodes)

        for (side, isLeft) in [(Float(-1.0), true), (Float(1.0), false)] {
            let boom = beamNode(
                start: SIMD3<Float>(side * 0.22, 0.018, 0.04),
                end: SIMD3<Float>(side * 0.22, 0.018, -0.40),
                radius: 0.014,
                material: bodyMaterial
            )
            root.addChildNode(boom)
            append(boom, to: isLeft ? .armRL : .armRR, componentNodes: &componentNodes)

            // Inverted-V tail, same construction as the Aerosonde above: the
            // roll lives on a parent so the panel keeps its own orientation.
            let panelPivot = SCNNode()
            panelPivot.position = SCNVector3(side * 0.22, 0.020, -0.42)
            panelPivot.eulerAngles = SCNVector3(0.0, 0.0, side * Float(0.58))
            panelPivot.addChildNode(verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.16, y: 0.0),
                    CGPoint(x: 0.06, y: -0.22)
                ],
                thickness: 0.011,
                material: wingMaterial
            ))
            root.addChildNode(panelPivot)
        }

        let engineBlock = boxNode(size: SIMD3<Float>(0.065, 0.062, 0.100), chamfer: 0.012, material: accentMaterial)
        engineBlock.position = SCNVector3(0.0, 0.006, -0.24)
        root.addChildNode(engineBlock)
        append(engineBlock, to: .motorRR, componentNodes: &componentNodes)

        let prop = forwardPropellerNode(material: rotorMaterial, radius: 0.125)
        prop.position = SCNVector3(0.0, 0.006, -0.30)
        prop.name = "propeller.rq7bShadow.pusher"
        root.addChildNode(prop)
        append(prop, to: .propellerRR, componentNodes: &componentNodes)

        let sensorBall = sphereNode(radius: 0.052, material: accentMaterial)
        sensorBall.position = SCNVector3(0.0, -0.055, 0.16)
        root.addChildNode(sensorBall)
        append(sensorBall, to: .escPower, componentNodes: &componentNodes)

        // Fixed tricycle gear. The Shadow leaves on a catapult but comes back onto
        // a strip into an arresting cable, and it carries its wheels the whole
        // time — which is why the physics gives it a skid's friction and the
        // picture should not.
        let landingGear = tricycleLandingGearNode(
            noseZ: 0.22,
            mainZ: -0.06,
            mainTrack: 0.10,
            attachY: -0.038,
            strutDrop: 0.045,
            wheelRadius: 0.022,
            strutMaterial: accentMaterial,
            tyreMaterial: material(diffuse: NSColor(calibratedWhite: 0.10, alpha: 1.0), roughness: 0.92, metalness: 0.02)
        )
        root.addChildNode(landingGear)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.020, 0.30)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [prop],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// IAI Harpy / Harop family — tailless delta with a rear Wankel pusher,
    /// optionally with the forward canards that distinguish Harop and Harpy NG
    /// from the original Harpy.
    ///
    /// `halfSpan` is a real difference between the two, not a styling knob: the
    /// original Harpy is 2.1 m across a 2.7 m body (a slender arrow), while Harop
    /// spans 3.0 m over 2.5 m. Against this build's ~0.69 overall length that is
    /// 0.27 and 0.41 respectively.
    private static func buildDeltaLoiteringMunition(
        payloadMountOffset: SIMD3<Float>,
        canards: Bool,
        halfSpan: Float
    ) -> DroneVisualModel {
        let root = SCNNode()
        root.name = canards ? "uavRoot.canardDeltaLoiteringMunition" : "uavRoot.deltaLoiteringMunition"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.36, green: 0.37, blue: 0.35, alpha: 1.0), roughness: 0.44, metalness: 0.24)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.29, green: 0.30, blue: 0.29, alpha: 1.0), roughness: 0.48, metalness: 0.22)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.12, alpha: 1.0), roughness: 0.28, metalness: 0.46)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.86, alpha: 0.80), roughness: 0.22, metalness: 0.10)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.66, radius: 0.038, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // Tailless delta: leading edge sweeps back sharply, trailing edge is
        // straight and carries the elevons that do both pitch and roll.
        let tip = CGFloat(halfSpan)
        let deltaWing = planformNode(
            points: [
                CGPoint(x: 0.0, y: -0.30),
                CGPoint(x: tip, y: 0.20),
                CGPoint(x: tip, y: 0.30),
                CGPoint(x: -tip, y: 0.30),
                CGPoint(x: -tip, y: 0.20)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        deltaWing.position = SCNVector3(0.0, 0.004, 0.02)
        root.addChildNode(deltaWing)
        append(deltaWing, to: .armFL, componentNodes: &componentNodes)
        append(deltaWing, to: .armFR, componentNodes: &componentNodes)

        // Elevons, drawn as a distinct trailing-edge strip so the control
        // layout reads correctly: no separate elevator or aileron exists here.
        for (side, isLeft) in [(Float(-1.0), true), (Float(1.0), false)] {
            let elevon = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * tip * 0.20, y: 0.245),
                    CGPoint(x: CGFloat(side) * tip * 0.97, y: 0.245),
                    CGPoint(x: CGFloat(side) * tip * 0.97, y: 0.298),
                    CGPoint(x: CGFloat(side) * tip * 0.20, y: 0.298)
                ],
                thickness: 0.010,
                material: accentMaterial
            )
            elevon.position = SCNVector3(0.0, 0.018, 0.02)
            root.addChildNode(elevon)
            append(elevon, to: isLeft ? .armRL : .armRR, componentNodes: &componentNodes)
        }

        if canards {
            for side in [Float(-1.0), Float(1.0)] {
                let canard = planformNode(
                    points: [
                        CGPoint(x: CGFloat(side) * 0.05, y: -0.24),
                        CGPoint(x: CGFloat(side) * tip * 0.62, y: -0.19),
                        CGPoint(x: CGFloat(side) * tip * 0.62, y: -0.14),
                        CGPoint(x: CGFloat(side) * 0.05, y: -0.15)
                    ],
                    thickness: 0.010,
                    material: wingMaterial
                )
                canard.position = SCNVector3(0.0, 0.030, 0.02)
                root.addChildNode(canard)
            }
        }

        for side in [Float(-1.0), Float(1.0)] {
            let fin = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.14, y: 0.0),
                    CGPoint(x: 0.04, y: 0.12)
                ],
                thickness: 0.009,
                material: wingMaterial
            )
            fin.position = SCNVector3(side * halfSpan * 0.94, 0.012, -0.19)
            root.addChildNode(fin)
        }

        // Warhead / seeker section forward of the wing.
        let seeker = sphereNode(radius: 0.046, material: accentMaterial)
        seeker.position = SCNVector3(0.0, -0.014, 0.28)
        root.addChildNode(seeker)
        append(seeker, to: .escPower, componentNodes: &componentNodes)

        let engineBlock = boxNode(size: SIMD3<Float>(0.058, 0.056, 0.090), chamfer: 0.010, material: accentMaterial)
        engineBlock.position = SCNVector3(0.0, 0.006, -0.27)
        root.addChildNode(engineBlock)
        append(engineBlock, to: .motorRR, componentNodes: &componentNodes)

        let prop = forwardPropellerNode(material: rotorMaterial, radius: 0.10)
        prop.position = SCNVector3(0.0, 0.006, -0.33)
        prop.name = "propeller.deltaLoiteringMunition.pusher"
        root.addChildNode(prop)
        append(prop, to: .propellerRR, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.030, 0.31)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [prop],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// Small electric research delta (EPFL model-based-navigation testbed) —
    /// moulded foam delta with two elevons and a single tractor motor.
    private static func buildResearchDeltaWing(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.researchDeltaWing"

        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.74, green: 0.76, blue: 0.80, alpha: 1.0), roughness: 0.58, metalness: 0.04)
        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.24, green: 0.44, blue: 0.70, alpha: 1.0), roughness: 0.42, metalness: 0.10)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1.0), roughness: 0.32, metalness: 0.38)
        let rotorMaterial = material(diffuse: NSColor(calibratedWhite: 0.92, alpha: 0.78), roughness: 0.20, metalness: 0.06)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        // Enlarged instrument fuselage — the modification that distinguishes
        // the research aircraft from the stock airframe its wings come from.
        let fuselage = horizontalCapsule(length: 0.44, radius: 0.028, material: bodyMaterial)
        fuselage.position = SCNVector3(0.0, 0.012, 0.03)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // Half-span 0.46 over a ~0.58 length matches the donor airframe's
        // published 1.245 m span against its 0.78 m body.
        let deltaWing = planformNode(
            points: [
                CGPoint(x: 0.0, y: -0.30),
                CGPoint(x: 0.46, y: 0.16),
                CGPoint(x: 0.46, y: 0.24),
                CGPoint(x: -0.46, y: 0.24),
                CGPoint(x: -0.46, y: 0.16)
            ],
            thickness: 0.020,
            material: wingMaterial
        )
        deltaWing.position = SCNVector3(0.0, 0.0, 0.02)
        root.addChildNode(deltaWing)
        append(deltaWing, to: .armFL, componentNodes: &componentNodes)
        append(deltaWing, to: .armFR, componentNodes: &componentNodes)

        for (side, isLeft) in [(Float(-1.0), true), (Float(1.0), false)] {
            let elevon = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * 0.08, y: 0.185),
                    CGPoint(x: CGFloat(side) * 0.44, y: 0.185),
                    CGPoint(x: CGFloat(side) * 0.44, y: 0.238),
                    CGPoint(x: CGFloat(side) * 0.08, y: 0.238)
                ],
                thickness: 0.009,
                material: accentMaterial
            )
            elevon.position = SCNVector3(0.0, 0.016, 0.02)
            root.addChildNode(elevon)
            append(elevon, to: isLeft ? .armRL : .armRR, componentNodes: &componentNodes)
        }

        for side in [Float(-1.0), Float(1.0)] {
            let winglet = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.10, y: 0.0),
                    CGPoint(x: 0.03, y: 0.10)
                ],
                thickness: 0.008,
                material: bodyMaterial
            )
            winglet.position = SCNVector3(side * 0.44, 0.010, -0.13)
            root.addChildNode(winglet)
        }

        let batteryPack = boxNode(size: SIMD3<Float>(0.060, 0.030, 0.100), chamfer: 0.008, material: accentMaterial)
        batteryPack.position = SCNVector3(0.0, -0.020, 0.06)
        root.addChildNode(batteryPack)
        append(batteryPack, to: .battery, componentNodes: &componentNodes)

        // Tractor installation: the disc has to sit ahead of the delta's apex
        // (z = +0.30), not inside the planform.
        let motor = forwardMotorNode(radius: 0.020, length: 0.048, material: accentMaterial)
        motor.position = SCNVector3(0.0, 0.016, 0.31)
        root.addChildNode(motor)
        append(motor, to: .motorFL, componentNodes: &componentNodes)

        let prop = forwardPropellerNode(material: rotorMaterial, radius: 0.085)
        prop.position = SCNVector3(0.0, 0.016, 0.35)
        prop.name = "propeller.researchDeltaWing.tractor"
        root.addChildNode(prop)
        append(prop, to: .propellerFL, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.026, 0.20)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [prop],
            propellerSpinDirections: [1.0],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// Blended wing-body research testbed — no distinct fuselage, twin outboard
    /// vertical stabilisers, dorsal-mounted mini turbojet, light fixed tricycle
    /// gear for its runway takeoff.
    private static func buildBlendedWingBodyTestbed(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.blendedWingBodyTestbed"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.80, green: 0.81, blue: 0.84, alpha: 1.0), roughness: 0.40, metalness: 0.16)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.68, green: 0.70, blue: 0.74, alpha: 1.0), roughness: 0.44, metalness: 0.18)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.18, alpha: 1.0), roughness: 0.30, metalness: 0.44)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        // Thick centre body blended straight into the wing — the whole point of
        // the configuration is that there is no fuselage/wing joint.
        // Half-span 0.54 over a ~0.56 length reproduces the published 2.859 m
        // span against the 1.473 m root chord.
        let centreBody = planformNode(
            points: [
                CGPoint(x: -0.05, y: -0.32),
                CGPoint(x: 0.05, y: -0.32),
                CGPoint(x: 0.17, y: -0.16),
                CGPoint(x: 0.19, y: 0.20),
                CGPoint(x: -0.19, y: 0.20),
                CGPoint(x: -0.17, y: -0.16)
            ],
            thickness: 0.070,
            material: wingMaterial
        )
        centreBody.position = SCNVector3(0.0, 0.0, 0.0)
        root.addChildNode(centreBody)
        append(centreBody, to: .flightControllerCore, componentNodes: &componentNodes)

        // Outboard panels: strongly tapered, root chord several times the tip.
        let outerWing = planformNode(
            points: [
                CGPoint(x: -0.17, y: -0.16),
                CGPoint(x: 0.17, y: -0.16),
                CGPoint(x: 0.54, y: 0.06),
                CGPoint(x: 0.54, y: 0.16),
                CGPoint(x: -0.54, y: 0.16),
                CGPoint(x: -0.54, y: 0.06)
            ],
            thickness: 0.026,
            material: wingMaterial
        )
        outerWing.position = SCNVector3(0.0, 0.010, 0.0)
        root.addChildNode(outerWing)
        append(outerWing, to: .armFL, componentNodes: &componentNodes)
        append(outerWing, to: .armFR, componentNodes: &componentNodes)

        // Segmented trailing-edge effector array, drawn as discrete strips —
        // this aircraft's reason for existing is that its trailing edge is a
        // row of independent surfaces rather than one aileron per side.
        for index in 0..<12 {
            let side: Float = index < 6 ? -1.0 : 1.0
            let slot = Float(index % 6)
            let inner = 0.19 + slot * 0.057
            let outer = inner + 0.054
            let segment = planformNode(
                points: [
                    CGPoint(x: CGFloat(side * inner), y: 0.125),
                    CGPoint(x: CGFloat(side * outer), y: 0.125),
                    CGPoint(x: CGFloat(side * outer), y: 0.158),
                    CGPoint(x: CGFloat(side * inner), y: 0.158)
                ],
                thickness: 0.008,
                material: accentMaterial
            )
            segment.position = SCNVector3(0.0, 0.020, 0.0)
            root.addChildNode(segment)
            append(segment, to: side < 0 ? .armRL : .armRR, componentNodes: &componentNodes)
        }

        for side in [Float(-1.0), Float(1.0)] {
            let stabiliser = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.20, y: 0.0),
                    CGPoint(x: 0.13, y: 0.20),
                    CGPoint(x: 0.03, y: 0.20)
                ],
                thickness: 0.012,
                material: wingMaterial
            )
            stabiliser.position = SCNVector3(side * 0.20, 0.030, -0.10)
            root.addChildNode(stabiliser)
        }

        let engineNacelle = horizontalCapsule(length: 0.20, radius: 0.044, material: accentMaterial)
        engineNacelle.position = SCNVector3(0.0, 0.072, -0.12)
        root.addChildNode(engineNacelle)
        append(engineNacelle, to: .motorRR, componentNodes: &componentNodes)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.072, -0.23)
        root.addChildNode(jetExhaustAnchor)

        // A light fixed tricycle gear. The header of this builder used to say the
        // testbed had none and was dolly-launched; its catalogue entry declares a
        // runway takeoff, and the flight model now gives it wheels and a tyre's
        // rolling resistance on the strength of that. Two answers to one question
        // is the thing worth fixing — this is the one the rest of the aircraft is
        // built around.
        let landingGear = tricycleLandingGearNode(
            noseZ: 0.10,
            mainZ: -0.06,
            mainTrack: 0.12,
            attachY: -0.020,
            strutDrop: 0.038,
            wheelRadius: 0.020,
            strutMaterial: accentMaterial,
            tyreMaterial: material(diffuse: NSColor(calibratedWhite: 0.12, alpha: 1.0), roughness: 0.92, metalness: 0.02)
        )
        root.addChildNode(landingGear)

        let intake = torusNode(ringRadius: 0.042, pipeRadius: 0.009, material: bodyMaterial)
        intake.position = SCNVector3(0.0, 0.072, -0.02)
        root.addChildNode(intake)

        let fuelCell = boxNode(size: SIMD3<Float>(0.10, 0.030, 0.13), chamfer: 0.010, material: accentMaterial)
        fuelCell.position = SCNVector3(0.0, -0.014, 0.02)
        root.addChildNode(fuelCell)
        append(fuelCell, to: .battery, componentNodes: &componentNodes)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.010, 0.32)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        // A turbojet has no propeller disc to animate; the empty arrays keep the
        // rotor-spin driver a no-op instead of spinning an invented prop.
        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// Jet-powered cropped-delta drone with a dorsal intake, wingtip fins and
    /// underwing hardpoints — rocket-assisted launch, parachute recovery, so no
    /// landing gear is modelled.
    private static func buildJetTargetDrone(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.jetTargetDrone"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.46, green: 0.48, blue: 0.50, alpha: 1.0), roughness: 0.38, metalness: 0.34)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.38, green: 0.40, blue: 0.42, alpha: 1.0), roughness: 0.42, metalness: 0.30)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1.0), roughness: 0.26, metalness: 0.52)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.82, radius: 0.058, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // Tailpipe. The scene controller hangs the exhaust plume here and drives it
        // from the engine's spool fraction; a jet with a cold tailpipe at 200 m/s
        // reads as a glider.
        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.0, -0.44)
        root.addChildNode(jetExhaustAnchor)

        let nose = sphereNode(radius: 0.056, material: bodyMaterial)
        nose.position = SCNVector3(0.0, 0.0, 0.40)
        nose.scale = SCNVector3(1.0, 1.0, 1.45)
        root.addChildNode(nose)

        // Cropped delta: swept leading edge, clipped tips carrying the fins.
        // Half-span 0.30 over a ~0.96 length reproduces the published 2.5 m
        // span against the 4.0 m fuselage — a long body on a small cropped delta.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.08, y: -0.16),
                CGPoint(x: 0.08, y: -0.16),
                CGPoint(x: 0.30, y: 0.18),
                CGPoint(x: 0.30, y: 0.26),
                CGPoint(x: -0.30, y: 0.26),
                CGPoint(x: -0.30, y: 0.18)
            ],
            thickness: 0.022,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, -0.004, -0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        for (side, isLeft) in [(Float(-1.0), true), (Float(1.0), false)] {
            let elevon = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * 0.07, y: 0.205),
                    CGPoint(x: CGFloat(side) * 0.29, y: 0.205),
                    CGPoint(x: CGFloat(side) * 0.29, y: 0.256),
                    CGPoint(x: CGFloat(side) * 0.07, y: 0.256)
                ],
                thickness: 0.009,
                material: accentMaterial
            )
            elevon.position = SCNVector3(0.0, 0.014, -0.02)
            root.addChildNode(elevon)
            append(elevon, to: isLeft ? .armRL : .armRR, componentNodes: &componentNodes)

            let tipFin = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.15, y: 0.0),
                    CGPoint(x: 0.05, y: 0.14)
                ],
                thickness: 0.010,
                material: wingMaterial
            )
            tipFin.position = SCNVector3(side * 0.29, 0.006, -0.18)
            root.addChildNode(tipFin)

            let hardpoint = boxNode(size: SIMD3<Float>(0.030, 0.028, 0.150), chamfer: 0.008, material: accentMaterial)
            hardpoint.position = SCNVector3(side * 0.17, -0.038, -0.05)
            root.addChildNode(hardpoint)
        }

        // Dorsal intake and tailpipe.
        let intakeDuct = boxNode(size: SIMD3<Float>(0.085, 0.060, 0.190), chamfer: 0.020, material: bodyMaterial)
        intakeDuct.position = SCNVector3(0.0, 0.062, 0.05)
        root.addChildNode(intakeDuct)
        append(intakeDuct, to: .motorRR, componentNodes: &componentNodes)

        let intakeLip = torusNode(ringRadius: 0.040, pipeRadius: 0.009, material: accentMaterial)
        intakeLip.position = SCNVector3(0.0, 0.064, 0.145)
        root.addChildNode(intakeLip)

        let exhaust = cylinderNode(radius: 0.048, height: 0.085, material: accentMaterial)
        exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        exhaust.position = SCNVector3(0.0, 0.0, -0.44)
        root.addChildNode(exhaust)
        append(exhaust, to: .escPower, componentNodes: &componentNodes)

        let fuelCell = boxNode(size: SIMD3<Float>(0.090, 0.055, 0.240), chamfer: 0.014, material: accentMaterial)
        fuelCell.position = SCNVector3(0.0, -0.014, 0.04)
        root.addChildNode(fuelCell)
        append(fuelCell, to: .battery, componentNodes: &componentNodes)

        let verticalTail = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.22, y: 0.0),
                CGPoint(x: 0.16, y: 0.20),
                CGPoint(x: 0.06, y: 0.20)
            ],
            thickness: 0.012,
            material: wingMaterial
        )
        verticalTail.position = SCNVector3(0.0, 0.030, -0.40)
        root.addChildNode(verticalTail)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, -0.026, 0.44)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    // MARK: - Supersonic reference aircraft
    //
    // All five are authored at roughly one sixth of full size, which is the scale the
    // existing large airframes in this catalogue use (the MQ-9B's scene model is 3.2 m
    // against a 24 m span). The physics does not read these dimensions — it takes the
    // real ones from the catalogue entry — so the scale here is a scene convention, and
    // matching the rest of the fleet matters more than matching a tape measure.
    //
    // Shape conventions in this file, both of which are easy to get wrong: the nose
    // points along **+Z**, and inside `planformNode` a shape's **+Y is aft**.

    /// Ryan BQM-34F Firebee II.
    ///
    /// The silhouette that matters is the slenderness. Almost all of this aircraft is
    /// fuselage: a 8.89 m body on a 2.94 m span, with a small cropped-delta wing set low
    /// and a cruciform tail. That ratio is not styling — it is why a 951 kg target drone
    /// on 8.5 kN of thrust reaches Mach 1.78, and why its wave-drag peak is a third of
    /// what a straight-winged aircraft would pay.
    private static func buildFirebeeII(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.bqm34fFirebeeII"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.86, green: 0.32, blue: 0.13, alpha: 1.0), roughness: 0.42, metalness: 0.22)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.78, green: 0.29, blue: 0.12, alpha: 1.0), roughness: 0.46, metalness: 0.20)
        let accentMaterial = material(diffuse: NSColor(calibratedWhite: 0.13, alpha: 1.0), roughness: 0.30, metalness: 0.55)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.30, radius: 0.055, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let nose = sphereNode(radius: 0.054, material: bodyMaterial)
        nose.position = SCNVector3(0.0, 0.0, 0.66)
        nose.scale = SCNVector3(1.0, 1.0, 1.9)
        root.addChildNode(nose)

        // Chin scoop: a plain forward-facing hole under the forward fuselage. One normal
        // shock, and the reason this aircraft dashes to Mach 1.78 rather than cruising
        // there.
        let intake = boxNode(size: SIMD3<Float>(0.090, 0.060, 0.230), chamfer: 0.022, material: bodyMaterial)
        intake.position = SCNVector3(0.0, -0.062, 0.20)
        root.addChildNode(intake)
        append(intake, to: .motorRR, componentNodes: &componentNodes)

        let intakeLip = torusNode(ringRadius: 0.040, pipeRadius: 0.008, material: accentMaterial)
        intakeLip.position = SCNVector3(0.0, -0.064, 0.312)
        root.addChildNode(intakeLip)

        // Cropped delta, low-set. Half-span 0.245 against a 1.48 m length reproduces the
        // published 2.94 m span on an 8.89 m body.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.055, y: -0.10),
                CGPoint(x: 0.055, y: -0.10),
                CGPoint(x: 0.245, y: 0.16),
                CGPoint(x: 0.245, y: 0.22),
                CGPoint(x: -0.245, y: 0.22),
                CGPoint(x: -0.245, y: 0.16)
            ],
            thickness: 0.016,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, -0.020, 0.02)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        // Cruciform tail: four identical surfaces at ninety degrees. The large total fin
        // area is what keeps a slender body pointed the right way at Mach 1.8, and it is
        // why this planform's weathercock stability is set so much higher than a
        // conventional wing's.
        for index in 0..<4 {
            let surface = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.20, y: 0.0),
                    CGPoint(x: 0.17, y: 0.15),
                    CGPoint(x: 0.07, y: 0.15)
                ],
                thickness: 0.010,
                material: wingMaterial
            )
            let carrier = SCNNode()
            carrier.addChildNode(surface)
            carrier.eulerAngles = SCNVector3(0.0, 0.0, Float(index) * Float.pi / 2.0)
            carrier.position = SCNVector3(0.0, 0.0, -0.56)
            root.addChildNode(carrier)
            append(carrier, to: index % 2 == 0 ? .armRL : .armRR, componentNodes: &componentNodes)
        }

        let exhaust = cylinderNode(radius: 0.046, height: 0.070, material: accentMaterial)
        exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        exhaust.position = SCNVector3(0.0, 0.0, -0.70)
        root.addChildNode(exhaust)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.0, -0.74)
        root.addChildNode(jetExhaustAnchor)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.012, 0.60)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// Northrop AQM-35, both marks.
    ///
    /// A 20-inch tube with wings — the published body diameter is 0.51 m on a 10 m
    /// length, which is a fineness ratio of twenty. The wing is mid-mounted, small and
    /// nearly unswept at the trailing edge; the tail is cruciform like the Firebee's but
    /// set further aft on a longer moment arm.
    private static func buildAQM35(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.aqm35TargetDrone"

        let bodyMaterial = material(diffuse: NSColor(calibratedRed: 0.90, green: 0.88, blue: 0.84, alpha: 1.0), roughness: 0.38, metalness: 0.30)
        let wingMaterial = material(diffuse: NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.16, alpha: 1.0), roughness: 0.44, metalness: 0.22)
        let accentMaterial = material(diffuse: NSColor(calibratedWhite: 0.15, alpha: 1.0), roughness: 0.30, metalness: 0.58)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 1.52, radius: 0.043, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // A sharp ogive nose rather than a rounded one. Above Mach 1.5 the nose shape is
        // a drag term rather than a styling choice.
        let nose = cylinderNode(radius: 0.043, height: 0.24, material: bodyMaterial)
        nose.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        nose.scale = SCNVector3(1.0, 1.0, 0.45)
        nose.position = SCNVector3(0.0, 0.0, 0.78)
        root.addChildNode(nose)

        let noseTip = sphereNode(radius: 0.020, material: accentMaterial)
        noseTip.position = SCNVector3(0.0, 0.0, 0.90)
        noseTip.scale = SCNVector3(1.0, 1.0, 2.2)
        root.addChildNode(noseTip)

        // Twin side intakes with a splitter plate — the fixed-ramp arrangement the B
        // needs for Mach 2, and visibly different from the Firebee's single chin scoop.
        for side in [Float(-1.0), Float(1.0)] {
            let duct = boxNode(size: SIMD3<Float>(0.055, 0.055, 0.210), chamfer: 0.016, material: bodyMaterial)
            duct.position = SCNVector3(side * 0.058, -0.012, 0.24)
            root.addChildNode(duct)
            append(duct, to: side < 0 ? .motorRL : .motorRR, componentNodes: &componentNodes)

            let splitter = boxNode(size: SIMD3<Float>(0.008, 0.048, 0.120), chamfer: 0.003, material: accentMaterial)
            splitter.position = SCNVector3(side * 0.086, -0.012, 0.30)
            root.addChildNode(splitter)
        }

        let wing = planformNode(
            points: [
                CGPoint(x: -0.048, y: -0.09),
                CGPoint(x: 0.048, y: -0.09),
                CGPoint(x: 0.282, y: 0.10),
                CGPoint(x: 0.282, y: 0.18),
                CGPoint(x: -0.282, y: 0.18),
                CGPoint(x: -0.282, y: 0.10)
            ],
            thickness: 0.014,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.0, -0.04)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        for index in 0..<4 {
            let surface = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.18, y: 0.0),
                    CGPoint(x: 0.15, y: 0.14),
                    CGPoint(x: 0.05, y: 0.14)
                ],
                thickness: 0.009,
                material: wingMaterial
            )
            let carrier = SCNNode()
            carrier.addChildNode(surface)
            carrier.eulerAngles = SCNVector3(0.0, 0.0, Float(index) * Float.pi / 2.0 + Float.pi / 4.0)
            carrier.position = SCNVector3(0.0, 0.0, -0.66)
            root.addChildNode(carrier)
            append(carrier, to: index % 2 == 0 ? .armRL : .armRR, componentNodes: &componentNodes)
        }

        let exhaust = cylinderNode(radius: 0.038, height: 0.060, material: accentMaterial)
        exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        exhaust.position = SCNVector3(0.0, 0.0, -0.80)
        root.addChildNode(exhaust)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.0, -0.84)
        root.addChildNode(jetExhaustAnchor)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.010, 0.72)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// NASA / Rockwell HiMAT.
    ///
    /// Four features, and every one of them was a research objective rather than
    /// decoration: close-coupled canards ahead of the wing, winglets at the tips, twin
    /// outward-canted fins, and a rearward-swept planform with aeroelastically tailored
    /// composite skins. The canards are the reason this aircraft's aerodynamic centre
    /// barely moves through Mach 1, which is modelled explicitly in its aero family.
    private static func buildHiMAT(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.rockwellHiMAT"

        let bodyMaterial = material(diffuse: NSColor(calibratedWhite: 0.93, alpha: 1.0), roughness: 0.34, metalness: 0.18)
        let wingMaterial = material(diffuse: NSColor(calibratedWhite: 0.88, alpha: 1.0), roughness: 0.38, metalness: 0.16)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.52, alpha: 1.0), roughness: 0.30, metalness: 0.30)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 0.98, radius: 0.062, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let nose = sphereNode(radius: 0.058, material: bodyMaterial)
        nose.position = SCNVector3(0.0, 0.006, 0.50)
        nose.scale = SCNVector3(0.9, 0.8, 2.1)
        root.addChildNode(nose)

        // Chin inlet, set well under the forebody so it stays in clean air when the
        // aircraft is pulling eight g.
        let intake = boxNode(size: SIMD3<Float>(0.110, 0.055, 0.200), chamfer: 0.020, material: bodyMaterial)
        intake.position = SCNVector3(0.0, -0.068, 0.16)
        root.addChildNode(intake)
        append(intake, to: .motorRR, componentNodes: &componentNodes)

        // Close-coupled canards: small, well forward, and set slightly above the wing
        // plane so their vortices pass over it rather than into it.
        for side in [Float(-1.0), Float(1.0)] {
            let canard = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * 0.045, y: -0.035),
                    CGPoint(x: CGFloat(side) * 0.185, y: 0.030),
                    CGPoint(x: CGFloat(side) * 0.185, y: 0.062),
                    CGPoint(x: CGFloat(side) * 0.045, y: 0.055)
                ],
                thickness: 0.010,
                material: accentMaterial
            )
            canard.position = SCNVector3(0.0, 0.028, 0.28)
            root.addChildNode(canard)
            append(canard, to: side < 0 ? .armFL : .armFR, componentNodes: &componentNodes)
        }

        // Cranked, sharply swept wing with winglets.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.062, y: -0.20),
                CGPoint(x: 0.062, y: -0.20),
                CGPoint(x: 0.396, y: 0.16),
                CGPoint(x: 0.396, y: 0.235),
                CGPoint(x: -0.396, y: 0.235),
                CGPoint(x: -0.396, y: 0.16)
            ],
            thickness: 0.016,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, -0.006, -0.10)
        root.addChildNode(wing)
        append(wing, to: .armRL, componentNodes: &componentNodes)
        append(wing, to: .armRR, componentNodes: &componentNodes)

        for side in [Float(-1.0), Float(1.0)] {
            // Winglets — one of the technologies the programme existed to demonstrate.
            let winglet = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.09, y: 0.0),
                    CGPoint(x: 0.06, y: 0.10),
                    CGPoint(x: 0.02, y: 0.10)
                ],
                thickness: 0.008,
                material: accentMaterial
            )
            winglet.position = SCNVector3(side * 0.396, 0.004, -0.02)
            root.addChildNode(winglet)

            // Twin fins, canted outward, mounted on the aft fuselage.
            let fin = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.15, y: 0.0),
                    CGPoint(x: 0.11, y: 0.16),
                    CGPoint(x: 0.03, y: 0.16)
                ],
                thickness: 0.009,
                material: wingMaterial
            )
            let finCarrier = SCNNode()
            finCarrier.addChildNode(fin)
            finCarrier.eulerAngles = SCNVector3(0.0, 0.0, side * 0.30)
            finCarrier.position = SCNVector3(side * 0.075, 0.030, -0.36)
            root.addChildNode(finCarrier)
        }

        let exhaust = cylinderNode(radius: 0.050, height: 0.070, material: accentMaterial)
        exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        exhaust.position = SCNVector3(0.0, 0.0, -0.52)
        root.addChildNode(exhaust)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.0, -0.56)
        root.addChildNode(jetExhaustAnchor)

        // Three skids rather than wheels: it lands on a dry lakebed and there is no
        // runway anywhere in the programme.
        for offset in [SIMD3<Float>(0.0, -0.070, 0.24), SIMD3<Float>(-0.16, -0.072, -0.12), SIMD3<Float>(0.16, -0.072, -0.12)] {
            let skid = boxNode(size: SIMD3<Float>(0.026, 0.016, 0.100), chamfer: 0.006, material: accentMaterial)
            skid.position = SCNVector3(offset.x, offset.y, offset.z)
            root.addChildNode(skid)
            append(skid, to: .escPower, componentNodes: &componentNodes)
        }

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.026, 0.44)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// Hermeus Quarterhorse Mk 2.1.
    ///
    /// Built from what Hermeus has actually shown: a delta wing, a single vertical
    /// stabiliser, and a variable inlet in the nose — the aircraft breathes through its
    /// nose cone rather than through side or chin intakes, which is unusual enough to be
    /// the recognisable feature. Proportions follow the company's own description of an
    /// F-16-sized aircraft; exact dimensions are not published, which the catalogue entry
    /// states plainly.
    private static func buildQuarterhorse(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.hermeusQuarterhorse"

        let bodyMaterial = material(diffuse: NSColor(calibratedWhite: 0.20, alpha: 1.0), roughness: 0.36, metalness: 0.52)
        let wingMaterial = material(diffuse: NSColor(calibratedWhite: 0.16, alpha: 1.0), roughness: 0.40, metalness: 0.48)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.85, green: 0.55, blue: 0.10, alpha: 1.0), roughness: 0.28, metalness: 0.40)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 2.10, radius: 0.105, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        // The nose inlet. An annular lip around a translating centrebody: this is the
        // variable geometry that makes a Mach 2.5 target reachable, and the precooler
        // sits directly behind it.
        let inletLip = torusNode(ringRadius: 0.095, pipeRadius: 0.016, material: accentMaterial)
        inletLip.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        inletLip.position = SCNVector3(0.0, 0.0, 1.05)
        root.addChildNode(inletLip)
        append(inletLip, to: .motorRR, componentNodes: &componentNodes)

        let centreBody = cylinderNode(radius: 0.048, height: 0.18, material: bodyMaterial)
        centreBody.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        centreBody.scale = SCNVector3(1.0, 1.0, 0.5)
        centreBody.position = SCNVector3(0.0, 0.0, 1.10)
        root.addChildNode(centreBody)

        let centreBodyTip = sphereNode(radius: 0.044, material: accentMaterial)
        centreBodyTip.position = SCNVector3(0.0, 0.0, 1.16)
        centreBodyTip.scale = SCNVector3(1.0, 1.0, 1.8)
        root.addChildNode(centreBodyTip)

        // Delta wing, blended into the body.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.105, y: -0.62),
                CGPoint(x: 0.105, y: -0.62),
                CGPoint(x: 0.700, y: 0.42),
                CGPoint(x: 0.700, y: 0.54),
                CGPoint(x: -0.700, y: 0.54),
                CGPoint(x: -0.700, y: 0.42)
            ],
            thickness: 0.028,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, -0.026, -0.18)
        root.addChildNode(wing)
        append(wing, to: .armFL, componentNodes: &componentNodes)
        append(wing, to: .armFR, componentNodes: &componentNodes)

        for (side, isLeft) in [(Float(-1.0), true), (Float(1.0), false)] {
            let elevon = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * 0.16, y: 0.455),
                    CGPoint(x: CGFloat(side) * 0.68, y: 0.455),
                    CGPoint(x: CGFloat(side) * 0.68, y: 0.535),
                    CGPoint(x: CGFloat(side) * 0.16, y: 0.535)
                ],
                thickness: 0.012,
                material: accentMaterial
            )
            elevon.position = SCNVector3(0.0, -0.008, -0.18)
            root.addChildNode(elevon)
            append(elevon, to: isLeft ? .armRL : .armRR, componentNodes: &componentNodes)

            // Retractable tricycle gear: this aircraft takes off and lands on a runway
            // under its own power, which is what separates it from every other
            // supersonic aircraft in this catalogue except the X-10.
            let gear = boxNode(size: SIMD3<Float>(0.030, 0.090, 0.048), chamfer: 0.010, material: accentMaterial)
            gear.position = SCNVector3(side * 0.24, -0.132, -0.16)
            root.addChildNode(gear)
            append(gear, to: .escPower, componentNodes: &componentNodes)
        }

        let noseGear = boxNode(size: SIMD3<Float>(0.026, 0.080, 0.042), chamfer: 0.009, material: accentMaterial)
        noseGear.position = SCNVector3(0.0, -0.126, 0.62)
        root.addChildNode(noseGear)
        append(noseGear, to: .escPower, componentNodes: &componentNodes)

        let fin = verticalSurfaceNode(
            points: [
                CGPoint(x: 0.0, y: 0.0),
                CGPoint(x: 0.42, y: 0.0),
                CGPoint(x: 0.34, y: 0.40),
                CGPoint(x: 0.16, y: 0.40)
            ],
            thickness: 0.018,
            material: wingMaterial
        )
        fin.position = SCNVector3(0.0, 0.060, -0.86)
        root.addChildNode(fin)

        let exhaust = cylinderNode(radius: 0.092, height: 0.130, material: accentMaterial)
        exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        exhaust.position = SCNVector3(0.0, 0.0, -1.06)
        root.addChildNode(exhaust)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, 0.0, -1.14)
        root.addChildNode(jetExhaustAnchor)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.070, 0.72)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    /// North American X-10.
    ///
    /// A 20-metre canard delta from 1953 with two afterburning turbojets side by side in
    /// the aft fuselage, a large mid-set delta wing, twin canted fins and retractable
    /// tricycle gear. It is the only twin-engined aircraft in this catalogue, and the
    /// only supersonic one besides the Quarterhorse that leaves the ground on its own
    /// wheels.
    private static func buildX10(payloadMountOffset: SIMD3<Float>) -> DroneVisualModel {
        let root = SCNNode()
        root.name = "uavRoot.northAmericanX10"

        let bodyMaterial = material(diffuse: NSColor(calibratedWhite: 0.80, alpha: 1.0), roughness: 0.30, metalness: 0.62)
        let wingMaterial = material(diffuse: NSColor(calibratedWhite: 0.74, alpha: 1.0), roughness: 0.34, metalness: 0.58)
        let accentMaterial = material(diffuse: NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.14, alpha: 1.0), roughness: 0.32, metalness: 0.30)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]

        let fuselage = horizontalCapsule(length: 2.90, radius: 0.115, material: bodyMaterial)
        root.addChildNode(fuselage)
        append(fuselage, to: .flightControllerCore, componentNodes: &componentNodes)

        let nose = cylinderNode(radius: 0.112, height: 0.50, material: bodyMaterial)
        nose.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        nose.scale = SCNVector3(1.0, 1.0, 0.40)
        nose.position = SCNVector3(0.0, 0.0, 1.52)
        root.addChildNode(nose)

        let noseTip = sphereNode(radius: 0.048, material: accentMaterial)
        noseTip.position = SCNVector3(0.0, 0.0, 1.70)
        noseTip.scale = SCNVector3(1.0, 1.0, 2.0)
        root.addChildNode(noseTip)

        // Canards well forward on the nose. On the X-10 they are trimming surfaces on a
        // long arm rather than the close-coupled lift generators HiMAT carries — the same
        // configuration name doing a different job, which is why both aircraft use the
        // canard-delta family and differ in everything else.
        for side in [Float(-1.0), Float(1.0)] {
            let canard = planformNode(
                points: [
                    CGPoint(x: CGFloat(side) * 0.090, y: -0.10),
                    CGPoint(x: CGFloat(side) * 0.340, y: 0.02),
                    CGPoint(x: CGFloat(side) * 0.340, y: 0.10),
                    CGPoint(x: CGFloat(side) * 0.090, y: 0.14)
                ],
                thickness: 0.016,
                material: accentMaterial
            )
            canard.position = SCNVector3(0.0, 0.030, 1.10)
            root.addChildNode(canard)
            append(canard, to: side < 0 ? .armFL : .armFR, componentNodes: &componentNodes)
        }

        // Mid-set delta. Half-span 0.715 on a 3.36 m length reproduces the published
        // 8.59 m span against a 20.17 m body.
        let wing = planformNode(
            points: [
                CGPoint(x: -0.115, y: -0.72),
                CGPoint(x: 0.115, y: -0.72),
                CGPoint(x: 0.715, y: 0.34),
                CGPoint(x: 0.715, y: 0.46),
                CGPoint(x: -0.715, y: 0.46),
                CGPoint(x: -0.715, y: 0.34)
            ],
            thickness: 0.030,
            material: wingMaterial
        )
        wing.position = SCNVector3(0.0, 0.004, -0.34)
        root.addChildNode(wing)
        append(wing, to: .armRL, componentNodes: &componentNodes)
        append(wing, to: .armRR, componentNodes: &componentNodes)

        for side in [Float(-1.0), Float(1.0)] {
            // Twin fins, canted outward at the wingtips — the X-10's most recognisable
            // feature after its size.
            let fin = verticalSurfaceNode(
                points: [
                    CGPoint(x: 0.0, y: 0.0),
                    CGPoint(x: 0.36, y: 0.0),
                    CGPoint(x: 0.27, y: 0.34),
                    CGPoint(x: 0.09, y: 0.34)
                ],
                thickness: 0.016,
                material: wingMaterial
            )
            let carrier = SCNNode()
            carrier.addChildNode(fin)
            carrier.eulerAngles = SCNVector3(0.0, 0.0, side * 0.26)
            carrier.position = SCNVector3(side * 0.640, 0.020, -0.62)
            root.addChildNode(carrier)

            // Two engines, side by side in the aft fuselage.
            let exhaust = cylinderNode(radius: 0.072, height: 0.150, material: accentMaterial)
            exhaust.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            exhaust.position = SCNVector3(side * 0.082, -0.010, -1.44)
            root.addChildNode(exhaust)
            append(exhaust, to: side < 0 ? .motorRL : .motorRR, componentNodes: &componentNodes)

            // Fixed side intakes with a splitter, cut for Mach 2.
            let duct = boxNode(size: SIMD3<Float>(0.085, 0.105, 0.420), chamfer: 0.024, material: bodyMaterial)
            duct.position = SCNVector3(side * 0.150, -0.020, 0.10)
            root.addChildNode(duct)

            let splitter = boxNode(size: SIMD3<Float>(0.010, 0.095, 0.180), chamfer: 0.004, material: accentMaterial)
            splitter.position = SCNVector3(side * 0.194, -0.020, 0.28)
            root.addChildNode(splitter)

            let mainGear = boxNode(size: SIMD3<Float>(0.038, 0.115, 0.062), chamfer: 0.012, material: accentMaterial)
            mainGear.position = SCNVector3(side * 0.30, -0.168, -0.28)
            root.addChildNode(mainGear)
            append(mainGear, to: .escPower, componentNodes: &componentNodes)
        }

        let noseGear = boxNode(size: SIMD3<Float>(0.032, 0.105, 0.055), chamfer: 0.010, material: accentMaterial)
        noseGear.position = SCNVector3(0.0, -0.162, 0.94)
        root.addChildNode(noseGear)
        append(noseGear, to: .escPower, componentNodes: &componentNodes)

        let jetExhaustAnchor = SCNNode()
        jetExhaustAnchor.name = "jetExhaustAnchor"
        jetExhaustAnchor.position = SCNVector3(0.0, -0.010, -1.56)
        root.addChildNode(jetExhaustAnchor)

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.position = SCNVector3(0.0, 0.060, 1.24)
        root.addChildNode(fpvAnchor)
        append(fpvAnchor, to: .frontCameraGimbal, componentNodes: &componentNodes)

        let payloadMountNode = makePayloadMountNode(offset: payloadMountOffset)
        root.addChildNode(payloadMountNode)

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: [],
            propellerSpinDirections: [],
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode
        )
    }

    private static func append(_ node: SCNNode, to component: DamageComponent, componentNodes: inout [DamageComponent: [SCNNode]]) {
        componentNodes[component, default: []].append(node)
    }

    private static func visualVariant(
        _ model: DroneVisualModel,
        name: String,
        scale: Float,
        accents: [AirframeAccent] = []
    ) -> DroneVisualModel {
        model.rootNode.name = name
        for accent in accents {
            applyAirframeAccent(accent, to: model.rootNode)
        }
        model.rootNode.scale = SCNVector3(scale, scale, scale)
        return model
    }

    private static func applyAirframeAccent(_ accent: AirframeAccent, to root: SCNNode) {
        switch accent {
        case let .topPanel(color, size, position):
            let panel = boxNode(size: size, chamfer: 0.006, material: material(diffuse: color, roughness: 0.30, metalness: 0.22))
            panel.name = "airframe.accent.topPanel"
            panel.position = SCNVector3(position.x, position.y, position.z)
            root.addChildNode(panel)
        case let .sideRails(color):
            let railMaterial = material(diffuse: color, roughness: 0.36, metalness: 0.24)
            for side: Float in [-1.0, 1.0] {
                let rail = beamNode(
                    start: SIMD3<Float>(0.090 * side, 0.030, -0.085),
                    end: SIMD3<Float>(0.090 * side, 0.030, 0.090),
                    radius: 0.006,
                    material: railMaterial
                )
                rail.name = "airframe.accent.sideRail"
                root.addChildNode(rail)
            }
        case .dockShell:
            let shellMaterial = material(
                diffuse: NSColor(calibratedRed: 0.74, green: 0.77, blue: 0.80, alpha: 1.0),
                roughness: 0.32,
                metalness: 0.18
            )
            let deck = boxNode(size: SIMD3<Float>(0.160, 0.018, 0.112), chamfer: 0.008, material: shellMaterial)
            deck.name = "airframe.accent.dockShell"
            deck.position = SCNVector3(0.0, 0.084, -0.016)
            root.addChildNode(deck)

            let finMaterial = material(diffuse: NSColor(calibratedWhite: 0.12, alpha: 1.0), roughness: 0.36, metalness: 0.22)
            for side: Float in [-1.0, 1.0] {
                let fin = boxNode(size: SIMD3<Float>(0.010, 0.052, 0.072), chamfer: 0.004, material: finMaterial)
                fin.name = "airframe.accent.dockFin"
                fin.position = SCNVector3(0.070 * side, 0.068, -0.010)
                root.addChildNode(fin)
            }
        case let .fixedWingWinglets(color):
            let wingletMaterial = material(diffuse: color, roughness: 0.34, metalness: 0.14)
            for side: Float in [-1.0, 1.0] {
                let winglet = boxNode(size: SIMD3<Float>(0.020, 0.095, 0.040), chamfer: 0.004, material: wingletMaterial)
                winglet.name = "airframe.accent.winglet"
                winglet.position = SCNVector3(0.500 * side, 0.040, 0.000)
                winglet.eulerAngles = SCNVector3(0.0, 0.0, -0.18 * side)
                root.addChildNode(winglet)
            }
        case let .indoorGuardCage(color):
            let cageMaterial = material(diffuse: color, roughness: 0.42, metalness: 0.16)
            let corners: [SIMD3<Float>] = [
                SIMD3<Float>(-0.145, 0.002, 0.108),
                SIMD3<Float>(0.145, 0.002, 0.108),
                SIMD3<Float>(0.145, 0.002, -0.108),
                SIMD3<Float>(-0.145, 0.002, -0.108)
            ]
            for index in corners.indices {
                let next = corners[(index + 1) % corners.count]
                let rail = beamNode(start: corners[index], end: next, radius: 0.005, material: cageMaterial)
                rail.name = "airframe.accent.indoorCage"
                root.addChildNode(rail)
            }
        }
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

    /// Tricycle undercarriage: a nose leg and two main legs, each a strut and a
    /// wheel.
    ///
    /// Every airframe in the catalogue was drawn without one, including the ones
    /// that unambiguously have retractable tricycle gear — an MQ-9 parked beside a
    /// runway read as a model resting on its belly in the grass. The physics engine
    /// now gives runway-capable airframes real wheels (`hasWheeledUndercarriage`),
    /// so the picture and the flight model were saying different things.
    ///
    /// `attachY` is where the legs meet the airframe and `strutDrop` how far below
    /// that the axle sits; the wheel hangs another radius below, which is what sets
    /// the aircraft's standing height. The ground clamp is rest-normalized, so
    /// adding this lowers the visible airframe onto its wheels rather than pushing
    /// the whole aircraft up.
    private static func tricycleLandingGearNode(
        noseZ: Float,
        mainZ: Float,
        mainTrack: Float,
        attachY: Float,
        strutDrop: Float,
        wheelRadius: Float,
        strutMaterial: SCNMaterial,
        tyreMaterial: SCNMaterial
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "landingGear"

        func leg(x: Float, z: Float, radius: Float, drop: Float) {
            let strut = beamNode(
                start: SIMD3<Float>(x, attachY, z),
                end: SIMD3<Float>(x, attachY - drop, z),
                radius: max(0.004, radius * 0.32),
                material: strutMaterial
            )
            root.addChildNode(strut)

            // SCNCylinder's axis is Y; a wheel turns about X, so the quarter turn
            // is about Z. Assigned on a plain cylinder node, never on a helper that
            // already carries an orientation of its own.
            let wheel = cylinderNode(radius: radius, height: radius * 0.62, material: tyreMaterial)
            wheel.eulerAngles = SCNVector3(0.0, 0.0, Float.pi / 2.0)
            wheel.position = SCNVector3(x, attachY - drop, z)
            root.addChildNode(wheel)
        }

        // The nose leg carries less weight and is usually the smaller wheel.
        leg(x: 0.0, z: noseZ, radius: wheelRadius * 0.78, drop: strutDrop)
        leg(x: -mainTrack, z: mainZ, radius: wheelRadius, drop: strutDrop)
        leg(x: mainTrack, z: mainZ, radius: wheelRadius, drop: strutDrop)
        return root
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

    /// Capsule spanning `start`...`end`.
    ///
    /// The aiming used to be built from euler angles: yaw/pitch to point the beam,
    /// plus a `Float.pi / 2` roll about Z to stand SCNCapsule's own +Y axis up.
    /// That silently produced a spanwise stick for every direction except ±X,
    /// because SceneKit applies eulerAngles with the **roll last** — so the Z roll
    /// was undoing the aim rather than preceding it. Booms and engine pylons across
    /// the whole catalogue rendered lying across the wing instead of reaching aft,
    /// which is what made tails and nacelles look like detached parts floating
    /// beside the aircraft.
    ///
    /// Aiming the capsule's axis with a single rotation removes the ordering
    /// question entirely.
    private static func beamNode(start: SIMD3<Float>, end: SIMD3<Float>, radius: Float, material: SCNMaterial) -> SCNNode {
        let delta = end - start
        let length = max(radius * 2.0, simd_length(delta))
        let node = SCNNode(geometry: SCNCapsule(capRadius: CGFloat(radius), height: CGFloat(length)))
        node.geometry?.materials = [material]
        node.position = SCNVector3((start.x + end.x) * 0.5, (start.y + end.y) * 0.5, (start.z + end.z) * 0.5)

        let capsuleAxis = SIMD3<Float>(0, 1, 0)
        guard simd_length(delta) > 1e-5 else { return node }
        let target = simd_normalize(delta)
        let alignment = simd_dot(capsuleAxis, target)
        if alignment < -0.9999 {
            // Exactly antiparallel: `simd_quatf(from:to:)` has no defined axis
            // there, so pick one explicitly.
            node.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        } else {
            node.simdOrientation = simd_quatf(from: capsuleAxis, to: target)
        }
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
