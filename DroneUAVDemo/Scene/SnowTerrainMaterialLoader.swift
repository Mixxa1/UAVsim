import AppKit
import SceneKit

private enum SnowTerrainConstants {
    static let resourceName = "Snow04"
    static let resourceExtension = "usdz"
    static let tileMeters: Float = 6.0
    static let fallbackColor = NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.96, alpha: 1.0)
}

enum SnowTerrainMaterialLoader {
    private static var cachedAlbedo: Any?
    private static var didAttemptLoad = false

    static func makeSnowMaterial(mapSizeMeters: Float) -> SCNMaterial {
        let albedo = loadAlbedo()

        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true

        material.diffuse.contents = albedo
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat

        let repeatCount = CGFloat(max(mapSizeMeters / SnowTerrainConstants.tileMeters, 1.0))
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatCount, repeatCount, 1)

        material.normal.contents = nil
        material.displacement.contents = nil
        material.transparent.contents = nil
        material.emission.contents = nil
        material.roughness.contents = NSNumber(value: 0.85)
        material.metalness.contents = NSNumber(value: 0.0)

        return material
    }

    private static func loadAlbedo() -> Any {
        if didAttemptLoad {
            return cachedAlbedo ?? SnowTerrainConstants.fallbackColor
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: SnowTerrainConstants.resourceName,
            withExtension: SnowTerrainConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            print("[Terrain] Snow04.usdz not found; using fallback snow color")
            return SnowTerrainConstants.fallbackColor
        }

        if let albedo = extractAlbedo(from: scene.rootNode) {
            cachedAlbedo = albedo
            return albedo
        }

        #if DEBUG
        print("[Terrain] Snow04 albedo not found in scene; using fallback color")
        #endif
        return SnowTerrainConstants.fallbackColor
    }

    private static func extractAlbedo(from node: SCNNode) -> Any? {
        if let mat = node.geometry?.firstMaterial {
            if let v = imageContents(from: mat.diffuse) { return v }
            if let v = imageContents(from: mat.multiply) { return v }
            if let v = imageContents(from: mat.emission) { return v }
        }
        for child in node.childNodes {
            if let result = extractAlbedo(from: child) { return result }
        }
        return nil
    }

    private static func imageContents(from property: SCNMaterialProperty) -> Any? {
        switch property.contents {
        case let image as NSImage: return image
        case let color as NSColor: return color
        case let cgImage as CGImage: return cgImage
        default: return nil
        }
    }
}
