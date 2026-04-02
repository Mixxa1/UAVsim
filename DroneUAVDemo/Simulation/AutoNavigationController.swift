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
    private var lastTurnBiasSign: Float = 1.0

    func replaceTarget(_ targetMarker: TargetMarkerState) {
        self.targetMarker = targetMarker
        isActive = false
        phase = .inactive
        lastCompletionReason = .none
        lastTurnBiasSign = 1.0
    }

    func clearTarget() {
        targetMarker = nil
        isActive = false
        phase = .inactive
        lastCompletionReason = .cancelled
        lastTurnBiasSign = 1.0
    }

    func start() {
        guard targetMarker != nil else {
            return
        }
        isActive = true
        phase = .takeoff
        lastCompletionReason = .none
    }

    func cancel() {
        guard isActive else {
            return
        }
        isActive = false
        phase = .inactive
        lastCompletionReason = .cancelled
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

        let planarPosition = SIMD2<Float>(input.position.x, input.position.z)
        let planarVelocity = SIMD2<Float>(input.velocity.x, input.velocity.z)
        let delta = targetMarker.position - planarPosition
        let distanceToTarget = simd_length(delta)
        let bearingDegrees = targetMarker.bearingDegrees(from: planarPosition)
        let targetWorldPosition = targetMarker.worldPosition(altitude: input.safeTravelAltitude)

        guard distanceToTarget > 0.0001 else {
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

        let altitudeError = input.safeTravelAltitude - input.position.y
        let verticalVelocity = input.velocity.y

        let axisIntent: AutoNavigationAxisIntent

        switch input.airframeClass {
        case .multirotor:
            let slowdownRadius: Float = 9.5
            let stabilizationRadius: Float = 1.8
            let reachedRadius: Float = 0.85

            if distanceToTarget <= reachedRadius,
               planarSpeed <= 0.32,
               abs(verticalVelocity) <= 0.28,
               abs(altitudeError) <= 0.45 {
                isActive = false
                phase = .hold
                lastCompletionReason = .reachedTarget
                return nil
            }

            if input.physicalState.isGroundRestState || input.position.y < input.safeTravelAltitude - 1.2 {
                phase = .takeoff
                let verticalIntent = (altitudeError * 0.40 - verticalVelocity * 0.16).clamped(to: 0.30...1.0)
                axisIntent = AutoNavigationAxisIntent(forward: 0.0, strafe: 0.0, vertical: verticalIntent)
            } else if distanceToTarget <= stabilizationRadius {
                phase = .hold
                let forwardIntent = (localForward * 0.42 - localVelocityForward * 0.34).clamped(to: -0.38...0.38)
                let strafeIntent = (localRight * 0.42 - localVelocityRight * 0.34).clamped(to: -0.38...0.38)
                let verticalIntent = (altitudeError * 0.36 - verticalVelocity * 0.20).clamped(to: -0.55...0.55)
                axisIntent = AutoNavigationAxisIntent(
                    forward: forwardIntent,
                    strafe: strafeIntent,
                    vertical: verticalIntent
                )
            } else {
                let slowdownScale = (distanceToTarget / slowdownRadius).clamped(to: 0.0...1.0)
                phase = distanceToTarget > slowdownRadius ? .cruise : .approach
                let movementScale = slowdownScale
                let verticalIntent = (altitudeError * 0.34 - verticalVelocity * 0.16).clamped(to: -0.60...0.60)
                axisIntent = AutoNavigationAxisIntent(
                    forward: (localForward * movementScale - localVelocityForward * 0.18).clamped(to: -1.0...1.0),
                    strafe: (localRight * movementScale - localVelocityRight * 0.18).clamped(to: -1.0...1.0),
                    vertical: verticalIntent
                )
            }

        case .fixedWing:
            let slowdownRadius: Float = 18.0
            let reachedRadius: Float = 4.8
            if distanceToTarget <= reachedRadius {
                isActive = false
                phase = .hold
                lastCompletionReason = .reachedTarget
                return nil
            }

            let slowdownScale = (distanceToTarget / slowdownRadius).clamped(to: 0.18...1.0)
            let turnBias: Float
            if localForward < -0.10 {
                let sign = abs(localRight) > 0.05 ? (localRight > 0 ? 1.0 : -1.0) : lastTurnBiasSign
                lastTurnBiasSign = sign
                turnBias = sign * 0.35
            } else {
                if abs(localRight) > 0.05 {
                    lastTurnBiasSign = localRight > 0 ? 1.0 : -1.0
                }
                turnBias = 0.0
            }

            if input.physicalState.isGroundRestState || input.position.y < 1.1 {
                phase = .takeoff
                axisIntent = AutoNavigationAxisIntent(
                    forward: 0.72,
                    strafe: (localRight * 0.40 + turnBias * 0.4).clamped(to: -0.55...0.55),
                    vertical: 1.0
                )
            } else {
                phase = distanceToTarget > slowdownRadius ? .cruise : .approach
                let pitchTrim = (altitudeError * 0.16 - verticalVelocity * 0.08).clamped(to: -0.45...0.45)
                let forwardBase = max(0.08, slowdownScale * 0.24)
                let throttleBase = (0.24 + slowdownScale * 0.16).clamped(to: 0.12...0.42)
                axisIntent = AutoNavigationAxisIntent(
                    forward: (forwardBase + pitchTrim).clamped(to: -0.35...0.75),
                    strafe: ((localRight * 0.92 + turnBias) * max(0.30, slowdownScale)).clamped(to: -1.0...1.0),
                    vertical: (throttleBase + altitudeError * 0.06 - verticalVelocity * 0.04).clamped(to: -0.25...0.85)
                )
            }
        }

        return AutoNavigationDirective(
            axisIntent: axisIntent,
            targetAltitude: input.safeTravelAltitude,
            targetWorldPosition: targetWorldPosition,
            distanceToTarget: distanceToTarget,
            bearingDegrees: bearingDegrees
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
