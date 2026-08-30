import AppKit
import SceneKit

private enum GrassConstants {
    static let resourceName = "Generic_grass"
    static let resourceExtension = "usdz"
    static let tileMeters: Float = 8.0
    static let fallbackColor = NSColor(calibratedRed: 0.32, green: 0.45, blue: 0.22, alpha: 1.0)
}

enum GenericGrassMaterialLoader {
    private static var cachedAlbedo: Any?
    private static var didAttemptLoad = false

    static func makeGrassMaterial(mapSizeMeters: Float) -> SCNMaterial {
        let albedo = loadAlbedo()

        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.isDoubleSided = false
        material.writesToDepthBuffer = true
        material.readsFromDepthBuffer = true

        material.diffuse.contents = albedo
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat

        // Capped at 8,192 repeats.
        //
        // A texture coordinate is a 32-bit float, and past about twenty thousand repeats
        // its spacing grows to a visible fraction of a tile: the sampler quantises inside
        // a single blade of grass and the ground smears. At 8,192 the coordinates are
        // exact to a ten-thousandth of a tile.
        //
        // The cap only binds on the extended map ranges, where it makes the far ground
        // coarse — which does not matter, because on those maps the near ground is drawn
        // by the detail patch that follows the aircraft (see
        // `DroneSceneController.refreshGroundDetailPatch`), and the capped plane is only
        // ever seen kilometres away.
        let repeatCount = CGFloat(
            min(8_192.0, max(mapSizeMeters / GrassConstants.tileMeters, 1.0))
        )
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(repeatCount, repeatCount, 1)
        // Grazing angles are most of what a low-flying camera sees of the ground, and they
        // are exactly where an isotropic sample collapses to a blur.
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8.0

        material.normal.contents = nil
        material.displacement.contents = nil
        material.transparent.contents = nil
        material.emission.contents = nil
        material.roughness.contents = NSNumber(value: 0.92)
        material.metalness.contents = NSNumber(value: 0.0)

        return material
    }

    private static func loadAlbedo() -> Any {
        if didAttemptLoad {
            return cachedAlbedo ?? GrassConstants.fallbackColor
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: GrassConstants.resourceName,
            withExtension: GrassConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            print("[Environment] Generic grass material unavailable; using fallback ground color")
            return GrassConstants.fallbackColor
        }

        let albedo = extractAlbedo(from: scene.rootNode)
        if let albedo {
            cachedAlbedo = albedo
            return albedo
        }

        #if DEBUG
        print("[Terrain] Generic grass albedo not found; using fallback color")
        #endif
        return GrassConstants.fallbackColor
    }

    private static func extractAlbedo(from node: SCNNode) -> Any? {
        if let mat = node.geometry?.firstMaterial {
            if let contents = imageContents(from: mat.diffuse) {
                return contents
            }
            if let contents = imageContents(from: mat.multiply) {
                return contents
            }
            if let contents = imageContents(from: mat.emission) {
                return contents
            }
        }
        for child in node.childNodes {
            if let result = extractAlbedo(from: child) {
                return result
            }
        }
        return nil
    }

    private static func imageContents(from property: SCNMaterialProperty) -> Any? {
        switch property.contents {
        case let image as NSImage:
            return image
        case let color as NSColor:
            return color
        case let cgImage as CGImage:
            return cgImage
        default:
            return nil
        }
    }
}
