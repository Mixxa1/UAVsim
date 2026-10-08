import Foundation
import simd

/// One line of an airframe's flight card: the figure its catalogue entry declares beside the
/// one the solver produces when the aircraft is flown for it.
struct FlightCardLine: Hashable, Codable {
    enum Quantity: String, CaseIterable, Hashable, Codable {
        case stallSpeed
        case cruiseSpeed
        case maximumSpeed
        case climbRate
        case endurance
        case glideRatio
        /// Power lever a rotorcraft holds its height on.
        case hoverLever
        /// How long a hybrid's pack holds it in a hover — a separate figure from its time on the
        /// wing, and an order of magnitude shorter.
        case hoverEndurance

        var unit: String {
            switch self {
            case .stallSpeed, .cruiseSpeed, .maximumSpeed, .climbRate: return "m/s"
            case .endurance, .hoverEndurance: return "h"
            case .glideRatio, .hoverLever: return ""
            }
        }

        /// Measured over declared, inside which the two are taken to agree. `nil` where the
        /// catalogue declares nothing to hold the measurement to.
        ///
        /// Three of these are the bars the single-purpose probes already apply and are carried
        /// over unchanged: a maximum speed within 15 % (`TopSpeedProbe`), a climb of at least
        /// three quarters of the declared one (`ClimbProbe`), an endurance between half and
        /// double (`FuelAtmosphereProbe`). A cruise within 3 % is the settling band of the speed
        /// loop that flies it (`CruiseEconomyProbe`). The stall is the one the wing is sized
        /// from, so 5 % there is not a tolerance on the aircraft but on the sizing surviving.
        var band: ClosedRange<Float>? {
            switch self {
            case .stallSpeed: return 0.95...1.05
            case .cruiseSpeed: return 0.97...1.03
            case .maximumSpeed: return 0.85...1.15
            case .climbRate: return 0.75...Float.greatestFiniteMagnitude
            case .endurance, .hoverEndurance: return 0.5...2.0
            // Shown, not judged: the height loop closes around whatever the lever turns out to be.
            case .glideRatio, .hoverLever: return nil
            }
        }
    }

    enum Verdict: String, Hashable, Codable {
        case within
        case outside
        /// Measured, with nothing declared to compare it with.
        case informational
        case notMeasured
    }

    let quantity: Quantity
    let declared: Float?
    let measured: Float?

    var ratio: Float? {
        guard let declared, let measured, declared > 0 else { return nil }
        return measured / declared
    }

    var verdict: Verdict {
        guard measured != nil else { return .notMeasured }
        guard let ratio, let band = quantity.band else { return .informational }
        return band.contains(ratio) ? .within : .outside
    }
}

/// An airframe's flight card: every line flown on the solver the app flies it on, at the weight
/// its declared figures are quoted for.
///
/// It exists because a catalogue entry cannot check itself. A twin flown on one engine's thrust,
/// tanks poured on top of the maximum weight, a throttle floor that held an aircraft nine per cent
/// above its own cruise — each of those was a number in the catalogue disagreeing with the
/// aircraft, each was found only when somebody measured that one quantity on that one airframe,
/// and each had been there since the day the airframe was added.
struct AirframeFlightCard: Hashable, Codable {
    let airframeID: String
    let displayName: String
    /// `fixedWing`, `multirotor` or `hybridVTOL`: which set of lines the card carries.
    let airframeClass: String
    /// Maximum takeoff weight, tanks full: what the stall, the climb and the top speed are flown at.
    let flownMassKg: Float
    /// Height the cruise, top speed and endurance were flown at, m.
    let workingAltitudeM: Float
    /// The power lever the airframe settles on in level cruise, and the one it is held at.
    let cruiseLeverAsked: Float?
    let cruiseLeverHeld: Float?
    let lines: [FlightCardLine]

    var outside: [FlightCardLine] { lines.filter { $0.verdict == .outside } }

    func line(_ quantity: FlightCardLine.Quantity) -> FlightCardLine? {
        lines.first { $0.quantity == quantity }
    }

    /// Flies the card for whatever kind of aircraft this is.
    static func measure(profile: DroneModelProfile) -> AirframeFlightCard? {
        switch profile.airframeClass {
        case .fixedWing: return measureFixedWing(profile: profile)
        case .multirotor: return measureMultirotor(profile: profile)
        // On the wing a hybrid is held to the same lines as an aeroplane; its rotor-borne
        // figures are a separate matter and are not on the card yet.
        case .hybridVTOL: return measureFixedWing(profile: profile)
        }
    }

