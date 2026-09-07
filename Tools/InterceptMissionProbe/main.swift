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
strict.step(deltaTime: InterceptMissionConfiguration().assessmentTimeout + 1,
            vehicles: vehicles, impacts: [], observerCanConfirm: false)
check(strict.result?.reason == .assessmentExpired, "observer LOS timeout has explicit failure")

// A surviving target with nothing left to send at it ends the run for that reason, immediately —
// not by sitting out the assessment clock and then blaming a timer that had minutes left on it.
var spentAfterContact = mission()
var spentVehicles = actors()
spentAfterContact.beginAttempt(vehicles: spentVehicles)
spentAfterContact.step(deltaTime: 0.1, vehicles: spentVehicles,
                       impacts: [impact(spentAfterContact)], observerCanConfirm: false)
spentVehicles[0].payloadState = .consumed
spentAfterContact.step(deltaTime: 0.1, vehicles: spentVehicles, impacts: [], observerCanConfirm: false)
check(spentAfterContact.result?.reason == .payloadUnavailable,
      "a spent module against a surviving target is reported as a spent module")
check(spentAfterContact.elapsed < InterceptMissionConfiguration().timeLimit * 0.5,
      "and it is reported at once, with the mission clock still running")
// ...but only against a target that is flying as if nothing had happened. A hit aircraft passes
// through `damaged` and `degraded` on its way down, and both of those still answer `canAttempt`:
// ending the run on the first sight of one called a success a failure a second before the target
// reached the ground.
var fallingTarget = mission()
var fallingVehicles = actors()
fallingTarget.beginAttempt(vehicles: fallingVehicles)
fallingTarget.step(deltaTime: 0.1, vehicles: fallingVehicles,
                   impacts: [impact(fallingTarget)], observerCanConfirm: false)
fallingVehicles[0].payloadState = .consumed
fallingVehicles[1].functionalState = .degraded
fallingTarget.step(deltaTime: 0.5, vehicles: fallingVehicles, impacts: [], observerCanConfirm: false)
check(fallingTarget.result == nil, "a stricken target is not written off while it is still coming down")
fallingVehicles[1].functionalState = .crashed
fallingTarget.step(deltaTime: 0.5, vehicles: fallingVehicles, impacts: [], observerCanConfirm: false)
check(fallingTarget.result?.success == true && fallingTarget.result?.reason == .targetNeutralized,
      "and the crash that follows is the result of the run")

// A contact that neither killed the target nor left anything to try again with still ends for the
// reason the operator actually ran out of.
var stalled = mission()
var stalledVehicles = actors()
stalled.beginAttempt(vehicles: stalledVehicles)
stalled.step(deltaTime: 0.1, vehicles: stalledVehicles, impacts: [impact(stalled)], observerCanConfirm: false)
stalledVehicles[0].payloadState = .consumed
stalledVehicles[1].functionalState = .damaged
stalled.step(deltaTime: 0.1, vehicles: stalledVehicles, impacts: [], observerCanConfirm: false)
check(stalled.result == nil, "a damaged target still gets its window")
stalled.step(deltaTime: InterceptMissionConfiguration().assessmentTimeout + 1,
             vehicles: stalledVehicles, impacts: [], observerCanConfirm: false)
check(stalled.result?.reason == .payloadUnavailable,
      "an unresolved contact with nothing left to send is not a timer expiring")
check(InterceptMissionConfiguration().validated.assessmentTimeout >= 20,
      "a fouled rotorcraft is given long enough to reach the ground from patrol altitude")

check(mission().runID != runtime.runID, "restart has a new identity")
// The hold has to be long enough that an ordinary interference burst is not a source change.
check(InterceptMissionConfiguration().validated.noSignalHold >= 3,
      "the handoff waits out a stumble rather than reacting to one")

// The module is a shape and a mass; what it does on contact is a separate setting. Both have to
// stay independent, and a heavier one has to actually be heavier.
check(Set(AttachedModuleShape.allCases.map(\.massKg)).count == AttachedModuleShape.allCases.count,
      "every module shape has its own mass")
check(AttachedModuleShape.net.massKg > AttachedModuleShape.charge.massKg,
      "the bulkiest module is the one that costs the most to carry")
// The module decides what the module does; there is no way to describe a net that behaves like a
// slug, because that is not a thing anybody could load.
check(AttachedModuleShape.charge.effectProfile == .structuralDestruction, "a charge takes airframes apart")
check(AttachedModuleShape.charge.effectProfile.destroysCarrier,
      "a charge going off under your own aircraft takes that one with it")
check(!AttachedModuleShape.net.effectProfile.destroysCarrier, "a net does not wreck its carrier")
check(AttachedModuleShape.net.effectProfile == .equipmentDisruption, "a net fouls equipment")
check(AttachedModuleShape.kineticSlug.effectProfile == .kineticPenetration,
      "a slug does its work by arriving, through one point of the target")
