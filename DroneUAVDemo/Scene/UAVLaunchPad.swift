import Foundation
import SceneKit
import simd

enum UAVLaunchPadConstants {
    static let bundleFolder = "LaunchPads"
    static let assetFile = "uav-launch-pad.usdz"
    /// The apron is 5 cm below the deck. Its top clears procedural ground by 5 mm.
    static let deckRiseAboveGroundM: Float = 0.055
}

struct WindsockPose {
    var yawRadians: Float = 0
    var pitchRadians = SIMD8<Float>(Float.pi / 2, 0, 0, 0, 0, 0, 0, 0)
}

/// Cosmetic wind response. Heading follows air motion, not a meteorological "from"
/// bearing. At zero wind the fabric hangs down and its flutter amplitude is zero.
struct WindsockDynamics {
    private(set) var pose = WindsockPose()
    private var phase: Float = 0

    mutating func advance(wind: SIMD3<Float>, gusts: Float, deltaTime: Float) -> WindsockPose {
        guard deltaTime.isFinite, deltaTime > 0 else { return pose }
        let dt = min(deltaTime, 0.1)
        let x = wind.x.isFinite ? wind.x : 0
        let z = wind.z.isFinite ? wind.z : 0
        let speed = min(hypot(x, z), 40)
        let gust = gusts.isFinite ? min(1, max(0, gusts)) : 0
        if speed > 0.05 {
            let heading = atan2(x, z)
            let difference = atan2(sin(heading - pose.yawRadians), cos(heading - pose.yawRadians))
            pose.yawRadians += difference * (1 - exp(-dt * (1.4 + min(speed, 12) * 0.32)))
            pose.yawRadians = atan2(sin(pose.yawRadians), cos(pose.yawRadians))
        }
        let inflation = 1 - exp(-speed * speed / 10)
        phase = (phase + dt * (1.4 + speed * 0.38)).truncatingRemainder(dividingBy: 20 * .pi)
        let response = 1 - exp(-dt * (3 + speed * 0.35))
        for index in 0..<5 {
            let sagDegrees: Float = index == 0 ? 90 - 84 * inflation : inflation * Float(index) * 1.2
            let amplitude = inflation * (0.4 + gust * 0.85) * (1 + Float(index) * 0.40)
            let ripple = sin(phase - Float(index) * 0.65)
                + 0.30 * sin(phase * 1.7 - Float(index) * 0.45)
            let target = (sagDegrees + ripple * amplitude) * .pi / 180
            pose.pitchRadians[index] += (target - pose.pitchRadians[index]) * response
        }
        return pose
    }
}

/// Keep each fabric inlet attached to the previous section while its outlet bends.
/// The ring vertices counter-rotate inside the joint; side triangles form the bend.
private final class WindsockFabricSkin {
    private let node: SCNNode
    private let geometry: SCNGeometry
    private let vertices: [SIMD3<Float>]
    private let faces: [SIMD3<Int>]
    private var lastAngle: Float?

    init?(node: SCNNode) {
        guard let geometry = node.geometry,
              let source = geometry.sources(for: .vertex).first,
              source.usesFloatComponents, source.bytesPerComponent == 4,
              geometry.elements.allSatisfy({ $0.primitiveType == .triangles }) else { return nil }
        self.node = node
        self.geometry = geometry
        vertices = source.data.withUnsafeBytes { buffer in
            (0..<source.vectorCount).map { index in
                let offset = source.dataOffset + index * source.dataStride
                return SIMD3<Float>(
                    buffer.loadUnaligned(fromByteOffset: offset, as: Float.self),
                    buffer.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                    buffer.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                )
            }
        }
        var triangles: [SIMD3<Int>] = []
        for element in geometry.elements {
            guard [1, 2, 4].contains(element.bytesPerIndex) else { return nil }
            element.data.withUnsafeBytes { buffer in
                func index(_ position: Int) -> Int {
                    let offset = position * element.bytesPerIndex
                    switch element.bytesPerIndex {
                    case 1: return Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    case 2: return Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    default: return Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    }
                }
                for triangle in 0..<element.primitiveCount {
                    triangles.append(SIMD3(index(triangle*3), index(triangle*3+1), index(triangle*3+2)))
                }
            }
        }
        let vertexCount = source.vectorCount
        guard triangles.allSatisfy({ $0.min() >= 0 && $0.max() < vertexCount }) else { return nil }
        faces = triangles
    }

