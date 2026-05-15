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
        let payloadMassModel = context.vehicleMassModel
        let baseline = FlightBaselineResolver.resolve(
            runtimeProfile: profile,
            activeUAVProfile: context.activeUAVProfile,
            vehicleMassModel: payloadMassModel,
            flightMode: control.mode
        )
        let maneuverAuthorityPenalty = baseline.maneuverAuthorityMultiplier
        let authority = (context.damageState.controlAuthorityMultiplier * maneuverAuthorityPenalty).clamped(to: 0.18...1.00)
        let batteryFactor = max(0.10, context.batteryState.chargePercent / 100.0)
        let mass = max(0.20, payloadMassModel.resolvedCurrentTotalMass)
        let hoverThrottle = baseline.hoverLockThrottle.clamped(to: 0.20...0.90)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed
        let groundRestThrottleThreshold = max(0.18, hoverThrottle * 0.68)

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.batteryState.isDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        }

        if control.mode == .hover || control.controlMode == .hoverAssist {
            let altitudeError = control.targetPosition.y - state.position.y
            let verticalDamping = -state.velocity.y
            let correction = (altitudeError * 0.05 + verticalDamping * 0.03) * baseline.effectiveVerticalResponseFactor
            throttleCommand = (hoverThrottle + correction + (throttleCommand - hoverThrottle) * 0.25).clamped(to: 0.0...1.0)
        }

        let spoolUpRate = (2.1 + authority * 1.8 + baseline.effectiveThrottleAuthority * 1.4).clamped(to: 1.6...5.4)
        let spoolDownRate = (2.8 + authority * 1.2 + baseline.effectiveThrottleAuthority * 1.0).clamped(to: 2.0...5.8)
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
        let liftPenalty = baseline.liftPenaltyMultiplier.clamped(to: 0.78...1.02)
        let maxThrust = mass * Tuning.gravity * (baseline.effectiveStabilizationThrust + authority * 0.35) * batteryFactor * liftPenalty
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
            var rates = angleTrackingRates(desiredAngles: desiredAngles, state: state)
            rates.z = desiredManualYawRate(
                control: control,
                state: state,
                authority: authority,
                fallbackHeading: desiredAngles.z,
                headingGain: 2.2,
                manualRateScale: 1.65
            )
            return rates

        case .hoverAssist:
            let desiredAngles = SIMD3<Float>(
                control.targetOrientation.x.clamped(to: -hoverLimit...hoverLimit),
                control.targetOrientation.y.clamped(to: -hoverLimit...hoverLimit),
                wrap(control.targetOrientation.z)
            )
            var rates = angleTrackingRates(desiredAngles: desiredAngles, state: state)
            rates.z = desiredManualYawRate(
                control: control,
                state: state,
                authority: authority,
                fallbackHeading: desiredAngles.z,
                headingGain: 2.2,
                manualRateScale: 1.65
            )
            return rates

        case .acro:
            return SIMD3<Float>(
                control.targetOrientation.x.clamped(to: -1.0...1.0) * acroRate,
                control.targetOrientation.y.clamped(to: -1.0...1.0) * acroRate,
                desiredManualYawRate(
                    control: control,
                    state: state,
                    authority: authority,
                    fallbackHeading: wrap(control.targetOrientation.z),
                    headingGain: 2.4,
                    manualRateScale: 2.10
                )
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
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.7,
            maxBankAngleDeg: 42.0
        )
        let payloadMassModel = context.vehicleMassModel
        let baseline = FlightBaselineResolver.resolve(
            runtimeProfile: profile,
            activeUAVProfile: context.activeUAVProfile,
            vehicleMassModel: payloadMassModel,
            flightMode: control.mode
        )
        let authorityPenalty = baseline.maneuverAuthorityMultiplier
        let authority = (context.damageState.controlAuthorityMultiplier * authorityPenalty).clamped(to: 0.18...1.00)
        let batteryFactor = max(0.10, context.batteryState.chargePercent / 100.0)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.batteryState.isDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        } else {
            let throttleFloor: Float
            switch baseline.vehicleType {
            case .fixedWing:
                switch control.mode {
                case .takeoff:
                    throttleFloor = baseline.takeoffThrottleReference
                case .landing:
                    throttleFloor = baseline.landingThrottleReference
                default:
                    throttleFloor = state.position.y > 0.15 ? baseline.effectiveMinimumSafeFlightThrottle : 0.0
                }
            case .hybridVTOL:
                switch control.mode {
                case .hover, .takeoff:
                    throttleFloor = baseline.takeoffThrottleReference
                case .landing:
                    throttleFloor = baseline.landingThrottleReference
                default:
                    throttleFloor = state.position.y > 0.15
                        ? max(baseline.cruiseReferenceThrottle, baseline.effectiveMinimumSafeFlightThrottle)
                        : 0.0
                }
            case .multicopter, .helicopter, .custom:
                throttleFloor = state.position.y > 0.15 ? baseline.cruiseReferenceThrottle : 0.0
            }
            throttleCommand = max(throttleCommand, throttleFloor)
        }

        let motorThrottle = approach(
            current: state.motorThrottle,
            target: throttleCommand,
            increaseRate: (1.6 + baseline.effectiveThrottleAuthority * 0.7 * wing.throttleResponseGain).clamped(to: 1.4...2.8),
            decreaseRate: (2.0 + baseline.effectiveThrottleAuthority * 0.6 * wing.throttleResponseGain).clamped(to: 1.8...3.0),
            dt: dt
        )

        let maxBank = Float(wing.maxBankAngleDeg).degreesToRadians
        let maxPitch = (control.controlMode == .hoverAssist ? Float(16.0) : Float(26.0)).degreesToRadians
        let targetYaw = wrap(control.targetOrientation.z)

        if state.physicalState == .crashed {
            next.angularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * 10.0))
            next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)
        } else if control.controlMode.isRateMode {
            let speedRatio = (max(state.forwardAirspeed, wing.minSustainableSpeedMps) / max(wing.cruiseSpeedMps, 0.1)).clamped(to: 0.55...1.35)
            let rollRateCommand = control.targetOrientation.x.clamped(to: -1.0...1.0) * (2.6 * authority * wing.turnAuthority.clamped(to: 0.5...1.4) * wing.bankResponseGain * speedRatio)
            let pitchRateCommand = control.targetOrientation.y.clamped(to: -1.0...1.0) * (2.1 * authority * max(0.78, wing.climbResponseGain))
            let yawRateCommand = desiredFixedWingYawRate(
                control: control,
                state: state,
                authority: authority,
                wing: wing,
                airspeed: max(state.forwardAirspeed, wing.minSustainableSpeedMps),
                fallbackHeading: targetYaw
            )
            let rateCommand = SIMD3<Float>(rollRateCommand, pitchRateCommand, yawRateCommand)
            let rateGain = SIMD3<Float>(6.2 * authority, 5.0 * authority, 4.0 * authority)
            let damping = SIMD3<Float>(1.5, 1.4, 1.3)
            next.angularVelocity = state.angularVelocity + ((rateCommand - state.angularVelocity) * rateGain - state.angularVelocity * damping) * dt
            next.angularVelocity = clampMagnitude(next.angularVelocity, limit: 7.8)
            next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)
        } else {
            let targetRoll = control.targetOrientation.x.clamped(to: -maxBank...maxBank)
            let targetPitch = control.targetOrientation.y.clamped(to: -maxPitch...maxPitch)
            next.orientation.x = approach(current: state.orientation.x, target: targetRoll, increaseRate: 2.6 * authority * wing.bankResponseGain, decreaseRate: 2.8 * authority * wing.bankResponseGain, dt: dt)
            next.orientation.y = approach(current: state.orientation.y, target: targetPitch, increaseRate: 2.2 * authority * max(0.76, wing.climbResponseGain), decreaseRate: 2.4 * authority * max(0.76, wing.descentResponseGain), dt: dt)
            if abs(control.yawIntent) > 0.001 {
                let yawRate = desiredFixedWingYawRate(
                    control: control,
                    state: state,
                    authority: authority,
                    wing: wing,
                    airspeed: max(state.forwardAirspeed, wing.minSustainableSpeedMps),
                    fallbackHeading: targetYaw
                )
                next.orientation.z = wrap(state.orientation.z + yawRate * dt)
            } else {
                let speedRatio = (state.forwardAirspeed / max(wing.cruiseSpeedMps, 0.1)).clamped(to: 0.45...1.20)
                let bankCoupling = sin(state.orientation.x) * wing.nominalTurnRateDegPerSec.degreesToRadians * max(0.45, speedRatio) * wing.turnAuthority
                let coupledYaw = wrap(state.orientation.z + bankCoupling * dt)
                next.orientation.z = wrap(approach(current: coupledYaw, target: targetYaw, increaseRate: 1.6 * authority * wing.bankResponseGain, decreaseRate: 1.6 * authority * wing.bankResponseGain, dt: dt))
            }
            next.angularVelocity = SIMD3<Float>(
                (next.orientation.x - state.orientation.x) / max(0.0001, dt),
                (next.orientation.y - state.orientation.y) / max(0.0001, dt),
                (next.orientation.z - state.orientation.z) / max(0.0001, dt)
            )
        }

        let cruiseTarget = max(
            wing.minSustainableSpeedMps * (0.82 + baseline.stallProtectionBias),
            wing.cruiseSpeedMps * baseline.payloadCruisePenaltyMultiplier
        )
        let climbTarget = max(wing.climbSpeedMps, wing.minSustainableSpeedMps)
        let speedEnvelope = control.mode == .takeoff ? climbTarget * 1.12 : cruiseTarget * 1.45
        let cappedAirspeed = min(profile.maxHorizontalSpeedMps, wing.maxAirspeed)
        let climbPenalty = max(0.0, sin(next.orientation.y)) * max(wing.cruiseAirspeed * 0.52, wing.nominalClimbRateMps * 2.4)
        let diveAssist = max(0.0, -sin(next.orientation.y)) * wing.cruiseAirspeed * 0.18
        let bankPenalty = abs(sin(next.orientation.x)) * max(wing.cruiseAirspeed * 0.20, wing.minSafeAirspeed * 0.25)
        let targetForwardSpeed = (
            motorThrottle * min(cappedAirspeed, speedEnvelope) * (0.55 + 0.45 * batteryFactor) -
            climbPenalty -
            bankPenalty +
            diveAssist
        ).clamped(to: 0.0...cappedAirspeed)
        let minimumForwardSpeed = state.position.y > 0.15
            ? wing.minSafeAirspeed * (0.90 + baseline.stallProtectionBias * 0.32)
            : 0.0
        let forwardSpeed = approach(
            current: max(0.0, state.forwardAirspeed),
            target: max(minimumForwardSpeed, targetForwardSpeed),
            increaseRate: (6.2 + baseline.effectiveThrottleAuthority * 0.8 * wing.throttleResponseGain).clamped(to: 5.0...8.0),
            decreaseRate: (4.8 + baseline.effectiveThrottleAuthority * 0.5 * wing.dragFactor).clamped(to: 4.0...6.4),
            dt: dt
        )

        let q = orientationQuaternion(from: next.orientation)
        var velocity = simd_act(q, SIMD3<Float>(0.0, 0.0, -forwardSpeed))
        velocity += (context.windVector - velocity) * (0.05 * wing.dragFactor)

        let maxClimbRate = min(profile.maxAscentSpeedMps, wing.nominalClimbRateMps * 1.45).clamped(to: 0.8...profile.maxAscentSpeedMps)
        let maxSinkRate = min(profile.maxDescentSpeedMps, wing.nominalSinkRateMps * 1.55).clamped(to: 0.8...profile.maxDescentSpeedMps)
        let clampedVerticalSpeed = velocity.y.clamped(to: -maxSinkRate...maxClimbRate)
        let planarVelocity = SIMD2<Float>(velocity.x, velocity.z)
        let planarDirection: SIMD2<Float>
        if simd_length(planarVelocity) > 0.001 {
            planarDirection = simd_normalize(planarVelocity)
        } else {
            planarDirection = SIMD2<Float>(-sin(next.orientation.z), -cos(next.orientation.z))
        }
        let planarSpeed = sqrt(max(0.0, forwardSpeed * forwardSpeed - clampedVerticalSpeed * clampedVerticalSpeed))
        velocity.x = planarDirection.x * planarSpeed
        velocity.z = planarDirection.y * planarSpeed
        velocity.y = clampedVerticalSpeed

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

    private func desiredManualYawRate(
        control: DroneControlInput,
        state: DroneState,
        authority: Float,
        fallbackHeading: Float,
        headingGain: Float,
        manualRateScale: Float
    ) -> Float {
        let manualIntent = control.yawIntent.clamped(to: -1.6...1.6)
        if abs(manualIntent) > 0.001 {
            return manualIntent * manualRateScale * authority
        }

        let yawError = wrap(fallbackHeading - state.orientation.z)
        return yawError * headingGain
    }

    private func desiredFixedWingYawRate(
        control: DroneControlInput,
        state: DroneState,
        authority: Float,
        wing: FixedWingParameters,
        airspeed: Float,
        fallbackHeading: Float
    ) -> Float {
        let manualIntent = control.yawIntent.clamped(to: -1.6...1.6)
        let turnScale = wing.turnAuthority.clamped(to: 0.4...1.4) * (airspeed / max(wing.cruiseSpeedMps, 0.1)).clamped(to: 0.55...1.25)
        if abs(manualIntent) > 0.001 {
            return manualIntent * wing.nominalTurnRateDegPerSec.degreesToRadians * 0.65 * authority * turnScale
        }

        let headingCorrection = wrap(fallbackHeading - state.orientation.z) * (0.52 * turnScale * wing.bankResponseGain)
        return headingCorrection + sin(state.orientation.x) * wing.nominalTurnRateDegPerSec.degreesToRadians * turnScale
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
