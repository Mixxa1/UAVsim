import Foundation
import simd

/// How a fixed-pitch propeller's efficiency falls away from the speed it was pitched for.
///
/// One function because two places have to agree on it: the solver's electric thrust model, and
/// the catalogue derivation that works out what climb rate a published top speed implies. A
/// shape, not a measurement — no airframe on that path publishes a propeller diagram.
enum FixedPitchPropellerShape {
    static func efficiency(speed: Float, cruiseSpeed: Float) -> Float {
        let offset = speed / max(1.0, cruiseSpeed) - 1.0
        return min(1.0, max(0.35, 1.0 - 1.2 * offset * offset))
    }
}

/// What is known about a particular airframe's engine and propeller beyond its engine type.
///
/// ⚠️ A fixed-pitch disc is pitched here for the aircraft's cruise speed at the engine's rated
/// speed, and stops pulling at 1.45 of that advance ratio. An aircraft whose top speed is more
/// than about 1.4 of its cruise therefore cannot reach it whatever its power: at its declared
/// 50 m/s a TEKEVER AR5 at full throttle had 506 N of *drag* from its own propellers, and throttled
/// to the 66 N its cruise needs they turned a fifth of the shaft power into thrust. A real
/// fixed-pitch propeller is pitched so the engine reaches its rated speed at the top of the
/// aircraft's speed range, and runs below it everywhere slower.
///
/// Declared one airframe at a time, like `AirframeInertiaRadii`; nothing else moves.
enum AirframePropulsionDetails {
    struct Details {
        var propellerIsConstantSpeed: Bool?
        var fixedPitchTopSpeedMps: Float?
        var boostCriticalAltitudeM: Float?
    }

    static let declared: [String: Details] = [
        // Two-stroke pushers with fixed-pitch propellers; the speeds are the published maxima.
        "tekever-ar5": Details(fixedPitchTopSpeedMps: 50.0),
        "insitu-scaneagle": Details(fixedPitchTopSpeedMps: 41.2),
        // Rotax 915 iS: turbocharged, rated power held to 15,000 ft, driving a constant-speed
        // propeller.
        "iai-heron-mk-ii": Details(propellerIsConstantSpeed: true, boostCriticalAltitudeM: 4_570.0)
    ]

    static func applied(to powerplant: UAVPowerplantSpec, airframeID: String) -> UAVPowerplantSpec {
        guard let details = declared[airframeID] else { return powerplant }
        var known = powerplant
        known.propellerIsConstantSpeed = details.propellerIsConstantSpeed
        known.fixedPitchTopSpeedMps = details.fixedPitchTopSpeedMps
        known.boostCriticalAltitudeM = details.boostCriticalAltitudeM
        return known
    }
}

/// The height an airframe's published endurance, cruise and top speed are quoted for, where its
/// catalogue entry does not carry one.
///
/// ⚠️ A medium-altitude long-endurance aircraft is not described by its sea-level figures. Flown at
/// 300 m at its published cruise speed an MQ-9B has a lift-to-drag of eight and lasts seventeen
/// hours; the forty its maker quotes are flown at 7–8 km, where the same true airspeed is two
/// thirds of the equivalent airspeed and the wing is near its best. The flight card flew every one
/// of them at 300 m and reported the difference as the aircraft's.
///
/// Read by the flight card and nothing else: no aircraft is started, routed or limited by it.
/// The figures are operating heights their makers publish, rounded: 25,000 ft for both Reapers
/// and for the Heron TP, 28,000 ft — where a P.180 reaches its top speed — for the P.1HH.
///
/// The Heron Mk II is not here though its endurance is quoted at height too: its engine is
/// modelled as naturally aspirated and has half its power left at 7 km, where the real one, a
/// turbocharged Rotax, has all of it. Sent up there it flies worse than at 300 m, which would be
/// measuring the engine model and calling it the aircraft.
enum AirframeCruiseAltitude {
    static let declared: [String: Float] = [
        "mq-9a-reaper": 7_600.0,
        "mq-9b-skyguardian": 7_600.0,
        "iai-heron-tp": 7_600.0,
        "piaggio-p1hh-hammerhead": 8_500.0
    ]
}

