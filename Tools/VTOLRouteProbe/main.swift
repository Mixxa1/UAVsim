import Darwin
import Foundation
import simd

// Headless contract probe for `HybridVTOLRouteCursor`.
//
// This does not simulate aerodynamics. It pins down the safety-critical handoff between a
// validated obstacle-avoiding route and rotor-borne/transition VTOL guidance: planner detours
// remain authoritative, progress is swept between ticks, malformed routes fail closed, and the
// fixed-wing controller can hand its monotonic route index back to the cursor.
//
// Run: Tools/VTOLRouteProbe/run.sh

private var failures: [String] = []

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

private func point(_ x: Float, _ z: Float, altitude: Float = 60.0) -> SIMD3<Float> {
    SIMD3<Float>(x, altitude, z)
}

private func route(
    _ identifier: String,
    _ points: [SIMD3<Float>],
    minimumWaypointIndex: Int? = 1,
    turnsValidated: Bool = true,
    traversalMode: ProtectedRouteTraversalMode = .continuousWingborne
) -> FixedWingRouteTrackingContext {
    FixedWingRouteTrackingContext(
        routeIdentifier: identifier,
        waypoints: points.enumerated().map { index, position in
            FixedWingRouteWaypoint(
                position: position,
                missionWaypointIndex: index == points.count - 1 ? 0 : nil,
                waypointIdentifier: index == points.count - 1 ? "final" : nil
            )
        },
        minimumWaypointIndex: minimumWaypointIndex,
        preferredLoiterCenter: points.last,
        preferredLoiterRadius: nil,
        traversalMode: traversalMode,
        turnsValidated: turnsValidated,
        validatedTurnRadiusMeters: nil,
        validatedAirspeedMps: nil,
        flyableRoute: nil
    )
}

private func update(
    _ cursor: inout HybridVTOLRouteCursor,
    route: FixedWingRouteTrackingContext?,
    finalTarget: SIMD3<Float>,
    position: SIMD3<Float>,
    controllerDebug: FixedWingAutopilotDebugState? = nil,
    intermediateRadius: Float = 3.0,
    corridorRadius: Float = 5.0,
    planarSpeed: Float = 0.0
) -> HybridVTOLRouteGuidance {
    cursor.update(
        route: route,
        expectedFinalTarget: finalTarget,
        position: position,
        controllerDebug: controllerDebug,
        intermediateRadius: intermediateRadius,
        corridorRadius: corridorRadius,
        planarSpeed: planarSpeed
    )
}

private func testStopAndPivotRequiresExactSlowCaptureAndAlignment() {
    let start = point(0, 0)
    let corner = point(10, 0)
    let final = point(10, 10)
    let protectedRoute = route(
        "stop-and-pivot",
        [start, corner, final],
        turnsValidated: false,
        traversalMode: .stopAndPivotVTOL
    )
    var cursor = HybridVTOLRouteCursor()

    let initial = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: start,
        planarSpeed: 0.0
    )
    checkReady(initial, index: 1, target: corner, "stop/pivot initial")
    check(
        initial.traversalMode == .stopAndPivotVTOL,
        "stop/pivot initial: traversal mode must survive route-to-guidance bridging"
    )

    var staleWingborneDebug = FixedWingAutopilotDebugState.idle
    staleWingborneDebug.routeIdentifier = "stop-and-pivot"
    staleWingborneDebug.activeSegmentIndex = 2
    var debugIsolationCursor = HybridVTOLRouteCursor()
    let debugIsolation = update(
        &debugIsolationCursor,
        route: protectedRoute,
        finalTarget: final,
        position: start,
        controllerDebug: staleWingborneDebug,
        planarSpeed: 0.0
    )
    checkReady(
        debugIsolation,
        index: 1,
        target: corner,
        "stop/pivot ignores fixed-wing cursor synchronization"
    )

    // Continuous mode deliberately accepts swept/projection passage. Stop-and-pivot must not:
    // one metre early consumes the raw A* physical margin, and 2.4 m/s is not a stop.
    let oneMetreEarly = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(9.0, 0),
        planarSpeed: 0.0
    )
    checkReady(oneMetreEarly, index: 1, target: corner, "stop/pivot one metre early")

    let fastInside = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(9.5, 0),
        planarSpeed: 2.4
    )
    checkReady(fastInside, index: 1, target: corner, "stop/pivot fast capture")

    let stoppedInside = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(9.35, 0),
        planarSpeed: 0.40
    )
    checkReady(stoppedInside, index: 2, target: final, "stop/pivot exact slow capture")

    var gate = HybridVTOLStopAndPivotGate()
    let turnRequired = gate.update(
        traversalMode: .stopAndPivotVTOL,
        routeIdentifier: "stop-and-pivot",
        routeIndex: 2,
        position: point(9.35, 0),
        planarSpeed: 0.40,
        headingErrorRadians: .pi / 2.0,
        yawRateRadiansPerSecond: 0.0
    )
    check(turnRequired.shouldHold, "stop/pivot gate: translation must wait for heading alignment")
    check(
        turnRequired.holdPosition == point(9.35, 0),
        "stop/pivot gate: corner hold must latch the first measured pose"
    )

    let aligned = gate.update(
        traversalMode: .stopAndPivotVTOL,
        routeIdentifier: "stop-and-pivot",
        routeIndex: 2,
        position: point(9.6, 0),
        planarSpeed: 0.20,
        headingErrorRadians: 3.0 * .pi / 180.0,
        yawRateRadiansPerSecond: 0.08
    )
    check(!aligned.shouldHold, "stop/pivot gate: settled aligned vehicle may translate")

    check(
        !HybridVTOLFlightPolicy.allowsReactiveHoverSidestep(
            decisionReason: "vtol_stop_and_pivot_align"
        ),
        "stop/pivot gate: reactive sidestep must not replace an exact corner hold"
    )
    check(
        HybridVTOLFlightPolicy.allowsReactiveHoverSidestep(
            decisionReason: "vtol_hover_hold_short_leg"
        ),
        "stop/pivot gate: ordinary hover guidance must retain reactive avoidance"
    )
}

