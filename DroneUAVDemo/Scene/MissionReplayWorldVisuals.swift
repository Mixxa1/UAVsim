import AppKit
import SceneKit
import simd

/// Captures actual scene objects, including custom assemblies and detached geometry.
/// Geometry is archived once; no live physics, actions or particle simulation run in a replay.
enum MissionReplayVisualCapture {
    static func pose(of node: SCNNode) -> MissionReplayPose {
        let transform = node.simdWorldTransform
        let scale = SIMD3<Float>(simd_length(SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
                                simd_length(SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
                                simd_length(SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)))
        return MissionReplayPose(position: node.simdWorldPosition, rotation: node.simdWorldOrientation.vector, scale: scale)
    }

    static func snapshot(id: String, node: SCNNode, recorder: MissionReplayRecorder,
                         role: String? = nil, displayName: String? = nil,
                         camera: SCNNode? = nil, poseNode: SCNNode? = nil) -> MissionReplayVisualSnapshot {
        let sourceID = "\(id):\(ObjectIdentifier(node))"
        var liveNodes: [ObjectIdentifier: SCNNode] = [:]
        visit(node, path: "") { child, _ in liveNodes[ObjectIdentifier(child)] = child }
        var assetID = recorder.visualAssetIDs[sourceID] ?? sourceID
        // Removing a child must not shift the paths of its surviving siblings. New children
        // need a new archive; removed children are simply hidden against the original paths.
        if let paths = recorder.visualNodePaths[assetID], liveNodes.keys.contains(where: { paths[$0] == nil }) {
            assetID = "\(sourceID):\(UUID())"
        }
        recorder.visualAssetIDs[sourceID] = assetID
        _ = recorder.registerVisualAsset(id: assetID) {
            recorder.visualNodeBaselines[assetID] = localStates(of: node)
            var paths: [ObjectIdentifier: String] = [:]
            visit(node, path: "") { child, path in paths[ObjectIdentifier(child)] = path }
            recorder.visualNodePaths[assetID] = paths
            let copy = node.clone()
            copy.simdTransform = matrix_identity_float4x4
            copy.opacity = 1
            copy.enumerateHierarchy { child, _ in
                child.removeAllActions()
                child.removeAllAnimations()
                child.removeAllParticleSystems()
                child.physicsBody = nil
                child.camera = nil
                child.light = nil
                child.constraints = nil
                child.isHidden = false
            }
            return try? NSKeyedArchiver.archivedData(withRootObject: copy, requiringSecureCoding: false)
        }
        let paths = recorder.visualNodePaths[assetID] ?? [:]
        let hidden = liveNodes.compactMap { identity, child in child.isHidden ? paths[identity] : nil }
        let baseline = recorder.visualNodeBaselines[assetID] ?? [:]
        var changes: [String: MissionReplayNodeState] = [:]
        for (identity, child) in liveNodes {
            guard let path = paths[identity], !path.isEmpty else { continue }
            let state = MissionReplayNodeState(pose: MissionReplayPose(position: child.simdPosition,
                rotation: child.simdOrientation.vector, scale: child.simdScale), opacity: Double(child.opacity))
            if baseline[path] != state { changes[path] = state }
        }
        let absent = paths.compactMap { identity, path in liveNodes[identity] == nil ? path : nil }
        return MissionReplayVisualSnapshot(
            id: id, assetID: assetID, role: role, displayName: displayName, pose: pose(of: poseNode ?? node),
            opacity: Double(node.opacity), isHidden: false, hiddenNodePaths: hidden,
            absentNodeNames: [],
            camera: camera.map { MissionReplayCameraSnapshot(pose: pose(of: $0), fieldOfView: Double($0.camera?.fieldOfView ?? 70)) },
            nodeStates: changes.isEmpty ? nil : changes, absentNodePaths: absent.isEmpty ? nil : absent
        )
    }

    static func localStates(of node: SCNNode) -> [String: MissionReplayNodeState] {
        var states: [String: MissionReplayNodeState] = [:]
        visit(node, path: "") { child, path in
            guard !path.isEmpty else { return }
            states[path] = MissionReplayNodeState(
                pose: MissionReplayPose(position: child.simdPosition, rotation: child.simdOrientation.vector, scale: child.simdScale),
                opacity: Double(child.opacity))
        }
        return states
    }

    static func visit(_ node: SCNNode, path: String, action: (SCNNode, String) -> Void) {
        action(node, path)
        for (index, child) in node.childNodes.enumerated() {
            visit(child, path: "\(path)/\(index)", action: action)
        }
    }
}

final class MissionReplayWorldVisuals {
    private let root = SCNNode()
    private var assets: [String: Data] = [:]
    private var instances: [String: (assetID: String, node: SCNNode)] = [:]
    private var effects: [UUID: SCNNode] = [:]
    private var baselines: [String: [String: MissionReplayNodeState]] = [:]
    private var previousChildChanges: [String: [String: MissionReplayNodeState]] = [:]
    private weak var playerRoot: SCNNode?
    private(set) var snapshots: [MissionReplayVisualSnapshot] = []
    private(set) var assetFailures = false