    /// A multirotor has no stall and no cruise to hold it to. Its lines are the lever it hovers
    /// on, the climb and the speed its entry declares, and how long its battery holds it up —
    /// flown at its own takeoff weight, which is what those figures are published for.
    private static func measureMultirotor(profile: DroneModelProfile) -> AirframeFlightCard? {
        guard let rig = RotorTestRig(profile: profile) else { return nil }
        let hover = rig.measureHoverLever()
        // What is measured is the hover, so it is held to the hover time where one is declared —
        // for a camera platform that is a tenth or two under its flight time, for a racing quad
        // a fifth over.
        let declaredEnduranceHours: Float? = {
            if profile.maxHoverTimeMin > 0 { return profile.maxHoverTimeMin / 60 }
            if let seconds = rig.uav?.nominalFlightTimeSec, seconds > 0 { return seconds / 3600 }
            return profile.maxFlightTimeMin > 0 ? profile.maxFlightTimeMin / 60 : nil
        }()
        return AirframeFlightCard(
            airframeID: profile.id,
            displayName: profile.displayName,
            airframeClass: "multirotor",
            flownMassKg: rig.flownMassKg,
            workingAltitudeM: RotorTestRig.altitude,
            cruiseLeverAsked: nil,
            cruiseLeverHeld: nil,
            lines: [
                FlightCardLine(quantity: .hoverLever, declared: rig.declaredHoverLever, measured: hover),
                FlightCardLine(quantity: .climbRate, declared: profile.maxAscentSpeedMps, measured: rig.measureClimbRate(hoverLever: hover)),
                FlightCardLine(quantity: .maximumSpeed, declared: profile.maxHorizontalSpeedMps, measured: rig.measureMaximumSpeed(hoverLever: hover)),
                FlightCardLine(quantity: .endurance, declared: declaredEnduranceHours, measured: hover.flatMap(rig.hoverEnduranceHours))
            ]
        )
    }

    private static func measureFixedWing(profile: DroneModelProfile) -> AirframeFlightCard? {
        guard let rig = FlightTestRig(profile: profile) else { return nil }
        let wing = rig.wing
        let uav = rig.uav

        let stall = rig.measureStallSpeed()
        let cruise = rig.measureCruise()
        let top = rig.measureMaximumSpeed()
        let climb = rig.measureClimbRate()
        let glide = rig.measureGlideRatio()

        let declaredEnduranceHours: Float? = {
            if let seconds = uav?.nominalFlightTimeSec, seconds > 0 { return seconds / 3600 }
            return profile.maxFlightTimeMin > 0 ? profile.maxFlightTimeMin / 60 : nil
        }()

        var lines = [
            FlightCardLine(quantity: .stallSpeed, declared: wing.minSustainableSpeedMps, measured: stall),
            FlightCardLine(quantity: .cruiseSpeed, declared: wing.cruiseSpeedMps, measured: cruise?.speed),
            // What the catalogue publishes, not the wing's own ceiling: the second is derived
            // from the first and would agree with itself.
            FlightCardLine(quantity: .maximumSpeed,
                           declared: max(wing.maxAirspeed, profile.maxHorizontalSpeedMps), measured: top),
            FlightCardLine(quantity: .climbRate, declared: wing.nominalClimbRateMps, measured: climb),
            FlightCardLine(quantity: .endurance, declared: declaredEnduranceHours, measured: cruise?.enduranceHours),
            FlightCardLine(quantity: .glideRatio, declared: nil, measured: glide)
        ]
        // The hover of a hybrid that holds it level on rotors of its own or on tilted ones. A
        // tailsitter hovers standing on its tail and is held to its own probes.
        if let hover = rig.measureHover() {
            lines.append(FlightCardLine(quantity: .hoverLever, declared: hover.declaredLever, measured: hover.lever))
            // Only where a hover time is declared: without one the battery charges a hover at the
            // rate of the cruise, and the figure that comes out describes that rule, not the aircraft.
            if profile.maxHoverTimeMin > 0 {
                lines.append(FlightCardLine(quantity: .hoverEndurance, declared: profile.maxHoverTimeMin / 60,
                                            measured: hover.enduranceHours))
            }
        }

        return AirframeFlightCard(
            airframeID: profile.id,
            displayName: profile.displayName,
            airframeClass: profile.airframeClass == .hybridVTOL ? "hybridVTOL" : "fixedWing",
            flownMassKg: rig.maximumMassKg,
            workingAltitudeM: rig.workingAltitude,
            cruiseLeverAsked: cruise?.leverAsked,
            cruiseLeverHeld: cruise?.leverHeld,
            lines: lines
        )
    }
}

/// Flight cards already flown this session, so opening an airframe's card a second time does not
/// fly it again. Keyed by the whole profile: a Workbench build keeps its identifier while what it
/// flies like changes with every part.
actor AirframeFlightCardCache {
    static let shared = AirframeFlightCardCache()
    private var cards: [DroneModelProfile: AirframeFlightCard?] = [:]

    func card(for profile: DroneModelProfile) async -> AirframeFlightCard? {
        if let flown = cards[profile] { return flown }
        let card = await Task.detached(priority: .utility) { AirframeFlightCard.measure(profile: profile) }.value
        cards[profile] = .some(card)
        return card
    }
}

/// One airframe on the solver and nothing else: the rig a flight card is flown on.
///
/// The aircraft is loaded to its maximum takeoff weight — its own dry weight, full tanks, and
/// ballast for whatever payload makes up the rest — because that is the weight a declared stall
/// speed or climb rate is quoted at. Each measurement starts from a fresh aircraft at 300 m, the
/// height the single-purpose probes use for sea-level figures.
final class FlightTestRig {
    let profile: DroneModelProfile
    let uav: UAVProfile?
    let wing: FixedWingParameters
    let maximumMassKg: Float

