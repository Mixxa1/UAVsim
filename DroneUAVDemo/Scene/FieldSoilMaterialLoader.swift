import AppKit
import SceneKit

private enum FieldSoilConstants {
    static let resourceName = "Dirt_2"
    static let resourceExtension = "usdz"
    /// Real-world size of one texture repeat. Ploughed soil has a visible clod scale; tiling it
    /// much larger reads as a blurry brown smear from spraying altitude, much smaller turns into
    /// moiré on the far side of the field.
    static let tileMeters: Float = 4.0
    static let fallbackColor = NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.15, alpha: 1.0)
}

/// Builds the ploughed-soil material of the agricultural mission's field from `Dirt_2.usdz`.
///
/// The asset is a material sample on a preview sphere, not a prop — the same shape as
/// `Generic_grass.usdz`, so this mirrors `GenericGrassMaterialLoader`: pull the textures out of
/// the first material that carries them, then tile them across the field patch.
enum FieldSoilMaterialLoader {
    private static var cachedAlbedo: Any?
    private static var cachedNormal: Any?
    private static var didAttemptLoad = false

    static func makeSoilMaterial(patchSizeMeters: Float) -> SCNMaterial {
        loadIfNeeded()

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = false
        material.diffuse.contents = cachedAlbedo ?? FieldSoilConstants.fallbackColor
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8.0

        let repeatCount = CGFloat(
            min(4_096.0, max(patchSizeMeters / FieldSoilConstants.tileMeters, 1.0))
        )
        let tiling = SCNMatrix4MakeScale(repeatCount, repeatCount, 1)
        material.diffuse.contentsTransform = tiling

        if let normal = cachedNormal {
            material.normal.contents = normal
            material.normal.wrapS = .repeat
            material.normal.wrapT = .repeat
            material.normal.contentsTransform = tiling
            material.normal.mipFilter = .linear
            material.normal.intensity = 0.8
        }

        material.roughness.contents = NSNumber(value: 0.95)
        material.metalness.contents = NSNumber(value: 0.0)
        return material
    }

    private static func loadIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: FieldSoilConstants.resourceName,
            withExtension: FieldSoilConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            print("[Agri] Dirt_2 soil material unavailable; using fallback ground colour")
            return
        }

        guard let material = firstTexturedMaterial(in: scene.rootNode) else {
            print("[Agri] Dirt_2 carried no usable texture; using fallback ground colour")
            return
        }
        cachedAlbedo = imageContents(from: material.diffuse)
        cachedNormal = imageContents(from: material.normal)
        print("[Agri] Dirt_2 soil material loaded: albedo=\(cachedAlbedo != nil), normal=\(cachedNormal != nil)")
    }

    private static func firstTexturedMaterial(in node: SCNNode) -> SCNMaterial? {
        if let material = node.geometry?.firstMaterial,
           imageContents(from: material.diffuse) != nil {
            return material
        }
        for child in node.childNodes {
            if let found = firstTexturedMaterial(in: child) {
                return found
            }
        }
        return nil
    }

    /// Resolves a material channel to an image that owns its own pixels.
    ///
    /// This asset hands its textures over as **file URLs into the unpacked archive**, not as
    /// loaded images. Handing such a URL straight to a long-lived material works right up until
    /// the source scene is released and its temporary files go with it — which is exactly what
    /// happens here, because the material outlives the `SCNScene` it was pulled from by the whole
    /// mission. The field then renders in the fallback colour with nothing in the logs to say why.
    /// Loading the image now, while the URL is still valid, is what makes the material safe to
    /// keep.
    private static func imageContents(from property: SCNMaterialProperty) -> Any? {
        switch property.contents {
        case let image as NSImage:
            return image
        case let cgImage as CGImage:
            return cgImage
        case let url as URL:
            return NSImage(contentsOf: url)
        case let path as String:
            return NSImage(contentsOfFile: path)
        default:
            return nil
        }
    }
}
