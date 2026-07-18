import Foundation

struct BatteryState {
    var chargePercent: Float
    var healthPercent: Float
    var powerDrawW: Float
    var remainingTimeSec: Float
    /// Pack terminal voltage under the current load (open-circuit voltage minus the
    /// instantaneous internal-resistance sag) — see `BatteryThermalSimulationService`.
    var packVoltage: Float = 0.0
    var cellVoltage: Float = 0.0
    var currentDrawA: Float = 0.0
    /// Cumulative draw since arm/reset, real telemetry units.
    var mahDrawn: Float = 0.0
    /// Decaying extra sag (volts) from a recent current ramp — the punch-out dip, separate from
    /// steady-state resistive sag. See `BatteryThermalSimulationService`.
    var transientSagBoost: Float = 0.0

    static let full = BatteryState(
        chargePercent: 100.0,
        healthPercent: 100.0,
        powerDrawW: 0.0,
        remainingTimeSec: 0.0
    )

    var isDepleted: Bool {
        chargePercent <= 0.1
    }

    /// Thrust derating from voltage sag under load — a real motor's achievable RPM scales with
    /// applied voltage (Kv × V), so a punch-out's transient sag costs real thrust the same way it
    /// does on a physical airframe. 3.7V/cell is the nominal reference; floored so a deeply sagged
    /// pack derates authority hard without ever fully zeroing thrust from voltage alone (a
    /// depleted/failed battery still gates thrust to zero through the existing chargePercent/
    /// powerSystemFactor terms).
    var voltageSagFactor: Float {
        guard cellVoltage > 0.1 else { return 1.0 }
        return (cellVoltage / 3.7).clamped(to: 0.75...1.05)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