check(AttachedModuleShape.ballast.effectProfile == .contactOnly, "inert practice mass does nothing on contact")
// Only the two inert modules leave the operator's aircraft flying. Anything that does something
// does it at contact range, off a mount on that aircraft's own nose.
check(!AttachedModuleShape.charge.effectProfile.sparesCarrier,
      "a charge does not leave its carrier flyable")
check(!AttachedModuleShape.net.effectProfile.sparesCarrier,
      "a net deployed off your own mount goes through your own rotors on the way out")
check(!AttachedModuleShape.kineticSlug.effectProfile.sparesCarrier,
      "a rigid slug driven into another aircraft takes its own out of the air too")
check(AttachedModuleShape.ballast.effectProfile.sparesCarrier,
      "inert practice mass does nothing to the aircraft carrying it")
check(AttachedModuleShape.selectable(for: .interceptor).filter { $0.effectProfile.sparesCarrier }.count == 1,
      "practice is the only interception load you fly home from")
for shape in AttachedModuleShape.allCases {
    var configured = InterceptMissionConfiguration()
    // Asked for on the side it belongs to, so validation has no reason to substitute it.
    configured.side = AttachedModuleShape.selectable(for: .interceptor).contains(shape) ? .interceptor : .delivery
    configured.moduleShape = shape
    configured.payloadProfile = .equipmentDisruption
    check(configured.validated.moduleShape == shape,
          "\(shape.rawValue) survives validation on its own side")
    check(configured.validated.payloadProfile == shape.effectProfile,
          "\(shape.rawValue) cannot be validated into behaving like something else")
}
for shape in AttachedModuleShape.allCases {
    let size = shape.sizeMeters
    check(size.x > 0 && size.y > 0 && size.z > 0, "\(shape.rawValue) has a real size to draw")
    check(shape.massKg > 0 && shape.massKg < 3, "\(shape.rawValue) has a mass an interceptor could carry")
}
check(InterceptMissionConfiguration().moduleShape == .charge,
      "the default module is the one that changes the aircraft least")

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
// A stumble that comes back inside the hold must leave the operator where they were.
attackerSource.video = clean
observation.register(attackerSource)
_ = observation.step(now: 1.6, noSignalHold: 1)
check(observation.activeVehicleID == InterceptCallsign.attacker && observation.revision == 0,
      "a brief dropout that recovers does not hand the feed to the observer")
attackerSource.video = .unavailable
observation.register(attackerSource)
// The clock restarts from the new loss, not from the first one — that is what makes the debounce
// a debounce rather than a delay.
_ = observation.step(now: 1.7, noSignalHold: 1)
_ = observation.step(now: 2.4, noSignalHold: 1)
check(observation.activeVehicleID == InterceptCallsign.attacker,
      "the hold is measured from the loss that is still going, not from an earlier one")
_ = observation.step(now: 2.9, noSignalHold: 1)
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

// MARK: - What an interception contact costs the aircraft that made it

// A ram is a ram. The carrier used to fly home from a collision that should have ended it, because
// the two-body contact charged each airframe half the energy the same impact against a building
// would have. These pin the outcome at the speeds an interception is actually flown at.
func ramHull(_ mass: Float) -> VehicleComponentGraph {
    VehicleComponentGraph(components: [
        VehicleComponent(id: "frame", kind: .frame, parentID: nil, massKg: mass,
                         localPosition: .zero, boundingHalfExtents: SIMD3<Float>(0.35, 0.12, 0.35),
                         strengthJ: 900, integrity: 1, legacyComponent: nil,
                         functionalDependencies: [], failureModes: [])
    ])
}
let ramProfile = VehicleContactProfile(
    spheres: [VehicleContactSphere(componentID: "frame", offset: .zero, radius: 0.35)],
    boundingRadius: 0.35
)
/// Head-on contact at a given closing speed; returns what is left of each frame.
func ram(closing: Float) -> (carrier: Float, target: Float, tier: ImpactOutcomeTier)? {
    var carrierBefore = DroneState.initial
    var targetBefore = DroneState.initial
    carrierBefore.position = SIMD3<Float>(0, 50, 2)
    targetBefore.position = SIMD3<Float>(0, 50, -2)
    carrierBefore.velocity = SIMD3<Float>(0, 0, -closing * 0.6)
    targetBefore.velocity = SIMD3<Float>(0, 0, closing * 0.4)
    var carrier = carrierBefore
    var target = targetBefore
    carrier.position.z = -2
    target.position.z = 2
    guard let pair = VehiclePairContactService.firstContact(
        firstPrevious: carrierBefore, first: carrier, firstProfile: ramProfile,
        secondPrevious: targetBefore, second: target, secondProfile: ramProfile
    ) else { return nil }
    var carrierGraph = ramHull(9.2)
    var targetGraph = ramHull(15.8)
    let reports = VehiclePairContactService.resolve(
        contact: pair, firstPrevious: carrierBefore, secondPrevious: targetBefore,
        first: &carrier, firstGraph: &carrierGraph, firstClass: .multirotor,
        second: &target, secondGraph: &targetGraph, secondClass: .multirotor, deltaTime: 1.0 / 60.0
    )
    return (carrierGraph.integrity(id: "frame"), targetGraph.integrity(id: "frame"), reports.first.tier)
}

