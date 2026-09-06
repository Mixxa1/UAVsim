import Foundation
import simd
import QuartzCore

var failures: [String] = []
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { failures.append(message) }
}
func actors() -> [InterceptVehicleSnapshot] {
    [InterceptVehicleSnapshot(id: InterceptCallsign.attacker, role: .attacker, position: .zero, velocity: .zero,
                              functionalState: .nominal, payloadState: .armedByMission),
     InterceptVehicleSnapshot(id: InterceptCallsign.target, role: .target, position: SIMD3<Float>(0, 0, -10),
                              velocity: .zero, functionalState: .nominal, payloadState: nil)]
}
func mission(_ configuration: InterceptMissionConfiguration = .init()) -> InterceptMissionRuntime {
    var value = InterceptMissionRuntime(configuration: configuration)
    value.worldReady()
    value.acquireTarget()
    return value
}
func impact(_ runtime: InterceptMissionRuntime) -> InterceptImpactEvent {
    InterceptImpactEvent(id: UUID(), runID: runtime.runID, timestamp: runtime.elapsed, authorityID: "local",
        firstVehicleID: InterceptCallsign.attacker, secondEntityID: InterceptCallsign.target, kind: .vehicle,
        position: .zero, normal: SIMD3<Float>(1, 0, 0), firstComponentID: "frame",
        secondComponentID: "frame", impactClass: .heavy, surface: "metal")
}

var runtime = mission()
var vehicles = actors()
runtime.beginAttempt(vehicles: vehicles)
runtime.step(deltaTime: 0.1, vehicles: vehicles, impacts: [], observerCanConfirm: false)
vehicles[1].position.z = -50
runtime.step(deltaTime: 1, vehicles: vehicles, impacts: [], observerCanConfirm: false)
check(runtime.attempts.last?.outcome == .miss, "a passed approach ends as miss")
check(runtime.canBeginAttempt(vehicles: vehicles), "miss preserves armed payload eligibility")
runtime.beginAttempt(vehicles: vehicles)
runtime.step(deltaTime: 26, vehicles: vehicles, impacts: [], observerCanConfirm: false)
check(runtime.attempts.count == 2 && runtime.attempts.last?.outcome == .miss, "two misses allow independent attempts")
runtime.beginAttempt(vehicles: vehicles)
let hit = impact(runtime)
runtime.step(deltaTime: 0.1, vehicles: vehicles, impacts: [hit, hit], observerCanConfirm: true)
check(runtime.result == nil && runtime.phase == .reattack, "contact is not a scripted kill")
check(runtime.events.filter { if case .impact = $0.kind { return true }; return false }.count == 1, "one impact ID is processed once")
check(runtime.attempts.last?.hadContact == true, "attempt retains real contact")

var loss = mission()
vehicles = actors()
vehicles[0].functionalState = .crashed
loss.step(deltaTime: 0.1, vehicles: vehicles, impacts: [], observerCanConfirm: true)
check(loss.result?.reason == .attackerLost, "attacker terrain loss fails before target is terminal")
vehicles[1].functionalState = .destroyed
loss.step(deltaTime: 1, vehicles: vehicles, impacts: [], observerCanConfirm: true)
check(loss.result?.success == false, "late target destruction cannot rewrite result")

var simultaneous = mission()
simultaneous.step(deltaTime: 0.1, vehicles: vehicles, impacts: [impact(simultaneous)], observerCanConfirm: false)
check(simultaneous.result?.success == true, "same-step terminal target and attacker has deterministic precedence")
var strictConfig = InterceptMissionConfiguration()
strictConfig.confirmationPolicy = .observerRequired
var strict = mission(strictConfig)
strict.step(deltaTime: 0.1, vehicles: vehicles, impacts: [], observerCanConfirm: false)
check(strict.result == nil, "strict confirmation waits for available observation")
strict.step(deltaTime: 13, vehicles: vehicles, impacts: [], observerCanConfirm: false)
check(strict.result?.reason == .assessmentExpired, "observer LOS timeout has explicit failure")
check(mission().runID != runtime.runID, "restart has a new identity")

