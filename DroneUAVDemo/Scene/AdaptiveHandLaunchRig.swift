import AppKit
import SceneKit
import simd

enum HandLaunchGripStyle: String {
    case twoWingEdges, singleWing, shoulderFuselage, overheadFuselage
    static func forAircraft(_ id: String) -> HandLaunchGripStyle {
        if id.contains("ebee") { return .twoWingEdges }
        if id == "delair-ux11" || id == "epfl-delta-wing-uav" { return .singleWing }
        if id.contains("puma") { return .overheadFuselage }
        return .shoulderFuselage
    }
}

struct HandLaunchGripAnchor {
    struct Section { let station:Float;let polygon:[SIMD2<Float>] }
    var position: SIMD3<Float>
    let yaw: Float
    let roll:Float
    let rightHand: Bool
    let polygon: [SIMD2<Float>]
    let wingSection: Bool
    let station: Float
    let sections:[Section]

    func signedDistance(_ point: SIMD3<Float>) -> Float {
        if wingSection && abs(point.x-station) > 0.11 { return 1 }
        if !wingSection && abs(point.z-station) > 0.15 { return 1 }
        let q = wingSection ? SIMD2<Float>(point.z,point.y) : SIMD2<Float>(point.x,point.y)
        func distance(to polygon:[SIMD2<Float>])->Float {
            guard polygon.count>2 else { return 1 }
            var inside=true,distance=Float.greatestFiniteMagnitude
            for i in polygon.indices {
                let a=polygon[i],b=polygon[(i+1)%polygon.count],edge=b-a
                if edge.x*(q.y-a.y)-edge.y*(q.x-a.x) < 0 { inside=false }
                let t=max(0,min(1,simd_dot(q-a,edge)/max(1e-12,simd_length_squared(edge))))
                distance=min(distance,simd_distance(q,a+edge*t))
            }
            return inside ? -distance : distance
        }
        let at=wingSection ? point.x : point.z
        guard sections.count>1 else { return distance(to:polygon) }
        let upper=sections.firstIndex { $0.station>=at } ?? sections.count-1
        let lower=max(0,upper-1),a=sections[lower],b=sections[upper]
        let blend=max(0,min(1,(at-a.station)/max(0.000001,b.station-a.station)))
        return distance(to:a.polygon)*(1-blend)+distance(to:b.polygon)*blend
    }
}

struct HandLaunchGripPlan {
    let style: HandLaunchGripStyle
    var anchors: [HandLaunchGripAnchor]
    let holdOffset: SIMD3<Float>

