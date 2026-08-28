import Foundation
import simd

enum FixedWingLaunchDynamicsPhase: Equatable {
    case held
    case catapultRail
    case handRelease
    /// Rocket booster driving the airframe out of a sealed canister and on past
    /// the muzzle. Unlike a catapult rail, the push continues after the airframe
    /// is free of the tube, and the aircraft's own engine is not yet running.
    case canisterBoost
}

/// A deterministic physics command produced by the launch state machine.
/// SceneKit only mirrors its progress; it never drives aircraft movement.
struct FixedWingLaunchDynamics: Equatable {
    let launchID: UUID
    let mode: LaunchMode
    let phase: FixedWingLaunchDynamicsPhase
    let origin: SIMD3<Float>
    let direction: SIMD3<Float>
    let worldYawRadians: Float
    let pitchRadians: Float
    let travelLengthMeters: Float
    let targetReleaseSpeedMps: Float
    let maximumAccelerationMps2: Float
    /// Mass for which the launcher reaches `maximumAccelerationMps2`.
    /// Heavier installed configurations therefore accelerate less on the
    /// same rail instead of receiving free, mass-independent force.
    let nominalLaunchMassKg: Float
}

struct DroneSimulationContext {
    let profile: DroneModelProfile
    let activeUAVProfile: UAVProfile?
    let weather: WeatherModel
    let damageState: DamageState
    let batteryState: BatteryState
    let collisionRisk: Float
    let windVector: SIMD3<Float>
    let vehicleMassModel: VehicleMassModel
    let fixedWingLaunchDynamics: FixedWingLaunchDynamics?
    /// Optional hard ceiling for conventional fixed-wing propulsion. Safety governors use this
    /// when the aircraft must decelerate; applying it in the physics layer prevents the ordinary
    /// airborne throttle floor from silently raising the command again. `nil` preserves the
    /// normal flight-mode floor and all existing callers' behaviour.
    let fixedWingThrottleCeiling: Float?
    /// Component-graph-derived rigid-body summary (CoM offset, inertia) for
    /// contact impulses and the uncontrolled-tumble integrator.
    let vehicleMassProperties: VehicleMassProperties
    /// Multi-sphere physical contact profile of the built visual. Empty
    /// profile falls back to the legacy single-point ground clamp.
    let contactProfile: VehicleContactProfile
    /// Per-rotor thrust model with damage/failure factors baked in — the
    /// multirotor mixer and VTOL per-unit thrust sums consume this. Empty
    /// model keeps the legacy single-virtual-rotor math.
    let rotorModel: VehicleRotorModel
    /// Aerodynamic deltas from structural damage (wing sections, tails).
    let aeroDamage: FixedWingAeroDamage
    /// Control surfaces seized by servo/structure failures: channel ->
    /// frozen deflection fraction, bypassing command and slew.
    let jammedSurfaces: [FlightSurfaceChannel: Float]
    /// Functional derating independent from stored charge/integrity. Battery
    /// faults reduce available propulsion power; controller faults reduce
    /// closed-loop command authority while the airframe remains simulated.
    let powerSystemFactor: Float
    let controlSystemFactor: Float

    /// Elevation of the surface directly beneath the aircraft, in world metres.
    ///
    /// Zero for the procedural presets, whose ground genuinely is the y = 0 plane. An imported
    /// photogrammetric world supplies the real height here, which is what lets the aircraft rest on
    /// a shoreline, a quay or a hillside instead of on an invisible plane at the origin's elevation.
    ///
    /// This is a *transport*, not a second opinion: the value is produced by the same
    /// `supportSurfaceY` query the view model already uses for rooftops, because the physics engine
    /// has no access to the scene and cannot ask for itself. Defaulted so every procedural
    /// construction site keeps compiling and behaving exactly as before.
    var groundHeight: Float = 0.0

    /// Ambient air the aerodynamics are evaluated in. Defaults to the standard
    /// sea-level day, which is exactly the constant every dynamic-pressure
    /// calculation used before this existed — so a caller that does not supply
    /// one gets the previous behaviour unchanged.
    var atmosphere: AtmosphereModel = .standard

