import AppKit
import SceneKit
import simd
import Metal

struct DroneVisualModel {
    let rootNode: SCNNode; let propellerNodes: [SCNNode]; let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]; let fpvAnchorNode: SCNNode
    let payloadMountNode: SCNNode; let tiltPivotNodes: [SCNNode]
    let visualBoundsCenter: SIMD3<Float>; let visualBoundsSize: SIMD3<Float>
    init(rootNode: SCNNode, propellerNodes: [SCNNode], propellerSpinDirections: [Float],
         componentNodes: [DamageComponent: [SCNNode]], fpvAnchorNode: SCNNode, payloadMountNode: SCNNode,
         tiltPivotNodes: [SCNNode] = [], visualBoundsCenter: SIMD3<Float> = .zero,
         visualBoundsSize: SIMD3<Float> = SIMD3<Float>(repeating: 0.36)) {
        self.rootNode = rootNode; self.propellerNodes = propellerNodes
        self.propellerSpinDirections = propellerSpinDirections; self.componentNodes = componentNodes
        self.fpvAnchorNode = fpvAnchorNode; self.payloadMountNode = payloadMountNode
        self.tiltPivotNodes = tiltPivotNodes; self.visualBoundsCenter = visualBoundsCenter
        self.visualBoundsSize = visualBoundsSize }
}
func bnds(_ node: SCNNode, _ ref: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
    var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude); var found = false
    func walk(_ c: SCNNode) {
        if c.geometry != nil {
            let b = c.boundingBox
            let a = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
            let d = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
            for k in [SIMD3<Float>(a.x,a.y,a.z), SIMD3<Float>(d.x,d.y,d.z), SIMD3<Float>(a.x,d.y,d.z),
                      SIMD3<Float>(d.x,a.y,a.z), SIMD3<Float>(a.x,a.y,d.z), SIMD3<Float>(d.x,d.y,a.z),
                      SIMD3<Float>(a.x,d.y,a.z), SIMD3<Float>(d.x,a.y,d.z)] {
                let v = ref.simdConvertPosition(k, from: c); low = simd_min(low, v); high = simd_max(high, v) }
            found = true }
        for ch in c.childNodes { walk(ch) } }
    walk(node); return found ? (low, high) : nil }


