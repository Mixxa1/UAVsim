import Foundation

struct BatteryState {
    var chargePercent: Float
    var healthPercent: Float
    var powerDrawW: Float
    var remainingTimeSec: Float

    static let full = BatteryState(
        chargePercent: 100.0,
        healthPercent: 100.0,
        powerDrawW: 0.0,
        remainingTimeSec: 0.0
    )

    var isDepleted: Bool {
        chargePercent <= 0.1
    }
}
