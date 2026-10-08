import AppKit
import SceneKit
import Metal
import simd

// Native import and studio inspection of the packaged USDZ, not its source mesh.
// Usage: render <model-directory> <previews-directory> [catalog-id]
let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("Usage: render <models> <previews> [id]") }
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is unavailable") }
let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "usdz" && (args.count < 4 || $0.deletingPathExtension().lastPathComponent == args[3]) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

func environment() -> NSImage {
    let w = 1024, h = 512
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: w * 3, bitsPerPixel: 24)!
    let bytes = bitmap.bitmapData!
    for y in 0..<h {
        for x in 0..<w {
            let u = Float(x) / Float(w), v = Float(y) / Float(h)
            let key = exp(-pow((u - 0.29) / 0.075, 4) - pow((v - 0.31) / 0.12, 4))
            let strip = exp(-pow((u - 0.78) / 0.027, 4) - pow((v - 0.41) / 0.18, 4))
            let fill = exp(-pow((u - 0.06) / 0.16, 2) - pow((v - 0.36) / 0.21, 2))
            let base: Float = 58 + 30 * (1 - v)
            for c in 0..<3 {
                let value = min(255, base + key * 153 + strip * 163 + fill * 42 + (c == 2 ? 5 : 0))
                bytes[y * w * 3 + x * 3 + c] = UInt8(value)
            }
        }
    }
    let image = NSImage(size: NSSize(width: w, height: h))
    image.addRepresentation(bitmap)
    return image
}
let ibl = environment()
var rows: [[String: Any]] = []
for url in files {
    try autoreleasepool {
        let id = url.deletingPathExtension().lastPathComponent
        let scene = try SCNScene(url: url, options: [.checkConsistency: true])
        let model = scene.rootNode.childNode(withName: "WorkbenchPart", recursively: true) ?? scene.rootNode
        let b = model.boundingBox
        let low = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
        let high = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
        let size = high - low, center = (low + high) * 0.5
        let extent = max(simd_length(size), 0.001)
        guard size.x > 0, size.y > 0, size.z > 0 else { fatalError("Empty USDZ \(id)") }
        var count = 0, triangles = 0, textured = 0
        model.enumerateChildNodes { node, _ in
            if let g = node.geometry {
                count += 1
                triangles += g.elements.reduce(0) { $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0) }
                for material in g.materials {
                    if let contents = material.diffuse.contents, !(contents is NSColor), !(contents is NSNumber) { textured += 1 }
                }
            }
        }
        guard count > 0 else { fatalError("No imported mesh \(id)") }
        scene.background.contents = NSColor(deviceRed: 0.115, green: 0.145, blue: 0.174, alpha: 1)
        scene.lightingEnvironment.contents = ibl
        scene.lightingEnvironment.intensity = 0.85
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.zNear = Double(extent) * 0.0001
        camera.zFar = Double(extent) * 12
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0.05
        camera.bloomIntensity = 0
        camera.screenSpaceAmbientOcclusionIntensity = 0.8
        camera.screenSpaceAmbientOcclusionRadius = Double(extent) * 0.014
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        for (direction, intensity, color) in [
            (SIMD3<Float>(-1.2, 2.0, 1.7), CGFloat(680), NSColor(deviceRed: 1, green: 0.96, blue: 0.91, alpha: 1)),
            (SIMD3<Float>(1.8, 0.8, -1.6), CGFloat(320), NSColor(deviceRed: 0.81, green: 0.89, blue: 1, alpha: 1)),
            (SIMD3<Float>(0.6, 1.2, -2.8), CGFloat(220), NSColor.white)
        ] {
            let node = SCNNode()
            node.light = SCNLight()
            node.light!.type = .directional
            node.light!.intensity = intensity
            node.light!.color = color
            node.simdPosition = center + direction * extent
            node.look(at: SCNVector3(center))
            scene.rootNode.addChildNode(node)
        }
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 75
        scene.rootNode.addChildNode(ambient)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        let flat = id.hasPrefix("prop-") || id.hasPrefix("fc-") || id.hasPrefix("esc-") || id.hasPrefix("gps-")
        let hero = flat ? SIMD3<Float>(0.65, 1.65, 1.1) : SIMD3<Float>(1.25, 0.9, 1.65)
        let views: [(String, SIMD3<Float>, SCNVector3)] = [
            ("", hero, SCNVector3(0, 1, 0)),
            ("-top", SIMD3<Float>(0, 3, 0), SCNVector3(0, 0, -1)),
            ("-rear", SIMD3<Float>(-1.2, 0.6, -1.8), SCNVector3(0, 1, 0)),
            ("-side", SIMD3<Float>(3, 0, 0), SCNVector3(0, 1, 0)),
            ("-underside", SIMD3<Float>(0.75, -1.2, 1.4), SCNVector3(0, 1, 0)),
            ("-front", SIMD3<Float>(0, 0, 3), SCNVector3(0, 1, 0))
        ]
        for (suffix, direction, up) in views {
            let back = simd_normalize(direction)
            let right = simd_normalize(simd_cross(SIMD3<Float>(Float(up.x), Float(up.y), Float(up.z)), back))
            let vertical = simd_cross(back, right)
            let width = simd_dot(abs(right), size), height = simd_dot(abs(vertical), size)
            let renderSize = NSSize(width: 1280, height: 960)
            camera.orthographicScale = Double(max(height / 2, width / (2 * 1280 / 960))) * 1.18
            cameraNode.simdPosition = center + back * extent * 3
            cameraNode.look(at: SCNVector3(center), up: up, localFront: SCNVector3(0, 0, -1))
            let image = renderer.snapshot(atTime: 0, with: renderSize, antialiasingMode: .multisampling4X)
            guard let data = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: data),
                  let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
            try png.write(to: output.appendingPathComponent(id + suffix + ".png"))
        }
        rows.append(["id": id, "meshes": count, "imported_triangles": triangles,
                     "textured_materials": textured, "bounds_min_m": [low.x, low.y, low.z],
                     "bounds_max_m": [high.x, high.y, high.z], "scene_kit_import": "passed"])
        print("\(id): SceneKit imported \(count) meshes, \(triangles) triangles, \(textured) texture bindings; 6 views")
    }
}
let reportURL = output.appendingPathComponent(args.count >= 4 ? "render-" + args[3] + ".json" : "render-report.json")
let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
try data.write(to: reportURL)
