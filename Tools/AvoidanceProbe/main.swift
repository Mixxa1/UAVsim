import Foundation
import simd

// Headless obstacle-avoidance probe.
//
// Chains the three parts that decide whether a fixed wing gets through a built-up area:
//
//   1. `AutoPathPlannerService` plans a route across a synthetic city block layout,
//   2. `FixedWingAutopilotController` + `SimpleDronePhysicsEngine` fly that route,
//   3. every flown chord is swept against the same obstacles with the aircraft's own envelope.
//
// Step 3 is the point. A planner that returns a route "around" obstacles proves nothing if the
// airframe cannot hold it, and a follower that tracks its route proves nothing if the route was
// never flyable. Only sweeping the *flown* path against the *same* geometry tests both at once.
//
// The scenario runs twice, under the two planner configurations the codebase actually uses, so
// the trade-off between them is visible in one output instead of inferred from flight logs.
//
// Not covered: the reactive avoidance layer, which lives in `DroneSimulationViewModel` behind
// SceneKit. This probe is about planner + follower.
//
// Run: Tools/AvoidanceProbe/run.sh

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

let altitude: Float = 60.0
let envelopeRadius: Float = max(profile.collisionRadius, 3.0)

// An L-shaped street network: the only route from start to goal runs south down the x=0 street,
// then east along the z=-520 street. A straight line between them crosses several blocks, so a
// pass requires the planner to find the corner and the airframe to actually fly it.
let blockPitch: Float = 260.0
let blockHalf = SIMD2<Float>(85.0, 85.0)
let openColumn = 0
let openRow = 2
var obstacles: [CollisionObstacle] = []
for row in -1...4 {
    for column in -2...3 {
        if column == openColumn || row == openRow { continue }
        let center = SIMD2<Float>(Float(column) * blockPitch, Float(row) * -blockPitch)
        obstacles.append(
            CollisionObstacle(
                id: UUID(),
                center: SIMD3<Float>(center.x, 60.0, center.y),
                radius: simd_length(blockHalf),
                source: "world.building",
                baseY: 0.0,
                topY: 120.0,
                planarHalfExtents: blockHalf
            )
        )
    }
}

let terrain = TerrainConfiguration(
    preset: .field,
    mapScale: .x64,
    density: 0.5,
    seed: 42,
    safeSpawnRadius: 40.0
)

let start = SIMD3<Float>(0, altitude, 120.0)
let goal = SIMD3<Float>(Float(3) * blockPitch, altitude, Float(openRow) * -blockPitch)

let planningSpeed = wing.cruiseAirspeed * 1.45
let planningBankDegrees: Float = 22.0
let turnRadius = planningSpeed * planningSpeed
    / (9.81 * tan(planningBankDegrees * .pi / 180.0))
let manoeuvreReserve = turnRadius + planningSpeed * 0.9

print("profile: \(profile.displayName)")
print(String(
    format: "envelope %.1f m   altitude %.0f m   planning speed %.1f m/s   turn radius %.0f m",
    envelopeRadius, altitude, planningSpeed, turnRadius
))
print("city: \(obstacles.count) buildings 170x170 m, 120 m tall, \(Int(blockPitch)) m pitch (90 m streets)")
print(String(format: "start (%.0f, %.0f) -> goal (%.0f, %.0f)", start.x, start.z, goal.x, goal.z))

enum Outcome {
    case noRoute(String)
    case collision(SIMD3<Float>, String)
    case strandedShort(SIMD3<Float>)
    case reached(seconds: Float, maxBank: Float, clearance: Float)
}

