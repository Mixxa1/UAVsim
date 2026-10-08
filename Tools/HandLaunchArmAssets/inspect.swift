import AppKit
import SceneKit
import Metal

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let side = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "left"
let scene = try SCNScene(url: root.appendingPathComponent("hand-launch-arm-\(side).usdz"), options: [.checkConsistency:true])
var skinNode:SCNNode?
scene.rootNode.enumerateHierarchy { node,_ in
    if let skinner=node.skinner {
        skinNode=node
        print("SKINNER",node.name ?? "",skinner.bones.count,skinner.bones.map { $0.name ?? "" },
              "INFLUENCES",skinner.boneWeights.componentsPerVector,"VERTICES",skinner.boneWeights.vectorCount)
    }
    if !node.animationKeys.isEmpty {
        print("ANIMATION",node.name ?? "",node.animationKeys)
        for key in node.animationKeys {
            node.animationPlayer(forKey:key)?.animation.usesSceneTimeBase=true
            node.animationPlayer(forKey:key)?.animation.repeatCount = .infinity
        }
    }
}
guard let node=skinNode,node.skinner!.bones.count==24,let device=MTLCreateSystemDefaultDevice() else { fatalError("Native skeleton failed") }
let cameraNode=SCNNode();cameraNode.camera=SCNCamera()
cameraNode.camera!.usesOrthographicProjection=true;cameraNode.camera!.orthographicScale=0.18
cameraNode.camera!.zNear=0.001;cameraNode.camera!.zFar=10
let target=SIMD3<Float>(0,0,-0.07)
cameraNode.simdPosition=target+SIMD3<Float>(0.45,0.8,-0.7)
cameraNode.look(at:SCNVector3(target));scene.rootNode.addChildNode(cameraNode)
let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=300
scene.rootNode.addChildNode(ambient)
let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=700
sun.position=SCNVector3(-1,2,-1);sun.look(at:SCNVector3(target));scene.rootNode.addChildNode(sun)
scene.background.contents=NSColor(calibratedWhite:0.85,alpha:1)
let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=cameraNode
let preview = root.appendingPathComponent("previews")
try FileManager.default.createDirectory(at:preview,withIntermediateDirectories:true)
for time in [0.0,1.0,2.0,3.0,4.0] {
    renderer.sceneTime=time
    let image=renderer.snapshot(atTime:time,with:NSSize(width:1000,height:800),antialiasingMode:.multisampling4X)
    let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
    try rep.representation(using:.png,properties:[:])!.write(to:preview.appendingPathComponent("\(side)-skeleton-\(time).png"))
}