    static func measure(aircraftID: String, root: SCNNode, bodyNodes: [SCNNode], wingNodes: [SCNNode]) -> HandLaunchGripPlan {
        let style=HandLaunchGripStyle.forAircraft(aircraftID)
        struct Mesh { let points:[SIMD3<Float>];let triangles:[SIMD3<Int>] }
        func capture(_ roots:[SCNNode])->[Mesh] {
            var found=Set<ObjectIdentifier>(),result:[Mesh]=[]
            for parent in roots {
                parent.enumerateHierarchy { node,_ in
                    guard found.insert(ObjectIdentifier(node)).inserted,
                          let source=node.geometry?.sources(for:.vertex).first,source.usesFloatComponents else { return }
                    var points:[SIMD3<Float>]=[]
                    source.data.withUnsafeBytes { bytes in
                        for i in 0..<source.vectorCount {
                            let offset=source.dataOffset+i*source.dataStride
                            func value(_ k:Int)->Float {
                                source.bytesPerComponent==4 ? bytes.loadUnaligned(fromByteOffset:offset+k*4,as:Float.self)
                                    : Float(bytes.loadUnaligned(fromByteOffset:offset+k*8,as:Double.self))
                            }
                            points.append(root.simdConvertPosition(SIMD3(value(0),value(1),value(2)),from:node))
                        }
                    }
                    var triangles:[SIMD3<Int>]=[]
                    for element in node.geometry!.elements {
                        guard element.primitiveType == .triangles || element.primitiveType == .triangleStrip else { continue }
                        let count=element.primitiveType == .triangles ? element.primitiveCount*3 : element.primitiveCount+2
                        var indices:[Int]=[]
                        if element.data.isEmpty { indices=Array(0..<min(count,points.count)) }
                        else { element.data.withUnsafeBytes { bytes in
                            for i in 0..<min(count,bytes.count/max(1,element.bytesPerIndex)) {
                                let offset=i*element.bytesPerIndex
                                switch element.bytesPerIndex {
                                case 1: indices.append(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt8.self)))
                                case 2: indices.append(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt16.self)))
                                case 4: indices.append(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))
                                default: indices.append(Int(bytes.loadUnaligned(fromByteOffset:offset,as:UInt64.self)))
                                }
                            }
                        } }
                        if element.primitiveType == .triangles {
                            for i in stride(from:0,to:max(0,indices.count-2),by:3) { triangles.append(SIMD3(indices[i],indices[i+1],indices[i+2])) }
                        } else if indices.count>2 {
                            for i in 0..<(indices.count-2) { triangles.append(SIMD3(indices[i],indices[i+1],indices[i+2])) }
                        }
                    }
                    result.append(Mesh(points:points,triangles:triangles))
                }
            }
            return result
        }
        func section(_ meshes:[Mesh],axis:Int,station:Float)->[SIMD3<Float>] {
            var result:[SIMD3<Float>]=[]
            for mesh in meshes { for face in mesh.triangles {
                let ids=[face.x,face.y,face.z]
                guard ids.allSatisfy({ $0>=0 && $0<mesh.points.count }) else { continue }
                for i in 0..<3 {
                    let a=mesh.points[ids[i]],b=mesh.points[ids[(i+1)%3]]
                    let da=a[axis]-station,db=b[axis]-station
                    if abs(da)<0.000001 { result.append(a) }
                    if da*db<0 { result.append(a+(b-a)*(da/(da-db))) }
                }
            } }
            return result
        }
        func hull(_ source:[SIMD2<Float>])->[SIMD2<Float>] {
            let p=source.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            guard p.count>2 else { return p }
            func turn(_ a:SIMD2<Float>,_ b:SIMD2<Float>,_ c:SIMD2<Float>)->Float {
                (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x)
            }
            var lo:[SIMD2<Float>]=[],hi:[SIMD2<Float>]=[]
            for q in p { while lo.count>1 && turn(lo[lo.count-2],lo.last!,q)<=0 { lo.removeLast() };lo.append(q) }
            for q in p.reversed() { while hi.count>1 && turn(hi[hi.count-2],hi.last!,q)<=0 { hi.removeLast() };hi.append(q) }
            lo.removeLast();hi.removeLast();return lo+hi
        }
        var namedBodies:[SCNNode]=[],namedWings:[SCNNode]=[]
        root.enumerateHierarchy { node,_ in
            guard node.geometry != nil else { return }
            let name=(node.name ?? "").lowercased()
            if ["fuselage","body","centralpod","centerpod","hull"].contains(where:name.contains) { namedBodies.append(node) }
            if name.contains("wing") && !name.contains("tail") && !name.contains("winglet") { namedWings.append(node) }
        }
        var bodyMeshes=capture(namedBodies.isEmpty ? bodyNodes : namedBodies)
        var body=bodyMeshes.flatMap(\.points)
        if body.isEmpty {
            bodyMeshes=capture([root])
            let all=bodyMeshes.flatMap(\.points);let span=all.map { abs($0.x) }.max() ?? 0.5
            body=all.filter { abs($0.x)<span*0.16 }
        }
        let wingMeshes=capture(namedWings.isEmpty ? wingNodes : namedWings)
        let wings=wingMeshes.flatMap(\.points)
        func sections(_ meshes:[Mesh],axis:Int,station:Float,width:Float)->[HandLaunchGripAnchor.Section] {
            stride(from:-width,through:width,by:width/5).compactMap { offset in
                let at=station+offset
                let polygon=hull(section(meshes,axis:axis,station:at).map { axis == 0 ? SIMD2($0.z,$0.y) : SIMD2($0.x,$0.y) })
                return polygon.count>2 ? HandLaunchGripAnchor.Section(station:at,polygon:polygon) : nil
            }
        }
        var anchors:[HandLaunchGripAnchor]=[]
        if (style == .twoWingEdges || style == .singleWing),!wings.isEmpty {
            let span=(wings.map(\.x).max() ?? 0.5)-(wings.map(\.x).min() ?? -0.5)
            for side:Float in style == .singleWing ? [1] : [-1,1] {
                let x=side*span*0.24
                var cut=section(wingMeshes,axis:0,station:x)
                if cut.count<3 { cut=wings.sorted { abs($0.x-x)<abs($1.x-x) }.prefix(100).map { $0 } }
                let polygon=hull(cut.map { SIMD2($0.z,$0.y) })
                let leading=cut.map(\.z).min() ?? 0
                let bottom=cut.map(\.y).min() ?? 0
                anchors.append(HandLaunchGripAnchor(position:SIMD3(x,bottom-0.018,leading+0.035),yaw:0,roll:0,
                    rightHand:side>0,polygon:polygon,wingSection:true,station:x,sections:sections(wingMeshes,axis:0,station:x,width:0.11)))
            }
        } else {
            let zLow=body.map(\.z).min() ?? -0.1,zHigh=body.map(\.z).max() ?? 0.1
            let z=max(zLow+0.03,min(zHigh-0.03,(zLow+zHigh)*0.5))
            for side:Float in style == .overheadFuselage ? [-1,1] : [1] {
                let handZ=z+(style == .overheadFuselage ? side*0.055 : 0)
                var cut=section(bodyMeshes,axis:2,station:handZ)
                if cut.count<3 { cut=body.sorted { abs($0.z-handZ)<abs($1.z-handZ) }.prefix(100).map { $0 } }
                let polygon=hull(cut.map { SIMD2($0.x,$0.y) })
                let low=cut.map(\.x).min() ?? -0.05,high=cut.map(\.x).max() ?? 0.05
                let bottom=cut.map(\.y).min() ?? -0.04
                let x=(low+high)*0.5+side*(high-low)*(style == .overheadFuselage ? 0.44 : 0.20)
                var surface=SIMD2<Float>(x,bottom),normal=SIMD2<Float>(0,1)
                var surfaceY=Float.greatestFiniteMagnitude
                for i in polygon.indices {
                    let a=polygon[i],b=polygon[(i+1)%polygon.count],edge=b-a
                    guard abs(edge.x)>0.000001 else { continue }
                    let along=(x-a.x)/edge.x
                    guard along>=0,along<=1 else { continue }
                    let candidate=a+edge*along
                    if candidate.y<surfaceY {
                        surfaceY=candidate.y;surface=candidate
                        normal=simd_normalize(SIMD2(-edge.y,edge.x))
                    }
                }
                let palm=surface-normal*0.018
                let roll=style == .overheadFuselage ? atan2(-normal.x,normal.y) : 0
                let yaw=style == .overheadFuselage ? Float(0) : side * .pi/4
                anchors.append(HandLaunchGripAnchor(position:SIMD3(palm.x,palm.y,handZ),yaw:yaw,roll:roll,
                    rightHand:side>0,polygon:polygon,wingSection:false,station:handZ,sections:sections(bodyMeshes,axis:2,station:handZ,width:0.15)))
            }
        }
        let palmCenter:SIMD3<Float>
        switch style {
        case .twoWingEdges: palmCenter=SIMD3(0,-0.16,-0.53)
        case .singleWing: palmCenter=SIMD3(0.25,-0.12,-0.52)
        case .shoulderFuselage: palmCenter=SIMD3(0.20,0.04,-0.32)
        case .overheadFuselage: palmCenter=SIMD3(0,0.18,-0.34)
        }
        // Hold the measured grip within an adult arm's reach, independent of the UAV origin.
        let meanAnchor=anchors.reduce(SIMD3<Float>.zero) { $0+$1.position }/Float(max(1,anchors.count))
        let hold=palmCenter-meanAnchor
        return HandLaunchGripPlan(style:style,anchors:anchors,holdOffset:hold)
    }
}

