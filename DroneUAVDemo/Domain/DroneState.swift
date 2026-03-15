import simd

enum DronePhysicalState: String, CaseIterable {
    case disarmed
    case armedOnGround
    case takeoffTransition
    case airborne
    case landing
    case landed
    case crashed

    var suppressesFullFlightAuthority: Bool {
        switch self {
        case .disarmed, .armedOnGround, .landed, .crashed:
            return true
        case .takeoffTransition, .airborne, .landing:
            return false
        }
    }

    var isGroundRestState: Bool {
        switch self {
        case .disarmed, .armedOnGround, .landed, .crashed:
            return true
        case .takeoffTransition, .airborne, .landing:
            return false
        }
    }

    var permitsRearm: Bool {
        self != .crashed
    }
}

struct DroneState {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var orientation: SIMD3<Float> // roll, pitch, yaw in radians
    var angularVelocity: SIMD3<Float>
    var throttle: Float
    var motorThrottle: Float
    var rotorAngularSpeed: SIMD4<Float> // rad/s for FL, FR, RL, RR (unused channels ignored by non-quad)
    var forwardAirspeed: Float
    var physicalState: DronePhysicalState
    var mode: DroneFlightMode

    static let initial = DroneState(
        position: SIMD3<Float>(0.0, 0.0, 0.0),
        velocity: SIMD3<Float>(repeating: 0.0),
        orientation: SIMD3<Float>(repeating: 0.0),
        angularVelocity: SIMD3<Float>(repeating: 0.0),
        throttle: 0.0,
        motorThrottle: 0.0,
        rotorAngularSpeed: SIMD4<Float>(repeating: 0.0),
        forwardAirspeed: 0.0,
        physicalState: .disarmed,
        mode: .manual
    )
}
