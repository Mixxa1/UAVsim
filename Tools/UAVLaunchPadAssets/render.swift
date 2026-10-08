import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

guard CommandLine.arguments.count == 2 else { fatalError("Usage: render_launch_pad <asset-directory>") }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let previews = root.appendingPathComponent("previews")
try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
let asset = root.appendingPathComponent(manifest["file"] as! String)
let scene = try SCNScene(url: asset, options: [.checkConsistency: true])
guard let pad = scene.rootNode.childNode(withName: "LaunchPad", recursively: true),
      let device = MTLCreateSystemDefaultDevice() else { fatalError("Native USDZ import or Metal unavailable") }
var geometryCount = 0
var animated: [SCNNode] = []
var materials = Set<String>()
pad.enumerateChildNodes { node, _ in
    if let geometry = node.geometry {
        geometryCount += 1
        for material in geometry.materials { materials.insert(material.name ?? "unnamed") }
    }
    if !node.animationKeys.isEmpty {
        animated.append(node)
        for key in node.animationKeys {
            guard let player = node.animationPlayer(forKey: key) else { continue }
            player.animation.usesSceneTimeBase = true
            player.animation.repeatCount = .infinity
        }
    }
}
guard geometryCount == manifest["mesh_count"] as! Int else { fatalError("Missing USDZ meshes") }
guard animated.count == 6 else { fatalError("The six windsock joints did not import") }
let bounds = pad.boundingBox
let size = SIMD3<Float>(Float(bounds.max.x-bounds.min.x), Float(bounds.max.y-bounds.min.y), Float(bounds.max.z-bounds.min.z))
guard abs(size.x-16) < 0.005, abs(size.z-16) < 0.005 else { fatalError("Wrong metre-scale footprint: \(size)") }

// Studio ground is only a preview aid, outside the packaged asset.
let ground = SCNNode(geometry: SCNFloor())
ground.position.y = -0.312
ground.geometry!.firstMaterial!.diffuse.contents = NSColor(calibratedRed: 0.34, green: 0.38, blue: 0.39, alpha: 1)
ground.geometry!.firstMaterial!.roughness.contents = 1.0
(ground.geometry as! SCNFloor).reflectivity = 0
scene.rootNode.addChildNode(ground)

let cameraNode = SCNNode()
let camera = SCNCamera()
camera.usesOrthographicProjection = true
camera.zNear = 0.01
camera.zFar = 200
camera.wantsHDR = true
camera.wantsExposureAdaptation = false
camera.exposureOffset = 0
camera.screenSpaceAmbientOcclusionIntensity = 0.65
camera.screenSpaceAmbientOcclusionRadius = 0.30
camera.bloomIntensity = 0
cameraNode.camera = camera
scene.rootNode.addChildNode(cameraNode)

let ambient = SCNNode()
ambient.light = SCNLight()
ambient.light!.type = .ambient
ambient.light!.color = NSColor(calibratedRed: 0.84, green: 0.91, blue: 1, alpha: 1)
ambient.light!.intensity = 360
scene.rootNode.addChildNode(ambient)
let sun = SCNNode()
sun.light = SCNLight()
sun.light!.type = .directional
sun.light!.intensity = 1250
sun.light!.color = NSColor(calibratedRed: 1, green: 0.94, blue: 0.85, alpha: 1)
sun.light!.castsShadow = true
sun.light!.shadowMapSize = CGSize(width: 2048, height: 2048)
sun.light!.shadowSampleCount = 16
sun.light!.shadowColor = NSColor.black.withAlphaComponent(0.25)
sun.light!.orthographicScale = 24
sun.position = SCNVector3(-9, 18, 11)
sun.look(at: SCNVector3(0, 0, 0))
scene.rootNode.addChildNode(sun)
let fill = SCNNode()
fill.light = SCNLight()
fill.light!.type = .directional
fill.light!.intensity = 290
fill.position = SCNVector3(9, 7, -11)
fill.look(at: SCNVector3(0, 0, 0))
scene.rootNode.addChildNode(fill)
scene.background.contents = NSColor(calibratedRed: 0.20, green: 0.25, blue: 0.28, alpha: 1)

let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = cameraNode
func frame(target: SIMD3<Float>, direction: SIMD3<Float>, scale: Double, up: SIMD3<Float> = SIMD3(0, 1, 0)) {
    camera.orthographicScale = scale
    cameraNode.simdPosition = target + simd_normalize(direction)*50
    cameraNode.look(at: SCNVector3(target), up: SCNVector3(up), localFront: SCNVector3(0, 0, -1))
}
func snapshot(_ time: Double, _ width: Int, _ height: Int) -> NSImage {
    renderer.sceneTime = time
    return renderer.snapshot(atTime: time, with: NSSize(width: width, height: height), antialiasingMode: .multisampling4X)
}
func png(_ name: String, _ time: Double = 0, _ width: Int = 1500, _ height: Int = 1100) throws {
    let image = snapshot(time, width, height)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding") }
    try data.write(to: previews.appendingPathComponent(name+".png"))
}

