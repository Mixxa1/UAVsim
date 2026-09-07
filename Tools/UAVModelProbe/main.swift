import Foundation
import SceneKit
import simd

// Headless check of the bundled USDZ airframe library against the catalogue.
//
// The app has no test target, so this compiles the Domain layer (via
// Tools/probe-sources.sh) together with `UAVModelAssetLibrary` and the stand-in for
// `DroneVisualModel` below — the real struct lives in `DroneModelBuilder`, which drags
// the whole Scene and Services layers in with it.
//
// What it checks, in the order these things have gone wrong here before:
//
//  1. Every catalogue profile resolves to a model.
//  2. Rotor extraction: the manifest's rotors are all found, none keeps its imported
//     display animation, and spinning the wrapper about its local +Y turns the disc in
//     its own plane instead of tumbling it or walking the hub off the motor axis.
//  3. The wing bucket. `VehicleComponentGraphBuilder` reads the union of .armFL/.armFR
//     as the fixed-wing *wing envelope* — its span, chord and thickness — so an
//     empennage or a fuselage landing in that bucket silently redefines the aeroplane.
//  4. Model span against the catalogue span the physics flies. A visual that disagrees
//     with it is the defect that put a scene-scale inertia tensor under three aircraft.
//
// Run: Tools/UAVModelProbe/run.sh [--verbose]

// MARK: - Stand-in for the Scene layer's DroneVisualModel

struct DroneVisualModel {
    let rootNode: SCNNode
    let propellerNodes: [SCNNode]
    let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]
    let fpvAnchorNode: SCNNode
    let payloadMountNode: SCNNode
    let visualBoundsCenter: SIMD3<Float>
    let visualBoundsSize: SIMD3<Float>
    let tiltPivotNodes: [SCNNode]

    init(
        rootNode: SCNNode,
        propellerNodes: [SCNNode],
        propellerSpinDirections: [Float],
        componentNodes: [DamageComponent: [SCNNode]],
        fpvAnchorNode: SCNNode,
        payloadMountNode: SCNNode,
        visualBoundsCenter: SIMD3<Float> = .zero,
        visualBoundsSize: SIMD3<Float> = SIMD3<Float>(repeating: 0.36),
        tiltPivotNodes: [SCNNode] = []
    ) {
        self.rootNode = rootNode
        self.propellerNodes = propellerNodes
        self.propellerSpinDirections = propellerSpinDirections
        self.componentNodes = componentNodes
        self.fpvAnchorNode = fpvAnchorNode
        self.payloadMountNode = payloadMountNode
        self.visualBoundsCenter = visualBoundsCenter
        self.visualBoundsSize = visualBoundsSize
        self.tiltPivotNodes = tiltPivotNodes
    }
}

// MARK: - Setup

let verbose = CommandLine.arguments.contains("--verbose")

// The probe is not an app bundle, so point the library at the checked-in resources.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let modelsDirectory = repoRoot.appendingPathComponent("DroneUAVDemo/Resources/Models/UAVModels")

guard FileManager.default.fileExists(atPath: modelsDirectory.path) else {
    print("FAIL  model directory missing: \(modelsDirectory.path)")
    exit(1)
}

let library = UAVModelAssetLibrary(directory: modelsDirectory)
let profiles = UAVReferenceCatalog.realProfiles

var failures: [String] = []
var notes: [String] = []

func fail(_ message: String) { failures.append(message) }
func note(_ message: String) { notes.append(message) }

/// Axis-aligned bounds of everything under `node`, expressed in `reference`'s space.
func bounds(of node: SCNNode, in reference: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
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
                let converted = reference.simdConvertPosition(corner, from: current)
                low = simd_min(low, converted)
                high = simd_max(high, converted)
            }
            found = true
        }
        for child in current.childNodes { walk(child) }
    }
    walk(node)
    return found ? (low, high) : nil
}

