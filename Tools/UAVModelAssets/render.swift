import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("Usage: render <model-directory> <output-directory> [id]") }
let input = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device unavailable") }
let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "usdz" && (args.count < 4 || $0.deletingPathExtension().lastPathComponent == args[3]) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
var reports: [[String: Any]] = []
for url in files {
    try autoreleasepool {
        let scene = try SCNScene(url: url, options: [.checkConsistency: true])
        let model = scene.rootNode
        let bounds = model.boundingBox
        let low = SIMD3<Float>(Float(bounds.min.x), Float(bounds.min.y), Float(bounds.min.z))
        let high = SIMD3<Float>(Float(bounds.max.x), Float(bounds.max.y), Float(bounds.max.z))
        let center = (low + high) * 0.5
        let size = high - low
        guard size.x > 0 && size.y > 0 && size.z > 0 else { fatalError("Empty asset: \(url)") }
        var geometries = 0
        var animated: [[String: Any]] = []
        model.enumerateChildNodes { node, _ in
            if node.geometry != nil { geometries += 1 }
            if !node.animationKeys.isEmpty {
                animated.append(["node": node.name ?? "", "keys": node.animationKeys])
                for key in node.animationKeys {
                    if let player = node.animationPlayer(forKey: key) {
                        player.animation.usesSceneTimeBase = true
                        player.animation.repeatCount = .infinity
                    }
                }
            }
        }
        guard geometries > 0 else { fatalError("No imported mesh: \(url)") }
        let extent = simd_length(size)
        let sceneCamera = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(extent) * 0.62
        camera.zNear = Double(extent) * 0.001
        camera.zFar = Double(extent) * 15
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = 0
        camera.wantsDepthOfField = false
        camera.screenSpaceAmbientOcclusionIntensity = 0.65
        camera.screenSpaceAmbientOcclusionRadius = Double(extent) * 0.035
        func frame(_ direction: SIMD3<Float>, _ up: SCNVector3, aspect: Float) {
            let back=simd_normalize(direction)
            let right=simd_normalize(simd_cross(SIMD3<Float>(Float(up.x),Float(up.y),Float(up.z)),back))
            let vertical=simd_cross(back,right)
            let width=simd_dot(abs(right),size), height=simd_dot(abs(vertical),size)
            camera.orthographicScale=Double(max(height/2,width/(2*aspect)))*1.18
        }
        sceneCamera.camera = camera
        sceneCamera.simdPosition = center + simd_normalize(SIMD3<Float>(1.1,0.85,1.4)) * extent * 3
        sceneCamera.look(at: SCNVector3(center), up: SCNVector3(0,1,0), localFront: SCNVector3(0,0,-1))
        model.addChildNode(sceneCamera)
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light!.type = .ambient
        ambient.light!.intensity = 450;ambient.light!.color = NSColor(calibratedRed: 0.90, green: 0.94, blue: 1.0, alpha: 1)
        model.addChildNode(ambient)
        for (direction, intensity) in [(SIMD3<Float>(-1,2,1), CGFloat(950)), (SIMD3<Float>(1,1,-2),CGFloat(500))] {
            let light = SCNNode();light.light = SCNLight();light.light!.type = .directional
            light.light!.intensity = intensity;light.simdPosition = center + direction * extent
            light.look(at: SCNVector3(center));model.addChildNode(light)
        }
        scene.background.contents = NSColor(calibratedRed: 0.925, green: 0.941, blue: 0.95, alpha: 1)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene;renderer.pointOfView = sceneCamera
        let id = url.deletingPathExtension().lastPathComponent
        let isVTOL = ["wingcopter-198", "wingtraone-gen-ii", "quantum-systems-trinity-pro"].contains(id)
        let cycle = isVTOL ? 12.0 : 2.0
        let views: [(String, SIMD3<Float>, SCNVector3, Double)] = [
            ("", SIMD3<Float>(1.1,0.85,1.4), SCNVector3(0,1,0),0),
            ("-top", SIMD3<Float>(0,3,0), SCNVector3(0,0,-1),0),
            ("-side", SIMD3<Float>(3,0.15,0), SCNVector3(0,1,0),0),
            ("-front", SIMD3<Float>(0,0.10,3), SCNVector3(0,1,0),0),
            ("-underside", SIMD3<Float>(0.85,-1.1,1.1), SCNVector3(0,1,0),0),
            ("-motion", SIMD3<Float>(0,3,0), SCNVector3(0,0,-1),0.037),
            ("-loop", SIMD3<Float>(0,3,0), SCNVector3(0,0,-1),cycle)
        ]
        var poses: [[String: Any]] = []
        for (suffix, direction, up, time) in views {
            frame(direction,up,aspect:1100.0/800.0)
            sceneCamera.simdPosition = center + simd_normalize(direction) * extent * 3
            sceneCamera.look(at: SCNVector3(center), up: up, localFront: SCNVector3(0,0,-1))
            renderer.sceneTime = time
            let image = renderer.snapshot(atTime: time, with: NSSize(width: 1100,height: 800), antialiasingMode: .multisampling4X)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
            if suffix != "-loop" {try data.write(to: output.appendingPathComponent(id + suffix + ".png"))}
            if suffix == "-top" || suffix == "-motion" || suffix == "-loop" {
                model.enumerateChildNodes { node, _ in
                    if !node.animationKeys.isEmpty {
                        let t=node.presentation.simdTransform
                        poses.append(["node": node.name ?? "", "time": time, "transform": [t.columns.0.x,t.columns.0.y,t.columns.0.z,t.columns.1.x,t.columns.1.y,t.columns.1.z,t.columns.2.x,t.columns.2.y,t.columns.2.z,t.columns.3.x,t.columns.3.y,t.columns.3.z]])
                    }
                }
            }
        }
        var transitionPoses: [[String: Any]] = []
        if isVTOL {
            camera.orthographicScale = Double(extent) * 0.59
            sceneCamera.simdPosition = center + simd_normalize(SIMD3<Float>(1.2,0.8,1.7)) * extent * 3
            sceneCamera.look(at: SCNVector3(center), up: SCNVector3(0,1,0), localFront: SCNVector3(0,0,-1))
            for time in [0.0,2.75,3.5,4.25,6.0,8.5,12.0] {
                renderer.sceneTime = time
                let img = renderer.snapshot(atTime: time, with: NSSize(width:1100,height:800), antialiasingMode:.multisampling4X)
                if [0.0,3.5,6.0].contains(time), let tiff=img.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let data=bitmap.representation(using:.png,properties:[:]) {
                    let suffix = time == 0 ? "hover" : time == 6 ? "cruise" : "transition"
                    try data.write(to: output.appendingPathComponent(id+"-"+suffix+".png"))
                }
                model.enumerateChildNodes { node, _ in
                    if node.geometry != nil || !node.animationKeys.isEmpty {
                        let t=node.presentation.simdWorldTransform
                        transitionPoses.append(["node":node.name ?? "", "time":time, "world_transform":[t.columns.0.x,t.columns.0.y,t.columns.0.z,t.columns.1.x,t.columns.1.y,t.columns.1.z,t.columns.2.x,t.columns.2.y,t.columns.2.z,t.columns.3.x,t.columns.3.y,t.columns.3.z]])
                    }
                }
            }
        }
        if id == "dji-neo" || isVTOL {
            let gifURL = output.appendingPathComponent(id + (isVTOL ? "-transition.gif" : "-animated.gif"))
            let frameCount = isVTOL ? 180 : 60
            let fps = isVTOL ? 15.0 : 30.0
            guard let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { fatalError("GIF destination") }
            CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            sceneCamera.simdPosition = center + simd_normalize(SIMD3<Float>(1.1,1.4,1.5)) * extent * 3
            sceneCamera.look(at: SCNVector3(center), up: SCNVector3(0,1,0), localFront: SCNVector3(0,0,-1))
            frame(SIMD3<Float>(1.1,1.4,1.5),SCNVector3(0,1,0),aspect:800.0/600.0)
            if isVTOL {camera.orthographicScale = Double(extent) * 0.56}
            for frame in 0..<frameCount {
                let time=Double(frame)/fps
                renderer.sceneTime=time
                let img=renderer.snapshot(atTime:time,with:NSSize(width:800,height:600),antialiasingMode:.multisampling4X)
                var rect=CGRect(x:0,y:0,width:800,height:600)
                guard let cg=img.cgImage(forProposedRect:&rect,context:nil,hints:nil) else {fatalError("GIF frame")}
                CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/fps]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(gif) else {fatalError("GIF finalize")}
        }
        let hash=SHA256.hash(data:try Data(contentsOf:url)).map {String(format:"%02x",$0)}.joined()
        reports.append(["id": id, "asset_sha256": hash, "scenekit_geometry_count": geometries, "bounds_size_m": [size.x,size.y,size.z], "animated_nodes": animated, "animation_poses": poses, "transition_poses": transitionPoses, "preview_written": true])
        print("Rendered \(id): \(geometries) meshes")
        fflush(stdout)
    }
}
let data = try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted,.sortedKeys])
try data.write(to: output.appendingPathComponent("scenekit-validation.json"))
