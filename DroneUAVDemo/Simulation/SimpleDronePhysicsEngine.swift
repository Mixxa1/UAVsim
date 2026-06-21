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

    /// Near-ground turbulence gust state (Dryden low-altitude model,
    /// MIL-F-8785C) — an Ornstein-Uhlenbeck process per axis, so it must
    /// persist across ticks rather than being recomputed fresh each step
    /// like everything else in `WeatherModel`. Lives on the engine (a class,
    /// one instance per simulation) rather than on `DroneState`/`WeatherModel`
    /// since it's filter state, not physical state — fixed-wing only.
    private var windGustState = SIMD3<Float>(repeating: 0.0)

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
                next = stepFixedWingAerodynamic(state: next, control: control, context: context, dt: dt)
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

    private func stepFixedWingAerodynamic(
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

        // `profile.dimensions` can be a *visual scene-scale override*
        // (`RuntimeTuning.runtimeSceneDimensionsOverride`, used by e.g.
        // MQ-9B/Hermes 900 because their 3D model assets are authored at a
        // different scale) — it is NOT a reliable physical size. Real
        // aerodynamics must come from the catalog's actual wingspan first;
        // fall back to a family-typical fuselage/height-to-span ratio for
        // whatever the catalog entry doesn't specify, and only fall all the
        // way back to `profile.dimensions` for aircraft with no catalog
        // entry at all (custom/abstract profiles, which never carry a scene
        // override). Getting this wrong silently undersizes wing area (and
        // therefore thrust, sized off drag-at-cruise) by an order of
        // magnitude — the aircraft "barely moves" despite 100% throttle.
        let catalogDimensions = context.activeUAVProfile?.dimensions
        let realWingSpanMm = catalogDimensions?.wingspanMillimeters ?? profile.dimensionsUnfoldedMm.x
        let realFuselageLengthMm = catalogDimensions?.fuselageLengthMillimeters ?? (realWingSpanMm * 0.55)
        let realHeightMm = catalogDimensions?.heightMillimeters ?? (realWingSpanMm * 0.12)

        let aero = FixedWingAerodynamics.build(
            family: wing.family,
            massKg: payloadMassModel.resolvedCurrentTotalMass,
            wingSpanM: realWingSpanMm / 1000.0,
            fuselageLengthM: realFuselageLengthMm / 1000.0,
            heightM: realHeightMm / 1000.0,
            turnAuthority: wing.turnAuthority,
            minSustainableSpeedMps: wing.minSustainableSpeedMps
        )

        // --- Control surface mapping: stick/angle commands -> elevator/aileron/rudder deflection fractions.
        var elevatorFraction: Float = 0.0
        var aileronFraction: Float = 0.0
        var rudderFraction: Float = 0.0

        if !crashOrDisarmed {
            let currentEuler = eulerFromFixedWingQuaternion(state.fixedWingOrientationQuat)
            if control.controlMode.isRateMode {
                elevatorFraction = control.targetOrientation.y.clamped(to: -1.0...1.0)
                aileronFraction = control.targetOrientation.x.clamped(to: -1.0...1.0)
                rudderFraction = desiredFixedWingRudderFraction(
                    control: control,
                    currentYaw: currentEuler.z,
                    yawRate: state.bodyAngularVelocity.z,
                    authority: authority,
                    wing: wing,
                    fallbackHeading: wrap(control.targetOrientation.z)
                )
            } else {
                let maxBank = Float(wing.maxBankAngleDeg).degreesToRadians
                let maxPitchAngle = (control.controlMode == .hoverAssist ? Float(16.0) : Float(26.0)).degreesToRadians
                let targetRoll = control.targetOrientation.x.clamped(to: -maxBank...maxBank)
                let targetPitch = control.targetOrientation.y.clamped(to: -maxPitchAngle...maxPitchAngle)
                let rollError = wrap(targetRoll - currentEuler.x)
                let pitchError = wrap(targetPitch - currentEuler.y)
                // Outer attitude-error loop: a normalized PD controller (error
                // against this airframe's own angle envelope, rate term for
                // damping) — NOT a raw angle-times-gain-divided-by-3 formula,
                // which previously came out roughly 5-6x too weak (a 10°
                // pitch command on FT5 only ever achieved ~3-4° actual pitch,
                // since even the *maximum* representable error produced just
                // ~0.2 of full elevator). Normalizing by maxBank/maxPitchAngle
                // means every airframe reaches meaningful authority well
                // inside its own commandable range, regardless of whether
                // that range is 16° or 40°.
                let rollErrorNorm = (rollError / maxBank).clamped(to: -1.0...1.0)
                let rollRateNorm = (state.bodyAngularVelocity.x / 1.8).clamped(to: -1.0...1.0)
                let pitchErrorNorm = (pitchError / maxPitchAngle).clamped(to: -1.0...1.0)
                let pitchRateNorm = (state.bodyAngularVelocity.y / 1.2).clamped(to: -1.0...1.0)
                // kP=3.5 (not 2.0): a pure P term always has some steady-state
                // droop against the airframe's own natural restoring
                // stiffness (cmAlpha) — e.g. Hermes 900 commanded to 8.5°
                // only settled near 4.6° at kP=2.0. 3.5 pushes the
                // equilibrium close enough to the commanded angle across the
                // whole fleet (1.6kg-5670kg) without re-introducing the
                // original bug's instability, since the rate term still damps
                // the approach.
                aileronFraction = ((rollErrorNorm * 3.5 - rollRateNorm * 0.4) * authority * max(0.75, wing.bankResponseGain)).clamped(to: -1.0...1.0)
                elevatorFraction = ((pitchErrorNorm * 3.5 - pitchRateNorm * 0.4) * authority * max(0.75, wing.climbResponseGain)).clamped(to: -1.0...1.0)
                rudderFraction = desiredFixedWingRudderFraction(
                    control: control,
                    currentYaw: currentEuler.z,
                    yawRate: state.bodyAngularVelocity.z,
                    authority: authority,
                    wing: wing,
                    fallbackHeading: wrap(control.targetOrientation.z)
                )
            }
        }

        // --- Actuator slew-rate limiting: a real servo can't snap to a new
        // deflection in one tick — applies to manual and autopilot input
        // alike, since it's a property of the actuator, not of who issued
        // the command. ~4/s means a full -1...1 swing takes ~0.5s, roughly
        // a 90°/s small-UAV servo for a ±20-25° surface.
        let surfaceSlewRate: Float = 4.0
        elevatorFraction = approach(current: state.elevatorDeflection, target: elevatorFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)
        aileronFraction = approach(current: state.aileronDeflection, target: aileronFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)
        rudderFraction = approach(current: state.rudderDeflection, target: rudderFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)
        next.elevatorDeflection = elevatorFraction
        next.aileronDeflection = aileronFraction
        next.rudderDeflection = rudderFraction

        // --- Aerodynamics: real angle-of-attack/sideslip-driven forces and moments.
        let effectiveWind = effectiveWindWithGusts(
            baseWind: context.windVector,
            altitudeM: state.position.y,
            turbulenceFactor: context.weather.effectiveFactors.turbulenceFactor,
            dt: dt,
            referenceAirspeed: max(simd_length(state.velocity), 1.0)
        )
        let bodyAirflow = simd_act(state.fixedWingOrientationQuat.conjugate, state.velocity - effectiveWind)
        let airspeed = max(simd_length(bodyAirflow), 0.5)
        let alpha = atan2(-bodyAirflow.y, -bodyAirflow.z).clamped(to: -1.4...1.4)
        let beta = asin((bodyAirflow.x / airspeed).clamped(to: -1.0...1.0))

        let airDensity: Float = 1.225
        let dynamicPressure = 0.5 * airDensity * airspeed * airspeed

        let (cl, cd) = aero.liftDrag(alphaRad: alpha)
        let cy = aero.cyBeta * beta

        let normalizedWindDir = simd_length(bodyAirflow) > 0.0001 ? simd_normalize(bodyAirflow) : SIMD3<Float>(0, 0, -1)
        let bodyUp = SIMD3<Float>(0, 1, 0)
        let bodyRight = SIMD3<Float>(1, 0, 0)
        let liftDirRaw = bodyUp - normalizedWindDir * simd_dot(bodyUp, normalizedWindDir)
        let liftDir = simd_length(liftDirRaw) > 0.0001 ? simd_normalize(liftDirRaw) : SIMD3<Float>(0, 1, 0)
        let sideDirRaw = bodyRight - normalizedWindDir * simd_dot(bodyRight, normalizedWindDir)
        let sideDir = simd_length(sideDirRaw) > 0.0001 ? simd_normalize(sideDirRaw) : SIMD3<Float>(1, 0, 0)

        let liftForce = liftDir * (cl * dynamicPressure * aero.wingArea)
        let dragForce = -normalizedWindDir * (cd * dynamicPressure * aero.wingArea)
        let sideForce = sideDir * (cy * dynamicPressure * aero.wingArea)
        let aeroForceBody = liftForce + dragForce + sideForce

        // bodyAngularVelocity convention matches orientation/.x=roll,.y=pitch,.z=yaw (see DroneState).
        let rollRate = state.bodyAngularVelocity.x
        let pitchRate = state.bodyAngularVelocity.y
        let yawRate = state.bodyAngularVelocity.z
        let pHat = rollRate * aero.wingSpan / (2.0 * airspeed)
        let qHat = pitchRate * aero.meanChord / (2.0 * airspeed)
        let rHat = yawRate * aero.wingSpan / (2.0 * airspeed)

        let cmPitch = aero.pitchMoment(alphaRad: alpha, elevatorFraction: elevatorFraction, qHat: qHat)
        let clRoll = aero.rollMoment(alphaRad: alpha, betaRad: beta, aileronFraction: aileronFraction, pHat: pHat)
        let cnYaw = aero.yawMoment(alphaRad: alpha, betaRad: beta, rudderFraction: rudderFraction, rHat: rHat)

        var momentBody = SIMD3<Float>(
            clRoll * dynamicPressure * aero.wingArea * aero.wingSpan,
            cmPitch * dynamicPressure * aero.wingArea * aero.meanChord,
            cnYaw * dynamicPressure * aero.wingArea * aero.wingSpan
        )

        // --- Thrust: sized so motorThrottle == baseline.cruiseReferenceThrottle balances drag at cruise.
        let (_, cdTrim) = aero.liftDrag(alphaRad: 0.0)
        let cruiseSpeed = max(wing.cruiseSpeedMps, wing.minSustainableSpeedMps, 1.0)
        let dragAtCruise = 0.5 * airDensity * cruiseSpeed * cruiseSpeed * aero.wingArea * cdTrim
        let referenceThrottle = max(0.2, baseline.cruiseReferenceThrottle)
        let maxThrust = max(0.5, dragAtCruise / referenceThrottle) * batteryFactor
        let thrustMagnitude = (crashOrDisarmed ? 0.0 : motorThrottle) * maxThrust
        let thrustForceBody = SIMD3<Float>(0, 0, -1) * thrustMagnitude

        // --- Propulsion-airframe coupling: prop wash on the tail, torque
        // reaction, P-factor, gyroscopic precession. None of this existed
        // before — thrust only ever pushed the aircraft forward.
        if !crashOrDisarmed {
            // Prop wash gives the elevator/rudder extra authority beyond
            // what freestream airspeed alone would provide (e.g. holding the
            // nose up during a slow takeoff roll) — added as the *delta*
            // over the freestream-based moment already computed above, so
            // the natural alpha/rate stability terms stay tied to freestream
            // dynamic pressure and only the control-deflection terms see the
            // boost.
            let tailQ = aero.tailDynamicPressure(airspeed: airspeed, thrust: thrustMagnitude, airDensity: airDensity)
            let extraQ = max(0.0, tailQ - dynamicPressure)
            momentBody.y += aero.cmDeltaE * elevatorFraction * extraQ * aero.wingArea * aero.meanChord
            momentBody.z += aero.cnDeltaR * rudderFraction * extraQ * aero.wingArea * aero.wingSpan

            // Torque reaction: the airframe rolls opposite to the prop spin.
            momentBody.x += -aero.propSpinSign * thrustMagnitude * aero.propRadius * aero.torqueThrustRatio

            // P-factor: asymmetric blade loading at high AoA/low speed yaws
            // the nose, growing with both thrust and AoA.
            momentBody.z += aero.propSpinSign * sin(alpha) * thrustMagnitude * aero.propRadius * aero.pFactorGain

            // Gyroscopic precession of the spinning prop disk against body
            // rotation. Remapped from this codebase's (roll,pitch,yaw)
            // labeling (roll about Z, pitch about X, yaw about Y) into
            // standard (X,Y,Z) for the cross product, then back.
            let propOmega = 50.0 + motorThrottle * 650.0
            let propSpinVectorXYZ = SIMD3<Float>(0, 0, -aero.propSpinSign * propOmega)
            let bodyRateXYZ = SIMD3<Float>(pitchRate, yawRate, rollRate)
            let gyroMomentXYZ = aero.propInertia * simd_cross(propSpinVectorXYZ, bodyRateXYZ)
            momentBody += SIMD3<Float>(gyroMomentXYZ.z, gyroMomentXYZ.x, gyroMomentXYZ.y)
        }

        // --- Integration: semi-implicit Euler (unconditionally stable for damped oscillatory systems).
        let mass = max(0.1, payloadMassModel.resolvedCurrentTotalMass)
        let totalForceWorld = simd_act(state.fixedWingOrientationQuat, aeroForceBody + thrustForceBody)
            + SIMD3<Float>(0, -mass * Tuning.gravity, 0)
        let acceleration = totalForceWorld / mass

        next.velocity = state.velocity + acceleration * dt
        next.position = state.position + next.velocity * dt

        let angularAccel = momentBody / aero.inertiaTensor
        next.bodyAngularVelocity = clampMagnitude(state.bodyAngularVelocity + angularAccel * dt, limit: 10.0)
        next.fixedWingOrientationQuat = integrateFixedWingOrientation(
            state.fixedWingOrientationQuat,
            rollRate: next.bodyAngularVelocity.x,
            pitchRate: next.bodyAngularVelocity.y,
            yawRate: next.bodyAngularVelocity.z,
            dt: dt
        )
        next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat)
        next.angularVelocity = next.bodyAngularVelocity
        next.angleOfAttack = alpha
        next.sideslipAngle = beta

        // --- Ground handling.
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
            next.bodyAngularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * 12.0))
            if state.physicalState != .crashed {
                // Level roll/pitch toward the ground while preserving current heading.
                let headingOnlyQuat = simd_quatf(angle: next.orientation.z, axis: SIMD3<Float>(0, 1, 0))
                let levelBlend = min(1.0, dt * 4.0)
                let blendedVector = next.fixedWingOrientationQuat.vector * (1.0 - levelBlend) + headingOnlyQuat.vector * levelBlend
                next.fixedWingOrientationQuat = simd_quatf(vector: simd_normalize(blendedVector))
                next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat)
            }
            next.angularVelocity = next.bodyAngularVelocity
        }

        next.throttle = crashOrDisarmed ? 0.0 : motorThrottle
        next.motorThrottle = next.throttle
        next.rotorAngularSpeed = SIMD4<Float>(crashOrDisarmed ? 0.0 : (60.0 + motorThrottle * 540.0), 0.0, 0.0, 0.0)
        next.forwardAirspeed = airspeed

        return next
    }

    /// Extracts display/telemetry Euler angles (roll, pitch, yaw) from the
    /// authoritative fixed-wing orientation quaternion. Derived directly from
    /// the body forward/up basis vectors rather than a generic textbook
    /// formula, so it matches this codebase's specific composition order
    /// (`yaw * pitch * roll`, roll about Z) and its existing yaw convention
    /// (`atan2(-dx, -dz)`, also used by `FixedWingAutopilotInput`). Gimbal-locks
    /// at pitch = ±90° like any Euler representation — display-only, never fed
    /// back into the physics integration.
    private func eulerFromFixedWingQuaternion(_ q: simd_quatf) -> SIMD3<Float> {
        let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
        let pitch = asin(forward.y.clamped(to: -1.0...1.0))
        let yaw = atan2(-forward.x, -forward.z)

        let upWorld = simd_act(q, SIMD3<Float>(0, 1, 0))
        let invYaw = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
        let invPitch = simd_quatf(angle: -pitch, axis: SIMD3<Float>(1, 0, 0))
        let unrolled = simd_act(invPitch, simd_act(invYaw, upWorld))
        let roll = atan2(-unrolled.x, unrolled.y)

        return SIMD3<Float>(roll, pitch, yaw)
    }

    /// Integrates the fixed-wing attitude quaternion from true body-frame
    /// rates via q̇ = 0.5 * q ⊗ ω, normalizing every step. `rollRate`/
    /// `pitchRate`/`yawRate` follow this codebase's roll-about-Z/pitch-about-X/
    /// yaw-about-Y axis labeling, remapped here into the quaternion's
    /// (x, y, z) imaginary axes.
    private func integrateFixedWingOrientation(
        _ q: simd_quatf,
        rollRate: Float,
        pitchRate: Float,
        yawRate: Float,
        dt: Float
    ) -> simd_quatf {
        let omega = simd_quatf(ix: pitchRate, iy: yawRate, iz: rollRate, r: 0)
        let qDotVector = (q * omega).vector * 0.5
        let qNextVector = q.vector + qDotVector * dt
        let length = simd_length(qNextVector)
        guard length.isFinite, length > 1e-6 else {
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatf(vector: qNextVector / length)
    }

    /// Manual yaw stick (if present) else a light heading-hold correction,
    /// returned as a rudder deflection fraction in -1...1.
    private func desiredFixedWingRudderFraction(
        control: DroneControlInput,
        currentYaw: Float,
        yawRate: Float,
        authority: Float,
        wing: FixedWingParameters,
        fallbackHeading: Float
    ) -> Float {
        // Yaw-rate damper (active in every mode): opposes yaw rate to suppress
        // the lightly-damped Dutch-roll wallow that the real 6DOF model now
        // simulates. Sign matches the aero cnr damper (cnDeltaR > 0, so rudder
        // ∝ -yawRate produces a damping yaw moment). 0.18 is a light hand —
        // enough to settle the side-to-side weave without making yaw sluggish.
        let yawDamper = (-yawRate * 0.18).clamped(to: -0.5...0.5)
        let manualIntent = control.yawIntent.clamped(to: -1.6...1.6)
        if abs(manualIntent) > 0.001 {
            return (manualIntent * 0.6 * authority + yawDamper).clamped(to: -1.0...1.0)
        }
        // Heading-error rudder gain was 0.8 — far too high. The rudder isn't
        // the primary heading actuator (bank is); a large heading-error rudder
        // term lags the wobble and pumps energy *into* the Dutch roll instead
        // of holding course. Cut to 0.25 and let the yaw damper do the work.
        let headingError = wrap(fallbackHeading - currentYaw)
        return (headingError * 0.25 * wing.bankResponseGain + yawDamper).clamped(to: -1.0...1.0)
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

    /// Adds a near-ground turbulence gust (Dryden low-altitude model,
    /// MIL-F-8785C) on top of the steady wind — strongest at the surface,
    /// fading to none by ~1000 ft. Driven by the existing steady wind speed
    /// (real mechanical/boundary-layer turbulence needs wind to exist),
    /// then *compounded* — not gated — by the weather preset's
    /// turbulenceFactor, so calm conditions with some ambient wind still get
    /// a believable bump on takeoff/landing and storms get more, rather
    /// than calm weather (turbulenceFactor 0) zeroing it outright.
    private func effectiveWindWithGusts(
        baseWind: SIMD3<Float>,
        altitudeM: Float,
        turbulenceFactor: Float,
        dt: Float,
        referenceAirspeed: Float
    ) -> SIMD3<Float> {
        let altitudeFt = max(altitudeM, 0.0) * 3.28084
        let fadeOut = (1.0 - altitudeFt / 1000.0).clamped(to: 0.0...1.0)
        guard fadeOut > 0.0 else {
            windGustState = .zero
            return baseWind
        }

        // MIL-F-8785C low-altitude form is defined in feet; convert the
        // resulting scale lengths back to meters for the sim's own units.
        let referenceWindSpeed = max(simd_length(baseWind), 0.5)
        let altitudeFtFloored = max(altitudeFt, 3.0)
        let shapingTerm = (0.177 + 0.000823 * altitudeFtFloored)
        let sigmaW = 0.1 * referenceWindSpeed
        let sigmaUV = sigmaW / max(0.05, pow(shapingTerm, 0.4))
        let scaleLengthWM = altitudeFtFloored * 0.3048
        let scaleLengthUVM = (altitudeFtFloored / max(0.05, pow(shapingTerm, 1.2))) * 0.3048

        let v = max(referenceAirspeed, 1.0)
        let intensityBoost = 0.6 + 0.4 * turbulenceFactor.clamped(to: 0.0...1.0)

        windGustState = SIMD3<Float>(
            ouGustStep(current: windGustState.x, sigma: sigmaUV, scaleLength: scaleLengthUVM, airspeed: v, dt: dt),
            ouGustStep(current: windGustState.y, sigma: sigmaW, scaleLength: scaleLengthWM, airspeed: v, dt: dt),
            ouGustStep(current: windGustState.z, sigma: sigmaUV, scaleLength: scaleLengthUVM, airspeed: v, dt: dt)
        )

        return baseWind + windGustState * (fadeOut * intensityBoost)
    }

    /// One step of the discrete-time Ornstein-Uhlenbeck process — the exact
    /// solution of the Dryden shaping filter's simplest (first-order) form,
    /// so no continuous transfer-function/ARMA implementation is needed.
    private func ouGustStep(current: Float, sigma: Float, scaleLength: Float, airspeed: Float, dt: Float) -> Float {
        let decay = exp(-airspeed * dt / max(0.1, scaleLength))
        let noise = sigma * sqrt(max(0.0, 1.0 - decay * decay)) * gaussianRandomSample()
        return current * decay + noise
    }

    private func gaussianRandomSample() -> Float {
        let u1 = max(1e-6, Float.random(in: 0.0...1.0))
        let u2 = Float.random(in: 0.0...1.0)
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
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