    func load(assets: [String: Data], scene: SCNScene, playerRoot: SCNNode) {
        root.removeFromParentNode()
        root.childNodes.forEach { $0.removeFromParentNode() }
        instances.removeAll()
        effects.removeAll()
        baselines.removeAll()
        previousChildChanges.removeAll()
        snapshots = []
        assetFailures = false
        self.assets = assets
        self.playerRoot = playerRoot
        scene.rootNode.addChildNode(root)
    }

    func node(for id: String) -> SCNNode? { id == "player" ? playerRoot : instances[id]?.node }

    func update(_ world: MissionReplayWorldSnapshot) {
        snapshots = world.nodes
        let live = Set(world.nodes.map(\.id))
        for id in Array(instances.keys) where !live.contains(id) {
            instances.removeValue(forKey: id)?.node.removeFromParentNode()
            baselines.removeValue(forKey: id)
            previousChildChanges.removeValue(forKey: id)
        }
        for snapshot in world.nodes {
            let node: SCNNode
            if let instance = instances[snapshot.id], instance.assetID == snapshot.assetID {
                node = instance.node
            } else {
                instances.removeValue(forKey: snapshot.id)?.node.removeFromParentNode()
                guard let data = assets[snapshot.assetID],
                      let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: SCNNode.self, from: data) else {
                    assetFailures = true
                    continue
                }
                node = decoded
                baselines[snapshot.id] = MissionReplayVisualCapture.localStates(of: node)
                previousChildChanges[snapshot.id] = [:]
                node.enumerateHierarchy { child, _ in
                    child.physicsBody = nil
                    child.removeAllActions()
                    child.removeAllAnimations()
                    child.removeAllParticleSystems()
                    child.constraints = nil
                }
                if snapshot.id == "player", let playerRoot {
                    playerRoot.childNodes.filter { $0.name != "replayGizmoRoot" }.forEach { $0.isHidden = true }
                    playerRoot.addChildNode(node)
                } else {
                    root.addChildNode(node)
                }
                instances[snapshot.id] = (snapshot.assetID, node)
            }
            if snapshot.id == "player" {
                if node.simdScale != snapshot.pose.scale { node.simdScale = snapshot.pose.scale }
            } else {
                node.simdPosition = snapshot.pose.position
                node.simdOrientation = simd_quatf(vector: snapshot.pose.rotation)
                node.simdScale = snapshot.pose.scale
            }
            if node.opacity != CGFloat(snapshot.opacity) { node.opacity = CGFloat(snapshot.opacity) }
            let hidden = Set(snapshot.hiddenNodePaths)
            let absent = Set(snapshot.absentNodeNames)
            let absentPaths = Set(snapshot.absentNodePaths ?? [])
            let previousChanges = previousChildChanges[snapshot.id] ?? [:]
            MissionReplayVisualCapture.visit(node, path: "") { child, path in
                let isHidden = path.isEmpty ? snapshot.isHidden : hidden.contains(path) || absentPaths.contains(path) || child.name.map { absent.contains($0) } == true
                if child.isHidden != isHidden { child.isHidden = isHidden }
                // Most child meshes never move. Apply only deltas, plus reversions needed by
                // backwards seeking, rather than dirtying every static mesh at display cadence.
                if let state = snapshot.nodeStates?[path] ?? (previousChanges[path] != nil ? baselines[snapshot.id]?[path] : nil),
                   previousChanges[path] != state {
                    child.simdPosition = state.pose.position
                    child.simdOrientation = simd_quatf(vector: state.pose.rotation)
                    child.simdScale = state.pose.scale
                    child.opacity = CGFloat(state.opacity)
                }
            }
            previousChildChanges[snapshot.id] = snapshot.nodeStates ?? [:]
        }
        updateEffects(world.effects)
    }

