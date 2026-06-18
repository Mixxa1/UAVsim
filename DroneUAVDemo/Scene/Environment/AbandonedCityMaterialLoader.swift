import AppKit
import SceneKit

enum AbandonedCityMaterialSource: String {
    case png
    case usdz
    case fallback
}

enum AbandonedCityMaterialLoader {
    private static let tileMeters: Float = 8.0
    private static let fallbackColor = NSColor(
        calibratedRed: 0.31,
        green: 0.29,
        blue: 0.25,
        alpha: 1.0
    )

    private static var cachedAlbedo: Any?
    private static var cachedSource: AbandonedCityMaterialSource?

    static func makeBrittleStoneMaterial(mapSizeMeters: Float) -> SCNMaterial {
        let (albedo, source) = loadAlbedo()

        let material = SCNMaterial()
        material.name = "terrain.city.abandoned.brittleStone"
        material.lightingModel = .lambert
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true
        material.diffuse.contents = albedo
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat

        let repeatCount = CGFloat(max(mapSizeMeters / tileMeters, 1.0))
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(
            repeatCount,
            repeatCount,
            1.0
        )
        material.normal.contents = nil
        material.displacement.contents = nil
        material.transparent.contents = nil
        material.emission.contents = nil
        material.metalness.contents = NSNumber(value: 0.0)
        material.roughness.contents = NSNumber(value: 0.9)

        #if DEBUG
        print("[AbandonedCity] baseSurface=brittleStone source=\(source.rawValue)")
        #endif
        return material
    }

    private static func loadAlbedo() -> (Any, AbandonedCityMaterialSource) {
        if let cachedAlbedo, let cachedSource {
            return (cachedAlbedo, cachedSource)
        }

        if let pngURL = AbandonedCityAssetCatalog.bundleURL(
            resourceName: AbandonedCityAssetCatalog.brittleStoneAlbedoName,
            extension: "png",
            subdirectory: AbandonedCityAssetCatalog.textureSubdirectory
        ), let image = NSImage(contentsOf: pngURL) {
            cachedAlbedo = image
            cachedSource = .png
            return (image, .png)
        }

        if let usdzURL = AbandonedCityAssetCatalog.bundleURL(
            resourceName: AbandonedCityAssetCatalog.brittleStoneModelName,
            extension: "usdz",
            subdirectory: AbandonedCityAssetCatalog.modelSubdirectory
        ), let scene = try? SCNScene(url: usdzURL, options: nil),
           let image = extractAlbedo(from: scene.rootNode) {
            cachedAlbedo = image
            cachedSource = .usdz
            return (image, .usdz)
        }

        print("[AbandonedCity] WARNING brittle stone texture unavailable; using neutral stone fallback")
        cachedAlbedo = fallbackColor
        cachedSource = .fallback
        return (fallbackColor, .fallback)
    }

    private static func extractAlbedo(from node: SCNNode) -> Any? {
        if let material = node.geometry?.firstMaterial,
           let contents = imageContents(from: material.diffuse) {
            return contents
        }
        for child in node.childNodes {
            if let contents = extractAlbedo(from: child) {
                return contents
            }
        }
        return nil
    }

    private static func imageContents(from property: SCNMaterialProperty) -> Any? {
        switch property.contents {
        case let image as NSImage:
            return image
        case let cgImage as CGImage:
            return cgImage
        default:
            return nil
        }
    }
}