func runScenario(
    manoeuvreReserveMeters: Float,
    repairCorners: Bool = false,
    repairRadius: Float? = nil
) -> Outcome {
    let planner = AutoPathPlannerService()
    planner.planIfNeeded(
        start: start,
        goal: goal,
        terrain: terrain,
        obstacles: obstacles,
        obstacleSignature: 1,
        droneRadius: envelopeRadius,
        minimumObstacleRadiusFactor: manoeuvreReserveMeters > 0.0 ? 1.0 : 0.0,
        additionalHardClearance: manoeuvreReserveMeters,
        modeTag: "avoidance_probe",
        forceRecompute: true,
        reason: "probe"
    )
    let plan = planner.snapshot(currentPosition: start)
    guard plan.status == .valid, plan.waypoints.count >= 2 else {
        return .noRoute(plan.reason)
    }

    var routePlanar = plan.waypoints.map { SIMD2<Float>($0.x, $0.z) }
    if repairCorners {
        let repair = FixedWingRouteRepair.repair(
            route: routePlanar,
            turnRadius: repairRadius ?? turnRadius,
            clearanceRadius: envelopeRadius,
            altitude: altitude,
            obstacles: obstacles,
            collisionService: CollisionAnalysisService(),
            maximumOutwardShiftMeters: repairRadius ?? turnRadius
        )
        print(String(
            format: "   repair: %d corners fixed, %d unrepairable, %d -> %d points",
            repair.repairedCorners, repair.unrepairableCorners,
            routePlanar.count, repair.points.count
        ))
        routePlanar = repair.points
    }
    let tracking = FixedWingRouteTrackingContext(
        routeIdentifier: "avoidance-probe",
        waypoints: routePlanar.enumerated().map { index, planar in
            FixedWingRouteWaypoint(
                position: SIMD3<Float>(planar.x, altitude, planar.y),
                missionWaypointIndex: index == routePlanar.count - 1 ? 0 : nil,
                waypointIdentifier: index == routePlanar.count - 1 ? "goal" : nil
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

    var state = DroneState(
        position: start,
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
    let collisions = CollisionAnalysisService()
    let dt: Float = 1.0 / 60.0
    let maxTicks = 60 * 300

    var ticks = 0
    var maxBank: Float = 0.0
    var minimumClearance = Float.greatestFiniteMagnitude
    var peakSpeed: Float = 0.0

    while ticks < maxTicks {
        ticks += 1
        let previousPosition = state.position

        let context = AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: goal,
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

        state = engine.step(state: state, control: control, context: simContext, deltaTime: dt)
        maxBank = max(maxBank, abs(state.orientation.x * 180.0 / .pi))
        peakSpeed = max(peakSpeed, state.forwardAirspeed)

        // Sweep the chord actually flown, not the route it was supposed to follow.
        if let hit = collisions.firstSweptCenterCollision(
            from: previousPosition,
            to: state.position,
            radius: envelopeRadius,
            obstacles: obstacles
        ) {
            print(String(
                format: "   at contact: peak airspeed %.1f m/s -> implied radius %.0f m",
                peakSpeed,
                peakSpeed * peakSpeed / (9.81 * tan(22.0 * .pi / 180.0))
            ))
            return .collision(state.position, hit.obstacle.source)
        }
        let planar = SIMD2<Float>(state.position.x, state.position.z)
        for obstacle in obstacles {
            minimumClearance = min(minimumClearance, obstacle.planarSignedDistance(to: planar))
        }
        if simd_distance(planar, SIMD2<Float>(goal.x, goal.z)) <= wing.waypointAcceptanceRadiusMeters {
            return .reached(
                seconds: Float(ticks) * dt,
                maxBank: maxBank,
                clearance: minimumClearance
            )
        }
    }
    return .strandedShort(state.position)
}

func report(_ label: String, _ outcome: Outcome) -> Bool {
    print("")
    print("--- \(label)")
    switch outcome {
    case let .noRoute(reason):
        print("   planner produced NO ROUTE (reason: \(reason))")
        print("   the aircraft never departs; nothing is demonstrated about avoidance")
        return false
    case let .collision(position, source):
        print(String(
            format: "   COLLISION with %@ at (%.0f, %.0f)",
            source as NSString, position.x, position.z
        ))
        print("   the planner called this route valid; the airframe could not hold it")
        return false
    case let .strandedShort(position):
        print(String(format: "   no collision, but goal never reached; stopped at (%.0f, %.0f)", position.x, position.z))
        return false
    case let .reached(seconds, maxBank, clearance):
        print(String(
            format: "   reached goal in %.0fs, max bank %.1fdeg, min clearance %.1f m",
            seconds, maxBank, clearance
        ))
        if maxBank < 10.0 {
            print("   but it never turned — the scenario did not exercise a detour")
            return false
        }
        return true
    }
}

let pointSafe = report(
    "A) planner as a multicopter uses it (no manoeuvre reserve)",
    runScenario(manoeuvreReserveMeters: 0.0)
)
let manoeuvreSafe = report(
    String(format: "B) planner as the fixed-wing path uses it (reserve %.0f m)", manoeuvreReserve),
    runScenario(manoeuvreReserveMeters: manoeuvreReserve)
)
print("")
print("--- C) point-safe grid + FixedWingRouteRepair at the live radius")
let repairedSafe = report(
    "C) result",
    runScenario(manoeuvreReserveMeters: 0.0, repairCorners: true)
)

// The radius the *follower* will actually fly, by its own formula: speed cruise*1.12, bank
// capped at FixedWingAutopilot.Tuning.flyByBankLimitDeg. Validating a repair against anything
// else repeats the mistake this whole exercise keeps finding — a proof at a radius the executor
// does not use.
func followerRadius(flyByBankLimitDegrees: Float) -> Float {
    let speed = max(wing.cruiseAirspeed * 1.12, wing.minSafeAirspeed)
    let bank = min(flyByBankLimitDegrees, wing.maxBankAngleDeg * 0.95)
    return max(
        wing.waypointAcceptanceRadiusMeters * 1.05,
        wing.minimumTurnRadius(airspeed: speed),
        speed * speed / (9.81 * tan(bank * .pi / 180.0))
    )
}

let shippedFlyByRadius = followerRadius(flyByBankLimitDegrees: 22.0)
print("")
print(String(
    format: "--- D) point-safe grid + repair at the FOLLOWER radius %.0f m (22deg fly-by cap)",
    shippedFlyByRadius
))
let achievableSafe = report(
    "D) result",
    runScenario(manoeuvreReserveMeters: 0.0, repairCorners: true, repairRadius: shippedFlyByRadius)
)

let widenedFlyByRadius = followerRadius(flyByBankLimitDegrees: 35.0)
print("")
print(String(
    format: "--- E) control: repair validated at %.0f m while the follower still flies %.0f m",
    widenedFlyByRadius, shippedFlyByRadius
))
let widenedSafe = report(
    "E) result",
    runScenario(manoeuvreReserveMeters: 0.0, repairCorners: true, repairRadius: widenedFlyByRadius)
)

print("")
if pointSafe || manoeuvreSafe || repairedSafe || achievableSafe || widenedSafe {
    print("RESULT: PASS - at least one configuration flies the detour cleanly")
    exit(0)
}
print("RESULT: FAIL - neither configuration gets a fixed wing through this street network")
print("  A route that is only point-safe cannot be held at this turn radius, and a reserve")
print("  large enough to guarantee it blocks every cell. That squeeze is the finding.")
exit(1)