private func testGenericPlannerClearanceOwnership() {
    check(
        HybridVTOLFlightPolicy.genericPlannerUsesWholeTurnHardClearance(
            airframeClass: .fixedWing
        ),
        "generic planner: conventional fixed wing keeps full-turn hard clearance"
    )
    check(
        !HybridVTOLFlightPolicy.genericPlannerUsesWholeTurnHardClearance(
            airframeClass: .hybridVTOL
        ),
        "generic planner: hybrid VTOL must expose physical-envelope A* to stop-and-pivot fallback"
    )
    check(
        !HybridVTOLFlightPolicy.genericPlannerUsesWholeTurnHardClearance(
            airframeClass: .multirotor
        ),
        "generic planner: multirotor must not receive fixed-wing turn dilation"
    )
    check(
        HybridVTOLFlightPolicy.supportsStopAndPivotVTOL(
            airframeClass: .hybridVTOL
        ),
        "stop/pivot policy: hybrid VTOLs, including tailsitters, must be eligible"
    )
    check(
        !HybridVTOLFlightPolicy.supportsStopAndPivotVTOL(
            airframeClass: .fixedWing
        ),
        "stop/pivot policy: conventional fixed wing must remain fail-closed"
    )
    check(
        HybridVTOLFlightPolicy.stopAndPivotYawRate(
            isTailsitter: true,
            tailsitterBodyXRate: 0.12,
            conventionalYawRate: 9.0
        ) == 0.12,
        "stop/pivot policy: tailsitter settle gate must read physical body-X yaw rate"
    )
    check(
        HybridVTOLFlightPolicy.stopAndPivotYawRate(
            isTailsitter: false,
            tailsitterBodyXRate: 9.0,
            conventionalYawRate: 0.14
        ) == 0.14,
        "stop/pivot policy: tilt-rotor settle gate must read conventional yaw rate"
    )
}

private func checkReady(
    _ guidance: HybridVTOLRouteGuidance,
    index: Int,
    target: SIMD3<Float>,
    _ context: String
) {
    check(guidance.status == .ready, "\(context): guidance must be ready")
    check(guidance.isReady, "\(context): ready guidance must expose a target")
    check(guidance.activeRouteIndex == index, "\(context): expected route index \(index)")
    check(guidance.guidanceTarget == target, "\(context): unexpected guidance target")
    check(guidance.remainingPathMeters.isFinite, "\(context): remaining path must be finite")
}

private func checkBlocked(
    _ guidance: HybridVTOLRouteGuidance,
    reason: String,
    _ context: String
) {
    check(guidance.status == .blocked(reason), "\(context): expected blocked(\(reason))")
    check(!guidance.isReady, "\(context): blocked guidance must not be ready")
    check(guidance.guidanceTarget == nil, "\(context): blocked guidance must have no target")
    check(guidance.activeRouteIndex == nil, "\(context): blocked guidance must have no index")
    check(guidance.remainingPathMeters == .infinity, "\(context): blocked path must be infinite")
}

