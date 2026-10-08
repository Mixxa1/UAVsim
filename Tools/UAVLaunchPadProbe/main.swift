import Foundation
import SceneKit
import simd

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "DroneUAVDemo/Resources/Models/LaunchPads"
let directory = URL(fileURLWithPath: path)
var failures: [String] = []
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}
func settle(_ pad: UAVLaunchPadInstance, wind: SIMD3<Float>, gusts: Float = 0, seconds: Float = 8) {
    for _ in 0..<Int(seconds * 60) { pad.update(wind: wind, gusts: gusts, deltaTime: 1 / 60) }
}
func direction(_ pad: UAVLaunchPadInstance) -> SIMD2<Float> {
    let heading = pad.node.childNode(withName: "Yaw", recursively: true)!
    let vector = heading.simdConvertVector(SIMD3<Float>(0, 0, 1), to: nil)
    return simd_normalize(SIMD2(vector.x, vector.z))
}

let loader = UAVLaunchPadAssetLoader(directory: directory)
guard let pad = loader.makeInstance() else { fatalError("Bundled launch pad failed to load") }
let scene = SCNScene()
scene.rootNode.addChildNode(pad.node)
var animations = 0, geometries = 0
pad.node.enumerateHierarchy { node, _ in
    animations += node.animationKeys.count
    if node.geometry != nil { geometries += 1 }
}
check(geometries == 186, "Incomplete native USDZ import")
check(animations == 0, "Viewer animation is still running in the simulator")

let originalScene = try SCNScene(url: directory.appendingPathComponent(UAVLaunchPadConstants.assetFile), options: nil)
func vertices(_ node: SCNNode) -> [SIMD3<Float>] {
    let source = node.geometry!.sources(for: .vertex).first!
    return source.data.withUnsafeBytes { buffer in
        (0..<source.vectorCount).map { index in
            let offset = source.dataOffset + index * source.dataStride
            func component(_ k: Int) -> Float {
                if source.bytesPerComponent == 4 {
                    return buffer.loadUnaligned(fromByteOffset: offset+k*4, as: Float.self)
                }
                return Float(buffer.loadUnaligned(fromByteOffset: offset+k*8, as: Double.self))
            }
            return SIMD3(component(0), component(1), component(2))
        }
    }
}
func checkAttachedInlets() {
    for index in 1...5 {
        let name = String(format: "Fabric%02d", index)
        let section = pad.node.childNode(withName: name, recursively: true)!
        let mesh = section.childNodes.first { $0.geometry != nil }!
        let originalSection = originalScene.rootNode.childNode(withName: name, recursively: true)!
        let originalMesh = originalSection.childNodes.first { $0.geometry != nil }!
        let authored = vertices(originalMesh), bent = vertices(mesh)
        check(authored.count == bent.count, "Fabric topology changed during bending")
        guard authored.count == bent.count else { continue }
        for i in authored.indices where abs(authored[i].z) < 0.000001 {
            let expected = section.parent!.simdConvertPosition(section.simdPosition+authored[i], to: nil)
            let actual = mesh.simdConvertPosition(bent[i], to: nil)
            check(simd_distance(expected, actual) < 0.0001, "Fabric inlet detached from its parent: \(name)")
        }
    }
}
checkAttachedInlets()

// Use actual imported transforms, including a rotated pad parent. Tail must point
// with air motion for every cardinal direction, rather than against the wind.
for yaw in [Float(0), .pi/2] {
    pad.node.simdOrientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
    for wind in [SIMD3<Float>(6, 0, 0), SIMD3(0, 0, 6), SIMD3(-6, 0, 0), SIMD3(0, 0, -6)] {
        settle(pad, wind: wind)
        checkAttachedInlets()
        let desired = simd_normalize(SIMD2(wind.x, wind.z))
        check(simd_dot(direction(pad), desired) > 0.9999, "Wrong downwind direction: yaw=\(yaw), wind=\(wind)")
    }
}
pad.node.simdOrientation = simd_quatf()