var payload = AttachedPayloadComponent(ownerVehicleID: InterceptCallsign.attacker)
check(payload.trigger(impactID: hit.id, policy: .targetContact), "ready mounted payload triggers")
payload.consume()
check(!payload.trigger(impactID: UUID(), policy: .targetContact), "consumed payload cannot trigger twice")
var inert = AttachedPayloadComponent(ownerVehicleID: InterceptCallsign.target, state: .inert, triggerPolicy: .ownerCritical, secondary: true)
check(!inert.trigger(impactID: UUID(), policy: .ownerCritical), "inert target payload never produces secondary effect")

var observation = InterceptObservationRuntime()
let clean = RFVideoPresentationState.clean(mode: .digital, nominalBitrateBPS: 1_000_000)
var attackerSource = InterceptObservationSource(vehicleID: InterceptCallsign.attacker, role: .attacker, position: .zero,
    orientation: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), video: clean,
    hasLineOfSight: true, cameraFunctional: true)
let observerSource = InterceptObservationSource(vehicleID: InterceptCallsign.observer, role: .observer, position: SIMD3<Float>(24, 35, -35),
    orientation: attackerSource.orientation, video: clean, hasLineOfSight: true, cameraFunctional: true)
observation.register(attackerSource)
observation.register(observerSource)
attackerSource.video.health = .degraded
observation.register(attackerSource)
_ = observation.step(now: 0, noSignalHold: 1)
check(observation.activeVehicleID == InterceptCallsign.attacker, "video degradation does not switch source early")
attackerSource.video = .unavailable
observation.register(attackerSource)
_ = observation.step(now: 1, noSignalHold: 1)
check(observation.phase == .noSignal && observation.activeVehicleID == InterceptCallsign.attacker, "NO SIGNAL precedes handoff")
_ = observation.step(now: 2.1, noSignalHold: 1)
check(observation.activeVehicleID == InterceptCallsign.observer && observation.revision == 1, "handoff selects existing observer")
check(observation.active?.position == observerSource.position, "handoff cannot move observer")
_ = observation.step(now: 10, noSignalHold: 1)
check(observation.revision == 1, "inactive attacker loss cannot retrigger handoff")

var gate = InterceptEventGate(runID: runtime.runID, authorityID: "local")
let missionEvents = runtime.drainEvents()
for event in missionEvents { check(gate.accept(event), "ordered authoritative event accepted") }
if let first = missionEvents.first { check(!gate.accept(first), "replayed ID rejected outside UI history") }
let stale = InterceptMissionEvent(id: UUID(), runID: UUID(), sequence: 1000, timestamp: 0, authorityID: "local", kind: .phase(.failed))
check(!gate.accept(stale), "old run cannot affect restarted mission")
let forged = InterceptMissionEvent(id: UUID(), runID: runtime.runID, sequence: 1000, timestamp: 0, authorityID: "remote", kind: .phase(.failed))
check(!gate.accept(forged), "non-owner cannot mutate authoritative results")
let encoded = try JSONEncoder().encode(missionEvents)
let decoded = try JSONDecoder().decode([InterceptMissionEvent].self, from: encoded)
check(decoded == missionEvents, "event log round trips")

func graph(_ mass: Float) -> VehicleComponentGraph {
    VehicleComponentGraph(components: [VehicleComponent(id: "frame", kind: .frame, parentID: nil,
        massKg: mass, localPosition: .zero, boundingHalfExtents: SIMD3<Float>(repeating: 0.2),
        strengthJ: 10000, integrity: 1, legacyComponent: nil, functionalDependencies: [], failureModes: [])])
}
let profile = VehicleContactProfile(spheres: [VehicleContactSphere(componentID: "frame", offset: .zero, radius: 0.2)], boundingRadius: 0.2)
var a0 = DroneState.initial
var b0 = DroneState.initial
a0.position = SIMD3<Float>(-2, 10, 0); b0.position = SIMD3<Float>(2, 10, 0)
a0.velocity = SIMD3<Float>(20, 0, 0); b0.velocity = SIMD3<Float>(-10, 0, 0)
var a = a0; var b = b0
a.position.x = 2; b.position.x = -2
let pair = VehiclePairContactService.firstContact(firstPrevious: a0, first: a, firstProfile: profile,
    secondPrevious: b0, second: b, secondProfile: profile)