private func testIntermediateDetourIsNotCut() {
    let start = point(0, 0)
    let detour = point(0, 100)
    let final = point(100, 100)
    let protectedRoute = route("detour", [start, detour, final])
    var cursor = HybridVTOLRouteCursor()

    let initial = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: start
    )
    checkReady(initial, index: 1, target: detour, "detour initial")
    check(!initial.isFinalSegment, "detour initial: intermediate must not be marked final")

    // The aircraft moved toward the raw final target, diagonally across the protected corner.
    // It crossed the detour's abeam plane far outside the certified corridor, so the cursor must
    // keep commanding the detour instead of silently accepting the shortcut.
    let attemptedShortcut = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: final
    )
    checkReady(attemptedShortcut, index: 1, target: detour, "detour shortcut")
    check(!attemptedShortcut.isFinalSegment, "detour shortcut: protected intermediate was skipped")
}

private func testHighDeltaTimeSweptAdvanceAndFinalOwnership() {
    let start = point(0, 0)
    let intermediate = point(0, 50)
    let final = point(0, 100)
    let protectedRoute = route("swept", [start, intermediate, final])
    var cursor = HybridVTOLRouteCursor()

    let before = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(0, 40)
    )
    checkReady(before, index: 1, target: intermediate, "swept before")

    // Models one long frame: neither sample is inside the intermediate sphere, but the motion
    // segment crosses it. A point-sampled cursor would miss this and turn back.
    let after = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(0, 65)
    )
    checkReady(after, index: 2, target: final, "swept after")
    check(after.isFinalSegment, "swept after: cursor must enter the final segment")

    let onFinal = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: final
    )
    checkReady(onFinal, index: 2, target: final, "final sphere")
    check(onFinal.isFinalSegment, "final sphere: final remains owned by mission progress")

    let beyondFinal = update(
        &cursor,
        route: protectedRoute,
        finalTarget: final,
        position: point(0, 120)
    )
    checkReady(beyondFinal, index: 2, target: final, "beyond final")
    check(beyondFinal.isFinalSegment, "beyond final: route cursor must not auto-complete")
}

private func testInvalidRoutesFailClosed() {
    let start = point(0, 0)
    let final = point(0, 100)
    let validRoute = route("valid", [start, final])
    var cursor = HybridVTOLRouteCursor()

    _ = update(&cursor, route: validRoute, finalTarget: final, position: start)
    check(cursor.routeIdentifier == "valid", "fail-closed setup: valid route was not adopted")

    let missing = update(&cursor, route: nil, finalTarget: final, position: start)
    checkBlocked(missing, reason: "missing_route", "missing route")
    check(cursor.routeIdentifier == nil, "missing route: cursor state must reset")

    let unvalidatedRoute = route("unvalidated", [start, final], turnsValidated: false)
    checkBlocked(
        update(&cursor, route: unvalidatedRoute, finalTarget: final, position: start),
        reason: "route_not_validated",
        "unvalidated route"
    )

    let emptyIdentifierRoute = route("", [start, final])
    checkBlocked(
        update(&cursor, route: emptyIdentifierRoute, finalTarget: final, position: start),
        reason: "missing_route_identifier",
        "empty route identifier"
    )

    let onePointRoute = route("short", [final])
    checkBlocked(
        update(&cursor, route: onePointRoute, finalTarget: final, position: start),
        reason: "route_has_no_guidance_leg",
        "one-point route"
    )

    let mismatchedFinalRoute = route("mismatch", [start, point(20, 100)])
    checkBlocked(
        update(&cursor, route: mismatchedFinalRoute, finalTarget: final, position: start),
        reason: "route_final_mismatch",
        "final mismatch"
    )

    checkBlocked(
        update(
            &cursor,
            route: validRoute,
            finalTarget: final,
            position: start,
            intermediateRadius: 0.0
        ),
        reason: "invalid_intermediate_radius",
        "invalid radius"
    )
}

