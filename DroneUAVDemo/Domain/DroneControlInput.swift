import simd

struct DroneControlInput {
    var targetPosition: SIMD3<Float>
    var targetOrientation: SIMD3<Float> // roll, pitch, yaw in radians
    var yawIntent: Float // manual keyboard yaw command; positive = left, negative = right
    var throttle: Float
    var isArmed: Bool
    var mode: DroneFlightMode
    var controlMode: FlightControlMode
}
