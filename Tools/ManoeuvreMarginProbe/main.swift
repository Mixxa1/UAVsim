import AppKit
import SceneKit
import simd

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

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let library = UAVModelAssetLibrary(
    directory: root.appendingPathComponent("DroneUAVDemo/Resources/Models/UAVModels"))
let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let solver = UAVStructuralLoadSolver()
let dt: Float = 1.0 / 90.0

// How much manoeuvre an airframe survives before `UAVStructuralLoadSolver` starts eroding
// a joint — measured by raising the load factor at a settled flight condition with nothing
// to hit, and reading which joint yields first.
//
// This exists because the structural loads are assembled from several independently
// plausible pieces — the geometry's areas, the catalogue's wing area, the airframe's lift
// budget, the joint limits — and a change to any one of them silently redistributes the
// others. Correcting the wing area alone once left the empennage carrying 35.7 % of the
// MQ-9B's lift and 55.2 % of the AQM-35A's, which took the MQ-9B's tail margin down to
// 2.0 g; an operator lost the horizontal tail at 217 m in a returnHome turn, with no
// impact in the log. Nothing in a unit test would have caught that, because every piece
// was still individually reasonable. A margin is the thing that is not.
//
// The floor is the transport category's limit load factor (CS-25/FAR-25), which is the
// lowest in civil use — a light airframe is stressed to 3.8 g and an aerobatic one to 6.
// `VehicleComponentGraph` sizes every lifting joint to carry it with the standard 1.5
// ultimate factor, so an airframe that lands below this line is not a weak airframe, it
// is a load the solver is computing that the joint was never sized for.
private let failFloor: Float = 2.5

print("First joint to yield as load factor is raised — every airframe class.")
print("")
print(String(format: "%-27@ %8@  %-20@ %8@  %-20@",
             "aircraft" as NSString, "n_first" as NSString, "joint" as NSString,
             "n_tail" as NSString, "tail joint" as NSString))
print(String(repeating: "-", count: 92))

var failures: [String] = []
for profile in repository.allProfiles {
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
    let cruise = profile.fixedWingParameters?.cruiseAirspeed ?? 20.0
    let density = AtmosphereModel.standard.state(worldY: 217).airDensity

    // The engine publishes the catalogue wing area; one settled step to read it.
    var probeState = DroneState(position: SIMD3<Float>(0, 217, 0), velocity: SIMD3<Float>(0, 0, -cruise),
        orientation: .zero, angularVelocity: .zero, throttle: 0.7, motorThrottle: 0.7,
        rotorAngularSpeed: .zero, forwardAirspeed: cruise, physicalState: .airborne, mode: .autoPath)
    probeState.armState = .armed
    let ctl = DroneControlInput(targetPosition: SIMD3<Float>(0, 217, -8000), targetOrientation: .zero,
        yawIntent: 0, throttle: 0.7, isArmed: true, mode: .autoPath, controlMode: .stabilized)
    let ctx = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
        damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
        vehicleMassModel: massModel, fuelState: nil, fuelPropulsion: nil)
    probeState = engine.step(state: probeState, control: ctl, context: ctx, deltaTime: dt)
    let wingArea = probeState.referenceWingAreaM2
    let thrust = probeState.propulsionThrustNewtons

    var firstN: Float = 0, firstID = "", tailN: Float = 0, tailID = ""
    var n: Float = 1.0
    while n <= 8.0 {
        var graph = built.graph
        // A pure normal acceleration of (n-1)g on top of gravity: specificForce = n·g.
        let aY = (n - 1.0) * 9.81
        var prev = DroneState(position: SIMD3<Float>(0, 217, 0), velocity: SIMD3<Float>(0, 0, -cruise),
            orientation: .zero, angularVelocity: .zero, throttle: 0.7, motorThrottle: 0.7,
            rotorAngularSpeed: .zero, forwardAirspeed: cruise, physicalState: .airborne, mode: .autoPath)
        prev.armState = .armed
        prev.vtolWingborneBlend = profile.airframeClass == .hybridVTOL ? 1.0 : 0.0
        var now = prev
        now.velocity = prev.velocity + SIMD3<Float>(0, aY * dt, 0)
        let result = solver.evaluate(graph: &graph, previousState: prev, state: now,
            airframeClass: profile.airframeClass, rotorModel: built.rotorModel, deltaTime: dt,
            airDensity: density, thermalWeakening: 0, thrustNewtons: thrust,
            referenceWingAreaM2: wingArea)
        if !result.connectionDamage.isEmpty {
            let hit = result.connectionDamage.map(\.childComponentID).sorted()
            if firstN == 0 { firstN = n; firstID = hit.joined(separator: ",") }
            if tailN == 0, let t = hit.first(where: { $0.hasPrefix("tail.") || $0.hasPrefix("elevator") || $0.hasPrefix("rudder") }) {
                tailN = n; tailID = t
            }
            if firstN != 0 && tailN != 0 { break }
        }
        n += 0.1
    }
    print(String(format: "%-27@ %8@  %-20@ %8@  %-20@", profile.id as NSString,
        (firstN == 0 ? ">8.0" : String(format: "%.1f", firstN)) as NSString,
        (firstID.isEmpty ? "-" : firstID) as NSString,
        (tailN == 0 ? ">8.0" : String(format: "%.1f", tailN)) as NSString,
        (tailID.isEmpty ? "-" : tailID) as NSString))
    if firstN > 0, firstN < failFloor {
        failures.append(String(format: "%@ yields at %.1f g (%@)", profile.id, firstN, firstID))
    }
}