private func testPlannerAltitudeNormalization() {
    let routeAltitude: Float = 17.306
    let overshootAltitude: Float = 27.57
    let actualPosition = point(0, 0, altitude: overshootAltitude)
    let expectedFinal = point(54, 0, altitude: routeAltitude)
    let plannerPolyline = [
        point(0, 0, altitude: overshootAltitude),
        point(54, 0, altitude: overshootAltitude)
    ]

    // This is the generic planner's intentional `max(start.y, goal.y)` output. Feeding it
    // directly to the strict cursor reproduces the AUTO-after-climb regression.
    var rawCursor = HybridVTOLRouteCursor()
    checkBlocked(
        update(
            &rawCursor,
            route: route("planner-overshoot-raw", plannerPolyline),
            finalTarget: expectedFinal,
            position: actualPosition
        ),
        reason: "route_final_mismatch",
        "planner overshoot before bridge normalization"
    )

    let normalizedPolyline = plannerPolyline.map {
        HybridVTOLRouteBridge.normalizedPlannerPosition(
            $0,
            targetAltitude: routeAltitude
        )
    }
    check(
        normalizedPolyline.allSatisfy { $0.y == routeAltitude },
        "planner bridge: every route point must use the authoritative target altitude"
    )
    check(
        zip(plannerPolyline, normalizedPolyline).allSatisfy {
            $0.0.x == $0.1.x && $0.0.z == $0.1.z
        },
        "planner bridge: altitude normalization must preserve the protected X/Z path"
    )

    var normalizedCursor = HybridVTOLRouteCursor()
    checkReady(
        update(
            &normalizedCursor,
            route: route("planner-overshoot-normalized", normalizedPolyline),
            finalTarget: expectedFinal,
            position: actualPosition
        ),
        index: 1,
        target: expectedFinal,
        "planner overshoot after bridge normalization"
    )

    // Normalizing altitude must not weaken route identity: a different planar endpoint remains
    // a hard failure even when its Y coordinate is correct.
    let mismatchedXZ = [
        normalizedPolyline[0],
        point(56, 0, altitude: routeAltitude)
    ]
    var mismatchCursor = HybridVTOLRouteCursor()
    checkBlocked(
        update(
            &mismatchCursor,
            route: route("planner-xz-mismatch", mismatchedXZ),
            finalTarget: expectedFinal,
            position: actualPosition
        ),
        reason: "route_final_mismatch",
        "planner bridge X/Z mismatch"
    )
}

private func testRouteIdentifierReset() {
    let routeAFinal = point(0, 20)
    let routeA = route("route-a", [point(0, 0), point(0, 10), routeAFinal])
    var cursor = HybridVTOLRouteCursor()

    _ = update(&cursor, route: routeA, finalTarget: routeAFinal, position: point(0, 0))
    let advanced = update(&cursor, route: routeA, finalTarget: routeAFinal, position: point(0, 15))
    checkReady(advanced, index: 2, target: routeAFinal, "route A advanced")

    let routeBStart = point(0, 15)
    let routeBDetour = point(100, 15)
    let routeBFinal = point(100, 50)
    let routeB = route("route-b", [routeBStart, routeBDetour, routeBFinal])
    let reset = update(
        &cursor,
        route: routeB,
        finalTarget: routeBFinal,
        position: routeBStart
    )

    check(cursor.routeIdentifier == "route-b", "route-id reset: new identifier was not adopted")
    checkReady(reset, index: 1, target: routeBDetour, "route-id reset")
    check(!reset.isFinalSegment, "route-id reset: old progress leaked into the new route")
}

private func testControllerIndexSynchronization() {
    let points = [point(0, 0), point(0, 20), point(0, 40), point(0, 60)]
    let protectedRoute = route("shared", points)
    let final = points[3]

    var matchingDebug = FixedWingAutopilotDebugState.idle
    matchingDebug.routeIdentifier = "shared"
    matchingDebug.activeSegmentIndex = 2

    var synchronizedCursor = HybridVTOLRouteCursor()
    let synchronized = update(
        &synchronizedCursor,
        route: protectedRoute,
        finalTarget: final,
        position: points[0],
        controllerDebug: matchingDebug
    )
    checkReady(synchronized, index: 2, target: points[2], "controller sync")

    matchingDebug.activeSegmentIndex = 1
    let monotonic = update(
        &synchronizedCursor,
        route: protectedRoute,
        finalTarget: final,
        position: points[0],
        controllerDebug: matchingDebug
    )
    checkReady(monotonic, index: 2, target: points[2], "controller sync monotonic")

    var staleDebug = FixedWingAutopilotDebugState.idle
    staleDebug.routeIdentifier = "old-route"
    staleDebug.activeSegmentIndex = 3
    var staleCursor = HybridVTOLRouteCursor()
    let ignored = update(
        &staleCursor,
        route: protectedRoute,
        finalTarget: final,
        position: points[0],
        controllerDebug: staleDebug
    )
    checkReady(ignored, index: 1, target: points[1], "stale controller sync")
}

