import AppKit
import SceneKit
import simd

enum PayloadVisualFactory {
    static func build(configuration: PayloadConfiguration) -> SCNNode {
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
            diffuse: NSColor(calibratedWhite: 0.74, alpha: 1.0),
            roughness: 0.56,
            metalness: 0.18
        )
        let accentMaterial = material(
            diffuse: NSColor(calibratedRed: 0.28, green: 0.31, blue: 0.35, alpha: 1.0),
            roughness: 0.42,
            metalness: 0.36
        )
        let darkMaterial = material(
            diffuse: NSColor(calibratedWhite: 0.18, alpha: 1.0),
            roughness: 0.44,
            metalness: 0.30
        )

        let hanger = cylinderNode(radius: 0.012, height: 0.035, material: accentMaterial)
        hanger.position = SCNVector3(0.0, 0.017, 0.0)
        standardPresentation.addChildNode(hanger)

        switch configuration.visualPreset {
        case .cargoBox:
            let box = boxNode(size: SIMD3<Float>(0.12, 0.08, 0.10) * sizeScale, chamfer: 0.012 * sizeScale, material: shellMaterial)
            box.position = SCNVector3(0.0, -0.042 * sizeScale, 0.0)
            standardPresentation.addChildNode(box)

            let band = boxNode(size: SIMD3<Float>(0.13, 0.012, 0.024) * sizeScale, chamfer: 0.004 * sizeScale, material: accentMaterial)
            band.position = SCNVector3(0.0, -0.028 * sizeScale, 0.0)
            standardPresentation.addChildNode(band)
        case .cameraGimbal, .thermalCamera:
            let core = boxNode(size: SIMD3<Float>(0.072, 0.046, 0.060) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            core.position = SCNVector3(0.0, -0.030 * sizeScale, 0.0)
            standardPresentation.addChildNode(core)

            let lens = sphereNode(radius: 0.018 * sizeScale, material: darkMaterial)
            lens.position = SCNVector3(0.0, -0.042 * sizeScale, 0.030 * sizeScale)
            standardPresentation.addChildNode(lens)

            if configuration.visualPreset == .thermalCamera {
                let shroud = cylinderNode(radius: 0.014 * sizeScale, height: 0.026 * sizeScale, material: accentMaterial)
                shroud.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
                shroud.position = SCNVector3(0.0, -0.040 * sizeScale, 0.046 * sizeScale)
                standardPresentation.addChildNode(shroud)
            }
        case .lidarModule:
            let pod = cylinderNode(radius: 0.032 * sizeScale, height: 0.040 * sizeScale, material: shellMaterial)
            pod.position = SCNVector3(0.0, -0.032 * sizeScale, 0.0)
            standardPresentation.addChildNode(pod)

            let cap = cylinderNode(radius: 0.036 * sizeScale, height: 0.010 * sizeScale, material: accentMaterial)
            cap.position = SCNVector3(0.0, -0.010 * sizeScale, 0.0)
            standardPresentation.addChildNode(cap)
        case .laserRangefinder:
            let laserAccentMaterial = material(
                diffuse: NSColor(calibratedRed: 0.62, green: 0.10, blue: 0.08, alpha: 1.0),
                roughness: 0.36,
                metalness: 0.30
            )

            let body = boxNode(size: SIMD3<Float>(0.064, 0.040, 0.052) * sizeScale, chamfer: 0.008 * sizeScale, material: shellMaterial)
            body.position = SCNVector3(0.0, -0.028 * sizeScale, 0.0)
            standardPresentation.addChildNode(body)

            let aperture = cylinderNode(radius: 0.012 * sizeScale, height: 0.018 * sizeScale, material: darkMaterial)
            aperture.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            aperture.position = SCNVector3(0.0, -0.034 * sizeScale, 0.034 * sizeScale)
            standardPresentation.addChildNode(aperture)

            let apertureRing = cylinderNode(radius: 0.014 * sizeScale, height: 0.004 * sizeScale, material: laserAccentMaterial)
            apertureRing.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            apertureRing.position = SCNVector3(0.0, -0.034 * sizeScale, 0.027 * sizeScale)
            standardPresentation.addChildNode(apertureRing)
        case .fireHose:
            let hoseAccentMaterial = material(
                diffuse: NSColor(calibratedRed: 0.62, green: 0.14, blue: 0.06, alpha: 1.0),
                roughness: 0.5,
                metalness: 0.24
            )

            let reel = cylinderNode(radius: 0.034 * sizeScale, height: 0.046 * sizeScale, material: shellMaterial)
            reel.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            reel.position = SCNVector3(0.0, -0.030 * sizeScale, 0.0)
            standardPresentation.addChildNode(reel)

            let reelBand = cylinderNode(radius: 0.036 * sizeScale, height: 0.008 * sizeScale, material: hoseAccentMaterial)
            reelBand.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            reelBand.position = SCNVector3(0.0, -0.030 * sizeScale, 0.0)
            standardPresentation.addChildNode(reelBand)

            let nozzle = cylinderNode(radius: 0.010 * sizeScale, height: 0.030 * sizeScale, material: darkMaterial)
            nozzle.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            nozzle.position = SCNVector3(0.0, -0.036 * sizeScale, 0.038 * sizeScale)
            standardPresentation.addChildNode(nozzle)
        case .fireCapsuleLauncher:
            let capsuleAccentMaterial = material(
                diffuse: NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.10, alpha: 1.0),
                roughness: 0.40,
                metalness: 0.20
            )
            let capsuleMaterial = material(
                diffuse: NSColor(calibratedWhite: 0.92, alpha: 1.0),
                roughness: 0.30,
                metalness: 0.10
            )

            let rack = boxNode(size: SIMD3<Float>(0.10, 0.028, 0.05) * sizeScale, chamfer: 0.008 * sizeScale, material: shellMaterial)
            rack.position = SCNVector3(0.0, -0.024 * sizeScale, 0.0)
            standardPresentation.addChildNode(rack)

            let rackBand = boxNode(size: SIMD3<Float>(0.104, 0.008, 0.052) * sizeScale, chamfer: 0.004 * sizeScale, material: capsuleAccentMaterial)
            rackBand.position = SCNVector3(0.0, -0.018 * sizeScale, 0.0)
            standardPresentation.addChildNode(rackBand)

            // Visible capsule count reflects the rigged count so the player can see remaining
            // ammo at a glance without a HUD element — same "show, don't tell" idea as the fire
            // hose's suppression foam.
            let capsuleCount = max(1, min(4, configuration.fireCapsuleCount))
            let spacing: Float = 0.026 * sizeScale
            let startX = -spacing * Float(capsuleCount - 1) / 2.0
            for index in 0..<capsuleCount {
                let capsule = sphereNode(radius: 0.011 * sizeScale, material: capsuleMaterial)
                capsule.position = SCNVector3(startX + spacing * Float(index), -0.040 * sizeScale, 0.0)
                standardPresentation.addChildNode(capsule)
            }
        case .agriculturalSprayer:
            let tankMaterial = material(
                diffuse: NSColor(calibratedRed: 0.16, green: 0.46, blue: 0.20, alpha: 1.0),
                roughness: 0.42,
                metalness: 0.16
            )
            let boomMaterial = material(
                diffuse: NSColor(calibratedWhite: 0.82, alpha: 1.0),
                roughness: 0.38,
                metalness: 0.30
            )

            let tank = cylinderNode(radius: 0.044 * sizeScale, height: 0.070 * sizeScale, material: tankMaterial)
            tank.position = SCNVector3(0.0, -0.048 * sizeScale, 0.0)
            standardPresentation.addChildNode(tank)

            let boom = boxNode(size: SIMD3<Float>(0.22, 0.010, 0.014) * sizeScale, chamfer: 0.003 * sizeScale, material: boomMaterial)
            boom.position = SCNVector3(0.0, -0.082 * sizeScale, 0.0)
            standardPresentation.addChildNode(boom)

            let nozzleCount = 4
            let spacing: Float = 0.052 * sizeScale
            let startX = -spacing * Float(nozzleCount - 1) / 2.0
            for index in 0..<nozzleCount {
                let nozzle = cylinderNode(radius: 0.006 * sizeScale, height: 0.014 * sizeScale, material: darkMaterial)
                nozzle.position = SCNVector3(startX + spacing * Float(index), -0.090 * sizeScale, 0.0)
                standardPresentation.addChildNode(nozzle)
            }
        case .rescuePack:
            let pack = boxNode(size: SIMD3<Float>(0.11, 0.07, 0.09) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            pack.position = SCNVector3(0.0, -0.040 * sizeScale, 0.0)
            standardPresentation.addChildNode(pack)

            let strap = boxNode(size: SIMD3<Float>(0.118, 0.010, 0.016) * sizeScale, chamfer: 0.003 * sizeScale, material: accentMaterial)
            strap.position = SCNVector3(0.0, -0.020 * sizeScale, 0.0)
            standardPresentation.addChildNode(strap)
        case .sensorModule:
            let module = boxNode(size: SIMD3<Float>(0.090, 0.050, 0.070) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            module.position = SCNVector3(0.0, -0.032 * sizeScale, 0.0)
            standardPresentation.addChildNode(module)

            let sensor = boxNode(size: SIMD3<Float>(0.040, 0.016, 0.040) * sizeScale, chamfer: 0.004 * sizeScale, material: darkMaterial)
            sensor.position = SCNVector3(0.0, -0.050 * sizeScale, 0.026 * sizeScale)
            standardPresentation.addChildNode(sensor)
        case .radioRelay:
            let relay = boxNode(size: SIMD3<Float>(0.085, 0.055, 0.060) * sizeScale, chamfer: 0.010 * sizeScale, material: shellMaterial)
            relay.position = SCNVector3(0.0, -0.030 * sizeScale, 0.0)
            standardPresentation.addChildNode(relay)

            for side: Float in [-1.0, 1.0] {
                let antenna = cylinderNode(radius: 0.004 * sizeScale, height: 0.070 * sizeScale, material: accentMaterial)
                antenna.position = SCNVector3(0.022 * side * sizeScale, 0.020 * sizeScale, -0.012 * sizeScale)
                standardPresentation.addChildNode(antenna)
            }
        case .customModule:
            let module = boxNode(size: SIMD3<Float>(0.10, 0.06, 0.08) * sizeScale, chamfer: 0.012 * sizeScale, material: shellMaterial)
            module.position = SCNVector3(0.0, -0.036 * sizeScale, 0.0)
            standardPresentation.addChildNode(module)
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
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
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