if let brush = ram(closing: 8) {
    check(brush.tier == .scrape, "a slow closing touch is a scrape, not a wreck")
    check(brush.carrier > 0.5, "an aircraft survives brushing another at walking-pace closure")
}
if let hard = ram(closing: 14) {
    check(hard.tier == .heavyImpact, "a 14 m/s closure is a heavy impact")
    check(hard.carrier < 0.6, "a heavy impact leaves the carrier badly damaged")
}
if let ramming = ram(closing: 20) {
    check(ramming.tier == .criticalImpact, "an interception ram at 20 m/s is a critical impact")
    check(ramming.carrier <= 0.001, "the aircraft that made the ram does not fly away from it")
    check(ramming.target <= 0.001, "and neither does the one it hit")
}
// Energy has to rise with closing speed, or the tiers above mean nothing.
if let slow = ram(closing: 8), let fast = ram(closing: 20) {
    check(slow.carrier > fast.carrier, "a faster contact costs the airframe more, not less")
}

// The module is bolted to the operator's own aircraft. Whatever it does at contact range it does
// to both of them — and the effect has to be produced, which is the part that was silently dead:
// `trigger` moves the module to `contactTriggered` and `consume` immediately moves it on to
// `consumed`, so a later test for `contactTriggered` was never true and no activation effect was
// ever added. Measured here by running a real contact through the real session.
/// Four arms of a rotorcraft. The frame's strength sets the tier the contact is charged at; the
/// rotors are given enough of their own that a glancing 10 m/s touch does not wreck them, so what
/// the assertions below see on a propeller came from the module and not from the collision.
func rotorHull(mass: Float) -> VehicleComponentGraph {
    var components = [
        VehicleComponent(id: "frame", kind: .frame, parentID: nil, massKg: mass * 0.5,
                         localPosition: .zero, boundingHalfExtents: SIMD3<Float>(0.25, 0.09, 0.25),
                         strengthJ: 900, integrity: 1, legacyComponent: nil,
                         functionalDependencies: [], failureModes: [])
    ]
    for (index, slot) in ["fl", "fr", "rl", "rr"].enumerated() {
        let x: Float = index % 2 == 0 ? -0.2 : 0.2
        let z: Float = index < 2 ? -0.2 : 0.2
        components.append(VehicleComponent(
            id: "motor.\(slot)", kind: .motor(slot: slot), parentID: "frame", massKg: mass * 0.08,
            localPosition: SIMD3<Float>(x, 0, z), boundingHalfExtents: SIMD3<Float>(repeating: 0.03),
            strengthJ: 3000, integrity: 1, legacyComponent: nil,
            functionalDependencies: [], failureModes: []
        ))
        components.append(VehicleComponent(
            id: "propeller.\(slot)", kind: .propeller(slot: slot), parentID: "motor.\(slot)",
            massKg: mass * 0.01, localPosition: SIMD3<Float>(x, 0.03, z),
            boundingHalfExtents: SIMD3<Float>(0.12, 0.005, 0.12), strengthJ: 3000, integrity: 1,
            legacyComponent: nil, functionalDependencies: [], failureModes: []
        ))
    }
    return VehicleComponentGraph(components: components)
}

/// Whether every rotor on an airframe is fouled or gone.
func rotorsFouled(_ graph: VehicleComponentGraph) -> Bool {
    let propellers = graph.components.filter { if case .propeller = $0.kind { return true }; return false }
    return !propellers.isEmpty && propellers.allSatisfy { !$0.isAttached || $0.integrity <= 0.06 }
}

