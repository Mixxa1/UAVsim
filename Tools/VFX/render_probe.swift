import AppKit
import Metal
import SceneKit

/// Checks the actual Metal sampling and frame interpolation, not just the CPU frame number.
@main struct FlipbookRenderProbe {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedWhite: 0.08, alpha: 1)
        renderer.scene = scene
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 1.2
        camera.position = SCNVector3(0, 0, 5)
        scene.rootNode.addChildNode(camera); renderer.pointOfView = camera
        let geometry = SCNPlane(width: 2, height: 2)
        let node = SCNNode(geometry: geometry); scene.rootNode.addChildNode(node)
        for asset in HoudiniFlipbook.allCases {
            let material = asset.makeMaterial(); geometry.firstMaterial = material
            var firstPixels: Data?
            for (index, age) in [0.0, 0.25, 0.5, 1.0, 1.5].enumerated() {
                SCNTransaction.begin(); SCNTransaction.disableActions = true
                asset.setAge(age, material: material)
                SCNTransaction.commit(); SCNTransaction.flush()
                let image = renderer.snapshot(atTime: age, with: CGSize(width: 400, height: 400), antialiasingMode: .none)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                let pixels = Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
                if index == 0 { firstPixels = pixels }
                if index == 2 {
                    let changed = zip(firstPixels!, pixels).filter { abs(Int($0) - Int($1)) > 10 }.count
                    precondition(changed > 2000, "\(asset.rawValue) must actually animate on Metal")
                }
                try bitmap.representation(using: .png, properties: [:])!.write(to:
                    output.appendingPathComponent("\(asset.rawValue)-\(index).png"))
                print("FRAME: \(asset.rawValue), \(age)s, uniform=\(material.value(forKey: "vfxFrame")!)")
            }
        }
        print("PASS: flame, burst and smoke animate on the native renderer")
    }
}
