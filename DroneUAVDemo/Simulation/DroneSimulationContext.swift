import Foundation
import simd

enum FixedWingLaunchDynamicsPhase: Equatable {
    case held
    case catapultRail
    case handRelease
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
        groundHeight: Float = 0.0
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
    }
}