check(pair != nil, "sweep detects fast crossing without center-distance overlap")
if let pair {
    var ag = graph(1); var bg = graph(2)
    let momentum = a.velocity + b.velocity * 2
    let energyBefore = simd_length_squared(a.velocity) * 0.5 + simd_length_squared(b.velocity)
    _ = VehiclePairContactService.resolve(contact: pair, firstPrevious: a0, secondPrevious: b0,
        first: &a, firstGraph: &ag, firstClass: .multirotor,
        second: &b, secondGraph: &bg, secondClass: .multirotor, deltaTime: 0.05)
    check(simd_distance(momentum, a.velocity + b.velocity * 2) < 0.001, "two-body response conserves linear momentum")
    check(simd_length_squared(a.velocity) * 0.5 + simd_length_squared(b.velocity) <= energyBefore + 0.001,
          "contact cannot create kinetic energy")
}
let startedAt = CACurrentMediaTime() - 4
check(CACurrentMediaTime() - startedAt > 3, "monotonic LAN grace period expires")

// Difficulty is the scenario's only automatic lever. It must move the geometry monotonically and
// must never quietly widen the escape boundary as the mission gets easier.
let easy = InterceptMissionConfiguration.make(difficulty: .easy).validated
let medium = InterceptMissionConfiguration.make(difficulty: .medium).validated
let hard = InterceptMissionConfiguration.make(difficulty: .hard).validated
check(easy.areaRadius < medium.areaRadius && medium.areaRadius < hard.areaRadius,
      "harder difficulty gives the target more room to escape into")
check(easy.acquisitionRange > medium.acquisitionRange && medium.acquisitionRange > hard.acquisitionRange,
      "harder difficulty is acquired later")
check(easy.targetAgility < hard.targetAgility, "harder difficulty moves the target harder")
check(easy.maximumAttempts == 0 && hard.maximumAttempts > 0, "only the hardest difficulty caps approaches")
for settings in [easy, medium, hard] {
    check(settings.acquisitionRange <= settings.areaRadius,
          "a target cannot be acquired further away than it is allowed to fly")
}
var absurd = InterceptMissionConfiguration()
absurd.areaRadius = .nan
absurd.acquisitionRange = .infinity
absurd.targetAgility = -8
absurd.timeLimit = -1
absurd.maximumAttempts = -3
absurd.targetOffset = SIMD3<Float>(.nan, 0, 0)
let repaired = absurd.validated
check(repaired.areaRadius.isFinite && repaired.acquisitionRange <= repaired.areaRadius,
      "non-finite configuration is repaired rather than propagated")
check(repaired.targetAgility >= 0 && repaired.timeLimit >= 10 && repaired.maximumAttempts == 0,
      "out-of-range configuration is clamped into a playable run")
check(repaired.targetOffset.x.isFinite, "a non-finite spawn offset falls back to the default")

// A run capped at three approaches has to end when they are gone, not carry on unwinnable.
var capped = mission(hard)
var cappedVehicles = actors()
for _ in 0..<hard.maximumAttempts {
    capped.beginAttempt(vehicles: cappedVehicles)
    capped.step(deltaTime: 26, vehicles: cappedVehicles, impacts: [], observerCanConfirm: false)
}
check(!capped.canBeginAttempt(vehicles: cappedVehicles), "the approach cap actually closes the door")
capped.step(deltaTime: 0.1, vehicles: cappedVehicles, impacts: [], observerCanConfirm: false)
check(capped.result?.reason == .attemptsExhausted, "running out of approaches is an explicit failure")

// A spent module is not a reason to keep flying an unwinnable mission either.
var spent = mission()
cappedVehicles = actors()
cappedVehicles[0].payloadState = .consumed
spent.step(deltaTime: 0.1, vehicles: cappedVehicles, impacts: [], observerCanConfirm: false)
check(spent.result?.reason == .payloadUnavailable, "a spent module ends the run with a stated reason")

