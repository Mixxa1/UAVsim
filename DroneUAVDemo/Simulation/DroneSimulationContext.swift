import Foundation
import simd

struct DroneSimulationContext {
    let profile: DroneModelProfile
    let activeUAVProfile: UAVProfile?
    let weather: WeatherModel
    let damageState: DamageState
    let batteryState: BatteryState
    let collisionRisk: Float
    let windVector: SIMD3<Float>
    let vehicleMassModel: VehicleMassModel
}