    /// Effect age comes from the recording. Seeking backwards removes and rebuilds the same
    /// deterministic shapes, rather than leaving emitters or actions running on wall-clock time.
    private func updateEffects(_ values: [MissionReplayEffectSnapshot]) {
        let live = Set(values.map(\.id))
        for id in Array(effects.keys) where !live.contains(id) {
            effects.removeValue(forKey: id)?.removeFromParentNode()
        }
        for effect in values {
            let node: SCNNode
            if let existing = effects[effect.id] { node = existing } else {
                node = makeEffect(effect)
                root.addChildNode(node)
                effects[effect.id] = node
            }
            node.simdPosition = effect.position
            let age = Float(max(0, effect.age))
            let life = Float(max(0.01, effect.lifetime))
            let fade = max(0, 1 - age / life)
            let kind = InterceptEffectKind(rawValue: effect.kind) ?? .contact
            let outward = simd_length_squared(effect.normal) > 0.0001 ? simd_normalize(effect.normal) : SIMD3<Float>(0, 1, 0)
            let orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: outward)
            for (index, particle) in node.childNodes.enumerated() {
                let seed = Float(index + 1)
                let direction = orientation.act(SIMD3<Float>(sin(seed * 2.4), 0.4 + abs(cos(seed)), cos(seed * 1.8)))
                var scale: Float
                var opacity: Float
                switch kind {
                case .smoke:
                    let rise = max(0, age - seed * 0.15)
                    particle.simdPosition = direction * rise * 0.22 + SIMD3<Float>(0, rise * 0.55, 0)
                    scale = 0.3 + rise * 0.22
                    opacity = fade * 0.45
                case .fire:
                    let phase = (age * 1.2 + seed * 0.13).truncatingRemainder(dividingBy: 1)
                    particle.simdPosition = direction * 0.22 + SIMD3<Float>(0, phase * 1.8, 0)
                    scale = 0.25 + (1 - phase) * 0.45
                    opacity = fade * (1 - phase) * 0.85
                case .contact, .secondary:
                    let burst = kind == .secondary ? Float(2.4) : 1
                    particle.simdPosition = direction * age * 5 * burst - SIMD3<Float>(0, 4.9 * age * age, 0)
                    scale = (0.04 + max(0, 1 - age) * 0.05) * burst
                    opacity = max(0, 1 - age / 0.8)
                    if index == 0 {
                        particle.simdPosition = .zero
                        scale = (0.25 + age * 1.8) * burst
                        opacity = exp(-age * 7) * fade
                    }
                }
                particle.simdScale = SIMD3<Float>(repeating: scale)
                particle.opacity = CGFloat(opacity)
            }
        }
    }

    private func makeEffect(_ effect: MissionReplayEffectSnapshot) -> SCNNode {
        let root = SCNNode()
        root.name = "replay.effect.\(effect.id)"
        for _ in 0..<18 {
            let sprite = SCNPlane(width: 2, height: 2)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = Self.effectSprite
            material.multiply.contents = effect.kind == "smoke" ? NSColor(white: 0.25, alpha: 1)
                : NSColor(calibratedRed: 1, green: effect.kind == "contact" ? 0.75 : 0.32, blue: 0.08, alpha: 1)
            material.writesToDepthBuffer = false
            material.blendMode = effect.kind == "smoke" ? .alpha : .add
            material.isDoubleSided = true
            sprite.firstMaterial = material
            let node = SCNNode(geometry: sprite)
            node.constraints = [SCNBillboardConstraint()]
            root.addChildNode(node)
        }
        return root
    }

    private static let effectSprite: NSImage = {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        for y in 0..<32 {
            for x in 0..<32 {
                let dx = (Double(x) + 0.5) / 16 - 1, dy = (Double(y) + 0.5) / 16 - 1
                let alpha = pow(max(0, 1 - sqrt(dx * dx + dy * dy)), 1.6)
                let pixel = bitmap.bitmapData!.advanced(by: y * 128 + x * 4)
                pixel[0] = 255; pixel[1] = 255; pixel[2] = 255; pixel[3] = UInt8(alpha * 255)
            }
        }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(bitmap)
        return image
    }()
}
