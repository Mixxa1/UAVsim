import Foundation
import simd

/// The protected-route point a hybrid VTOL should currently fly toward.
///
/// `finalTarget` deliberately remains separate from `guidanceTarget`: planner-generated points
/// shape the trajectory around obstacles, but only the operator-authored final target is allowed
/// to drive mission-leg identity and waypoint capture.
struct HybridVTOLRouteGuidance: Equatable {
    enum Status: Equatable {
        case ready
        case blocked(String)
    }

    var status: Status
    var routeIdentifier: String?
    var finalTarget: SIMD3<Float>
    var guidanceTarget: SIMD3<Float>?
    var activeRouteIndex: Int?
    var remainingPathMeters: Float
    var isFinalSegment: Bool
    var traversalMode: ProtectedRouteTraversalMode

    var isReady: Bool {
        status == .ready && guidanceTarget != nil
    }
}

/// Converts the generic planner's 3-D polyline into the fixed-wing route altitude contract.
///
/// `AutoPathPlannerService` deliberately keeps a route at the higher of its start and goal
/// altitudes. That is useful for generic point-to-point flight, but a hybrid VTOL can enter AUTO
/// while still overshooting its vertical departure. Its fixed-wing altitude is authoritative and
/// controlled separately, so carrying the temporary overshoot into the route's final waypoint
/// makes the cursor reject an otherwise identical X/Z route as `route_final_mismatch`.
enum HybridVTOLRouteBridge {
    static func normalizedPlannerPosition(
        _ plannerPosition: SIMD3<Float>,
        targetAltitude: Float
    ) -> SIMD3<Float> {
        SIMD3<Float>(plannerPosition.x, targetAltitude, plannerPosition.z)
    }
}

/// Pure regime-selection contracts shared by hybrid-VTOL guidance and avoidance.
///
/// Keeping these decisions outside the ViewModel makes the safety thresholds independently
/// testable: a fast rotor-borne fall must not acquire fixed-wing controls, while a tailsitter must
/// not be asked to translate horizontally without beginning its whole-airframe transition.
enum HybridVTOLFlightPolicy {
    static let fixedWingAvoidanceMinimumEntryProgress: Float = 0.15
    static let fixedWingAvoidanceWingborneEntry: Float = 0.55
    static let fixedWingAvoidanceCommittedProgress: Float = 0.30
    static let fixedWingAvoidanceReleaseProgress: Float = 0.08

    /// Generic marker/AUTO/RTH A* may reserve a whole continuous turn only for a conventional
    /// fixed wing. A hybrid VTOL can fall back to physically clear stop-and-pivot hover legs, so
    /// applying the same reserve there erases the route before that fallback can evaluate it.
    static func genericPlannerUsesWholeTurnHardClearance(
        airframeClass: AirframeClass
    ) -> Bool {
        airframeClass == .fixedWing
    }

    /// Every hybrid VTOL may execute a physically clear route as rotor-borne stop-and-pivot legs.
    /// This includes tailsitters: their hover-translation quaternion controller is now validated
    /// independently, while a conventional fixed wing still has no safe way to stop at a corner.
    static func supportsStopAndPivotVTOL(airframeClass: AirframeClass) -> Bool {
        airframeClass == .hybridVTOL
    }

    /// Selects the physical yaw-rate channel used by the in-place pivot settle gate. A tailsitter
    /// yaws around body X while standing nose-up; ordinary tilt-rotors use the Euler yaw/Z channel.
    static func stopAndPivotYawRate(
        isTailsitter: Bool,
        tailsitterBodyXRate: Float,
        conventionalYawRate: Float
    ) -> Float {
        isTailsitter ? tailsitterBodyXRate : conventionalYawRate
    }

    /// Whether local hover sidestepping may alter a nominal target. Stop-and-pivot targets are
    /// exact route vertices/latched holds; replacing one with the helper's final-goal fallback
    /// cuts across the protected corner.
    static func allowsReactiveHoverSidestep(decisionReason: String) -> Bool {
        decisionReason != "vtol_protected_route_blocked"
            && !decisionReason.hasPrefix("vtol_stop_and_pivot")
    }