/// Radii of gyration for the airframes whose mass distribution is declared rather than inferred.
///
/// Everything else takes its inertia from the component graph, which spreads an airframe's mass
/// over its visual parts. That spread is close to uniform along the fuselage — measured across
/// the fleet, a pitch radius of 0.21–0.28 of the length, the figure of a box — where a real
/// aircraft keeps its engines, fuel and wing box near the centre of mass. On most of the fleet the
/// difference hides behind control power to spare. On the P.1HH it does not: six tonnes with the
/// pitch inertia of a uniform beam leave a full elevator 4.4°/s² of authority, an attitude loop
/// with an 8.5-second period and almost no damping, and a flare whose back-swing puts the
/// aircraft on the runway at 3.2 m/s.
///
/// Non-dimensional, in the convention of Raymer's class statistics (*Aircraft Design: A
/// Conceptual Approach*, table of non-dimensional radii of gyration):
/// `I_roll = m·(b·R̄x/2)²`, `I_pitch = m·(L·R̄y/2)²`, `I_yaw = m·((b+L)/2·R̄z/2)²`.
/// An airframe is added here one at a time, with its class, and nothing else moves.
enum AirframeInertiaRadii {
    static let declared: [String: SIMD3<Float>] = [
        // Twin turboprop.
        "piaggio-p1hh-hammerhead": SIMD3<Float>(0.22, 0.34, 0.38)
    ]

    /// (roll, pitch, yaw) inertia, kg·m², in the solver's rate order.
    static func tensor(massKg: Float, wingSpanM: Float, fuselageLengthM: Float, radii: SIMD3<Float>) -> SIMD3<Float> {
        let roll = wingSpanM * radii.x / 2
        let pitch = fuselageLengthM * radii.y / 2
        let yaw = (wingSpanM + fuselageLengthM) / 2 * radii.z / 2
        return simd_max(SIMD3<Float>(repeating: 0.001), massKg * SIMD3<Float>(roll * roll, pitch * pitch, yaw * yaw))
    }
}

/// Takeoff and climb figures of one airframe, worked out from its own mass, wing, polar and
/// powerplant rather than quoted per class.
///
/// The catalogue used to give every aircraft in the expansion the same 4.5 m/s climb and a
/// runway of fifteen wingspans. A 12 kg hand-launched glider and a six-tonne twin turboprop
/// do not share a climb rate, and fifteen spans of a short-span, heavily loaded aircraft is a
/// quarter of the strip it needs: the P.1HH was given 234 m against a ground roll of 700.
struct AirframePerformanceEstimate {
    /// 1.1·VS in the takeoff configuration (CS-23.51), flaps included where the airframe has them.
    let rotationSpeedMps: Float
    /// Brake release to rotation speed at maximum weight, sea level, still air; `nil` for an
    /// airframe that is thrown or catapulted.
    let groundRollM: Float?
    /// Full-power rate of climb at the climb speed, maximum weight, sea level.
    let climbRateMps: Float
    /// Wing aerodynamic centre to tail, for airframes that have a tail behind the wing.
    let tailArmM: Float?
    /// The power lever at which this airframe's own engine and propeller hold level flight at
    /// its cruise speed, and the least lever on which it flies level at any speed from 1.2·VS up
    /// to cruise — both at its weight without fuel or payload, which is the weight the tuning
    /// scales from. `nil` without an engine and propeller to run: electric airframes are on a
    /// thrust model calibrated the other way round, from the throttle to the drag.
    let cruiseLever: Float?
    let minimumLever: Float?

    private static let cacheLock = NSLock()
    private static var cache: [String: AirframePerformanceEstimate?] = [:]