    private let massModel: VehicleMassModel
    /// The wing as the solver builds it, used only to start each run already in trim.
    private let aero: FixedWingAerodynamics
    private let backend: FuelPropulsionBackend?
    private let solver = SimpleDronePhysicsEngine(logsStartup: false)
    private let tankKg: Float
    private var fuelState: FuelSystemState?
    private var state: DroneState

    private let cruiseLeverGuess: Float
    /// A lift-and-cruise or tilting airframe, flown here already on its wing.
    private let isHybrid: Bool
    /// Where the airframe's cruise, top speed and endurance are published for: its own cruise
    /// altitude where the catalogue names one, 300 m otherwise. A Reaper's forty hours and a
    /// Firebee's Mach 1.5 are high-altitude figures, and flown at 300 m they measure the test.
    let workingAltitude: Float

    private static let dt: Float = 1.0 / 60.0
    fileprivate static let altitude: Float = 300.0
    /// √(ρ/ρ₀) at the test height: true airspeed to equivalent.
    private static let densityRoot: Float = (AtmosphereModel.standard.state(altitudeMeters: altitude).airDensity
        / AtmosphereModel.seaLevelDensity).squareRoot()

    init?(profile: DroneModelProfile) {
        guard profile.airframeClass != .multirotor, let wing = profile.fixedWingParameters else { return nil }
        self.profile = profile
        self.wing = wing
        isHybrid = profile.airframeClass == .hybridVTOL
        let uav = profile.resolvedUAVProfile
        self.uav = uav
        let dry = VehicleMassModel.baseline(for: profile, uavProfile: uav)
        let tank = uav?.powerplant?.fuel?.usableFuelMassKg ?? 0.0
        tankKg = tank
        let unballasted = dry.resolvedCurrentTotalMass + tank
        let declaredMaximum = uav?.maxTakeoffMass ?? uav?.estimatedMaxTakeoffMass ?? unballasted
        let ballast = max(0.0, declaredMaximum - unballasted)
        massModel = VehicleMassModel.resolve(for: profile, uavProfile: uav, payloadMass: ballast)
        maximumMassKg = massModel.resolvedCurrentTotalMass + tank
        backend = FuelPropulsionBackend(powerplant: uav?.powerplant, cruiseSpeedMps: wing.cruiseSpeedMps)
        let spanMm = uav?.dimensions.wingspanMillimeters ?? profile.dimensionsUnfoldedMm.x
        aero = FixedWingAerodynamics.build(
            family: wing.family, massKg: maximumMassKg, wingSpanM: spanMm / 1000.0,
            fuselageLengthM: (uav?.dimensions.fuselageLengthMillimeters ?? spanMm * 0.55) / 1000.0,
            heightM: (uav?.dimensions.heightMillimeters ?? spanMm * 0.12) / 1000.0,
            turnAuthority: wing.turnAuthority, minSustainableSpeedMps: wing.minSustainableSpeedMps,
            designMassKg: uav.flatMap { $0.maxTakeoffMass ?? $0.estimatedMaxTakeoffMass },
            profileID: profile.id, engineering: profile.engineeringAerodynamics,
            tailArmM: wing.tailArmMeters, inertiaRadii: wing.inertiaRadii, wingAreaM2: wing.wingAreaM2,
            gyrationRadiiMeters: wing.gyrationRadiiMeters)
        workingAltitude = max(Self.altitude, uav?.nominalCruiseAltitudeMeters ?? Self.altitude)
        cruiseLeverGuess = FlightBaselineResolver.resolve(
            runtimeProfile: profile, activeUAVProfile: uav, vehicleMassModel: massModel, flightMode: .autoPath
        ).cruiseReferenceThrottle
        state = .initial
        reset(speed: wing.cruiseSpeedMps, mode: .manual)
    }

    // MARK: - The aircraft