    /// Returns the fixed-wing avoidance latch state for the next guidance tick.
    ///
    /// Transition progress is the required physical proof that the hybrid has left rotor-borne
    /// hover. Wing loading alone is insufficient because a tumbling wing can momentarily generate
    /// a high lift ratio at progress zero. Once latched, progress below the hover hand-back
    /// threshold releases immediately regardless of residual wing loading.
    static func nextFixedWingAvoidanceLatchState(
        isLatched: Bool,
        transitionProgress: Float,
        wingborneBlend: Float
    ) -> Bool {
        guard transitionProgress.isFinite else { return false }

        if isLatched {
            return transitionProgress >= fixedWingAvoidanceReleaseProgress
        }

        let hasWingborneProof = wingborneBlend.isFinite &&
            wingborneBlend >= fixedWingAvoidanceWingborneEntry
        return transitionProgress >= fixedWingAvoidanceMinimumEntryProgress &&
            (hasWingborneProof || transitionProgress >= fixedWingAvoidanceCommittedProgress)
    }

    /// Whether a validated tailsitter leg must enter wing transition to make horizontal progress.
    ///
    /// A tailsitter has no independently tilting lift rotors. It may remain rotor-borne only while
    /// capturing the final waypoint inside its precision sphere; every intermediate protected leg
    /// and every final approach outside that sphere requires whole-airframe transition.
    static func tailsitterValidatedLegRequiresWingTransition(
        isTailsitter: Bool,
        routeIsValidated: Bool,
        isFinalSegment: Bool,
        finalPlanarDistance: Float,
        precisionRadius: Float
    ) -> Bool {
        guard isTailsitter,
              routeIsValidated,
              finalPlanarDistance.isFinite,
              precisionRadius.isFinite,
              precisionRadius > 0.0 else {
            return false
        }
        return !isFinalSegment || finalPlanarDistance > precisionRadius
    }
}

/// Holds a rotor-borne VTOL still while it yaws onto the next straight protected leg.
///
/// The route cursor already requires the previous node to be captured at low speed before it
/// advances. This second, independent gate prevents translation toward the new node until the
/// vehicle has stopped and aligned its heading, which makes every raw A* corner a real
/// stop-and-pivot instead of a rounded shortcut through the inside obstacle.
struct HybridVTOLStopAndPivotGate: Equatable {
    static let maximumPlanarSpeedMps: Float = 0.55
    static let maximumHeadingErrorRadians: Float = 6.0 * .pi / 180.0
    static let maximumYawRateRadiansPerSecond: Float = 0.18
    /// How far a still-moving aircraft may coast past its latched hold before the hold follows it.
    /// Wider than the position loop's settled error (0.44 m measured) so an aircraft that has
    /// actually stopped keeps a fixed anchor, narrower than any braking distance so a coasting one
    /// is never told to fly back.
    static let maximumHoldDriftMeters: Float = 1.5

    struct Guidance: Equatable {
        var shouldHold: Bool
        var holdPosition: SIMD3<Float>?

        static let translate = Guidance(shouldHold: false, holdPosition: nil)
    }

    private(set) var routeIdentifier: String?
    private(set) var routeIndex: Int?
    private(set) var pivotPending = false
    private var holdPosition: SIMD3<Float>?

    mutating func reset() {
        routeIdentifier = nil
        routeIndex = nil
        pivotPending = false
        holdPosition = nil
    }

