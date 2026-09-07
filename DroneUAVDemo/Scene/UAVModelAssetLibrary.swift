import AppKit
import SceneKit
import simd

/// The bundled USDZ airframe library — one authored model per catalogue entry.
///
/// These files replace the procedural silhouettes in `UAVVisualFactory` for every
/// aircraft the library covers. They are authored to the same conventions the
/// procedural builders use, which is what makes the swap a drop-in: metres, +Y up,
/// **nose toward +Z** (`DroneModelBuilder.build` applies the legacy chase-camera yaw
/// flip afterwards, exactly as before).
///
/// Two things are deliberately *not* taken from the file:
///
/// - **The embedded animation.** Propellers have a two-second display loop; the
///   three transitioning VTOL aircraft have a twelve-second hover/cruise loop.
///   Both are slowed for inspection in Finder and Preview. They are viewing aids, not
///   a flight model: in the simulator the discs have to turn at the speed the
///   propulsion step is actually commanding. Every animation is stripped on import and
///   the rotor nodes are driven from `DroneSceneController` through the same
///   `eulerAngles.y` path the procedural rigs use. Normalized tilt drivers consume
///   the existing positive-X servo angle; a tailsitter uses the physics body pose.
/// - **The materials as shared objects.** The damage/thermal overlay writes emission
///   onto a component's materials in place, so two nodes sharing one `SCNMaterial`
///   would light up together. Every instance gets its own copies.
enum UAVModelAssetConstants {
    /// Folder-reference name inside the app bundle.
    static let bundleFolder = "UAVModels"
    static let manifestFile = "manifest.json"

    /// How many parsed airframes stay resident.
    ///
    /// Judgement, not measurement: the selection grid shows roughly six to twelve
    /// cards at once, so sixteen covers a viewport plus a scroll margin without
    /// pinning all fifty-five (about 6,500 meshes and 1.6 M vertices in total). A
    /// card scrolled far out of view is cheaper to re-parse than to keep.
    static let templateCacheLimit = 16
}

// MARK: - Manifest

/// The subset of `manifest.json` the runtime reads. Every other field in that file —
/// checksums, provenance, validation notes — belongs to the asset pipeline in
/// `Tools/UAVModelAssets/` and is intentionally ignored here rather than duplicated
/// into a second format that could drift from it.
struct UAVModelManifest: Decodable {
    struct Rotor: Decodable {
        let name: String
        /// Rotor centre in model space, metres. On the motor axis by construction.
        let center: [Float]
        /// `"y"` for a lifting disc, `"z"` for a tractor/pusher propeller.
        let axis: String
        /// +1 / -1. Counter-rotating pairs carry opposite signs.
        let direction: Float
        let radiusM: Float
    }

    struct Entry: Decodable {
        let id: String
        let file: String
        let rotors: [Rotor]?
        let transition: Transition?
    }

    struct Transition: Decodable {
        struct Pivot: Decodable {
            let name: String
            let hoverDegrees: Float
            let cruiseDegrees: Float
        }
        let mechanism: String
        let pivots: [Pivot]
        let bodyNode: String?
    }

    let models: [Entry]
}

// MARK: - Library

final class UAVModelAssetLibrary {
    static let shared = UAVModelAssetLibrary(
        directory: Bundle.main.url(
            forResource: UAVModelAssetConstants.bundleFolder,
            withExtension: nil
        )
    )

    private let rootURL: URL?
    private let entriesByID: [String: UAVModelManifest.Entry]

    private var templates: [String: SCNNode] = [:]
    private var templateOrder: [String] = []
    private var warnedIDs: Set<String> = []
    private var didWarnMissingLibrary = false

