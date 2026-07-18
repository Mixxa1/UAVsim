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
            if next.physicalState == .crashed {
                // A crashed airframe stops being an aircraft but keeps being a
                // physical body: ballistic tumble with per-contact-sphere
                // ground collisions instead of the old "pin flat to the
                // ground" damping.
                next = stepUncontrolledBody(state: next, context: context, dt: dt)
                remaining -= dt
                continue
            }
            switch context.profile.airframeClass {
            case .multirotor:
                next = stepMultirotorBaseline(state: next, control: control, context: context, dt: dt)
            case .fixedWing:
                let previousSubstep = next
                next = stepFixedWingAerodynamic(state: next, control: control, context: context, dt: dt)
                if let launchDynamics = context.fixedWingLaunchDynamics {
                    next = applyFixedWingLaunchDynamics(
                        previousState: previousSubstep,
                        integratedState: next,
                        dynamics: launchDynamics,
                        context: context,
                        dt: dt
                    )
                }
            case .hybridVTOL:
                if context.profile.airframeStyle == .tailsitterVTOL {
                    next = stepTailsitterVTOLTransitional(state: next, control: control, context: context, dt: dt)
                } else {
                    next = stepHybridVTOLTransitional(state: next, control: control, context: context, dt: dt)
                }
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
        let thrustMagnitude = rotorBorneThrustMagnitude(
            motorThrottle: motorThrottle,
            baseline: baseline,
            authority: authority,
            mass: mass,
            batteryFactor: batteryFactor,
            liftPenalty: liftPenalty
        )
        let thrustWorld = simd_act(q, SIMD3<Float>(0.0, thrustMagnitude, 0.0))

        let gravityForce = SIMD3<Float>(0.0, -mass * Tuning.gravity, 0.0)
        let horizontalMax = profile.maxHorizontalSpeedMps.clamped(to: 3.0...42.0)
        let horizontalDragDamping = multirotorHorizontalDragDamping(
            profile: profile,
            controlMode: control.controlMode,
            weather: weather
        )
        let verticalDragDamping = (1.45 + weather.dragMultiplier * 0.45).clamped(to: 1.20...2.40)
        let linearDrag = SIMD3<Float>(
            -state.velocity.x * mass * horizontalDragDamping,
            -state.velocity.y * mass * verticalDragDamping,
            -state.velocity.z * mass * horizontalDragDamping
        )
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

        let verticalUpMax = profile.maxAscentSpeedMps.clamped(to: 1.0...20.0)
        let verticalDownMax = profile.maxDescentSpeedMps.clamped(to: 1.0...20.0)

        let horizontalVelocity = SIMD2<Float>(next.velocity.x, next.velocity.z)
        let horizontalSpeed = simd_length(horizontalVelocity)
        if horizontalSpeed > horizontalMax {
            let scale = horizontalMax / horizontalSpeed
            next.velocity.x *= scale
            next.velocity.z *= scale
        }
        next.velocity.y = next.velocity.y.clamped(to: -verticalDownMax...verticalUpMax)

        next.position = state.position + next.velocity * dt
        let groundClearance = contactGroundClearance(context: context, orientation: q)
        if next.position.y < groundClearance {
            next.position.y = groundClearance
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        let groundRestState = next.position.y <= groundClearance + 0.03 && state.physicalState.isGroundRestState
        if groundRestState {
            next.position.y = groundClearance
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

    /// Total rotor-borne vertical thrust magnitude, sized so 100% throttle
    /// supports (`effectiveStabilizationThrust` + maneuver margin) times the
    /// aircraft's own weight. Shared by `stepMultirotorBaseline` (a single
    /// virtual rotor) and `stepHybridVTOLTransitional` (split across however
    /// many lift-capable propulsion units the airframe has).
    private func rotorBorneThrustMagnitude(
        motorThrottle: Float,
        baseline: ResolvedFlightBaseline,
        authority: Float,
        mass: Float,
        batteryFactor: Float,
        liftPenalty: Float
    ) -> Float {
        let maxThrust = mass * Tuning.gravity * (baseline.effectiveStabilizationThrust + authority * 0.35) * batteryFactor * liftPenalty
        return motorThrottle * maxThrust
    }

    private func multirotorHorizontalDragDamping(
        profile: DroneModelProfile,
        controlMode: FlightControlMode,
        weather: WeatherFactors
    ) -> Float {
        let profileMaxSpeed = profile.maxHorizontalSpeedMps.clamped(to: 3.0...42.0)
        let referenceTiltDegrees: Float
        switch controlMode {
        case .hoverAssist:
            referenceTiltDegrees = 22.0
        case .stabilized:
            referenceTiltDegrees = 36.0
        case .acro:
            referenceTiltDegrees = 48.0
        }

        let referenceAcceleration = Tuning.gravity * tan(referenceTiltDegrees.degreesToRadians)
        let weatherDragPenalty = (weather.dragMultiplier - 1.0).clamped(to: 0.0...0.65)
        return ((referenceAcceleration / profileMaxSpeed) * (1.0 + weatherDragPenalty * 0.55)).clamped(to: 0.18...2.80)
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
            let currentEuler = eulerFromFixedWingQuaternion(state.fixedWingOrientationQuat, fallback: state.orientation)
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
                // Rate (damping) terms clamp at ±3, not ±1: an ultralight
                // airframe (1-2 kg hand-launch wing) reaches several rad/s of
                // roll with full aileron, and with a ±1 clamp the damping
                // term saturated at 0.4 against a P term of up to 3.5 — the
                // aircraft blew straight through its commanded bank into a
                // near-knife-edge overshoot. Heavier airframes never exceed
                // the old clamp, so their behaviour is unchanged.
                let rollRateNorm = (state.bodyAngularVelocity.x / 1.8).clamped(to: -3.0...3.0)
                let pitchErrorNorm = (pitchError / maxPitchAngle).clamped(to: -1.0...1.0)
                let pitchRateNorm = (state.bodyAngularVelocity.y / 1.2).clamped(to: -3.0...3.0)
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
                    fallbackHeading: wrap(control.targetOrientation.z),
                    coordinationBankRad: currentEuler.x
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
        next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat, fallback: state.orientation)
        next.angularVelocity = next.bodyAngularVelocity
        next.angleOfAttack = alpha
        next.sideslipAngle = beta

        // --- Ground handling.
        let groundClearance = contactGroundClearance(context: context, orientation: next.fixedWingOrientationQuat)
        if next.position.y < groundClearance {
            next.position.y = groundClearance
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        let groundRestState = next.position.y <= groundClearance + 0.03 && state.physicalState.isGroundRestState && motorThrottle < 0.18
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
                next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat, fallback: next.orientation)
            }
            next.angularVelocity = next.bodyAngularVelocity
        }

        next.throttle = crashOrDisarmed ? 0.0 : motorThrottle
        next.motorThrottle = next.throttle
        next.rotorAngularSpeed = SIMD4<Float>(crashOrDisarmed ? 0.0 : (60.0 + motorThrottle * 540.0), 0.0, 0.0, 0.0)
        next.forwardAirspeed = airspeed

        return next
    }

    private func applyFixedWingLaunchDynamics(
        previousState: DroneState,
        integratedState: DroneState,
        dynamics: FixedWingLaunchDynamics,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = integratedState
        let directionLength = simd_length(dynamics.direction)
        guard directionLength.isFinite, directionLength > 0.5 else {
            return next
        }
        let direction = dynamics.direction / directionLength

        func constrainAttitudeAndRates(_ state: inout DroneState, pitchBias: Float = 0.0) {
            let launchEuler = SIMD3<Float>(
                0.0,
                dynamics.pitchRadians + pitchBias,
                dynamics.worldYawRadians
            )
            state.orientation = launchEuler
            state.fixedWingOrientationQuat = orientationQuaternion(from: launchEuler)
            state.angularVelocity = .zero
            state.bodyAngularVelocity = .zero
            state.angleOfAttack = pitchBias
            state.sideslipAngle = 0.0
        }

        switch dynamics.phase {
        case .held:
            next.position = dynamics.origin
            next.velocity = .zero
            next.forwardAirspeed = simd_length(context.windVector)
            constrainAttitudeAndRates(&next)

        case .catapultRail:
            let travelLength = max(0.5, dynamics.travelLengthMeters)
            let priorOffset = previousState.position - dynamics.origin
            let priorDistance = simd_dot(priorOffset, direction).clamped(to: 0.0...travelLength)
            let priorSpeed = max(0.0, simd_dot(previousState.velocity, direction))
            let targetSpeed = max(0.1, dynamics.targetReleaseSpeedMps)
            let requiredAcceleration = (targetSpeed * targetSpeed) / (2.0 * travelLength)
            let actualMass = max(0.2, context.vehicleMassModel.resolvedCurrentTotalMass)
            let forceLimitedAcceleration = dynamics.maximumAccelerationMps2 *
                max(0.2, dynamics.nominalLaunchMassKg) / actualMass
            let acceleration = min(
                max(0.1, forceLimitedAcceleration),
                max(0.1, requiredAcceleration)
            )
            let nextSpeed = min(targetSpeed, priorSpeed + acceleration * dt)
            let averageSpeed = (priorSpeed + nextSpeed) * 0.5
            let nextDistance = min(travelLength, priorDistance + averageSpeed * dt)

            next.position = dynamics.origin + direction * nextDistance
            // Never manufacture the configured exit speed at the rail end.
            // If installed mass makes the launcher force insufficient, the
            // aircraft leaves with the speed it actually accumulated.
            next.velocity = direction * nextSpeed
            next.forwardAirspeed = simd_length(next.velocity - context.windVector)
            constrainAttitudeAndRates(&next)

        case .handRelease:
            let actualMass = max(0.2, context.vehicleMassModel.resolvedCurrentTotalMass)
            let throwMassScale = sqrt(max(0.2, dynamics.nominalLaunchMassKg) / actualMass)
                .clamped(to: 0.65...1.15)
            let massAdjustedThrowSpeed = dynamics.targetReleaseSpeedMps * throwMassScale
            let relativeVelocity = previousState.velocity - context.windVector
            let longitudinalAirspeed = simd_dot(relativeVelocity, direction)
            let distanceFromRelease = simd_distance(previousState.position, dynamics.origin)
            if longitudinalAirspeed < massAdjustedThrowSpeed * 0.55,
               distanceFromRelease < 0.12 {
                next.position = dynamics.origin + direction * 0.015
                // The throw is a ground-relative impulse. Wind remains in the
                // normal airflow calculation and can help or hurt the launch.
                next.velocity = direction * massAdjustedThrowSpeed
                next.forwardAirspeed = simd_length(next.velocity - context.windVector)
                // A thrower releases nose-high: the wing leaves the hand at a
                // working angle of attack. Releasing with the nose exactly on
                // the velocity vector (AoA 0) produced near-zero lift for the
                // first second and the airframe sank from hand height to the
                // ground before alpha could build.
                constrainAttitudeAndRates(
                    &next,
                    pitchBias: FixedWingHandLaunchTuning.releaseAngleOfAttackDegrees * .pi / 180.0
                )
            }
        }

        return next
    }

    /// hybridVTOL: a genuine transition-capable integrator, not a throttle-
    /// floor tweak bolted onto the fixed-wing model. Each `PropulsionUnit`'s
    /// own `thrustDirectionBody` sweeps from vertical (hover) to forward
    /// (cruise) as its tilt servo moves, so propulsive force is one unified
    /// per-unit sum rather than separate hover/cruise force terms.
    ///
    /// The hover<->cruise handover is governed by `vtolWingborneBlend` — the
    /// physically computed fraction of the weight the wing actually carries
    /// (wingLift/weight, smoothed) — NOT by tilt geometry or a timer. Tilt
    /// angle only steers the thrust vector; whether the rotors may shed load
    /// (thrust budget, attitude authority, throttle floor, vertical caps)
    /// follows real lift. A safety controller additionally gates the tilt
    /// servo: it may only advance toward cruise while wing lift plus the
    /// rotors' remaining vertical capacity cover the weight with margin, and
    /// it rolls back toward hover on stall or excessive sink regardless of
    /// the pilot's lever.
    /// Pure output of the aero/transition-servo math shared by every VTOL
    /// stepper (tilt-rotor Wingcopter/Trinity AND tailsitter Wingtra) —
    /// everything through "how much does the wing carry, and is the
    /// transition allowed to advance" is identical regardless of *how* the
    /// airframe converts that into thrust direction (per-unit tilt angle vs
    /// whole-body pitch). See `computeVTOLAeroTransitionStep`.
    private struct VTOLAeroTransitionStep {
        let profile: DroneModelProfile
        let wing: FixedWingParameters
        let aero: FixedWingAerodynamics
        let baseline: ResolvedFlightBaseline
        let authority: Float
        let batteryFactor: Float
        let mass: Float
        let liftPenalty: Float
        let crashOrDisarmed: Bool

        let alpha: Float
        let beta: Float
        let airspeed: Float
        let aeroForceBody: SIMD3<Float>
        let aeroMomentBody: SIMD3<Float>

        let elevatorFraction: Float
        let aileronFraction: Float
        let rudderFraction: Float

        let wingLiftRatio: Float
        let wingborneBlend: Float

        let units: [PropulsionUnit]
        let vtolTransitionProgress: Float
        let vtolTransitionBlocked: Bool
        let leverForward: Bool

        let motorThrottle: Float
        let ratedDescent: Float
    }

    /// Sections 1-6 of the original stepHybridVTOLTransitional: airframe
    /// aero model, control-surface mapping, angle-of-attack/aero force+
    /// moment, wingLiftRatio/wingborneBlend, the tilt-servo-or-synthetic-
    /// progress safety gate, and the throttle floor blend. None of this
    /// depends on *how* thrust direction is produced, so both the tilt-rotor
    /// and tailsitter steppers call it verbatim.
    private func computeVTOLAeroTransitionStep(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        dt: Float
    ) -> VTOLAeroTransitionStep {
        let profile = context.profile
        let wing = profile.fixedWingParameters ?? FixedWingParameters(
            family: .surveyEVTOL,
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
            maxBankAngleDeg: 36.0
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
        let mass = max(0.20, payloadMassModel.resolvedCurrentTotalMass)
        let liftPenalty = baseline.liftPenaltyMultiplier.clamped(to: 0.78...1.02)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed

        // --- 1. Aerodynamic model: real airframe size from the catalog first
        // (see the identical note in stepFixedWingAerodynamic — getting this
        // wrong silently undersizes wing area/thrust by an order of magnitude).
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

        // --- 2. Control surfaces: identical stick/angle -> elevator/aileron/
        // rudder mapping as stepFixedWingAerodynamic (reused verbatim so the
        // pilot's roll/pitch commands mean the same thing in both phases).
        var elevatorFraction: Float = 0.0
        var aileronFraction: Float = 0.0
        var rudderFraction: Float = 0.0

        if !crashOrDisarmed {
            let currentEuler = eulerFromFixedWingQuaternion(state.fixedWingOrientationQuat, fallback: state.orientation)
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
                let rollErrorNorm = (rollError / maxBank).clamped(to: -1.0...1.0)
                // Rate (damping) terms clamp at ±3, not ±1: an ultralight
                // airframe (1-2 kg hand-launch wing) reaches several rad/s of
                // roll with full aileron, and with a ±1 clamp the damping
                // term saturated at 0.4 against a P term of up to 3.5 — the
                // aircraft blew straight through its commanded bank into a
                // near-knife-edge overshoot. Heavier airframes never exceed
                // the old clamp, so their behaviour is unchanged.
                let rollRateNorm = (state.bodyAngularVelocity.x / 1.8).clamped(to: -3.0...3.0)
                let pitchErrorNorm = (pitchError / maxPitchAngle).clamped(to: -1.0...1.0)
                let pitchRateNorm = (state.bodyAngularVelocity.y / 1.2).clamped(to: -3.0...3.0)
                aileronFraction = ((rollErrorNorm * 3.5 - rollRateNorm * 0.4) * authority * max(0.75, wing.bankResponseGain)).clamped(to: -1.0...1.0)
                elevatorFraction = ((pitchErrorNorm * 3.5 - pitchRateNorm * 0.4) * authority * max(0.75, wing.climbResponseGain)).clamped(to: -1.0...1.0)
                rudderFraction = desiredFixedWingRudderFraction(
                    control: control,
                    currentYaw: currentEuler.z,
                    yawRate: state.bodyAngularVelocity.z,
                    authority: authority,
                    wing: wing,
                    fallbackHeading: wrap(control.targetOrientation.z),
                    coordinationBankRad: currentEuler.x
                )
            }
        }

        let surfaceSlewRate: Float = 4.0
        elevatorFraction = approach(current: state.elevatorDeflection, target: elevatorFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)
        aileronFraction = approach(current: state.aileronDeflection, target: aileronFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)
        rudderFraction = approach(current: state.rudderDeflection, target: rudderFraction, increaseRate: surfaceSlewRate, decreaseRate: surfaceSlewRate, dt: dt)

        // --- 3. Aerodynamics: identical angle-of-attack model as
        // stepFixedWingAerodynamic. No hover-gating needed — `airspeed` is
        // floored at 0.5 m/s, so dynamic pressure (and therefore lift/drag/
        // moment) is naturally ~900x smaller at hover than at cruise.
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

        let rollRate = state.bodyAngularVelocity.x
        let pitchRate = state.bodyAngularVelocity.y
        let yawRate = state.bodyAngularVelocity.z
        let pHat = rollRate * aero.wingSpan / (2.0 * airspeed)
        let qHat = pitchRate * aero.meanChord / (2.0 * airspeed)
        let rHat = yawRate * aero.wingSpan / (2.0 * airspeed)

        let cmPitch = aero.pitchMoment(alphaRad: alpha, elevatorFraction: elevatorFraction, qHat: qHat)
        let clRoll = aero.rollMoment(alphaRad: alpha, betaRad: beta, aileronFraction: aileronFraction, pHat: pHat)
        let cnYaw = aero.yawMoment(alphaRad: alpha, betaRad: beta, rudderFraction: rudderFraction, rHat: rHat)

        let aeroMomentBody = SIMD3<Float>(
            clRoll * dynamicPressure * aero.wingArea * aero.wingSpan,
            cmPitch * dynamicPressure * aero.wingArea * aero.meanChord,
            cnYaw * dynamicPressure * aero.wingArea * aero.wingSpan
        )
        // Propulsion-airframe coupling (torque reaction/P-factor/gyroscopic
        // precession) is intentionally omitted here — those formulas assume
        // one prop disk, not an arbitrary array of independently-tilting
        // units, and are a secondary realism layer rather than a
        // flyability requirement for this pass.

        // --- 4. Wing-borne blend: THE transition variable. Not tilt geometry
        // (which only says where the servos point) but the physically
        // computed fraction of the aircraft's weight the wing is carrying
        // right now — so airspeed, wind, mass, air density and stall all
        // directly govern the hover<->cruise handover, and a headwind
        // genuinely makes the transition complete earlier.
        let aeroForceWorld = simd_act(state.fixedWingOrientationQuat, aeroForceBody)
        let weight = mass * Tuning.gravity
        let wingLiftRatio = max(0.0, aeroForceWorld.y) / weight
        // Asymmetric smoothing: hand weight to the wing slowly (gust-proof),
        // re-engage the rotors fast when lift collapses (stall recovery).
        let wingborneBlend = approach(
            current: state.vtolWingborneBlend,
            target: wingLiftRatio.clamped(to: 0.0...1.0),
            increaseRate: 0.8,
            decreaseRate: 2.5,
            dt: dt
        )

        // --- 5. Tilt servos + transition safety controller. The lever is
        // pilot *intent*; the controller only lets tilt advance toward cruise
        // while wing lift plus the rotors' remaining vertical capacity still
        // cover the weight with margin — and rolls the tilt back toward
        // hover on stall or excessive sink, regardless of the lever
        // (safety wins over the command, same precedent as mission
        // constraint enforcement).
        var units = state.propulsionUnits
        let leverForward = control.vtolTransitionLever > 0.05
        let leverBack = control.vtolTransitionLever < -0.05
        var vtolTransitionBlocked = false

        // alpha is only meaningful against *forward* airflow — a pure
        // vertical hover climb reads as alpha ~ ±90° (the relative wind comes
        // from below, not from ahead) regardless of how fast it's climbing,
        // and that is not a stall, it's just a helicopter-mode climb with no
        // forward speed yet. Gating on total airspeed (as an earlier version
        // of this check did) made isStalled true throughout any ordinary
        // climb, permanently blocking the tilt gate below — the exact "X
        // does nothing" bug this fixes. Gate on the body-forward airflow
        // component specifically, since that's what a wing stall is about.
        let forwardAirspeedForStallCheck = max(0.0, -bodyAirflow.z)
        let stallRelevant = forwardAirspeedForStallCheck > max(4.0, wing.stallWarningSpeedMps * 0.5)
        let isStalled = stallRelevant && abs(alpha) > aero.stallAlphaRad
        let ratedDescent = profile.maxDescentSpeedMps.clamped(to: 1.0...20.0)
        let sinkingTooFast = state.velocity.y < -ratedDescent * 1.15
        let airborne = !state.physicalState.isGroundRestState && state.position.y > 0.5
        let emergencyRollback = airborne && state.vtolTransitionProgress > 0.05 && (isStalled || sinkingTooFast)

        // Advancing to tilt angle θ is safe while the wing's current lift
        // plus the rotors' maximum vertical capacity at θ still cover the
        // weight with a 5% reserve. Capped at 0.9 so the final degrees to
        // 90° can complete once the wing carries ~90% (cos 90° = 0 would
        // otherwise demand wingLiftRatio >= 1.05 — unreachable in level
        // flight).
        func tiltAdvanceIsSafe(toTiltRad nextTilt: Float) -> Bool {
            let requiredLiftRatio = min(0.9, 1.05 - baseline.effectiveStabilizationThrust * cos(nextTilt))
            // Below ~13.5°, thrust is still almost entirely vertical and
            // requiredLiftRatio is already deeply negative (always
            // satisfied) — the wing isn't expected to be carrying any
            // weight yet. Alpha reads large here on any climb with modest
            // forward speed (steep flight-path angle, not flow separation),
            // so gate the stall check off until the tilt has actually
            // reached an angle where the wing is meant to start
            // contributing. This avoids blocking the first few degrees of
            // every climbing transition attempt while still catching a
            // genuine stall once it matters.
            let stallGateArmed = nextTilt > (Float.pi / 2) * 0.15
            return wingLiftRatio >= requiredLiftRatio && !(stallGateArmed && isStalled) && !sinkingTooFast
        }

        let tiltRotorIndices = units.indices.filter { units[$0].role == .tiltRotor }
        for index in tiltRotorIndices {
            let unit = units[index]
            let commandedTarget: Float
            if emergencyRollback {
                commandedTarget = 0.0
            } else if leverForward {
                commandedTarget = .pi / 2
            } else if leverBack {
                commandedTarget = 0.0
            } else {
                commandedTarget = unit.targetTiltAngleRad
            }
            units[index].targetTiltAngleRad = commandedTarget

            guard !crashOrDisarmed else { continue }
            let candidate = approach(
                current: unit.tiltAngleRad,
                target: commandedTarget,
                increaseRate: unit.tiltRateLimitRadPerSec,
                decreaseRate: unit.tiltRateLimitRadPerSec,
                dt: dt
            )
            if candidate > unit.tiltAngleRad {
                if tiltAdvanceIsSafe(toTiltRad: candidate) {
                    units[index].tiltAngleRad = candidate
                } else {
                    vtolTransitionBlocked = true // hold at current tilt
                }
            } else {
                units[index].tiltAngleRad = candidate // toward hover: always allowed
            }
        }
        if emergencyRollback {
            vtolTransitionBlocked = true
        }

        let vtolTransitionProgress: Float
        if tiltRotorIndices.isEmpty {
            // No tilting hardware — synthetic lever-driven progress, gated
            // by the same safety condition. This is also exactly what a
            // tailsitter needs: 0 = nose-up/hover, 1 = level/cruise, with
            // "tilt angle" here standing in for "how far the effective
            // thrust direction has rotated from vertical."
            let target: Float = emergencyRollback ? 0.0 : (leverForward ? 1.0 : (leverBack ? 0.0 : state.vtolTransitionProgress))
            var candidate = crashOrDisarmed ? state.vtolTransitionProgress : approach(current: state.vtolTransitionProgress, target: target, increaseRate: 0.5, decreaseRate: 0.5, dt: dt)
            if candidate > state.vtolTransitionProgress, !tiltAdvanceIsSafe(toTiltRad: candidate * .pi / 2) {
                candidate = state.vtolTransitionProgress
                vtolTransitionBlocked = true
            }
            vtolTransitionProgress = candidate
        } else {
            let sum = tiltRotorIndices.reduce(Float(0)) { $0 + units[$1].tiltAngleRad }
            let meanTiltAngleRad = sum / Float(tiltRotorIndices.count)
            vtolTransitionProgress = (meanTiltAngleRad / (Float.pi / 2)).clamped(to: 0.0...1.0)
        }

        // --- 6. Throttle: continuous hover<->cruise floor blend, driven by
        // how much of the weight the wing actually carries.
        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.batteryState.isDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        } else {
            let hoverPhaseFloor: Float
            switch control.mode {
            case .takeoff:
                hoverPhaseFloor = baseline.takeoffThrottleReference
            case .hover:
                hoverPhaseFloor = profile.airframeStyle == .tailsitterVTOL
                    ? baseline.hoverLockThrottle
                    : baseline.takeoffThrottleReference
            case .landing:
                hoverPhaseFloor = baseline.landingThrottleReference
            case .manual, .autoPath, .returnHome, .emergencyStop:
                hoverPhaseFloor = baseline.hoverLockThrottle
            }
            let cruiseFloor = max(baseline.cruiseReferenceThrottle, baseline.effectiveMinimumSafeFlightThrottle)
            let allowGroundTakeoffFloor = profile.airframeStyle == .tailsitterVTOL && control.mode == .takeoff
            let manualTailsitterThrottle = profile.airframeStyle == .tailsitterVTOL && control.mode == .manual
            let throttleFloor: Float
            if manualTailsitterThrottle {
                throttleFloor = 0.0
            } else if state.position.y > 0.15 || allowGroundTakeoffFloor {
                throttleFloor = hoverPhaseFloor * (1.0 - wingborneBlend) + cruiseFloor * wingborneBlend
            } else {
                throttleFloor = 0.0
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

        return VTOLAeroTransitionStep(
            profile: profile,
            wing: wing,
            aero: aero,
            baseline: baseline,
            authority: authority,
            batteryFactor: batteryFactor,
            mass: mass,
            liftPenalty: liftPenalty,
            crashOrDisarmed: crashOrDisarmed,
            alpha: alpha,
            beta: beta,
            airspeed: airspeed,
            aeroForceBody: aeroForceBody,
            aeroMomentBody: aeroMomentBody,
            elevatorFraction: elevatorFraction,
            aileronFraction: aileronFraction,
            rudderFraction: rudderFraction,
            wingLiftRatio: wingLiftRatio,
            wingborneBlend: wingborneBlend,
            units: units,
            vtolTransitionProgress: vtolTransitionProgress,
            vtolTransitionBlocked: vtolTransitionBlocked,
            leverForward: leverForward,
            motorThrottle: motorThrottle,
            ratedDescent: ratedDescent
        )
    }

    /// Sections 9-10 of the original stepHybridVTOLTransitional: integrates
    /// velocity/position/attitude from the already-assembled force/moment,
    /// applies the vertical-speed governor and absolute-speed safety net,
    /// and handles ground rest — identical for every VTOL stepper regardless
    /// of how thrust direction was produced.
    private func integrateVTOLBody(
        state: DroneState,
        next startingNext: DroneState,
        aeroForceBody: SIMD3<Float>,
        thrustForceBody: SIMD3<Float>,
        angularAccel: SIMD3<Float>,
        mass: Float,
        wingborneBlend: Float,
        wing: FixedWingParameters,
        profile: DroneModelProfile,
        context: DroneSimulationContext,
        ratedDescent: Float,
        alpha: Float,
        beta: Float,
        airspeed: Float,
        motorThrottle: Float,
        crashOrDisarmed: Bool,
        dt: Float
    ) -> DroneState {
        var next = startingNext

        // --- 9. Integration: always the fixed-wing quaternion path — a real
        // tilt-rotor's fuselage attitude representation doesn't change with
        // nacelle angle, so there is exactly one rotational integrator here.
        let totalForceWorld = simd_act(state.fixedWingOrientationQuat, aeroForceBody + thrustForceBody)
            + SIMD3<Float>(0, -mass * Tuning.gravity, 0)
        let acceleration = totalForceWorld / mass

        next.velocity = state.velocity + acceleration * dt

        // Vertical-speed governor: blends from the multirotor-style hard
        // ascent/descent cap (hover) to the wing's own climb capability
        // (cruise) as the wing takes the weight — without this a
        // near-vertical hover climb has nothing bounding it (unlike
        // stepMultirotorBaseline, which always clamps `velocity.y`) and
        // keeps accelerating until drag alone catches up, far past the
        // airframe's rated ascent rate.
        let hoverVerticalUpMax = profile.maxAscentSpeedMps.clamped(to: 1.0...20.0)
        let hoverVerticalDownMax = ratedDescent
        let cruiseVerticalMax = max(wing.climbSpeedMps, hoverVerticalUpMax)
        let verticalUpMax = hoverVerticalUpMax * (1.0 - wingborneBlend) + cruiseVerticalMax * wingborneBlend
        let verticalDownMax = hoverVerticalDownMax * (1.0 - wingborneBlend) + cruiseVerticalMax * wingborneBlend
        next.velocity.y = next.velocity.y.clamped(to: -verticalDownMax...verticalUpMax)

        // Absolute total-speed safety net: a defensive ceiling well above the
        // airframe's own cruise envelope, independent of the vertical cap
        // above — guards against any other runaway (e.g. an aero force
        // computed at an extreme, physically-invalid angle of attack during
        // a mismatched transition) compounding into an unbounded climb in
        // total kinetic energy rather than just leaving the vertical axis.
        // Tilt-rotors keep the old defensive headroom; tailsitters were
        // visibly riding that headroom as a steady 40+ m/s "cruise", so keep
        // them close to the catalog envelope instead.
        let speedCeilingMultiplier: Float = profile.airframeStyle == .tailsitterVTOL ? 1.0 : 1.6
        let absoluteSpeedCeiling = max(profile.maxHorizontalSpeedMps, wing.cruiseSpeedMps) * speedCeilingMultiplier
        let currentSpeed = simd_length(next.velocity)
        if currentSpeed > absoluteSpeedCeiling {
            next.velocity *= absoluteSpeedCeiling / currentSpeed
        }

        next.position = state.position + next.velocity * dt

        next.bodyAngularVelocity = clampMagnitude(state.bodyAngularVelocity + angularAccel * dt, limit: 10.0)
        next.fixedWingOrientationQuat = integrateFixedWingOrientation(
            state.fixedWingOrientationQuat,
            rollRate: next.bodyAngularVelocity.x,
            pitchRate: next.bodyAngularVelocity.y,
            yawRate: next.bodyAngularVelocity.z,
            dt: dt
        )
        next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat, fallback: state.orientation)
        next.angularVelocity = next.bodyAngularVelocity
        next.angleOfAttack = alpha
        next.sideslipAngle = beta

        // --- 10. Ground handling: reused verbatim from stepFixedWingAerodynamic
        // — a hybridVTOL rests on gear like a fixed-wing, not by cutting
        // thrust flush to the ground like a multirotor.
        //
        // A tailsitter's tail (its actual ground-contact point when nose-up)
        // sits below the airframe origin used here — tempting to offset
        // position.y itself, but `position.y == supportSurfaceY` is a
        // load-bearing contract for *everything else* in the app (arm/
        // takeoff ground checks, throttle floors, `heightAboveSupportSurface`
        // callers) that treats any nonzero height as "already airborne".
        // Tried exactly that offset once already: it silently broke arming
        // (the aircraft read as already flying at rest and self-applied
        // hover throttle). The tail/ground visual gap is handled purely as a
        // rendering offset in DroneSceneController instead — physics keeps
        // position.y == 0 at rest for every airframe, tailsitter included.
        // (contactGroundClearance is rest-normalized for exactly this
        // reason: it stays 0 at the rest attitude and only lifts the origin
        // at non-rest attitudes, e.g. a banked wingtip near the ground.)
        let groundClearance = contactGroundClearance(context: context, orientation: next.fixedWingOrientationQuat)
        if next.position.y < groundClearance {
            next.position.y = groundClearance
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        let groundRestState = next.position.y <= groundClearance + 0.03 && state.physicalState.isGroundRestState && motorThrottle < 0.18
        if groundRestState {
            next.velocity.x *= max(0.0, 1.0 - dt * 10.0)
            next.velocity.z *= max(0.0, 1.0 - dt * 10.0)
            next.bodyAngularVelocity *= SIMD3<Float>(repeating: max(0.0, 1.0 - dt * 12.0))
            if state.physicalState != .crashed {
                // Level roll/pitch toward the ground while preserving current
                // heading — EXCEPT a tailsitter, which rests nose-up on its
                // tail (pitch = +90°), not flat on its belly. Snapping it
                // level here would fight the hover transition controller,
                // which always demands pitch -> 90° at rest (progress = 0):
                // the very first tick after arming would see thrust ~100%
                // horizontal (nose level) while the controller yanks for a
                // 90° attitude it doesn't have yet.
                let restQuat: simd_quatf
                if profile.airframeStyle == .tailsitterVTOL {
                    restQuat = simd_quatf(angle: next.orientation.z, axis: SIMD3<Float>(0, 1, 0))
                        * simd_quatf(angle: Float.pi / 2, axis: SIMD3<Float>(1, 0, 0))
                } else {
                    restQuat = simd_quatf(angle: next.orientation.z, axis: SIMD3<Float>(0, 1, 0))
                }
                let levelBlend = min(1.0, dt * 4.0)
                let blendedVector = next.fixedWingOrientationQuat.vector * (1.0 - levelBlend) + restQuat.vector * levelBlend
                next.fixedWingOrientationQuat = simd_quatf(vector: simd_normalize(blendedVector))
                next.orientation = eulerFromFixedWingQuaternion(next.fixedWingOrientationQuat, fallback: next.orientation)
            }
            next.angularVelocity = next.bodyAngularVelocity
        }

        next.throttle = crashOrDisarmed ? 0.0 : motorThrottle
        next.motorThrottle = next.throttle
        next.forwardAirspeed = airspeed

        return next
    }

    private func stepHybridVTOLTransitional(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = state
        let s = computeVTOLAeroTransitionStep(state: state, control: control, context: context, dt: dt)

        next.elevatorDeflection = s.elevatorFraction
        next.aileronDeflection = s.aileronFraction
        next.rudderDeflection = s.rudderFraction
        next.vtolWingLiftRatio = s.wingLiftRatio
        next.vtolWingborneBlend = s.wingborneBlend
        next.vtolTransitionProgress = s.vtolTransitionProgress
        next.vtolTransitionBlocked = s.vtolTransitionBlocked

        // --- 7. Propulsive thrust: one unified per-unit sum. Each unit's own
        // thrustDirectionBody encodes the direction sweep via its tilt angle;
        // the *magnitude* budget blends by wingborneBlend — the rotors carry
        // exactly the share of weight the wing does not yet carry, and decay
        // to drag-canceling cruise thrust as the wing takes over (a rotor
        // does not shut down on a schedule, it sheds load as lift builds).
        var units = s.units
        let liftCapableUnits = units.filter { $0.role == .liftRotor || $0.role == .tiltRotor }
        let cruiseUnits = units.filter { $0.role == .cruiseProp }

        let airDensity: Float = 1.225
        let (_, cdTrim) = s.aero.liftDrag(alphaRad: 0.0)
        let cruiseSpeed = max(s.wing.cruiseSpeedMps, s.wing.minSustainableSpeedMps, 1.0)
        let dragAtCruise = 0.5 * airDensity * cruiseSpeed * cruiseSpeed * s.aero.wingArea * cdTrim
        let referenceThrottle = max(0.2, s.baseline.cruiseReferenceThrottle)
        let cruiseSizedThrustMagnitude = s.crashOrDisarmed ? 0.0 : s.motorThrottle * max(0.5, dragAtCruise / referenceThrottle) * s.batteryFactor

        let hoverSizedThrustMagnitude = liftCapableUnits.isEmpty ? 0.0 : rotorBorneThrustMagnitude(
            motorThrottle: s.crashOrDisarmed ? 0.0 : s.motorThrottle,
            baseline: s.baseline,
            authority: s.authority,
            mass: s.mass,
            batteryFactor: s.batteryFactor,
            liftPenalty: s.liftPenalty
        )
        let totalLiftCapableThrustMagnitude = hoverSizedThrustMagnitude * (1.0 - s.wingborneBlend) + cruiseSizedThrustMagnitude * s.wingborneBlend
        let perLiftUnitThrustMagnitude = liftCapableUnits.isEmpty ? 0.0 : totalLiftCapableThrustMagnitude / Float(liftCapableUnits.count)

        let perCruiseUnitThrustMagnitude = cruiseUnits.isEmpty ? 0.0 : cruiseSizedThrustMagnitude / Float(cruiseUnits.count)

        var thrustForceBody = SIMD3<Float>(repeating: 0.0)
        for index in units.indices {
            let magnitude: Float
            switch units[index].role {
            case .liftRotor, .tiltRotor:
                magnitude = perLiftUnitThrustMagnitude
            case .cruiseProp:
                magnitude = perCruiseUnitThrustMagnitude
            }
            thrustForceBody += units[index].thrustDirectionBody * magnitude
            units[index].rotationalSpeedRadPerSec = s.crashOrDisarmed ? 0.0 : (120.0 + s.motorThrottle * 640.0)
        }

        // --- 8. Attitude authority blend: aero moments alone (~zero at
        // hover, since dynamicPressure floors near zero there) would leave
        // the aircraft with no control in hover — layer in multirotor-style
        // differential-thrust rate tracking, weighted by how much of the
        // weight the rotors still carry, so it fades out exactly as real
        // aero authority (dynamic pressure) fades in. On stall the blend
        // collapses fast and rotor-style control returns automatically.
        let desiredRates = s.crashOrDisarmed ? SIMD3<Float>(repeating: 0.0) : desiredMultirotorRates(control: control, state: state, authority: s.authority)
        let hoverRateGain = SIMD3<Float>(7.2 * s.authority, 7.2 * s.authority, 4.8 * s.authority)
        let hoverAngularDamping = SIMD3<Float>(2.8, 2.8, 2.2)
        let hoverAngularAccel = (desiredRates - state.bodyAngularVelocity) * hoverRateGain - state.bodyAngularVelocity * hoverAngularDamping
        let aeroAngularAccel = s.aeroMomentBody / s.aero.inertiaTensor
        let angularAccel = hoverAngularAccel * (1.0 - s.wingborneBlend) + aeroAngularAccel * s.wingborneBlend

        next = integrateVTOLBody(
            state: state,
            next: next,
            aeroForceBody: s.aeroForceBody,
            thrustForceBody: thrustForceBody,
            angularAccel: angularAccel,
            mass: s.mass,
            wingborneBlend: s.wingborneBlend,
            wing: s.wing,
            profile: s.profile,
            context: context,
            ratedDescent: s.ratedDescent,
            alpha: s.alpha,
            beta: s.beta,
            airspeed: s.airspeed,
            motorThrottle: s.motorThrottle,
            crashOrDisarmed: s.crashOrDisarmed,
            dt: dt
        )

        // --- 11. VTOL phase telemetry label (display-only, see VTOLFlightPhase).
        if next.vtolTransitionProgress <= 0.02 {
            switch control.mode {
            case .takeoff:
                next.vtolPhase = .verticalTakeoff
            case .landing:
                next.vtolPhase = .verticalLanding
            default:
                next.vtolPhase = .hover
            }
        } else if next.vtolTransitionProgress >= 0.98 {
            next.vtolPhase = .cruise
        } else {
            next.vtolPhase = s.leverForward ? .transitionToForward : .transitionToHover
        }
        next.propulsionUnits = units

        return next
    }

    /// Tailsitter stepper (WingtraOne GEN II): unlike a tilt-rotor, the
    /// propulsion units never move relative to the airframe (fixed
    /// `.cruiseProp` thrust along body -Z) — instead the *whole airframe*
    /// pitches from nose-up (hover, thrust vertical) to level (cruise,
    /// thrust forward) as `vtolTransitionProgress` sweeps 0->1. Reuses the
    /// exact same aero/safety-gate/progress-tracking math as the tilt-rotor
    /// stepper via `computeVTOLAeroTransitionStep` (the synthetic-progress
    /// branch there — originally written for "no tilting hardware" — turns
    /// out to already be exactly the tailsitter's safety semantics). Only
    /// thrust sizing (section 7) and attitude authority (section 8) differ.
    private func stepTailsitterVTOLTransitional(
        state: DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = state
        let s = computeVTOLAeroTransitionStep(state: state, control: control, context: context, dt: dt)

        next.elevatorDeflection = s.elevatorFraction
        next.aileronDeflection = s.aileronFraction
        next.rudderDeflection = s.rudderFraction
        next.vtolWingLiftRatio = s.wingLiftRatio
        next.vtolWingborneBlend = s.wingborneBlend
        next.vtolTransitionProgress = s.vtolTransitionProgress
        next.vtolTransitionBlocked = s.vtolTransitionBlocked

        // --- 7 (tailsitter variant). All units are fixed-direction and do
        // double duty — weight-support in hover, drag-canceling in cruise —
        // depending on the SAME wingborneBlend, not on a role split (there is
        // no separate lift-rotor bucket to fall back on like the tilt-rotor
        // case has). Reusing the tilt-rotor's role-based split verbatim would
        // size these units purely by the "drag-canceling" cruise formula,
        // which is ~0 at hover airspeed — the aircraft would simply fall.
        var units = s.units
        let airDensity: Float = 1.225
        let (_, cdTrim) = s.aero.liftDrag(alphaRad: 0.0)
        let cruiseSpeed = max(s.wing.cruiseSpeedMps, s.wing.minSustainableSpeedMps, 1.0)
        let dragAtCruise = 0.5 * airDensity * cruiseSpeed * cruiseSpeed * s.aero.wingArea * cdTrim
        let referenceThrottle = max(0.2, s.baseline.cruiseReferenceThrottle)
        let cruiseSizedThrustMagnitude = s.crashOrDisarmed ? 0.0 : s.motorThrottle * max(0.5, dragAtCruise / referenceThrottle) * s.batteryFactor
        let hoverSizedThrustMagnitude = units.isEmpty ? 0.0 : rotorBorneThrustMagnitude(
            motorThrottle: s.crashOrDisarmed ? 0.0 : s.motorThrottle,
            baseline: s.baseline,
            authority: s.authority,
            mass: s.mass,
            batteryFactor: s.batteryFactor,
            liftPenalty: s.liftPenalty
        )
        let totalThrustMagnitude = hoverSizedThrustMagnitude * (1.0 - s.wingborneBlend) + cruiseSizedThrustMagnitude * s.wingborneBlend
        let perUnitThrustMagnitude = units.isEmpty ? 0.0 : totalThrustMagnitude / Float(units.count)

        var thrustForceBody = SIMD3<Float>(repeating: 0.0)
        for index in units.indices {
            thrustForceBody += units[index].thrustDirectionBody * perUnitThrustMagnitude
            units[index].rotationalSpeedRadPerSec = s.crashOrDisarmed ? 0.0 : (120.0 + s.motorThrottle * 640.0)
        }

        // --- 8 (tailsitter variant). Roll/yaw stay under ordinary body-rate
        // stick control the whole flight (no world-frame axis remap between
        // hover/cruise — real tailsitter autopilots also fly body rates, not
        // world Euler angles). Pitch is different: while transitioning, the
        // pitch axis is initially commanded by the sweep itself (nose-up 90°
        // at progress 0, matching eulerFromFixedWingQuaternion's
        // pitch = asin(forward.y) convention). As the sweep reaches cruise,
        // its endpoint blends into the requested fixed-wing pitch so the
        // residual SAS and the aerodynamic elevator share one target. Normal
        // aero pitch authority takes back over via the same hover<->aero blend
        // used for roll/yaw.
        let desiredRates = s.crashOrDisarmed ? SIMD3<Float>(repeating: 0.0) : desiredMultirotorRates(control: control, state: state, authority: s.authority)
        let currentPitch = eulerFromFixedWingQuaternion(state.fixedWingOrientationQuat, fallback: state.orientation).y
        // Once the tailsitter is in cruise, the residual body-rate SAS must
        // follow the same pitch target as the aerodynamic elevator loop. The
        // old target always ended at exactly 0 degrees, so the still-active
        // SAS fought every altitude-hold pitch command and produced the
        // Wingtra-only up/down oscillation. Keep the 90-degree hover target,
        // but blend its cruise endpoint into the actual commanded attitude.
        let maxCruisePitchUp = max(0.05, s.wing.maxPitchUpDeg.degreesToRadians)
        let maxCruisePitchDown = max(0.05, s.wing.maxPitchDownDeg.degreesToRadians)
        let cruisePitchTarget = control.targetOrientation.y.clamped(
            to: -maxCruisePitchDown...maxCruisePitchUp
        )
        let targetPitchRad = (1.0 - s.vtolTransitionProgress) * (Float.pi / 2) +
            s.vtolTransitionProgress * cruisePitchTarget
        let pitchRateTarget = ((targetPitchRad - currentPitch) * 2.2).clamped(to: -1.6...1.6)
        // Roll/yaw's stick-tracking rate commands (desiredRates.x/z) come from
        // angleTrackingRates, which diffs against state.orientation.x/z — the
        // roll/yaw Euler angles extracted via atan2(-forward.x, -forward.z).
        // That extraction is gimbal-locked exactly at pitch = +-90 deg
        // (forward.x and forward.z both -> 0, so atan2 sees a near-(0,0)
        // input and returns an arbitrarily noisy angle) — precisely the
        // attitude a tailsitter sits at for all of hover. Feeding that noise
        // into a full-authority rate controller is what reads as "jerks
        // left-right" at spawn/hover. Fade roll/yaw command authority out as
        // the nose approaches vertical (gimbalSafetyFactor -> 0); the
        // damping term below (driven by bodyAngularVelocity, a real
        // integrated quantity, not an Euler extraction) still actively
        // resists any actual rotation, so the aircraft holds still rather
        // than going slack. Full stick authority returns smoothly as the
        // nose comes down toward level, exactly where the extraction becomes
        // well-conditioned again.
        let gimbalSafetyFactor = abs(cos(currentPitch))
        let verticalness = abs(sin(currentPitch)).clamped(to: 0.0...1.0)
        let hoverYawBlend = (verticalness * (1.0 - s.vtolTransitionProgress)).clamped(to: 0.0...1.0)
        let rollCommandBlend = min(gimbalSafetyFactor, s.vtolTransitionProgress)
        // Near vertical, the world-yaw axis is the airframe's thrust axis
        // (body Z / this integrator's roll-rate channel), not body Y. Sending
        // manual yaw into body Y at hover rocks the aircraft around a
        // horizontal axis and creates the left-right resonance seen in flight.
        // Blend that command back to the normal body-yaw channel as the
        // tailsitter pitches toward cruise.
        let yawRateCommand = desiredRates.z * 0.45
        let hoverDesiredRates = SIMD3<Float>(
            desiredRates.x * rollCommandBlend + yawRateCommand * hoverYawBlend,
            pitchRateTarget,
            yawRateCommand * (1.0 - hoverYawBlend)
        )
        let hoverRateGain = SIMD3<Float>(4.2 * s.authority, 6.4 * s.authority, 3.2 * s.authority)
        let hoverAngularDamping = SIMD3<Float>(5.2, 3.2, 4.8)
        let hoverAngularAccel = (hoverDesiredRates - state.bodyAngularVelocity) * hoverRateGain - state.bodyAngularVelocity * hoverAngularDamping
        let aeroAngularAccel = s.aeroMomentBody / s.aero.inertiaTensor
        // Attitude authority blends by *pilot-commanded* progress here, not
        // by wingborneBlend (unlike Wingcopter, where thrust direction is
        // already locked to the tilt angle regardless of aero authority).
        // For a tailsitter, pitch itself is the contested axis: even at
        // pitch near 0 deg (nose level, thrust ~horizontal), an ordinary wing
        // moving forward generates real lift -- wingborneBlend rises from
        // that alone, with no regard for whether the current pitch matches
        // what the pilot actually asked for (progress). Blending aero
        // authority in by wingborneBlend let that incidental lift hand
        // control away from the hover-pitch-lock before it ever reached 90
        // deg, which is exactly the self-reinforcing loop that kept the
        // aircraft flying like a conventional low-pitch airplane instead of
        // holding nose-up hover: low pitch -> real lift -> more aero
        // authority -> pitch never corrects. Progress instead only grows
        // when the pilot commands it (gated by the safety check in
        // computeVTOLAeroTransitionStep), so at progress = 0 the hover
        // controller keeps full, uncontested authority over pitch.
        // Even at full cruise progress, keep a slice of body-rate SAS online:
        // the simplified Wingtra aero model is not stable enough by itself to
        // damp a manual roll/yaw disturbance without overshooting.
        let attitudeAuthorityBlend = min(s.vtolTransitionProgress, 0.72)
        let angularAccel = hoverAngularAccel * (1.0 - attitudeAuthorityBlend) + aeroAngularAccel * attitudeAuthorityBlend

        next = integrateVTOLBody(
            state: state,
            next: next,
            aeroForceBody: s.aeroForceBody,
            thrustForceBody: thrustForceBody,
            angularAccel: angularAccel,
            mass: s.mass,
            wingborneBlend: s.wingborneBlend,
            wing: s.wing,
            profile: s.profile,
            context: context,
            ratedDescent: s.ratedDescent,
            alpha: s.alpha,
            beta: s.beta,
            airspeed: s.airspeed,
            motorThrottle: s.motorThrottle,
            crashOrDisarmed: s.crashOrDisarmed,
            dt: dt
        )

        // --- 11. VTOL phase telemetry label (display-only, see VTOLFlightPhase).
        if next.vtolTransitionProgress <= 0.02 {
            switch control.mode {
            case .takeoff:
                next.vtolPhase = .verticalTakeoff
            case .landing:
                next.vtolPhase = .verticalLanding
            default:
                next.vtolPhase = .hover
            }
        } else if next.vtolTransitionProgress >= 0.98 {
            next.vtolPhase = .cruise
        } else {
            next.vtolPhase = s.leverForward ? .transitionToForward : .transitionToHover
        }
        next.propulsionUnits = units

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
    private func eulerFromFixedWingQuaternion(_ q: simd_quatf, fallback: SIMD3<Float>? = nil) -> SIMD3<Float> {
        let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
        let pitch = asin(forward.y.clamped(to: -1.0...1.0))
        let horizontalForward = simd_length(SIMD2<Float>(forward.x, forward.z))
        let fallbackYaw = fallback?.z ?? 0.0
        let yaw = horizontalForward < 0.08 && fallbackYaw.isFinite
            ? fallbackYaw
            : atan2(-forward.x, -forward.z)

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
        fallbackHeading: Float,
        coordinationBankRad: Float = 0.0
    ) -> Float {
        // Yaw-rate damper (active in every mode): opposes yaw rate to suppress
        // the lightly-damped Dutch-roll wallow that the real 6DOF model now
        // simulates. Sign matches the aero cnr damper (cnDeltaR > 0, so rudder
        // ∝ -yawRate produces a damping yaw moment). 0.18 is a light hand —
        // enough to settle the side-to-side weave without making yaw sluggish.
        let yawDamper = (-yawRate * 0.18).clamped(to: -0.5...0.5)
        // Turn coordination (autopilot/assist only — manual stick-and-rudder
        // is the player's job): a banked turn's own geometry demands a yaw
        // rate of the *same sign* as the bank (right bank -> right turn).
        // Same-sign with bank is the self-consistent direction here too —
        // the autopilot already commands bank with the same sign as its
        // course error, so this rudder term must reinforce that bank, not
        // oppose it. Without this the turn is flown on ailerons alone and
        // has to build sideslip before the fuselage/fin "catch up" to the
        // turn — exactly the slip that was feeding the Dutch-roll wallow.
        let coordination = coordinationBankRad * 0.5
        let manualIntent = control.yawIntent.clamped(to: -1.6...1.6)
        if abs(manualIntent) > 0.001 {
            return (manualIntent * 0.6 * authority + yawDamper).clamped(to: -1.0...1.0)
        }
        // Heading-error rudder gain was 0.8 — far too high. The rudder isn't
        // the primary heading actuator (bank is); a large heading-error rudder
        // term lags the wobble and pumps energy *into* the Dutch roll instead
        // of holding course. Cut to 0.25 and let the yaw damper do the work.
        let headingError = wrap(fallbackHeading - currentYaw)
        return (headingError * 0.25 * wing.bankResponseGain + yawDamper + coordination).clamped(to: -1.0...1.0)
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

    // MARK: - Uncontrolled (crashed) body

    /// Free-body integrator for a crashed airframe: gravity + quadratic drag,
    /// full 3D rotation, and iterative contact impulses of the vehicle's
    /// contact spheres against the world ground plane (restitution +
    /// friction), settling to natural rest. Elevated supports (roofs) are
    /// still handled by the view model's support-surface clamp after the
    /// step. Deliberately NOT a full LCP solver — two impulse iterations per
    /// substep are plenty at 90 Hz for a believable tumble.
    private func stepUncontrolledBody(
        state: DroneState,
        context: DroneSimulationContext,
        dt: Float
    ) -> DroneState {
        var next = state

        let massProperties = context.contactProfile.isEmpty
            ? VehicleMassProperties.fallback
            : context.vehicleMassProperties
        let mass = max(0.2, massProperties.totalMassKg)
        let isQuaternionAirframe = context.profile.airframeClass != .multirotor

        // --- Forces: gravity + quadratic body drag.
        let referenceRadius = max(0.12, context.contactProfile.boundingRadius)
        let referenceArea = Float.pi * referenceRadius * referenceRadius * 0.35
        let speed = simd_length(state.velocity)
        var force = SIMD3<Float>(0.0, -mass * Tuning.gravity, 0.0)
        if speed > 0.01 {
            let dragMagnitude = 0.5 * 1.225 * referenceArea * 1.0 * speed * speed
            force -= (state.velocity / speed) * dragMagnitude
        }
        next.velocity = state.velocity + (force / mass) * dt

        // --- Rotation: light aero damping, full 3D integration.
        let rotationalDamping = max(0.0, 1.0 - dt * 0.6)
        var rates = (isQuaternionAirframe ? state.bodyAngularVelocity : state.angularVelocity) * rotationalDamping

        // --- Attitude integration.
        var attitude: simd_quatf
        if isQuaternionAirframe {
            attitude = integrateFixedWingOrientation(
                state.fixedWingOrientationQuat,
                rollRate: rates.x,
                pitchRate: rates.y,
                yawRate: rates.z,
                dt: dt
            )
        } else {
            // Multirotor keeps its legacy Euler-rate integration (rendering
            // and telemetry read Euler for this airframe class).
            next.orientation = wrappedAngles(state.orientation + rates * dt)
            attitude = orientationQuaternion(from: next.orientation)
        }

        next.position = state.position + next.velocity * dt

        // --- Ground contacts.
        //
        // A dynamic hit (real falling speed onto few points) gets a point
        // impulse with restitution. A RESTING body — two or more spheres in
        // ground contact, or a slow approach — must NOT receive point
        // impulses: applying the whole gravity-accumulated impulse at
        // whichever corner happens to be deepest each substep alternates
        // corners and rocks the airframe indefinitely (the post-crash
        // "dancing in place" bug, violent on small airframes whose inertia
        // is tiny). Rest is handled as a support polygon: kill the vertical
        // approach, damp horizontal slide and rotation.
        let spheres = context.contactProfile.spheres
        if !spheres.isEmpty {
            let inertia = simd_max(massProperties.inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))

            var deepestSphere: VehicleContactSphere?
            var deepestBottom: Float = 0.0
            for sphere in spheres {
                let center = sphere.worldCenter(position: next.position, orientation: attitude)
                let bottom = center.y - sphere.radius
                if bottom < deepestBottom {
                    deepestBottom = bottom
                    deepestSphere = sphere
                }
            }

            if let contactSphere = deepestSphere {
                // Single positional correction: deepest sphere exactly on the ground.
                next.position.y -= deepestBottom

                var groundedContactCount = 0
                for sphere in spheres {
                    let bottom = sphere.worldCenter(position: next.position, orientation: attitude).y - sphere.radius
                    if bottom <= 0.02 {
                        groundedContactCount += 1
                    }
                }

                let worldCoM = next.position + simd_act(attitude, massProperties.centerOfMassOffset)
                let sphereCenter = contactSphere.worldCenter(position: next.position, orientation: attitude)
                let contactPoint = SIMD3<Float>(sphereCenter.x, 0.0, sphereCenter.z)
                let leverArm = contactPoint - worldCoM
                let ratesAxes = SIMD3<Float>(rates.y, rates.z, rates.x)
                let omegaWorld = simd_act(attitude, ratesAxes)
                let contactVelocity = next.velocity + simd_cross(omegaWorld, leverArm)

                let isDynamicHit = contactVelocity.y < -0.35 && groundedContactCount < 2
                if isDynamicHit {
                    let normal = SIMD3<Float>(0.0, 1.0, 0.0)
                    let torquePerImpulse = simd_cross(leverArm, normal)
                    let torqueBody = simd_act(attitude.conjugate, torquePerImpulse)
                    let omegaPerImpulseWorld = simd_act(attitude, torqueBody / inertia)
                    let kNormal = 1.0 / mass + simd_dot(simd_cross(omegaPerImpulseWorld, leverArm), normal)
                    // Restitution threshold: only a genuine fall bounces —
                    // micro-approach speeds would otherwise keep the body
                    // hopping forever.
                    let restitution: Float = contactVelocity.y < -1.2 ? 0.18 : 0.0
                    let impulse = -(1.0 + restitution) * contactVelocity.y / max(0.0001, kNormal)

                    next.velocity.y += impulse / mass
                    var deltaOmegaWorld = omegaPerImpulseWorld * impulse

                    // Friction against the tangential contact motion.
                    let tangential = SIMD3<Float>(contactVelocity.x, 0.0, contactVelocity.z)
                    let tangentialSpeed = simd_length(tangential)
                    if tangentialSpeed > 0.03 {
                        let tangent = tangential / tangentialSpeed
                        let torquePerFriction = simd_cross(leverArm, tangent)
                        let frictionOmegaWorld = simd_act(attitude, simd_act(attitude.conjugate, torquePerFriction) / inertia)
                        let kTangent = 1.0 / mass + simd_dot(simd_cross(frictionOmegaWorld, leverArm), tangent)
                        let stoppingImpulse = tangentialSpeed / max(0.0001, kTangent)
                        let frictionImpulse = min(0.65 * impulse, stoppingImpulse)
                        next.velocity -= tangent * (frictionImpulse / mass)
                        deltaOmegaWorld -= frictionOmegaWorld * frictionImpulse
                    }

                    let deltaAxes = simd_act(attitude.conjugate, deltaOmegaWorld)
                    var contactRatesDelta = SIMD3<Float>(deltaAxes.z, deltaAxes.x, deltaAxes.y)
                    // A single point impulse on a tiny-inertia airframe can
                    // compute an absurd spin — cap what one contact may add.
                    contactRatesDelta = clampMagnitude(contactRatesDelta, limit: 4.0)
                    rates = clampMagnitude(rates + contactRatesDelta, limit: 10.0)
                } else {
                    // Resting contact (support polygon or slow touch).
                    if next.velocity.y < 0.0 {
                        next.velocity.y = 0.0
                    }
                    let slideDamping = exp(-dt * 6.0)
                    next.velocity.x *= slideDamping
                    next.velocity.z *= slideDamping
                    rates *= exp(-dt * 5.0)

                    if groundedContactCount < 2 {
                        // Balanced on one point: the ground reaction force
                        // torque tips the body until more points land (an
                        // inverted airframe rolls onto its back instead of
                        // freezing on a corner).
                        let reactionForce = SIMD3<Float>(0.0, mass * Tuning.gravity, 0.0)
                        let tipTorqueWorld = simd_cross(leverArm, reactionForce)
                        let tipTorqueBody = simd_act(attitude.conjugate, tipTorqueWorld)
                        let tipAccelAxes = tipTorqueBody / inertia
                        let tipAccelRates = SIMD3<Float>(tipAccelAxes.z, tipAccelAxes.x, tipAccelAxes.y)
                        rates += clampMagnitude(tipAccelRates, limit: 12.0) * dt
                        rates = clampMagnitude(rates, limit: 10.0)
                    }
                }
            }
        } else if next.position.y < 0.0 {
            next.position.y = 0.0
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        // --- Rest/sleep: once slow and supported, bleed the residual motion
        // out instead of jittering forever on the contact impulses.
        let lowestBottom = spheres.reduce(Float.greatestFiniteMagnitude) { lowest, sphere in
            min(lowest, sphere.worldCenter(position: next.position, orientation: attitude).y - sphere.radius)
        }
        let isSupported = spheres.isEmpty ? next.position.y <= 0.01 : lowestBottom <= 0.02
        if isSupported, simd_length(next.velocity) < 0.5, simd_length(rates) < 1.0 {
            let sleepDamping = max(0.0, 1.0 - dt * 8.0)
            next.velocity *= sleepDamping
            rates *= sleepDamping
            if simd_length(next.velocity) < 0.03 { next.velocity = .zero }
            if simd_length(rates) < 0.03 { rates = .zero }
        }

        if isQuaternionAirframe {
            next.bodyAngularVelocity = rates
            next.angularVelocity = rates
            next.fixedWingOrientationQuat = attitude
            next.orientation = eulerFromFixedWingQuaternion(attitude, fallback: state.orientation)
        } else {
            next.angularVelocity = rates
            next.fixedWingOrientationQuat = attitude
        }

        next.throttle = 0.0
        next.motorThrottle = 0.0
        let rotorDecay = max(0.0, 1.0 - dt * 3.0)
        next.rotorAngularSpeed = state.rotorAngularSpeed * rotorDecay
        next.forwardAirspeed = simd_length(next.velocity)

        return next
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        return yaw * pitch * roll
    }

    /// Attitude-aware ground clearance from the vehicle's contact profile:
    /// the world-ground clamp compares `position.y` against this instead of
    /// 0, so a banked wing or a tumbling airframe rests on its actual lowest
    /// structure instead of sinking to the gear reference. Rest-normalized —
    /// exactly 0 at the airframe's rest attitude — because
    /// `position.y == supportSurfaceY` at rest is a load-bearing contract for
    /// arming/takeoff/landing checks (see the tailsitter note in
    /// `integrateVTOLBody`). Empty profile (no graph built) keeps the legacy
    /// behavior.
    private func contactGroundClearance(
        context: DroneSimulationContext,
        orientation: simd_quatf
    ) -> Float {
        let profile = context.contactProfile
        guard !profile.isEmpty else {
            return 0.0
        }
        return profile.groundClearanceOffset(
            orientation: orientation,
            restOrientation: VehicleContactProfile.restOrientation(for: context.profile.airframeStyle)
        )
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