struct HandLaunchArmRigDefinition: Decodable {
    struct Joint:Decodable { let name:String;let parent:Int;let position:[Float];let localPosition:[Float] }
    struct Digit:Decodable { let name:String;let joints:[Int];let axes:[[Float]] }
    struct Sample:Decodable { let point:[Float];let indices:[Int];let weights:[Float] }
    let joints:[Joint]
    let digits:[Digit]
    let collisionSamples:[Sample]
}

final class AdaptiveHandLaunchArm {
    let node:SCNNode
    let definition:HandLaunchArmRigDefinition
    let bones:[SCNNode]
    var closedAngles:[Float]
    private var fitted=false
    private var restTransforms:[simd_float4x4]
    private var fitDrop:Float=0
    private var holdingTransform:simd_float4x4?
    private let rightHand:Bool
    private var thumbOpposition:Float=0

    init?(node:SCNNode,definition:HandLaunchArmRigDefinition,rightHand:Bool) {
        var skinner:SCNSkinner?
        node.enumerateHierarchy { n,_ in n.removeAllAnimations();n.removeAllActions();if let s=n.skinner { skinner=s } }
        guard let skin=skinner else { return nil }
        var found:[SCNNode]=[]
        for joint in definition.joints {
            guard let bone=skin.bones.first(where: { $0.name==joint.name }) else { return nil };found.append(bone)
        }
        self.node=node;self.definition=definition;self.bones=found;self.restTransforms=found.map(\.simdTransform)
        self.rightHand=rightHand
        self.closedAngles=Array(repeating:0,count:found.count)
        node.castsShadow=false
        node.enumerateHierarchy { n,_ in n.castsShadow=false }
    }