    /// `directory` is the folder holding the `.usdz` files and `manifest.json` — the
    /// bundled `UAVModels` folder in the app, or the checked-in resource directory for
    /// the headless probe, which has no bundle to look in.
    init(directory: URL?) {
        guard let root = directory else {
            rootURL = nil
            entriesByID = [:]
            return
        }
        rootURL = root

        let manifestURL = root.appendingPathComponent(UAVModelAssetConstants.manifestFile)
        guard let data = try? Data(contentsOf: manifestURL) else {
            entriesByID = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let manifest = try? decoder.decode(UAVModelManifest.self, from: data) else {
            entriesByID = [:]
            return
        }
        entriesByID = Dictionary(manifest.models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Whether an authored model exists for this catalogue id.
    func hasModel(for profileID: String) -> Bool {
        entriesByID[profileID] != nil
    }

    /// Every catalogue id the library covers. Read by `Tools/UAVModelProbe`.
    var coveredIDs: [String] { Array(entriesByID.keys) }

    /// How many rotors the manifest declares for an aircraft — the count the extracted
    /// spin nodes are checked against.
    /// How many tilt hinges the manifest declares, and by what mechanism. Read by
    /// `Tools/UAVModelProbe` to check the rig against the file it came from.
    func transitionSummary(for profileID: String) -> (mechanism: String, pivotCount: Int)? {
        guard let transition = entriesByID[profileID]?.transition else { return nil }
        return (transition.mechanism, transition.pivots.count)
    }

    func rotorCount(for profileID: String) -> Int {
        entriesByID[profileID]?.rotors?.count ?? 0
    }

    /// Builds the flight-ready visual for one catalogue aircraft, or `nil` when the
    /// library does not cover it — in which case `UAVVisualFactory` falls back to its
    /// procedural builder rather than leaving the operator with no aircraft at all.
    ///
    /// `scale` exists for the case where an aircraft's *runtime* size differs from its
    /// catalogue size (`RuntimeTuning.runtimeSceneDimensionsOverride`). Passing the
    /// ratio keeps the rendered airframe the same size as the one the physics is
    /// flying; it is 1.0 for every aircraft in the catalogue today.
    func makeVisualModel(
        profileID: String,
        payloadMountOffset: SIMD3<Float>,
        scale: Float = 1.0
    ) -> DroneVisualModel? {
        guard let entry = entriesByID[profileID] else {
            warnMissing(profileID)
            return nil
        }
        guard let template = template(for: entry) else {
            warnMissing(profileID)
            return nil
        }

        let root = SCNNode()
        root.name = "uavRoot.model.\(profileID)"

        let modelNode = template.clone()
        UAVModelAssetLibrary.giveInstanceItsOwnMaterials(modelNode)

        // The scale lives on an inner node rather than on `root`: `DroneModelBuilder`
        // measures the visual bounds in root space, and a scale sitting *on* root is
        // not part of that conversion — it would be silently dropped from the bounds,
        // the ground lift and the component graph.
        let scaleNode = SCNNode()
        scaleNode.name = "uavModelScale"
        let resolvedScale = scale.isFinite && scale > 0.0001 ? scale : 1.0
        scaleNode.simdScale = SIMD3<Float>(repeating: resolvedScale)
        scaleNode.addChildNode(modelNode)
        root.addChildNode(scaleNode)

        // The point the quadrant split runs through — measured before any rotor is
        // rewrapped, so it describes the aircraft as authored.
        let (modelCentre, modelExtent) = UAVModelAssetLibrary.boundsCentreAndExtent(of: modelNode)

        var componentNodes: [DamageComponent: [SCNNode]] = [:]
        var propellerNodes: [SCNNode] = []
        var spinDirections: [Float] = []
        var rotorSubtrees: [SCNNode] = []

        for rotor in entry.rotors ?? [] {
            guard rotor.center.count == 3,
                  let rotorNode = modelNode.childNode(withName: rotor.name, recursively: true) else {
                continue
            }
            let spinNode = UAVModelAssetLibrary.makeSpinNode(for: rotorNode, axis: rotor.axis)
            propellerNodes.append(spinNode)
            spinDirections.append(rotor.direction >= 0.0 ? 1.0 : -1.0)
            rotorSubtrees.append(spinNode)

            let rotorCentre = SIMD3<Float>(rotor.center[0], rotor.center[1], rotor.center[2])
            let corner = UAVModelAssetLibrary.corner(of: rotorCentre, centre: modelCentre, extent: modelExtent)
            componentNodes[corner.propeller, default: []].append(spinNode)
        }

        UAVModelAssetLibrary.mapDamageComponents(
            in: modelNode,
            skipping: rotorSubtrees,
            centre: modelCentre,
            extent: modelExtent,
            into: &componentNodes
        )

        let fpvAnchor = SCNNode()
        fpvAnchor.name = "fpvCameraAnchor"
        fpvAnchor.simdPosition = UAVModelAssetLibrary.fpvAnchorPosition(in: modelNode)
        modelNode.addChildNode(fpvAnchor)
        componentNodes[.frontCameraGimbal, default: []].append(fpvAnchor)

        // The mount offset is a catalogue figure in real metres, so it is placed
        // outside the scale node — a shrunk visual must not drag the payload
        // attachment point in with it.
        let payloadMountNode = SCNNode()
        payloadMountNode.name = "payloadMountNode"
        payloadMountNode.simdPosition = payloadMountOffset
        root.addChildNode(payloadMountNode)

        UAVModelAssetLibrary.enableShadows(modelNode)
        UAVModelAssetLibrary.cullSurfaceDetailWhenTiny(modelNode, airframeExtent: modelExtent)

        // Preserve canonical geometry for bounds/damage sampling. The live scene
        // applies the servo angle on its next update; no baked preview can compete.
        let tiltPivots: [SCNNode] = (entry.transition?.pivots ?? []).compactMap { definition in
            guard let pivot = modelNode.childNode(withName: definition.name, recursively: true) else { return nil }
            return UAVModelAssetLibrary.makeTiltDriver(for: pivot, definition: definition)
        }

        return DroneVisualModel(
            rootNode: root,
            propellerNodes: propellerNodes,
            propellerSpinDirections: spinDirections,
            componentNodes: componentNodes,
            fpvAnchorNode: fpvAnchor,
            payloadMountNode: payloadMountNode,
            tiltPivotNodes: tiltPivots
        )
    }

    // MARK: - Template loading

    /// Normalize every hinge to the simulator's positive X, 0..pi/2 servo API.
    /// A fixed frame handles the rear Wingcopter's opposite hinge direction;
    /// a fixed child handles Trinity's cruise-authored motor geometry.
    private static func makeTiltDriver(for pivot: SCNNode, definition: UAVModelManifest.Transition.Pivot) -> SCNNode {
        let parent = pivot.parent
        let mount = SCNNode()
        mount.name = "tiltMount.\(definition.name)"
        mount.simdPosition = pivot.simdPosition
        let sign: Float = definition.cruiseDegrees >= definition.hoverDegrees ? 1 : -1
        let basis = simd_quatf(angle: sign < 0 ? .pi : 0, axis: SIMD3<Float>(0,0,1))
        mount.simdOrientation = basis
        let driver = SCNNode()
        driver.name = "tiltServo.\(definition.name)"
        let counter = SCNNode()
        let hover = definition.hoverDegrees * Float.pi / 180
        counter.simdOrientation = simd_inverse(basis) * simd_quatf(angle: hover, axis: SIMD3<Float>(1,0,0))
        // Keep the authored pose for initial graph/bounds extraction.
        driver.eulerAngles.x = CGFloat(-hover / sign)
        pivot.removeFromParentNode()
        pivot.simdPosition = .zero
        pivot.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(1,0,0))
        counter.addChildNode(pivot)
        driver.addChildNode(counter)
        mount.addChildNode(driver)
        parent?.addChildNode(mount)
        return driver
    }

    private func template(for entry: UAVModelManifest.Entry) -> SCNNode? {
        if let cached = templates[entry.id] {
            touch(entry.id)
            return cached
        }
        guard let rootURL else { return nil }

        // `entry.file` is "models/<id>.usdz" in the authoring tree; the bundle keeps
        // the files flat, so only the leaf name is used.
        let fileName = (entry.file as NSString).lastPathComponent
        let url = rootURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        // ⚠️ No `.preserveOriginalTopology: false` here, though every other asset loader
        // in this folder passes it. Measured: with that option SceneKit re-processes the
        // imported geometry and the material colours come out gamma-mangled — the
        // WingtraOne's orange (sRGB 1.00, 0.63, 0.05) rendered as a flat red
        // (1.00, 0.32, 0.10), and the same shift hit every aircraft with a saturated
        // livery. Nothing else in the import touched it: cloning, copying geometry,
        // copying materials and stripping animation all leave the colour exactly alone.
        guard let source = SCNSceneSource(url: url, options: nil),
              let scene = source.scene(options: [
                  .animationImportPolicy: SCNSceneSource.AnimationImportPolicy.doNotPlay,
                  .checkConsistency: false
              ]) else {
            return nil
        }

        let template = SCNNode()
        template.name = "uavModelTemplate.\(entry.id)"
        for child in scene.rootNode.childNodes {
            template.addChildNode(child)
        }
        UAVModelAssetLibrary.stripEmbeddedAnimation(template)
        // USD viewers play the full hover/cruise loop. In the simulator Wingtra's
        // attitude belongs to physics, and motor hinges belong to live servos.
        for pivot in entry.transition?.pivots ?? [] {
            template.childNode(withName: pivot.name, recursively: true)?.eulerAngles = SCNVector3Zero
        }
        if let body = entry.transition?.bodyNode {
            template.childNode(withName: body, recursively: true)?.eulerAngles = SCNVector3Zero
        }

        templates[entry.id] = template
        touch(entry.id)
        evictIfNeeded()
        return template
    }

    private func touch(_ id: String) {
        templateOrder.removeAll { $0 == id }
        templateOrder.append(id)
    }

    private func evictIfNeeded() {
        while templateOrder.count > UAVModelAssetConstants.templateCacheLimit {
            let oldest = templateOrder.removeFirst()
            templates.removeValue(forKey: oldest)
        }
    }

    private func warnMissing(_ profileID: String) {
        if rootURL == nil {
            guard !didWarnMissingLibrary else { return }
            didWarnMissingLibrary = true
            print("[UAVModels] bundled airframe library missing — every aircraft renders procedurally")
            return
        }
        guard warnedIDs.insert(profileID).inserted else { return }
        print("[UAVModels] no bundled model for '\(profileID)' — rendering procedurally")
    }

    // MARK: - Import hygiene

    /// Drops the file's own rotor animation. The simulator owns rotor speed.
    private static func stripEmbeddedAnimation(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            node.removeAllAnimations()
            node.removeAllActions()
        }
    }

    /// `SCNNode.clone()` shares geometry *and* materials with the template. The
    /// damage/thermal overlay writes emission straight onto a component's materials,
    /// so shared instances would tint each other — a hot motor on the flown aircraft
    /// lighting up the same motor on every selection card.
    private static func giveInstanceItsOwnMaterials(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let copy = geometry.copy() as? SCNGeometry else { return }
            copy.materials = geometry.materials.compactMap { $0.copy() as? SCNMaterial }
            node.geometry = copy
        }
    }

