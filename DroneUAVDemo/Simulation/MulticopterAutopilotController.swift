import Foundation
import simd

struct AutopilotTrackingContext {
    let state: DroneState
    let physicalState: DronePhysicalState
    let target: SIMD3<Float>
    let targetAltitude: Float
    let speedScale: Float
    let yawAlignToHome: Bool
    let yawOverrideRadians: Float?
    let deltaTime: Float
    let flightBaseline: ResolvedFlightBaseline
    /// Height above the surface beneath the aircraft. Only the fixed-wing path reads it, for
    /// low-altitude bank protection; the default keeps every other caller unchanged.
    var heightAboveSurfaceMeters: Float = .greatestFiniteMagnitude
    /// Derivative gain for the vertical hold loop. Hybrid VTOLs need more
    /// damping while rotor-borne because their transition-sized propulsion
    /// has substantially more thrust authority than an ordinary multirotor.
    var verticalVelocityDampingGain: Float = 0.03
}

struct AutopilotControlCommand: Equatable {
    var positionTarget: SIMD3<Float>
    var rollDegrees: Float
    var pitchDegrees: Float
    var yawDegrees: Float
    var throttle: Float
}

/// Safety/feel parameters for the multirotor route-following yaw.
/// These keep the autopilot's yaw command behaving like manual J/L
/// (rate-limited, deadbanded, clamped) instead of snapping the SceneKit
/// orientation directly to the bearing.
private enum MulticopterRouteTuning {
    static let yawGain: Float = 1.6              // proportional gain on heading error
    static let yawDeadbandRadians: Float = 0.07  // ~4 degrees: ignore tiny errors
    static let maxYawRateDegPerSec: Float = 75.0 // matches a comfortable J/L feel
    static let forwardSlowdownAngleRadians: Float = 0.78 // ~45 degrees: pitch limited
    static let holdRadiusMeters: Float = 0.6     // do not chase noise inside this radius
    static let lateralPositionGain: Float = 1.15
    static let lateralVelocityDamping: Float = 2.1
    static let brakingSpeedThreshold: Float = 0.12
}

final class MulticopterAutopilotController {
    private var lastCommandedYawDegrees: Float?

    func reset() {
        lastCommandedYawDegrees = nil
    }

