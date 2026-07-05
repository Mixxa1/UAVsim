import Foundation
import simd

enum AutoNavigationPhase: String, Equatable {
    case inactive
    case takeoff
    case cruise
    case approach
    case hold
}

enum AutoNavigationCompletionReason: Equatable {
    case none
    case reachedTarget
    case cancelled
}

struct AutoNavigationAxisIntent: Equatable {
    let forward: Float
    let strafe: Float
    let vertical: Float

    static let zero = AutoNavigationAxisIntent(forward: 0.0, strafe: 0.0, vertical: 0.0)
}

struct AutoNavigationStatus: Equatable {
    let isActive: Bool
    let phase: AutoNavigationPhase
    let distanceToTarget: Float
    let bearingDegrees: Float
    let hasTarget: Bool

    static let inactive = AutoNavigationStatus(
        isActive: false,
        phase: .inactive,
        distanceToTarget: .nan,
        bearingDegrees: .nan,
        hasTarget: false
    )
}

struct AutoNavigationUpdateInput {
    let position: SIMD3<Float>
    let velocity: SIMD3<Float>
    let currentYawRadians: Float
    let physicalState: DronePhysicalState
    let airframeClass: AirframeClass
    let fixedWingParameters: FixedWingParameters?
    let deltaTime: Float
    let safeTravelAltitude: Float
}

struct AutoNavigationDirective: Equatable {
    let axisIntent: AutoNavigationAxisIntent
    let targetAltitude: Float
    let targetWorldPosition: SIMD3<Float>
    let distanceToTarget: Float
    let bearingDegrees: Float
}

final class AutoNavigationController {
    private(set) var targetMarker: TargetMarkerState?
    private(set) var isActive: Bool = false
    private(set) var phase: AutoNavigationPhase = .inactive

    private var lastCompletionReason: AutoNavigationCompletionReason = .none
    private var lockedTravelAltitude: Float?
    private var lastCourseCommandRadians: Float?

    func replaceTarget(_ targetMarker: TargetMarkerState) {
        self.targetMarker = targetMarker
        isActive = false
        phase = .inactive
        lastCompletionReason = .none
        lockedTravelAltitude = nil
        lastCourseCommandRadians = nil
    }

    func clearTarget() {
        targetMarker = nil
        isActive = false
        phase = .inactive
        lastCompletionReason = .cancelled
        lockedTravelAltitude = nil
        lastCourseCommandRadians = nil
    }

    func start(safeTravelAltitude: Float) {
        guard targetMarker != nil else {
            return
        }
        isActive = true
        phase = .takeoff
        lastCompletionReason = .none
        lockedTravelAltitude = safeTravelAltitude
        lastCourseCommandRadians = nil
    }

    func cancel() {
        guard isActive else {
            return
        }
        isActive = false
        phase = .inactive
        lastCompletionReason = .cancelled
        lockedTravelAltitude = nil
        lastCourseCommandRadians = nil
    }

    func consumeCompletionReason() -> AutoNavigationCompletionReason {
        let reason = lastCompletionReason
        lastCompletionReason = .none
        return reason
    }

    func status(from planarPosition: SIMD2<Float>) -> AutoNavigationStatus {
        guard let targetMarker else {
            return .inactive
        }

        return AutoNavigationStatus(
            isActive: isActive,
            phase: phase,
            distanceToTarget: targetMarker.distance(from: planarPosition),
            bearingDegrees: targetMarker.bearingDegrees(from: planarPosition),
            hasTarget: true
        )
    }

