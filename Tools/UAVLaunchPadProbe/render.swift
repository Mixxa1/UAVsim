import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers

/// Render the same runtime class used by DroneSceneController, with changing wind.
/// No imported USDZ clip plays here; every pose is produced by WindsockDynamics.
@main
struct WindResponsePreview {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: wind_preview <bundle-folder> <preview-folder>") }
        let bundle = URL(fileURLWithPath: CommandLine.arguments[1])
        let out = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let pad = UAVLaunchPadAssetLoader(directory: bundle).makeInstance(),
              let device = MTLCreateSystemDefaultDevice() else { fatalError("Native asset or Metal unavailable") }
        let scene = SCNScene()
        scene.rootNode.addChildNode(pad.node)
        pad.node.simdPosition.y = UAVLaunchPadConstants.deckRiseAboveGroundM
        scene.background.contents = NSColor(calibratedRed: 0.25, green: 0.29, blue: 0.30, alpha: 1)
        let floor = SCNNode(geometry: SCNFloor())
        (floor.geometry as! SCNFloor).reflectivity = 0
        floor.geometry!.firstMaterial!.diffuse.contents = NSColor(calibratedRed: 0.33, green: 0.37, blue: 0.36, alpha: 1)
        scene.rootNode.addChildNode(floor)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 360
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 1000
        sun.position = SCNVector3(-8, 18, 9)
        sun.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sun)
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 2.15
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        let target = SIMD3<Float>(7.25, 2.35, -6.15)
        cameraNode.simdPosition = target + simd_normalize(SIMD3<Float>(1.1, 0.4, 1.6))*30
        cameraNode.look(at: SCNVector3(target))
        scene.rootNode.addChildNode(cameraNode)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let fps = 12, seconds = 21, frames = fps * seconds
        let gifURL = out.appendingPathComponent("uav-launch-pad-wind-response.gif")
        guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames, nil) else { fatalError("GIF destination") }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        var samples: [[String: Any]] = []
        for index in 0..<frames {
            let time = Float(index) / Float(fps)
            let wind = time < 3 || time >= 15 ? SIMD3<Float>.zero
                : time < 9 ? SIMD3<Float>(0, 0, 8) : SIMD3<Float>(8, 0, 0)
            for _ in 0..<5 { pad.update(wind: wind, gusts: 0.55, deltaTime: 1 / Float(fps * 5)) }
            renderer.sceneTime = Double(time)
            let image = renderer.snapshot(atTime: Double(time), with: NSSize(width: 800, height: 600), antialiasingMode: .multisampling4X)
            if [2 * fps, 8 * fps, 14 * fps, 20 * fps].contains(index),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("wind-response-\(index / fps)s.png"))
            }
            var rect = CGRect(x: 0, y: 0, width: 800, height: 600)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("GIF frame") }
            CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / Double(fps)]] as CFDictionary)
            if index % fps == 0 {
                let heading = pad.node.childNode(withName: "Yaw", recursively: true)!
                let forward = heading.simdConvertVector(SIMD3<Float>(0, 0, 1), to: nil)
                samples.append(["time_seconds": time, "wind_mps": [wind.x, wind.y, wind.z],
                                "heading_forward": [forward.x, forward.y, forward.z]])
            }
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("GIF finalize") }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("wind-response.json"))
        print("Rendered simulator wind response: calm → 8 m/s along +Z → 8 m/s along +X → calm")
    }
}
