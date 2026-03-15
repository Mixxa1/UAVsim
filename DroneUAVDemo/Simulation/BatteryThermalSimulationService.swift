import Foundation
import simd

struct BatteryComputationInput {
    let droneProfile: DroneModelProfile
    let weather: WeatherModel
    let damageState: DamageState
    let speedMps: Float
    let verticalSpeedMps: Float
    let throttle: Float
    let maneuverAggressiveness: Float
}

final class BatteryThermalSimulationService {
    func updateBattery(
        current battery: BatteryState,
        input: BatteryComputationInput,
        deltaTime: Float
    ) -> BatteryState {
        var next = battery

        let baseHoverPower = input.droneProfile.batteryEnergyWh / max(0.1, (input.droneProfile.maxFlightTimeMin / 60.0))

        let speedFactor = 1.0 + (input.speedMps / max(0.1, input.droneProfile.maxHorizontalSpeedMps)) * 0.58
        let verticalFactor = 1.0 + abs(input.verticalSpeedMps) / max(0.1, input.droneProfile.maxVerticalSpeedMps) * 0.42
        let throttleFactor = 0.66 + input.throttle * 1.24
        let maneuverFactor = 1.0 + input.maneuverAggressiveness * 0.36
        let weatherFactor = input.weather.effectiveFactors.batteryDrainMultiplier
        let damageFactor = input.damageState.batteryPenaltyMultiplier

        let rawPowerDraw = baseHoverPower * speedFactor * verticalFactor * throttleFactor * maneuverFactor * weatherFactor * damageFactor
        next.powerDrawW = rawPowerDraw

        let drainPercent = (rawPowerDraw * deltaTime / 3600.0) / max(0.1, input.droneProfile.batteryEnergyWh) * 100.0
        next.chargePercent = (battery.chargePercent - drainPercent).clamped(to: 0.0...100.0)

        let healthWear = drainPercent * 0.0005 + max(0, input.weather.severityScore - 0.58) * 0.0022
        next.healthPercent = (battery.healthPercent - healthWear).clamped(to: 65.0...100.0)

        if next.powerDrawW > 0.1 {
            let remainingHours = (next.chargePercent / 100.0) * input.droneProfile.batteryEnergyWh / next.powerDrawW
            next.remainingTimeSec = max(0.0, remainingHours * 3600.0)
        } else {
            next.remainingTimeSec = 0.0
        }

        return next
    }

    func updateThermal(
        current thermalState: ThermalState,
        throttle: Float,
        weather: WeatherModel,
        damageState: DamageState,
        collisionRisk: Float,
        maneuverAggressiveness: Float,
        deltaTime: Float
    ) -> ThermalState {
        var next = thermalState
        let factors = weather.effectiveFactors

        for component in DamageComponent.allCases {
            let currentTemp = thermalState.temperature(for: component)
            let healthPenalty = (1.0 - damageState.health(for: component)) * 0.85

            let componentLoad: Float
            switch component {
            case .battery:
                componentLoad = throttle * 0.82 + (factors.batteryDrainMultiplier - 1.0) * 1.45 + healthPenalty
            case .escPower:
                componentLoad = throttle * 1.08 + maneuverAggressiveness * 0.45 + healthPenalty
            case .flightControllerCore:
                componentLoad = maneuverAggressiveness * 0.55 + collisionRisk * 0.6 + healthPenalty
            case .frontCameraGimbal:
                componentLoad = (factors.sensorNoiseMultiplier - 1.0) * 0.68 + collisionRisk * 0.44 + healthPenalty * 0.5
            case .motorFL, .motorFR, .motorRL, .motorRR:
                componentLoad = throttle * 1.42 + maneuverAggressiveness * 0.62 + healthPenalty
            case .propellerFL, .propellerFR, .propellerRL, .propellerRR:
                componentLoad = throttle * 1.15 + collisionRisk * 0.35 + healthPenalty
            case .armFL, .armFR, .armRL, .armRR:
                componentLoad = throttle * 0.62 + healthPenalty * 1.2
            }

            let ambient = 23.0 + weather.severityScore * 9.0
            let targetTemp = ambient + componentLoad * 34.0
            let response = (deltaTime * 1.95).clamped(to: 0.0...1.0)
            let cooled = currentTemp + (targetTemp - currentTemp) * response

            next.temperatureByComponent[component] = cooled.clamped(to: 20.0...98.0)
        }

        return next
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
