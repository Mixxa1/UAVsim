import AppKit
import SceneKit

private enum RunwayAssetConstants {
    static let resourceName = "Runway"
    static let resourceExtension = "usdz"
    static let nodeName = "launch.runway_strip"
    /// Width of the strip, and the width the imported model is scaled to. 45 m is
    /// the ICAO code-E figure — the class of runway an MQ-9 operates from — and a
    /// width is a standard rather than something to derive from a model's aspect.
    static let widthMeters: Float = 45.0
    /// How far the paved surface stands above the surrounding ground.
    static let surfaceProudMeters: Float = 0.02
}

/// Loads `Runway.usdz` as the runway strip, with a procedural strip as the fallback.
///
/// Same contract as `PineTreeAssetLoader` and `FireTruckAssetLoader`: a lazily
/// cached template, normalisation onto the dimensions the caller asks for, and a
/// procedural stand-in when the asset is not bundled — so the runway launch works
/// either way and the imported model is a visual upgrade rather than a dependency.
///
/// The model is fitted by its **width** and tiled along the strip; see
/// `makeRunwayNode`. It is laid out from the threshold along -Z, matching the
/// launch heading applied to the parent node, and long enough to cover the usable
/// distance the launch sequence measures its abort against.
///
/// Attribution for the imported asset lives in `Resources/Credits/ThirdPartyAssets.json`
/// and is required by its licence whenever the file is present.
final class RunwayAssetLoader {
    static let shared = RunwayAssetLoader()

