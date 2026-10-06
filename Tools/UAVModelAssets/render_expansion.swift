import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("Usage: render_expansion <collection-directory> [id]") }
let root = URL(fileURLWithPath: args[1])
let output = root.appendingPathComponent("previews")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as! [String: Any]
let profiles = manifest["models"] as! [[String: Any]]
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device unavailable") }
var reports: [[String: Any]] = []

for profile in profiles {
    let id = profile["id"] as! String
    if args.count > 2 && id != args[2] { continue }
    try autoreleasepool {
        let url = root.appendingPathComponent(profile["file"] as! String)
        let scene = try SCNScene(url: url, options: [.checkConsistency: true])
        let model = scene.rootNode.childNode(withName: "Aircraft", recursively: true) ?? scene.rootNode
        let box = model.boundingBox
        let low = SIMD3<Float>(Float(box.min.x),Float(box.min.y),Float(box.min.z))
        let high = SIMD3<Float>(Float(box.max.x),Float(box.max.y),Float(box.max.z))
        let size = high-low, center = (low+high)*0.5, extent = simd_length(size)
        guard extent > 0 else { fatalError("Empty model: \(id)") }
        let animation = profile["animation"] as! [String: Any]
        let cycle = animation["duration_seconds"] as! Double
        let isTailsitter = (profile["transition"] as? [String:Any])?["mechanism"] as? String == "tailsitter"
        let baseTime = isTailsitter ? 6.0 : 0.0
        var count = 0
        var animated: [[String:Any]] = []
        var animatedNodes: [SCNNode] = []
        model.enumerateChildNodes { node, _ in
            if node.geometry != nil { count += 1 }
            if !node.animationKeys.isEmpty {
                animatedNodes.append(node)
                var durations: [Double] = []
                for key in node.animationKeys {
                    if let player = node.animationPlayer(forKey: key) {
                        player.animation.usesSceneTimeBase = true
                        player.animation.repeatCount = .infinity
                        durations.append(player.animation.duration)
                    }
                }
                animated.append(["node":node.name ?? "", "keys":node.animationKeys,"durations":durations])
            }
        }
        guard count == profile["mesh_count"] as! Int else { fatalError("Mesh count: \(id)") }
        guard !animatedNodes.isEmpty else { fatalError("No imported animation: \(id)") }
        let cameraNode = SCNNode(); let camera = SCNCamera();cameraNode.camera = camera
        camera.usesOrthographicProjection = true
        camera.zNear = Double(extent)*0.001;camera.zFar = Double(extent)*15
        camera.wantsHDR = true;camera.wantsExposureAdaptation = false;camera.exposureOffset = 0
        camera.screenSpaceAmbientOcclusionIntensity = 0.65
        camera.screenSpaceAmbientOcclusionRadius = Double(extent)*0.025
        scene.rootNode.addChildNode(cameraNode)
        let ambient = SCNNode();ambient.light = SCNLight();ambient.light!.type = .ambient
        ambient.light!.intensity = 420;ambient.light!.color = NSColor(calibratedRed:0.92,green:0.96,blue:1,alpha:1)
        scene.rootNode.addChildNode(ambient)
        for (direction,intensity) in [(SIMD3<Float>(-1,2,1),CGFloat(1000)),(SIMD3<Float>(1,1,-2),CGFloat(550))] {
            let light = SCNNode();light.light = SCNLight();light.light!.type = .directional
            light.light!.intensity = intensity;light.simdPosition = center+direction*extent
            light.look(at:SCNVector3(center));scene.rootNode.addChildNode(light)
        }
        scene.background.contents = NSColor(calibratedRed:0.94,green:0.952,blue:0.96,alpha:1)
        let renderer = SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=cameraNode
        func frame(_ direction: SIMD3<Float>,_ up: SIMD3<Float>,_ aspect:Float,wide:Bool=false) {
            let back=simd_normalize(direction),right=simd_normalize(simd_cross(up,back)),vertical=simd_cross(back,right)
            let width=simd_dot(abs(right),size),height=simd_dot(abs(vertical),size)
            camera.orthographicScale=wide ? Double(extent)*0.63 : Double(max(height/2,width/(2*aspect)))*1.22
            cameraNode.simdPosition=center+back*extent*3
            cameraNode.look(at:SCNVector3(center),up:SCNVector3(up),localFront:SCNVector3(0,0,-1))
        }
        func snapshot(_ time:Double,_ width:Int,_ height:Int)->NSImage {
            renderer.sceneTime=time
            return renderer.snapshot(atTime:time,with:NSSize(width:width,height:height),antialiasingMode:.multisampling4X)
        }
        func writePNG(_ image:NSImage,_ suffix:String) throws {
            guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),
                  let data=bitmap.representation(using:.png,properties:[:]) else { fatalError("PNG encoding") }
            try data.write(to:output.appendingPathComponent(id+suffix+".png"))
        }
        let views:[(String,SIMD3<Float>,SIMD3<Float>)]=[
            ("",SIMD3<Float>(1.1,0.90,1.5),SIMD3<Float>(0,1,0)),
            ("-top",SIMD3<Float>(0,3,0),SIMD3<Float>(0,0,-1)),
            ("-side",SIMD3<Float>(3,0.12,0),SIMD3<Float>(0,1,0)),
            ("-front",SIMD3<Float>(0,0.10,3),SIMD3<Float>(0,1,0)),
            ("-underside",SIMD3<Float>(0.8,-1.1,1.1),SIMD3<Float>(0,1,0))]
        for (suffix,direction,up) in views {
            frame(direction,up,1100.0/800.0)
            try writePNG(snapshot(baseTime,1100,800),suffix)
        }
        frame(SIMD3<Float>(1.1,0.90,1.5),SIMD3<Float>(0,1,0),1100.0/800.0,wide:isTailsitter)
        var poses:[[String:Any]]=[]
        let times = cycle > 2 ? [0.0,0.037,1.0,3.5,6.0,12.0] : [0.0,0.037,0.5,1.0,2.0]
        for time in times {
            _ = snapshot(time,320,240)
            for node in animatedNodes {
                let t=node.presentation.simdTransform
                poses.append(["node":node.name ?? "","time":time,
                    "transform":[t.columns.0.x,t.columns.0.y,t.columns.0.z,t.columns.1.x,t.columns.1.y,t.columns.1.z,
                                 t.columns.2.x,t.columns.2.y,t.columns.2.z,t.columns.3.x,t.columns.3.y,t.columns.3.z]])
            }
            if isTailsitter && [0.0,3.5,6.0].contains(time) {
                try writePNG(snapshot(time,1100,800),time==0 ? "-hover" : time==6 ? "-cruise" : "-transition")
            }
        }
        // Every GIF is a native rendering of the animation in that exact USDZ.
        // Camera remains stationary so movement cannot be mistaken for a turntable.
        let gifURL=output.appendingPathComponent(id+"-animated.gif")
        let fps=cycle>2 ? 8.0 : 16.0,frames=Int(cycle*fps)
        guard let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,frames,nil) else {fatalError("GIF destination")}
        CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        frame(SIMD3<Float>(1.1,1.0,1.5),SIMD3<Float>(0,1,0),800.0/600.0,wide:isTailsitter)
        for index in 0..<frames {
            let im=snapshot(Double(index)/fps,800,600)
            var rect=CGRect(x:0,y:0,width:800,height:600)
            guard let cg=im.cgImage(forProposedRect:&rect,context:nil,hints:nil) else {fatalError("GIF frame")}
            CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/fps]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(gif) else { fatalError("GIF finalize") }
        let hash=SHA256.hash(data:try Data(contentsOf:url)).map{String(format:"%02x",$0)}.joined()
        reports.append(["id":id,"asset_sha256":hash,"scenekit_geometry_count":count,
                        "bounds_size_m":[size.x,size.y,size.z],"animated_nodes":animated,"animation_poses":poses,
                        "cycle_seconds":cycle,"views":5,"animated_preview":id+"-animated.gif"])
        print("Rendered \(id): \(count) meshes, \(animatedNodes.count) animated nodes, \(cycle)s cycle")
        fflush(stdout)
    }
}
try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys])
    .write(to:output.appendingPathComponent("scenekit-validation.json"))
