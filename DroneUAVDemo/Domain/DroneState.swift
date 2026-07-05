import simd

/// Identity attitude (no rotation), used as the default/reset value for
/// `DroneState.fixedWingOrientationQuat`.
private let identityOrientationQuat = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

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
    var orientation: SIMD3<Float> // roll, pitch, yaw in radians. Multirotor: authoritative. Fixed-wing: derived display copy of fixedWingOrientationQuat (see note below).
    var angularVelocity: SIMD3<Float> // multirotor: Euler-rate d(orientation)/dt. Fixed-wing: unused, see bodyAngularVelocity.
    var throttle: Float
    var motorThrottle: Float
    var rotorAngularSpeed: SIMD4<Float> // rad/s for FL, FR, RL, RR (unused channels ignored by non-quad)
    var forwardAirspeed: Float
    var physicalState: DronePhysicalState
    var mode: DroneFlightMode

    // MARK: - Fixed-wing 6DOF state
    //
    // Fixed-wing flight is integrated with this quaternion as the source of
    // truth (no Euler gimbal lock at pitch = ±90°, which a sustained acro loop
    // must pass through). `orientation` above is re-derived from this every
    // fixed-wing substep purely for rendering/telemetry/autopilot call sites
    // that still read Euler angles — it must never be fed back into the
    // physics integration for fixed-wing aircraft.
    var fixedWingOrientationQuat: simd_quatf = identityOrientationQuat
    /// True body-frame angular rates (p, q, r) in rad/s. Fixed-wing only.
    var bodyAngularVelocity: SIMD3<Float> = .zero
    /// Angle of attack, radians. Fixed-wing telemetry/debug only.
    var angleOfAttack: Float = 0.0
    /// Sideslip angle, radians. Fixed-wing telemetry/debug only.
    var sideslipAngle: Float = 0.0

    /// Actual (servo-rate-limited) control surface positions, -1...1
    /// fraction of max deflection — distinct from the instantaneously
    /// *commanded* fraction, since a real actuator can't snap to a new
    /// position in one tick. Applies to manual and autopilot input alike
    /// (it's a property of the servo, not of who is commanding it).
    /// Fixed-wing only.
    var elevatorDeflection: Float = 0.0
    var aileronDeflection: Float = 0.0
    var rudderDeflection: Float = 0.0

    // MARK: - hybridVTOL propulsion units
    //
    // Mutable per-unit simulation state (tilt angle, spin rate) seeded from
    // the profile's static `propulsionUnitTemplate` on arm/spawn/reset. Empty
    // for airframes that aren't hybridVTOL.
    var propulsionUnits: [PropulsionUnit] = []
    /// 0 = hover, 1 = cruise. Mean tilt of `tiltRotor` units / (pi/2) —
    /// indicates servo *position*, not force balance (see vtolWingborneBlend).
    var vtolTransitionProgress: Float = 0.0
    var vtolPhase: VTOLFlightPhase = .hover
    /// 0...1: what fraction of the aircraft's weight the wing is *actually*
    /// carrying right now (smoothed, asymmetric: hands over to the wing
    /// slowly, re-engages rotors fast on lift loss). This — not tilt
    /// geometry — is the master hover<->cruise blend for hybridVTOL physics.
    var vtolWingborneBlend: Float = 0.0
    /// Raw wingLift/weight from the last tick. Telemetry for the future HUD.
    var vtolWingLiftRatio: Float = 0.0
    /// true when the pilot's lever demanded forward tilt this tick but the
    /// transition safety gate held or rolled the servo back.
    var vtolTransitionBlocked: Bool = false

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
        mode: .manual,
        fixedWingOrientationQuat: identityOrientationQuat,
        bodyAngularVelocity: .zero,
        angleOfAttack: 0.0,
        sideslipAngle: 0.0,
        elevatorDeflection: 0.0,
        aileronDeflection: 0.0,
        rudderDeflection: 0.0
    )
}