    mutating func update(
        traversalMode: ProtectedRouteTraversalMode,
        routeIdentifier: String?,
        routeIndex: Int?,
        position: SIMD3<Float>,
        planarSpeed: Float,
        headingErrorRadians: Float,
        yawRateRadiansPerSecond: Float
    ) -> Guidance {
        guard traversalMode == .stopAndPivotVTOL,
              let routeIdentifier,
              !routeIdentifier.isEmpty,
              let routeIndex else {
            reset()
            return .translate
        }

        if self.routeIdentifier != routeIdentifier || self.routeIndex != routeIndex {
            self.routeIdentifier = routeIdentifier
            self.routeIndex = routeIndex
            pivotPending = true
            holdPosition = position
        }

        guard pivotPending else {
            return .translate
        }

        // "Stop" means come to rest, not fly back to where the stop was ordered.
        //
        // The hold is latched the instant the cursor reaches a node, while the aircraft still
        // carries its leg speed. Rotor-borne braking is bounded by the tilt envelope — measured at
        // a 16 deg command, 12 deg achieved — so it coasts well past the latch: 11.3 m from 8 m/s,
        // 18.5 m from 14 m/s. Holding the original point then commands a return flight over that
        // distance, during which the aircraft is moving again and never satisfies the release
        // speed, so the pivot never completes. In the air it reads as the aircraft sailing past its
        // waypoint and coming back for it, across geometry the protected route never approved.
        //
        // While the aircraft is still travelling, let the hold follow it, so the command is "shed
        // speed" rather than "shed speed and then return". Once it is at or below the release
        // speed the hold stops moving and becomes a real anchor for the pivot.
        if let latched = holdPosition,
           planarSpeed.isFinite,
           planarSpeed > Self.maximumPlanarSpeedMps {
            let drift = simd_distance(
                SIMD2<Float>(position.x, position.z),
                SIMD2<Float>(latched.x, latched.z)
            )
            if drift > Self.maximumHoldDriftMeters {
                holdPosition = position
            }
        }

        let isSettled = planarSpeed.isFinite
            && headingErrorRadians.isFinite
            && yawRateRadiansPerSecond.isFinite
            && planarSpeed >= 0.0
            && planarSpeed <= Self.maximumPlanarSpeedMps
            && abs(headingErrorRadians) <= Self.maximumHeadingErrorRadians
            && abs(yawRateRadiansPerSecond) <= Self.maximumYawRateRadiansPerSecond
        if isSettled {
            pivotPending = false
            holdPosition = nil
            return .translate
        }
        return Guidance(shouldHold: true, holdPosition: holdPosition ?? position)
    }
}

/// Monotonic progress through planner-generated hybrid-VTOL route points.
///
/// The fixed-wing controller owns its own route cursor while wing-borne. Rotor-borne and
/// transition guidance need an equivalent cursor; otherwise they aim directly at the raw mission
/// waypoint and cut across a protected reroute. This type contains no scene or ViewModel state so
/// its route-change, swept-advance, and fail-closed behavior can be tested headlessly.
struct HybridVTOLRouteCursor: Equatable {
    static let finalTargetToleranceMeters: Float = 0.5
    /// Raw A* has only the physical-envelope margin, so a hover leg may not begin 1.5 m inside a
    /// corner and consume that entire margin. Require a near-exact stop before changing legs.
    static let stopAndPivotCaptureRadiusMeters: Float = 0.70

    private(set) var routeIdentifier: String?
    private(set) var routeIndex: Int = 1
    private var traversalMode: ProtectedRouteTraversalMode = .continuousWingborne
    private var previousPlanarPosition: SIMD2<Float>?

    mutating func reset() {
        routeIdentifier = nil
        routeIndex = 1
        traversalMode = .continuousWingborne
        previousPlanarPosition = nil
    }

