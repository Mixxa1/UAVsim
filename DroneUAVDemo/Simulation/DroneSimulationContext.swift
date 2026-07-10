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

    init(
        profile: DroneModelProfile,
        activeUAVProfile: UAVProfile?,
        weather: WeatherModel,
        damageState: DamageState,
        batteryState: BatteryState,
        collisionRisk: Float,
        windVector: SIMD3<Float>,
        vehicleMassModel: VehicleMassModel,
        fixedWingLaunchDynamics: FixedWingLaunchDynamics? = nil
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
    }
}
