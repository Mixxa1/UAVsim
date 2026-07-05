import Foundation

struct DroneControlValues: Equatable {
    var x: Double = 0.0
    var y: Double = 0.0
    var z: Double = 0.0

    var roll: Double = 0.0
    var pitch: Double = 0.0
    var yaw: Double = 0.0

    var throttle: Double = 0.0

    /// -1...1. hybridVTOL transition lever: +1 drives tiltRotor units toward
    /// cruise, -1 toward hover, 0 holds the current tilt target. Ignored by
    /// non-hybridVTOL airframes.
    var vtolTransitionLever: Double = 0.0
}