    /// Live fuel quantity, for aircraft that burn it. `nil` means the aircraft is
    /// battery-electric, which is every profile that predates the fuel work.
    var fuelState: FuelSystemState?

    /// Live engine state for a fuel aircraft: where it is in its start sequence,
    /// shaft speed, delivered power and temperature. `nil` for electric aircraft,
    /// which have no start sequence to model.
    var engineState: EngineRuntimeState?

    /// Physical propulsion chain — engine torque against propeller torque, or a
    /// turbojet's spool. Present only for fuel aircraft; battery-electric profiles
    /// keep the calibrated thrust backend untouched.
    var fuelPropulsion: FuelPropulsionBackend?

    /// Thrust and telemetry from that chain, resolved once per substep by the
    /// physics engine.
    var propulsionOutput: PropulsionOutput?

    /// True when the aircraft flies on a physical engine/propeller chain rather
    /// than the weight-derived calibrated thrust.
    var usesPhysicalPropulsion: Bool {
        fuelPropulsion != nil && engineState != nil
    }

    /// Whether propulsion has any energy left to draw on, whichever kind it uses.
    /// The plan's `energyUnsafe` in miniature: fixed-wing thrust used to be gated
    /// on `batteryState.isDepleted` alone, which is meaningless for an engine
    /// fed from a tank.
    var isEnergyDepleted: Bool {
        if let fuelState {
            return fuelState.isStarved
        }
        return batteryState.isDepleted
    }

    /// Is propulsion actually able to produce thrust right now? For a fuel
    /// aircraft an armed throttle means nothing until the engine is firing.
    var isPropulsionLive: Bool {
        if let engineState {
            return engineState.runState.isFiring
        }
        return !batteryState.isDepleted
    }

    /// Derating applied to available propulsion. Voltage sag is a battery
    /// phenomenon and must not be charged to a piston engine; a fuel aircraft
    /// keeps only the component-failure factor.
    var propulsionAvailabilityFactor: Float {
        let functional = min(1.0, max(0.0, powerSystemFactor))
        guard fuelState == nil else {
            return functional
        }
        return functional * batteryState.voltageSagFactor
    }

    init(
        profile: DroneModelProfile,
        activeUAVProfile: UAVProfile?,
        weather: WeatherModel,
        damageState: DamageState,
        batteryState: BatteryState,
        collisionRisk: Float,
        windVector: SIMD3<Float>,
        vehicleMassModel: VehicleMassModel,
        fixedWingLaunchDynamics: FixedWingLaunchDynamics? = nil,
        fixedWingThrottleCeiling: Float? = nil,
        vehicleMassProperties: VehicleMassProperties = .fallback,
        contactProfile: VehicleContactProfile = .empty,
        rotorModel: VehicleRotorModel = .empty,
        aeroDamage: FixedWingAeroDamage = .pristine,
        jammedSurfaces: [FlightSurfaceChannel: Float] = [:],
        powerSystemFactor: Float = 1.0,
        controlSystemFactor: Float = 1.0,
        groundHeight: Float = 0.0,
        atmosphere: AtmosphereModel = .standard,
        fuelState: FuelSystemState? = nil,
        engineState: EngineRuntimeState? = nil,
        fuelPropulsion: FuelPropulsionBackend? = nil
    ) {
        self.profile = profile
        self.activeUAVProfile = activeUAVProfile
        self.weather = weather
        self.damageState = damageState
        self.batteryState = batteryState
        self.collisionRisk = collisionRisk
        self.windVector = windVector
        self.vehicleMassModel = vehicleMassModel
        self.fixedWingLaunchDynamics = fixedWingLaunchDynamics
        self.fixedWingThrottleCeiling = fixedWingThrottleCeiling
        self.vehicleMassProperties = vehicleMassProperties
        self.contactProfile = contactProfile
        self.rotorModel = rotorModel
        self.aeroDamage = aeroDamage
        self.jammedSurfaces = jammedSurfaces
        self.powerSystemFactor = powerSystemFactor
        self.controlSystemFactor = controlSystemFactor
        self.groundHeight = groundHeight
        self.atmosphere = atmosphere
        self.fuelState = fuelState
        self.engineState = engineState
        self.fuelPropulsion = fuelPropulsion
    }
}
