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
    /// Share of the weight a hybrid is carrying on its rotors rather than on its wing, 0…1.
    /// Zero for everything that is not a hybrid in the air.
    let rotorBorneFraction: Float
    /// The lever the airframe holds its cruise on — the condition its declared endurance is
    /// quoted for. `nil` from a caller with no flight baseline to read it from.
    let cruiseReferenceThrottle: Float?

    init(
        droneProfile: DroneModelProfile,
        weather: WeatherModel,
        damageState: DamageState,
        speedMps: Float,
        verticalSpeedMps: Float,
        throttle: Float,
        maneuverAggressiveness: Float,
        propulsionDrawsFromBattery: Bool = true,
        rotorBorneFraction: Float = 0.0,
        cruiseReferenceThrottle: Float? = nil
    ) {
        self.droneProfile = droneProfile
        self.weather = weather
        self.damageState = damageState
        self.speedMps = speedMps
        self.verticalSpeedMps = verticalSpeedMps
        self.throttle = throttle
        self.maneuverAggressiveness = maneuverAggressiveness
        self.propulsionDrawsFromBattery = propulsionDrawsFromBattery
        self.rotorBorneFraction = rotorBorneFraction
        self.cruiseReferenceThrottle = cruiseReferenceThrottle
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
        // ⚠️ The declared figure is met in the condition it is declared for.
        //
        // The model was `energy / flight time` multiplied by a throttle term and a speed term that
        // are both above one in any flight at all — so the time on the datasheet was the time at
        // zero throttle and zero airspeed, and nothing ever flew for it. An aeroplane at its own
        // cruise drew 1.7–1.8 of the anchor and lasted 49–62 % of its declared endurance, all
        // fourteen of them; a multirotor in a hover lasted 68–76 % of its flight time, and the
        // hover time its entry declares separately was never read. A flight time under six
        // minutes was floored at six, so the racing quads flew half as long again as theirs.
        //
        // Each term is now taken relative to its value at the reference: the cruise speed and
        // cruise throttle for a wing, the hover throttle at rest for rotors.
        let profile = input.droneProfile
        let energy = profile.batteryEnergyWh
        let flightPower = energy / max(0.005, profile.maxFlightTimeMin / 60.0)
        let speedRatio = input.speedMps / max(0.1, profile.maxHorizontalSpeedMps)
        func throttleTerm(_ lever: Float) -> Float { 0.66 + lever * 1.24 }
        func linearSpeedTerm(_ ratio: Float) -> Float { 1.0 + ratio * 0.58 }

        let propulsionPower: Float
        if !input.propulsionDrawsFromBattery {
            // Avionics, servos and payload of a fuel aircraft: unchanged.
            propulsionPower = flightPower * 0.08 * linearSpeedTerm(speedRatio)
        } else {
            // On the wing: the declared endurance at cruise speed and cruise throttle. Without a
            // cruise throttle to refer to — a caller that has no flight baseline — the old terms.
            var wingPower = flightPower * linearSpeedTerm(speedRatio) * throttleTerm(input.throttle)
            if let cruiseLever = input.cruiseReferenceThrottle, let wing = profile.fixedWingParameters {
                let cruiseRatio = wing.cruiseSpeedMps / max(0.1, profile.maxHorizontalSpeedMps)
                wingPower /= linearSpeedTerm(cruiseRatio) * throttleTerm(cruiseLever)
            }

            // On the rotors: the declared hover time at the hover throttle, and the declared
            // flight time at the speed a rotorcraft covers most ground on — 0.4 of its maximum,
            // where a rotor has left its own downwash and the airframe's drag has not yet come in.
            // The curve through those two and the old 1.58 at full speed dips below the hover for
            // a camera platform, whose flight time is the longer of the two, and only rises for a
            // racing quad, whose flight time is quoted for flying it hard.
            var rotorPower: Float?
            let hoverMinutes = profile.maxHoverTimeMin
            if hoverMinutes > 0, profile.hoverThrottle > 0.01 {
                let hoverPower = energy / max(0.005, hoverMinutes / 60.0)
                let flightOverHover = hoverMinutes / max(0.01, profile.maxFlightTimeMin)
                let linear = (flightOverHover - 1.0928) / 0.24
                let speedTerm = max(0.5, 1.0 + linear * speedRatio + (0.58 - linear) * speedRatio * speedRatio)
                rotorPower = hoverPower * speedTerm * throttleTerm(input.throttle) / throttleTerm(profile.hoverThrottle)
            }

            switch profile.airframeClass {
            case .multirotor:
                propulsionPower = rotorPower ?? wingPower
            case .fixedWing:
                propulsionPower = wingPower
            case .hybridVTOL:
                // A hybrid that declares how long it hovers is charged for hovering while it
                // hovers; one that does not — every catalogue hybrid — is charged at the rate of
                // its wing in a hover too, which is too little and is all its entry supports.
                let share = input.rotorBorneFraction.clamped(to: 0.0...1.0)
                if let rotorPower, hoverMinutes < profile.maxFlightTimeMin, share > 0 {
                    propulsionPower = wingPower + (rotorPower - wingPower) * share
                } else {
                    propulsionPower = wingPower
                }
            }
        }

        let verticalFactor = 1.0 + abs(input.verticalSpeedMps) / max(0.1, profile.maxVerticalSpeedMps) * 0.42
        let maneuverFactor = 1.0 + input.maneuverAggressiveness * 0.36
        let weatherFactor = input.weather.effectiveFactors.batteryDrainMultiplier
        let damageFactor = input.damageState.batteryPenaltyMultiplier

        let rawPowerDraw = propulsionPower * verticalFactor * maneuverFactor * weatherFactor * damageFactor
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