    private func sampledPoints(in aircraft:SCNNode,joints:[Int]?=nil)->[SIMD3<Float>] {
        let affected=joints.map(Set.init)
        return definition.collisionSamples.compactMap { sample in
            if let affected {
                let strength=zip(sample.indices,sample.weights).reduce(Float(0)) { $0+(affected.contains($1.0) ? $1.1 : 0) }
                guard strength>0.12 else { return nil }
            }
            var result=SIMD3<Float>.zero
            let p=SIMD3<Float>(sample.point[0],sample.point[1],sample.point[2])
            for k in sample.indices.indices where sample.weights[k]>0 {
                let index=sample.indices[k],bind=definition.joints[index].position
                result += aircraft.simdConvertPosition(p-SIMD3(bind[0],bind[1],bind[2]),from:bones[index])*sample.weights[k]
            }
            return result
        }
    }

    func place(anchor:HandLaunchGripAnchor,aircraft:SCNNode,camera:SCNNode,release:Float) {
        let yaw=simd_quatf(angle:anchor.yaw,axis:SIMD3<Float>(0,1,0))
        let roll=simd_quatf(angle:anchor.roll,axis:SIMD3<Float>(0,0,1))
        var local=simd_float4x4(roll*yaw)
        local.columns.3=SIMD4(anchor.position-SIMD3<Float>(0,fitDrop,0),1)
        let current=camera.simdConvertTransform(local,from:aircraft)
        if release>0,let holdingTransform { node.simdTransform=holdingTransform }
        else { node.simdTransform=current;holdingTransform=current }
        for i in bones.indices { bones[i].simdTransform=restTransforms[i] }
        if !fitted {
            thumbOpposition=anchor.wingSection ? 0.35 : 0.55
            applyFingers(release:0)
            poseArm(camera:camera,rightHand:rightHand,wingGrip:anchor.wingSection)
            for _ in 0..<55 {
                let worst=sampledPoints(in:aircraft).map(anchor.signedDistance).min() ?? 1
                if worst >= -0.0015 { break }
                local.columns.3.y -= 0.0015
                fitDrop += 0.0015
                node.simdTransform=camera.simdConvertTransform(local,from:aircraft)
                poseArm(camera:camera,rightHand:rightHand,wingGrip:anchor.wingSection)
            }
            for digit in definition.digits {
                let limits:[Float]=digit.name == "thumb" ? [0.80,1.00,0.80] : [1.25,1.35,0.78]
                var accepted:Float=0
                // Close a digit as a natural three-joint curve. Skin around a proximal
                // joint should not lock its distal joints before they begin to bend.
                for amount in stride(from:Float(0),through:1,by:0.025) {
                    for (part,index) in digit.joints.enumerated() { closedAngles[index]=amount*limits[part] }
                    applyFingers(release:0)
                    if (sampledPoints(in:aircraft,joints:digit.joints).map(anchor.signedDistance).min() ?? 1) < -0.002 { break }
                    accepted=amount
                }
                for (part,index) in digit.joints.enumerated() { closedAngles[index]=accepted*limits[part] }
                applyFingers(release:0)
            }
            fitted=true
            holdingTransform=node.simdTransform
        }
        applyFingers(release:release)
        node.simdPosition.y -= release*0.16
        node.simdPosition.z -= release*0.08
        poseArm(camera:camera,rightHand:rightHand,wingGrip:anchor.wingSection)
    }