/// Rams the target with the given module and reports what is left of both aircraft, plus which
/// vehicles the run produced world effects for.
func activate(module: AttachedModuleShape) -> (
    carrier: VehicleComponentGraph,
    target: VehicleComponentGraph,
    payload: AttachedPayloadState,
    effects: [InterceptWorldEffect],
    feedCut: Bool
)? {
    guard let rotorProfile = LIPODroneModelRepository().allProfiles
        .first(where: { $0.airframeClass == .multirotor }) else { return nil }
    var settings = InterceptMissionConfiguration()
    settings.moduleShape = module
    settings = settings.validated

    let mass = VehicleMassModel.baseline(for: rotorProfile, uavProfile: rotorProfile.resolvedUAVProfile)
    let hull = VehicleContactProfile(
        spheres: [VehicleContactSphere(componentID: "frame", offset: .zero, radius: 0.4)],
        boundingRadius: 0.4
    )
    // A fixed airframe mass rather than the catalogue's, so the contact is charged the same energy
    // whichever multirotor happens to come first out of the repository.
    let hullMass: Float = 7
    let station = SIMD3<Float>(0, 60, 0)
    func actor(_ id: String, role: InterceptVehicleRole, at position: SIMD3<Float>) -> InterceptVehicleRuntime {
        InterceptVehicleRuntime(
            id: id, role: role, profile: rotorProfile, massModel: mass, position: position,
            graph: rotorHull(mass: hullMass), contacts: hull, rotors: .empty,
            payload: nil, seed: 7
        )
    }
    let session = InterceptMissionSession(
        configuration: settings,
        target: actor(InterceptCallsign.target, role: .target, at: station),
        observer: actor(InterceptCallsign.observer, role: .observer, at: station + SIMD3<Float>(90, 6, 40)),
        origin: .zero
    )

    // Ten metres a second of closure: hard enough that the contact is a real one and the module
    // goes off, gentle enough that the collision on its own leaves both airframes flying. What the
    // assertions then see is the module's doing.
    var previous = DroneState.initial
    previous.position = station + SIMD3<Float>(0, 0, 0.6)
    previous.physicalState = .airborne
    previous.velocity = SIMD3<Float>(0, 0, -10)
    var player = previous
    player.position = station + SIMD3<Float>(0, 0, 0.6 - 10.0 / 60.0)
    var carrierGraph = rotorHull(mass: hullMass)
    _ = session.simulate(
        deltaTime: 1.0 / 60.0, playerPrevious: previous, player: &player, playerGraph: &carrierGraph,
        playerContacts: hull, playerClass: .multirotor, weather: .normal, wind: .zero,
        ground: { _, _ in 0 }, obstacles: { _, _, _ in [] }
    )
    return (
        carrierGraph,
        session.target.graph,
        session.playerPayload.state,
        session.effects.effects,
        session.observation.isDisrupted(InterceptCallsign.attacker, now: session.worldTime)
    )
}

// Mass taped to the nose is mass on the nose. The module used to be carried for free: an operator
// could take 0.9 kg of net over 0.35 kg of charge and fly exactly the same aircraft, because the
// only place its mass was ever applied was the NPC actors.
var bareHull = rotorHull(mass: 7)
let bareMass = bareHull.massProperties
let noseLoad = VehicleComponent(
    id: AttachedPayloadComponent.noseMountPointID, kind: .payloadMount, parentID: "frame",
    massKg: AttachedModuleShape.net.massKg, localPosition: SIMD3<Float>(0, -0.10, -0.32),
    boundingHalfExtents: AttachedModuleShape.net.sizeMeters * 0.5, strengthJ: 120, integrity: 1,
    legacyComponent: nil, functionalDependencies: [], failureModes: []
)
var loadedHull = VehicleComponentGraph(components: bareHull.components + [noseLoad])
let loadedMass = loadedHull.massProperties
check(loadedMass.totalMassKg > bareMass.totalMassKg + AttachedModuleShape.net.massKg * 0.99,
      "the module's mass reaches the aircraft that is carrying it")
check(loadedMass.centerOfMassOffset.z < bareMass.centerOfMassOffset.z - 0.01,
      "and pulls the centre of mass towards where it hangs")
check(loadedMass.centerOfMassOffset.y < bareMass.centerOfMassOffset.y,
      "including downwards, because it is taped underneath")
check(loadedMass.inertiaDiagonal.x > bareMass.inertiaDiagonal.x,
      "a load out on the nose is also harder to pitch, which is what makes a heavy one a decision")
_ = loadedHull.detachSubtree(rootComponentID: AttachedPayloadComponent.noseMountPointID)
let releasedMass = loadedHull.massProperties
check(abs(releasedMass.totalMassKg - bareMass.totalMassKg) < 0.001,
      "separating at activation gives the aircraft its mass back")
check(simd_distance(releasedMass.centerOfMassOffset, bareMass.centerOfMassOffset) < 0.001,
      "with the centre of mass back where the airframe's own is")

