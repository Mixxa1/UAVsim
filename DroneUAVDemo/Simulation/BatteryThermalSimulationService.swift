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
    /// Does propulsion actually draw from this battery?
    ///
    /// False for a fuel aircraft, where the pack runs avionics and servos and the
    /// engine burns fuel. Without this distinction the model sized the draw from
    /// `batteryEnergyWh / maxFlightTimeMin` as though the battery flew the
    /// aircraft: on the NC State BWB DELTA — a turbojet with a twelve-minute
    /// endurance — that came out as 2.5 kW from a six-cell pack, roughly 113 A,
    /// which cooked the battery twice in a row on the ramp.
    let propulsionDrawsFromBattery: Bool

    init(
        droneProfile: DroneModelProfile,
        weather: WeatherModel,
        damageState: DamageState,
        speedMps: Float,
        verticalSpeedMps: Float,
        throttle: Float,
        maneuverAggressiveness: Float,
        propulsionDrawsFromBattery: Bool = true
    ) {
        self.droneProfile = droneProfile
        self.weather = weather
        self.damageState = damageState
        self.speedMps = speedMps
        self.verticalSpeedMps = verticalSpeedMps
        self.throttle = throttle
        self.maneuverAggressiveness = maneuverAggressiveness
        self.propulsionDrawsFromBattery = propulsionDrawsFromBattery
    }
}

final class BatteryThermalSimulationService {
    func updateBattery(
        current battery: BatteryState,
        input: BatteryComputationInput,
        deltaTime: Float
    ) -> BatteryState {
        var next = battery

        // An electric aircraft's pack carries the whole flight. A fuel aircraft's
        // carries avionics, servos and payload while the engine does the work, so
        // it draws a small fraction and is sized to outlast the tanks rather than
        // to move the airframe.
        let fullFlightPower = input.droneProfile.batteryEnergyWh / max(0.1, (input.droneProfile.maxFlightTimeMin / 60.0))
        let baseHoverPower = input.propulsionDrawsFromBattery
            ? fullFlightPower
            : fullFlightPower * 0.08

        let speedFactor = 1.0 + (input.speedMps / max(0.1, input.droneProfile.maxHorizontalSpeedMps)) * 0.58
        let verticalFactor = 1.0 + abs(input.verticalSpeedMps) / max(0.1, input.droneProfile.maxVerticalSpeedMps) * 0.42
        // Throttle only loads the pack when the pack is what turns the propellers.
        let throttleFactor = input.propulsionDrawsFromBattery
            ? 0.66 + input.throttle * 1.24
            : 1.0
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

        // --- Pack voltage: cell count (S) x open-circuit-voltage(SOC) minus sag. Two sag terms,
        // deliberately kept separate:
        //  - steady-state resistive sag (Ohm's law, current x internal resistance) — small at a
        //    sustained throttle, by design: it must never eat meaningfully into the thrust-ceiling
        //    ratio a climb depends on (that ceiling already has thin headroom above hover on many
        //    airframes, so even a "mild-sounding" 15-20% sag there reads as "barely climbs").
        //  - transient punch-out boost, proportional to how fast current is RISING (not its
        //    absolute level) and decaying over ~0.35s — the actual "cell voltage dips on a hard
        //    punch, then recovers" behavior, felt once per throttle step rather than as a
        //    permanent handicap while holding that throttle.
        // A worn/damaged pack sags harder under the same load — real internal resistance rises as
        // cells age or take damage.
        let cellCount = max(1, input.droneProfile.batteryCellCount)
        let stateOfCharge = (next.chargePercent / 100.0).clamped(to: 0.0...1.0)
        let openCircuitCellVoltage = Self.openCircuitVoltagePerCell(stateOfCharge: stateOfCharge)
        let healthFactor = (next.healthPercent / 100.0).clamped(to: 0.4...1.0)
        let internalResistancePerCell: Float = 0.010 / healthFactor * input.damageState.batteryPenaltyMultiplier
        let totalInternalResistance = internalResistancePerCell * Float(cellCount)
        // Current from the pack's own PREVIOUS voltage avoids a same-tick feedback loop (real
        // telemetry samples discretely too); falls back to the nominal pack voltage on the first
        // tick, when there is no previous reading yet.
        let referenceVoltage = battery.packVoltage > 1.0 ? battery.packVoltage : Float(cellCount) * 3.7
        let currentDrawA = next.powerDrawW / max(1.0, referenceVoltage)
        let openCircuitPackVoltage = openCircuitCellVoltage * Float(cellCount)

        let currentIncrease = max(0.0, currentDrawA - battery.currentDrawA)
        let transientDecay = max(0.0, 1.0 - deltaTime / 0.35)
        let transientSagBoost = max(
            currentIncrease * totalInternalResistance * 4.0,
            battery.transientSagBoost * transientDecay
        )
        next.transientSagBoost = transientSagBoost

        let steadySagVoltage = currentDrawA * totalInternalResistance
        let sagVoltage = min(openCircuitPackVoltage * 0.35, steadySagVoltage + transientSagBoost)
        next.packVoltage = max(1.0, openCircuitPackVoltage - sagVoltage)
        next.cellVoltage = next.packVoltage / Float(cellCount)
        next.currentDrawA = currentDrawA
        next.mahDrawn = battery.mahDrawn + currentDrawA * 1000.0 * deltaTime / 3600.0

        return next
    }

    /// Per-cell open-circuit voltage vs. state of charge, shaped like a real LiPo discharge curve:
    /// a steep drop from full to ~90%, a long flat plateau through the usable middle, then a
    /// steep final drop toward the empty floor — not the straight line a naive interpolation
    /// would give, which is what actually makes the low-battery HUD warning feel sudden on a
    /// real pack instead of gradual.
    private static func openCircuitVoltagePerCell(stateOfCharge: Float) -> Float {
        let soc = stateOfCharge.clamped(to: 0.0...1.0)
        let fullVoltage: Float = 4.20
        let plateauHighVoltage: Float = 3.85
        let plateauLowVoltage: Float = 3.70
        let emptyVoltage: Float = 3.20

        if soc > 0.9 {
            let t = (soc - 0.9) / 0.1
            return plateauHighVoltage + (fullVoltage - plateauHighVoltage) * t
        } else if soc > 0.2 {
            let t = (soc - 0.2) / 0.7
            return plateauLowVoltage + (plateauHighVoltage - plateauLowVoltage) * t
        } else {
            let t = soc / 0.2
            return emptyVoltage + (plateauLowVoltage - emptyVoltage) * t
        }
    }

    func updateThermal(
        current thermalState: ThermalState,
        throttle: Float,
        weather: WeatherModel,
        damageState: DamageState,
        collisionRisk: Float,
        maneuverAggressiveness: Float,
        deltaTime: Float,
        /// False for a fuel aircraft, whose battery, ESC and motors are not what
        /// the throttle lever commands. Heating them by it is the same mistake as
        /// draining the pack for propulsion — the engine's own heat is modelled
        /// separately, on the engine.
        propulsionDrawsFromBattery: Bool = true
    ) -> ThermalState {
        var next = thermalState
        let factors = weather.effectiveFactors
        let throttle = propulsionDrawsFromBattery ? throttle : throttle * 0.10

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