    func command(for context: AutopilotTrackingContext) -> AutopilotControlCommand {
        // Sanitize state and target to guarantee no NaN ever reaches physics.
        // Without these guards an upstream bug (invalid marker, unbound mission
        // target, malformed waypoint) would propagate through the autopilot and
        // poison roll/pitch/yaw/throttle.
        let safeState = sanitizedState(context.state)
        let safeTarget = sanitizedTarget(
            context.target,
            fallback: safeState.position,
            altitude: context.targetAltitude
        )

        let headingVector = SIMD2<Float>(
            safeTarget.x - safeState.position.x,
            safeTarget.z - safeState.position.z
        )
        let headingDistance = simd_length(headingVector)
        let planarVelocity = SIMD2<Float>(safeState.velocity.x, safeState.velocity.z)
        let planarSpeed = simd_length(planarVelocity)

        // Hold position for invalid / extremely-close targets instead of
        // letting the controller spin a noisy bearing into a roll/pitch
        // command (this is what allowed the multicopter to "fly off" when
        // a stray marker landed under itself).
        let targetHasBearing = headingDistance.isFinite &&
            headingDistance >= MulticopterRouteTuning.holdRadiusMeters
        let targetIsUsable = targetHasBearing ||
            (headingDistance.isFinite && planarSpeed > MulticopterRouteTuning.brakingSpeedThreshold)

        let yawDegrees = resolvedYawDegrees(
            context: context,
            safeState: safeState,
            headingVector: headingVector,
            headingDistance: headingDistance,
            targetIsUsable: targetHasBearing
        )

        let controlScale = context.speedScale.isFinite ? context.speedScale : 1.0
        let altitudeError = clampFinite(
            context.targetAltitude - safeState.position.y,
            fallback: 0.0
        )
        let verticalComp =
            (altitudeError * 0.06 - safeState.velocity.y * clampFloat(context.verticalVelocityDampingGain, to: 0.02...0.10)) *
            context.flightBaseline.effectiveVerticalResponseFactor
        let commandedThrottle = clampFloat(
            context.flightBaseline.hoverLockThrottle + verticalComp,
            to: 0.18...0.90
        )

        // Lateral commands. When the target is invalid the lateral intent is
        // zeroed so the multicopter holds position instead of drifting.
        let lateralRoll: Float
        let lateralPitch: Float
        if targetIsUsable {
            // Soft slowdown when the nose is far from the heading: the more
            // the drone needs to turn, the less translational thrust we ask
            // for. This avoids the "drift sideways while turning" feel.
            let alignmentScale: Float
            if targetHasBearing {
                let yawErrorRadians = computeYawError(
                    fromYaw: safeState.orientation.z,
                    desiredYawRadians: yawRadiansForDirection(headingVector)
                )
                alignmentScale = forwardScaleFromYawError(yawErrorRadians)
            } else {
                alignmentScale = 1.0
            }

            // `speedScale` throttles how fast we are willing to *go*. It must not throttle the
            // brake: scaling the velocity-damping term by it means the more firmly guidance asks
            // the aircraft to hold still, the less authority it has to stop.
            //
            // Measured on the hybrid-VTOL stop-and-pivot hold, which runs at `speedScale` 0.28.
            // Entering the node at 4 m/s produced a 2.7 deg command — 0.46 m/s^2 — and the
            // aircraft was still above 0.55 m/s after 15 s, having coasted 14.2 m past its own
            // latched hold; at 8 m/s it coasted 26.7 m. A city street is narrower than that.
            // `HybridVTOLStopAndPivotGate` releases the node only below 0.55 m/s, so the pivot
            // never completed: the aircraft kept translating and yawing in
            // `vtol_stop_and_pivot_align` until it hit a facade, never having reached the wing
            // transition that mode hands off to.
            //
            // Position error keeps the scale, so a cautious approach still approaches cautiously.
            let worldIntent = headingVector * alignmentScale * controlScale -
                planarVelocity * MulticopterRouteTuning.lateralVelocityDamping
            let bodyAxes = planarBodyAxes(safeState)
            let localForwardIntent = simd_dot(worldIntent, bodyAxes.forward)
            let localRightIntent = simd_dot(worldIntent, bodyAxes.right)
            let lateralGain = MulticopterRouteTuning.lateralPositionGain
            lateralRoll = clampFloat(-localRightIntent * lateralGain, to: -16.0...16.0)
            lateralPitch = clampFloat(-localForwardIntent * lateralGain, to: -16.0...16.0)
        } else {
            lateralRoll = 0.0
            lateralPitch = 0.0
        }

        let positionTarget: SIMD3<Float>
        if targetIsUsable {
            positionTarget = SIMD3<Float>(
                safeTarget.x,
                context.targetAltitude,
                safeTarget.z
            )
        } else {
            // Hold current planar position; only altitude command can move.
            positionTarget = SIMD3<Float>(
                safeState.position.x,
                context.targetAltitude,
                safeState.position.z
            )
        }

        return AutopilotControlCommand(
            positionTarget: positionTarget,
            rollDegrees: lateralRoll,
            pitchDegrees: lateralPitch,
            yawDegrees: yawDegrees,
            throttle: clampFloat(commandedThrottle, to: 0.0...1.0)
        )
    }

    // MARK: - Sanitisation

    private func sanitizedState(_ state: DroneState) -> DroneState {
        var safe = state
        safe.position = SIMD3<Float>(
            clampFinite(state.position.x),
            clampFinite(state.position.y),
            clampFinite(state.position.z)
        )
        safe.velocity = SIMD3<Float>(
            clampFinite(state.velocity.x),
            clampFinite(state.velocity.y),
            clampFinite(state.velocity.z)
        )
        safe.orientation = SIMD3<Float>(
            clampFinite(state.orientation.x),
            clampFinite(state.orientation.y),
            clampFinite(state.orientation.z)
        )
        return safe
    }

