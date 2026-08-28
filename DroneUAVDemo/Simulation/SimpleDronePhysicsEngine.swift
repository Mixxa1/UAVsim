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

    /// Oscillator phase for the blade-imbalance vibration disturbance —
    /// engine-instance filter state, like `windGustState` above.
    private var vibrationPhase: Float = 0.0

    /// Start-sequence and shaft dynamics for fuel-burning aircraft. Stateless
    /// itself — the state it advances lives on `DroneState.engineRuntime`.
    private let engineService = EngineRuntimeService()

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
            // Engine and propeller advance on the same substep as the airframe, so
            // the disc's load, the shaft's speed and the thrust it makes all belong
            // to the same instant. `substepContext` is the only thing that differs
            // from `context`; an aircraft with no fuel propulsion never enters here
            // and its context is passed through untouched.
            var substepContext = context
            if let backend = context.fuelPropulsion {
                next.engineRuntime = advanceEngine(
                    state: &next,
                    control: control,
                    context: context,
                    backend: backend,
                    dt: dt
                )
                substepContext.engineState = next.engineRuntime
                if let engineRuntime = next.engineRuntime {
                    substepContext.propulsionOutput = backend.output(
                        engine: engineRuntime,
                        airspeedMps: max(0.0, next.forwardAirspeed),
                        atmosphere: context.atmosphere.state(worldY: next.position.y)
                    )
                }
            }

            // `crashed` is a compatibility/UI lifecycle label, not a switch
            // to a different universe. The normal airframe solver keeps
            // surviving aero surfaces, rotors and their asymmetric forces;
            // disarm/control failure already removes only unavailable input.
            switch context.profile.airframeClass {
            case .multirotor:
                next = stepMultirotorBaseline(state: next, control: control, context: substepContext, dt: dt)
            case .fixedWing:
                let previousSubstep = next
                next = stepFixedWingAerodynamic(state: next, control: control, context: substepContext, dt: dt)
                if let launchDynamics = context.fixedWingLaunchDynamics {
                    next = applyFixedWingLaunchDynamics(
                        previousState: previousSubstep,
                        integratedState: next,
                        dynamics: launchDynamics,
                        context: substepContext,
                        dt: dt
                    )
                }
            case .hybridVTOL:
                if context.profile.airframeStyle == .tailsitterVTOL {
                    next = stepTailsitterVTOLTransitional(state: next, control: control, context: substepContext, dt: dt)
                } else {
                    next = stepHybridVTOLTransitional(state: next, control: control, context: substepContext, dt: dt)
                }
            }
            remaining -= dt
        }

        next.mode = control.mode
        return next
    }

    /// Angular acceleration for a rigid body, including the gyroscopic coupling
    /// term the engine used to drop.
    ///
    /// `omega_dot = I⁻¹ · (M - omega × (I·omega))`. Leaving out the cross product
    /// makes each axis independent, which is only true while the body's rates are
    /// small or its inertias are nearly equal. Neither holds for a fast delta, a
    /// heavily damaged asymmetric airframe, or anything doing an acro roll: a
    /// rolling aircraft with unequal pitch and yaw inertia genuinely pitches and
    /// yaws from the roll alone, and that coupling is what makes a departure look
    /// like a departure instead of three separate first-order responses.
    ///
    /// **Axis convention.** This engine stores rates and moments as
    /// `(roll, pitch, yaw)` about world (Z, X, Y) — mirrored against the textbook
    /// body frame on the roll and yaw axes, as `FixedWingAerodynamics` documents at
    /// length. The cross product is therefore evaluated in a properly right-handed
    /// frame and mapped back, rather than being applied to the mirrored triple
    /// directly, which would silently flip the sign of the coupling.
    private func rotationalAcceleration(
        momentBody: SIMD3<Float>,
        omegaBody: SIMD3<Float>,
        inertiaRateOrdered: SIMD3<Float>
    ) -> SIMD3<Float> {
        let inertia = simd_max(inertiaRateOrdered, SIMD3<Float>(repeating: 1.0e-4))
        // (roll, pitch, yaw) -> right-handed (x, y, z) for the cross product.
        let omegaXYZ = SIMD3<Float>(omegaBody.y, omegaBody.z, omegaBody.x)
        let inertiaXYZ = SIMD3<Float>(inertia.y, inertia.z, inertia.x)
        let angularMomentumXYZ = inertiaXYZ * omegaXYZ
        let couplingXYZ = simd_cross(omegaXYZ, angularMomentumXYZ)
        // ...and back to (roll, pitch, yaw).
        let coupling = SIMD3<Float>(couplingXYZ.z, couplingXYZ.x, couplingXYZ.y)
        return (momentBody - coupling) / inertia
    }

    /// Advances the engine one substep and returns its new state.
    ///
    /// The start request is not simply "armed". A ground-started aircraft begins
    /// its sequence as soon as it is armed, so the operator watches it crank, catch
    /// and warm before the launch is cleared. A canister-launched loitering munition
    /// cannot do that at all — it is sealed in a tube and ejected by a booster, and
    /// only lights its engine once it is out and has flying speed.
    private func advanceEngine(
        state: inout DroneState,
        control: DroneControlInput,
        context: DroneSimulationContext,
        backend: FuelPropulsionBackend,
        dt: Float
    ) -> EngineRuntimeState {
        let atmosphere = context.atmosphere.state(worldY: state.position.y)
        var engine = state.engineRuntime
            ?? context.engineState
            ?? .cold(ambientTemperatureC: atmosphere.temperatureK - 273.15)

        let airspeed = max(0.0, state.forwardAirspeed)
        let isAirborne = state.position.y > context.groundHeight + 0.8
        let startRequested: Bool
        switch backend.powerplant.startPolicy {
        case .groundStartBeforeLaunch:
            startRequested = control.isArmed && state.physicalState != .crashed
        case .airStartAfterBoost:
            // Sealed in its canister the engine genuinely cannot run, and it lights
            // only once the booster has thrown the airframe clear. But "cannot start
            // in the tube" is not "cannot ever start on the ground": with no
            // launcher present the aircraft is simply parked, and refusing to start
            // there left the whole Harpy family dead on the pad with the throttle
            // open — armed, full power commanded, and not moving.
            let sealedInCanister = context.fixedWingLaunchDynamics != nil && !isAirborne
            startRequested = control.isArmed
                && state.physicalState != .crashed
                && !sealedInCanister
        }

        let hasFuel = (context.fuelState.map { !$0.isStarved && $0.remainingKg > 0.0 }) ?? true
        let load = backend.propellerLoadWatts(
            engine: engine,
            airspeedMps: airspeed,
            airDensity: atmosphere.airDensity
        )

        engine = engineService.update(
            current: engine,
            input: EngineUpdateInput(
                powerplant: backend.powerplant,
                throttle: control.isArmed ? state.motorThrottle : 0.0,
                startRequested: startRequested,
                atmosphere: atmosphere,
                airspeedMps: airspeed,
                isAirborne: isAirborne,
                hasFuel: hasFuel,
                healthFactor: context.powerSystemFactor,
                propellerAbsorbedPowerW: load
            ),
            deltaTime: dt
        )
        return engine
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
        let authority = (resolvedControlAuthority(context: context) * maneuverAuthorityPenalty).clamped(to: 0.05...1.00)
        // State of charge is stored energy, not an instantaneous thrust control. The old model
        // multiplied maximum thrust by charge percentage, so a healthy pack at 55% charge could
        // produce only 55% thrust and a perfectly intact aircraft became unable to take off long
        // before the battery was empty. A LiPo pack holds a broad voltage plateau through its
        // usable middle; the battery service already models that voltage curve and load sag.
        // Apply only that electrical derating here. `isDepleted` below remains the hard cutoff.
        // Voltage sag is a battery phenomenon; a fuel aircraft must not be charged
        // for it. `propulsionAvailabilityFactor` keeps the electric behaviour
        // bit-identical and drops the sag term only when a fuel system is present.
        let batteryFactor = context.propulsionAvailabilityFactor
        let mass = resolvedVehicleMass(
            context: context,
            fallback: payloadMassModel.resolvedCurrentTotalMass,
            minimum: 0.20
        )
        let hoverThrottle = baseline.hoverLockThrottle.clamped(to: 0.20...0.90)
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed
        let groundRestThrottleThreshold = max(0.18, hoverThrottle * 0.68)

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.isEnergyDepleted || control.mode == .emergencyStop {
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

        let effectiveControl = hoverHoldingControl(control: control, state: state, authority: authority)
        var desiredRates = crashOrDisarmed ? SIMD3<Float>(repeating: 0.0) : desiredMultirotorRates(
            control: effectiveControl,
            state: state,
            authority: authority
        )

        var rateGain = effectiveControl.controlMode.isRateMode
            ? SIMD3<Float>(8.6 * authority, 8.6 * authority, 5.6 * authority)
            : SIMD3<Float>(7.2 * authority, 7.2 * authority, 4.8 * authority)
        var angularDamping = effectiveControl.controlMode.isRateMode
            ? SIMD3<Float>(1.6, 1.6, 1.5)
            : SIMD3<Float>(2.8, 2.8, 2.2)

        // Height *above the surface*, not above the world origin. On a 20 m hill the raw y never
        // approaches these thresholds, so neither the low-throttle safety nor the landing damping
        // would ever engage and a parked aircraft would keep skittering.
        let heightAboveGround = state.position.y - context.groundHeight
        let groundedLowThrottleSafety = heightAboveGround <= 0.08 &&
            state.physicalState.isGroundRestState &&
            throttleCommand <= groundRestThrottleThreshold

        if groundedLowThrottleSafety {
            desiredRates *= SIMD3<Float>(repeating: 0.06)
            rateGain *= SIMD3<Float>(repeating: 0.22)
            angularDamping *= SIMD3<Float>(4.8, 4.8, 4.2)
        } else if state.physicalState == .landing && heightAboveGround <= 0.18 {
            angularDamping *= SIMD3<Float>(1.5, 1.5, 1.35)
        } else if state.physicalState == .crashed {
            desiredRates = .zero
            rateGain = SIMD3<Float>(repeating: 0.12)
            angularDamping = SIMD3<Float>(14.0, 14.0, 11.0)
        }

        let commandedAngularAccel = (desiredRates - state.angularVelocity) * rateGain - state.angularVelocity * angularDamping

        let liftPenalty = baseline.liftPenaltyMultiplier.clamped(to: 0.78...1.02)
        let commandedThrust = rotorBorneThrustMagnitude(
            motorThrottle: motorThrottle,
            baseline: baseline,
            authority: authority,
            mass: mass,
            batteryFactor: batteryFactor,
            liftPenalty: liftPenalty
        )

        // --- Per-rotor control allocation. A pristine aircraft deliberately
        // stays on the legacy symmetric baseline: catalog geometry is visual
        // data and is not guaranteed to be perfectly centered, so feeding it
        // through the damage mixer would introduce a false trim moment. Once
        // a rotor loses thrust or its mount bends, allocation becomes active
        // and the resulting asymmetric force/moment is physical.
        let rotorModel = context.rotorModel
        let angularAccel: SIMD3<Float>
        let thrustBody: SIMD3<Float>
        // Per-lane commanded-thrust fractions for the rotor spin visuals
        // (FL/FR/RL/RR); pristine default mirrors the collective throttle.
        var laneThrustFraction = SIMD4<Float>(repeating: motorThrottle)
        var laneAlive = SIMD4<Float>(repeating: 1.0)
        if rotorModel.isEmpty || rotorModel.isPristine {
            angularAccel = commandedAngularAccel
            thrustBody = SIMD3<Float>(0.0, commandedThrust, 0.0)
        } else {
            // Inertia in the engine's (roll, pitch, yaw) rate order: roll is
            // about body Z, pitch about X, yaw about Y.
            let inertiaRates = resolvedRateOrderedInertia(
                context: context,
                fallback: SIMD3<Float>(repeating: 0.02),
                minimum: 0.0005
            )
            let desiredTorque = commandedAngularAccel * inertiaRates

            let maxTotalThrust = rotorBorneThrustMagnitude(
                motorThrottle: 1.0,
                baseline: baseline,
                authority: authority,
                mass: mass,
                batteryFactor: batteryFactor,
                liftPenalty: liftPenalty
            )
            let maxRotorThrust = maxTotalThrust / Float(max(1, rotorModel.rotors.count))
            let allocation = rotorModel.allocate(
                desiredTorque: desiredTorque,
                desiredCollective: commandedThrust,
                maxRotorThrust: maxRotorThrust
            )

            var accel = allocation.actualTorque / inertiaRates
            // Blade-imbalance vibration: a small oscillating disturbance
            // torque proportional to damage and rotor speed.
            let vibration = rotorModel.vibrationLevel
            if vibration > 0.001, motorThrottle > 0.05 {
                vibrationPhase += dt * (70.0 + motorThrottle * 50.0)
                // Wrap at 200π: exact for sin(phase) and, since
                // 1.31·200π == 131·2π, for the 1.31-ratio channel too.
                if vibrationPhase > 200.0 * .pi {
                    vibrationPhase -= 200.0 * .pi
                }
                let wobble = vibration * motorThrottle * 2.6
                accel.x += sin(vibrationPhase) * wobble
                accel.y += sin(vibrationPhase * 1.31 + 0.9) * wobble * 0.8
            }
            angularAccel = accel
            thrustBody = allocation.actualForceBody

            for (index, rotor) in rotorModel.rotors.enumerated() {
                guard let lane = rotor.laneIndex, index < allocation.thrusts.count else { continue }
                laneThrustFraction[lane] = maxRotorThrust > 0.0001
                    ? (allocation.thrusts[index] / maxRotorThrust).clamped(to: 0.0...1.0)
                    : 0.0
                laneAlive[lane] = rotor.thrustFactor > 0.01 ? 1.0 : 0.0
            }
        }

        next.angularVelocity = state.angularVelocity + angularAccel * dt
        next.angularVelocity = clampMagnitude(next.angularVelocity, limit: 8.0)
        next.orientation = wrappedAngles(state.orientation + next.angularVelocity * dt)

        let q = orientationQuaternion(from: next.orientation)
        let thrustWorld = simd_act(q, thrustBody)

        let gravityForce = SIMD3<Float>(0.0, -mass * Tuning.gravity, 0.0)
        let horizontalMax = profile.maxHorizontalSpeedMps.clamped(to: 3.0...42.0)
        let horizontalDragDamping = multirotorHorizontalDragDamping(
            profile: profile,
            controlMode: effectiveControl.controlMode,
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

        let rotorOmega: SIMD4<Float>
        if state.physicalState == .crashed || !control.isArmed {
            rotorOmega = SIMD4<Float>(repeating: 0.0)
        } else if groundRestState && throttleCommand <= groundRestThrottleThreshold {
            rotorOmega = SIMD4<Float>(repeating: 58.0) * laneAlive
        } else {
            // Per-lane speeds from the mixer's actual per-rotor commands: a
            // compensating rotor audibly/visibly spins harder, a dead one
            // stops (laneAlive zeroes it).
            rotorOmega = (SIMD4<Float>(repeating: 120.0) + laneThrustFraction * 640.0) * laneAlive
        }
        if state.physicalState == .crashed || !control.isArmed {
            next.throttle = 0.0
        } else if groundRestState && throttleCommand <= groundRestThrottleThreshold {
            next.throttle = min(motorThrottle, 0.08)
        } else {
            next.throttle = motorThrottle
        }
        next.motorThrottle = next.throttle
        next.rotorAngularSpeed = rotorOmega
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

    /// Propulsive thrust available in wing-borne flight at a commanded throttle, in newtons.
    ///
    /// Two anchors, and both of them have to hold:
    ///
    /// * `cruiseReferenceThrottle` balances the drag of **level flight at cruise** — the drag at
    ///   the angle of attack that actually carries the weight, solved for here, not the drag at
    ///   alpha 0. At alpha 0 these wings barely lift, so that figure is parasite drag alone and
    ///   leaves the induced term out entirely.
    /// * Full throttle delivers the climb rate the profile declares, so `nominalClimbRateMps`
    ///   reaches the flight model instead of being an accident of the cruise-throttle baseline.
    ///
    /// The map between them is piecewise because a single linear scale cannot hold both: raising
    /// the full-throttle figure alone multiplies thrust at every setting and silently moves cruise
    /// speed, which then moves turn radius by its square.
    ///
    /// This was fixed once, for `stepFixedWingAerodynamic`, and the VTOL steppers were left on the
    /// old alpha-0 formula — with the variable still named `cdTrim`, which is what let it sit there
    /// unnoticed. Two code paths modelling the same physics is how they diverged; one function is
    /// how they stop. The consequence of the divergence was not subtle: because a wing-borne VTOL's
    /// throttle floor *is* `cruiseReferenceThrottle`, a reference throttle that produced more than
    /// cruise drag pinned the aircraft above its published cruise speed with no way down —
    /// measured at 24.2 m/s against a 17 m/s book figure on a Quantum Trinity.
    ///
    /// Battery, damage and per-unit factors belong to the caller: a fixed wing scales one pusher,
    /// a VTOL divides this among tilting units that each carry their own damage state.
    private func wingborneThrustMagnitude(
        commandedThrottle: Float,
        aero: FixedWingAerodynamics,
        wing: FixedWingParameters,
        cruiseReferenceThrottle: Float,
        mass: Float,
        airDensity: Float
    ) -> Float {
        let cruiseSpeed = max(wing.cruiseSpeedMps, wing.minSustainableSpeedMps, 1.0)
        let cruiseDynamicPressure = 0.5 * airDensity * cruiseSpeed * cruiseSpeed
        let weightNewtons = mass * Tuning.gravity
        // The lift curve is monotonic below stall, so a short bisection is exact enough and cannot
        // wander into the post-stall branch.
        var lowAlpha: Float = 0.0
        var highAlpha: Float = 12.0 * Float.pi / 180.0
        for _ in 0..<12 {
            let midAlpha = (lowAlpha + highAlpha) * 0.5
            let lift = cruiseDynamicPressure * aero.wingArea * aero.liftDrag(alphaRad: midAlpha).cl
            if lift < weightNewtons {
                lowAlpha = midAlpha
            } else {
                highAlpha = midAlpha
            }
        }
        let (_, cdTrim) = aero.liftDrag(alphaRad: (lowAlpha + highAlpha) * 0.5)
        let dragAtCruise = cruiseDynamicPressure * aero.wingArea * cdTrim
        let referenceThrottle = max(0.2, cruiseReferenceThrottle)
        let nominalClimbRate = max(0.0, wing.nominalClimbRateMps)
        let climbSizedThrust = dragAtCruise + weightNewtons * nominalClimbRate / cruiseSpeed
        let fullThrottleThrust = max(
            0.5,
            dragAtCruise / referenceThrottle,
            climbSizedThrust
        )
        if commandedThrottle <= referenceThrottle {
            return max(0.0, dragAtCruise * (commandedThrottle / referenceThrottle))
        }
        let span = max(0.001, 1.0 - referenceThrottle)
        return max(
            0.0,
            dragAtCruise
                + (fullThrottleThrust - dragAtCruise)
                    * ((commandedThrottle - referenceThrottle) / span)
        )
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

    /// Converts the point captured by the Space/hover command into a modest
    /// attitude correction. The old hover path held altitude and level only;
    /// any existing horizontal velocity (or a small trim error) therefore
    /// remained as drift. This controller damps that velocity and returns to
    /// the captured X/Z point while keeping the ordinary attitude/rate loop
    /// responsible for the actual motion.
    private func hoverHoldingControl(
        control: DroneControlInput,
        state: DroneState,
        authority: Float
    ) -> DroneControlInput {
        guard control.mode == .hover else { return control }

        var held = control
        held.controlMode = .hoverAssist

        let positionErrorWorld = SIMD3<Float>(
            control.targetPosition.x - state.position.x,
            0.0,
            control.targetPosition.z - state.position.z
        )
        let horizontalVelocityWorld = SIMD3<Float>(
            state.velocity.x,
            0.0,
            state.velocity.z
        )
        var desiredAccelerationWorld = positionErrorWorld * 0.9 - horizontalVelocityWorld * 1.6
        let maximumTilt = Float(18.0).degreesToRadians * authority.clamped(to: 0.35...1.0)
        let maximumAcceleration = Tuning.gravity * tan(maximumTilt)
        desiredAccelerationWorld = clampMagnitude(desiredAccelerationWorld, limit: maximumAcceleration)

        let inverseYaw = simd_quatf(
            angle: -state.orientation.z,
            axis: SIMD3<Float>(0.0, 1.0, 0.0)
        )
        let desiredAccelerationBody = simd_act(inverseYaw, desiredAccelerationWorld)
        held.targetOrientation.x = -atan2(desiredAccelerationBody.x, Tuning.gravity)
        held.targetOrientation.y = atan2(desiredAccelerationBody.z, Tuning.gravity)
        return held
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
        let authority = (resolvedControlAuthority(context: context) * authorityPenalty).clamped(to: 0.05...1.00)
        // Voltage sag is a battery phenomenon; a fuel aircraft must not be charged
        // for it. `propulsionAvailabilityFactor` keeps the electric behaviour
        // bit-identical and drops the sag term only when a fuel system is present.
        let batteryFactor = context.propulsionAvailabilityFactor
        let crashOrDisarmed = !control.isArmed || state.physicalState == .crashed

        var throttleCommand = control.throttle.clamped(to: 0.0...1.0)
        if crashOrDisarmed || context.isEnergyDepleted || control.mode == .emergencyStop {
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
            if let fixedWingThrottleCeiling = context.fixedWingThrottleCeiling {
                // This ceiling is a hard safety command, not another baseline preference. Apply
                // it after the normal airborne floor so a mesh-horizon speed governor can
                // actually reduce propulsion while the aircraft is overspeed.
                throttleCommand = min(
                    throttleCommand,
                    fixedWingThrottleCeiling.clamped(to: 0.0...1.0)
                )
            }
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

        let mass = resolvedVehicleMass(
            context: context,
            fallback: payloadMassModel.resolvedCurrentTotalMass,
            minimum: 0.10
        )
        let aero = FixedWingAerodynamics.build(
            family: wing.family,
            massKg: mass,
            wingSpanM: realWingSpanMm / 1000.0,
            fuselageLengthM: realFuselageLengthMm / 1000.0,
            heightM: realHeightMm / 1000.0,
            turnAuthority: wing.turnAuthority,
            minSustainableSpeedMps: wing.minSustainableSpeedMps
        ).applyingDamage(context.aeroDamage)

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
                // Elevator trim: the integral term that removes the droop kP alone cannot.
                //
                // Raising kP 2.0 → 3.5 (see above) narrowed the steady-state error but could not
                // remove it — it is a balance against cmAlpha, so *some* error is always needed to
                // hold the surface. Measured on the eBee-class wing: 11° commanded, 7.9° achieved,
                // which is 0.35 m/s of climb instead of 1.4. Integrating the residual gives the
                // surface a standing deflection the way a real trim tab does, so the commanded
                // attitude is actually reached. Slow (0.6/s at full error) so it never competes
                // with the rate term for stability, and frozen while the surface is saturated
                // (anti-windup).
                //
                // The ±0.65 bound is sized from the flight data, not guessed: the elevator holding
                // 7.9° equals the P output at its 3.1° of error, which identifies the airframe's
                // restoring stiffness at ~0.04 of full deflection per degree. Holding 11° then
                // needs 0.44, and 15° — this wing's `maxPitchUpDeg` — needs 0.59. A tighter bound
                // silently re-imposes the droop it exists to remove; ±0.65 covers the envelope and
                // still leaves a third of the surface to the P and rate terms.
                // Rate gain 0.9, not 0.4: the pitch loop was under-damped and it
                // showed up as the launch "resonance" the operator kept reporting.
                //
                // Held level at altitude the loop is quiet (a tenth of a degree
                // across the fleet), which is why it never looked wrong in a steady
                // measurement. Through a climb-out it is not steady — speed and trim
                // are both moving — and 0.4 against a P of 3.5 leaves a damping
                // ratio near 0.2: measured on the FT5, +/-2 degrees at 0.6 Hz,
                // halving per cycle. That is Level 2 handling by MIL-F-8785C, which
                // asks for at least 0.35 in this flight phase and is exactly the
                // band a pilot describes as the aircraft hunting. 0.9 puts the
                // damping near 0.45 and costs nothing in steady state, because the
                // droop the rate term would otherwise add is what the elevator trim
                // integrator below already removes.
                let unsaturatedElevator = (pitchErrorNorm * 3.5 - pitchRateNorm * 0.9)
                    * authority * max(0.75, wing.climbResponseGain)
                // The plain integrator, as first written.
                //
                // Gates were added later chasing a roll oscillation whose cause turned out to be
                // elsewhere — manual flight inheriting a commanded bank at the launch handover.
                // They were never shown to fix anything and measurably cost the correction this
                // exists for: with them the aircraft settled at 11.5° against a steady 15°
                // command. Frozen only while the surface saturates, which is ordinary anti-windup.
                //
                // The droop is real and measured: in the launch log the command was 15.0° and the
                // attitude 6.6°, less than half — which is most of why a departure that should
                // climb was arriving at the ground instead.
                if abs(unsaturatedElevator) < 0.98 {
                    next.elevatorTrim = (state.elevatorTrim + pitchErrorNorm * 0.6 * dt)
                        .clamped(to: -0.65...0.65)
                } else {
                    next.elevatorTrim = state.elevatorTrim
                }
                elevatorFraction = (unsaturatedElevator + next.elevatorTrim).clamped(to: -1.0...1.0)
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
        // Seized/frozen servos override command and slew alike — a jammed
        // surface holds its deflection no matter who is flying.
        if let frozen = context.jammedSurfaces[.elevator] { elevatorFraction = frozen }
        if let frozen = context.jammedSurfaces[.aileron] { aileronFraction = frozen }
        if let frozen = context.jammedSurfaces[.rudder] { rudderFraction = frozen }
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

        // Ambient density at the aircraft's own altitude rather than a sea-level
        // constant. Note this is NOT the density used to size the wing: that one
        // is a sea-level calibration of the airframe's geometry against its stall
        // speed and must stay fixed, or the wing would change area as the
        // aircraft climbed (see FixedWingAerodynamics.build).
        let atmosphere = context.atmosphere.state(worldY: state.position.y)
        let airDensity = atmosphere.airDensity
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

        // --- Thrust: sized so motorThrottle == baseline.cruiseReferenceThrottle balances drag in
        // *level* flight at cruise — which means the drag at the angle of attack that actually
        // carries the weight, not the drag at alpha 0.
        //
        // Taking `liftDrag(alphaRad: 0)` left out the induced term entirely: at alpha 0 this wing
        // barely lifts, so the figure was parasite drag alone and full throttle came out only
        // ~2.2x it. Level flight at cruise needs parasite *plus* induced, so the real margin over
        // cruise drag was a few per cent and the airframe could not climb — measured, the eBee-class
        // wing held 17.6 m/s at 11° of pitch and gained 0.3 m/s while its own profile claims
        // 4.5 m/s of ascent. Solving for the trim alpha restores the margin a real aircraft has,
        // and it changes no published characteristic: mass, wing area, cd0, the induced-drag
        // factor and the cruise-throttle baseline are all still exactly what the profile says.
        // Sizing lives in `wingborneThrustMagnitude`, shared with the VTOL steppers so the two
        // cannot drift apart again. Climb performance is part of that sizing: deriving full-throttle
        // thrust solely from `dragAtCruise / cruiseReferenceThrottle` made it an accident of the
        // cruise baseline, and `nominalClimbRateMps` — declared on every catalogue entry — reached
        // the flight model nowhere. Measured by `Tools/ClimbProbe` before that change: every fixed
        // wing delivered about a third of its declared rate, and the MQ-9B and Hermes 900 could not
        // climb at all.
        let commandedThrottle = crashOrDisarmed ? 0.0 : motorThrottle
        // A fuel aircraft's thrust comes from its engine and propeller, not from
        // its weight. `wingborneThrustMagnitude` remains the only backend for every
        // battery-electric profile, whose cruise and climb figures it is calibrated
        // against — none of that calibration is re-opened here.
        let thrustMagnitude: Float
        if let propulsion = context.propulsionOutput {
            thrustMagnitude = propulsion.thrustNewtons
                * batteryFactor
                * context.rotorModel.cruiseThrustFactor
        } else {
            thrustMagnitude = wingborneThrustMagnitude(
                commandedThrottle: commandedThrottle,
                aero: aero,
                wing: wing,
                cruiseReferenceThrottle: baseline.cruiseReferenceThrottle,
                mass: mass,
                airDensity: airDensity
            ) * batteryFactor * context.rotorModel.cruiseThrustFactor
        }
        let thrustForceBody = SIMD3<Float>(0, 0, -1) * thrustMagnitude

        // --- Propulsion-airframe coupling: prop wash on the tail, torque
        // reaction, P-factor, gyroscopic precession. None of this existed
        // before — thrust only ever pushed the aircraft forward.
        //
        // Every term below is a *propeller* phenomenon and none of it belongs to a
        // turbojet, which has no disc to react against. Charging them to one rolled
        // the HESA Karrar onto its back on the ground at 2 m/s: at that speed there
        // is no dynamic pressure for the aero damping to work against, so a
        // constant thrust-derived roll moment had nothing opposing it at all.
        let hasPropeller = context.fuelPropulsion.map { $0.propeller != nil } ?? true
        // On the ground the landing gear reacts torque into the surface — that is
        // why a real aircraft does not roll over when its engine is run up on the
        // ramp. There is no gear model here, so the reaction is applied directly:
        // thrust-induced roll and yaw fade out as the airframe settles onto its
        // contact point. Without this a 4-tonne MQ-9A tipped over during its ground
        // roll at 34 m/s under nothing but its own propeller torque.
        let groundClearanceForReaction = contactGroundClearance(
            context: context,
            orientation: state.fixedWingOrientationQuat
        )
        let heightAboveSurface = state.position.y - groundClearanceForReaction
        let gearReactionRelief = (heightAboveSurface / 1.5).clamped(to: 0.0...1.0)

        if !crashOrDisarmed && hasPropeller {
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
            momentBody.x += -aero.propSpinSign * thrustMagnitude * aero.propRadius
                * aero.torqueThrustRatio * gearReactionRelief

            // P-factor: asymmetric blade loading at high AoA/low speed yaws
            // the nose, growing with both thrust and AoA.
            momentBody.z += aero.propSpinSign * sin(alpha) * thrustMagnitude * aero.propRadius
                * aero.pFactorGain * gearReactionRelief

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

        // --- Centre-of-mass shift as fuel burns off.
        //
        // NOT a blanket `r × F` about the centre of mass. That looks like the
        // obvious way to do it and is wrong twice over.
        //
        // First it double-counts: `Cm` from the coefficient build-up already *is*
        // the pitching moment about the reference point. Adding the lift force's
        // own moment arm on top charges the same physics twice. Second, the lever
        // it used was the component graph's centre-of-mass offset, which for the
        // aircraft carrying a `runtimeSceneDimensionsOverride` is measured on a
        // scene-scale visual — three metres standing in for twenty. Applied to
        // thrust that produced a pitch-up with no airspeed to damp it, and every
        // fuel aircraft reared onto its tail from a standing start: the MQ-9A went
        // from 0° to 51° of pitch while still doing 0.5 m/s.
        //
        // The physically correct statement is the textbook one — moving the centre
        // of mass changes where the aerodynamic moment is referenced:
        // `Cm_cg = Cm_ac + CL · Δx / c̄`. Only the *change* from fuel burn belongs
        // here, because the airframe's baseline balance is already inside
        // `cmAlpha`. Aft shift destabilises and trims nose-up; forward does the
        // reverse. Zero at full tanks by construction, and zero for every aircraft
        // that carries no fuel.
        let fuelBalanceShiftAft = fuelCentreOfMassShift(context: context).z
        if abs(fuelBalanceShiftAft) > 1.0e-4 {
            let deltaCm = cl * fuelBalanceShiftAft / max(0.05, aero.meanChord)
            momentBody.y += deltaCm * dynamicPressure * aero.wingArea * aero.meanChord
        }

        // --- Integration: semi-implicit Euler (unconditionally stable for damped oscillatory systems).
        let totalForceWorld = simd_act(state.fixedWingOrientationQuat, aeroForceBody + thrustForceBody)
            + SIMD3<Float>(0, -mass * Tuning.gravity, 0)
        let acceleration = totalForceWorld / mass

        next.velocity = state.velocity + acceleration * dt
        next.position = state.position + next.velocity * dt

        let inertiaRates = resolvedRateOrderedInertia(
            context: context,
            fallback: aero.inertiaTensor,
            minimum: 0.001
        )
        let angularAccel = rotationalAcceleration(
            momentBody: momentBody,
            omegaBody: state.bodyAngularVelocity,
            inertiaRateOrdered: inertiaRates
        )
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

        // --- Weight on wheels.
        //
        // Until this existed, a fixed wing under power on the ground was a free
        // rigid body sliding on a frictionless floor: nothing reacted roll, nothing
        // resisted sideslip, nothing held it on its heading. The only ground term
        // in the solver was the rest block below, gated on a nearly closed throttle,
        // so it never ran during a takeoff. At low speed there is no dynamic
        // pressure for the aerodynamic damping to work against either, so any
        // disturbance — a gust, a torque reaction, a metre of sloping ground — grew
        // unopposed until a wingtip was the lowest point, the ground clamp lifted
        // the airframe onto it, and the contact solver tore the gear off. That is
        // the ground roll-over every fuel aircraft reported.
        //
        // The gear is modelled by what it physically does rather than by freezing
        // the aircraft: it carries the share of the weight the wing has not taken
        // yet, and every term below scales with that share. The constraint
        // therefore fades out exactly as lift builds, so rotation and lift-off need
        // no separate release — at `wheelLoad == 0` this block does nothing at all.
        // How much of the weight the gear still carries — and that is the *vertical*
        // component of the aerodynamic force, not its magnitude.
        //
        // `cl · q · S` is how much lift the wing is making; it says nothing about
        // where that lift is pointing. Roll the aircraft ninety degrees and the
        // number is unchanged while the wing is holding up precisely nothing. So a
        // banked airframe reported a nearly unloaded undercarriage exactly when it
        // was leaning its whole weight on one wheel, the levelling faded out at the
        // moment it was needed most, and a heavy aircraft that got a wing down at
        // speed stayed down. Rotating the force into the world costs one quaternion
        // multiply and removes the whole class of error.
        let verticalAeroForce = simd_act(next.fixedWingOrientationQuat, aeroForceBody).y
        let weightNewtons = max(1.0, mass * Tuning.gravity)
        let inGroundContact = next.position.y <= groundClearance + 0.05
        let wheelLoad = inGroundContact && state.physicalState != .crashed
            ? (1.0 - verticalAeroForce / weightNewtons).clamped(to: 0.0...1.0)
            : 0.0

        if wheelLoad > 0.001 {
            var euler = next.orientation

            // Roll: main gear on both sides reacts a bank moment straight into the
            // surface. Levelling rather than merely damping is the honest model —
            // an aircraft standing on two wheels cannot hold a bank angle.
            let levelRate = min(1.0, dt * 9.0 * wheelLoad)
            euler.x -= euler.x * levelRate
            next.bodyAngularVelocity.x *= max(0.0, 1.0 - dt * 12.0 * wheelLoad)

            // Pitch: the nose gear stops it pitching below the rest attitude and
            // the tail stops it going past the strike angle. Between those the
            // elevator is free, which is what makes rotation possible at all.
            let tailStrikeLimit: Float = 0.26
            if euler.y < 0.0 {
                euler.y -= euler.y * levelRate
                if next.bodyAngularVelocity.y < 0.0 { next.bodyAngularVelocity.y = 0.0 }
            } else if euler.y > tailStrikeLimit {
                euler.y = tailStrikeLimit
                if next.bodyAngularVelocity.y > 0.0 { next.bodyAngularVelocity.y = 0.0 }
            }

            next.orientation = euler
            next.fixedWingOrientationQuat = orientationQuaternion(from: euler)

            // Tyres resist sideways motion far harder than they resist rolling, so
            // the aircraft tracks where it points instead of drifting across the
            // strip. Yaw damping is deliberately light: the rudder and the
            // nosewheel still have to be able to steer it.
            let heading = SIMD3<Float>(-sin(euler.z), 0.0, -cos(euler.z))
            let horizontal = SIMD3<Float>(next.velocity.x, 0.0, next.velocity.z)
            let lateral = horizontal - heading * simd_dot(horizontal, heading)
            next.velocity -= lateral * min(1.0, dt * 7.0 * wheelLoad)
            next.bodyAngularVelocity.z *= max(0.0, 1.0 - dt * 3.0 * wheelLoad)

            // Rolling resistance. Wheels on a prepared surface are cheap; a belly
            // or a skid dragging through grass is not, and that difference is most
            // of what stops an aircraft after a wheels-up landing.
            let rollingFriction: Float = wing.hasWheeledUndercarriage ? 0.035 : 0.38
            let groundSpeed = simd_length(horizontal)
            if groundSpeed > 0.05 {
                let decelerated = max(
                    0.0,
                    groundSpeed - rollingFriction * Tuning.gravity * wheelLoad * dt
                )
                let scale = decelerated / groundSpeed
                next.velocity.x *= scale
                next.velocity.z *= scale
            }
            next.angularVelocity = next.bodyAngularVelocity
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
            let actualMass = resolvedVehicleMass(
                context: context,
                fallback: context.vehicleMassModel.resolvedCurrentTotalMass,
                minimum: 0.20
            )
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

        case .canisterBoost:
            // A booster is a thrust source, not a rail: it keeps accelerating the
            // airframe along the tube axis for its whole burn, well past the point
            // where the aircraft has left the tube. Attitude is held to the launch
            // axis for the tube length only — after that the airframe is free and
            // the aero model takes over while the booster is still pushing.
            let actualMass = resolvedVehicleMass(
                context: context,
                fallback: context.vehicleMassModel.resolvedCurrentTotalMass,
                minimum: 0.20
            )
            let boosterAcceleration = dynamics.maximumAccelerationMps2
                * max(0.2, dynamics.nominalLaunchMassKg) / actualMass
            let priorSpeed = max(0.0, simd_dot(previousState.velocity, direction))
            let targetSpeed = max(0.1, dynamics.targetReleaseSpeedMps)
            let nextSpeed = min(targetSpeed, priorSpeed + boosterAcceleration * dt)
            let travelled = simd_dot(previousState.position - dynamics.origin, direction)

            next.velocity = direction * nextSpeed
            next.position = previousState.position + next.velocity * dt
            next.forwardAirspeed = simd_length(next.velocity - context.windVector)
            if travelled < dynamics.travelLengthMeters {
                // Still constrained by the tube.
                constrainAttitudeAndRates(&next)
            }

        case .handRelease:
            let actualMass = resolvedVehicleMass(
                context: context,
                fallback: context.vehicleMassModel.resolvedCurrentTotalMass,
                minimum: 0.20
            )
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
        let authority = (resolvedControlAuthority(context: context) * authorityPenalty).clamped(to: 0.05...1.00)
        // Voltage sag is a battery phenomenon; a fuel aircraft must not be charged
        // for it. `propulsionAvailabilityFactor` keeps the electric behaviour
        // bit-identical and drops the sag term only when a fuel system is present.
        let batteryFactor = context.propulsionAvailabilityFactor
        let mass = resolvedVehicleMass(
            context: context,
            fallback: payloadMassModel.resolvedCurrentTotalMass,
            minimum: 0.20
        )
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
            massKg: mass,
            wingSpanM: realWingSpanMm / 1000.0,
            fuselageLengthM: realFuselageLengthMm / 1000.0,
            heightM: realHeightMm / 1000.0,
            turnAuthority: wing.turnAuthority,
            minSustainableSpeedMps: wing.minSustainableSpeedMps
        ).applyingDamage(context.aeroDamage)

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
        // Seized/frozen servos override command and slew alike — a jammed
        // surface holds its deflection no matter who is flying.
        if let frozen = context.jammedSurfaces[.elevator] { elevatorFraction = frozen }
        if let frozen = context.jammedSurfaces[.aileron] { aileronFraction = frozen }
        if let frozen = context.jammedSurfaces[.rudder] { rudderFraction = frozen }

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

        let airDensity = context.atmosphere.state(worldY: state.position.y).airDensity
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
        if crashOrDisarmed || context.isEnergyDepleted || control.mode == .emergencyStop {
            throttleCommand = 0.0
        } else {
            // A rotor-borne hover holds an altitude, not a throttle setting.
            //
            // `hover()` locks the stick at `hoverLockThrottle`, and for a hybrid VTOL that constant
            // is `max(hover, transition)` — the transition figure, measured on the Wingtra at 0.60
            // against a hover equilibrium near 0.45. With nothing closing the loop the aircraft
            // simply left: `mode=hover thr=0.61 vy=5.80` held flat from 227 m past 338 m and still
            // climbing when the recording ended, and the same lock added ~19 m every time a mission
            // handed a waypoint through hover. Opening the floor below is not enough — the floor
            // cannot lower a command that is already above it. The multirotor step has always
            // closed this loop; the VTOL step never did.
            let holdsAltitudeInHover = (control.mode == .hover || control.controlMode == .hoverAssist) &&
                state.vtolTransitionProgress < 0.25 &&
                wingborneBlend < 0.25 &&
                control.targetPosition.y.isFinite
            if holdsAltitudeInHover {
                let altitudeError = control.targetPosition.y - state.position.y
                let correction = (altitudeError * 0.05 - state.velocity.y * 0.03) *
                    baseline.effectiveVerticalResponseFactor
                throttleCommand = (throttleCommand + correction).clamped(to: 0.0...1.0)
            }
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
            // The wing-borne floor is stall protection, and stall protection only.
            //
            // Anchoring it at `cruiseReferenceThrottle` made it a speed setting instead: that
            // throttle is, by construction of `wingborneThrustMagnitude`, exactly the power that
            // sustains level flight *at* cruise — so a floor there means cruise speed is the
            // slowest the aircraft may ever fly level, not its nominal speed. Nothing could then
            // slow it down: not the fixed-wing autopilot's speed loop, which commands throttle and
            // was clamped straight back up, and not the stop-at-waypoint braking that a VTOL needs
            // in order to arrive at a corner rather than orbit it.
            //
            // Below the airframe's minimum sustainable speed the floor still holds at full value.
            // It fades out linearly and is gone by cruise speed, where there is no stall left to
            // protect against and the only thing a floor can do is forbid deceleration.
            let cruiseSpeedReference = max(
                wing.minSustainableSpeedMps + 1.0,
                wing.cruiseSpeedMps
            )
            let flyingSpeedMargin = ((airspeed - wing.minSustainableSpeedMps)
                / (cruiseSpeedReference - wing.minSustainableSpeedMps)).clamped(to: 0.0...1.0)
            let cruiseFloor = baseline.effectiveMinimumSafeFlightThrottle * (1.0 - flyingSpeedMargin)
            let allowGroundTakeoffFloor = profile.airframeStyle == .tailsitterVTOL && control.mode == .takeoff
            let manualTailsitterThrottle = profile.airframeStyle == .tailsitterVTOL && control.mode == .manual
            // An autopilot altitude hold must be allowed to command *below*
            // the nominal hover floor while arresting an upward climb.  The
            // old hard floor erased the controller's `-verticalVelocity`
            // term: a blocked Wingtra held progress=0 but stayed pinned at
            // its +5.8 m/s ascent governor indefinitely. Keep the ordinary
            // floor for a requested climb, but let a rotor-borne altitude
            // controller command both sides of hover thrust while holding or
            // descending; otherwise it cannot brake or settle at the target.
            let targetAltitude = control.targetPosition.y
            let hasFiniteAltitudeTarget = targetAltitude.isFinite
            let holdOrDescentRequested = hasFiniteAltitudeTarget &&
                targetAltitude <= state.position.y + 0.35
            let aboveAltitudeTarget = hasFiniteAltitudeTarget &&
                state.position.y > targetAltitude + 0.15
            let rotorBorneAltitudeControl = control.mode != .manual &&
                state.vtolTransitionProgress < 0.25 &&
                wingborneBlend < 0.25 &&
                (holdOrDescentRequested || aboveAltitudeTarget)
            let throttleFloor: Float
            if manualTailsitterThrottle {
                throttleFloor = 0.0
            } else if rotorBorneAltitudeControl {
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

        let airDensity = context.atmosphere.state(worldY: state.position.y).airDensity
        // Same sizing as the fixed wing, from the same function: cruise-reference throttle balances
        // level-flight drag at cruise. This used to be an inline copy that took drag at alpha 0 —
        // parasite only, no induced term — which made reference throttle over-thrust, and since a
        // wing-borne VTOL's throttle floor *is* the cruise reference, the aircraft was pinned above
        // its published cruise speed for the whole leg.
        let cruiseSizedThrustMagnitude = s.crashOrDisarmed ? 0.0 : wingborneThrustMagnitude(
            commandedThrottle: s.motorThrottle,
            aero: s.aero,
            wing: s.wing,
            cruiseReferenceThrottle: s.baseline.cruiseReferenceThrottle,
            mass: s.mass,
            airDensity: airDensity
        ) * s.batteryFactor

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
            // Damage: each unit delivers only what its (geometrically
            // nearest) rotor's propeller/motor integrity still allows.
            let damageFactor = context.rotorModel.thrustFactor(
                nearMount: units[index].mountOffset,
                centerOfMass: resolvedCenterOfMass(context: context)
            )
            thrustForceBody += units[index].thrustDirectionBody * (magnitude * damageFactor)
            units[index].rotationalSpeedRadPerSec = (s.crashOrDisarmed || damageFactor <= 0.01)
                ? 0.0
                : (120.0 + s.motorThrottle * 640.0) * (0.4 + 0.6 * damageFactor)
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
        let inertiaRates = resolvedRateOrderedInertia(
            context: context,
            fallback: s.aero.inertiaTensor,
            minimum: 0.001
        )
        let aeroAngularAccel = rotationalAcceleration(
            momentBody: s.aeroMomentBody,
            omegaBody: state.bodyAngularVelocity,
            inertiaRateOrdered: inertiaRates
        )
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
        let airDensity = context.atmosphere.state(worldY: state.position.y).airDensity
        // Same sizing as the fixed wing, from the same function: cruise-reference throttle balances
        // level-flight drag at cruise. This used to be an inline copy that took drag at alpha 0 —
        // parasite only, no induced term — which made reference throttle over-thrust, and since a
        // wing-borne VTOL's throttle floor *is* the cruise reference, the aircraft was pinned above
        // its published cruise speed for the whole leg.
        let cruiseSizedThrustMagnitude = s.crashOrDisarmed ? 0.0 : wingborneThrustMagnitude(
            commandedThrottle: s.motorThrottle,
            aero: s.aero,
            wing: s.wing,
            cruiseReferenceThrottle: s.baseline.cruiseReferenceThrottle,
            mass: s.mass,
            airDensity: airDensity
        ) * s.batteryFactor
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
            // Damage: nearest-rotor propeller/motor integrity caps the unit.
            let damageFactor = context.rotorModel.thrustFactor(
                nearMount: units[index].mountOffset,
                centerOfMass: resolvedCenterOfMass(context: context)
            )
            thrustForceBody += units[index].thrustDirectionBody * (perUnitThrustMagnitude * damageFactor)
            units[index].rotationalSpeedRadPerSec = (s.crashOrDisarmed || damageFactor <= 0.01)
                ? 0.0
                : (120.0 + s.motorThrottle * 640.0) * (0.4 + 0.6 * damageFactor)
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
        // `asin(forward.y)` cannot tell 89 degrees from 91 degrees: both
        // report +89.  Using that folded Euler pitch in the feedback loop
        // made a tiny nose-up overshoot look like a nose-down error, so the
        // controller accelerated the Wingtra through the vertical and into a
        // full tumble.  Project the shortest forward-vector correction onto
        // the *actual body pitch axis* instead.  Its sign remains correct on
        // both sides of vertical and through an arbitrary hover heading.
        let pitchAttitudeError = signedTailsitterPitchError(
            orientation: state.fixedWingOrientationQuat,
            targetPitch: targetPitchRad,
            targetHeading: control.targetOrientation.z
        )
        let pitchRateTarget = (pitchAttitudeError * 2.2).clamped(to: -1.6...1.6)
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
        // At nose-up hover the normal forward-vector yaw is undefined.  The
        // horizontal projection of body -Y is not: it is the direction the
        // nose will move when the aircraft pitches toward cruise.  Close the
        // heading loop on that physical vector instead of the frozen Euler
        // fallback used by `desiredMultirotorRates`.
        let hoverHeading = tailsitterHoverHeading(
            orientation: state.fixedWingOrientationQuat,
            fallback: state.orientation.z
        )
        let manualYawIntent = control.yawIntent.clamped(to: -1.6...1.6)
        let hoverWorldYawRate: Float
        if abs(manualYawIntent) > 0.001 {
            hoverWorldYawRate = manualYawIntent * 1.65 * s.authority
        } else {
            hoverWorldYawRate = wrap(control.targetOrientation.z - hoverHeading) * 2.2
        }
        let hoverYawRateCommand = (hoverWorldYawRate * 0.45).clamped(to: -0.85...0.85)
        // Convert the desired world-up rotation into true body rates.  This
        // derives the nose-up sign from the quaternion (`body +Z` points
        // down there) and continues smoothly as the body pitches to cruise,
        // instead of relying on a hand-written axis/sign special case.
        let hoverYawBodyOmega = simd_act(
            state.fixedWingOrientationQuat.conjugate,
            SIMD3<Float>(0, hoverYawRateCommand, 0)
        )
        let hoverYawRateChannels = SIMD3<Float>(
            hoverYawBodyOmega.z,
            hoverYawBodyOmega.x,
            hoverYawBodyOmega.y
        )
        let cruiseYawRateCommand = (desiredRates.z * 0.45).clamped(to: -0.85...0.85)
        let legacyHoverDesiredRates = SIMD3<Float>(
            desiredRates.x * rollCommandBlend + hoverYawRateChannels.x * hoverYawBlend,
            pitchRateTarget + hoverYawRateChannels.y * hoverYawBlend,
            cruiseYawRateCommand * (1.0 - hoverYawBlend) + hoverYawRateChannels.z * hoverYawBlend
        )
        // At progress ~= 0 the two generic lateral commands above disappear:
        // `rollCommandBlend` is zero at the Euler singularity and the pitch
        // channel is reserved for the 90-degree transition target. That made
        // a route-following Wingtra hold altitude and heading correctly but
        // physically unable to translate toward a nearby hover waypoint.
        //
        // Treat the command as the equivalent multirotor attitude while the
        // vehicle is rotor-borne. Multiplying the ordinary multicopter target
        // (yaw * pitch * roll) by the tailsitter's +90-degree rest rotation
        // maps its body -Z thrust onto the same world vector as multicopter
        // body +Y thrust. Feedback is a shortest-arc quaternion error, so it
        // stays well-defined at vertical and through heading wrap.
        let rotorBorneFraction = control.mode != .manual && control.controlMode != .acro
            ? (1.0 - s.vtolTransitionProgress / 0.12).clamped(to: 0.0...1.0)
            : 0.0
        let rotorBorneAttitudeBlend = rotorBorneFraction * rotorBorneFraction * (3.0 - 2.0 * rotorBorneFraction)
        var rotorBorneDesiredRates = s.crashOrDisarmed
            ? SIMD3<Float>(repeating: 0.0)
            : tailsitterRotorBorneAttitudeRates(
                orientation: state.fixedWingOrientationQuat,
                // Keep the tilt correction in the aircraft's current heading
                // plane. Heading itself is applied below as a true world-up
                // rotation; combining both into one geodesic quaternion error
                // briefly separated body-forward course from the physical
                // hover heading and created a telemetry gauge jump as the
                // forward projection crossed the near-vertical threshold.
                targetHeading: hoverHeading,
                commandRoll: control.targetOrientation.x,
                commandPitch: control.targetOrientation.y
            )
        rotorBorneDesiredRates += hoverYawRateChannels
        let hoverDesiredRates = legacyHoverDesiredRates * (1.0 - rotorBorneAttitudeBlend) +
            rotorBorneDesiredRates * rotorBorneAttitudeBlend
        let hoverRateGain = SIMD3<Float>(4.2 * s.authority, 6.4 * s.authority, 3.2 * s.authority)
        let hoverAngularDamping = SIMD3<Float>(5.2, 3.2, 4.8)
        let hoverAngularAccel = (hoverDesiredRates - state.bodyAngularVelocity) * hoverRateGain - state.bodyAngularVelocity * hoverAngularDamping
        let inertiaRates = resolvedRateOrderedInertia(
            context: context,
            fallback: s.aero.inertiaTensor,
            minimum: 0.001
        )
        let aeroAngularAccel = rotationalAcceleration(
            momentBody: s.aeroMomentBody,
            omegaBody: state.bodyAngularVelocity,
            inertiaRateOrdered: inertiaRates
        )
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

        // Preserve a meaningful yaw/roll decomposition while the nose is
        // vertical. The quaternion remains authoritative; this only chooses
        // the non-singular tailsitter heading as the Euler gauge consumed by
        // telemetry and the remaining guidance call sites. Blend that gauge
        // into forward-course yaw before the 0.08 extraction boundary. A hard
        // hover-heading -> forward-heading switch made a perfectly smooth
        // quaternion transition appear as a several-degree telemetry jump.
        let nextForward = simd_act(next.fixedWingOrientationQuat, SIMD3<Float>(0, 0, -1))
        let nextHorizontalForward = simd_length(SIMD2<Float>(nextForward.x, nextForward.z))
        if nextHorizontalForward < 0.08 {
            let hoverGauge = tailsitterHoverHeading(
                orientation: next.fixedWingOrientationQuat,
                fallback: state.orientation.z
            )
            let forwardGauge = nextHorizontalForward > 1e-5
                ? atan2(-nextForward.x, -nextForward.z)
                : hoverGauge
            let rawGaugeBlend = ((nextHorizontalForward - 0.02) / 0.055).clamped(to: 0.0...1.0)
            let gaugeBlend = rawGaugeBlend * rawGaugeBlend * (3.0 - 2.0 * rawGaugeBlend)
            let preferredYaw = wrap(hoverGauge + wrap(forwardGauge - hoverGauge) * gaugeBlend)
            next.orientation = eulerFromFixedWingQuaternion(
                next.fixedWingOrientationQuat,
                fallback: next.orientation,
                preferredYaw: preferredYaw
            )
        }

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
    /// at pitch = ±90° like any Euler representation. The quaternion remains
    /// authoritative for integration, but this value is also consumed by a
    /// few legacy guidance/rate call sites, so the tailsitter step supplies a
    /// physical hover-heading fallback near vertical.
    private func eulerFromFixedWingQuaternion(
        _ q: simd_quatf,
        fallback: SIMD3<Float>? = nil,
        preferredYaw: Float? = nil
    ) -> SIMD3<Float> {
        let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
        let pitch = asin(forward.y.clamped(to: -1.0...1.0))
        let horizontalForward = simd_length(SIMD2<Float>(forward.x, forward.z))
        let fallbackYaw = fallback?.z ?? 0.0
        let yaw: Float
        if let preferredYaw, preferredYaw.isFinite {
            yaw = wrap(preferredYaw)
        } else if horizontalForward < 0.08 && fallbackYaw.isFinite {
            yaw = fallbackYaw
        } else {
            yaw = atan2(-forward.x, -forward.z)
        }

        let upWorld = simd_act(q, SIMD3<Float>(0, 1, 0))
        let invYaw = simd_quatf(angle: -yaw, axis: SIMD3<Float>(0, 1, 0))
        let invPitch = simd_quatf(angle: -pitch, axis: SIMD3<Float>(1, 0, 0))
        let unrolled = simd_act(invPitch, simd_act(invYaw, upWorld))
        let roll = atan2(-unrolled.x, unrolled.y)

        return SIMD3<Float>(roll, pitch, yaw)
    }

    /// Physical heading of a nose-up tailsitter.  Body -Y is horizontal at
    /// hover and points in the direction produced by a pitch-down transition;
    /// unlike body forward it does not collapse to a zero-length X/Z vector.
    private func tailsitterHoverHeading(
        orientation: simd_quatf,
        fallback: Float
    ) -> Float {
        let transitionDirection = -simd_act(orientation, SIMD3<Float>(0, 1, 0))
        let planarLength = simd_length(SIMD2<Float>(transitionDirection.x, transitionDirection.z))
        guard planarLength > 1e-5 else {
            return fallback.isFinite ? wrap(fallback) : 0.0
        }
        return atan2(-transitionDirection.x, -transitionDirection.z)
    }

    /// Quaternion-stable hover attitude target for tailsitter translation.
    /// `commandRoll`/`commandPitch` use the existing multicopter convention;
    /// their resultant tilt is capped so diagonal route commands cannot spend
    /// too much of the available thrust on horizontal acceleration.
    private func tailsitterRotorBorneAttitudeRates(
        orientation: simd_quatf,
        targetHeading: Float,
        commandRoll: Float,
        commandPitch: Float
    ) -> SIMD3<Float> {
        let safeRoll = commandRoll.isFinite ? commandRoll : 0.0
        let safePitch = commandPitch.isFinite ? commandPitch : 0.0
        var lateralAttitude = SIMD2<Float>(safeRoll, safePitch)
        let maximumTilt = Float(16.0).degreesToRadians
        let requestedTilt = simd_length(lateralAttitude)
        if requestedTilt > maximumTilt {
            lateralAttitude *= maximumTilt / requestedTilt
        }

        let heading = targetHeading.isFinite ? wrap(targetHeading) : 0.0
        let yawQ = simd_quatf(angle: heading, axis: SIMD3<Float>(0, 1, 0))
        let pitchQ = simd_quatf(angle: lateralAttitude.y, axis: SIMD3<Float>(1, 0, 0))
        let rollQ = simd_quatf(angle: lateralAttitude.x, axis: SIMD3<Float>(0, 0, 1))
        let restQ = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
        let targetQ = yawQ * pitchQ * rollQ * restQ

        let orientationLength = simd_length(orientation.vector)
        guard orientationLength.isFinite, orientationLength > 1e-6 else {
            return .zero
        }
        let currentQ = simd_quatf(vector: orientation.vector / orientationLength)
        var errorVector = (currentQ.conjugate * targetQ).vector
        let errorLength = simd_length(errorVector)
        guard errorLength.isFinite, errorLength > 1e-6 else {
            return .zero
        }
        errorVector /= errorLength
        if errorVector.w < 0.0 {
            errorVector = -errorVector
        }

        let imaginary = SIMD3<Float>(errorVector.x, errorVector.y, errorVector.z)
        let imaginaryLength = simd_length(imaginary)
        guard imaginaryLength.isFinite, imaginaryLength > 1e-6 else {
            return .zero
        }
        let errorAngle = 2.0 * atan2(imaginaryLength, max(0.0, errorVector.w))
        let bodyError = imaginary * (errorAngle / imaginaryLength)

        // Engine rate order is (roll about body Z, pitch about body X, yaw
        // about body Y), not quaternion imaginary XYZ order.
        return SIMD3<Float>(
            (bodyError.z * 0.99).clamped(to: -0.85...0.85),
            (bodyError.x * 2.2).clamped(to: -1.6...1.6),
            (bodyError.y * 2.2).clamped(to: -1.6...1.6)
        )
    }

    /// Signed pitch error about the current body-X axis.  This is deliberately
    /// vector/quaternion based: scalar Euler pitch folds after +/-90 degrees
    /// and cannot be used as a stable tailsitter feedback signal.
    private func signedTailsitterPitchError(
        orientation: simd_quatf,
        targetPitch: Float,
        targetHeading: Float
    ) -> Float {
        let currentForward = simd_act(orientation, SIMD3<Float>(0, 0, -1))
        let bodyPitchAxis = simd_act(orientation, SIMD3<Float>(1, 0, 0))
        let heading = wrap(targetHeading)
        let horizontalForward = SIMD3<Float>(-sin(heading), 0, -cos(heading))
        let unconstrainedTargetForward = simd_normalize(
            horizontalForward * cos(targetPitch) + SIMD3<Float>(0, 1, 0) * sin(targetPitch)
        )
        // Heading and pitch may both be changing during transition.  A body-X
        // rate can only rotate within the plane perpendicular to body X, so
        // compare against the reachable projection rather than letting a
        // simultaneous heading error bias the pitch magnitude or sign.
        let projectedTarget = unconstrainedTargetForward -
            bodyPitchAxis * simd_dot(unconstrainedTargetForward, bodyPitchAxis)
        let projectedLength = simd_length(projectedTarget)
        guard projectedLength > 1e-5 else { return 0.0 }
        let targetForward = projectedTarget / projectedLength
        let sine = simd_dot(simd_cross(currentForward, targetForward), bodyPitchAxis)
        let cosine = simd_dot(currentForward, targetForward).clamped(to: -1.0...1.0)
        return atan2(sine, cosine)
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

    // MARK: - Live component-graph mass properties

    /// The contact profile is created together with the component graph and
    /// is empty for legacy callers. That makes it the compatibility gate for
    /// consuming live attached-component mass properties: old contexts keep
    /// their original mass/inertia models bit-for-bit, while a built graph
    /// immediately reflects detached mass, shifted CoM and changed inertia.
    private func resolvedGraphMassProperties(
        context: DroneSimulationContext
    ) -> VehicleMassProperties? {
        guard !context.contactProfile.isEmpty else {
            return nil
        }

        let properties = context.vehicleMassProperties
        guard properties.totalMassKg.isFinite,
              properties.totalMassKg > 0.0,
              properties.centerOfMassOffset.x.isFinite,
              properties.centerOfMassOffset.y.isFinite,
              properties.centerOfMassOffset.z.isFinite,
              properties.inertiaDiagonal.x.isFinite,
              properties.inertiaDiagonal.y.isFinite,
              properties.inertiaDiagonal.z.isFinite else {
            return nil
        }
        return properties
    }

    /// Airframe mass the flight model integrates against, including whatever fuel
    /// is still in the tanks.
    ///
    /// Fuel is *added* to the dry mass rather than subtracted from a wet one. The
    /// subtractive form looks equivalent and is not: it only works where a
    /// profile's base mass was back-derived from maximum takeoff weight and so
    /// already contains a full load. Several fuel aircraft publish a real empty
    /// weight instead (MQ-9A 2,223 kg, RQ-7B 77 kg, BWB DELTA 13.6 kg), and
    /// subtracting burnt fuel from those drove them below their own dry weight.
    /// Every fuel profile therefore carries an explicitly dry `baseMass`, and this
    /// is the one place the tank contents are added back. Battery aircraft have no
    /// fuel state and are untouched.
    private func resolvedVehicleMass(
        context: DroneSimulationContext,
        fallback: Float,
        minimum: Float
    ) -> Float {
        let dryMass = resolvedGraphMassProperties(context: context)?.totalMassKg ?? fallback
        let fuelMass = max(0.0, context.fuelState?.remainingKg ?? 0.0)
        return max(minimum, dryMass + fuelMass)
    }

    private func resolvedCenterOfMass(
        context: DroneSimulationContext
    ) -> SIMD3<Float> {
        resolvedGraphMassProperties(context: context)?.centerOfMassOffset ?? .zero
    }

    /// How far the centre of mass moves as the tanks empty, metres in body axes.
    ///
    /// Tanks sit near the balance point by design — an aircraft whose trim ran away
    /// as it burned fuel would be unflyable — but "near" is not "at", and the
    /// residual shift is a real handling change over a long flight. The offset is
    /// taken as a small fraction of the airframe's own length rather than being
    /// given per-aircraft, because no manufacturer in this catalogue publishes a
    /// tank station.
    ///
    /// Two per cent of length, not six: on the MQ-9A six per cent worked out to a
    /// fifth of the mean chord of travel, which is several times what any real
    /// aircraft's loading limits permit. This lands near five per cent MAC — a trim
    /// change the pilot notices and trims out, not a stability change.
    private func fuelCentreOfMassShift(context: DroneSimulationContext) -> SIMD3<Float> {
        guard let fuel = context.fuelState, fuel.capacityKg > 0.01 else { return .zero }
        let burnedFraction = (fuel.consumedKg / fuel.capacityKg).clamped(to: 0.0...1.0)
        guard burnedFraction > 0.001 else { return .zero }

        let dryMass = max(0.2, context.vehicleMassModel.resolvedCurrentTotalMass)
        let fuelMass = max(0.0, fuel.remainingKg)
        // Body Z is aft. A tank slightly aft of the balance point moves the centre
        // of mass forward as it empties.
        let lengthMm = context.activeUAVProfile?.dimensions.fuselageLengthMillimeters
            ?? context.profile.dimensionsUnfoldedMm.y
        let tankStationAft = (lengthMm / 1000.0) * 0.02
        let massFraction = fuelMass / max(0.2, dryMass + fuelMass)
        let fullTankShift = tankStationAft * (fuel.capacityKg / max(0.2, dryMass + fuel.capacityKg))
        return SIMD3<Float>(0.0, 0.0, tankStationAft * massFraction - fullTankShift)
    }

    /// Legacy damage authority averages motors, propellers and structure.
    /// Those channels are already represented locally by the rotor mixer and
    /// sectional aero model when a component graph exists; applying the old
    /// aggregate again would double-count the same broken arm/propeller. In
    /// graph mode only the flight-controller health scales command authority.
    private func resolvedControlAuthority(context: DroneSimulationContext) -> Float {
        guard resolvedGraphMassProperties(context: context) != nil else {
            return context.damageState.controlAuthorityMultiplier
        }
        let controllerHealth = context.damageState.health(for: .flightControllerCore)
        return (controllerHealth * context.controlSystemFactor).clamped(to: 0.0...1.0)
    }

    /// `VehicleMassProperties` stores literal body-axis `(Ixx, Iyy, Izz)`.
    /// This engine stores angular rates/moments as `(roll, pitch, yaw)`, where
    /// roll is rotation about body Z, pitch about X and yaw about Y. Therefore
    /// the live tensor must be reordered to `(Izz, Ixx, Iyy)` before division.
    /// The fixed-wing fallback is already rate-ordered and is not remapped.
    private func resolvedRateOrderedInertia(
        context: DroneSimulationContext,
        fallback: SIMD3<Float>,
        minimum: Float
    ) -> SIMD3<Float> {
        guard let properties = resolvedGraphMassProperties(context: context) else {
            // The fixed-wing fallback tensor is built from the already
            // fuel-adjusted mass, so it tracks a burning tank on its own.
            return simd_max(fallback, SIMD3<Float>(repeating: minimum))
        }
        let bodyAxes = properties.inertiaDiagonal
        let rateAxes = SIMD3<Float>(bodyAxes.z, bodyAxes.x, bodyAxes.y)
        // The graph tensor is built from the dry airframe. Scaling it by the mass
        // actually being flown keeps inertia and mass consistent as the tanks
        // empty; the ratio is 1.0 for every aircraft without a fuel system.
        let fuelMass = max(0.0, context.fuelState?.remainingKg ?? 0.0)
        let massRatio = fuelMass > 0.0 && properties.totalMassKg > 0.01
            ? (properties.totalMassKg + fuelMass) / properties.totalMassKg
            : 1.0

        // ⚠️ The graph tensor is measured on the VISUAL, and for the aircraft that
        // carry a `runtimeSceneDimensionsOverride` the visual is a scene-scale
        // stand-in: three metres of model standing in for twenty-four metres of
        // aeroplane. Inertia goes with the square of length, so the MQ-9B was being
        // flown with about one fiftieth of its real roll inertia while its
        // aerodynamic moments were computed from the real twenty-four-metre wing.
        // Every moment therefore produced roughly fifty times the angular
        // acceleration it should, and the three override aircraft — MQ-9B,
        // Hermes 900, MQ-9A — departed in roll from nothing at all. It is the same
        // contamination that put a scene-scale lever under the centre-of-mass
        // moment, in the same field, one layer down.
        let corrected = rateAxes * massRatio * visualInertiaScaleCorrection(context: context)

        // And a floor and ceiling against the aerodynamic tensor, which is built
        // from the catalogue's real dimensions and is therefore the one number here
        // that cannot be scene-contaminated. The correction above fixes the known
        // cause; this bounds every unknown one. A graph tensor that disagrees with
        // the airframe's own geometry by more than a factor of three is not
        // describing this aircraft.
        let floor = simd_max(fallback * 0.33, SIMD3<Float>(repeating: minimum))
        let ceiling = fallback * 3.0
        return simd_min(simd_max(corrected, floor), ceiling)
    }

    /// How far the component graph's geometry is from the airframe's real size.
    ///
    /// 1.0 for every aircraft whose visual is at true scale, which is most of them.
    /// Squared because that is how a moment of inertia scales with length.
    private func visualInertiaScaleCorrection(context: DroneSimulationContext) -> Float {
        guard let realSpanMm = context.activeUAVProfile?.dimensions.wingspanMillimeters,
              realSpanMm > 1.0 else {
            return 1.0
        }
        let visualSpanMm = context.profile.dimensionsUnfoldedMm.x
        guard visualSpanMm > 1.0 else { return 1.0 }
        let ratio = realSpanMm / visualSpanMm
        return (ratio * ratio).clamped(to: 1.0...400.0)
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

        let massProperties = resolvedGraphMassProperties(context: context)
            ?? VehicleMassProperties.fallback
        let mass = max(0.2, massProperties.totalMassKg)
        let isQuaternionAirframe = context.profile.airframeClass != .multirotor

        // --- Forces: gravity + quadratic body drag.
        let referenceRadius = max(0.12, context.contactProfile.boundingRadius)
        let referenceArea = Float.pi * referenceRadius * referenceRadius * 0.35
        let speed = simd_length(state.velocity)
        let airDensityForUncontrolledBody = context.atmosphere.state(worldY: state.position.y).airDensity
        var force = SIMD3<Float>(0.0, -mass * Tuning.gravity, 0.0)
        if speed > 0.01 {
            let dragMagnitude = 0.5 * airDensityForUncontrolledBody * referenceArea * 1.0 * speed * speed
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
        } else if next.position.y < context.groundHeight {
            next.position.y = context.groundHeight
            if next.velocity.y < 0.0 {
                next.velocity.y = 0.0
            }
        }

        // --- Rest/sleep: once slow and supported, bleed the residual motion
        // out instead of jittering forever on the contact impulses.
        let lowestBottom = spheres.reduce(Float.greatestFiniteMagnitude) { lowest, sphere in
            min(lowest, sphere.worldCenter(position: next.position, orientation: attitude).y - sphere.radius)
        }
        let isSupported = spheres.isEmpty
            ? next.position.y <= context.groundHeight + 0.01
            : lowestBottom <= context.groundHeight + 0.02
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
    /// Height the airframe origin rests at, given the surface beneath it.
    ///
    /// Shifting the whole world so the launch pad sat at y = 0 would **not** substitute for this: it
    /// only makes the contract true at one point, and everywhere the real terrain falls below the
    /// launch elevation — in a coastal city, most of it — the aircraft would still stop on the
    /// invisible zero plane and hover above the actual ground.
    private func contactGroundClearance(
        context: DroneSimulationContext,
        orientation: simd_quatf
    ) -> Float {
        let profile = context.contactProfile
        guard !profile.isEmpty else {
            return context.groundHeight
        }
        return context.groundHeight + profile.groundClearanceOffset(
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
