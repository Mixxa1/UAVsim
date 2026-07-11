import AppKit
import SceneKit

/// Visual for the fiber-optic spool module — a standalone comms/control-link equipment slot
/// (see `FiberSpoolModule`), not a mission payload, so it gets its own small factory instead of
/// living in `PayloadVisualFactory`'s `PayloadType`-keyed switch.
enum FiberSpoolVisualFactory {
    static func build(reelClass: FiberOpticReelClass) -> SCNNode {
        let root = SCNNode()
        root.name = "fiberSpoolVisualNode"

        // Larger-tier reels carry more fiber and heavier hardware — a modest size bump reads as
        // "bigger reel" without needing a distinct model per tier.
        let scale: Float
        switch reelClass {
        case .short: scale = 0.85
        case .medium: scale = 1.0
        case .long: scale = 1.2
        }

        let shellMaterial = material(diffuse: NSColor(calibratedWhite: 0.74, alpha: 1.0), roughness: 0.56, metalness: 0.18)
        let reelMaterial = material(
            diffuse: NSColor(calibratedRed: 0.86, green: 0.53, blue: 0.06, alpha: 1.0),
            roughness: 0.44,
            metalness: 0.22
        )
        let darkMaterial = material(diffuse: NSColor(calibratedWhite: 0.18, alpha: 1.0), roughness: 0.44, metalness: 0.30)

        let spool = cylinderNode(radius: 0.030 * scale, height: 0.052 * scale, material: shellMaterial)
        spool.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        spool.position = SCNVector3(0.0, -0.032 * scale, 0.0)
        root.addChildNode(spool)

        let spoolBand = cylinderNode(radius: 0.032 * scale, height: 0.010 * scale, material: reelMaterial)
        spoolBand.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        spoolBand.position = SCNVector3(0.0, -0.032 * scale, 0.0)
        root.addChildNode(spoolBand)

        let feedEyelet = cylinderNode(radius: 0.006 * scale, height: 0.018 * scale, material: darkMaterial)
        feedEyelet.eulerAngles = SCNVector3(Float.pi / 2.0, 0.0, 0.0)
        feedEyelet.position = SCNVector3(0.0, -0.046 * scale, 0.030 * scale)
        root.addChildNode(feedEyelet)

        return root
    }

    private static func material(diffuse: NSColor, roughness: CGFloat, metalness: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = diffuse
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        material.lightingModel = .physicallyBased
        return material
    }

    private static func cylinderNode(radius: Float, height: Float, material: SCNMaterial) -> SCNNode {
        let geometry = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }
}