if let netHit = activate(module: .net) {
    check(netHit.payload == .consumed, "a real contact spends the module")
    check(rotorsFouled(netHit.target),
          "a net fouls the rotors of the aircraft it was thrown at")
    check(rotorsFouled(netHit.carrier),
          "and the rotors of the aircraft it came off, which is the whole point of carrying it")
    check(netHit.carrier.integrity(id: "frame") > 0.001 && netHit.target.integrity(id: "frame") > 0.001,
          "a net brings aircraft down without taking either airframe apart")
    check(netHit.effects.contains { $0.vehicleID == InterceptCallsign.attacker },
          "the operator's own aircraft is where something visibly happened, too")
    check(netHit.effects.contains { $0.vehicleID == InterceptCallsign.target },
          "and so is the target")
}
if let chargeHit = activate(module: .charge) {
    check(chargeHit.payload == .consumed, "a charge is spent by the same contact")
    check(chargeHit.target.integrity(id: "frame") <= 0.001, "a charge takes the target's airframe apart")
    check(chargeHit.carrier.integrity(id: "frame") <= 0.001, "and the airframe it was bolted to")
    // Integrity and joint strength are separate. Zeroing only the first left every joint intact,
    // so nothing ever came off and a "destroyed" target sat on screen in one piece.
    check(chargeHit.target.components.contains { !$0.isAttached },
          "the target's components actually come off it")
    check(chargeHit.target.components.filter { !$0.isAttached }.count >= 4,
          "and it is the whole airframe coming apart, not one arm")
    // The operator's own aircraft is left with failed joints instead: the app's impact pipeline
    // detaches those a moment later and spawns real physics debris, and it reads the list this
    // leaves behind. Detaching here would hand it an empty one.
    check(!chargeHit.carrier.failedConnectionRootIDs.isEmpty,
          "the carrier's structure is handed to the app's own detachment pass")
    check(chargeHit.effects.contains { $0.vehicleID == InterceptCallsign.attacker && $0.kind == .secondary },
          "the loudest moment of the run happens on the operator's own aircraft")
    check(chargeHit.effects.contains { $0.vehicleID == InterceptCallsign.target && $0.kind == .secondary },
          "and on the target it met")
}
if let slugHit = activate(module: .kineticSlug) {
    check(slugHit.payload == .consumed, "a slug is spent by the same contact")
    check(slugHit.target.integrity(id: "frame") <= 0.001,
          "a rigid slug goes through the target's structure rather than denting it")
    check(rotorsFouled(slugHit.carrier), "the aircraft that delivered it loses its rotors")
    check(slugHit.carrier.integrity(id: "frame") > 0.001 && slugHit.carrier.integrity(id: "frame") <= 0.15,
          "and is left wrecked but not scattered — the one thing separating it from a charge")
    check(slugHit.effects.contains { $0.vehicleID == InterceptCallsign.attacker && $0.kind == .secondary }
            && slugHit.effects.contains { $0.vehicleID == InterceptCallsign.target && $0.kind == .secondary },
          "a strike at interception speed is visible on both aircraft")
    check(!slugHit.effects.contains { $0.kind == .fire },
          "there is nothing in a slug to burn")
}
if let ballastHit = activate(module: .ballast) {
    check(ballastHit.carrier.integrity(id: "propeller.fl") > 0.5,
          "inert mass leaves the carrier's rotors alone — only the contact itself counts")
    check(!ballastHit.feedCut,
          "and does not black out the picture, which is the one thing the operator came to watch")
}
if let chargeHit = activate(module: .charge) {
    check(chargeHit.feedCut, "a module that goes off against your own airframe takes the picture with it")
}

// MARK: - The delivery side

// The mission read from the other end: the operator carries a load to a zone while an interceptor
// hunts them. Four cases were specified, and they reduce to one question — where the load ended up.
// These fly the four, including the two that differ only in what happened to the aircraft.
func deliveryRun(
    carrierState: InterceptFunctionalState,
    delivery: InterceptDeliveryState,
    seconds: TimeInterval = 1
) -> InterceptMissionResult? {
    var settings = InterceptMissionConfiguration()
    settings.side = .delivery
    var run = InterceptMissionRuntime(configuration: settings)
    run.worldReady()
    var vehicles = actors()
    vehicles[0].functionalState = carrierState
    run.step(deltaTime: seconds, vehicles: vehicles, impacts: [], observerCanConfirm: false, delivery: delivery)
    return run.result
}

check(deliveryRun(carrierState: .nominal, delivery: .landedInside)?.success == true,
      "an untouched aircraft whose load reached the zone succeeded")
check(deliveryRun(carrierState: .nominal, delivery: .landedInside)?.reason == .payloadDelivered,
      "and it is reported as a delivery, not as a surviving aircraft")
check(deliveryRun(carrierState: .crashed, delivery: .landedInside)?.success == true,
      "a wrecked aircraft whose load still reached the zone also succeeded — the aircraft is not the mission")
check(deliveryRun(carrierState: .nominal, delivery: .landedOutside)?.success == false,
      "an untouched aircraft that put the load down short failed")
check(deliveryRun(carrierState: .nominal, delivery: .landedOutside)?.reason == .payloadLost,
      "with nothing to blame but the drop")
check(deliveryRun(carrierState: .crashed, delivery: .landedOutside)?.reason == .attackerLost,
      "and a load that came down short after the hunter got there reads as a lost aircraft")
check(deliveryRun(carrierState: .nominal, delivery: .falling) == nil,
      "a load still in the air decides nothing yet")
check(deliveryRun(carrierState: .crashed, delivery: .falling) == nil,
      "including when the aircraft that dropped it is already gone — the run waits for the load")
check(deliveryRun(carrierState: .crashed, delivery: .carried)?.reason == .attackerLost,
      "a load that went down with the aircraft is a lost aircraft")
check(deliveryRun(carrierState: .nominal, delivery: .carried,
                  seconds: InterceptMissionConfiguration().timeLimit + 1)?.reason == .timeExpired,
      "and carrying it around until the clock runs out is a failure of its own")

// The configuration has to be coherent on its own: one behaviour, and a boundary that contains the
// place the load has to reach.
var deliverySettings = InterceptMissionConfiguration()
deliverySettings.side = .delivery
deliverySettings.targetBehavior = .routeFollower
deliverySettings.areaRadius = 120
let deliveryValidated = deliverySettings.validated
check(deliveryValidated.targetBehavior == .interceptorPursuit,
      "the aircraft on the delivery side hunts — it is not left to the setup screen to get right")