    /// One derivation per airframe: the catalogue resolves a profile more than once.
    static func cached(for definition: UAVExpansionCatalog.Definition, climbSpeedMps: Float,
                       turnAuthority: Float) -> AirframePerformanceEstimate? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[definition.id] { return cached }
        let estimate = estimate(definition: definition, climbSpeedMps: climbSpeedMps, turnAuthority: turnAuthority)
        cache[definition.id] = estimate
        return estimate
    }

    /// Rolling friction of wheels on a prepared strip — the solver's own figure.
    private static let rollingFriction: Float = 0.035
    private static let gravity: Float = 9.81

    static func estimate(definition: UAVExpansionCatalog.Definition, climbSpeedMps: Float,
                         turnAuthority: Float) -> AirframePerformanceEstimate? {
        guard !definition.isMulticopter else { return nil }
        let f = definition.flight
        let dimensions = definition.dimensions.meters
        let mass = max(0.1, f.massKg)
        let weight = mass * gravity
        let rho = AtmosphereModel.seaLevelDensity
        let stall = max(3, f.minSpeedMps)
        let clean = FixedWingAerodynamics.build(
            family: definition.family, massKg: mass, wingSpanM: dimensions.x,
            fuselageLengthM: dimensions.y, heightM: dimensions.z, turnAuthority: turnAuthority,
            minSustainableSpeedMps: stall, designMassKg: mass, profileID: definition.id)

        // --- Takeoff configuration: the flap setting the takeoff is flown with.
        var takeoff = clean
        var takeoffStall = stall
        if let configuration = definition.mechanics, configuration.hasFlaps,
           let characteristics = AircraftMechanizationCharacteristics.resolve(
            configuration: configuration, profileID: definition.id, aero: clean, stallSpeedMps: stall,
            designMassKg: mass, modelGroundLift: 0) {
            var state = AircraftMechanizationState()
            state.flapDeployment = AircraftMechanizationCharacteristics.takeoffFlapSetting
            state.flapAngleRadians = state.flapDeployment * characteristics.flapMaxRad
            // On its wheels, as it stands during the roll.
            takeoff.mechanization = characteristics.aeroIncrements(
                state: state, hasFlaps: true, retractableGear: configuration.retractableGear)
            takeoffStall = characteristics.stallSpeed(deployment: state.flapDeployment)
        }
        let rotation = 1.1 * takeoffStall

        // --- Thrust at full power against airspeed.
        let powerplant = definition.powerplant
        let propeller = powerplant.flatMap { PropellerModel.resolve(powerplant: $0, cruiseSpeedMps: f.cruiseSpeedMps) }
        // Electric airframes publish no motor rating. Their installed power is the power their
        // published top speed takes, through the same propeller shape the solver flies them on.
        let electricPower: Float = {
            let top = max(f.maxSpeedMps, f.cruiseSpeedMps * 1.05)
            return levelDrag(clean, speed: top, weight: weight, density: rho) * top
                / FixedPitchPropellerShape.efficiency(speed: top, cruiseSpeed: f.cruiseSpeedMps)
        }()
        func thrust(_ speed: Float) -> Float? {
            guard let powerplant else { return nil }
            if let propeller, let ratedKW = powerplant.ratedShaftPowerKW, let rpm = powerplant.ratedShaftRPM {
                return propeller.thrustNewtons(airspeedMps: speed, shaftRPM: rpm, shaftPowerW: ratedKW * 1000,
                                               airDensity: rho) * Float(powerplant.engineCount)
            }
            return powerplant.totalRatedThrustN
        }

        // --- Ground roll: brake release to rotation speed, integrated in speed.
        var groundRoll: Float?
        if f.launchMode == "runway", thrust(0) != nil {
            let ground = takeoff.liftDrag(alphaRad: 0)
            var distance: Float = 0
            let steps = 60
            for step in 0..<steps {
                let speed = rotation * (Float(step) + 0.5) / Float(steps)
                let q = 0.5 * rho * speed * speed * takeoff.wingArea
                let onWheels = max(0, weight - q * ground.cl)
                let force = (thrust(speed) ?? 0) - q * ground.cd - rollingFriction * onWheels
                guard force > 0.02 * weight else { distance = .infinity; break }
                distance += speed * (rotation / Float(steps)) / (force / mass)
            }
            groundRoll = distance.isFinite ? distance : nil
        }

        // --- Rate of climb from excess power at the climb speed.
        let climbSpeed = max(climbSpeedMps, stall * 1.1)
        let climbDrag = levelDrag(clean, speed: climbSpeed, weight: weight, density: rho)
        let climbRate: Float
        if let available = thrust(climbSpeed) {
            // A rated engine and its own propeller: the figure is whatever they leave over.
            climbRate = (available - climbDrag) * climbSpeed / weight
        } else {
            // No motor rating to work from, only the power the published top speed implies —
            // and that hangs on a pair of estimated speeds and on the propeller shape above.
            // So it is held to the gradients this class is flown at: not under 15 %, below
            // which a launch does not clear what stands in front of it (`Tools/ClimbProbe`),
            // and not over 34 %, which is what the class figure of 4.5 m/s gave these airframes.
            let implied = (electricPower * FixedPitchPropellerShape.efficiency(speed: climbSpeed, cruiseSpeed: f.cruiseSpeedMps)
                - climbDrag * climbSpeed) / weight
            climbRate = min(max(implied, 0.15 * climbSpeed), 0.34 * climbSpeed)
        }

        // --- The levers level flight asks of this airframe's own installation.
        //
        // Every fixed wing used to be given its class's cruise throttle and its class's
        // "minimum safe" one — 0.45 and 0.38 of the lever, say — and the solver holds a guided
        // aircraft at or above the second. A TEKEVER AR5 cruises on a twelfth of its engine.
        // Held at a third of it, it flew nine per cent fast and emptied twenty hours of fuel in
        // under eight, with its speed loop asking for a closed throttle the whole way.
        var cruiseLever: Float?
        var minimumLever: Float?
        if let powerplant, powerplant.energySource == .fuel, propeller != nil,
           let backend = FuelPropulsionBackend(powerplant: powerplant, cruiseSpeedMps: f.cruiseSpeedMps) {
            let air = AtmosphereModel.standard.state(altitudeMeters: 0)
            let referenceMass = max(0.1, f.massKg - f.payloadMassKg - f.batteryMassKg - f.fuelMassKg)
            let referenceWeight = referenceMass * gravity
            cruiseLever = backend.lever(
                forThrust: levelDrag(clean, speed: f.cruiseSpeedMps, weight: referenceWeight, density: rho),
                airspeedMps: f.cruiseSpeedMps, atmosphere: air)
            let slowest = min(f.cruiseSpeedMps, 1.2 * stall * (referenceMass / mass).squareRoot())
            // Three speeds are the whole curve for this purpose: the lever a speed needs falls
            // towards the slow end, where the disc bites hardest and the drag is still modest.
            for step in 0...2 {
                let speed = slowest + (f.cruiseSpeedMps - slowest) * Float(step) / 3
                guard let lever = backend.lever(
                    forThrust: levelDrag(clean, speed: speed, weight: referenceWeight, density: rho),
                    airspeedMps: speed, atmosphere: air) else { continue }
                minimumLever = min(minimumLever ?? lever, lever)
            }
        }

        // Tail-volume layouts carry their tail a little under half the fuselage behind the wing.
        let tailArm: Float? = definition.isFlyingWing || definition.isTailsitter ? nil : 0.45 * dimensions.y
        return AirframePerformanceEstimate(
            rotationSpeedMps: rotation, groundRollM: groundRoll,
            climbRateMps: min(40, max(0.5, climbRate)), tailArmM: tailArm,
            cruiseLever: cruiseLever, minimumLever: minimumLever)
    }

    /// Drag in level flight at a speed: the angle of attack that carries the weight, then the polar there.
    static func levelDrag(_ aero: FixedWingAerodynamics, speed: Float, weight: Float, density: Float) -> Float {
        let q = 0.5 * density * speed * speed * aero.wingArea
        var low: Float = -0.1
        var high = aero.stallAlphaRad
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if q * aero.liftDrag(alphaRad: middle).cl < weight { low = middle } else { high = middle }
        }
        return q * aero.liftDrag(alphaRad: (low + high) / 2).cd
    }
}