/// A blade tip as a *material point*: the node it belongs to plus its position in that
/// node's own coordinates.
///
/// ⚠️ It has to be a fixed point, not "whichever corner is currently furthest out". A
/// two-blade propeller has a second tip 180° away, so re-running a furthest-point search
/// after the turn silently reports a different blade and the direction comes out random.
func bladeReference(
    of spinNode: SCNNode,
    in reference: SCNNode,
    shaftAxis: Int
) -> (node: SCNNode, local: SIMD3<Float>)? {
    let hub = reference.simdConvertPosition(.zero, from: spinNode)
    var best: (SCNNode, SIMD3<Float>)?
    var bestRadius: Float = 0.0
    func walk(_ node: SCNNode) {
        if node.geometry != nil {
            let box = node.boundingBox
            let a = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let b = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            for corner in [
                SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(a.x, a.y, b.z),
                SIMD3<Float>(a.x, b.y, a.z), SIMD3<Float>(a.x, b.y, b.z),
                SIMD3<Float>(b.x, a.y, a.z), SIMD3<Float>(b.x, a.y, b.z),
                SIMD3<Float>(b.x, b.y, a.z), SIMD3<Float>(b.x, b.y, b.z)
            ] {
                var offset = reference.simdConvertPosition(corner, from: node) - hub
                offset[shaftAxis] = 0.0
                let radius = simd_length(offset)
                if radius > bestRadius { bestRadius = radius; best = (node, corner) }
            }
        }
        for child in node.childNodes { walk(child) }
    }
    walk(spinNode)
    return bestRadius > 0.001 ? best : nil
}

// MARK: - 1. Coverage

let profileIDs = Set(profiles.map { $0.id })
let modelIDs = Set(library.coveredIDs)

for id in profileIDs.subtracting(modelIDs).sorted() {
    fail("no bundled model for catalogue profile '\(id)'")
}
for id in modelIDs.subtracting(profileIDs).sorted() {
    note("model '\(id)' has no catalogue profile")
}
print("coverage: \(profileIDs.count) profiles, \(modelIDs.count) models, \(profileIDs.intersection(modelIDs).count) matched")

// MARK: - Per-aircraft checks

var checked = 0
var totalRotors = 0