// MARK: - Standing still with the throttle up
//
// ⚠️ Zero airspeed is where a propeller makes its greatest thrust, and it was the one
// condition none of the flight probes covered — they started the ground roll at 11.5 m/s
// and flew the climb at cruise. An operator's MQ-9B threw its propeller onto the runway
// before it had moved a metre, and the measurement that finally reproduced it was this
// one: throttle up, brakes on, nothing hit. Fleet at the time: RQ-7B at 1.29 of its mount's
// limit, MQ-9A at 1.10, MQ-9B at 1.05, and the three IAI munitions at 0.88–0.93.
print("")
print("Standing still, throttle up, nothing moving and nothing hit.")
print(String(format: "%-27@ %10@ %10@ %8@", "aircraft" as NSString, "thrust N" as NSString,
             "mount N" as NSString, "ratio" as NSString))
print(String(repeating: "-", count: 60))

for profile in repository.allProfiles where profile.airframeClass != .multirotor {
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
    guard let mount = built.graph.structuralConnections.first(
        where: { $0.childComponentID.hasPrefix("propeller.") }
    ) else { continue }
    let fuelState: FuelSystemState? = uav.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction) }
    let backend = FuelPropulsionBackend(powerplant: uav.powerplant,
        cruiseSpeedMps: profile.fixedWingParameters?.cruiseSpeedMps ?? 20.0)

    var state = DroneState(position: SIMD3<Float>(0, 0, 0), velocity: SIMD3<Float>(0, 0, 0),
        orientation: .zero, angularVelocity: .zero, throttle: 1.0, motorThrottle: 1.0,
        rotorAngularSpeed: .zero, forwardAirspeed: 0.0,
        physicalState: .armedOnGround, mode: .takeoff)
    state.armState = UAVArmState.armed
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6_000.0) * 0.95
        warm.temperatureC = EngineOperatingEnvelope.envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm }
    let holdControl = DroneControlInput(targetPosition: SIMD3<Float>(0, 300, -3000),
        targetOrientation: .zero, yawIntent: 0, throttle: 1.0, isArmed: true,
        mode: .takeoff, controlMode: .stabilized)
    let holdContext = DroneSimulationContext(profile: profile, activeUAVProfile: uav,
        weather: .normal, damageState: .pristine, batteryState: .full, collisionRisk: 0,
        windVector: .zero, vehicleMassModel: massModel, fuelState: fuelState,
        fuelPropulsion: backend)

    // Two seconds of spool-up with the aircraft pinned, which is what the takeoff hold does.
    var peakThrust: Float = 0
    for _ in 0..<180 {
        var stepped = engine.step(state: state, control: holdControl, context: holdContext,
                                  deltaTime: dt)
        stepped.position = SIMD3<Float>(0, 0, 0)
        stepped.velocity = SIMD3<Float>(0, 0, 0)
        stepped.forwardAirspeed = 0.0
        state = stepped
        peakThrust = max(peakThrust, state.propulsionThrustNewtons)
    }
    guard peakThrust > 1.0 else { continue }
    let perRotor = peakThrust / Float(max(1, built.rotorModel.rotors.count))
    let ratio = perRotor / max(0.01, mount.shearLimitN)
    print(String(format: "%-27@ %10.0f %10.0f %8.3f %@", profile.id as NSString, peakThrust,
                 mount.shearLimitN, ratio, (ratio > 1.0 ? "<= OVER" : "") as NSString))
    if ratio > 1.0 {
        failures.append(String(
            format: "%@: propeller mount holds %.0f N but its own engine pulls %.0f N standing still",
            profile.id, mount.shearLimitN, perRotor))
    }
}

print("")
if failures.isEmpty {
    print(String(format: "OK — %.1f g in flight, and every mount holds its own thrust", failFloor))
} else {
    print("\(failures.count) structural problem(s):")
    for line in failures { print("  \(line)") }
    exit(1)
}
