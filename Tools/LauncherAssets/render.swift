import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
let args=CommandLine.arguments
let root=URL(fileURLWithPath:args[1]);let out=root.appendingPathComponent("previews")
let device=MTLCreateSystemDefaultDevice()!
let files=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("models"),includingPropertiesForKeys:nil).filter{$0.pathExtension=="usdz"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
var reports:[[String:Any]]=[]
for file in files {
 try autoreleasepool {
  let scene=try SCNScene(url:file,options:[.checkConsistency:true]);let model=scene.rootNode
  let b=model.boundingBox;let lo=SIMD3<Float>(Float(b.min.x),Float(b.min.y),Float(b.min.z));let hi=SIMD3<Float>(Float(b.max.x),Float(b.max.y),Float(b.max.z));let size=hi-lo;let center=(lo+hi)*0.5;let extent=simd_length(size)
  let id=file.deletingPathExtension().lastPathComponent
  var meshCount=0
  model.enumerateChildNodes{n,_ in
   if n.geometry != nil {meshCount += 1}
   for key in n.animationKeys {if let p=n.animationPlayer(forKey:key){p.animation.usesSceneTimeBase=true;p.animation.repeatCount = .infinity}}
  }
  let cameraNode=SCNNode();let camera=SCNCamera();cameraNode.camera=camera;camera.usesOrthographicProjection=true;camera.zNear=0.01;camera.zFar=Double(extent*20);camera.wantsHDR=true;camera.wantsExposureAdaptation=false
  camera.screenSpaceAmbientOcclusionIntensity=0.8;camera.screenSpaceAmbientOcclusionRadius=Double(extent)*0.02
  model.addChildNode(cameraNode)
  let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=380;model.addChildNode(ambient)
  for (dir,intensity) in [(SIMD3<Float>(-1,2,1),CGFloat(1000)),(SIMD3<Float>(2,1,-1),CGFloat(450))] {
   let n=SCNNode();n.light=SCNLight();n.light!.type = .directional;n.light!.intensity=intensity;n.simdPosition=center+dir*extent;n.look(at:SCNVector3(center));model.addChildNode(n)
  }
  scene.background.contents=NSColor(calibratedRed:0.925,green:0.945,blue:0.956,alpha:1)
  let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=cameraNode
  func frame(_ dir:SIMD3<Float>,_ up:SIMD3<Float>=SIMD3<Float>(0,1,0),aspect:Float=1.5) {
   let back=simd_normalize(dir);let right=simd_normalize(simd_cross(up,back));let vertical=simd_cross(back,right)
   camera.orthographicScale=Double(max(simd_dot(abs(vertical),size)/2,simd_dot(abs(right),size)/(2*aspect)))*1.20
   cameraNode.simdPosition=center+back*extent*3;cameraNode.look(at:SCNVector3(center),up:SCNVector3(up),localFront:SCNVector3(0,0,-1))
  }
  func snapshot(_ time:Double)->NSImage {renderer.sceneTime=time;return renderer.snapshot(atTime:time,with:NSSize(width:1200,height:800),antialiasingMode:.multisampling4X)}
  for (suffix,dir,up) in [("",SIMD3<Float>(2,1.2,1.5),SIMD3<Float>(0,1,0)),("-side",SIMD3<Float>(3,0.1,0),SIMD3<Float>(0,1,0)),("-front",SIMD3<Float>(0,0.1,3),SIMD3<Float>(0,1,0)),("-top",SIMD3<Float>(0,3,0),SIMD3<Float>(0,0,-1)),("-rear",SIMD3<Float>(-2,1,-2),SIMD3<Float>(0,1,0))] {
   frame(dir,up);let img=snapshot(0);let bitmap=NSBitmapImageRep(data:img.tiffRepresentation!)!;try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(id+suffix+".png"))
  }
  frame(SIMD3<Float>(2,1.2,1.5));let carriage=model.childNode(withName:"Carriage",recursively:true)!
  var poses:[[String:Any]]=[]
  for time in [0.0,1.75,2.75,4.5,6.0] {
   let img=snapshot(time);let t=carriage.presentation.simdWorldTransform
   poses.append(["time":time,"translation":[t.columns.3.x,t.columns.3.y,t.columns.3.z],"basis":[t.columns.0.x,t.columns.0.y,t.columns.0.z,t.columns.1.x,t.columns.1.y,t.columns.1.z,t.columns.2.x,t.columns.2.y,t.columns.2.z]])
   if time==2.75 {let bitmap=NSBitmapImageRep(data:img.tiffRepresentation!)!;try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(id+"-end.png"))}
  }
  let gifURL=out.appendingPathComponent(id+"-animated.gif");let gif=CGImageDestinationCreateWithURL(gifURL as CFURL,UTType.gif.identifier as CFString,90,nil)!
  CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
  for i in 0..<90 {
   let time=Double(i)/15;renderer.sceneTime=time
   let img=renderer.snapshot(atTime:time,with:NSSize(width:900,height:600),antialiasingMode:.multisampling4X);var rect=CGRect(x:0,y:0,width:900,height:600)
   let cg=img.cgImage(forProposedRect:&rect,context:nil,hints:nil)!
   CGImageDestinationAddImage(gif,cg,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:1.0/15.0]] as CFDictionary)
  }
  guard CGImageDestinationFinalize(gif) else {fatalError("GIF encoding")}
  let hash=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
  reports.append(["id":id,"sha256":hash,"mesh_count":meshCount,"carriage_poses":poses,"animated_node":"/Launcher/Geometry/Carriage"])
  print("Rendered \(id): \(meshCount) meshes; six views and animated carriage");fflush(stdout)
 }
}
try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("native-validation.json"))