    /// Angle of attack that carries the weight at this speed, or the stall angle if none does.
    /// A run that starts level at zero pitch spends its first half-minute falling and recovering,
    /// and on a light airframe that excursion is still ringing when the measurement is taken.
    private func trimAlpha(speed: Float, altitude: Float) -> Float {
        let air = AtmosphereModel.standard.state(altitudeMeters: altitude)
        let lift = air.dynamicPressure(airspeedMps: speed) * aero.wingArea
        let weight = maximumMassKg * 9.81
        var low: Float = -0.05
        var high = aero.stallAlphaRad
        guard lift * aero.liftDrag(alphaRad: high).cl > weight else { return high }
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if lift * aero.liftDrag(alphaRad: middle).cl < weight { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    private func reset(speed: Float, mode: DroneFlightMode, tankFraction: Float = 1.0,
                       altitude: Float = FlightTestRig.altitude) {
        var fresh = DroneState(
            position: SIMD3<Float>(0, altitude, 0),
            velocity: SIMD3<Float>(0, 0, -speed),
            orientation: SIMD3<Float>(0, trimAlpha(speed: speed, altitude: altitude), 0),
            angularVelocity: .zero,
            throttle: cruiseLeverGuess,
            motorThrottle: cruiseLeverGuess,
            rotorAngularSpeed: .zero,
            forwardAirspeed: speed,
            physicalState: .airborne,
            mode: mode
        )
        fresh.armState = .armed
        // The attitude a fixed wing is flown on is the quaternion; the Euler triple above is
        // only its read-out, and left alone the aircraft starts level whatever that says.
        fresh.attitudeQuat = simd_quatf(angle: fresh.orientation.y, axis: SIMD3<Float>(1, 0, 0))
        if isHybrid {
            // Transition complete: rotors that tilt are tilted, and the wing carries the weight.
            fresh.motionState = .airborne
            fresh.propulsionUnits = profile.propulsionUnitTemplate.map { unit in
                var tilted = unit
                if unit.role == .tiltRotor {
                    tilted.tiltAngleRad = .pi / 2
                    tilted.targetTiltAngleRad = .pi / 2
                }
                return tilted
            }
            fresh.vtolTransitionProgress = 1.0
            fresh.vtolWingborneBlend = 1.0
        }
        // Flown clean: every figure on the card is quoted with the undercarriage up.
        fresh.mechanization.gearExtension = 0
        if let backend {
            var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
            warm.runState = .ready
            warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6_000.0) * 0.9
            warm.temperatureC = EngineOperatingEnvelope.envelope(for: backend.powerplant.engineType).operatingTemperatureC
            fresh.engineRuntime = warm
        }
        state = fresh
        if let fuel = uav?.powerplant?.fuel {
            var tanks = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
            tanks.remainingKg = fuel.usableFuelMassKg * tankFraction
            fuelState = tanks
        } else {
            fuelState = nil
        }
    }

    private func step(pitch: Float, throttle: Float, mode: DroneFlightMode) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, state.position.y, state.position.z - 500.0),
            targetOrientation: SIMD3<Float>(0, pitch, 0),
            yawIntent: 0.0,
            throttle: throttle,
            isArmed: true,
            mode: mode,
            controlMode: .stabilized,
            vtolTransitionLever: isHybrid ? 1.0 : 0.0,
            landingGearDownCommand: false
        )
        let context = DroneSimulationContext(
            profile: profile,
            activeUAVProfile: uav,
            weather: .normal,
            damageState: .pristine,
            batteryState: .full,
            collisionRisk: 0.0,
            windVector: .zero,
            vehicleMassModel: massModel,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: backend
        )
        state = solver.step(state: state, control: control, context: context, deltaTime: Self.dt)
    }

    // MARK: - Level flight

    private struct LevelFlight {
        var speed: Float = 0
        var leverAsked: Float = 0
        var leverHeld: Float = 0
        var shaftPowerKW: Float = 0
        var thrustNewtons: Float = 0
        var verticalSpeed: Float = 0
        var endAltitude: Float = 0
        var endSpeed: Float = 0
        var height: Float = FlightTestRig.altitude
        /// Mean equivalent airspeed over the averaged stretch — what a sea-level figure is compared with.
        var equivalentSpeed: Float = 0

        /// Level at the end, at the height it was asked to hold.
        func heldHeight(within metres: Float) -> Bool {
            abs(endAltitude - height) < metres && abs(verticalSpeed) < 0.3
        }
    }

    /// Holds the height with the elevator and either a speed with the lever or the lever itself.
    /// Averages are taken over the last `averagedSeconds`.
    private func flyLevel(holdingSpeed: Float?, lever fixedLever: Float?, mode: DroneFlightMode,
                          seconds: Float, averagedSeconds: Float, height: Float = FlightTestRig.altitude,
                          until settled: ((Float, Float) -> Bool)? = nil) -> LevelFlight {
        var result = LevelFlight()
        result.height = height
        var pitchTrim: Float = state.orientation.y
        var leverTrim: Float = state.motorThrottle
        var samples: Float = 0
        let total = Int(seconds / Self.dt)
        let averagedFrom = total - Int(averagedSeconds / Self.dt)
        var speedTenSecondsAgo = state.forwardAirspeed
        for tick in 0..<total {
            let heightError: Float = height - state.position.y
            let trimStep: Float = heightError * 0.002 * Self.dt
            pitchTrim = min(0.30, max(-0.15, pitchTrim + trimStep))
            let pitchRaw: Float = pitchTrim + heightError * 0.006 - state.velocity.y * 0.012
            let pitch: Float = min(0.30, max(-0.20, pitchRaw))

            var lever: Float = fixedLever ?? 0
            if let holdingSpeed {
                let speedError: Float = holdingSpeed - state.forwardAirspeed
                let leverStep: Float = speedError * 0.01 * Self.dt
                leverTrim = min(1, max(0, leverTrim + leverStep))
                lever = min(1, max(0, leverTrim + speedError * 0.05))
            }
            step(pitch: pitch, throttle: lever, mode: mode)

            if tick >= averagedFrom {
                result.speed += state.forwardAirspeed
                result.verticalSpeed += state.velocity.y
                result.equivalentSpeed += state.forwardAirspeed * Self.densityRoot
                result.leverAsked += lever
                result.leverHeld += state.motorThrottle
                let engines = Float(uav?.powerplant?.engineCount ?? 1)
                result.shaftPowerKW += (state.engineRuntime?.shaftPowerKW ?? 0) * engines
                result.thrustNewtons += state.propulsionThrustNewtons
                samples += 1
            }
            if let settled, tick > 0, tick % Int(10.0 / Self.dt) == 0 {
                let finished = settled(state.forwardAirspeed, speedTenSecondsAgo)
                speedTenSecondsAgo = state.forwardAirspeed
                if finished, tick >= Int(30.0 / Self.dt) {
                    result.endAltitude = state.position.y
                    result.endSpeed = state.forwardAirspeed
                    if samples == 0 { result.speed = state.forwardAirspeed; samples = 1 }
                    break
                }
            }
            result.endAltitude = state.position.y
            result.endSpeed = state.forwardAirspeed
        }
        if samples > 0 {
            result.speed /= samples
            result.verticalSpeed /= samples
            result.equivalentSpeed /= samples
            result.leverAsked /= samples
            result.leverHeld /= samples
            result.shaftPowerKW /= samples
            result.thrustNewtons /= samples
        }
        return result
    }

    // MARK: - Measurements

    /// Power-off stall speed: the slowest steady glide the wing flies attached.
    ///
    /// ⚠️ Glides at a held attitude, with no loop of the rig's own in the measurement. Two closed
    /// loops were tried first — lever for speed, then elevator for speed with lever for height —
    /// and each put its own failure on the card: near the stall an aircraft is on the back of its
    /// power curve, and a Heron TP "stalled" at 51 and then 59 m/s against a wing that stalls at
    /// 45, while the heaviest airframes never settled inside the run at all. A glide has nothing
    /// to tune. The attitude is held by the solver's own loop, the speed finds itself, and the
    /// angle of attack is read off the flight path.
    ///
    /// Reported in equivalent airspeed: the declared figure is a sea-level one, and at 300 m the
    /// same wing needs 1.5 % more true airspeed.
    func measureStallSpeed() -> Float? {
        let declared = wing.minSustainableSpeedMps
        guard declared > 0 else { return nil }
        // An airframe with lift rotors of its own has no power-off glide to measure: the solver
        // keeps its cruise propeller on a floor near the stall and brings the rotors in under an
        // unloading wing, which is what such an aircraft is for. What comes out of a glide there
        // is how slowly the pair of them fly it, 30–40 % under the wing's own figure.
        guard !profile.propulsionUnitTemplate.contains(where: { $0.role == .liftRotor }) else { return nil }
        // Half a degree inside the stall angle, so the glide measured is the last attached one.
        let wanted = aero.stallAlphaRad - 0.009
        var low: Float = -0.05
        var high: Float = 0.45
        // The nose held as high as it will go. A steady glide there, still short of the stall
        // angle, means the attitude limit stops the wing before its stall does.
        if let steepest = steadyGlide(pitch: high), steepest.alpha < wanted {
            return steepest.equivalentSpeed
        }
        var best: Float?
        for _ in 0..<8 {
            let middle = (low + high) / 2
            // No steady glide at this attitude is the far side of the stall.
            guard let glide = steadyGlide(pitch: middle), glide.alpha < wanted else {
                high = middle
                continue
            }
            low = middle
            best = glide.equivalentSpeed
        }
        return best
    }

    private struct Glide {
        let equivalentSpeed: Float
        let alpha: Float
    }

    /// Lever closed, one pitch attitude held until the speed has stopped moving; `nil` if it
    /// never does, which past the stall is the usual outcome.
    private func steadyGlide(pitch: Float) -> Glide? {
        // From 1,500 m: a six-tonne aircraft near its stall comes down at four to eight metres
        // a second, and from the usual 300 m it was on the ground before it had settled.
        let entry = wing.minSustainableSpeedMps * 1.3
        reset(speed: entry, mode: .manual, altitude: 1_500.0)
        // A phugoid takes π√2·V/g seconds; three of them to settle, the last one averaged.
        let period = max(6.0, 0.453 * entry)
        let total = Int(min(150.0, 3.0 * period + 10.0) / Self.dt)
        let averagedFrom = total - Int(period / Self.dt)
        var speed: Float = 0, alpha: Float = 0, samples: Float = 0
        var slowest = Float.greatestFiniteMagnitude, fastest: Float = 0
        for tick in 0..<total {
            step(pitch: pitch, throttle: 0.0, mode: .manual)
            guard tick >= averagedFrom else { continue }
            let planar = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
            let path = atan2(state.velocity.y, max(1.0, planar))
            // Equivalent airspeed sample by sample: the glide loses several hundred metres.
            let density = AtmosphereModel.standard.state(altitudeMeters: state.position.y).airDensity
            speed += state.forwardAirspeed * (density / AtmosphereModel.seaLevelDensity).squareRoot()
            alpha += state.orientation.y - path
            slowest = min(slowest, state.forwardAirspeed)
            fastest = max(fastest, state.forwardAirspeed)
            samples += 1
        }
        guard samples > 0, state.position.y > 5.0 else { return nil }
        speed /= samples
        alpha /= samples
        // Still swinging by more than a twentieth of its speed: not a steady glide.
        guard fastest - slowest < speed * 0.05 else { return nil }
        return Glide(equivalentSpeed: speed, alpha: alpha)
    }

    struct Cruise {
        let speed: Float
        let leverAsked: Float
        let leverHeld: Float
        let enduranceHours: Float?
    }

    /// Level cruise under a guided mode, tanks half full: the speed the aircraft settles at when
    /// its published cruise is asked for, and how long its energy lasts there.
    func measureCruise() -> Cruise? {
        reset(speed: wing.cruiseSpeedMps, mode: .autoPath, tankFraction: 0.5, altitude: workingAltitude)
        let flown = flyLevel(holdingSpeed: wing.cruiseSpeedMps, lever: nil, mode: .autoPath,
                             seconds: 150, averagedSeconds: 40, height: workingAltitude)
        guard flown.heldHeight(within: 15.0) else { return nil }
        return Cruise(speed: flown.speed, leverAsked: flown.leverAsked, leverHeld: flown.leverHeld,
                      enduranceHours: enduranceHours(cruise: flown))
    }

    /// The lever the flight baseline calls cruise: what the battery's declared endurance refers to.
    private var cruiseReferenceThrottle: Float {
        FlightBaselineResolver.resolve(
            runtimeProfile: profile, activeUAVProfile: uav, vehicleMassModel: massModel, flightMode: .autoPath
        ).cruiseReferenceThrottle
    }

    private func enduranceHours(cruise: LevelFlight) -> Float? {
        if let powerplant = uav?.powerplant, powerplant.energySource == .fuel, let fuel = powerplant.fuel {
            let air = AtmosphereModel.standard.state(altitudeMeters: workingAltitude)
            var tanks = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
            tanks = FuelBurnService().update(
                current: tanks,
                input: FuelBurnInput(
                    powerplant: powerplant, throttle: cruise.leverHeld, engineRunning: true, atmosphere: air,
                    leakKgPerSec: 0.0,
                    shaftPowerKW: powerplant.drivesPropeller
                        ? cruise.shaftPowerKW / Float(max(1, powerplant.engineCount)) : nil,
                    thrustNewtons: powerplant.drivesPropeller ? nil : cruise.thrustNewtons),
                deltaTime: 1.0)
            guard tanks.flowKgPerHour > 0 else { return nil }
            return fuel.usableFuelMassKg / tanks.flowKgPerHour
        }
        guard profile.batteryEnergyWh > 0 else { return nil }
        let drawn = BatteryThermalSimulationService().updateBattery(
            current: .full,
            input: BatteryComputationInput(
                droneProfile: profile, weather: .normal, damageState: .pristine, speedMps: cruise.speed,
                verticalSpeedMps: 0.0, throttle: cruise.leverHeld, maneuverAggressiveness: 0.0,
                propulsionDrawsFromBattery: true, cruiseReferenceThrottle: cruiseReferenceThrottle),
            deltaTime: 1.0)
        guard drawn.powerDrawW > 0 else { return nil }
        return profile.batteryEnergyWh / drawn.powerDrawW
    }

    struct Hover {
        /// The lever the flight baseline locks a hover at.
        let declaredLever: Float
        let lever: Float
        let enduranceHours: Float?
    }

    /// A hybrid in its hover mode at 300 m, from rest: the lever it settles on, and how long the
    /// pack lasts there. `nil` for a fixed wing, a tailsitter, and a hover that does not hold.
    func measureHover() -> Hover? {
        guard isHybrid, profile.airframeStyle != .tailsitterVTOL else { return nil }
        let baseline = FlightBaselineResolver.resolve(
            runtimeProfile: profile, activeUAVProfile: uav, vehicleMassModel: massModel, flightMode: .hover)
        var fresh = DroneState(
            position: SIMD3<Float>(0, Self.altitude, 0), velocity: .zero, orientation: .zero, angularVelocity: .zero,
            throttle: baseline.hoverLockThrottle, motorThrottle: baseline.hoverLockThrottle,
            rotorAngularSpeed: .zero, forwardAirspeed: 0, physicalState: .airborne, mode: .hover)
        fresh.armState = .armed
        fresh.motionState = .airborne
        fresh.attitudeQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        fresh.propulsionUnits = profile.propulsionUnitTemplate
        fresh.mechanization.gearExtension = 0
        state = fresh
        fuelState = nil

        let seconds: Float = 12, averagedSeconds: Float = 4
        let total = Int(seconds / Self.dt), averagedFrom = total - Int(averagedSeconds / Self.dt)
        var lever: Float = 0, samples: Float = 0
        for tick in 0..<total {
            let control = DroneControlInput(
                targetPosition: SIMD3<Float>(0, Self.altitude, 0), targetOrientation: .zero, yawIntent: 0.0,
                throttle: baseline.hoverLockThrottle, isArmed: true, mode: .hover, controlMode: .hoverAssist,
                vtolTransitionLever: 0.0, landingGearDownCommand: false)
            let context = DroneSimulationContext(
                profile: profile, activeUAVProfile: uav, weather: .normal, damageState: .pristine,
                batteryState: .full, collisionRisk: 0.0, windVector: .zero, vehicleMassModel: massModel)
            state = solver.step(state: state, control: control, context: context, deltaTime: Self.dt)
            if tick >= averagedFrom { lever += state.motorThrottle; samples += 1 }
        }
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        guard samples > 0, abs(state.position.y - Self.altitude) < 3.0, abs(state.velocity.y) < 0.3, planarSpeed < 1.0 else {
            return nil
        }
        lever /= samples

        var enduranceHours: Float?
        if profile.batteryEnergyWh > 0, uav?.powerplant?.energySource != .fuel {
            let drawn = BatteryThermalSimulationService().updateBattery(
                current: .full,
                input: BatteryComputationInput(
                    droneProfile: profile, weather: .normal, damageState: .pristine, speedMps: 0.0,
                    verticalSpeedMps: 0.0, throttle: lever, maneuverAggressiveness: 0.0,
                    propulsionDrawsFromBattery: true, rotorBorneFraction: 1.0,
                    cruiseReferenceThrottle: cruiseReferenceThrottle),
                deltaTime: 1.0)
            if drawn.powerDrawW > 0 { enduranceHours = profile.batteryEnergyWh / drawn.powerDrawW }
        }
        return Hover(declaredLever: baseline.hoverLockThrottle, lever: lever, enduranceHours: enduranceHours)
    }

    /// Full power, height held, until the speed stops rising.
    func measureMaximumSpeed() -> Float? {
        reset(speed: wing.cruiseSpeedMps, mode: .manual, altitude: workingAltitude)
        let flown = flyLevel(holdingSpeed: nil, lever: 1.0, mode: .manual, seconds: 360, averagedSeconds: 5,
                             height: workingAltitude) {
            now, tenSecondsAgo in abs(now - tenSecondsAgo) < 0.15
        }
        guard abs(flown.endAltitude - workingAltitude) < 50.0 else { return nil }
        return flown.endSpeed
    }

    /// Full power at the climb speed; the rate at which the aircraft gains energy once settled.
    /// Height plus V²/2g, so that trading one for the other cannot flatter the figure.
    func measureClimbRate() -> Float? {
        reset(speed: wing.climbAirspeed, mode: .autoPath)
        var trim: Float = wing.initialClimbPitchDeg * .pi / 180.0
        let settle = Int(30.0 / Self.dt), total = Int(50.0 / Self.dt)
        var energyAtStart: Float = 0
        for tick in 0..<total {
            let speedError: Float = state.forwardAirspeed - wing.climbAirspeed
            trim = min(0.45, max(-0.10, trim + speedError * 0.004 * Self.dt))
            let pitch: Float = min(0.45, max(-0.10, trim + speedError * 0.02))
            if tick == settle { energyAtStart = energyHeight }
            step(pitch: pitch, throttle: 1.0, mode: .autoPath)
        }
        return (energyHeight - energyAtStart) / (Float(total - settle) * Self.dt)
    }

    /// Lever closed at the cruise speed: distance covered for height lost.
    func measureGlideRatio() -> Float? {
        reset(speed: wing.cruiseSpeedMps, mode: .manual)
        var trim: Float = 0.0
        let settle = Int(25.0 / Self.dt), total = Int(40.0 / Self.dt)
        var heightAtStart: Float = 0, distanceAtStart: Float = 0
        for tick in 0..<total {
            let speedError: Float = state.forwardAirspeed - wing.cruiseSpeedMps
            trim = min(0.30, max(-0.40, trim + speedError * 0.004 * Self.dt))
            let pitch: Float = min(0.30, max(-0.40, trim + speedError * 0.02))
            if tick == settle {
                heightAtStart = state.position.y
                distanceAtStart = -state.position.z
            }
            step(pitch: pitch, throttle: 0.0, mode: .manual)
        }
        let lost = heightAtStart - state.position.y
        guard lost > 0.5 else { return nil }
        return (-state.position.z - distanceAtStart) / lost
    }

    private var energyHeight: Float {
        state.position.y + simd_length_squared(state.velocity) / (2 * 9.81)
    }
}

