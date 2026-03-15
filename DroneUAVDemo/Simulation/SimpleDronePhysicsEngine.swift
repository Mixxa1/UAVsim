import Foundation
import simd

final class SimpleDronePhysicsEngine: DronePhysicsEngine {
    private enum Tuning {
        static let fixedStep: Float = 1.0 / 90.0
        static let gravity: Float = 9.81
        static let startupDiagnosticsFrames = 8
        static let enableContinuousForceLogging = false
    }

    private var startupDiagnosticsFrames = Tuning.startupDiagnosticsFrames
    private var warnedAboutStartupLateralForce = false
    private var verticalDebugCooldown: Float = 0.0

    func step(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        deltaTime: Float
    ) -> DroneState {
        let clampedDelta = max(0.001, min(deltaTime, 1.0 / 20.0))

        var next = state
        var remaining = clampedDelta
        while remaining > 0.0 {
            let dt = min(Tuning.fixedStep, remaining)
            switch context.profile.airframeClass {
            case .multirotor:
                next = stepMultirotorBaseline(state: next, control: control, context: context, dt: dt)
            case .fixedWing:
                next = stepFixedWingBaseline(state: next, control: control, context: context, dt: dt)
            }
            remaining -= dt
        }

        next.mode = control.mode
        return next
    }

    private func stepMultirotorBaseline(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = state

        let profile = context.profile
        let weather = context.weather.effectiveFactors
        let authority = context.damageState.controlAuthorityMultiplier.clamped(to: 0.20...1.00)
        let batteryFactor = max(0.10, context.batteryState.chargePercent / 100.0)
        let mass = max(0.20, profile.massKg)
        let hoverThrottle = profile.hoverThrottle.clamped(to: 0.20...0.82)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed
        let groundRestThrottleThreshold = max(0.18, hoverThrottle * 0.68)

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.batteryState.isDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        }

        if control.mode == .hover || control.controlMode == .hoverAssist {
            let altitudeError = control.targetPosition.y - state.position.y
            let verticalDamping = -state.velocity.y
            let correction = altitudeError * 0.05 + verticalDamping * 0.03
            throttleCommand = (hoverThrottle + correction + (throttleCommand - hoverThrottle) * 0.25).clamped(to: 0.0...1.0)
        }

        let spoolUpRate = (2.6 + authority * 2.4).clamped(to: 1.6...5.2)
        let spoolDownRate = (3.4 + authority * 1.8).clamped(to: 2.0...5.8)
        let motorThrottle = approach(
            current: state.motorThrottle,
            target: throttleCommand,
            increaseRate: spoolUpRate,
            decreaseRate: spoolDownRate,
            dt: dt
        )

        var desiredRates = crashOrDisarmed ? SIMD3<Float>(repeating: 0.0) : desiredMultirotorRates(
            control: control,
            state: state,
            authority: authority
        )

        var rateGain = control.controlMode.isRateMode
            ? SIMD3<Float>(8.6 * authority, 8.6 * authority, 5.6 * authority)
            : SIMD3<Float>(7.2 * authority, 7.2 * authority, 4.8 * authority)
        var angularDamping = control.controlMode.isRateMode
            ? SIMD3<Float>(1.6, 1.6, 1.5)
            : SIMD3<Float>(2.8, 2.8, 2.2)

        let groundedLowThrottleSafety = state.position.y <= 0.08 &&
            state.physicalState.isGroundRestState &&
            throttleCommand <= groundRestThrottleThreshold

        if groundedLowThrottleSafety {
            desiredRates *= SIMD3<Float>(repeating: 0.06)
            rateGain *= SIMD3<Float>(repeating: 0.22)
            angularDamping *= SIMD3<Float>(4.8, 4.8, 4.2)
        } else if state.physicalState == .landing && state.position.y <= 0.18 {
            angularDamping *= SIMD3<Float>(1.5, 1.5, 1.35)
        } else if state.physicalState == .crashed {
            desiredRates = .zero
            rateGain = SIMD3<Float>(repeating: 0.12)
            angularDamping = SIMD3<Float>(14.0, 14.0, 11.0)
        }

        let angularAccel = (desiredRates - state.angularVelocity) * rateGain - state.angularVelocity * angularDamping