let zoneReach = simd_length(SIMD2<Float>(
    deliveryValidated.deliveryZoneOffset.x, deliveryValidated.deliveryZoneOffset.z
))
check(deliveryValidated.areaRadius >= zoneReach + deliveryValidated.deliveryZoneRadius,
      "and the mission area contains the zone the run has to reach")
var interceptSettings = InterceptMissionConfiguration()
interceptSettings.targetBehavior = .interceptorPursuit
check(interceptSettings.validated.targetBehavior != .interceptorPursuit,
      "a target that hunts the interceptor is a different mission and cannot be selected into this one")
check(!InterceptTargetBehavior.selectable.contains(.interceptorPursuit),
      "so the picker does not offer it")

// What the aircraft carries is not always ordnance. The delivery side is flown with cargo, and the
// two lists overlap only where a load makes sense on both.
check(AttachedModuleShape.selectable(for: .delivery).contains(.supplyCrate),
      "a delivery run can be made with cargo rather than a weapon")
check(!AttachedModuleShape.selectable(for: .interceptor).contains(.medicalPack),
      "and an interceptor does not fly out with a medical pack taped to it")
check(!AttachedModuleShape.selectable(for: .delivery).contains(.net),
      "nor is a net something anybody delivers")
check(AttachedModuleShape.selectable(for: .delivery).contains(.charge),
      "a charge is still a thing that can be delivered")
for cargo in [AttachedModuleShape.supplyCrate, .medicalPack, .sensorPod] {
    check(cargo.effectProfile == .contactOnly, "\(cargo.rawValue) does nothing to what it touches")
    check(cargo.massKg > AttachedModuleShape.net.massKg,
          "\(cargo.rawValue) is real cargo — heavier than anything on the interception list")
}
// Switching sides with a load already chosen must not leave the other side's load selected.
var swapped = InterceptMissionConfiguration()
swapped.moduleShape = .net
swapped.side = .delivery
check(AttachedModuleShape.selectable(for: .delivery).contains(swapped.validated.moduleShape),
      "switching sides substitutes a load that belongs to the new one")
check(swapped.validated.payloadProfile == swapped.validated.moduleShape.effectProfile,
      "and the effect follows the substituted load, not the one that was dropped")

// Ballistics. A drop is a piece of flying: where the load lands depends on where, how fast and how
// high it was let go, which is the whole skill of the delivery side.
func drop(from height: Float, speed: Float, offset: Float) -> InterceptDeliveryRuntime {
    var load = InterceptDeliveryRuntime(
        zoneCentre: SIMD3<Float>(0, 0, 0), zoneRadius: 45,
        massKg: AttachedModuleShape.charge.massKg, size: AttachedModuleShape.charge.sizeMeters
    )
    load.release(
        from: SIMD3<Float>(0, height, offset),
        velocity: SIMD3<Float>(0, 0, -speed)
    )
    var ticks = 0
    while load.state == .falling, ticks < 6000 {
        load.step(deltaTime: 1.0 / 60.0, groundHeight: 0)
        ticks += 1
    }
    return load
}
let overhead = drop(from: 60, speed: 0, offset: 0)
check(overhead.state == .landedInside, "a load let go over the middle of the zone lands in it")
check(overhead.position.y <= 0.001, "and it comes to rest on the ground rather than falling forever")
let downrange = drop(from: 60, speed: 18, offset: 0)
check(downrange.position.z < -20,
      "let go at speed it carries on downrange, so the release point is not the impact point")
check(downrange.state == .landedOutside || simd_length(SIMD2<Float>(downrange.position.x, downrange.position.z)) > 20,
      "which is exactly what makes the drop a decision rather than a button")
let higher = drop(from: 140, speed: 18, offset: 0)
check(higher.position.z < downrange.position.z,
      "and dropping from higher throws it further, because it falls for longer")
let short = drop(from: 60, speed: 0, offset: 300)
check(short.state == .landedOutside, "a load let go far from the zone lands outside it")

// Pursuit. A hunter that flies at where its quarry is never catches anything that is moving.
var hunter = InterceptTargetGuidance()
var hunterPosition = SIMD3<Float>(0, 60, 120)
// The hunter is the faster aircraft — in the mission proper its cruise is scaled by the difficulty's
// agility. Without an advantage a stern chase is not a chase, it is two aircraft in formation.
let hunterSpeed: Float = 24
let quarrySpeed = SIMD3<Float>(0, 0, -16)
var quarry = SIMD3<Float>(0, 60, 0)
var closest = Float.greatestFiniteMagnitude
let hunterDt: Float = 1.0 / 30.0
for _ in 0..<(30 * 40) {
    let aim = hunter.aimPoint(InterceptTargetGuidance.Situation(
        behavior: .interceptorPursuit, agility: 1.4, position: hunterPosition,
        velocity: SIMD3<Float>(0, 0, -hunterSpeed), spawnPosition: SIMD3<Float>(0, 60, 120),
        attacker: quarry, attackerVelocity: quarrySpeed, origin: .zero, areaRadius: 280,
        isFixedWing: false, isDamaged: false, deltaTime: hunterDt
    ))
    let course = InterceptTargetGuidance.planar(aim - hunterPosition)
    hunterPosition += course * hunterSpeed * hunterDt
    hunterPosition.y = aim.y
    quarry += quarrySpeed * hunterDt
    closest = min(closest, simd_distance(hunterPosition, quarry))
}
check(closest < 20, "a hunter with a speed advantage closes on a fleeing quarry")
check(abs(hunterPosition.y - quarry.y) < 1,
      "and follows it in height rather than holding the altitude it spawned at")