    private var cachedTemplate: SCNNode?
    private var modelNativeLength: Float = 1.0
    private var modelNativeWidth: Float = 1.0
    private var modelNativeMaxY: Float = 0.0
    private var modelNativeCenter = SIMD3<Float>(repeating: 0.0)
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makeRunwayNode(lengthMeters: Float) -> SCNNode {
        let length = max(40.0, lengthMeters)
        guard let template = loadTemplate() else {
            warnOnce()
            return makeProceduralRunway(lengthMeters: length)
        }

        // Fit by WIDTH and tile along the strip, rather than stretching one copy to
        // the required length.
        //
        // Scaling by length looked simpler and is wrong for any real runway asset:
        // this one is 13:1, so sizing it to a kilometre of strip would have made it
        // seventy-five metres wide, and scaling non-uniformly instead would smear
        // the centreline dashes down the whole runway. A runway's width is a
        // standard, not a free parameter — so pin the width, keep the model's own
        // proportions, and lay down as many copies as the strip needs.
        let scale = RunwayAssetConstants.widthMeters / max(modelNativeWidth, 0.001)
        let tileLength = max(1.0, modelNativeLength * scale)
        let tiles = max(1, Int((length / tileLength).rounded(.up)))

        let wrapper = SCNNode()
        wrapper.name = RunwayAssetConstants.nodeName
        for index in 0..<tiles {
            let model = template.clone()
            model.scale = SCNVector3(scale, scale, scale)
            // The strip starts at the threshold (z = 0) and runs along -Z, and the
            // slab sits flush: its top surface is a hair proud of the grass rather
            // than a step the aircraft has to be lifted onto. An imported runway is
            // typically a thick slab, and standing the aircraft on top of it — or
            // burying it inside — was the difference between a takeoff roll and a
            // model wedged into the asphalt.
            model.position = SCNVector3(
                -modelNativeCenter.x * scale,
                -modelNativeMaxY * scale + RunwayAssetConstants.surfaceProudMeters,
                -modelNativeCenter.z * scale - tileLength * (Float(index) + 0.5)
            )
            wrapper.addChildNode(model)
        }
        return wrapper
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: RunwayAssetConstants.resourceName,
            withExtension: RunwayAssetConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let root = SCNNode()
        root.name = "runway_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }

        let (minBB, maxBB) = root.boundingBox
        // The long horizontal axis is the runway's length whichever way the asset
        // was authored, so measure rather than assume.
        let extentX = Float(maxBB.x - minBB.x)
        let extentZ = Float(maxBB.z - minBB.z)
        if extentX > extentZ {
            // Authored across X: turn it to run along -Z like every other launcher.
            root.eulerAngles = SCNVector3(0.0, SCNFloat.pi / 2.0, 0.0)
            modelNativeLength = extentX
            modelNativeWidth = extentZ
        } else {
            modelNativeLength = extentZ
            modelNativeWidth = extentX
        }
        modelNativeLength = max(modelNativeLength, 0.001)
        modelNativeMaxY = Float(maxBB.y)
        modelNativeCenter = SIMD3<Float>(
            Float(minBB.x + maxBB.x) * 0.5,
            0.0,
            Float(minBB.z + maxBB.z) * 0.5
        )
        print("[Launch] Runway.usdz loaded: nativeLength=\(modelNativeLength) "
              + "nativeWidth=\(modelNativeWidth) nativeTop=\(modelNativeMaxY) units "
              + "(bounding box); one tile covers "
              + "\(modelNativeLength * RunwayAssetConstants.widthMeters / max(modelNativeWidth, 0.001)) m")

        cachedTemplate = root
        return root
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Launch] Runway asset unavailable; using procedural strip")
    }

    /// Paved surface, dashed centreline and threshold bars. Nothing here moves — a
    /// runway has no carriage, no arm and no muzzle cap, because it puts no energy
    /// into the aircraft. It is drawn so the operator can see the heading he is
    /// committed to and how much of the strip the roll is using.
    private func makeProceduralRunway(lengthMeters: Float) -> SCNNode {
        let root = SCNNode()
        root.name = RunwayAssetConstants.nodeName
        let length = lengthMeters
        let width = CGFloat(RunwayAssetConstants.widthMeters)
        let halfWidth = Float(width) * 0.5

        let surfaceMaterial = SCNMaterial()
        surfaceMaterial.diffuse.contents = NSColor(calibratedWhite: 0.19, alpha: 1.0)
        surfaceMaterial.roughness.contents = 0.92
        surfaceMaterial.metalness.contents = 0.0

        let markingMaterial = SCNMaterial()
        markingMaterial.diffuse.contents = NSColor(calibratedWhite: 0.86, alpha: 1.0)
        markingMaterial.roughness.contents = 0.80
        // Coplanar with the surface: paint the markings on top instead of letting
        // the depth buffer fight over two surfaces a centimetre apart.
        markingMaterial.writesToDepthBuffer = false
        markingMaterial.readsFromDepthBuffer = false

        let surface = SCNNode(geometry: SCNBox(
            width: width,
            height: 0.08,
            length: CGFloat(length),
            chamferRadius: 0.0
        ))
        surface.geometry?.materials = [surfaceMaterial]
        surface.simdPosition = SIMD3<Float>(0.0, RunwayAssetConstants.surfaceProudMeters - 0.04, -length * 0.5)
        surface.renderingOrder = -20
        root.addChildNode(surface)

        let dashLength: Float = 12.0
        let dashGap: Float = 12.0
        var travelled: Float = dashGap
        while travelled + dashLength < length {
            let dash = SCNNode(geometry: SCNBox(
                width: 0.9,
                height: 0.02,
                length: CGFloat(dashLength),
                chamferRadius: 0.0
            ))
            dash.geometry?.materials = [markingMaterial]
            dash.simdPosition = SIMD3<Float>(0.0, RunwayAssetConstants.surfaceProudMeters + 0.01, -(travelled + dashLength * 0.5))
            dash.renderingOrder = -19
            root.addChildNode(dash)
            travelled += dashLength + dashGap
        }

        for offset in stride(from: -halfWidth * 0.62, through: halfWidth * 0.62, by: halfWidth * 0.21) {
            let bar = SCNNode(geometry: SCNBox(width: 1.4, height: 0.02, length: 14.0, chamferRadius: 0.0))
            bar.geometry?.materials = [markingMaterial]
            bar.simdPosition = SIMD3<Float>(offset, RunwayAssetConstants.surfaceProudMeters + 0.01, -9.0)
            bar.renderingOrder = -19
            root.addChildNode(bar)
        }

        return root
    }
}
