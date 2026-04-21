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
}

struct AutopilotControlCommand: Equatable {
    var positionTarget: SIMD3<Float>
    var rollDegrees: Float
    var pitchDegrees: Float
    var yawDegrees: Float
    var throttle: Float
}

final class MulticopterAutopilotController {
    func command(for context: AutopilotTrackingContext) -> AutopilotControlCommand {
        let headingVector = SIMD2<Float>(
            context.target.x - context.state.position.x,
            context.target.z - context.state.position.z
        )
        let yawRadians = context.yawOverrideRadians ?? atan2(-headingVector.x, headingVector.y)
        let controlScale = context.speedScale
        let altitudeError = context.targetAltitude - context.state.position.y
        let verticalComp =
            (altitudeError * 0.06 - context.state.velocity.y * 0.03) *
            context.flightBaseline.effectiveVerticalResponseFactor
        let commandedThrottle = clampFloat(
            context.flightBaseline.hoverLockThrottle + verticalComp,
            to: 0.18...0.90
        )

        return AutopilotControlCommand(
            positionTarget: SIMD3<Float>(
                context.target.x,
                context.targetAltitude,
                context.target.z
            ),
            rollDegrees: clampFloat(-headingVector.x * 0.95 * controlScale, to: -16.0...16.0),
            pitchDegrees: clampFloat(headingVector.y * 0.95 * controlScale, to: -16.0...16.0),
            yawDegrees: {
                if context.yawAlignToHome && simd_length(headingVector) < 1.2 {
                    return 0.0
                }
                return radiansToDegrees(yawRadians)
            }(),
            throttle: clampFloat(commandedThrottle, to: 0.0...1.0)
        )
    }
}

private func clampFloat(_ value: Float, to range: ClosedRange<Float>) -> Float {
    Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
}

private func radiansToDegrees(_ radians: Float) -> Float {
    radians * 180.0 / .pi
}