// The harder test: a quarry that keeps turning. A fixed lead aims at a point it never passes
// through, and pure pursuit trails it round the circle forever. Only a collision course cuts in.
func chase(quarrySpeed: Float, hunterSpeed: Float, turnRate: Float, seconds: Float) -> Float {
    var guidance = InterceptTargetGuidance()
    var hunter = SIMD3<Float>(0, 60, 160)
    var runner = SIMD3<Float>(0, 60, 0)
    var runnerCourse = SIMD3<Float>(0, 0, -1)
    var closest = Float.greatestFiniteMagnitude
    let dt: Float = 1.0 / 30.0
    var elapsed: Float = 0
    while elapsed < seconds {
        let angle = turnRate * dt
        runnerCourse = InterceptTargetGuidance.planar(SIMD3<Float>(
            runnerCourse.x * cos(angle) + runnerCourse.z * sin(angle),
            0,
            -runnerCourse.x * sin(angle) + runnerCourse.z * cos(angle)
        ))
        let runnerVelocity = runnerCourse * quarrySpeed
        let aim = guidance.aimPoint(InterceptTargetGuidance.Situation(
            behavior: .interceptorPursuit, agility: 1.4, position: hunter,
            velocity: SIMD3<Float>(0, 0, -hunterSpeed), spawnPosition: SIMD3<Float>(0, 60, 160),
            attacker: runner, attackerVelocity: runnerVelocity, origin: .zero, areaRadius: 400,
            isFixedWing: false, isDamaged: false, deltaTime: dt
        ))
        hunter += InterceptTargetGuidance.planar(aim - hunter) * hunterSpeed * dt
        hunter.y = aim.y
        runner += runnerVelocity * dt
        closest = min(closest, simd_distance(hunter, runner))
        elapsed += dt
    }
    return closest
}
check(chase(quarrySpeed: 16, hunterSpeed: 22, turnRate: 0.25, seconds: 45) < 12,
      "a hunter cuts the corner on a quarry that keeps turning instead of trailing it round")
check(chase(quarrySpeed: 16, hunterSpeed: 22, turnRate: 0, seconds: 45) < 12,
      "and still runs down one flying straight")

// Difficulty is how far the load has to be carried and how precisely it has to be put down.
let easyZone = InterceptMissionConfiguration.make(difficulty: .easy)
let mediumZone = InterceptMissionConfiguration.make(difficulty: .medium)
let hardZone = InterceptMissionConfiguration.make(difficulty: .hard)
func zoneReach(_ configuration: InterceptMissionConfiguration) -> Float {
    simd_length(SIMD2<Float>(configuration.deliveryZoneOffset.x, configuration.deliveryZoneOffset.z))
}
check(zoneReach(easyZone) < zoneReach(mediumZone) && zoneReach(mediumZone) < zoneReach(hardZone),
      "a harder run carries the load further, with the hunter on it the whole way")
check(zoneReach(easyZone) > 800, "and even the easy one is a transit rather than a hop")
check(easyZone.deliveryZoneRadius > mediumZone.deliveryZoneRadius
        && mediumZone.deliveryZoneRadius > hardZone.deliveryZoneRadius,
      "and asks the load to be put down more precisely")
for configuration in [easyZone, mediumZone, hardZone] {
    var picked = configuration
    picked.side = .delivery
    let validated = picked.validated
    check(validated.areaRadius >= zoneReach(validated) + validated.deliveryZoneRadius,
          "every difficulty's boundary still contains its own zone")
}

