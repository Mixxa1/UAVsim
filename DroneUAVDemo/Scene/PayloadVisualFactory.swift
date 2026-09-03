import AppKit
import SceneKit
import simd

enum PayloadVisualFactory {
    static func build(
        configuration: PayloadConfiguration,
        cameraModule: CameraModule? = nil
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "payloadVisualNode"

        let standardPresentation = SCNNode()
        standardPresentation.name = "payloadStandardPresentationNode"
        root.addChildNode(standardPresentation)

        let fpvProxyPresentation = SCNNode()
        fpvProxyPresentation.name = "payloadFPVProxyNode"
        fpvProxyPresentation.isHidden = true
        root.addChildNode(fpvProxyPresentation)

        let sizeScale = payloadSizeScale(for: configuration.payloadMass)
        let shellMaterial = material(
            diffuse: NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.45, alpha: 1.0),
            roughness: 0.68,
            metalness: 0.18
        )
        let accentMaterial = material(
            diffuse: accentColor(for: configuration.visualPreset),
            roughness: 0.62,
            metalness: 0.20
        )
        let darkMaterial = material(
            diffuse: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.145, alpha: 1.0),
            roughness: 0.58,
            metalness: 0.48
        )
        let glassMaterial = material(
            diffuse: NSColor(calibratedRed: 0.018, green: 0.045, blue: 0.058, alpha: 1.0),
            roughness: 0.18,
            metalness: 0.06
        )

        addQuickReleaseMount(
            scale: min(1.22, sizeScale),
            shellMaterial: shellMaterial,
            accentMaterial: accentMaterial,
            darkMaterial: darkMaterial,
            to: standardPresentation
        )

        switch configuration.visualPreset {
        case .cargoBox:
            let box = boxNode(size: SIMD3<Float>(0.12, 0.08, 0.10) * sizeScale, chamfer: 0.012 * sizeScale, material: shellMaterial)
            box.position = SCNVector3(0.0, -0.050 * sizeScale, 0.0)
            standardPresentation.addChildNode(box)

            let lid = boxNode(size: SIMD3<Float>(0.124, 0.014, 0.104) * sizeScale, chamfer: 0.006 * sizeScale, material: darkMaterial)
            lid.position = SCNVector3(0.0, -0.008 * sizeScale, 0.0)
            standardPresentation.addChildNode(lid)

            for z: Float in [-0.031, 0.031] {
                let band = boxNode(size: SIMD3<Float>(0.132, 0.010, 0.014) * sizeScale, chamfer: 0.003 * sizeScale, material: accentMaterial)
                band.position = SCNVector3(0.0, -0.046 * sizeScale, z * sizeScale)
                standardPresentation.addChildNode(band)
            }

            for x: Float in [-0.040, 0.040] {
                let latch = boxNode(size: SIMD3<Float>(0.018, 0.020, 0.008) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                latch.position = SCNVector3(x * sizeScale, -0.026 * sizeScale, 0.052 * sizeScale)
                standardPresentation.addChildNode(latch)
            }

            for x: Float in [-0.056, 0.056] {
                for z: Float in [-0.046, 0.046] {
                    let cornerGuard = boxNode(size: SIMD3<Float>(0.010, 0.066, 0.010) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                    cornerGuard.position = SCNVector3(x * sizeScale, -0.052 * sizeScale, z * sizeScale)
                    standardPresentation.addChildNode(cornerGuard)
                }
            }

            for x: Float in [-0.034, 0.034] {
                let hinge = cylinderNode(radius: 0.004 * sizeScale, height: 0.018 * sizeScale, material: darkMaterial)
                hinge.eulerAngles.z = .pi / 2
                hinge.position = SCNVector3(x * sizeScale, -0.010 * sizeScale, -0.052 * sizeScale)
                standardPresentation.addChildNode(hinge)
            }
        case .cameraGimbal, .thermalCamera:
            let panHousing = cylinderNode(radius: 0.026 * sizeScale, height: 0.018 * sizeScale, material: darkMaterial)
            panHousing.position = SCNVector3(0.0, -0.015 * sizeScale, 0.0)
            standardPresentation.addChildNode(panHousing)

            let yawRing = torusNode(ringRadius: 0.030 * sizeScale, pipeRadius: 0.0045 * sizeScale, material: shellMaterial)
            yawRing.position = SCNVector3(0.0, -0.010 * sizeScale, 0.0)
            standardPresentation.addChildNode(yawRing)

            let forkBridge = boxNode(size: SIMD3<Float>(0.070, 0.010, 0.020) * sizeScale, chamfer: 0.003 * sizeScale, material: darkMaterial)
            forkBridge.position = SCNVector3(0.0, -0.026 * sizeScale, 0.0)
            standardPresentation.addChildNode(forkBridge)

            for side: Float in [-1, 1] {
                let yoke = boxNode(size: SIMD3<Float>(0.008, 0.050, 0.016) * sizeScale, chamfer: 0.003 * sizeScale, material: darkMaterial)
                yoke.position = SCNVector3(side * 0.031 * sizeScale, -0.050 * sizeScale, 0.0)
                standardPresentation.addChildNode(yoke)

                let tiltAxle = cylinderNode(radius: 0.006 * sizeScale, height: 0.012 * sizeScale, material: shellMaterial)
                tiltAxle.eulerAngles.z = .pi / 2
                tiltAxle.position = SCNVector3(side * 0.031 * sizeScale, -0.058 * sizeScale, 0.0)
                standardPresentation.addChildNode(tiltAxle)
            }

            let core = boxNode(size: SIMD3<Float>(0.058, 0.050, 0.052) * sizeScale, chamfer: 0.018 * sizeScale, material: shellMaterial)
            core.position = SCNVector3(0.0, -0.058 * sizeScale, 0.0)
            standardPresentation.addChildNode(core)

            let frontPlate = boxNode(size: SIMD3<Float>(0.052, 0.039, 0.006) * sizeScale, chamfer: 0.004 * sizeScale, material: darkMaterial)
            frontPlate.position = SCNVector3(0.0, -0.058 * sizeScale, 0.028 * sizeScale)
            standardPresentation.addChildNode(frontPlate)

            let lens = cylinderNode(radius: 0.014 * sizeScale, height: 0.012 * sizeScale, material: glassMaterial)
            lens.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            lens.position = SCNVector3(-0.009 * sizeScale, -0.058 * sizeScale, 0.034 * sizeScale)
            standardPresentation.addChildNode(lens)

            let lensBezel = torusNode(ringRadius: 0.014 * sizeScale, pipeRadius: 0.0022 * sizeScale, material: shellMaterial)
            lensBezel.eulerAngles.x = .pi / 2
            lensBezel.position = SCNVector3(-0.009 * sizeScale, -0.058 * sizeScale, 0.041 * sizeScale)
            standardPresentation.addChildNode(lensBezel)

            if let cameraModule, cameraModule.maximumOpticalZoom > 1.5 {
                // Reach costs length: a 34x turret carries a barrel a prime lens simply does not
                // have, so the zoom range is visible on the model rather than only in the readout.
                let reach = Float(min(1.0, log(cameraModule.maximumOpticalZoom) / log(40.0)))
                let barrelLength = (0.010 + 0.052 * reach) * sizeScale
                let barrel = cylinderNode(
                    radius: 0.0125 * sizeScale,
                    height: barrelLength,
                    material: darkMaterial
                )
                barrel.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                barrel.position = SCNVector3(
                    -0.009 * sizeScale,
                    -0.058 * sizeScale,
                    0.034 * sizeScale + barrelLength * 0.5
                )
                standardPresentation.addChildNode(barrel)

                let hood = torusNode(
                    ringRadius: 0.0135 * sizeScale,
                    pipeRadius: 0.0022 * sizeScale,
                    material: shellMaterial
                )
                hood.eulerAngles.x = .pi / 2
                hood.position = SCNVector3(
                    -0.009 * sizeScale,
                    -0.058 * sizeScale,
                    0.034 * sizeScale + barrelLength
                )
                standardPresentation.addChildNode(hood)
            }

            for x: Float in [-0.022, 0.022] {
                for y: Float in [-0.015, 0.015] {
                    let screw = cylinderNode(radius: 0.0018 * sizeScale, height: 0.003 * sizeScale, material: shellMaterial)
                    screw.eulerAngles.x = .pi / 2
                    screw.position = SCNVector3(x * sizeScale, (-0.058 + y) * sizeScale, 0.032 * sizeScale)
                    standardPresentation.addChildNode(screw)
                }
            }

            if configuration.visualPreset == .thermalCamera {
                let thermalGlass = material(
                    diffuse: NSColor(calibratedRed: 0.34, green: 0.08, blue: 0.035, alpha: 1.0),
                    roughness: 0.18,
                    metalness: 0.06
                )
                let thermalLens = cylinderNode(radius: 0.009 * sizeScale, height: 0.013 * sizeScale, material: thermalGlass)
                thermalLens.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                thermalLens.position = SCNVector3(0.017 * sizeScale, -0.058 * sizeScale, 0.034 * sizeScale)
                standardPresentation.addChildNode(thermalLens)

                let thermalBezel = torusNode(ringRadius: 0.009 * sizeScale, pipeRadius: 0.0018 * sizeScale, material: shellMaterial)
                thermalBezel.eulerAngles.x = .pi / 2
                thermalBezel.position = SCNVector3(0.017 * sizeScale, -0.058 * sizeScale, 0.041 * sizeScale)
                standardPresentation.addChildNode(thermalBezel)
            }
        case .lidarModule:
            let pod = cylinderNode(radius: 0.036 * sizeScale, height: 0.038 * sizeScale, material: shellMaterial)
            pod.position = SCNVector3(0.0, -0.032 * sizeScale, 0.0)
            standardPresentation.addChildNode(pod)

            let scanBand = cylinderNode(radius: 0.038 * sizeScale, height: 0.013 * sizeScale, material: glassMaterial)
            scanBand.position = SCNVector3(0.0, -0.030 * sizeScale, 0.0)
            standardPresentation.addChildNode(scanBand)

            let cap = cylinderNode(radius: 0.040 * sizeScale, height: 0.009 * sizeScale, material: accentMaterial)
            cap.position = SCNVector3(0.0, -0.008 * sizeScale, 0.0)
            standardPresentation.addChildNode(cap)

            let lowerBearing = cylinderNode(radius: 0.038 * sizeScale, height: 0.014 * sizeScale, material: darkMaterial)
            lowerBearing.position = SCNVector3(0.0, -0.067 * sizeScale, 0.0)
            standardPresentation.addChildNode(lowerBearing)

            for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi / 3) {
                let post = cylinderNode(radius: 0.0025 * sizeScale, height: 0.028 * sizeScale, material: darkMaterial)
                post.position = SCNVector3(cos(angle) * 0.031 * sizeScale, -0.055 * sizeScale, sin(angle) * 0.031 * sizeScale)
                standardPresentation.addChildNode(post)
            }

            for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi / 2) {
                let fastener = cylinderNode(radius: 0.0022 * sizeScale, height: 0.004 * sizeScale, material: shellMaterial)
                fastener.position = SCNVector3(cos(angle) * 0.030 * sizeScale, -0.003 * sizeScale, sin(angle) * 0.030 * sizeScale)
                standardPresentation.addChildNode(fastener)
            }
        case .laserRangefinder:
            let laserAccentMaterial = material(
                diffuse: NSColor(calibratedRed: 0.62, green: 0.10, blue: 0.08, alpha: 1.0),
                roughness: 0.36,
                metalness: 0.30
            )

            let body = boxNode(size: SIMD3<Float>(0.072, 0.044, 0.058) * sizeScale, chamfer: 0.008 * sizeScale, material: shellMaterial)
            body.position = SCNVector3(0.0, -0.034 * sizeScale, 0.0)
            standardPresentation.addChildNode(body)

            let aperture = cylinderNode(radius: 0.012 * sizeScale, height: 0.018 * sizeScale, material: darkMaterial)
            aperture.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            aperture.position = SCNVector3(-0.014 * sizeScale, -0.034 * sizeScale, 0.034 * sizeScale)
            standardPresentation.addChildNode(aperture)

            let apertureRing = cylinderNode(radius: 0.014 * sizeScale, height: 0.004 * sizeScale, material: laserAccentMaterial)
            apertureRing.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            apertureRing.position = SCNVector3(-0.014 * sizeScale, -0.034 * sizeScale, 0.027 * sizeScale)
            standardPresentation.addChildNode(apertureRing)

            let receiver = cylinderNode(radius: 0.008 * sizeScale, height: 0.018 * sizeScale, material: glassMaterial)
            receiver.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            receiver.position = SCNVector3(0.019 * sizeScale, -0.034 * sizeScale, 0.033 * sizeScale)
            standardPresentation.addChildNode(receiver)

            let sightRail = boxNode(size: SIMD3<Float>(0.050, 0.006, 0.018) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
            sightRail.position = SCNVector3(0.0, -0.009 * sizeScale, -0.003 * sizeScale)
            standardPresentation.addChildNode(sightRail)

            for side: Float in [-1, 1] {
                let rib = boxNode(size: SIMD3<Float>(0.006, 0.036, 0.050) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                rib.position = SCNVector3(side * 0.038 * sizeScale, -0.034 * sizeScale, 0.0)
                standardPresentation.addChildNode(rib)
            }

            let rearConnector = cylinderNode(radius: 0.007 * sizeScale, height: 0.010 * sizeScale, material: accentMaterial)
            rearConnector.eulerAngles.x = .pi / 2
            rearConnector.position = SCNVector3(0.022 * sizeScale, -0.037 * sizeScale, -0.033 * sizeScale)
            standardPresentation.addChildNode(rearConnector)
        case .fireHose:
            let hoseMaterial = material(
                diffuse: NSColor(calibratedRed: 0.46, green: 0.11, blue: 0.065, alpha: 1.0),
                roughness: 0.82,
                metalness: 0.02
            )
            let couplingMaterial = material(
                diffuse: NSColor(calibratedWhite: 0.52, alpha: 1.0),
                roughness: 0.42,
                metalness: 0.62
            )

            // The aircraft does not carry a reel. It carries the working end of a charged hose:
            // a load-bearing cradle, swivel coupling, two-axis monitor and strain-relieved hose
            // tail. The rest of the line continues out of the preview toward the truck.
            let cradle = boxNode(size: SIMD3<Float>(0.116, 0.014, 0.078) * sizeScale, chamfer: 0.004 * sizeScale, material: darkMaterial)
            cradle.position = SCNVector3(0.0, -0.015 * sizeScale, 0.0)
            standardPresentation.addChildNode(cradle)

            for z: Float in [-0.034, 0.034] {
                standardPresentation.addChildNode(tubeNode(
                    from: SIMD3<Float>(-0.047, -0.020, z) * sizeScale,
                    to: SIMD3<Float>(-0.020, -0.058, z) * sizeScale,
                    radius: 0.004 * sizeScale,
                    material: darkMaterial
                ))
                standardPresentation.addChildNode(tubeNode(
                    from: SIMD3<Float>(0.047, -0.020, z) * sizeScale,
                    to: SIMD3<Float>(0.020, -0.058, z) * sizeScale,
                    radius: 0.004 * sizeScale,
                    material: darkMaterial
                ))
            }

            let swivelHousing = cylinderNode(radius: 0.021 * sizeScale, height: 0.038 * sizeScale, material: shellMaterial)
            swivelHousing.position = SCNVector3(-0.018 * sizeScale, -0.047 * sizeScale, 0.0)
            standardPresentation.addChildNode(swivelHousing)

            let swivelCollar = torusNode(ringRadius: 0.021 * sizeScale, pipeRadius: 0.0035 * sizeScale, material: couplingMaterial)
            swivelCollar.position = SCNVector3(-0.018 * sizeScale, -0.061 * sizeScale, 0.0)
            standardPresentation.addChildNode(swivelCollar)

            let valveBlock = boxNode(size: SIMD3<Float>(0.043, 0.029, 0.052) * sizeScale, chamfer: 0.006 * sizeScale, material: shellMaterial)
            valveBlock.position = SCNVector3(0.020 * sizeScale, -0.059 * sizeScale, 0.0)
            standardPresentation.addChildNode(valveBlock)

            let pivotAxle = cylinderNode(radius: 0.007 * sizeScale, height: 0.080 * sizeScale, material: couplingMaterial)
            pivotAxle.eulerAngles.x = .pi / 2
            pivotAxle.position = SCNVector3(0.042 * sizeScale, -0.061 * sizeScale, 0.0)
            standardPresentation.addChildNode(pivotAxle)

            for z: Float in [-0.034, 0.034] {
                standardPresentation.addChildNode(tubeNode(
                    from: SIMD3<Float>(0.020, -0.058, z) * sizeScale,
                    to: SIMD3<Float>(0.042, -0.061, z) * sizeScale,
                    radius: 0.0045 * sizeScale,
                    material: darkMaterial
                ))
            }

            let nozzleBarrel = cylinderNode(radius: 0.013 * sizeScale, height: 0.055 * sizeScale, material: darkMaterial)
            nozzleBarrel.name = "payloadFireHoseStaticBarrelNode"
            nozzleBarrel.eulerAngles.z = -.pi / 2
            nozzleBarrel.position = SCNVector3(0.068 * sizeScale, -0.061 * sizeScale, 0.0)
            standardPresentation.addChildNode(nozzleBarrel)

            let nozzle = coneNode(topRadius: 0.007 * sizeScale, bottomRadius: 0.013 * sizeScale, height: 0.040 * sizeScale, material: couplingMaterial)
            nozzle.name = "payloadFireHoseStaticTipNode"
            nozzle.eulerAngles.z = -.pi / 2
            nozzle.position = SCNVector3(0.112 * sizeScale, -0.061 * sizeScale, 0.0)
            standardPresentation.addChildNode(nozzle)

            let actuator = boxNode(size: SIMD3<Float>(0.024, 0.014, 0.022) * sizeScale, chamfer: 0.003 * sizeScale, material: accentMaterial)
            actuator.position = SCNVector3(0.037 * sizeScale, -0.037 * sizeScale, 0.0)
            standardPresentation.addChildNode(actuator)

            // Flexible inlet: every segment meets the next and the first is clamped into the
            // swivel. The last segment deliberately exits the assembly downward/rearward — it is
            // the visible continuation toward the ground vehicle, not a loose floating part.
            let hosePath: [SIMD3<Float>] = [
                SIMD3<Float>(-0.018, -0.066, 0.0),
                SIMD3<Float>(-0.029, -0.085, -0.006),
                SIMD3<Float>(-0.047, -0.105, -0.015),
                SIMD3<Float>(-0.066, -0.126, -0.025),
                SIMD3<Float>(-0.082, -0.153, -0.034)
            ].map { $0 * sizeScale }
            for index in 0..<(hosePath.count - 1) {
                standardPresentation.addChildNode(tubeNode(
                    from: hosePath[index],
                    to: hosePath[index + 1],
                    radius: 0.0065 * sizeScale,
                    material: hoseMaterial
                ))
            }

            let inletCoupling = cylinderNode(radius: 0.012 * sizeScale, height: 0.018 * sizeScale, material: couplingMaterial)
            inletCoupling.position = SCNVector3(-0.018 * sizeScale, -0.071 * sizeScale, 0.0)
            standardPresentation.addChildNode(inletCoupling)

            let strainRelief = boxNode(size: SIMD3<Float>(0.030, 0.009, 0.030) * sizeScale, chamfer: 0.003 * sizeScale, material: darkMaterial)
            strainRelief.position = SCNVector3(-0.040 * sizeScale, -0.098 * sizeScale, -0.011 * sizeScale)
            strainRelief.eulerAngles.z = -.pi / 4
            standardPresentation.addChildNode(strainRelief)
        case .fireCapsuleLauncher:
            let capsuleAccentMaterial = material(
                diffuse: NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.12, alpha: 1.0),
                roughness: 0.66,
                metalness: 0.12
            )
            let capsuleMaterial = material(
                diffuse: NSColor(calibratedWhite: 0.58, alpha: 1.0),
                roughness: 0.54,
                metalness: 0.16
            )

            let rack = boxNode(size: SIMD3<Float>(0.112, 0.026, 0.060) * sizeScale, chamfer: 0.006 * sizeScale, material: darkMaterial)
            rack.position = SCNVector3(0.0, -0.026 * sizeScale, 0.0)
            standardPresentation.addChildNode(rack)

            let rackBand = boxNode(size: SIMD3<Float>(0.116, 0.008, 0.064) * sizeScale, chamfer: 0.004 * sizeScale, material: capsuleAccentMaterial)
            rackBand.position = SCNVector3(0.0, -0.013 * sizeScale, 0.0)
            standardPresentation.addChildNode(rackBand)

            for z: Float in [-0.031, 0.031] {
                let retentionPlate = boxNode(size: SIMD3<Float>(0.116, 0.042, 0.008) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                retentionPlate.position = SCNVector3(0.0, -0.038 * sizeScale, z * sizeScale)
                standardPresentation.addChildNode(retentionPlate)
            }

            // Visible capsule count reflects the rigged count so the player can see remaining
            // ammo at a glance without a HUD element — same "show, don't tell" idea as the fire
            // hose's suppression foam.
            let capsuleCount = max(1, min(4, configuration.fireCapsuleCount))
            let spacing: Float = 0.026 * sizeScale
            let startX = -spacing * Float(capsuleCount - 1) / 2.0
            for index in 0..<capsuleCount {
                let launchTube = cylinderNode(radius: 0.0125 * sizeScale, height: 0.056 * sizeScale, material: shellMaterial)
                launchTube.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                launchTube.position = SCNVector3(startX + spacing * Float(index), -0.036 * sizeScale, 0.0)
                standardPresentation.addChildNode(launchTube)

                let capsule = capsuleNode(capRadius: 0.0095 * sizeScale, height: 0.040 * sizeScale, material: capsuleMaterial)
                capsule.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                capsule.position = SCNVector3(startX + spacing * Float(index), -0.036 * sizeScale, 0.010 * sizeScale)
                standardPresentation.addChildNode(capsule)
            }

            for side: Float in [-1, 1] {
                let leg = boxNode(size: SIMD3<Float>(0.008, 0.036, 0.052) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                leg.position = SCNVector3(side * 0.053 * sizeScale, -0.037 * sizeScale, 0.0)
                standardPresentation.addChildNode(leg)
            }
        case .agriculturalSprayer:
            let tankMaterial = material(
                diffuse: NSColor(calibratedRed: 0.22, green: 0.34, blue: 0.23, alpha: 1.0),
                roughness: 0.72,
                metalness: 0.08
            )
            let boomMaterial = material(
                diffuse: NSColor(calibratedWhite: 0.46, alpha: 1.0),
                roughness: 0.58,
                metalness: 0.42
            )

            let tank = capsuleNode(capRadius: 0.040 * sizeScale, height: 0.092 * sizeScale, material: tankMaterial)
            tank.position = SCNVector3(0.0, -0.050 * sizeScale, 0.0)
            standardPresentation.addChildNode(tank)

            let fillCap = cylinderNode(radius: 0.010 * sizeScale, height: 0.010 * sizeScale, material: accentMaterial)
            fillCap.position = SCNVector3(0.026 * sizeScale, -0.007 * sizeScale, 0.0)
            standardPresentation.addChildNode(fillCap)

            for y: Float in [-0.027, -0.072] {
                let tankBand = torusNode(ringRadius: 0.039 * sizeScale, pipeRadius: 0.003 * sizeScale, material: darkMaterial)
                tankBand.position = SCNVector3(0.0, y * sizeScale, 0.0)
                standardPresentation.addChildNode(tankBand)
            }

            let boom = boxNode(size: SIMD3<Float>(0.24, 0.009, 0.014) * sizeScale, chamfer: 0.003 * sizeScale, material: boomMaterial)
            boom.position = SCNVector3(0.0, -0.108 * sizeScale, 0.0)
            standardPresentation.addChildNode(boom)

            for side: Float in [-1, 1] {
                standardPresentation.addChildNode(tubeNode(
                    from: SIMD3<Float>(side * 0.028, -0.078, 0.0) * sizeScale,
                    to: SIMD3<Float>(side * 0.045, -0.108, 0.0) * sizeScale,
                    radius: 0.0035 * sizeScale,
                    material: darkMaterial
                ))
            }

            let manifold = cylinderNode(radius: 0.009 * sizeScale, height: 0.020 * sizeScale, material: darkMaterial)
            manifold.position = SCNVector3(0.0, -0.100 * sizeScale, 0.0)
            standardPresentation.addChildNode(manifold)

            let nozzleCount = 4
            let spacing: Float = 0.052 * sizeScale
            let startX = -spacing * Float(nozzleCount - 1) / 2.0
            for index in 0..<nozzleCount {
                let nozzle = cylinderNode(radius: 0.006 * sizeScale, height: 0.014 * sizeScale, material: darkMaterial)
                nozzle.position = SCNVector3(startX + spacing * Float(index), -0.118 * sizeScale, 0.0)
                standardPresentation.addChildNode(nozzle)

                let nozzleTip = coneNode(topRadius: 0.0015 * sizeScale, bottomRadius: 0.004 * sizeScale, height: 0.010 * sizeScale, material: accentMaterial)
                nozzleTip.position = SCNVector3(startX + spacing * Float(index), -0.128 * sizeScale, 0.0)
                standardPresentation.addChildNode(nozzleTip)
            }
        case .rescuePack:
            let rescueMaterial = material(
                diffuse: NSColor(calibratedRed: 0.55, green: 0.18, blue: 0.14, alpha: 1.0),
                roughness: 0.70,
                metalness: 0.08
            )
            let pack = boxNode(size: SIMD3<Float>(0.112, 0.072, 0.092) * sizeScale, chamfer: 0.012 * sizeScale, material: rescueMaterial)
            pack.position = SCNVector3(0.0, -0.046 * sizeScale, 0.0)
            standardPresentation.addChildNode(pack)

            let lid = boxNode(size: SIMD3<Float>(0.108, 0.012, 0.088) * sizeScale, chamfer: 0.005 * sizeScale, material: darkMaterial)
            lid.position = SCNVector3(0.0, -0.009 * sizeScale, 0.0)
            standardPresentation.addChildNode(lid)

            for x: Float in [-0.050, 0.050] {
                for z: Float in [-0.040, 0.040] {
                    let bumper = boxNode(size: SIMD3<Float>(0.010, 0.060, 0.010) * sizeScale, chamfer: 0.002 * sizeScale, material: darkMaterial)
                    bumper.position = SCNVector3(x * sizeScale, -0.050 * sizeScale, z * sizeScale)
                    standardPresentation.addChildNode(bumper)
                }
            }

            for x: Float in [-0.035, 0.035] {
                let latch = boxNode(size: SIMD3<Float>(0.014, 0.022, 0.006) * sizeScale, chamfer: 0.002 * sizeScale, material: shellMaterial)
                latch.position = SCNVector3(x * sizeScale, -0.024 * sizeScale, 0.048 * sizeScale)
                standardPresentation.addChildNode(latch)
            }

            let crossVertical = boxNode(size: SIMD3<Float>(0.018, 0.043, 0.006) * sizeScale, chamfer: 0.003 * sizeScale, material: shellMaterial)
            crossVertical.position = SCNVector3(0.0, -0.048 * sizeScale, 0.048 * sizeScale)
            standardPresentation.addChildNode(crossVertical)
            let crossHorizontal = boxNode(size: SIMD3<Float>(0.043, 0.018, 0.006) * sizeScale, chamfer: 0.003 * sizeScale, material: shellMaterial)
            crossHorizontal.position = crossVertical.position
            standardPresentation.addChildNode(crossHorizontal)
        case .sensorModule:
            let module = boxNode(size: SIMD3<Float>(0.090, 0.050, 0.070) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            module.position = SCNVector3(0.0, -0.032 * sizeScale, 0.0)
            standardPresentation.addChildNode(module)

            let sensorPlate = boxNode(size: SIMD3<Float>(0.076, 0.034, 0.006) * sizeScale, chamfer: 0.003 * sizeScale, material: darkMaterial)
            sensorPlate.position = SCNVector3(0.0, -0.032 * sizeScale, 0.037 * sizeScale)
            standardPresentation.addChildNode(sensorPlate)

            for x: Float in [-0.024, 0.0, 0.024] {
                let sensor = cylinderNode(radius: 0.008 * sizeScale, height: 0.008 * sizeScale, material: glassMaterial)
                sensor.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                sensor.position = SCNVector3(x * sizeScale, -0.032 * sizeScale, 0.038 * sizeScale)
                standardPresentation.addChildNode(sensor)
            }

            for x: Float in [-0.024, -0.012, 0.0, 0.012, 0.024] {
                let vent = boxNode(size: SIMD3<Float>(0.006, 0.003, 0.028) * sizeScale, chamfer: 0.001 * sizeScale, material: darkMaterial)
                vent.position = SCNVector3(x * sizeScale, -0.007 * sizeScale, 0.0)
                standardPresentation.addChildNode(vent)
            }

            let cableGland = cylinderNode(radius: 0.007 * sizeScale, height: 0.010 * sizeScale, material: darkMaterial)
            cableGland.eulerAngles.z = .pi / 2
            cableGland.position = SCNVector3(0.048 * sizeScale, -0.030 * sizeScale, -0.012 * sizeScale)
            standardPresentation.addChildNode(cableGland)
        case .radioRelay:
            let relay = boxNode(size: SIMD3<Float>(0.090, 0.058, 0.066) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            relay.position = SCNVector3(0.0, -0.034 * sizeScale, 0.0)
            standardPresentation.addChildNode(relay)

            for side: Float in [-1.0, 1.0] {
                let base = cylinderNode(radius: 0.007 * sizeScale, height: 0.010 * sizeScale, material: darkMaterial)
                base.eulerAngles.z = .pi / 2
                base.position = SCNVector3(side * 0.046 * sizeScale, -0.018 * sizeScale, -0.012 * sizeScale)
                standardPresentation.addChildNode(base)

                let start = SIMD3<Float>(side * 0.050, -0.016, -0.012) * sizeScale
                let end = SIMD3<Float>(side * 0.070, 0.042, -0.012) * sizeScale
                standardPresentation.addChildNode(tubeNode(from: start, to: end, radius: 0.0032 * sizeScale, material: darkMaterial))

                let tip = sphereNode(radius: 0.005 * sizeScale, material: accentMaterial)
                tip.simdPosition = end
                standardPresentation.addChildNode(tip)
            }

            let statusBand = boxNode(size: SIMD3<Float>(0.074, 0.010, 0.006) * sizeScale, chamfer: 0.002 * sizeScale, material: accentMaterial)
            statusBand.position = SCNVector3(0.0, -0.032 * sizeScale, 0.035 * sizeScale)
            standardPresentation.addChildNode(statusBand)
        case .customModule:
            let module = boxNode(size: SIMD3<Float>(0.10, 0.060, 0.082) * sizeScale, chamfer: 0.010 * sizeScale, material: darkMaterial)
            module.position = SCNVector3(0.0, -0.038 * sizeScale, 0.0)
            standardPresentation.addChildNode(module)

            for side: Float in [-1, 1] {
                let rail = boxNode(size: SIMD3<Float>(0.010, 0.066, 0.088) * sizeScale, chamfer: 0.003 * sizeScale, material: shellMaterial)
                rail.position = SCNVector3(side * 0.046 * sizeScale, -0.038 * sizeScale, 0.0)
                standardPresentation.addChildNode(rail)
            }

            for y: Float in [-0.010, -0.068] {
                let crossRail = boxNode(size: SIMD3<Float>(0.102, 0.008, 0.088) * sizeScale, chamfer: 0.003 * sizeScale, material: shellMaterial)
                crossRail.position = SCNVector3(0.0, y * sizeScale, 0.0)
                standardPresentation.addChildNode(crossRail)
            }

            let core = boxNode(size: SIMD3<Float>(0.048, 0.030, 0.006) * sizeScale, chamfer: 0.004 * sizeScale, material: accentMaterial)
            core.position = SCNVector3(0.0, -0.038 * sizeScale, 0.043 * sizeScale)
            standardPresentation.addChildNode(core)
        }

        let fpvProxyBody = boxNode(
            size: SIMD3<Float>(0.060, 0.022, 0.040) * min(1.15, sizeScale),
            chamfer: 0.006 * min(1.15, sizeScale),
            material: darkMaterial
        )
        fpvProxyBody.position = SCNVector3(0.0, -0.072 * sizeScale, -0.012 * sizeScale)
        fpvProxyPresentation.addChildNode(fpvProxyBody)

        let fpvProxyMount = boxNode(
            size: SIMD3<Float>(0.018, 0.028, 0.016) * min(1.10, sizeScale),
            chamfer: 0.003 * min(1.10, sizeScale),
            material: accentMaterial
        )
        fpvProxyMount.position = SCNVector3(0.0, -0.046 * sizeScale, -0.006 * sizeScale)
        fpvProxyPresentation.addChildNode(fpvProxyMount)

        return root
    }

    private static func addQuickReleaseMount(
        scale: Float,
        shellMaterial: SCNMaterial,
        accentMaterial: SCNMaterial,
        darkMaterial: SCNMaterial,
        to root: SCNNode
    ) {
        let plate = boxNode(
            size: SIMD3<Float>(0.074, 0.009, 0.058) * scale,
            chamfer: 0.003 * scale,
            material: darkMaterial
        )
        plate.position = SCNVector3(0.0, 0.018 * scale, 0.0)
        root.addChildNode(plate)

        let collar = cylinderNode(radius: 0.016 * scale, height: 0.028 * scale, material: shellMaterial)
        collar.position = SCNVector3(0.0, 0.036 * scale, 0.0)
        root.addChildNode(collar)

        let lowerAdapter = cylinderNode(radius: 0.014 * scale, height: 0.026 * scale, material: shellMaterial)
        lowerAdapter.position = SCNVector3(0.0, 0.0, 0.0)
        root.addChildNode(lowerAdapter)

        let retainingWasher = cylinderNode(radius: 0.021 * scale, height: 0.004 * scale, material: accentMaterial)
        retainingWasher.position = SCNVector3(0.0, 0.012 * scale, 0.0)
        root.addChildNode(retainingWasher)

        for x: Float in [-0.026, 0.026] {
            let guide = boxNode(
                size: SIMD3<Float>(0.010, 0.006, 0.042) * scale,
                chamfer: 0.0015 * scale,
                material: shellMaterial
            )
            guide.position = SCNVector3(x * scale, 0.025 * scale, 0.0)
            root.addChildNode(guide)
        }

        for x: Float in [-0.029, 0.029] {
            for z: Float in [-0.020, 0.020] {
                let bolt = cylinderNode(radius: 0.0025 * scale, height: 0.006 * scale, material: shellMaterial)
                bolt.position = SCNVector3(x * scale, 0.024 * scale, z * scale)
                root.addChildNode(bolt)
            }
        }
    }

    private static func accentColor(for preset: PayloadVisualPreset) -> NSColor {
        switch preset {
        case .cargoBox, .rescuePack:
            return NSColor(calibratedRed: 0.68, green: 0.48, blue: 0.20, alpha: 1.0)
        case .cameraGimbal, .lidarModule, .sensorModule, .radioRelay, .customModule:
            return NSColor(calibratedRed: 0.22, green: 0.37, blue: 0.47, alpha: 1.0)
        case .thermalCamera:
            return NSColor(calibratedRed: 0.66, green: 0.30, blue: 0.12, alpha: 1.0)
        case .laserRangefinder:
            return NSColor(calibratedRed: 0.60, green: 0.16, blue: 0.12, alpha: 1.0)
        case .fireHose, .fireCapsuleLauncher:
            return NSColor(calibratedRed: 0.64, green: 0.20, blue: 0.12, alpha: 1.0)
        case .agriculturalSprayer:
            return NSColor(calibratedRed: 0.24, green: 0.45, blue: 0.25, alpha: 1.0)
        }
    }

    private static func payloadSizeScale(for payloadMass: Float) -> Float {
        let mass = max(0.15, payloadMass)
        return min(1.60, max(0.82, sqrt(mass) * 0.46))
    }

    private static func material(diffuse: NSColor, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        material.lightingModel = .physicallyBased
        return material
    }

    private static func boxNode(size: SIMD3<Float>, chamfer: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNBox(
            width: CGFloat(size.x),
            height: CGFloat(size.y),
            length: CGFloat(size.z),
            chamferRadius: CGFloat(chamfer)
        )
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func sphereNode(radius: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNSphere(radius: CGFloat(radius))
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func cylinderNode(radius: Float, height: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
        geometry.radialSegmentCount = 32
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func capsuleNode(capRadius: Float, height: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNCapsule(capRadius: CGFloat(capRadius), height: CGFloat(height))
        geometry.radialSegmentCount = 32
        geometry.capSegmentCount = 12
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func coneNode(
        topRadius: Float,
        bottomRadius: Float,
        height: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let geometry = SCNCone(
            topRadius: CGFloat(topRadius),
            bottomRadius: CGFloat(bottomRadius),
            height: CGFloat(height)
        )
        geometry.radialSegmentCount = 32
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func torusNode(ringRadius: Float, pipeRadius: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNTorus(ringRadius: CGFloat(ringRadius), pipeRadius: CGFloat(pipeRadius))
        geometry.ringSegmentCount = 48
        geometry.pipeSegmentCount = 12
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    /// Creates a structural rod or hose between two exact attachment points. Using endpoints
    /// instead of hand-tuned rotations keeps braces, cables, and pipes visibly connected.
    private static func tubeNode(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        material: SCNMaterial
    ) -> SCNNode {
        let delta = end - start
        let length = simd_length(delta)
        let node = cylinderNode(radius: radius, height: max(length, 0.001), material: material)
        node.simdPosition = (start + end) * 0.5
        if length > 0.0001 {
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
        }
        return node
    }
}

enum CADPayloadVisualFactory {
    static func build(payload: MountedCADPayload) -> SCNNode {
        let root = SCNNode()
        root.name = "CADPayloadNode"
        root.simdPosition = payload.localPositionOnUAV.simdFloat
        root.simdOrientation = payload.localRotationOnUAV.quaternion

        let material = material(previewColor: payload.materialPreviewColor)
        if let mesh = payload.visualMesh, mesh.isRenderable, let geometry = geometry(from: mesh, material: material) {
            root.addChildNode(SCNNode(geometry: geometry))
        } else {
            let bounds = SCNBox(
                width: CGFloat(max(payload.boundingWidth, 0.001)),
                height: CGFloat(max(payload.boundingHeight, 0.001)),
                length: CGFloat(max(payload.boundingDepth, 0.001)),
                chamferRadius: CGFloat(max(0.001, min(payload.boundingWidth, payload.boundingHeight, payload.boundingDepth) * 0.015))
            )
            bounds.firstMaterial = material
            let boundsNode = SCNNode(geometry: bounds)
            let center = (payload.boundingBoxMin.simdFloat + payload.boundingBoxMax.simdFloat) * 0.5
            boundsNode.simdPosition = center
            root.addChildNode(boundsNode)
        }

        return root
    }

    private static func geometry(from mesh: MountedCADPayload.VisualMesh, material: SCNMaterial) -> SCNGeometry? {
        let vertexCount = mesh.vertices.count / 3
        guard vertexCount > 0 else {
            return nil
        }

        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(vertexCount)
        for index in 0..<vertexCount {
            vertices.append(
                SCNVector3(
                    Float(mesh.vertices[index * 3 + 0]),
                    Float(mesh.vertices[index * 3 + 1]),
                    Float(mesh.vertices[index * 3 + 2])
                )
            )
        }

        let indices = mesh.indices
        let source = SCNGeometrySource(vertices: vertices)
        let indexData = indices.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.stride
        )
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.materials = [material]
        return geometry
    }

    private static func material(previewColor: String) -> SCNMaterial {
        let color = nsColor(from: previewColor) ?? NSColor(calibratedRed: 0.56, green: 0.64, blue: 0.72, alpha: 1.0)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.specular.contents = NSColor(calibratedWhite: 0.82, alpha: 1.0)
        material.roughness.contents = 0.48
        material.metalness.contents = 0.16
        material.lightingModel = .physicallyBased
        return material
    }

    private static func nsColor(from hex: String) -> NSColor? {
        guard hex.count == 7, hex.first == "#" else {
            return nil
        }
        let scanner = Scanner(string: String(hex.dropFirst()))
        var value: UInt64 = 0
        guard scanner.scanHexInt64(&value) else {
            return nil
        }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1.0
        )
    }
}