/// A multirotor on the solver, hovering at 300 m: the rig its flight card is flown on.
final class RotorTestRig {
    let profile: DroneModelProfile
    let uav: UAVProfile?
    let flownMassKg: Float
    /// The lever the flight baseline locks a hover at.
    let declaredHoverLever: Float

    private let massModel: VehicleMassModel
    private let solver = SimpleDronePhysicsEngine(logsStartup: false)
    private var state: DroneState = .initial

    private static let dt: Float = 1.0 / 60.0
    static let altitude: Float = 300.0

    init?(profile: DroneModelProfile) {
        guard profile.airframeClass == .multirotor else { return nil }
        self.profile = profile
        uav = profile.resolvedUAVProfile
        massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
        flownMassKg = massModel.resolvedCurrentTotalMass
        declaredHoverLever = FlightBaselineResolver.resolve(
            runtimeProfile: profile, activeUAVProfile: uav, vehicleMassModel: massModel, flightMode: .hover
        ).hoverLockThrottle
        reset(lever: declaredHoverLever)
    }

    private func reset(lever: Float, pitch: Float = 0) {
        var fresh = DroneState(
            position: SIMD3<Float>(0, Self.altitude, 0),
            velocity: .zero,
            orientation: SIMD3<Float>(0, pitch, 0),
            angularVelocity: .zero,
            throttle: lever,
            // Spooled up: the card measures the aircraft, not the ramp.
            motorThrottle: lever,
            rotorAngularSpeed: .zero,
            forwardAirspeed: 0,
            physicalState: .airborne,
            mode: .manual
        )
        fresh.armState = .armed
        fresh.attitudeQuat = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
        state = fresh
    }