    func bend(angle: Float) {
        guard lastAngle != angle else { return }
        lastAngle = angle
        let inverse = simd_quatf(angle: -angle, axis: SIMD3<Float>(1, 0, 0))
        let points = vertices.map { abs($0.z) < 0.000001 ? simd_act(inverse, $0) : $0 }
        var normals = [SIMD3<Float>](repeating: .zero, count: points.count)
        for face in faces {
            let normal = simd_cross(points[face.y]-points[face.x], points[face.z]-points[face.x])
            normals[face.x] += normal
            normals[face.y] += normal
            normals[face.z] += normal
        }
        let positionSource = SCNGeometrySource(vertices: points.map { SCNVector3($0) })
        let normalSource = SCNGeometrySource(normals: normals.map {
            SCNVector3(simd_length_squared($0) > 1e-15 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0))
        })
        let otherSources = geometry.sources.filter { $0.semantic != .vertex && $0.semantic != .normal }
        let bent = SCNGeometry(sources: [positionSource, normalSource] + otherSources, elements: geometry.elements)
        bent.materials = geometry.materials
        node.geometry = bent
    }
}

final class UAVLaunchPadInstance {
    let node: SCNNode
    private let headingNode: SCNNode
    private let fabricNodes: [SCNNode]
    private let fabricSkins: [WindsockFabricSkin]
    private var dynamics = WindsockDynamics()

    init?(node: SCNNode) {
        guard let heading = node.childNode(withName: "Yaw", recursively: true) else { return nil }
        var fabric: [SCNNode] = []
        var skins: [WindsockFabricSkin] = []
        for index in 1...5 {
            guard let section = heading.childNode(withName: String(format: "Fabric%02d", index), recursively: true)
            else { return nil }
            guard let mesh = section.childNodes.first(where: { $0.geometry != nil }),
                  let skin = WindsockFabricSkin(node: mesh) else { return nil }
            fabric.append(section)
            skins.append(skin)
        }
        self.node = node
        self.headingNode = heading
        self.fabricNodes = fabric
        self.fabricSkins = skins
        // The packaged loop is only for USDZ viewers. Weather owns every joint here.
        node.enumerateHierarchy { child, _ in
            child.removeAllAnimations()
            child.removeAllActions()
        }
        apply(dynamics.pose)
    }

    func update(wind: SIMD3<Float>, gusts: Float, deltaTime: Float) {
        let localWind = node.simdConvertVector(wind, from: nil)
        apply(dynamics.advance(wind: localWind, gusts: gusts, deltaTime: deltaTime))
    }

    private func apply(_ pose: WindsockPose) {
        headingNode.simdOrientation = simd_quatf(angle: pose.yawRadians, axis: SIMD3(0, 1, 0))
        for (index, fabric) in fabricNodes.enumerated() {
            fabric.simdOrientation = simd_quatf(angle: pose.pitchRadians[index], axis: SIMD3(1, 0, 0))
            fabricSkins[index].bend(angle: pose.pitchRadians[index])
        }
    }

    /// Flat deck and apron are queried analytically rather than raycasting 37k triangles
    /// for every wheel. The world spawn remains the same surface used by flight physics.
    func supportHeight(at point: SIMD2<Float>, clearanceRadius: Float, maximumHeight: Float) -> Float? {
        let origin = node.simdWorldPosition
        let local = node.simdConvertPosition(SIMD3(point.x, origin.y, point.y), from: nil)
        let radius = max(0, clearanceRadius)
        func intersects(halfExtent: Float) -> Bool {
            let dx = max(0, abs(local.x) - halfExtent)
            let dz = max(0, abs(local.z) - halfExtent)
            return dx * dx + dz * dz <= radius * radius
        }
        if intersects(halfExtent: 6), origin.y <= maximumHeight + 0.08 { return origin.y }
        let apronY = origin.y - 0.05
        if intersects(halfExtent: 8), apronY <= maximumHeight + 0.08 { return apronY }
        return nil
    }
}

final class UAVLaunchPadAssetLoader {
    static let shared = UAVLaunchPadAssetLoader(directory: Bundle.main.url(
        forResource: UAVLaunchPadConstants.bundleFolder, withExtension: nil))
    private let directory: URL?
    private var template: SCNNode?

    init(directory: URL?) { self.directory = directory }

    func makeInstance() -> UAVLaunchPadInstance? {
        if template == nil {
            guard let directory,
                  let source = SCNSceneSource(url: directory.appendingPathComponent(UAVLaunchPadConstants.assetFile), options: nil),
                  let scene = source.scene(options: [
                    .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay,
                    .checkConsistency: true
                  ]), let root = scene.rootNode.childNode(withName: "LaunchPad", recursively: true) else { return nil }
            template = root
        }
        guard let node = template?.clone() else { return nil }
        return UAVLaunchPadInstance(node: node)
    }
}