    func update(with input: AutoNavigationUpdateInput) -> AutoNavigationDirective? {
        guard isActive, let targetMarker else {
            return nil
        }

        // Reject non-finite inputs early so the rest of the controller does
        // not emit NaN axis intents. Such values can arrive from a malformed
        // marker, a recovering physics tick, or out-of-bounds projections.
        guard isFiniteVector3(input.position),
              isFiniteVector3(input.velocity),
              input.currentYawRadians.isFinite,
              isFiniteVector2(targetMarker.position) else {
            return nil
        }

        let planarPosition = SIMD2<Float>(input.position.x, input.position.z)
        let planarVelocity = SIMD2<Float>(input.velocity.x, input.velocity.z)
        let delta = targetMarker.position - planarPosition
        let distanceToTarget = simd_length(delta)
        let bearingDegrees = targetMarker.bearingDegrees(from: planarPosition)
        let safeTravelAltitude = lockedTravelAltitude ?? input.safeTravelAltitude
        let targetWorldPosition = targetMarker.worldPosition(altitude: safeTravelAltitude)

        guard distanceToTarget.isFinite, distanceToTarget > 0.0001 else {
            return nil
        }

        let direction = delta / distanceToTarget
        // Match the same body-frame forward convention used by the manual movement layer:
        // nose-forward aligns with the local -Z axis rather than +Z.
        let bodyForwardWorld = SIMD2<Float>(sin(input.currentYawRadians), -cos(input.currentYawRadians))
        let rightWorld = SIMD2<Float>(cos(input.currentYawRadians), sin(input.currentYawRadians))
        let localForward = simd_dot(direction, bodyForwardWorld)
        let localRight = simd_dot(direction, rightWorld)
        let localVelocityForward = simd_dot(planarVelocity, bodyForwardWorld)
        let localVelocityRight = simd_dot(planarVelocity, rightWorld)
        let planarSpeed = simd_length(planarVelocity)

        let verticalVelocity = input.velocity.y

        let axisIntent: AutoNavigationAxisIntent
        let targetAltitude: Float

        switch input.airframeClass {
        case .multirotor:
            let slowdownRadius: Float = 9.5
            let stabilizationRadius: Float = 1.8
            let reachedRadius: Float = 0.85
            let holdAltitude = min(safeTravelAltitude, input.position.y)
            let effectiveTargetAltitude =
                distanceToTarget <= stabilizationRadius
                ? holdAltitude
                : safeTravelAltitude
            let altitudeError = effectiveTargetAltitude - input.position.y

            if distanceToTarget <= reachedRadius,
               planarSpeed <= 0.32,
               abs(verticalVelocity) <= 0.28,
               abs(altitudeError) <= 0.45 {
                isActive = false
                phase = .hold
                lastCompletionReason = .reachedTarget
                lockedTravelAltitude = nil
                return nil
            }

            if input.physicalState.isGroundRestState || input.position.y < safeTravelAltitude - 1.2 {
                phase = .takeoff
                axisIntent = .zero
                targetAltitude = safeTravelAltitude
            } else if distanceToTarget <= stabilizationRadius {
                phase = .hold
                let forwardIntent = (localForward * 0.42 - localVelocityForward * 0.34).clamped(to: -0.38...0.38)
                let strafeIntent = (localRight * 0.42 - localVelocityRight * 0.34).clamped(to: -0.38...0.38)
                axisIntent = AutoNavigationAxisIntent(
                    forward: forwardIntent,
                    strafe: strafeIntent,
                    vertical: 0.0
                )
                targetAltitude = effectiveTargetAltitude
            } else {
                let slowdownScale = (distanceToTarget / slowdownRadius).clamped(to: 0.0...1.0)
                phase = distanceToTarget > slowdownRadius ? .cruise : .approach
                let movementScale = slowdownScale
                axisIntent = AutoNavigationAxisIntent(
                    forward: (localForward * movementScale - localVelocityForward * 0.18).clamped(to: -1.0...1.0),
                    strafe: (localRight * movementScale - localVelocityRight * 0.18).clamped(to: -1.0...1.0),
                    vertical: 0.0
                )
                targetAltitude = effectiveTargetAltitude
            }

        case .fixedWing, .hybridVTOL:
            let wing = resolvedFixedWingParameters(input.fixedWingParameters)
            let currentAirspeed = max(planarSpeed, input.physicalState.isGroundRestState ? 0.0 : wing.minSafeAirspeed * 0.62)
            let minimumTurnRadius = wing.minimumTurnRadius(
                airspeed: max(currentAirspeed, wing.cruiseAirspeed * 0.84)
            )
            let slowdownRadius = max(
                wing.waypointAcceptanceRadiusMeters * 3.2,
                minimumTurnRadius * 1.35,
                wing.cruiseAirspeed * 1.4
            )
            let reachedRadius = max(
                wing.waypointAcceptanceRadiusMeters,
                minimumTurnRadius * 0.44
            )
            let altitudeError = safeTravelAltitude - input.position.y
            let speedError = max(0.0, wing.minSafeAirspeed - currentAirspeed)
            let directCourse = atan2(-delta.x, -delta.y)
            var courseError = shortestAngleRadians(directCourse - input.currentYawRadians)
            let turnCaptureDistance = minimumTurnRadius * 1.18
            let turnCaptureActive = distanceToTarget < turnCaptureDistance && abs(courseError) > 0.58

            let courseBlend = (input.deltaTime * (turnCaptureActive ? 2.4 : 1.8)).clamped(to: 0.08...0.30)
            let previousCourseCommand = lastCourseCommandRadians ?? input.currentYawRadians
            let commandedCourse = previousCourseCommand +
                shortestAngleRadians(directCourse - previousCourseCommand) * courseBlend
            lastCourseCommandRadians = commandedCourse
            courseError = shortestAngleRadians(commandedCourse - input.currentYawRadians)

            if distanceToTarget <= reachedRadius,
               abs(courseError) <= 1.18,
               abs(altitudeError) <= 1.2,
               abs(verticalVelocity) <= 1.4 {
                isActive = false
                phase = .hold
                lastCompletionReason = .reachedTarget
                lockedTravelAltitude = nil
                lastCourseCommandRadians = nil
                return nil
            }

            let maxBankRadians = wing.maxBankAngleDeg * .pi / 180.0
            let bankIntent = (
                courseError / max(0.36, maxBankRadians * 1.15)
            ).clamped(to: -1.0...1.0)

            if input.physicalState.isGroundRestState || input.position.y < 1.1 {
                phase = .takeoff
                axisIntent = AutoNavigationAxisIntent(
                    forward: (-0.56 - altitudeError.clamped(to: -1.0...6.0) * 0.024).clamped(to: -0.76 ... -0.38),
                    strafe: (bankIntent * 0.26 * wing.bankResponseGain - localVelocityRight * 0.06).clamped(to: -0.34...0.34),
                    vertical: 1.0
                )
                targetAltitude = safeTravelAltitude
            } else {
                let slowdownScale = (distanceToTarget / slowdownRadius).clamped(to: 0.40...1.0)
                phase = distanceToTarget > slowdownRadius ? .cruise : .approach
                let closeTurnDemand = turnCaptureActive || (distanceToTarget < minimumTurnRadius * 1.15 && abs(courseError) > 0.92)
                let turnAuthorityScale = closeTurnDemand ? 1.0 : max(0.58, slowdownScale)
                let requestedVerticalSpeed = altitudeError >= 0.0
                    ? min(wing.climbSpeedMps * 0.24, altitudeError * 0.44)
                    : max(-wing.climbSpeedMps * 0.18, altitudeError * 0.30)
                var pitchIntent = (
                    -requestedVerticalSpeed / max(wing.climbAirspeed, 0.1) * (1.9 * wing.climbResponseGain) +
                    verticalVelocity * (0.07 * wing.descentResponseGain)
                ).clamped(to: -0.58...0.30)
                if speedError > 0.02 {
                    pitchIntent = max(
                        pitchIntent,
                        min(0.34, speedError / max(wing.minSafeAirspeed, 0.1) * 0.48)
                    )
                }
                let throttleBase = (
                    0.44 +
                    slowdownScale * 0.18 +
                    speedError * 0.10 +
                    (closeTurnDemand ? 0.05 : 0.0)
                ).clamped(to: 0.42...0.88)
                axisIntent = AutoNavigationAxisIntent(
                    forward: pitchIntent,
                    strafe: (
                        bankIntent * turnAuthorityScale * wing.turnAuthority -
                        localVelocityRight * 0.08
                    ).clamped(to: -1.0...1.0),
                    vertical: (
                        throttleBase +
                        altitudeError * 0.04 -
                        verticalVelocity * 0.03
                    ).clamped(to: 0.26...0.94)
                )
                targetAltitude = safeTravelAltitude
            }
        }

        return AutoNavigationDirective(
            axisIntent: axisIntent,
            targetAltitude: targetAltitude,
            targetWorldPosition: targetWorldPosition,
            distanceToTarget: distanceToTarget,
            bearingDegrees: bearingDegrees
        )
    }
}

private extension AutoNavigationController {
    func resolvedFixedWingParameters(
        _ fixedWingParameters: FixedWingParameters?
    ) -> FixedWingParameters {
        fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
    }

    func shortestAngleRadians(_ angle: Float) -> Float {
        var normalized = angle
        while normalized > .pi {
            normalized -= (.pi * 2.0)
        }
        while normalized < -.pi {
            normalized += (.pi * 2.0)
        }
        return normalized
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
