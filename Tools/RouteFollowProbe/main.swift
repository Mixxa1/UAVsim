import Foundation
import simd

// Headless closed-loop route-following probe.
//
// Runs `FixedWingAutopilotController` against `SimpleDronePhysicsEngine` over a multi-waypoint
// route in empty airspace: no SceneKit, no world, no obstacles. That isolates one question —
// *can the follower and the airframe fly a polyline at all* — from the separate question of
// whether the planner can route around a city. Flight logs cannot separate those two; this can.
//
// It also pins down the contract the follower depends on. `.required` waypoints (every
// operator-authored mission point) put the autopilot into a measured-course hold on capture, and
// it stays there until the owner publishes a *new route built from the measured pose*. Model that
// handshake and the whole route is flown; omit it and the aircraft flies straight past the first
// waypoint forever at zero bank. `simulateReplanHandshake` below toggles exactly that.
//
// Run: Tools/RouteFollowProbe/run.sh

let simulateReplanHandshake = !CommandLine.arguments.contains("--no-replan-handshake")

let repository = LIPODroneModelRepository()
let fixedWings = repository.allProfiles.filter { $0.airframeClass == .fixedWing }
let profile: DroneModelProfile = fixedWings.first { $0.id == "sensefly-ebee-tac" } ?? fixedWings[0]

let wing: FixedWingParameters = profile.fixedWingParameters!
let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
let baseline = FlightBaselineResolver.resolve(
    runtimeProfile: profile,
    activeUAVProfile: nil,
    vehicleMassModel: massModel,
    flightMode: .autoPath
)

print("profile: \(profile.displayName)")
print(String(
    format: "cruise=%.1f m/s  minSafe=%.1f  maxBank=%.0fdeg  acceptance=%.1fm  climbTarget=%.0fm",
    wing.cruiseAirspeed, wing.minSafeAirspeed, wing.maxBankAngleDeg,
    wing.waypointAcceptanceRadiusMeters, wing.initialClimbTargetAltitude
))
print("replan handshake: \(simulateReplanHandshake ? "modelled" : "OMITTED")")

// Turns of increasing severity, at spacings a small survey wing should manage in open air.
let altitude: Float = 90.0
let route: [SIMD2<Float>] = [
    SIMD2(0, -400),
    SIMD2(350, -750),
    SIMD2(350, -1300),
    SIMD2(-150, -1650)
]

var routeGeneration = 0
var firstRemaining = 0
var routeStart = SIMD2<Float>(0, 0)
var handledCaptureIndex: Int?

/// The route as the owner would publish it: a start at the measured pose, then the operator
/// waypoints that have not been captured yet.
func makeTracking() -> FixedWingRouteTrackingContext {
    let remaining = Array(route[firstRemaining...])
    let published: [(SIMD2<Float>, Int?)] =
        [(routeStart, nil)] + remaining.enumerated().map { ($0.element, firstRemaining + $0.offset) }
    return FixedWingRouteTrackingContext(
        routeIdentifier: "probe-\(routeGeneration)",
        waypoints: published.map { planar, missionIndex in
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(planar.x, altitude, planar.y),
                missionWaypointIndex: missionIndex,
                waypointIdentifier: missionIndex.map { "w\($0)" }
            )
        },
        minimumWaypointIndex: 1,
        preferredLoiterCenter: nil,
        preferredLoiterRadius: nil,
        turnsValidated: true,
        validatedTurnRadiusMeters: nil,
        validatedAirspeedMps: wing.cruiseAirspeed,
        flyableRoute: nil
    )
}

var tracking = makeTracking()

var state = DroneState(
    position: SIMD3<Float>(0, altitude, 0),
    velocity: SIMD3<Float>(0, 0, -wing.cruiseAirspeed),
    orientation: SIMD3<Float>(0, 0, 0),
    angularVelocity: .zero,
    throttle: baseline.cruiseReferenceThrottle,
    motorThrottle: baseline.cruiseReferenceThrottle,
    rotorAngularSpeed: .zero,
    forwardAirspeed: wing.cruiseAirspeed,
    physicalState: .airborne,
    mode: .autoPath
)
state.armState = .armed