private func testFixedWingAvoidanceLatchPolicy() {
    func next(
        _ isLatched: Bool,
        progress: Float,
        wingborne: Float
    ) -> Bool {
        HybridVTOLFlightPolicy.nextFixedWingAvoidanceLatchState(
            isLatched: isLatched,
            transitionProgress: progress,
            wingborneBlend: wingborne
        )
    }

    check(
        !next(false, progress: 0.0, wingborne: 0.98),
        "avoidance latch: tumble lift at progress zero must not engage fixed-wing ownership"
    )
    check(
        !next(false, progress: 0.149, wingborne: 1.0),
        "avoidance latch: wing loading before minimum transition progress must not engage"
    )
    check(
        next(false, progress: 0.15, wingborne: 0.55),
        "avoidance latch: minimum progress plus wing loading must engage"
    )
    check(
        !next(false, progress: 0.299, wingborne: 0.54),
        "avoidance latch: uncommitted transition without wing loading must remain rotor-borne"
    )
    check(
        next(false, progress: 0.30, wingborne: 0.0),
        "avoidance latch: committed transition progress must engage before lift jumps"
    )
    check(
        next(true, progress: 0.08, wingborne: 0.0),
        "avoidance latch: release boundary must retain hysteresis"
    )
    check(
        !next(true, progress: 0.079, wingborne: 1.0),
        "avoidance latch: hover hand-back must release regardless of wing loading"
    )
    check(
        !next(true, progress: .nan, wingborne: 1.0),
        "avoidance latch: non-finite progress must fail closed to rotor-borne ownership"
    )
}

private func testTailsitterValidatedLegTransitionPolicy() {
    func requiresTransition(
        tailsitter: Bool = true,
        validated: Bool = true,
        final: Bool,
        distance: Float,
        radius: Float = 16.0
    ) -> Bool {
        HybridVTOLFlightPolicy.tailsitterValidatedLegRequiresWingTransition(
            isTailsitter: tailsitter,
            routeIsValidated: validated,
            isFinalSegment: final,
            finalPlanarDistance: distance,
            precisionRadius: radius
        )
    }

    check(
        requiresTransition(final: false, distance: 4.0),
        "tailsitter transition: every validated intermediate leg requires wing translation"
    )
    check(
        requiresTransition(final: true, distance: 16.01),
        "tailsitter transition: final leg outside precision sphere requires wing translation"
    )
    check(
        !requiresTransition(final: true, distance: 16.0),
        "tailsitter transition: precision-sphere boundary belongs to final capture"
    )
    check(
        !requiresTransition(final: true, distance: 5.0),
        "tailsitter transition: final capture inside precision sphere may remain rotor-borne"
    )
    check(
        !requiresTransition(validated: false, final: false, distance: 50.0),
        "tailsitter transition: an unvalidated route must hold instead of transitioning"
    )
    check(
        !requiresTransition(tailsitter: false, final: false, distance: 50.0),
        "tailsitter transition: tilt-rotor cruise economy remains a separate policy"
    )
    check(
        !requiresTransition(final: false, distance: .nan),
        "tailsitter transition: non-finite leg geometry must fail closed"
    )
    check(
        !requiresTransition(final: false, distance: 50.0, radius: 0.0),
        "tailsitter transition: invalid precision radius must fail closed"
    )
}

testIntermediateDetourIsNotCut()
testHighDeltaTimeSweptAdvanceAndFinalOwnership()
testStopAndPivotRequiresExactSlowCaptureAndAlignment()
testInvalidRoutesFailClosed()
testPlannerAltitudeNormalization()
testRouteIdentifierReset()
testControllerIndexSynchronization()
testFixedWingAvoidanceLatchPolicy()
testTailsitterValidatedLegTransitionPolicy()
testGenericPlannerClearanceOwnership()

if failures.isEmpty {
    print("RESULT: PASS - hybrid VTOL protected-route cursor contract holds")
} else {
    print("RESULT: FAIL - \(failures.count) assertion(s) failed")
    exit(EXIT_FAILURE)
}