var calm = WindsockDynamics()
let atRest = calm.advance(wind: .zero, gusts: 1, deltaTime: 1/60)
for _ in 0..<600 { _ = calm.advance(wind: .zero, gusts: 1, deltaTime: 1/60) }
check(calm.pose.pitchRadians == atRest.pitchRadians, "Fabric flutters with zero wind")
check(abs(calm.pose.pitchRadians[0] - .pi/2) < 0.0001, "Calm fabric is not hanging vertically")
var strong = WindsockDynamics()
for _ in 0..<600 { _ = strong.advance(wind: SIMD3(0, 0, 10), gusts: 0.5, deltaTime: 1/60) }
check(strong.pose.pitchRadians[0] < 0.2, "Strong wind did not straighten the fabric")
let beforePause = strong.pose
_ = strong.advance(wind: SIMD3(0, 0, 10), gusts: 0.5, deltaTime: 0)
check(strong.pose.pitchRadians == beforePause.pitchRadians, "Paused simulation keeps fluttering")
for _ in 0..<600 { _ = strong.advance(wind: .zero, gusts: 0, deltaTime: 1/60) }
check(abs(strong.pose.pitchRadians[0] - .pi/2) < 0.001, "Fabric did not droop after wind stopped")

var turning = WindsockDynamics()
let almostSouth = Float(179) * .pi / 180
let otherSide = Float(-179) * .pi / 180
for _ in 0..<600 {
    _ = turning.advance(wind: SIMD3(sin(almostSouth)*6, 0, cos(almostSouth)*6), gusts: 0, deltaTime: 1/60)
}
let oldHeading = turning.pose.yawRadians
_ = turning.advance(wind: SIMD3(sin(otherSide)*6, 0, cos(otherSide)*6), gusts: 0, deltaTime: 1/60)
let turn = atan2(sin(turning.pose.yawRadians-oldHeading), cos(turning.pose.yawRadians-oldHeading))
check(turn > 0 && turn < 0.01, "Wind direction crossed the long arc at ±180 degrees")
_ = turning.advance(wind: SIMD3(.nan, .infinity, .nan), gusts: .nan, deltaTime: 1/60)
check(turning.pose.yawRadians.isFinite && (0..<5).allSatisfy { turning.pose.pitchRadians[$0].isFinite }, "Invalid weather poisoned node transforms")

pad.node.simdPosition.y = UAVLaunchPadConstants.deckRiseAboveGroundM
let deck = pad.supportHeight(at: .zero, clearanceRadius: 0, maximumHeight: 100)
let apron = pad.supportHeight(at: SIMD2(7, 0), clearanceRadius: 0, maximumHeight: 100)
check(abs((deck ?? -100)-0.055) < 0.0001, "Deck contact elevation differs from visible surface")
check(abs((apron ?? -100)-0.005) < 0.0001, "Apron contact elevation differs from visible surface")
check(pad.supportHeight(at: SIMD2(9, 0), clearanceRadius: 0, maximumHeight: 100) == nil, "Pad support extends outside its footprint")
check(pad.supportHeight(at: SIMD2(0, 0), clearanceRadius: 0, maximumHeight: -1) == nil, "Pad was selected from beneath its base")

// Inspect the imported vertex buffers directly. SceneKit's headless segment test
// needs a prepared render tree, but these are the exact vertices sent to Metal.
var deckPlanes = 0
pad.node.enumerateHierarchy { node, _ in
    guard (node.name ?? "").hasPrefix("SlabFinish"),
          let source = node.geometry?.sources(for: .vertex).first else { return }
    deckPlanes += 1
    check(source.usesFloatComponents && source.bytesPerComponent == 4, "Unexpected deck vertex format")
    guard source.usesFloatComponents, source.bytesPerComponent == 4 else { return }
    source.data.withUnsafeBytes { buffer in
        for index in 0..<source.vectorCount {
            let offset = source.dataOffset + index * source.dataStride
            let x = buffer.loadUnaligned(fromByteOffset: offset, as: Float.self)
            let y = buffer.loadUnaligned(fromByteOffset: offset+4, as: Float.self)
            let z = buffer.loadUnaligned(fromByteOffset: offset+8, as: Float.self)
            let world = node.simdConvertPosition(SIMD3(x, y, z), to: nil)
            check(abs(world.y-0.055) < 0.001, "Imported deck mesh differs from contact height")
        }
    }
}
check(deckPlanes == 16, "Expected sixteen imported landing surfaces")

if failures.isEmpty {
    print("PASS: native 186-mesh pad, attached fabric inlets, wind direction in world space, calm/strong wind, pause, shortest turn, finite transforms and contact heights")
} else {
    failures.forEach { print("FAIL: \($0)") }
    exit(1)
}
