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
            let state = localState(of: child)
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
            states[path] = localState(of: child)
        }
        return states
    }

    static func localState(of node: SCNNode) -> MissionReplayNodeState {
        let colour = (node.geometry?.firstMaterial?.multiply.contents as? NSColor)?.usingColorSpace(.deviceRGB)
        let tint = colour.map { SIMD4<Float>(Float($0.redComponent), Float($0.greenComponent), Float($0.blueComponent), Float($0.alphaComponent)) }
        let roll = (node.value(forKey: "userData") as? NSDictionary)?["wheelRoll"] as? Double
        return MissionReplayNodeState(pose: MissionReplayPose(position: node.simdPosition,
            rotation: node.simdOrientation.vector, scale: node.simdScale), opacity: Double(node.opacity),
            materialTint: tint, wheelRoll: roll)
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
    private var effects: [UUID: WorldDamageEffectVisual] = [:]
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
        root.name = "mission-replay-world"
        root.addChildNode(WorldDamageEffectVisual.makePreparationNode())
        scene.rootNode.addChildNode(root)
    }

    func node(for id: String) -> SCNNode? { id == "player" ? playerRoot : instances[id]?.node }

    func update(_ world: MissionReplayWorldSnapshot) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
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
                    if state.materialTint != previousChanges[path]?.materialTint {
                        let tint = state.materialTint ?? SIMD4<Float>(repeating: 1)
                        let colour = NSColor(calibratedRed: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z), alpha: CGFloat(tint.w))
                        for material in child.geometry?.materials ?? [] { material.multiply.contents = colour }
                    }
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
            effects.removeValue(forKey: id)?.node.removeFromParentNode()
        }
        for effect in values {
            let instance: WorldDamageEffectVisual
            if let existing = effects[effect.id] { instance = existing } else {
                instance = WorldDamageEffectVisual(kind: InterceptEffectKind(rawValue: effect.kind) ?? .contact,
                    scale: effect.scale ?? 1)
                instance.node.name = "replay.effect.\(effect.id)"
                root.addChildNode(instance.node); effects[effect.id] = instance
            }
            instance.node.simdPosition = effect.position
            instance.update(age: effect.age, lifetime: effect.lifetime, normal: effect.normal, wind: effect.wind ?? .zero)
        }
    }
}
