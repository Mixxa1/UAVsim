import AppKit
import SceneKit
import Metal
import ImageIO
import UniformTypeIdentifiers

@main
struct HandLaunchArmFitProbe {
static func main() throws {
guard CommandLine.arguments.count==4 else { fatalError("Usage: fit_hands <models> <arm-folder> <output-folder>") }
let models=URL(fileURLWithPath:CommandLine.arguments[1]),hands=URL(fileURLWithPath:CommandLine.arguments[2]),out=URL(fileURLWithPath:CommandLine.arguments[3])
try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:models.appendingPathComponent("manifest.json"))) as! [String:Any]
let entries=manifest["models"] as! [[String:Any]]
let ids=["sensefly-ebee-tac","epfl-delta-wing-uav","ageagle-ebee-x","delair-ux11","aerovironment-puma-le","aerovironment-raven-b","aerovironment-puma-3-ae"]
let loader=AdaptiveHandLaunchAssetLoader(directory:hands)
guard let cloneA=loader.makeArm(rightHand:true),let cloneB=loader.makeArm(rightHand:true) else { fatalError("Rig unavailable") }
for (a,b) in zip(cloneA.bones,cloneB.bones) { precondition(a !== b,"Cloned hands share mutable bones") }
let before=cloneB.bones[10].simdOrientation
cloneA.bones[10].simdOrientation=simd_quatf(angle:0.7,axis:SIMD3(1,0,0))
precondition(abs(simd_dot(before.vector,cloneB.bones[10].simdOrientation.vector))>0.99999,"Cloned finger pose leaked")
guard let device=MTLCreateSystemDefaultDevice() else { fatalError("Metal unavailable") }
var reports:[[String:Any]]=[]
for id in ids {
    try autoreleasepool {
        let entry=entries.first { $0["id"] as? String==id }!
        let file=(entry["file"] as! NSString).lastPathComponent
        let scene=try SCNScene(url:models.appendingPathComponent(file),options:[.checkConsistency:true])
        let aircraft=SCNNode(),geometry=SCNNode()
        for child in scene.rootNode.childNodes { geometry.addChildNode(child) }
        geometry.simdOrientation=simd_quatf(angle:.pi,axis:SIMD3(0,1,0))
        aircraft.addChildNode(geometry);scene.rootNode.addChildNode(aircraft)
        var bodies:[SCNNode]=[],wings:[SCNNode]=[]
        geometry.enumerateHierarchy { node,_ in
            node.removeAllAnimations()
            guard node.geometry != nil else { return }
            let name=(node.name ?? "").lowercased()
            if ["fuselage","body","centralpod","centerpod","hull"].contains(where:name.contains) { bodies.append(node) }
            if name.contains("wing") && !name.contains("tail") && !name.contains("winglet") { wings.append(node) }
        }
        let plan=HandLaunchGripPlan.measure(aircraftID:id,root:aircraft,bodyNodes:bodies,wingNodes:wings)
        aircraft.simdPosition=plan.holdOffset
        let cameraNode=SCNNode();cameraNode.camera=SCNCamera();cameraNode.camera!.fieldOfView=78
        cameraNode.camera!.zNear=0.012;cameraNode.camera!.zFar=100
        scene.rootNode.addChildNode(cameraNode)
        let ambient=SCNNode();ambient.light=SCNLight();ambient.light!.type = .ambient;ambient.light!.intensity=400
        scene.rootNode.addChildNode(ambient)
        let sun=SCNNode();sun.light=SCNLight();sun.light!.type = .directional;sun.light!.intensity=1000
        sun.position=SCNVector3(-3,6,1);sun.look(at:SCNVector3(0,0,-1));scene.rootNode.addChildNode(sun)
        scene.background.contents=NSColor(calibratedRed:0.64,green:0.76,blue:0.84,alpha:1)
        var arms:[AdaptiveHandLaunchArm]=[]
        for anchor in plan.anchors {
            guard let arm=loader.makeArm(rightHand:anchor.rightHand) else { fatalError("Arm load failed") }
            cameraNode.addChildNode(arm.node)
            arm.place(anchor:anchor,aircraft:aircraft,camera:cameraNode,release:0)
            arms.append(arm)
        }
        let renderer=SCNRenderer(device:device,options:nil);renderer.scene=scene;renderer.pointOfView=cameraNode
        func snapshot(_ suffix:String) throws {
            let im=renderer.snapshot(atTime:0,with:NSSize(width:1200,height:850),antialiasingMode:.multisampling4X)
            let rep=NSBitmapImageRep(data:im.tiffRepresentation!)!
            try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(id+suffix+".png"))
        }
        try snapshot("-pov")
        let observer=SCNNode();observer.camera=SCNCamera();observer.camera!.usesOrthographicProjection=true
        observer.camera!.orthographicScale=0.32;observer.camera!.zNear=0.001;observer.camera!.zFar=20
        let target=aircraft.simdConvertPosition(plan.anchors[0].position,to:nil)
        observer.simdPosition=target+SIMD3<Float>(0.8,-0.35,0.65)
        observer.look(at:SCNVector3(target));scene.rootNode.addChildNode(observer);renderer.pointOfView=observer
        try snapshot("-grip")
        func flat(_ m:simd_float4x4)->[[Float]] { (0..<4).map { c in (0..<4).map { r in m[c][r] } } }
        let pose:[[String:Any]]=zip(arms,plan.anchors).map { arm,anchor in
            let metrics=arm.contactMetrics(anchor:anchor,aircraft:aircraft,camera:cameraNode)
            precondition(metrics.penetration<=0.0022,"Grip penetrates the airframe")
            precondition(metrics.shoulderError<=0.002,"Arm cannot reach the operator's shoulder")
            precondition(metrics.wristAngle<=65,"Wrist pose exceeds the preview limit")
            return ["transform":flat(aircraft.simdConvertTransform(matrix_identity_float4x4,from:arm.node)),
             "bone_local_transforms":arm.bones.map { flat($0.simdTransform) },
             "bone_local_positions":arm.bones.map { [$0.simdPosition.x,$0.simdPosition.y,$0.simdPosition.z] },
             "bone_rotations":arm.bones.map { [$0.simdOrientation.real,$0.simdOrientation.imag.x,$0.simdOrientation.imag.y,$0.simdOrientation.imag.z] },
             "bone_scales":arm.bones.map { [$0.simdScale.x,$0.simdScale.y,$0.simdScale.z] },
             "closed_angles":arm.closedAngles,"maximum_sample_penetration_m":metrics.penetration,
             "shoulder_error_m":metrics.shoulderError,"wrist_angle_degrees":metrics.wristAngle]
        }
        let report:[String:Any]=["id":id,"style":plan.style.rawValue,"hand_count":arms.count,
            "hold_offset_m":[plan.holdOffset.x,plan.holdOffset.y,plan.holdOffset.z],"poses":pose,
            "anchors":plan.anchors.map { ["position_m":[$0.position.x,$0.position.y,$0.position.z],"right":$0.rightHand] as [String:Any] }]
        reports.append(report)
        renderer.pointOfView=cameraNode
        for release:Float in [0.25,0.5,1] {
            for (arm,anchor) in zip(arms,plan.anchors) { arm.place(anchor:anchor,aircraft:aircraft,camera:cameraNode,release:release) }
            try snapshot("-release-\(release)")
        }
        let releasedPositions=arms.map { $0.node.simdPosition }
        aircraft.simdPosition.z -= 3
        for (i,pair) in zip(arms,plan.anchors).enumerated() {
            pair.0.place(anchor:pair.1,aircraft:aircraft,camera:cameraNode,release:1)
            precondition(simd_distance(pair.0.node.simdPosition,releasedPositions[i])<0.00001,"Released arm follows the aircraft")
        }
        print("Fitted \(id): \(arms.count) hands, \(plan.style.rawValue)")
        fflush(stdout)
    }
}
try JSONSerialization.data(withJSONObject:reports,options:[.prettyPrinted,.sortedKeys]).write(to:out.deletingLastPathComponent().appendingPathComponent("grips.json"))
}
}