        next.angularVelocity = state.angularVelocity + angularAccel * dt
        next.angularVelocity = clampMagnitude(next.angularVelocity, limit: 8.0)
        next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)

        let q = orientationQuaternion(from: next.orientation)
        let maxThrust = mass * Tuning.gravity * (2.10 * authority + 0.45) * batteryFactor
        let thrustMagnitude = motorThrottle * maxThrust
        let thrustWorld = simd_act(q, SIMD3<Float>(0.0, thrustMagnitude, 0.0))

        let gravityForce = SIMD3<Float>(0.0, -mass * Tuning.gravity, 0.0)
        let linearDrag = -state.velocity * (1.45 + weather.dragMultiplier * 0.45)
        let windCompensation = (context.windVector - state.velocity) * (0.08 + weather.turbulenceFactor * 0.06)
        let totalForce = thrustWorld + gravityForce + linearDrag + windCompensation

        emitStartupDiagnosticsIfNeeded(
            state: state,
            control: control,
            context: context,
            totalForce: totalForce,
            thrustWorld: thrustWorld,
            motorThrottle: motorThrottle
        )
        emitVerticalDiagnosticsIfNeeded(
            control: control,
            hoverThrottle: hoverThrottle,
            motorThrottle: motorThrottle,
            thrustWorld: thrustWorld,
            totalForce: totalForce,
            dt: dt
        )

        let acceleration = totalForce / mass
        next.velocity = state.velocity + acceleration * dt

        let horizontalMax = profile.maxHorizontalSpeedMps.clamped(to: 3.0...42.0)
        let verticalUpMax = profile.maxAscentSpeedMps.clamped(to: 1.0...20.0)
        let verticalDownMax = profile.maxDescentSpeedMps.clamped(to: 1.0...20.0)

        next.velocity.x = next.velocity.x.clamped(to: -horizontalMax...horizontalMax)
        next.velocity.z = next.velocity.z.clamped(to: -horizontalMax...horizontalMax)
        next.velocity.y = next.velocity.y.clamped(to: -verticalDownMax...verticalUpMax)

        next.position = state.position + next.velocity * dt
        if next.position.y < 0.0 {
            next.position.y = 0.0
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        let groundRestState = next.position.y <= 0.03 && state.physicalState.isGroundRestState
        if groundRestState {
            next.position.y = 0.0
            next.velocity.x *= max(0.0, 1.0 - dt * 14.0)
            next.velocity.z *= max(0.0, 1.0 - dt * 14.0)
            next.velocity.y = 0.0
            next.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * (state.physicalState == .crashed ? 12.0 : 18.0)))

            if state.physicalState != .crashed {
                next.orientation.x = approach(current: next.orientation.x, target: 0.0, increaseRate: 5.4, decreaseRate: 5.4, dt: dt)
                next.orientation.y = approach(current: next.orientation.y, target: 0.0, increaseRate: 5.4, decreaseRate: 5.4, dt: dt)
            }

            if abs(next.orientation.x) < 0.0005 { next.orientation.x = 0.0 }
            if abs(next.orientation.y) < 0.0005 { next.orientation.y = 0.0 }
            if simd_length(SIMD2<Float>(next.velocity.x, next.velocity.z)) < 0.02 {
                next.velocity.x = 0.0
                next.velocity.z = 0.0
            }
            if simd_length(next.angularVelocity) < 0.02 {
                next.angularVelocity = .zero
            }
        }

        let rotorOmega: Float
        if state.physicalState == .crashed || !control.isArmed {
            rotorOmega = 0.0
        } else if groundRestState && throttleCommand <= groundRestThrottleThreshold {
            rotorOmega = 58.0
        } else {
            rotorOmega = 120.0 + motorThrottle * 640.0
        }
        if state.physicalState == .crashed || !control.isArmed {
            next.throttle = 0.0
        } else if groundRestState && throttleCommand <= groundRestThrottleThreshold {
            next.throttle = min(motorThrottle, 0.08)
        } else {
            next.throttle = motorThrottle
        }
        next.motorThrottle = next.throttle
        next.rotorAngularSpeed = SIMD4<Float>(repeating: rotorOmega)
        next.forwardAirspeed = simd_length(SIMD2<Float>(next.velocity.x, next.velocity.z))

        return next
    }

    private func desiredMultirotorRates(
        control: DroneControlInput,
        state: DroneState,
        authority: Float
    ) -> SIMD3<Float> {
        let stabilizedLimit = Float(36.0).degreesToRadians
        let hoverLimit = Float(22.0).degreesToRadians
        let acroRate = Float(5.8) * authority

        switch control.controlMode {
        case .stabilized:
            let desiredAngles = SIMD3<Float>(
                control.targetOrientation.x.clamped(to: -stabilizedLimit...stabilizedLimit),
                control.targetOrientation.y.clamped(to: -stabilizedLimit...stabilizedLimit),
                wrap(control.targetOrientation.z)
            )
            return angleTrackingRates(desiredAngles: desiredAngles, state: state)

        case .hoverAssist:
            let desiredAngles = SIMD3<Float>(
                control.targetOrientation.x.clamped(to: -hoverLimit...hoverLimit),
                control.targetOrientation.y.clamped(to: -hoverLimit...hoverLimit),
                wrap(control.targetOrientation.z)
            )
            return angleTrackingRates(desiredAngles: desiredAngles, state: state)

        case .acro:
            return SIMD3<Float>(
                control.targetOrientation.x.clamped(to: -1.0...1.0) * acroRate,
                control.targetOrientation.y.clamped(to: -1.0...1.0) * acroRate,
                wrap(control.targetOrientation.z - state.orientation.z) * 2.4
            )
        }
    }

    private func stepFixedWingBaseline(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = state

        let profile = context.profile
        let wing = profile.fixedWingParameters ?? FixedWingParameters(
            family: .rectangular,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            turnAuthority: 0.7,
            maxBankAngleDeg: 42.0
        )
        let authority = context.damageState.controlAuthorityMultiplier.clamped(to: 0.20...1.00)
        let batteryFactor = max(0.10, context.batteryState.chargePercent / 100.0)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.batteryState.isDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        }

        let motorThrottle = approach(
            current: state.motorThrottle,
            target: throttleCommand,
            increaseRate: 1.8,
            decreaseRate: 2.4,
            dt: dt
        )

        let maxBank = Float(wing.maxBankAngleDeg).degreesToRadians
        let maxPitch = (control.controlMode == .hoverAssist ? Float(16.0) : Float(26.0)).degreesToRadians
        let targetYaw = wrap(control.targetOrientation.z)

        if state.physicalState == .crashed {
            next.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * 10.0))
            next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)
        } else if control.controlMode.isRateMode {
            let rollRateCommand = control.targetOrientation.x.clamped(to: -1.0...1.0) * (2.6 * authority * wing.turnAuthority.clamped(to: 0.5...1.4))
            let pitchRateCommand = (-control.targetOrientation.y).clamped(to: -1.0...1.0) * (2.1 * authority)
            let yawRateCommand = wrap(targetYaw - state.orientation.z) * (2.0 * wing.turnAuthority.clamped(to: 0.4...1.4))
            let rateCommand = SIMD3<Float>(rollRateCommand, pitchRateCommand, yawRateCommand)
            let rateGain = SIMD3<Float>(6.2 * authority, 5.0 * authority, 4.0 * authority)
            let damping = SIMD3<Float>(1.5, 1.4, 1.3)
            next.angularVelocity = state.angularVelocity + ((rateCommand - state.angularVelocity) * rateGain - state.angularVelocity * damping) * dt
            next.angularVelocity = clampMagnitude(next.angularVelocity, limit: 7.8)
            next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)
        } else {
            let targetRoll = control.targetOrientation.x.clamped(to: -maxBank...maxBank)
            let targetPitch = (-control.targetOrientation.y).clamped(to: -maxPitch...maxPitch)
            next.orientation.x = approach(current: state.orientation.x, target: targetRoll, increaseRate: 2.6 * authority, decreaseRate: 2.8 * authority, dt: dt)
            next.orientation.y = approach(current: state.orientation.y, target: targetPitch, increaseRate: 2.2 * authority, decreaseRate: 2.4 * authority, dt: dt)
            next.orientation.z = wrap(approach(current: state.orientation.z, target: targetYaw, increaseRate: 1.8 * authority, decreaseRate: 1.8 * authority, dt: dt))
            next.angularVelocity = SIMD3<Float>(
                (next.orientation.x - state.orientation.x) / max(0.0001, dt),
                (next.orientation.y - state.orientation.y) / max(0.0001, dt),
                (next.orientation.z - state.orientation.z) / max(0.0001, dt)
            )
        }

        let cruiseTarget = max(wing.minSustainableSpeedMps * 0.78, wing.cruiseSpeedMps)
        let targetForwardSpeed = motorThrottle * min(profile.maxHorizontalSpeedMps, cruiseTarget * 1.45) * (0.55 + 0.45 * batteryFactor)
        let forwardSpeed = approach(current: max(0.0, state.forwardAirspeed), target: targetForwardSpeed, increaseRate: 6.8, decreaseRate: 5.2, dt: dt)

        let q = orientationQuaternion(from: next.orientation)
        var velocity = simd_act(q, SIMD3<Float>(0.0, 0.0, forwardSpeed))
        velocity += (context.windVector - velocity) * 0.05

        if next.position.y <= 0.0 && motorThrottle < 0.12 {
            velocity.y = 0.0
        }

        next.velocity = velocity
        next.position += next.velocity * dt
        if next.position.y < 0.0 {
            next.position.y = 0.0
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        let groundRestState = next.position.y <= 0.03 && state.physicalState.isGroundRestState && motorThrottle < 0.18
        if groundRestState {
            next.velocity.x *= max(0.0, 1.0 - dt * 10.0)
            next.velocity.z *= max(0.0, 1.0 - dt * 10.0)
            next.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * 12.0))
            if state.physicalState != .crashed {
                next.orientation.x = approach(current: next.orientation.x, target: 0.0, increaseRate: 4.0, decreaseRate: 4.0, dt: dt)
                next.orientation.y = approach(current: next.orientation.y, target: 0.0, increaseRate: 4.0, decreaseRate: 4.0, dt: dt)
            }
        }

        next.throttle = crashOrDisarmed ? 0.0 : motorThrottle
        next.motorThrottle = next.throttle
        next.rotorAngularSpeed = SIMD4<Float>(crashOrDisarmed ? 0.0 : (60.0 + motorThrottle * 540.0), 0.0, 0.0, 0.0)
        next.forwardAirspeed = forwardSpeed

        return next
    }

    private func angleTrackingRates(
        desiredAngles: SIMD3<Float>,
        state: DroneState
    ) -> SIMD3<Float> {
        let rollError = wrap(desiredAngles.x - state.orientation.x)
        let pitchError = wrap(desiredAngles.y - state.orientation.y)
        let yawError = wrap(desiredAngles.z - state.orientation.z)

        return SIMD3<Float>(
            rollError * 4.8,
            pitchError * 4.8,
            yawError * 2.2
        )
    }

    private func emitStartupDiagnosticsIfNeeded(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        totalForce: SIMD3<Float>,
        thrustWorld: SIMD3<Float>,
        motorThrottle: Float
    ) {
        guard startupDiagnosticsFrames > 0 else { return }
        guard context.profile.airframeClass == .multirotor else { return }

        startupDiagnosticsFrames -= 1
        let lateralForce = simd_length(SIMD2<Float>(totalForce.x, totalForce.z))

        print(
            "[PhysicsStartup] mode=\(state.mode.rawValue) " +
            "pos=\(state.position) ori=\(state.orientation) vel=\(state.velocity) angVel=\(state.angularVelocity) " +
            "throttleCmd=\(control.throttle) motor=\(motorThrottle) wind=\(context.windVector) " +
            "thrustWorld=\(thrustWorld) totalForce=\(totalForce)"
        )

        if lateralForce > 0.35, !warnedAboutStartupLateralForce {
            print("[PhysicsStartup][Warning] Nonzero startup lateral force = \(lateralForce)")
            warnedAboutStartupLateralForce = true
        }
    }

    private func emitVerticalDiagnosticsIfNeeded(
        control: DroneControlInput,
        hoverThrottle: Float,
        motorThrottle: Float,
        thrustWorld: SIMD3<Float>,
        totalForce: SIMD3<Float>,
        dt: Float
    ) {
        guard Tuning.enableContinuousForceLogging else {
            return
        }

        verticalDebugCooldown = max(0.0, verticalDebugCooldown - dt)

        let verticalCommandMagnitude = abs(control.throttle - hoverThrottle)
        guard verticalCommandMagnitude > 0.03 else {
            return
        }
        guard verticalDebugCooldown <= 0.0 else {
            return
        }

        print(
            "[VerticalForce] throttleCmd=\(control.throttle) hover=\(hoverThrottle) motor=\(motorThrottle) " +
            "thrustWorld=\(thrustWorld) totalForce=\(totalForce)"
        )

        verticalDebugCooldown = 0.25
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        return yaw * pitch * roll
    }

    private func wrap(_ value: Float) -> Float {
        var angle = value
        let tau = Float.pi * 2.0
        while angle > Float.pi {
            angle -= tau
        }
        while angle < -Float.pi {
            angle += tau
        }
        return angle
    }

    private func wrappedAngles(_ angle: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(wrap(angle.x), wrap(angle.y), wrap(angle.z))
    }

    private func clampMagnitude(_ vector: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > limit else {
            return vector
        }
        return simd_normalize(vector) * limit
    }

    private func approach(current: Float, target: Float, increaseRate: Float, decreaseRate: Float, dt: Float) -> Float {
        let delta = target - current
        if delta > 0 {
            return current + min(delta, increaseRate * dt)
        }
        return current + max(delta, -decreaseRate * dt)
    }
}

private extension Float {
    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