// The hunter flown for real, against the easiest target there is: an aircraft hovering in place.
// The guidance can be right and the approach still miss — the aim point is a lever, and with the
// fixed 95 m one this used to carry, passes went by at 14, 7 and 5 metres before one connected.
// What is measured here is what the operator sees: how close it actually gets, and whether the
// contact service ever registers anything.
func hunterRun(
    hunterAt spawn: SIMD3<Float>,
    playerAt player: SIMD3<Float>,
    wood: Bool = false,
    retreating: Bool = false,
    seconds: Float = 40
) -> (closest: Float, contacts: Int, hunter: InterceptFunctionalState)? {
    guard let fast = LIPODroneModelRepository().allProfiles
        .filter({ $0.airframeClass == .multirotor })
        .max(by: { $0.maxHorizontalSpeedMps < $1.maxHorizontalSpeedMps }) else { return nil }
    var settings = InterceptMissionConfiguration()
    settings.side = .delivery
    settings = settings.validated

    let mass = VehicleMassModel.baseline(for: fast, uavProfile: fast.resolvedUAVProfile)
    let hull = VehicleContactProfile(
        spheres: [VehicleContactSphere(componentID: "frame", offset: .zero, radius: 0.4)],
        boundingRadius: 0.4
    )
    func actor(_ id: String, role: InterceptVehicleRole, at position: SIMD3<Float>) -> InterceptVehicleRuntime {
        InterceptVehicleRuntime(
            id: id, role: role, profile: fast, massModel: mass, position: position,
            graph: rotorHull(mass: 7), contacts: hull, rotors: .empty, payload: nil, seed: 7,
            initialCourse: SIMD3<Float>(0, 0, -1)
        )
    }
    let hunter = actor(InterceptCallsign.target, role: .target, at: spawn)
    hunter.cruiseSpeedScale = 1.35
    let session = InterceptMissionSession(
        configuration: settings,
        target: hunter,
        observer: actor(InterceptCallsign.observer, role: .observer, at: spawn + SIMD3<Float>(220, 20, 160)),
        origin: .zero,
        deliveryZone: SIMD3<Float>(0, 0, -1500)
    )

    // A wood of 28 m trunks over the whole engagement.
    var obstacles: [CollisionObstacle] = []
    if wood {
        for gx in -10...10 {
            for gz in -10...14 {
                obstacles.append(CollisionObstacle(
                    id: UUID(), center: SIMD3<Float>(Float(gx) * 22 + 6, 14, Float(gz) * 22 - 10),
                    radius: 2.5, source: "tree", baseY: 0, topY: 28,
                    planarHalfExtents: nil, yawRadians: 0, meshTriangles: nil, planarFootprint: nil))
            }
        }
    }

    var previous = DroneState.initial
    previous.position = player
    previous.physicalState = .airborne
    var state = previous
    var graph = rotorHull(mass: 7)
    var closest = Float.greatestFiniteMagnitude
    var contacts = 0
    let dt: Float = 1.0 / 60.0
    for _ in 0..<Int(60 * seconds) {
        // `retreating` keeps the quarry permanently just ahead of the hunter, so it is committed
        // for the whole run and never gets to ram anything: whatever happens to it came from the
        // wood. `hovering` is the opposite case — the easiest possible intercept.
        let quarry = retreating ? hunter.state.position + SIMD3<Float>(0, 0, -50) : player
        previous = state
        state.position = quarry
        contacts += session.simulate(
            deltaTime: dt, playerPrevious: previous, player: &state, playerGraph: &graph,
            playerContacts: hull, playerClass: .multirotor, weather: .normal, wind: .zero,
            ground: { _, _ in 0 }, obstacles: { _, _, _ in obstacles }
        ).count
        state.position = quarry
        state.velocity = .zero
        closest = min(closest, simd_distance(hunter.state.position, quarry))
    }
    return (closest, contacts, hunter.snapshot.functionalState)
}
if let astern = hunterRun(hunterAt: SIMD3<Float>(0, 70, 150), playerAt: SIMD3<Float>(0, 70, 0)) {
    check(astern.closest <= 1, "a hunter reaches an aircraft that is hovering in front of it")
    check(astern.contacts >= 1, "and the contact is registered rather than flown past")
}
if let crossing = hunterRun(hunterAt: SIMD3<Float>(0, 52, 150), playerAt: SIMD3<Float>(-70, 90, 60)) {
    check(crossing.closest <= 1,
          "including from below and off to one side, where it has to climb and turn to get there")
    check(crossing.contacts >= 1, "and that approach connects too")
}
// The wood. Avoidance switched off for a committed hunter made it destroy itself on trunks after
// a few hundred metres; avoidance left wide open put it permanently above the canopy where it
// could not reach anything. What survives both is a *heading-aware* altitude rule: hop the trunk
// that is actually in the path, and come down behind it.
if let chase = hunterRun(
    hunterAt: SIMD3<Float>(0, 18, 260), playerAt: .zero,
    wood: true, retreating: true, seconds: 60
) {
    check(!chase.hunter.isTerminal,
          "a hunter chasing under the canopy survives the wood instead of flying into it")
    check(chase.hunter == .nominal,
          "and comes through it without collecting damage on the way")
}
if let woodedApproach = hunterRun(
    hunterAt: SIMD3<Float>(0, 70, 150), playerAt: SIMD3<Float>(0, 70, 0), wood: true
) {
    check(woodedApproach.closest <= 1, "and still reaches a quarry hovering above that wood")
    check(!woodedApproach.hunter.isTerminal, "having got there in one piece")
}

if failures.isEmpty { print("PASS: \(checks) interception checks") }
else { failures.forEach { print("FAIL: \($0)") }; exit(1) }