for profile in profiles.sorted(by: { $0.id < $1.id }) {
    guard let visual = library.makeVisualModel(
        profileID: profile.id,
        payloadMountOffset: profile.payloadMountOffset
    ) else {
        continue  // already reported as a coverage failure
    }
    checked += 1

    // Bounds through a stand-in parent, the way `DroneModelBuilder.wrapVisualModel`
    // measures them — measuring inside the model's own frame reads it before the yaw
    // flip and negates the centre's x and z.
    let measuringParent = SCNNode()
    measuringParent.addChildNode(visual.rootNode)
    guard let box = bounds(of: measuringParent, in: measuringParent) else {
        fail("\(profile.id): model has no geometry")
        continue
    }
    visual.rootNode.removeFromParentNode()
    let size = box.max - box.min

    // 2. Rotors.
    let manifestRotorCount = library.rotorCount(for: profile.id)
    if visual.propellerNodes.count != manifestRotorCount {
        fail("\(profile.id): \(visual.propellerNodes.count) rotor nodes extracted, manifest declares \(manifestRotorCount)")
    }
    if visual.propellerSpinDirections.count != visual.propellerNodes.count {
        fail("\(profile.id): \(visual.propellerSpinDirections.count) spin directions for \(visual.propellerNodes.count) rotors")
    }
    totalRotors += visual.propellerNodes.count

    var liveAnimations = 0
    visual.rootNode.enumerateHierarchy { node, _ in
        liveAnimations += node.animationKeys.count
    }
    if liveAnimations > 0 {
        fail("\(profile.id): \(liveAnimations) imported animations survived import")
    }

    // Does spinning the wrapper actually turn the disc in its own plane?
    //
    // ⚠️ Measure in the *model* frame, never in the spin node's own. An earlier version
    // of this check took the bounds `in: spinNode`, where the node's own rotation is by
    // definition invisible — it passed every aircraft while forward-facing propellers
    // were tumbling end over end in the app. The shaft is the axis the disc is thinnest
    // along; a disc turning about its shaft keeps its extent along it.
    for (index, spinNode) in visual.propellerNodes.enumerated() {
        guard let before = bounds(of: spinNode, in: visual.rootNode) else {
            fail("\(profile.id): rotor \(index) has no geometry")
            continue
        }
        let hubBefore = visual.rootNode.simdConvertPosition(.zero, from: spinNode)
        spinNode.eulerAngles.y = CGFloat(Float.pi / 3.0)
        let hubAfter = visual.rootNode.simdConvertPosition(.zero, from: spinNode)
        guard let after = bounds(of: spinNode, in: visual.rootNode) else {
            spinNode.eulerAngles.y = 0.0
            continue
        }
        spinNode.eulerAngles.y = 0.0

        let hubDrift = simd_length(hubAfter - hubBefore)
        if hubDrift > 0.0005 {
            fail(String(format: "%@: rotor %d hub moved %.4f m when spun", profile.id, index, hubDrift))
        }

        let spanBefore = before.max - before.min
        let spanAfter = after.max - after.min
        let shaftAxis = (0..<3).min(by: { spanBefore[$0] < spanBefore[$1] })!
        let growth = spanAfter[shaftAxis] - spanBefore[shaftAxis]
        if growth > max(0.004, spanBefore[shaftAxis] * 0.5) {
            let names = ["X", "Y", "Z"]
            fail(String(
                format: "%@: rotor %d grew %.3f m along its %@ shaft when spun (%.3f -> %.3f) — it is tumbling, not spinning",
                profile.id, index, growth, names[shaftAxis] as NSString,
                spanBefore[shaftAxis], spanAfter[shaftAxis]
            ))
        }

        // And it must turn the way the file's own animation turns. The manifest's
        // `direction` is the sign of the authored rotation, and the simulator feeds it
        // straight into the spin angle, so a positive direction has to advance the disc
        // positively about its shaft.
        let declared = index < visual.propellerSpinDirections.count
            ? visual.propellerSpinDirections[index] : 1.0
        guard let blade = bladeReference(of: spinNode, in: visual.rootNode, shaftAxis: shaftAxis) else { continue }
        let hub = visual.rootNode.simdConvertPosition(.zero, from: spinNode)
        var tipBefore = visual.rootNode.simdConvertPosition(blade.local, from: blade.node) - hub
        spinNode.eulerAngles.y = CGFloat(declared * Float.pi / 6.0)
        var tipAfter = visual.rootNode.simdConvertPosition(blade.local, from: blade.node) - hub
        spinNode.eulerAngles.y = 0.0
        tipBefore[shaftAxis] = 0.0
        tipAfter[shaftAxis] = 0.0
        // Signed turn about the shaft, right-handed.
        let turn = simd_cross(tipBefore, tipAfter)[shaftAxis]
        if turn * declared < 0 {
            fail(String(
                format: "%@: rotor %d turns against its declared direction %+.0f",
                profile.id, index, declared
            ))
        }
    }

    // 2b. Reaction torque.
    // Imported motor/propeller rigs must consume the same 0..pi/2 servo signal
    // as procedural rigs, including Trinity's cruise-authored basis and the
    // opposing front/rear Wingcopter hinge directions.
    let expectedTilts = ["wingcopter-198": 4, "quantum-systems-trinity-pro": 3][profile.id] ?? 0
    if visual.tiltPivotNodes.count != expectedTilts {
        fail("\(profile.id): expected \(expectedTilts) tilt pivots, found \(visual.tiltPivotNodes.count)")
    }
    for pivot in visual.tiltPivotNodes {
        let rest = pivot.simdTransform
        let origin = pivot.simdWorldPosition
        let children = visual.propellerNodes.filter { rotor in
            var parent = rotor.parent
            while let p = parent {
                if p === pivot { return true }
                parent = p.parent
            }
            return false
        }
        if children.count != 1 { fail("\(profile.id): tilt assembly must own exactly one spinning propeller") }
        let radii = children.map { simd_length($0.simdWorldPosition - origin) }
        for fraction: Float in [0, 0.25, 0.5, 0.75, 1] {
            pivot.eulerAngles.x = CGFloat(fraction * .pi / 2)
            if simd_length(pivot.simdWorldPosition - origin) > 0.00001 {
                fail("\(profile.id): moving hinge anchor")
            }
            for (index, rotor) in children.enumerated() {
                if abs(simd_length(rotor.simdWorldPosition - origin) - radii[index]) > 0.00001 {
                    fail("\(profile.id): motor/rotor lost rigid attachment during transition")
                }
                let shaft = simd_normalize(rotor.simdConvertVector(SIMD3<Float>(0,1,0), to: visual.rootNode))
                if fraction == 0 && abs(shaft.y) < 0.999 { fail("\(profile.id): hover shaft is not vertical") }
                if fraction == 1 && abs(shaft.z) < 0.999 { fail("\(profile.id): cruise shaft is not longitudinal") }
                let hub = rotor.simdWorldPosition
                rotor.eulerAngles.y = 1.1
                if simd_length(rotor.simdWorldPosition - hub) > 0.00001 { fail("\(profile.id): spinning hub orbits tilted motor") }
                rotor.eulerAngles.y = 0
            }
        }
        pivot.simdTransform = rest
    }

    // 2b. Reaction torque.
    //
    // `VehicleRotorModel` yaws the aircraft by biasing rotors against their own
    // `spinSign`, so a rotorcraft whose discs do not cancel flies with a standing
    // torque it can never trim out. An even-numbered set has to sum to zero; an odd one
    // (the Trinity Pro's three) cannot, and balances by other means.
    let runtime = LIPODroneModelRepository.runtimeProfile(from: profile)
    let isRotorcraft = runtime.airframeClass == .multirotor || runtime.airframeClass == .hybridVTOL
    if isRotorcraft,
       visual.propellerNodes.count > 1,
       visual.propellerNodes.count.isMultiple(of: 2) {
        let net = visual.propellerSpinDirections.reduce(0.0, +)
        if net != 0.0 {
            fail(String(
                format: "%@: %d rotors with a net spin of %+.0f — the airframe cannot trim its own torque",
                profile.id, visual.propellerNodes.count, net
            ))
        }
    }

    // 3. Wing bucket.
    //
    // No chord test here on purpose. The fleet runs from a straight-winged Aerosonde
    // to a tailless delta, and across that range there is no chord-to-span ratio that
    // separates "the bucket swallowed the fuselage" from "this aeroplane really is a
    // delta" — the X-10's own wing is wider fore-and-aft than it is across. What *is*
    // true of every fixed-wing aircraft here is that the wing is the widest thing on
    // it: only winglets and tip fins reach past it, by centimetres. A bucket spanning
    // materially less than the airframe is therefore not the wing, whatever shape it is.
    let wingNodes = (visual.componentNodes[.armFL] ?? []) + (visual.componentNodes[.armFR] ?? [])
    var wingChordRatio: Float = 0.0
    if runtime.airframeClass != .multirotor {
        if wingNodes.isEmpty {
            fail("\(profile.id): fixed-wing airframe with an empty .armFL/.armFR wing bucket")
        } else {
            var wingLow = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var wingHigh = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            for node in wingNodes {
                guard let nodeBox = bounds(of: node, in: visual.rootNode) else { continue }
                wingLow = simd_min(wingLow, nodeBox.min)
                wingHigh = simd_max(wingHigh, nodeBox.max)
            }
            let wingSpan = wingHigh.x - wingLow.x
            wingChordRatio = (wingHigh.z - wingLow.z) / max(0.001, wingSpan)
            if wingSpan < size.x * 0.8 {
                fail(String(
                    format: "%@: wing bucket spans %.2f m of a %.2f m airframe — that is not the wing",
                    profile.id, wingSpan, size.x
                ))
            }
        }
    }

    // 4. Span against the catalogue.
    let catalogSpanMm = profile.dimensions.resolvedUnfoldedMillimeters(
        fallback: DroneDimensionsMM(x: size.x * 1000.0, y: size.z * 1000.0, z: size.y * 1000.0)
    ).x
    let ratio = size.x / max(0.001, catalogSpanMm / 1000.0)
    // Models are anchored to catalogue dimensions where those exist, but a rotorcraft's
    // published width excludes its propeller discs while the model draws them, so the
    // rendered envelope legitimately runs wider. Past double it is not that.
    if ratio > 2.0 || ratio < 0.5 {
        fail(String(
            format: "%@: model spans %.2f m against a catalogue %.2f m (x%.2f)",
            profile.id, size.x, catalogSpanMm / 1000.0, ratio
        ))
    }

    // 5. The physics the model produces.
    //
    // This is the part of the swap that is not cosmetic. `VehicleComponentGraphBuilder`
    // reads the rendered geometry and returns the mass distribution, the rotor slots
    // and the contact spheres the flight model then runs on, so an authored airframe
    // that renders beautifully and lands its wheels a metre underground is still a
    // defect. The wrapping below reproduces what `DroneModelBuilder.wrapVisualModel`
    // does — the chase-camera yaw flip, then a lift that puts the lowest geometry at
    // y = 0 — because the sample is captured in that frame, not in the authoring frame.
    if runtime.airframeClass == .multirotor
        || runtime.airframeClass == .fixedWing
        || runtime.airframeClass == .hybridVTOL {
        visual.rootNode.eulerAngles.y = CGFloat(Float.pi)
    }
    let groundLift = max(0.0, -box.min.y)
    let liftedMin = box.min + SIMD3<Float>(0.0, groundLift, 0.0)
    let liftedMax = box.max + SIMD3<Float>(0.0, groundLift, 0.0)

    let flightRoot = SCNNode()
    let visualRoot = SCNNode()
    visual.rootNode.removeFromParentNode()
    visual.rootNode.simdPosition += SIMD3<Float>(0.0, groundLift, 0.0)
    visualRoot.addChildNode(visual.rootNode)
    flightRoot.addChildNode(visualRoot)

    let wrapped = DroneVisualModel(
        rootNode: flightRoot,
        propellerNodes: visual.propellerNodes,
        propellerSpinDirections: visual.propellerSpinDirections,
        componentNodes: visual.componentNodes,
        fpvAnchorNode: visual.fpvAnchorNode,
        payloadMountNode: visual.payloadMountNode,
        visualBoundsCenter: (liftedMin + liftedMax) * 0.5,
        visualBoundsSize: simd_max(liftedMax - liftedMin, SIMD3<Float>(repeating: 0.001))
    )

    let sample = DroneVisualGeometrySample.capture(from: wrapped)
    let built = VehicleComponentGraphBuilder.build(
        profile: runtime,
        vehicleMassModel: VehicleMassModel.baseline(for: runtime, uavProfile: profile),
        geometry: sample
    )

    if built.rotorModel.rotors.count != visual.propellerNodes.count {
        fail("\(profile.id): graph has \(built.rotorModel.rotors.count) rotor slots for \(visual.propellerNodes.count) visual rotors")
    }

    let graphMass = built.graph.massProperties.totalMassKg
    let expectedMass = VehicleMassModel.baseline(for: runtime, uavProfile: profile).effectiveMass
    if abs(graphMass - expectedMass) > max(0.05, expectedMass * 0.02) {
        fail(String(
            format: "%@: graph mass %.1f kg against an expected %.1f kg",
            profile.id, graphMass, expectedMass
        ))
    }

    // 5a. The VTOL tilt hinges.
    //
    // `DroneSceneController.updatePropulsionUnitVisuals` writes one number onto every
    // pivot: `PropulsionUnit.tiltAngleRad`, where 0 is hover — thrust along body +Y,
    // rotor plane horizontal — and π/2 is cruise, thrust along body −Z. Body −Z is the
    // model's +Z, so a hinge is correct exactly when driving it to 0 leaves the disc
    // spinning about the model's Y and driving it to π/2 leaves it spinning about Z.
    //
    // The files are authored the other way round for viewing: their own animation
    // starts in hover with the hinge already at −90°. That baked pose is normalised out
    // on import, so this checks the normalisation rather than trusting it.
    if let transition = library.transitionSummary(for: profile.id) {
        if visual.tiltPivotNodes.count != transition.pivotCount {
            fail("\(profile.id): \(visual.tiltPivotNodes.count) tilt drivers built for \(transition.pivotCount) declared hinges (\(transition.mechanism))")
        }
        for (angle, expectedShaft, pose) in [
            (Float(0.0), 1, "hover"), (Float.pi / 2.0, 2, "cruise")
        ] {
            for pivot in visual.tiltPivotNodes { pivot.eulerAngles.x = CGFloat(angle) }
            for (index, spinNode) in visual.propellerNodes.enumerated() {
                // Only the rotors that actually hang off a hinge move with it.
                var hinged = false
                var cursor: SCNNode? = spinNode.parent
                while let node = cursor {
                    if visual.tiltPivotNodes.contains(where: { $0 === node }) { hinged = true; break }
                    cursor = node.parent
                }
                guard hinged else { continue }
                guard let box = bounds(of: spinNode, in: visual.rootNode) else { continue }
                let span = box.max - box.min
                let shaft = (0..<3).min(by: { span[$0] < span[$1] })!
                if shaft != expectedShaft {
                    let names = ["X", "Y", "Z"]
                    fail(String(
                        format: "%@: in %@ rotor %d's shaft points along %@, expected %@",
                        profile.id, pose as NSString, index,
                        names[shaft] as NSString, names[expectedShaft] as NSString
                    ))
                }
                // And it still has to turn in its own plane while tilted.
                let before = span[shaft]
                spinNode.eulerAngles.y = CGFloat(Float.pi / 3.0)
                let after = bounds(of: spinNode, in: visual.rootNode).map { ($0.max - $0.min)[shaft] } ?? before
                spinNode.eulerAngles.y = 0.0
                if after - before > max(0.004, before * 0.5) {
                    fail(String(
                        format: "%@: in %@ rotor %d tumbles instead of spinning (%.3f -> %.3f along its shaft)",
                        profile.id, pose as NSString, index, before, after
                    ))
                }
            }
        }
        for pivot in visual.tiltPivotNodes { pivot.eulerAngles.x = 0.0 }
    }

    // 5b. Does the graph agree with the visual about which motor is which?
    //
    // The two sides label quadrants independently — `UAVModelAssetLibrary.corner` on the
    // authored geometry, `VehicleComponentGraphBuilder.quadrantSlot` on the captured
    // sample — and they have to reach the same answer for every rotor. When they do not,
    // damaging one propeller hides another, and a graph bucket that holds no geometry at
    // all draws a bare box with the debris material instead: a part that was never on
    // the aircraft, dropping onto the runway while the real propeller stays attached.
    // That is the defect the operator photographed, and it affected all fifty-five.
    for (index, spinNode) in visual.propellerNodes.enumerated() {
        let hub = flightRoot.simdConvertPosition(.zero, from: spinNode)
        let graphBucket = built.graph.components
            .filter { if case .propeller = $0.kind { return true }; return false }
            .min(by: { simd_distance($0.localPosition, hub) < simd_distance($1.localPosition, hub) })?
            .legacyComponent
        let visualBucket = visual.componentNodes.first { key, nodes in
            key.rawValue.hasPrefix("propeller") && nodes.contains(where: { $0 === spinNode })
        }?.key
        if graphBucket != visualBucket {
            fail(String(
                format: "%@: rotor %d is %@ to the graph and %@ to the visual",
                profile.id, index,
                (graphBucket?.rawValue ?? "unmapped") as NSString,
                (visualBucket?.rawValue ?? "unmapped") as NSString
            ))
        }
    }

    // Legacy buckets the graph uses that carry no geometry. Reported, not failed: the
    // battery and the ESC are synthetic internals every airframe is given, and no
    // aircraft in this library models its own battery box. Worth seeing, because a
    // component with no geometry is the one that can still drop a bare debris box.
    let graphBuckets = Set(built.graph.components.compactMap(\.legacyComponent))
    let visualBuckets = Set(visual.componentNodes.filter { !$0.value.isEmpty }.keys)
    let emptyBuckets = graphBuckets.subtracting(visualBuckets)
        .subtracting([.battery, .escPower])
        .sorted { $0.rawValue < $1.rawValue }
    if !emptyBuckets.isEmpty {
        note("\(profile.id): graph buckets with no geometry — " +
             emptyBuckets.map(\.rawValue).joined(separator: ", "))
    }

    // How far the contact spheres reach below the origin at rest.
    //
    // Reported, not asserted. It is tempting to demand zero — the wrap puts the lowest
    // geometry on the ground, so surely the lowest sphere belongs there too — but the
    // engine subtracts this very number: `groundClearanceOffset` is normalised against
    // the rest attitude precisely so `position.y == supportY` at rest whatever the
    // sphere discretisation did, and a tailsitter standing on its tail depends on that.
    // Asserting on it would flag the Harpy's coarse spheres and the WingtraOne's
    // nose-up rest pose, neither of which is a defect. What it does influence is how
    // much clearance a *banked* airframe gets near the ground, which is worth being
    // able to read off.
    let rest = VehicleContactProfile.restOrientation(for: runtime.airframeStyle)
    let restOffset = built.contactProfile.lowestPointY(position: .zero, orientation: rest)

    if verbose {
        let components = visual.componentNodes
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: " ")
        let anchor = visual.fpvAnchorNode.simdPosition
        print(String(
            format: "%-30@ span=%7.2fm len=%7.2fm h=%5.2fm x%.2f rotors=%2d chord/span=%.2f fpvZ=%6.2f rest=%+.3f mass=%7.1fkg  %@",
            profile.id as NSString, size.x, size.z, size.y, ratio,
            visual.propellerNodes.count, wingChordRatio, anchor.z, restOffset, graphMass, components
        ))
    }
}

// MARK: - Report

print("checked \(checked) aircraft, \(totalRotors) rotors")
for message in notes { print("note  \(message)") }
for message in failures { print("FAIL  \(message)") }
print(failures.isEmpty ? "OK" : "\(failures.count) failures")
exit(failures.isEmpty ? 0 : 1)
