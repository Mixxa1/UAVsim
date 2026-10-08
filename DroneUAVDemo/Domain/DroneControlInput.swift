import simd

struct DroneControlInput {
    var targetPosition: SIMD3<Float>
    var targetOrientation: SIMD3<Float> // roll, pitch, yaw in radians
    var yawIntent: Float // manual keyboard yaw command; positive = left, negative = right
    var throttle: Float
    var isArmed: Bool
    var mode: DroneFlightMode
    var controlMode: FlightControlMode

    /// -1...1. hybridVTOL transition lever: +1 drives tiltRotor units'
    /// targetTiltAngleRad toward cruise (pi/2), -1 toward hover (0), 0 holds
    /// the current target. Ignored by non-hybridVTOL airframes.
    var vtolTransitionLever: Float = 0.0
    /// Flap lever, 0…1 of full travel. `nil` is a lever nobody has moved, which is up.
    var flapCommand: Float? = nil
    /// Undercarriage lever. `nil` is a lever nobody has moved, which is down.
    ///
    /// Neither lever is ever scheduled by a flight mode or held back by a protection: flaps and
    /// legs go where the operator puts them, at any height and speed, and stay there through
    /// autopilot updates.
    var landingGearDownCommand: Bool? = nil
}
