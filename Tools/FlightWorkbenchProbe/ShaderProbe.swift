import AppKit
import SceneKit
import Metal
import DroneUAVDemo

@main struct ShaderProbe {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let sourceURL = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("DroneUAVDemo/Scene/World/TerrainMeshFactory.swift")
        let source = try String(contentsOf: sourceURL)
        func shader(_ name: String) -> String {
            let tail = source.components(separatedBy: "private static let " + name + " = \"\"\"")[1]
            return tail.components(separatedBy: "\"\"\"")[0].split(separator: "\n").map { String($0.dropFirst(4)) }.joined(separator: "\n")
        }
        var config = TerrainConfiguration.default
        config.preset = .field; config.mapScale = .x4; config.seed = 42; config.reliefEnabled = true; config.reliefAmplitude = 250
        let scene = SCNScene()
        let node = TerrainMeshFactory.makeReliefNode(configuration: config)!
        node.geometry!.firstMaterial!.shaderModifiers = [.geometry: shader("reliefGeometryShader"), .surface: shader("reliefSurfaceShader")]
        scene.rootNode.addChildNode(node)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.zFar = 10000
        camera.position = SCNVector3(250, 180, 320); camera.look(at: SCNVector3(150, 40, 170))
        scene.rootNode.addChildNode(camera)
        scene.background.contents = NSColor(calibratedRed: 0.45, green: 0.65, blue: 0.85, alpha: 1)
        let light = SCNNode(); light.light = SCNLight(); light.light!.type = .directional; light.light!.intensity = 800; light.eulerAngles = SCNVector3(-0.8, -0.5, 0); scene.rootNode.addChildNode(light)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light!.type = .ambient; ambient.light!.intensity = 500; scene.rootNode.addChildNode(ambient)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera
        for i in 0...1 {
            let image = renderer.snapshot(atTime: Double(i), with: CGSize(width: 1200, height: 800), antialiasingMode: .multisampling4X)
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let data = rep.representation(using: .png, properties: [:])!
            try data.write(to: output.appendingPathComponent("relief-stress.png"))
            var magenta = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) { for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                let c = rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if c.redComponent > 0.8 && c.blueComponent > 0.8 && c.greenComponent < 0.2 { magenta += 1 }
            } }
            print("Shader render \(i): magenta=\(magenta)")
        }
    }
}