    /// Advances over intermediate route points and returns the next protected guidance target.
    ///
    /// The final point is never consumed here. Mission progress must continue to require the
    /// aircraft's real swept intersection with the operator waypoint's capture volume.
    mutating func update(
        route: FixedWingRouteTrackingContext?,
        expectedFinalTarget: SIMD3<Float>,
        position: SIMD3<Float>,
        controllerDebug: FixedWingAutopilotDebugState?,
        intermediateRadius: Float,
        corridorRadius: Float,
        planarSpeed: Float = 0.0
    ) -> HybridVTOLRouteGuidance {
        guard Self.isFinite(expectedFinalTarget) else {
            return blocked(
                reason: "non_finite_expected_final",
                routeIdentifier: route?.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard Self.isFinite(position) else {
            return blocked(
                reason: "non_finite_position",
                routeIdentifier: route?.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard intermediateRadius.isFinite, intermediateRadius > 0.0 else {
            return blocked(
                reason: "invalid_intermediate_radius",
                routeIdentifier: route?.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard corridorRadius.isFinite, corridorRadius > 0.0 else {
            return blocked(
                reason: "invalid_corridor_radius",
                routeIdentifier: route?.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard let route else {
            return blocked(
                reason: "missing_route",
                routeIdentifier: nil,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard !route.routeIdentifier.isEmpty else {
            return blocked(
                reason: "missing_route_identifier",
                routeIdentifier: nil,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        // Emptiness is checked before certification, and the order is load-bearing.
        //
        // Every "no route" sentinel the route builder returns is an empty context carrying the
        // default `turnsValidated == false`. With the certification guard first, the single most
        // common real failure — the planner produced nothing at all — was reported as
        // `route_not_validated`, which reads as "a route exists but was not certified" and sent
        // the diagnosis looking at the turn validator instead of at route construction.
        guard route.waypoints.count >= 2 else {
            return blocked(
                reason: route.blockReason.map { "route_unavailable:\($0)" }
                    ?? "route_has_no_guidance_leg",
                routeIdentifier: route.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard route.turnsValidated || route.traversalMode == .stopAndPivotVTOL else {
            return blocked(
                reason: "route_not_validated",
                routeIdentifier: route.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard route.waypoints.allSatisfy({ Self.isFinite($0.position) }) else {
            return blocked(
                reason: "non_finite_route_waypoint",
                routeIdentifier: route.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }
        guard let routeFinal = route.waypoints.last?.position,
              simd_distance(routeFinal, expectedFinalTarget) <= Self.finalTargetToleranceMeters else {
            return blocked(
                reason: "route_final_mismatch",
                routeIdentifier: route.routeIdentifier,
                finalTarget: expectedFinalTarget,
                position: position
            )
        }

        let currentPlanar = SIMD2<Float>(position.x, position.z)
        let finalIndex = route.waypoints.count - 1
        let minimumIndex = min(
            finalIndex,
            max(1, route.minimumWaypointIndex ?? 1)
        )

        if routeIdentifier != route.routeIdentifier || traversalMode != route.traversalMode {
            routeIdentifier = route.routeIdentifier
            routeIndex = minimumIndex
            traversalMode = route.traversalMode
            previousPlanarPosition = currentPlanar
        } else {
            routeIndex = min(finalIndex, max(minimumIndex, routeIndex))
        }

        // When the aircraft has already flown part of this exact route under the fixed-wing
        // controller, carry that monotonic progress back into hover guidance. A debug sample from a
        // previous route must never move this cursor.
        if route.traversalMode == .continuousWingborne,
           controllerDebug?.routeIdentifier == route.routeIdentifier,
           let controllerIndex = controllerDebug?.activeSegmentIndex {
            routeIndex = min(finalIndex, max(routeIndex, controllerIndex))
        }

        let previousPlanar = previousPlanarPosition ?? currentPlanar
        let captureRadius = max(0.4, intermediateRadius)
        let passCorridorRadius = max(captureRadius, corridorRadius)

        // Only planner intermediates are advanced here. The final required waypoint remains active
        // even when this cursor is inside it; MissionProgressTracker owns its physical capture.
        while routeIndex < finalIndex {
            let activePlanar = Self.planar(route.waypoints[routeIndex].position)
            if route.traversalMode == .stopAndPivotVTOL {
                // A raw A* corner is safe only if it is reached and stopped at. Swept-circle,
                // projection and abeam advancement are intentionally forbidden in this mode:
                // at ordinary hover speed they advance several metres early and turn the next
                // target into a diagonal shortcut through the obstacle the node goes around.
                let stopCaptureRadius = min(
                    Self.stopAndPivotCaptureRadiusMeters,
                    max(0.35, captureRadius)
                )
                guard planarSpeed.isFinite,
                      planarSpeed >= 0.0,
                      planarSpeed <= HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps,
                      simd_distance(currentPlanar, activePlanar) <= stopCaptureRadius else {
                    break
                }
                routeIndex += 1
                continue
            }
            let inboundStart = Self.planar(route.waypoints[routeIndex - 1].position)
            let inbound = activePlanar - inboundStart
            let inboundLength = simd_length(inbound)
            let insideCapture = simd_distance(currentPlanar, activePlanar) <= captureRadius
            let crossedCapture = Self.motionSegmentIntersectsCircle(
                from: previousPlanar,
                to: currentPlanar,
                center: activePlanar,
                radius: captureRadius
            )

            let passedAbeamWithinCorridor: Bool = {
                // Duplicate planner points add no trajectory information and are safe to consume.
                guard inboundLength > 0.05 else { return true }
                let direction = inbound / inboundLength
                let previousAlong = simd_dot(previousPlanar - activePlanar, direction)
                let currentAlong = simd_dot(currentPlanar - activePlanar, direction)
                let crossedAbeam = previousAlong < 0.0 && currentAlong >= 0.0
                let fromInboundStart = currentPlanar - inboundStart
                let crossTrack = abs(
                    fromInboundStart.x * direction.y - fromInboundStart.y * direction.x
                )
                return crossedAbeam && crossTrack <= passCorridorRadius
            }()

            guard insideCapture || crossedCapture || passedAbeamWithinCorridor else {
                break
            }
            routeIndex += 1
        }

        previousPlanarPosition = currentPlanar

        let isFinalSegment = routeIndex == finalIndex
        let routeGuidanceTarget = route.waypoints[routeIndex].position
        // Preserve the exact operator-authored endpoint even if the validated route differs by a
        // harmless sub-tolerance float round-trip.
        let guidanceTarget = isFinalSegment ? expectedFinalTarget : routeGuidanceTarget
        let remainingPath = Self.remainingPlanarPath(
            from: currentPlanar,
            route: route,
            activeIndex: routeIndex,
            expectedFinalTarget: expectedFinalTarget
        )

        return HybridVTOLRouteGuidance(
            status: .ready,
            routeIdentifier: route.routeIdentifier,
            finalTarget: expectedFinalTarget,
            guidanceTarget: guidanceTarget,
            activeRouteIndex: routeIndex,
            remainingPathMeters: remainingPath,
            isFinalSegment: isFinalSegment,
            traversalMode: route.traversalMode
        )
    }

    private mutating func blocked(
        reason: String,
        routeIdentifier blockedRouteIdentifier: String?,
        finalTarget: SIMD3<Float>,
        position: SIMD3<Float>
    ) -> HybridVTOLRouteGuidance {
        // A later valid route must start from its measured pose rather than sweep from a stale
        // pre-block sample.
        routeIdentifier = nil
        routeIndex = 1
        traversalMode = .continuousWingborne
        previousPlanarPosition = Self.isFinite(position)
            ? SIMD2<Float>(position.x, position.z)
            : nil
        return HybridVTOLRouteGuidance(
            status: .blocked(reason),
            routeIdentifier: blockedRouteIdentifier,
            finalTarget: finalTarget,
            guidanceTarget: nil,
            activeRouteIndex: nil,
            remainingPathMeters: .infinity,
            isFinalSegment: false,
            traversalMode: .continuousWingborne
        )
    }

    private static func remainingPlanarPath(
        from position: SIMD2<Float>,
        route: FixedWingRouteTrackingContext,
        activeIndex: Int,
        expectedFinalTarget: SIMD3<Float>
    ) -> Float {
        let finalIndex = route.waypoints.count - 1
        func point(at index: Int) -> SIMD2<Float> {
            if index == finalIndex {
                return planar(expectedFinalTarget)
            }
            return planar(route.waypoints[index].position)
        }

        var remaining = simd_distance(position, point(at: activeIndex))
        guard activeIndex < finalIndex else { return remaining }
        for index in activeIndex..<finalIndex {
            remaining += simd_distance(point(at: index), point(at: index + 1))
        }
        return remaining
    }

    private static func motionSegmentIntersectsCircle(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.000001 else {
            return simd_distance(end, center) <= radius
        }
        let projection = simd_dot(center - start, delta) / lengthSquared
        let clampedProjection = min(Float(1.0), max(Float(0.0), projection))
        let closest = start + delta * clampedProjection
        return simd_distance(closest, center) <= radius
    }

    private static func planar(_ point: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2<Float>(point.x, point.z)
    }

    private static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}