// Every event has to say something specific in the log, and say it at the right volume.
var logged = mission()
logged.record(.videoLost(InterceptCallsign.attacker))
logged.record(.vehicleState(InterceptCallsign.target, .destroyed))
logged.record(.payload(InterceptCallsign.attacker, .inert))
let loggedEvents = logged.drainEvents()
check(loggedEvents.allSatisfy { !$0.kind.detailKey.isEmpty && $0.kind.detailKey != "intercept.log." },
      "every logged event resolves to its own detail key")
check(loggedEvents.map(\.kind.detailKey).count == Set(loggedEvents.map(\.kind.detailKey)).count,
      "distinct events do not collapse onto one log line")
check(InterceptMissionEventKind.vehicleState(InterceptCallsign.target, .destroyed).severity == .critical,
      "a destroyed aircraft is a critical log entry")
check(InterceptMissionEventKind.phase(.reattack).severity == .info, "a phase change is not an alarm")
check(InterceptMissionEventKind.videoLost(InterceptCallsign.attacker).severity == .warning,
      "losing the picture is a warning")

// Call signs are one constant, and roles agree with it.
check(InterceptVehicleRole.attacker.callsign == InterceptCallsign.attacker
        && InterceptVehicleRole.target.callsign == InterceptCallsign.target
        && InterceptVehicleRole.observer.callsign == InterceptCallsign.observer,
      "roles and call signs cannot drift apart")

// Target behaviour. The previous shape was a sum of sines around the spawn point: it wandered,
// it never saw the interceptor, and it could not be flown against. These measure what replaced it
// by actually flying the guidance forward at 30 Hz.
func flyTarget(
    behavior: InterceptTargetBehavior,
    agility: Float = 1,
    areaRadius: Float = 280,
    isFixedWing: Bool = false,
    seconds: Float = 40,
    obstacles: [CollisionObstacle] = [],
    attacker: (Float, SIMD3<Float>) -> SIMD3<Float>
) -> (path: [SIMD3<Float>], courseChanges: [Float]) {
    let dt: Float = 1.0 / 30.0
    let origin = SIMD3<Float>(0, 0, 0)
    var guidance = InterceptTargetGuidance()
    var position = SIMD3<Float>(0, 60, -120)
    var velocity = SIMD3<Float>(0, 0, 12)
    let speed: Float = isFixedWing ? 28 : 12
    var path: [SIMD3<Float>] = [position]
    var changes: [Float] = []
    var previousCourse: SIMD3<Float>?
    var elapsed: Float = 0
    while elapsed < seconds {
        let aim = guidance.aimPoint(InterceptTargetGuidance.Situation(
            behavior: behavior, agility: agility, position: position, velocity: velocity,
            spawnPosition: SIMD3<Float>(0, 60, -120), attacker: attacker(elapsed, position),
            origin: origin, areaRadius: areaRadius, isFixedWing: isFixedWing,
            isDamaged: false, obstacles: obstacles, deltaTime: dt
        ))
        // The aircraft is idealised here: it simply flies its course at a constant speed. That is
        // the point — this measures the guidance, not the airframe.
        let course = InterceptTargetGuidance.planar(aim - position)
        if let previousCourse {
            changes.append(acos(max(-1, min(1, simd_dot(previousCourse, course)))) / dt)
        }
        previousCourse = course
        velocity = course * speed
        position += velocity * dt
        position.y = aim.y
        path.append(position)
        elapsed += dt
    }
    return (path, changes)
}
func planarRange(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    simd_length(SIMD2<Float>(a.x - b.x, a.z - b.z))
}

let parked = SIMD3<Float>(0, 60, -400)
let patrol = flyTarget(behavior: .routeFollower) { _, _ in parked }
check(patrol.path.allSatisfy { planarRange($0, .zero) <= 280 },
      "a patrolling target stays inside the mission area")
check(patrol.courseChanges.allSatisfy { $0 <= 1.6 },
      "the target's course is rate-limited rather than snapping between headings")
// It has to actually go somewhere: the shape this replaced returned to its own start every few
// seconds, which is what made it read as random drift.
check(patrol.path.map { planarRange($0, patrol.path[0]) }.max() ?? 0 > 120,
      "a patrolling target transits the area instead of circling its spawn")