frame(target: SIMD3(0, 0.35, 0), direction: SIMD3(1.10, 1.32, 1.55), scale: 9.1)
try png("uav-launch-pad")
frame(target: SIMD3(0, 0, 0), direction: SIMD3(0, 1, 0), scale: 8.7, up: SIMD3(0, 0, -1))
try png("uav-launch-pad-top", 0, 1300, 1300)
frame(target: SIMD3(6.8, 0.64, 4.65), direction: SIMD3(1.2, 0.8, 1.8), scale: 1.20)
try png("uav-launch-pad-cabinet", 0, 1000, 900)
frame(target: SIMD3(6.1, 2.98, -6.45), direction: SIMD3(1.1, 0.55, 1.6), scale: 1.3)
try png("uav-launch-pad-windsock", 0, 1000, 750)

// Verify real imported motion while rendering with a stationary camera.
let cycle = 6.0
var poses: [[String: Any]] = []
var matrices: [String: [simd_float4x4]] = [:]
for time in [0.0, 1.5, 3.0, 4.5, 6.0] {
    _ = snapshot(time, 160, 120)
    for node in animated {
        let transform = node.presentation.simdTransform
        let name = node.name!
        matrices[name, default: []].append(transform)
        let values = (0..<4).flatMap { column in (0..<4).map { row in transform[column][row] } }
        poses.append(["node": name, "time": time, "transform": values])
    }
}
func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    (0..<4).map { simd_length(a[$0]-b[$0]) }.max()!
}
for (name, samples) in matrices {
    guard samples.dropFirst().dropLast().contains(where: { distance(samples[0], $0) > 0.01 }) else {
        fatalError("Static imported windsock joint: \(name)")
    }
    guard distance(samples[0], samples.last!) < 0.003 else { fatalError("Unclosed windsock cycle: \(name)") }
}

func writeGIF(_ name: String) {
let gifURL = previews.appendingPathComponent(name+".gif")
let frames = 72
guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frames, nil) else {
    fatalError("GIF destination")
}
CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for index in 0..<frames {
    let image = snapshot(cycle*Double(index)/Double(frames), 800, 600)
    var rect = CGRect(x: 0, y: 0, width: 800, height: 600)
    guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { fatalError("GIF frame") }
    CGImageDestinationAddImage(gif, cg, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: cycle/Double(frames)]] as CFDictionary)
}
guard CGImageDestinationFinalize(gif) else { fatalError("GIF finalize") }
}
writeGIF("uav-launch-pad-windsock")
frame(target: SIMD3(0, 0.35, 0), direction: SIMD3(1.10, 1.32, 1.55), scale: 9.1)
writeGIF("uav-launch-pad-animated")
print("Native USDZ: \(geometryCount) meshes, \(animated.count) moving joints, closed 6s cycle")
fflush(stdout)

ambient.light!.intensity = 55
sun.light!.intensity = 110
fill.light!.intensity = 45
sun.light!.color = NSColor(calibratedRed: 0.64, green: 0.74, blue: 1, alpha: 1)
camera.bloomIntensity = 0
let lensNodes = pad.childNode(withName: "EdgeLights", recursively: false)!.childNodes.filter { ($0.name ?? "").hasPrefix("GreenLens") }
for lens in lensNodes {
    let light = SCNNode()
    light.light = SCNLight()
    light.light!.type = .omni
    light.light!.color = NSColor(calibratedRed: 0.68, green: 0.80, blue: 0.68, alpha: 1)
    light.light!.intensity = 4
    light.light!.attenuationStartDistance = 0.2
    light.light!.attenuationEndDistance = 2.2
    let centre = lens.boundingBox
    light.position = SCNVector3((centre.min.x+centre.max.x)/2, 0.075, (centre.min.z+centre.max.z)/2)
    scene.rootNode.addChildNode(light)
}
frame(target: SIMD3(0, 0.3, 0), direction: SIMD3(1.1, 1.25, 1.6), scale: 9.1)
try png("uav-launch-pad-night", 1.5)

let hash = SHA256.hash(data: try Data(contentsOf: asset)).map { String(format: "%02x", $0) }.joined()
let report: [String: Any] = [
    "asset_sha256": hash, "native_import": "passed", "geometry_count": geometryCount,
    "bounds_min_m": [bounds.min.x, bounds.min.y, bounds.min.z],
    "bounds_max_m": [bounds.max.x, bounds.max.y, bounds.max.z],
    "animated_nodes": animated.map { $0.name! }, "closed_animation_cycle": true,
    "cycle_seconds": cycle, "animation_poses": poses, "material_names": Array(materials).sorted(),
    "preview_note": "Exact USDZ imported by SceneKit/Metal. Studio floor, cameras and illumination are preview aids."
]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("native-validation.json"))
print("Rendered five views, full-pad animation and windsock animation")