    private func sanitizedTarget(
        _ target: SIMD3<Float>,
        fallback: SIMD3<Float>,
        altitude: Float
    ) -> SIMD3<Float> {
        let safeAltitude = altitude.isFinite ? altitude : fallback.y
        return SIMD3<Float>(
            target.x.isFinite ? target.x : fallback.x,
            safeAltitude,
            target.z.isFinite ? target.z : fallback.z
        )
    }

    // MARK: - Yaw resolution

    private func resolvedYawDegrees(
        context: AutopilotTrackingContext,
        safeState: DroneState,
        headingVector: SIMD2<Float>,
        headingDistance: Float,
        targetIsUsable: Bool
    ) -> Float {
        // Honour explicit yaw overrides (return-home, scripted hold, etc.)
        if let yawOverride = context.yawOverrideRadians, yawOverride.isFinite {
            let degrees = radiansToDegrees(yawOverride)
            lastCommandedYawDegrees = degrees
            return degrees
        }

        let currentYawRadians = safeState.orientation.z
        let currentYawDegrees = radiansToDegrees(currentYawRadians)

        // No usable target => keep the last yaw we committed to. This is the
        // critical "do not flip the nose at noise" guarantee.
        guard targetIsUsable else {
            let held = lastCommandedYawDegrees ?? currentYawDegrees
            lastCommandedYawDegrees = held
            return held
        }

        // Match return-home convention: when asked to align home and we are
        // already close to the target we hand the nose to neutral.
        if context.yawAlignToHome && headingDistance < 1.2 {
            lastCommandedYawDegrees = 0.0
            return 0.0
        }

        let desiredYawRadians = yawRadiansForDirection(headingVector)
        let yawErrorRadians = computeYawError(
            fromYaw: currentYawRadians,
            desiredYawRadians: desiredYawRadians
        )

        // Deadband: ignore tiny errors. This stops the autopilot from issuing
        // a constant micro-correction that visibly twitches the nose.
        if abs(yawErrorRadians) < MulticopterRouteTuning.yawDeadbandRadians {
            let held = lastCommandedYawDegrees ?? currentYawDegrees
            lastCommandedYawDegrees = held
            return held
        }

        // Rate limit the yaw command similarly to how manual J/L feels.
        let proposedYawRadians = currentYawRadians +
            yawErrorRadians * MulticopterRouteTuning.yawGain * max(0.0, context.deltaTime)
        let proposedYawDegrees = radiansToDegrees(proposedYawRadians)

        let dt = max(0.0, context.deltaTime)
        let maxStepDeg = MulticopterRouteTuning.maxYawRateDegPerSec * dt
        let baseYawDegrees = lastCommandedYawDegrees ?? currentYawDegrees
        let stepped = stepYawDegrees(
            from: baseYawDegrees,
            toward: proposedYawDegrees,
            maxStepDeg: maxStepDeg
        )
        lastCommandedYawDegrees = stepped
        return stepped
    }

    private func yawRadiansForDirection(_ direction: SIMD2<Float>) -> Float {
        // Match the physics convention: yaw 0 points body-forward along -Z.
        let yaw = atan2(-direction.x, -direction.y)
        return yaw.isFinite ? yaw : 0.0
    }