// Same run, but the interceptor sits right on top of it. A route follower must not care.
let ignoring = flyTarget(behavior: .routeFollower) { _, position in position + SIMD3<Float>(20, 0, 0) }
check(zip(patrol.path, ignoring.path).allSatisfy { simd_distance($0, $1) < 0.01 },
      "the route-following profile does not react to the interceptor at all")

// An interceptor parked squarely on the target's opening course. A route follower flies straight
// through it; an evading target must never let it get as close.
let ambush = SIMD3<Float>(0, 60, -40)
let evading = flyTarget(behavior: .evasiveBasic) { _, _ in ambush }
let oblivious = flyTarget(behavior: .routeFollower) { _, _ in ambush }
func closestApproach(_ path: [SIMD3<Float>], to point: SIMD3<Float>) -> Float {
    path.map { planarRange($0, point) }.min() ?? .greatestFiniteMagnitude
}
check(closestApproach(oblivious.path, to: ambush) < 20, "the unaware profile flies straight into the interceptor")
check(closestApproach(evading.path, to: ambush) > closestApproach(oblivious.path, to: ambush) + 30,
      "an evading target keeps the interceptor meaningfully further away")
check(evading.path.allSatisfy { planarRange($0, .zero) <= 280 },
      "evasion does not fly the target out of the mission area on its own")
check(evading.courseChanges.allSatisfy { $0 <= 2.2 },
      "even a hard break stays within the target's turn rate")

// Escaping is the one profile that is supposed to cross the boundary.
let escaping = flyTarget(behavior: .escapeBoundary, seconds: 60) { _, _ in SIMD3<Float>(0, 60, 0) }
check(planarRange(escaping.path.last!, .zero) > 280, "the escape profile leaves the mission area")

// An aeroplane needs a leg, not a destination: its aim point has to sit far enough ahead for the
// route follower to have something to track.
var aeroplane = InterceptTargetGuidance()
let aeroplaneAim = aeroplane.aimPoint(InterceptTargetGuidance.Situation(
    behavior: .routeFollower, agility: 1, position: SIMD3<Float>(0, 110, 0),
    velocity: SIMD3<Float>(0, 0, 28), spawnPosition: SIMD3<Float>(0, 110, -200),
    attacker: SIMD3<Float>(0, 110, -30), origin: .zero, areaRadius: 280,
    isFixedWing: true, isDamaged: false, deltaTime: 1.0 / 30.0
))
check(planarRange(aeroplaneAim, SIMD3<Float>(0, 110, 0)) >= 700, "an aeroplane target is given a leg to fly")
check(abs(aeroplaneAim.y - 110) < 0.001, "an aeroplane target holds its transit altitude")

// A damaged recovery target stops where it was hit and stays there.
var recovering = InterceptTargetGuidance()
func recoveryAim(_ position: SIMD3<Float>) -> SIMD3<Float> {
    recovering.aimPoint(InterceptTargetGuidance.Situation(
        behavior: .damagedRecovery, agility: 1, position: position, velocity: .zero,
        spawnPosition: SIMD3<Float>(0, 60, -120), attacker: SIMD3<Float>(0, 60, -100),
        origin: .zero, areaRadius: 280, isFixedWing: false, isDamaged: true, deltaTime: 1.0 / 30.0
    ))
}
let held = recoveryAim(SIMD3<Float>(14, 58, -130))
check(held == SIMD3<Float>(14, 58, -130), "a damaged target holds where it was hit")
check(recoveryAim(SIMD3<Float>(30, 40, -160)) == held, "the recovery point is latched, not re-chosen every tick")