    private func step(pitch: Float, lever: Float) {
        let control = DroneControlInput(
            targetPosition: state.position,
            targetOrientation: SIMD3<Float>(0, pitch, 0),
            yawIntent: 0.0,
            throttle: lever,
            isArmed: true,
            mode: .manual,
            controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: profile,
            activeUAVProfile: uav,
            weather: .normal,
            damageState: .pristine,
            batteryState: .full,
            collisionRisk: 0.0,
            windVector: .zero,
            vehicleMassModel: massModel
        )
        state = solver.step(state: state, control: control, context: context, deltaTime: Self.dt)
    }

    private struct Held {
        var lever: Float = 0
        var sink: Float = 0
        var speed: Float = 0
    }

    /// Holds the height with the lever at one lean; means over the last `averagedSeconds`.
    private func holdHeight(pitch: Float, startLever: Float, seconds: Float, averagedSeconds: Float) -> Held {
        var held = Held()
        var trim = startLever
        var samples: Float = 0
        let total = Int(seconds / Self.dt), averagedFrom = total - Int(averagedSeconds / Self.dt)
        for tick in 0..<total {
            let heightError: Float = Self.altitude - state.position.y
            trim = min(1, max(0, trim + heightError * 0.02 * Self.dt))
            let raw: Float = trim + heightError * 0.04 - state.velocity.y * 0.08
            let lever: Float = min(1, max(0, raw))
            step(pitch: pitch, lever: lever)
            guard tick >= averagedFrom else { continue }
            held.lever += lever
            held.sink += state.velocity.y
            held.speed += simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
            samples += 1
        }
        held.lever /= samples
        held.sink /= samples
        held.speed /= samples
        return held
    }