var failures: [String] = []
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !ok() { failures.append(message); print("FAIL: \(message)") }
}
func aircraftState(position: SIMD3<Float> = .zero, velocity: SIMD3<Float> = .zero) -> DroneState {
    DroneState(position: position, velocity: velocity, orientation: .zero, angularVelocity: .zero,
        throttle: 0, motorThrottle: 0, rotorAngularSpeed: .zero, forwardAirspeed: 0,
        physicalState: .airborne, mode: .manual)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let library = UAVModelAssetLibrary(directory: root.appendingPathComponent("DroneUAVDemo/Resources/Models/UAVModels"))
let repository = LIPODroneModelRepository()
let impact = ImpactResolutionService()
let ground = VehicleGroundContactSolver()
let dt: Float = 1 / 90
let renderDamage = CommandLine.arguments.contains("--render")
let surface = CollisionObstacle(id: UUID(), center: SIMD3<Float>(0, -0.5, 0), radius: 10000,
    source: "ground.asphalt", baseY: -1, topY: 0, acousticSurface: .asphalt)
StructuralMemberImpactSolver.debugLog = CommandLine.arguments.contains("--log")

let onlyProfiles = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let verbose = CommandLine.arguments.contains("--trace")
var models = 0

/// Total mechanical energy: translation, rotation (graph inertia, rate order) and the height of
/// the centre of mass — not of `position`, which is the airframe's ground reference and moves
/// with its attitude, so a wreck tipping over would read as energy appearing from nowhere.
func energy(_ s: DroneState, mass: Float, inertiaRates: SIMD3<Float>, com: SIMD3<Float>, rotor: Bool) -> (total: Float, rot: Float) {
    let rates = rotor ? s.angularVelocity : s.bodyAngularVelocity
    let rot = 0.5 * simd_dot(inertiaRates * rates, rates)
    let kin = 0.5 * mass * simd_length_squared(s.velocity)
    let height = s.position.y + simd_act(s.attitudeQuat, com).y
    return (kin + rot + mass * 9.81 * height, rot)
}

for profile in repository.allProfiles where onlyProfiles.isEmpty || onlyProfiles.contains(profile.id) {

    guard let uav = profile.resolvedUAVProfile,
          let visual = library.makeVisualModel(profileID: profile.id, payloadMountOffset: uav.payloadMountOffset)
    else { continue }
    visual.rootNode.eulerAngles.y = CGFloat(Float.pi)
    let mp = SCNNode(); mp.addChildNode(visual.rootNode)
    guard let box = bnds(visual.rootNode, mp) else { continue }
    let liftY = max(0.0, -box.min.y)
    let lo = box.min + SIMD3<Float>(0, liftY, 0), hi = box.max + SIMD3<Float>(0, liftY, 0)
    visual.rootNode.removeFromParentNode()
    let fr = SCNNode(); let vr = SCNNode()
    visual.rootNode.simdPosition += SIMD3<Float>(0, liftY, 0)
    vr.addChildNode(visual.rootNode); fr.addChildNode(vr)
    let wrapped = DroneVisualModel(rootNode: fr, propellerNodes: visual.propellerNodes,
        propellerSpinDirections: visual.propellerSpinDirections, componentNodes: visual.componentNodes,
        fpvAnchorNode: visual.fpvAnchorNode, payloadMountNode: visual.payloadMountNode,
        tiltPivotNodes: visual.tiltPivotNodes, visualBoundsCenter: (lo + hi) * 0.5,
        visualBoundsSize: simd_max(hi - lo, SIMD3<Float>(repeating: 0.001)))
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    let built = VehicleComponentGraphBuilder.build(profile: profile, vehicleMassModel: massModel,
        geometry: DroneVisualGeometrySample.capture(from: wrapped))

    let rest = VehicleContactProfile.restOrientation(for: profile.airframeStyle)
    let lift = built.contactProfile.lowestPointOffset(orientation: rest)
    let origin = SIMD3<Float>(0, lift, 0)

    models += 1
    let rotor = profile.airframeClass == .multirotor
    let cruise = profile.fixedWingParameters?.cruiseAirspeed ?? 10
    struct Scenario { let name: String; let height: Float; let velocity: SIMD3<Float>; let attitude: simd_quatf
                      let rates: SIMD3<Float>; let detach: [String]; let armed: Bool }
    let wingRoot = built.graph.memberChains["wing.right"]?.first
    let tailRoot = built.graph.components.first { $0.kind == .horizontalTail }?.id
    var scenarios: [Scenario] = CommandLine.arguments.contains("--air") ? [
        Scenario(name: "spin in still air", height: 200, velocity: SIMD3<Float>(0, 0, 0),
                 attitude: rest, rates: SIMD3<Float>(9, 0, 0), detach: [], armed: false),
        Scenario(name: "pitch tumble in still air", height: 200, velocity: SIMD3<Float>(0, 0, 0),
                 attitude: rest, rates: SIMD3<Float>(0, 9, 0), detach: [], armed: false),
        Scenario(name: "yaw spin in still air", height: 200, velocity: SIMD3<Float>(0, 0, 0),
                 attitude: rest, rates: SIMD3<Float>(0, 0, 9), detach: [], armed: false),
    ] : [
        Scenario(name: "nose-down 45° 25 m/s", height: 15, velocity: SIMD3<Float>(0, -17.7, -17.7),
                 attitude: simd_quatf(angle: -.pi / 4, axis: SIMD3<Float>(1, 0, 0)) * rest, rates: .zero, detach: [], armed: false),
        Scenario(name: "wreck inverted, spinning", height: 1.0, velocity: SIMD3<Float>(2, 0, -3),
                 attitude: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1)) * rest, rates: SIMD3<Float>(3, 1, 2), detach: [], armed: false),
        Scenario(name: "cruise, disarmed", height: 40, velocity: SIMD3<Float>(0, 0, -cruise),
                 attitude: rest, rates: .zero, detach: [], armed: false),
    ]
    if let wingRoot {
        scenarios.append(Scenario(name: "right wing lost in cruise", height: 60, velocity: SIMD3<Float>(0, 0, -cruise),
                                  attitude: rest, rates: .zero, detach: [wingRoot], armed: true))
    }
    if let tailRoot {
        scenarios.append(Scenario(name: "h-tail lost in cruise", height: 60, velocity: SIMD3<Float>(0, 0, -cruise),
                                  attitude: rest, rates: .zero, detach: [tailRoot], armed: true))
    }
    for scenario in scenarios {
        var graph = built.graph
        var contacts = built.contactProfile
        for id in scenario.detach {
            if let piece = graph.detachSubtree(rootComponentID: id) { contacts = contacts.removing(componentIDs: piece.componentIDs) }
        }
        var s = aircraftState(position: SIMD3<Float>(0, scenario.height, 0), velocity: scenario.velocity)
        s.attitudeQuat = scenario.attitude
        s.orientation = eulerForProbe(scenario.attitude)
        s.bodyAngularVelocity = scenario.rates
        s.angularVelocity = scenario.rates
        s.forwardAirspeed = simd_length(scenario.velocity)
        s.throttle = scenario.armed ? 0.6 : 0; s.motorThrottle = s.throttle
        if scenario.armed { s.armState = .armed }
        let lift = contacts.lowestPointOffset(orientation: rest)
        let origin = SIMD3<Float>(0, lift, 0)
        var preload: [String: VehicleJointLoad] = [:]
        var lastE = Float.nan
        var worstGain: (dE: Float, t: Float, what: String) = (0, 0, "")
        var touchdown: Float? = nil
        var touchdownSpeed: Float = 0
        var restAt: Float? = nil
        var restHold: Float = 0
        var peakRate: Float = 0, lateRate: Float = 0, peakEnergy: Float = 0
        var time: Float = 0
        let steps = Int(20 / dt)
        var armed = scenario.armed
        for _ in 0..<steps {
            let previous = s
            let props = graph.massProperties
            let inertia = SIMD3<Float>(props.inertiaDiagonal.z, props.inertiaDiagonal.x, props.inertiaDiagonal.y)
            // The app disarms a crashed aircraft (`disarm(preserveCrashDynamics:)`); so does this.
            if touchdown != nil { armed = false; s.armState = .disarmed }
            let ctl = DroneControlInput(targetPosition: s.position, targetOrientation: .zero, yawIntent: 0,
                throttle: armed ? 0.6 : 0, isArmed: armed, mode: .manual, controlMode: .stabilized)
            let ctx: DroneSimulationContext = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
                damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
                vehicleMassModel: massModel, vehicleMassProperties: props,
                contactProfile: contacts, rotorModel: built.rotorModel, aeroDamage: FixedWingAeroDamage.build(from: graph))
            var stepContext = ctx
            if !CommandLine.arguments.contains("--nodrag") { stepContext.rotationalDragElements = graph.rotationalDragElements() }
            s = SimpleDronePhysicsEngine().step(state: s, control: ctl, context: stepContext, deltaTime: dt)
            let afterEngine = energy(s, mass: props.totalMassKg, inertiaRates: inertia, com: props.centerOfMassOffset, rotor: rotor).total
            let beforeEngine = energy(previous, mass: props.totalMassKg, inertiaRates: inertia, com: props.centerOfMassOffset, rotor: rotor).total
            let loadState = s
            let reports = ground.resolve(previousState: previous, state: &s, graph: &graph,
                profile: contacts, massProperties: graph.massProperties, airframeClass: profile.airframeClass,
                obstacle: surface, bodyOriginWorldOffset: origin,
                hasWheels: profile.fixedWingParameters?.hasWheeledUndercarriage ?? false,
                rotorsSpinning: armed, deltaTime: dt, jointPreload: preload)
            let afterGround = energy(s, mass: graph.massProperties.totalMassKg, inertiaRates: inertia, com: graph.massProperties.centerOfMassOffset, rotor: rotor).total
            if !reports.isEmpty && touchdown == nil { touchdown = time; touchdownSpeed = simd_length(previous.velocity) }
            let result = UAVStructuralLoadSolver().evaluate(graph: &graph, previousState: previous, state: loadState,
                airframeClass: profile.airframeClass, rotorModel: built.rotorModel, deltaTime: dt,
                sustainedForces: reports.flatMap { $0.sustainedForces })
            preload = result.jointLoads
            for root in graph.failedConnectionRootIDs {
                guard let piece = graph.detachSubtree(rootComponentID: root) else { continue }
                contacts = contacts.removing(componentIDs: piece.componentIDs)
            }
            // Energy bookkeeping only while nothing is powered: then it can only fall.
            if !armed {
                // The whole step: engine and ground together can only take energy out.
                let tickGain = afterGround - beforeEngine
                let scale = max(1, abs(beforeEngine - props.totalMassKg * 9.81 * previous.position.y))
                if tickGain > worstGain.dE {
                    let what = reports.map { r in String(format: "%@ vN=%.2f j=%.1f", r.componentID, r.normalClosingSpeed, r.appliedImpulse) }.joined(separator: "; ")
                    worstGain = (tickGain, time, String(format: "%.0f%% of KE [engine %+.1f, ground %+.1f] %@", tickGain / scale * 100,
                                                        afterEngine - beforeEngine, afterGround - afterEngine, what))
                }
                if CommandLine.arguments.contains("--gains"), tickGain > max(0.5, 0.02 * scale) {
                    let what = reports.map { r in String(format: "%@ vN=%.2f j=%.1f", r.componentID, r.normalClosingSpeed, r.appliedImpulse) }.joined(separator: "; ")
                    print(String(format: "    gain t=%.2f %+.1fJ (%.0f%%) engine %+.1f ground %+.1f |w| %.2f→%.2f v %.2f→%.2f %@", time, tickGain, tickGain / scale * 100,
                                 afterEngine - beforeEngine, afterGround - afterEngine, simd_length(rotor ? previous.angularVelocity : previous.bodyAngularVelocity),
                                 simd_length(rotor ? s.angularVelocity : s.bodyAngularVelocity), simd_length(previous.velocity), simd_length(s.velocity), what))
                }
            }
            lastE = afterGround
            peakEnergy = max(peakEnergy, abs(afterGround - props.totalMassKg * 9.81 * s.position.y))
            let rates = rotor ? s.angularVelocity : s.bodyAngularVelocity
            let rate = simd_length(rates)
            peakRate = max(peakRate, rate)
            if time > 17 { lateRate = max(lateRate, rate) }
            if touchdown != nil, simd_length(s.velocity) < 0.2, rate < 0.2 {
                restHold += dt
                if restHold > 1, restAt == nil { restAt = time - 1 }
            } else { restHold = 0 }
            if verbose, Int(time / dt) % 45 == 0 {
                let upW = simd_act(s.attitudeQuat, SIMD3<Float>(0, 1, 0)), fwdW = simd_act(s.attitudeQuat, SIMD3<Float>(0, 0, -1))
                print(String(format: "    t=%5.2f y=%6.2f v=%5.1f |w|=%5.2f rates=(%5.2f %5.2f %5.2f) up.y=%.2f nose.y=%.2f contacts=%d %@", time, s.position.y,
                             simd_length(s.velocity), rate, rates.x, rates.y, rates.z, upW.y, fwdW.y, reports.count,
                             reports.map { "\($0.componentID):\(String(format: "%.2f", $0.normalClosingSpeed))" }.joined(separator: ",")))
            }
            time += dt
        }
        _ = lastE
        let line = String(format: "%@ | %@: peak|w|=%.1f late|w|=%.2f touchdown=%@ rest=%@ worst gain=%.1fJ at %.2fs by %@",
                          profile.id, scenario.name, peakRate, lateRate,
                          touchdown.map { String(format: "%.2fs", $0) } ?? "-",
                          restAt.map { String(format: "%.2fs", $0) } ?? "never",
                          worstGain.dE, worstGain.t, worstGain.what)
        if verbose || CommandLine.arguments.contains("--list") { print(line) }
        // A wreck comes to rest. Nothing on the ground turns for ever: what holds it up also
        // rubs on it, and the air resists its rotation.
        // Eight seconds is for a crash a wreck can stop from. A hypersonic airframe arriving at
        // three hundred metres a second slides and skips for much longer, and that is not a
        // defect of the contact — what it must not do is turn for ever.
        if let touchdown, touchdownSpeed <= 40 {
            check(restAt != nil && restAt! - touchdown <= 8,
                  "\(profile.id) [\(scenario.name)]: does not come to rest within 8 s of touching down (\(line))")
            check(lateRate < 0.3,
                  "\(profile.id) [\(scenario.name)]: still turning at \(String(format: "%.2f", lateRate)) rad/s after 17 s (\(line))")
        }
        // Unpowered, a step can only take mechanical energy out of the aircraft.
        check(worstGain.dE < 0.05 * max(1, peakEnergy),
              "\(profile.id) [\(scenario.name)]: a step adds \(String(format: "%.0f", worstGain.dE)) J (\(line))")
    }
}

func eulerForProbe(_ q: simd_quatf) -> SIMD3<Float> {
    let f = simd_act(q, SIMD3<Float>(0, 0, -1)), r = simd_act(q, SIMD3<Float>(1, 0, 0))
    return SIMD3<Float>(asin(max(-1, min(1, r.y))), asin(max(-1, min(1, f.y))), atan2(-f.x, -f.z))
}


print("CrashScenarioProbe: \(checks) checks, \(models) aircraft, \(failures.count) failures")
if !failures.isEmpty { exit(1) }