// A fixed-wing target is the one actor flown by a different control law, and the one that falls
// out of the sky if that law is wired up wrongly. Fly a real one for a minute against the real
// guidance and check it behaves like an aeroplane transiting an area.
if let wingProfile = LIPODroneModelRepository().allProfiles
    .first(where: { $0.airframeClass == .fixedWing && $0.fixedWingParameters != nil }) {
    let transitAltitude: Float = 110
    let areaRadius: Float = 280
    let wingMass = VehicleMassModel.baseline(for: wingProfile, uavProfile: wingProfile.resolvedUAVProfile)
    // The airframe's real size, not a placeholder box. `VehicleComponentGraphBuilder` measures
    // this from the visual in the app and cannot run headlessly — and a stand-in graph with
    // 0.2 m half-extents gives an aeroplane a model-glider's moment of inertia, which makes it
    // roll itself into the ground on the first correction. That would be a defect in the probe's
    // input, not in the flight law under test.
    let catalogue = wingProfile.resolvedUAVProfile?.dimensions
    let spanM = (catalogue?.wingspanMillimeters ?? wingProfile.dimensionsUnfoldedMm.x) / 1000
    let lengthM = (catalogue?.fuselageLengthMillimeters ?? spanM * 550) / 1000
    let hullExtents = SIMD3<Float>(spanM / 2, max(0.15, spanM / 20), lengthM / 2)
    let hullGraph = VehicleComponentGraph(components: [
        VehicleComponent(
            id: "frame", kind: .frame, parentID: nil, massKg: wingMass.resolvedCurrentTotalMass,
            localPosition: .zero, boundingHalfExtents: hullExtents, strengthJ: 10000, integrity: 1,
            legacyComponent: nil, functionalDependencies: [], failureModes: []
        )
    ])
    let hull = VehicleContactProfile(
        spheres: [VehicleContactSphere(componentID: "frame", offset: .zero, radius: 0.6)],
        boundingRadius: 0.6
    )
    let actor = InterceptVehicleRuntime(
        id: InterceptCallsign.target, role: .target, profile: wingProfile, massModel: wingMass,
        position: SIMD3<Float>(0, transitAltitude, -areaRadius * 0.7),
        graph: hullGraph, contacts: hull, rotors: .empty,
        payload: nil, seed: 11, initialCourse: SIMD3<Float>(0, 0, 1)
    )
    check(actor.isFixedWing, "the aeroplane target is recognised as one")
    check(simd_length(actor.state.velocity) > 5, "an aeroplane target is spawned already flying")

    var wingGuidance = InterceptTargetGuidance()
    var lowest = Float.greatestFiniteMagnitude
    var furthest: Float = 0
    let dt: Float = 1.0 / 60.0
    for tick in 0..<(60 * 60) {
        // An interceptor loitering over the middle of the area, which the transit crosses.
        let attacker = SIMD3<Float>(0, transitAltitude, 0)
        let aim = wingGuidance.aimPoint(InterceptTargetGuidance.Situation(
            behavior: .routeFollower, agility: 1, position: actor.state.position,
            velocity: actor.state.velocity, spawnPosition: actor.spawnPosition, attacker: attacker,
            origin: .zero, areaRadius: areaRadius, isFixedWing: true, isDamaged: false, deltaTime: dt
        ))
        _ = actor.step(deltaTime: dt, desiredPosition: aim, weather: .normal, wind: .zero,
                       groundHeight: 0, obstacles: [])
        // Skip the first second: the follower is still capturing its opening leg.
        guard tick > 60 else { continue }
        lowest = min(lowest, actor.state.position.y)
        furthest = max(furthest, simd_length(SIMD2<Float>(actor.state.position.x, actor.state.position.z)))
    }
    check(actor.state.physicalState != .crashed, "the aeroplane target does not crash on its own")
    check(lowest > transitAltitude * 0.5, "the aeroplane target holds a transit altitude clear of the trees")
    check(furthest < areaRadius * 1.25, "the aeroplane target's patrol is contained by the mission area")
    check(simd_length(actor.state.velocity) > wingProfile.fixedWingParameters!.minSafeAirspeed,
          "the aeroplane target stays above its stall speed")
}

// The patrol height itself is the first line of defence. A dense forest in this simulator reaches
// 28 m (see `ScenePopulationService.sizeForBelt`), so a target patrolling below that is being asked
// to thread trees continuously — which is what flying into them looks like.
let tallestForestTree: Float = 28
check(InterceptMissionConfiguration().targetOffset.y > tallestForestTree + 15,
      "the target patrols clear of the canopy, not inside it")
check(InterceptMissionConfiguration().observerOffset.y > tallestForestTree + 15,
      "the observer holds station above the canopy")