    /// Stops drawing surface detail once it is too small on screen to be seen.
    ///
    /// These models are detailed at the fastener level — 55% of every airframe's nodes
    /// are screws, cooling grooves, vent slots and seams — and the chase camera's
    /// distance scales with the aircraft, so the biggest airframes pay the most for
    /// them. The MQ-9B is 27 m across the diagonal, which puts the chase camera 134 m
    /// back (`subjectScale * 5.6`) against 7 m for a Mavic: at that range its 3 cm
    /// wheel bolts are a fraction of a pixel each, and there are 68 such nodes.
    ///
    /// The cut is made by SceneKit itself, per node, on the render thread: an empty
    /// level of detail below a screen radius draws nothing. There is no per-frame work
    /// here and no distance bookkeeping to get wrong.
    ///
    /// Two numbers, both stated rather than tuned. **Two pixels** of projected radius is
    /// the point below which a part covers about four by four pixels and can no longer
    /// show a shape. **A tenth of the airframe's diagonal** is what counts as detail at
    /// all — wings, fuselage and tail keep drawing at any range, so the aircraft never
    /// thins out into nothing, however far away it is.
    private static func cullSurfaceDetailWhenTiny(_ root: SCNNode, airframeExtent: SIMD3<Float>) {
        let detailLimit = simd_length(airframeExtent) * 0.10
        guard detailLimit > 0.0001 else { return }
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let box = node.boundingBox
            let size = SIMD3<Float>(
                Float(box.max.x - box.min.x),
                Float(box.max.y - box.min.y),
                Float(box.max.z - box.min.z)
            )
            guard max(size.x, max(size.y, size.z)) < detailLimit else { return }
            geometry.levelsOfDetail = [SCNLevelOfDetail(geometry: nil, screenSpaceRadius: 2.0)]
        }
    }

    private static func enableShadows(_ root: SCNNode) {
        root.enumerateHierarchy { node, _ in
            node.castsShadow = true
        }
    }

    // MARK: - Rotors

    /// Wraps one authored rotor in a node the simulator can spin.
    ///
    /// `DroneSceneController` turns every propeller by assigning `eulerAngles.y`, so a
    /// disc has to sit in a frame whose local +Y *is* its shaft. That is already true
    /// of a lifting rotor; a tractor or pusher turns about the aircraft's +Z, so its
    /// shaft has to be aimed there first.
    ///
    /// ⚠️ Aiming it by putting the quarter-turn pitch on the *same* node the simulator
    /// writes to does not work, however natural it looks. SceneKit composes an Euler
    /// triple as `Rz · Ry · Rx` — the pitch is applied to the geometry **first** and the
    /// yaw afterwards, in the parent's frame — so `eulerAngles = (π/2, θ, 0)` turns the
    /// disc about the parent's +Y no matter what the pitch is, and a forward-facing
    /// propeller tumbles end over end instead of spinning. Measured: a blade tip at
    /// (1,0,0) traced the XZ plane, which is rotation about Y.
    ///
    /// So the aim goes on a separate parent. `mount` carries the rotor's position and
    /// the quarter turn that puts its own +Y along the shaft; `spin` sits underneath it
    /// with no rotation of its own and is the only node the simulator touches; the
    /// rotor is counter-rotated back under `spin` so the geometry is unchanged at rest.
    /// The composition is then `Rx(π/2) · Ry(θ) · Rx(−π/2)`, which is a turn of θ about
    /// the aircraft's +Z — the axis the file's own animation uses.
    private static func makeSpinNode(for rotorNode: SCNNode, axis: String) -> SCNNode {
        let parent = rotorNode.parent
        let originalPosition = rotorNode.simdPosition
        let originalOrientation = rotorNode.simdOrientation
        let isLongitudinal = axis.lowercased() == "z"

        let mountNode = SCNNode()
        mountNode.name = "rotorMount.\(rotorNode.name ?? "rotor")"
        mountNode.simdPosition = originalPosition
        mountNode.eulerAngles = SCNVector3(isLongitudinal ? CGFloat.pi / 2.0 : 0.0, 0.0, 0.0)

        let spinNode = SCNNode()
        spinNode.name = "propeller.\(rotorNode.name ?? "rotor")"
        mountNode.addChildNode(spinNode)

        let frame = isLongitudinal
            ? simd_quatf(angle: .pi / 2.0, axis: SIMD3<Float>(1, 0, 0))
            : simd_quatf(angle: 0.0, axis: SIMD3<Float>(0, 1, 0))

        rotorNode.removeFromParentNode()
        rotorNode.simdPosition = .zero
        rotorNode.simdOrientation = simd_inverse(frame) * originalOrientation
        spinNode.addChildNode(rotorNode)
        parent?.addChildNode(mountNode)
        return spinNode
    }

    // MARK: - Damage component mapping

    private struct Corner {
        let motor: DamageComponent
        let propeller: DamageComponent
        let arm: DamageComponent
    }

    /// Which quadrant a part sits in, named so that it agrees with the physics graph.
    ///
    /// ⚠️ Two things here are easy to get backwards, and both were.
    ///
    /// **The hand.** An aircraft's starboard side is `forward × up`; in the authoring
    /// frame these models use — nose +Z, up +Y — that comes out −X, so the aircraft's
    /// *left* is +X. `DroneModelBuilder` then yaws the model by π, putting the nose at −Z
    /// and the left wing at −X, which is the frame
    /// `VehicleComponentGraphBuilder.quadrantSlot` names quadrants in. The procedural
    /// builders in `UAVVisualFactory` use the opposite hand (`.armFL` sits at x = −0.079
    /// on the FPV frame) and copying them mirrored every bucket on all fifty-five
    /// aircraft: damaging the front-left motor hid the front-right propeller.
    ///
    /// **The origin.** The split runs through the model's bounds centre, not through
    /// zero, because that is what the graph divides on. They differ: the Matrice 350's
    /// centre is 0.1 m off-axis because its blades are frozen at an azimuth, and a rotor
    /// on the centreline then falls on opposite sides of the two tests. Every remaining
    /// mismatch after the hand was fixed was exactly that — a propeller at x = 0.
    /// `extent` is the airframe's bounding size, used only for the centreline dead band
    /// — the mirror image of the one in `VehicleComponentGraphBuilder.quadrantSlot`, so
    /// a part with no side lands in the same bucket on both sides (right, and rear).
    private static func corner(
        of position: SIMD3<Float>,
        centre: SIMD3<Float>,
        extent: SIMD3<Float>
    ) -> Corner {
        let left = position.x - centre.x > max(1e-4, extent.x * 1e-3)
        let front = position.z - centre.z > max(1e-4, extent.z * 1e-3)
        switch (left, front) {
        case (true, true): return Corner(motor: .motorFL, propeller: .propellerFL, arm: .armFL)
        case (false, true): return Corner(motor: .motorFR, propeller: .propellerFR, arm: .armFR)
        case (true, false): return Corner(motor: .motorRL, propeller: .propellerRL, arm: .armRL)
        case (false, false): return Corner(motor: .motorRR, propeller: .propellerRR, arm: .armRR)
        }
    }

    /// Sorts the model's meshes into the legacy damage buckets by name and position.
    ///
    /// The buckets are not cosmetic. `VehicleComponentGraphBuilder` reads the union of
    /// `.armFL` + `.armFR` as *the wing envelope* of a fixed-wing aircraft — its span,
    /// chord and thickness — so the front arm pair must hold the lifting surfaces and
    /// nothing else. Empennage, booms and fins go to the rear pair, which is what the
    /// procedural fixed-wing builders already did with their tailplanes.
    private static func mapDamageComponents(
        in root: SCNNode,
        skipping rotorSubtrees: [SCNNode],
        centre: SIMD3<Float>,
        extent: SIMD3<Float>,
        into componentNodes: inout [DamageComponent: [SCNNode]]
    ) {
        let skipped = Set(rotorSubtrees.map(ObjectIdentifier.init))

        func walk(_ node: SCNNode) {
            if skipped.contains(ObjectIdentifier(node)) { return }
            if node.geometry != nil, let component = classify(node, centre: centre, extent: extent) {
                componentNodes[component, default: []].append(node)
            }
            for child in node.childNodes { walk(child) }
        }
        walk(root)
    }

    /// Axis-aligned centre and extent of everything under `node`, in that node's frame.
    private static func boundsCentreAndExtent(of node: SCNNode) -> (centre: SIMD3<Float>, extent: SIMD3<Float>) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false
        func walk(_ current: SCNNode) {
            if current.geometry != nil {
                let box = current.boundingBox
                let a = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
                let b = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
                for corner in [
                    SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(a.x, a.y, b.z),
                    SIMD3<Float>(a.x, b.y, a.z), SIMD3<Float>(a.x, b.y, b.z),
                    SIMD3<Float>(b.x, a.y, a.z), SIMD3<Float>(b.x, a.y, b.z),
                    SIMD3<Float>(b.x, b.y, a.z), SIMD3<Float>(b.x, b.y, b.z)
                ] {
                    let inNode = node.simdConvertPosition(corner, from: current)
                    low = simd_min(low, inNode)
                    high = simd_max(high, inNode)
                }
                found = true
            }
            for child in current.childNodes { walk(child) }
        }
        walk(node)
        guard found else { return (.zero, SIMD3<Float>(repeating: 1.0)) }
        return ((low + high) * 0.5, simd_max(high - low, SIMD3<Float>(repeating: 0.001)))
    }

    private static func classify(
        _ node: SCNNode,
        centre modelCentre: SIMD3<Float>,
        extent modelExtent: SIMD3<Float>
    ) -> DamageComponent? {
        let name = (node.name ?? "").lowercased()
        guard !name.isEmpty else { return .flightControllerCore }

        let box = node.boundingBox
        let centre = SIMD3<Float>(
            Float(box.min.x + box.max.x) * 0.5,
            Float(box.min.y + box.max.y) * 0.5,
            Float(box.min.z + box.max.z) * 0.5
        )
        // Same hand, origin and dead band as `corner(of:centre:extent:)` above.
        let left = centre.x - modelCentre.x > max(1e-4, modelExtent.x * 1e-3)

        func contains(_ needles: [String]) -> Bool {
            needles.contains { name.contains($0) }
        }

        // Order is load-bearing, because these are substring tests on names that
        // overlap. `WingtipFin` is a wing, not a fin; `CameraCoolingFin` is optics, not
        // an empennage; `WheelHub` is landing gear, not a propeller hub. Each of those
        // is settled by testing the more specific bucket first.

        // The main plane, and only the main plane — this bucket *is* the wing envelope
        // the fixed-wing graph measures span, chord and thickness from. A canard sits
        // several metres ahead of the wing, so letting one in stretches that envelope
        // from the canard's leading edge to the wing's trailing edge: on the X-10 it
        // turned a 10.8 m chord into 14.3 m. Canards go with the other control surfaces
        // below, whose boxes the graph does not read.
        if contains(["wing"]) {
            return left ? .armFL : .armFR
        }
        // Landing gear stays unmapped, exactly as in the procedural rigs: the legs are
        // drawn but are not a damage component, and mapping them would put the wheels
        // inside whichever structural bucket claimed them.
        if contains(["gear", "wheel", "tyre", "tire", "strut", "skid", "leg", "foot"]) {
            return nil
        }
        if contains(["camera", "gimbal", "lens", "optic", "turret", "focal", "sensor", "fpv", "glass"]) {
            return .frontCameraGimbal
        }
        // Empennage, canards and the structure that carries them.
        if contains(["tail", "stabil", "elevator", "rudder", "fin", "boom", "empennage", "canard"]) {
            return left ? .armRL : .armRR
        }
        if contains(["motor"]) {
            return corner(of: centre, centre: modelCentre, extent: modelExtent).motor
        }
        if contains(["blade", "prop", "rotor", "pusher", "tractor", "hub"]) {
            return corner(of: centre, centre: modelCentre, extent: modelExtent).propeller
        }
        // Arms, ducts, guards and the rest of the load path out to the motors.
        if contains(["arm", "duct", "cage", "guard", "spoke", "pylon", "spar", "brace", "tower"]) {
            return corner(of: centre, centre: modelCentre, extent: modelExtent).arm
        }
        if contains(["battery", "cell", "pack", "fuel", "tank"]) {
            return .battery
        }
        if contains(["esc", "board", "stack", "connector", "lead", "wire", "led", "lamp", "light", "antenna", "gnss"]) {
            return .escPower
        }
        return .flightControllerCore
    }

    // MARK: - FPV anchor

    /// Where the pilot's camera sits.
    ///
    /// The optics if the model has any — a nose pod, a belly turret, a gimbal — because
    /// that is where the aircraft's own camera actually is, and because the same
    /// position becomes the `cameraGimbal` component in the physics graph. Falling back
    /// to a point forward of centre keeps a camera-less airframe (a target drone, a
    /// loitering munition) looking where it is going.
    private static func fpvAnchorPosition(in root: SCNNode) -> SIMD3<Float> {
        var opticsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var opticsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var foundOptics = false

        var modelMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var modelMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var foundGeometry = false

        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let box = node.boundingBox
            let low = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let high = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))

            let name = (node.name ?? "").lowercased()
            let isOptics = ["fpvcamera", "camerahousing", "sensorturret", "gimbal", "opticalglass", "lensrim", "focalring"]
                .contains { name.contains($0) }

            for corner in [
                SIMD3<Float>(low.x, low.y, low.z), SIMD3<Float>(low.x, low.y, high.z),
                SIMD3<Float>(low.x, high.y, low.z), SIMD3<Float>(low.x, high.y, high.z),
                SIMD3<Float>(high.x, low.y, low.z), SIMD3<Float>(high.x, low.y, high.z),
                SIMD3<Float>(high.x, high.y, low.z), SIMD3<Float>(high.x, high.y, high.z)
            ] {
                let inRoot = root.simdConvertPosition(corner, from: node)
                modelMin = simd_min(modelMin, inRoot)
                modelMax = simd_max(modelMax, inRoot)
                guard isOptics else { continue }
                opticsMin = simd_min(opticsMin, inRoot)
                opticsMax = simd_max(opticsMax, inRoot)
            }
            foundGeometry = true
            foundOptics = foundOptics || isOptics
        }

        if foundOptics {
            let centre = (opticsMin + opticsMax) * 0.5
            return SIMD3<Float>(0.0, centre.y, opticsMax.z)
        }
        guard foundGeometry else { return .zero }
        let centre = (modelMin + modelMax) * 0.5
        return SIMD3<Float>(0.0, centre.y, centre.z + (modelMax.z - centre.z) * 0.55)
    }
}