    /// Planar body frame the lateral command is projected into.
    ///
    /// Euler yaw is extracted with `atan2` on the forward vector's X/Z components, which is
    /// singular at pitch = ±90 deg — exactly the attitude a tailsitter holds for all of hover, and
    /// visibly so: a flight log of a hovering Wingtra shows the extracted roll/yaw walking
    /// monotonically (+40 -> +125 deg) with the airframe barely moving. Projecting into a frame
    /// built from that number sends the braking vector somewhere other than along travel; measured
    /// on a 4 m/s stop-and-pivot entry, the aircraft shed no speed at all, drifted 15 m
    /// cross-track and accelerated to 13 m/s.
    ///
    /// Body -Y stays horizontal at the nose-up attitude and is the gauge both the engine's
    /// tailsitter step and the view model already use for heading. Blend towards it as the nose
    /// approaches vertical so an ordinary multirotor (pitch ~ 0) is bit-for-bit unchanged and no
    /// airframe sees the frame jump at a threshold.
    private func planarBodyAxes(
        _ state: DroneState
    ) -> (forward: SIMD2<Float>, right: SIMD2<Float>) {
        let eulerAxes = bodyPlanarAxes(forYaw: state.orientation.z)
        let gimbalMargin = abs(cos(state.orientation.y))
        guard gimbalMargin.isFinite, gimbalMargin < 0.5 else {
            return eulerAxes
        }
        let direction = -simd_act(state.fixedWingOrientationQuat, SIMD3<Float>(0, 1, 0))
        let planar = SIMD2<Float>(direction.x, direction.z)
        guard planar.x.isFinite, planar.y.isFinite,
              simd_length_squared(planar) > 1e-8 else {
            return eulerAxes
        }
        let hoverAxes = bodyPlanarAxes(forYaw: atan2(-planar.x, -planar.y))
        let blend = clampFloat((0.5 - gimbalMargin) / 0.5, to: 0.0...1.0)
        let forward = eulerAxes.forward * (1.0 - blend) + hoverAxes.forward * blend
        let right = eulerAxes.right * (1.0 - blend) + hoverAxes.right * blend
        guard simd_length_squared(forward) > 1e-6, simd_length_squared(right) > 1e-6 else {
            return eulerAxes
        }
        return (forward: simd_normalize(forward), right: simd_normalize(right))
    }

    private func bodyPlanarAxes(forYaw yaw: Float) -> (forward: SIMD2<Float>, right: SIMD2<Float>) {
        let safeYaw = yaw.isFinite ? yaw : 0.0
        return (
            forward: SIMD2<Float>(-sin(safeYaw), -cos(safeYaw)),
            right: SIMD2<Float>(cos(safeYaw), -sin(safeYaw))
        )
    }

    private func computeYawError(
        fromYaw currentYaw: Float,
        desiredYawRadians: Float
    ) -> Float {
        guard currentYaw.isFinite, desiredYawRadians.isFinite else {
            return 0.0
        }
        return normalizeAngleRadians(desiredYawRadians - currentYaw)
    }

    private func forwardScaleFromYawError(_ yawError: Float) -> Float {
        let magnitude = abs(yawError)
        if magnitude <= MulticopterRouteTuning.forwardSlowdownAngleRadians {
            return 1.0
        }
        // Scale linearly to 0.25 as the error approaches pi (180°).
        let span = max(0.001, .pi - MulticopterRouteTuning.forwardSlowdownAngleRadians)
        let overflow = (magnitude - MulticopterRouteTuning.forwardSlowdownAngleRadians) / span
        return clampFloat(1.0 - overflow * 0.75, to: 0.25...1.0)
    }

    private func stepYawDegrees(
        from current: Float,
        toward target: Float,
        maxStepDeg: Float
    ) -> Float {
        guard current.isFinite, target.isFinite else {
            return target.isFinite ? target : current
        }

        let delta = shortestDegreesDelta(current, target)
        let limited = clampFloat(delta, to: -maxStepDeg...maxStepDeg)
        let stepped = current + limited
        // Wrap into [-180, 180] for downstream clamps.
        return wrapDegrees(stepped)
    }

    private func shortestDegreesDelta(_ from: Float, _ to: Float) -> Float {
        var delta = to - from
        while delta > 180.0 {
            delta -= 360.0
        }
        while delta < -180.0 {
            delta += 360.0
        }
        return delta
    }

    private func wrapDegrees(_ value: Float) -> Float {
        var wrapped = value.truncatingRemainder(dividingBy: 360.0)
        if wrapped > 180.0 {
            wrapped -= 360.0
        }
        if wrapped < -180.0 {
            wrapped += 360.0
        }
        return wrapped
    }
}

private func clampFloat(_ value: Float, to range: ClosedRange<Float>) -> Float {
    Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
}

private func radiansToDegrees(_ radians: Float) -> Float {
    radians * 180.0 / .pi
}