// A target that dodges the interceptor and then flies into a tree is not evading anything. The
// guidance has to see the world it is manoeuvring in.
func mast(_ x: Float, _ z: Float, radius: Float = 5, top: Float = 72) -> CollisionObstacle {
    CollisionObstacle(id: UUID(), center: SIMD3<Float>(x, top * 0.5, z), radius: radius,
                      source: "probe-mast", baseY: 0, topY: top, acousticSurface: .foliage)
}
/// A line of masts across the target's opening course, tall enough to matter at its patrol height.
let stand = [mast(0, -40), mast(-14, -52), mast(15, -55), mast(2, -70)]
/// Closest a path came to hitting one: horizontal clearance where the aircraft was below the top,
/// and vertical clearance where it flew over. Whichever kept it out of the obstacle.
func nearestMiss(_ path: [SIMD3<Float>], _ obstacles: [CollisionObstacle]) -> Float {
    var worst = Float.greatestFiniteMagnitude
    for point in path {
        for obstacle in obstacles {
            let horizontal = planarRange(point, obstacle.center) - obstacle.radius
            let vertical = point.y - obstacle.topY
            worst = min(worst, max(horizontal, vertical))
        }
    }
    return worst
}
let blind = flyTarget(behavior: .routeFollower, seconds: 30) { _, _ in parked }
let seeing = flyTarget(behavior: .routeFollower, seconds: 30, obstacles: stand) { _, _ in parked }
check(nearestMiss(blind.path, stand) < 5, "the opening course does run into the masts")
check(nearestMiss(seeing.path, stand) > 10, "with obstacles in view the target keeps clear of them")
check(seeing.path.allSatisfy { planarRange($0, .zero) <= 280 },
      "avoiding an obstacle does not throw the target out of the mission area")

// Something wide it cannot go round is something it goes over.
var overflying = InterceptTargetGuidance()
let wall = (-4...4).map { mast(Float($0) * 9, -60, radius: 8, top: 34) }
let overAim = overflying.aimPoint(InterceptTargetGuidance.Situation(
    behavior: .routeFollower, agility: 1, position: SIMD3<Float>(0, 20, -20),
    velocity: SIMD3<Float>(0, 0, -12), spawnPosition: SIMD3<Float>(0, 20, 0),
    attacker: SIMD3<Float>(0, 20, 200), origin: .zero, areaRadius: 280,
    isFixedWing: false, isDamaged: false, obstacles: wall, deltaTime: 1.0 / 30.0
))
check(overAim.y >= 34, "the aim point clears the top of what is in the way")

// Effects are world-space and bounded: one per impact/vehicle/kind, expiring on their own.
var effects = InterceptEffectRuntime()
let effectRun = UUID()
func effect(kind: InterceptEffectKind, impactID: UUID, lifetime: TimeInterval, run: UUID = effectRun) -> InterceptWorldEffect {
    InterceptWorldEffect(id: UUID(), runID: run, impactID: impactID, vehicleID: InterceptCallsign.target,
                         kind: kind, position: .zero, startedAt: 0, lifetime: lifetime)
}
let sharedImpact = UUID()
check(effects.add(effect(kind: .fire, impactID: sharedImpact, lifetime: 6), runID: effectRun), "an effect is created once")
check(!effects.add(effect(kind: .fire, impactID: sharedImpact, lifetime: 6), runID: effectRun),
      "a replayed effect event does not produce a second fire")
check(!effects.add(effect(kind: .fire, impactID: UUID(), lifetime: 6, run: UUID()), runID: effectRun),
      "an effect from another run is rejected")
check(!effects.add(effect(kind: .smoke, impactID: UUID(), lifetime: 600), runID: effectRun),
      "an effect cannot claim an unbounded lifetime")
for _ in 0..<80 { effects.add(effect(kind: .smoke, impactID: UUID(), lifetime: 12), runID: effectRun) }
check(effects.effects.count <= 48, "persistent smoke stays inside its policy")
effects.step(now: 1000)
check(effects.effects.isEmpty, "a restart-free run still retires every effect it created")

if failures.isEmpty { print("PASS: \(checks) interception checks") }
else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
