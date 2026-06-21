import AppKit
import SceneKit

private enum AsphaltMaterialConstants {
    static let resourceName = "Asphalt13"
    static let resourceExtension = "usdz"
    static let tileMeters: Float = 7.0
    static let fallbackColor = NSColor(
        calibratedRed: 0.19,
        green: 0.20,
        blue: 0.21,
        alpha: 1.0
    )
}

enum AsphaltMaterialLoader {
    private static var cachedSourceMaterial: SCNMaterial?
    private static var didAttemptLoad = false

    static func makeAsphaltMaterial(mapSizeMeters: Float) -> SCNMaterial {
        let source = loadSourceMaterial()
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true

        copy(source?.diffuse, to: material.diffuse, fallback: AsphaltMaterialConstants.fallbackColor)
        copy(source?.normal, to: material.normal)
        copy(source?.roughness, to: material.roughness, fallback: NSNumber(value: 0.88))
        copy(source?.metalness, to: material.metalness, fallback: NSNumber(value: 0.02))
        copy(source?.ambientOcclusion, to: material.ambientOcclusion)

        let repeatCount = CGFloat(max(mapSizeMeters / AsphaltMaterialConstants.tileMeters, 1.0))
        for property in [
            material.diffuse,
            material.normal,
            material.roughness,
            material.metalness,
            material.ambientOcclusion
        ] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.contentsTransform = SCNMatrix4MakeScale(repeatCount, repeatCount, 1.0)
        }

        material.displacement.contents = nil
        material.transparent.contents = nil
        material.emission.contents = nil
        return material
    }

    private static func loadSourceMaterial() -> SCNMaterial? {
        if didAttemptLoad {
            return cachedSourceMaterial
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: AsphaltMaterialConstants.resourceName,
            withExtension: AsphaltMaterialConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]),
        let material = firstMaterial(in: scene.rootNode) else {
            print("[Terrain] Asphalt13.usdz not found; using fallback asphalt color")
            return nil
        }

        cachedSourceMaterial = material
        return material
    }

    private static func firstMaterial(in node: SCNNode) -> SCNMaterial? {
        if let material = node.geometry?.firstMaterial {
            return material
        }
        for child in node.childNodes {
            if let material = firstMaterial(in: child) {
                return material
            }
        }
        return nil
    }

    private static func copy(
        _ source: SCNMaterialProperty?,
        to destination: SCNMaterialProperty,
        fallback: Any? = nil
    ) {
        destination.contents = source?.contents ?? fallback
        destination.intensity = source?.intensity ?? 1.0
    }
}