    private func applyFingers(release:Float) {
        for digit in definition.digits { for (part,index) in digit.joints.enumerated() {
            let axis=digit.axes[part]
            let bend=simd_quatf(angle:closedAngles[index]*(1-release),axis:SIMD3(axis[0],axis[1],axis[2]))
            if digit.name == "thumb",part == 0 {
                let opposition=simd_quatf(angle:(rightHand ? -1 : 1)*thumbOpposition*(1-release),axis:SIMD3(0,1,0))
                bones[index].simdOrientation=opposition*bend
            } else { bones[index].simdOrientation=bend }
        } }
    }

    private func poseArm(camera:SCNNode,rightHand:Bool,wingGrip:Bool) {
        let wrist=bones[1]
        let start=camera.simdConvertPosition(.zero,from:wrist)
        let shoulder=SIMD3<Float>(rightHand ? 0.26 : -0.26,-0.29,0.045)
        let delta=shoulder-start,distance=simd_length(delta),direction=delta/max(distance,0.001)
        func bind(_ i:Int)->SIMD3<Float> { let p=definition.joints[i].position;return SIMD3(p[0],p[1],p[2]) }
        let foreVector=bind(2)-bind(1),upperVector=bind(3)-bind(2)
        let stretch=max(1,min(1.20,distance/max(0.01,simd_length(foreVector)+simd_length(upperVector))*1.015))
        let fore=simd_length(foreVector)*stretch,upper=simd_length(upperVector)*stretch
        let d=min(distance,fore+upper-0.002)
        let along=max(-fore,min(fore,(fore*fore+d*d-upper*upper)/(2*max(d,0.001))))
        var bend=SIMD3<Float>(rightHand ? 0.4 : -0.4,-1,0.1)
        if !wingGrip {
            // Choose the elbow on its reachable circle to keep the wrist aligned
            // with the palm, instead of forcing a ninety-degree sideways kink.
            bend=camera.simdConvertVector(SIMD3(0,0,1),from:node)+SIMD3(rightHand ? 0.08 : -0.08,-0.04,0)
        }
        bend -= direction*simd_dot(bend,direction)
        bend=simd_normalize(bend)
        let elbow=start+direction*along+bend*sqrt(max(0,fore*fore-along*along))
        let desiredFore=node.simdConvertVector(elbow-start,from:camera)
        let foreRotation=simd_quatf(from:simd_normalize(foreVector),to:simd_normalize(desiredFore))
        wrist.simdOrientation=foreRotation
        wrist.simdScale=SIMD3(repeating:stretch)
        let desiredUpper=foreRotation.conjugate.act(node.simdConvertVector(shoulder-elbow,from:camera))
        bones[2].simdOrientation=simd_quatf(from:simd_normalize(upperVector),to:simd_normalize(desiredUpper))
    }