let engine = SimpleDronePhysicsEngine()
let controller = FixedWingAutopilotController()
let dt: Float = 1.0 / 60.0

var captured = Set<Int>()
var closest = [Int: Float](uniqueKeysWithValues: route.indices.map { ($0, .greatestFiniteMagnitude) })
var maxBank: Float = 0.0
var minSpeed = Float.greatestFiniteMagnitude
var minAltitude = Float.greatestFiniteMagnitude
var ticks = 0
let maxTicks = 60 * 400

while ticks < maxTicks, captured.count < route.count {
    ticks += 1

    let context = AutopilotTrackingContext(
        state: state,
        physicalState: .airborne,
        target: SIMD3<Float>(route[route.count - 1].x, altitude, route[route.count - 1].y),
        targetAltitude: altitude,
        speedScale: 1.0,
        yawAlignToHome: false,
        yawOverrideRadians: nil,
        deltaTime: dt,
        flightBaseline: baseline
    )
    let output = controller.trackingCommand(
        for: context,
        parameters: wing,
        launchMode: .standard,
        launchAsset: nil,
        routeTracking: tracking
    )

    let control = DroneControlInput(
        targetPosition: output.command.positionTarget,
        targetOrientation: SIMD3<Float>(
            output.command.rollDegrees * .pi / 180.0,
            output.command.pitchDegrees * .pi / 180.0,
            output.command.yawDegrees * .pi / 180.0
        ),
        yawIntent: 0.0,
        throttle: output.command.throttle,
        isArmed: true,
        mode: .autoPath,
        controlMode: .stabilized
    )

    let simContext = DroneSimulationContext(
        profile: profile,
        activeUAVProfile: nil,
        weather: .normal,
        damageState: .pristine,
        batteryState: .full,
        collisionRisk: 0.0,
        windVector: .zero,
        vehicleMassModel: massModel
    )

    if simulateReplanHandshake,
       let capturedIndex = output.debugState.capturedMissionWaypointIndexAwaitingReplan,
       capturedIndex != handledCaptureIndex {
        // What `MissionProgressTracker` + the view model do in the app: acknowledge the physical
        // capture and publish the next route from the aircraft's measured pose.
        handledCaptureIndex = capturedIndex
        firstRemaining = min(capturedIndex + 1, route.count - 1)
        routeStart = SIMD2<Float>(state.position.x, state.position.z)
        routeGeneration += 1
        tracking = makeTracking()
    }

    state = engine.step(state: state, control: control, context: simContext, deltaTime: dt)

    let planar = SIMD2<Float>(state.position.x, state.position.z)
    for (index, waypoint) in route.enumerated() {
        let distance = simd_distance(planar, waypoint)
        closest[index] = min(closest[index] ?? .greatestFiniteMagnitude, distance)
        if distance <= wing.waypointAcceptanceRadiusMeters {
            captured.insert(index)
        }
    }
    maxBank = max(maxBank, abs(state.orientation.x * 180.0 / .pi))
    minSpeed = min(minSpeed, state.forwardAirspeed)
    minAltitude = min(minAltitude, state.position.y)
}

print("")
print(String(format: "simulated %.0fs (%d ticks)", Float(ticks) * dt, ticks))
print(String(
    format: "max bank %.1fdeg   min airspeed %.1f m/s   min altitude %.1f m",
    maxBank, minSpeed, minAltitude
))
print("")
var passed = true
for index in route.indices {
    let distance = closest[index] ?? .greatestFiniteMagnitude
    let ok = captured.contains(index)
    passed = passed && ok
    print(String(format: "W%d %@  closest %8.1f m", index + 1, ok ? "CAPTURED" : "MISSED  ", distance))
}
print("")
print(passed ? "RESULT: PASS - every waypoint captured" : "RESULT: FAIL - route not flown")
exit(passed ? 0 : 1)
