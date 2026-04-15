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
        case .inertImpactPod:
            let body = cylinderNode(radius: 0.026 * sizeScale, height: 0.120 * sizeScale, material: shellMaterial)
            body.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            body.position = SCNVector3(0.0, -0.040 * sizeScale, 0.0)
            standardPresentation.addChildNode(body)

            let nose = sphereNode(radius: 0.023 * sizeScale, material: accentMaterial)
            nose.position = SCNVector3(0.0, -0.040 * sizeScale, 0.060 * sizeScale)
            standardPresentation.addChildNode(nose)

            let tailBand = cylinderNode(radius: 0.030 * sizeScale, height: 0.014 * sizeScale, material: darkMaterial)
            tailBand.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
            tailBand.position = SCNVector3(0.0, -0.040 * sizeScale, -0.036 * sizeScale)
            standardPresentation.addChildNode(tailBand)
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