    func contactMetrics(anchor:HandLaunchGripAnchor,aircraft:SCNNode,camera:SCNNode)->(penetration:Float,shoulderError:Float,wristAngle:Float) {
        let deepest=sampledPoints(in:aircraft).map(anchor.signedDistance).min() ?? 1
        let expected=SIMD3<Float>(rightHand ? 0.26 : -0.26,-0.29,0.045)
        let actual=camera.simdConvertPosition(.zero,from:bones[3])
        let wrist=camera.simdConvertPosition(.zero,from:bones[1])
        let elbow=camera.simdConvertPosition(.zero,from:bones[2])
        let backward=simd_normalize(camera.simdConvertVector(SIMD3(0,0,1),from:node))
        let angle=acos(max(-1,min(1,simd_dot(backward,simd_normalize(elbow-wrist)))))*180 / .pi
        return (max(0,-deepest),simd_distance(actual,expected),angle)
    }
}

final class AdaptiveHandLaunchAssetLoader {
    static let shared=AdaptiveHandLaunchAssetLoader(directory:Bundle.main.url(forResource:"HandLaunchHands",withExtension:nil))
    private let directory:URL?
    private let lock=NSLock()
    private var templates:[String:SCNNode]=[:]
    private var definitions:[String:HandLaunchArmRigDefinition]=[:]
    init(directory:URL?) { self.directory=directory }
    func preloadInBackground() { DispatchQueue.global(qos:.utility).async {
        _=self.makeArm(rightHand:false);_=self.makeArm(rightHand:true)
    } }
    func makeArm(rightHand:Bool)->AdaptiveHandLaunchArm? {
        lock.lock();defer { lock.unlock() }
        let side=rightHand ? "right" : "left"
        if templates[side]==nil {
            guard let directory,let data=try? Data(contentsOf:directory.appendingPathComponent("rig-\(side).json")),
                  let source=SCNSceneSource(url:directory.appendingPathComponent("hand-launch-arm-\(side).usdz"),options:nil),
                  let scene=source.scene(options:[.animationImportPolicy:SCNSceneSource.AnimationImportPolicy.doNotPlay]) else { return nil }
            let decoder=JSONDecoder();decoder.keyDecodingStrategy = .convertFromSnakeCase
            definitions[side]=try? decoder.decode(HandLaunchArmRigDefinition.self,from:data)
            templates[side]=scene.rootNode.childNode(withName:"HandLaunchArm",recursively:true)
        }
        guard let template=templates[side],let definition=definitions[side] else { return nil }
        let clone=template.clone()
        clone.enumerateHierarchy { node,_ in
            guard let old=node.skinner else { return }
            let remapped=old.bones.compactMap { bone in
                bone.name.flatMap { clone.childNode(withName:$0,recursively:true) }
            }
            guard remapped.count==old.bones.count else { return }
            let skin=SCNSkinner(baseGeometry:old.baseGeometry,bones:remapped,
                boneInverseBindTransforms:old.boneInverseBindTransforms,
                boneWeights:old.boneWeights,boneIndices:old.boneIndices)
            skin.baseGeometryBindTransform=old.baseGeometryBindTransform
            skin.skeleton=old.skeleton?.name.flatMap { clone.childNode(withName:$0,recursively:true) }
            node.skinner=skin
        }
        return AdaptiveHandLaunchArm(node:clone,definition:definition,rightHand:rightHand)
    }
}