    /// The lever the aircraft sits still on.
    func measureHoverLever() -> Float? {
        reset(lever: declaredHoverLever)
        let held = holdHeight(pitch: 0, startLever: declaredHoverLever, seconds: 14, averagedSeconds: 4)
        guard abs(held.sink) < 0.2, abs(state.position.y - Self.altitude) < 2.0 else { return nil }
        return held.lever
    }

    /// Lever fully open from the hover, level; the vertical speed it settles at.
    func measureClimbRate(hoverLever: Float?) -> Float? {
        reset(lever: hoverLever ?? declaredHoverLever)
        var rate: Float = 0, samples: Float = 0
        let total = Int(9.0 / Self.dt), averagedFrom = Int(6.0 / Self.dt)
        for tick in 0..<total {
            step(pitch: 0, lever: 1.0)
            if tick >= averagedFrom {
                rate += state.velocity.y
                samples += 1
            }
        }
        return rate / samples
    }

    /// The fastest level flight: leaned as far as an assisted mode leans, height held with the
    /// lever, and the lean eased only if the lever runs out before the height is held.
    func measureMaximumSpeed(hoverLever: Float?) -> Float? {
        var lean: Float = 36.0 * .pi / 180.0
        for _ in 0..<6 {
            // Nose down is negative pitch in this frame.
            reset(lever: hoverLever ?? declaredHoverLever, pitch: -lean)
            let held = holdHeight(pitch: -lean, startLever: hoverLever ?? declaredHoverLever, seconds: 30, averagedSeconds: 5)
            if abs(held.sink) < 0.5, held.lever < 0.99 { return held.speed }
            lean *= 0.85
        }
        return nil
    }

    /// How long the battery holds the hover.
    func hoverEnduranceHours(lever: Float) -> Float? {
        guard profile.batteryEnergyWh > 0 else { return nil }
        let drawn = BatteryThermalSimulationService().updateBattery(
            current: .full,
            input: BatteryComputationInput(
                droneProfile: profile, weather: .normal, damageState: .pristine, speedMps: 0.0,
                verticalSpeedMps: 0.0, throttle: lever, maneuverAggressiveness: 0.0,
                propulsionDrawsFromBattery: true),
            deltaTime: 1.0)
        guard drawn.powerDrawW > 0 else { return nil }
        return profile.batteryEnergyWh / drawn.powerDrawW
    }
}
