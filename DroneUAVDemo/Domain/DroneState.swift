import simd

/// Identity attitude (no rotation), used as the default/reset value for
/// `DroneState.attitudeQuat`.
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

/// Orthogonal physical state axes.  `DronePhysicalState` remains as the
/// compatibility lifecycle used by existing UI, while these values prevent
/// arming, movement, damage and control authority from being collapsed into
/// one terminal `crashed` flag.
enum UAVArmState: String, CaseIterable, Codable {
    case disarmed
    case armed
}

enum UAVMotionState: String, CaseIterable, Codable {
    case grounded
    case airborne
    case falling
    case tumbling
    case sliding
    case rolling
    case floating
    case settled
}

enum UAVDamageState: String, CaseIterable, Codable {
    case nominal
    case degraded
    case critical
    case uncontrolled
    case destroyed
}

enum UAVControlState: String, CaseIterable, Codable {
    case full
    case reduced
    case emergency
    case insufficient
    case none
}

struct DroneState {
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var orientation: SIMD3<Float> // roll, pitch, yaw in radians. Derived display copy of attitudeQuat for every airframe class (see note below).
    /// True body-frame angular rates in the engine's (roll, pitch, yaw) order — rotation about
    /// body Z, X and Y respectively — in rad/s. Multirotor only; fixed-wing uses
    /// `bodyAngularVelocity`.
    ///
    /// ⚠️ This used to hold the Euler rate `d(orientation)/dt`, which is a different quantity as
    /// soon as the aircraft is not level: a pitch command at 90° of bank rotated the airframe
    /// about a world axis instead of its own, off by 90°, and inverted it rotated the wrong way
    /// entirely. `ImpactResolutionService` was already reading this field as body rates when it
    /// converted an impact into world angular velocity, so the two halves of the simulator
    /// disagreed about what the number meant.
    var angularVelocity: SIMD3<Float>
    var throttle: Float
    var motorThrottle: Float
    var rotorAngularSpeed: SIMD4<Float> // rad/s for FL, FR, RL, RR (unused channels ignored by non-quad)
    var forwardAirspeed: Float
    var physicalState: DronePhysicalState
    var mode: DroneFlightMode
    var armState: UAVArmState = .disarmed
    var motionState: UAVMotionState = .grounded
    var damageCondition: UAVDamageState = .nominal
    var controlState: UAVControlState = .full

    // MARK: - 6DOF attitude state
    //
    // Every airframe class is integrated with this quaternion as the source of
    // truth (no Euler gimbal lock at pitch = ±90°, which a sustained acro loop
    // must pass through). `orientation` above is re-derived from this every
    // substep purely for rendering/telemetry/autopilot call sites that still
    // read Euler angles — it must never be fed back into the physics
    // integration.
    //
    // The multirotor path used to be the exception: it integrated the Euler
    // triple directly, which is only equivalent to rotating the body while the
    // aircraft is close to level. It is not an approximation that degrades
    // gracefully — at 90° of bank the pitch stick commanded an entirely
    // different axis, and inverted it commanded the opposite of what the pilot
    // asked for. Anything outside the physics step that forces `orientation`
    // must call the view model's `resyncAttitudeQuaternionFromEuler()`
    // afterward, or the next substep flies the stale attitude.
    var attitudeQuat: simd_quatf = identityOrientationQuat
    /// True body-frame angular rates (p, q, r) in rad/s. Fixed-wing and hybrid VTOL; the
    /// multirotor path keeps its body rates in `angularVelocity`.
    var bodyAngularVelocity: SIMD3<Float> = .zero
    /// Live engine state for a fuel-burning aircraft — where it is in its start
    /// sequence, shaft speed, delivered power and temperature. Lives on the state
    /// rather than on the engine object because it is physical state that has to
    /// survive across ticks and be recorded, not filter state. `nil` for every
    /// battery-electric aircraft, which has no start sequence to model.
    var engineRuntime: EngineRuntimeState?

    /// Angle of attack, radians. Fixed-wing telemetry/debug only.
    var angleOfAttack: Float = 0.0
    /// Sideslip angle, radians. Fixed-wing telemetry/debug only.
    var sideslipAngle: Float = 0.0

    /// Flight Mach number at the last physics substep.
    ///
    /// Published as state rather than recomputed by every reader because "speed" stops
    /// being one quantity above the tropopause: Mach governs compressibility, dynamic
    /// pressure governs loads, and true airspeed governs where the aircraft ends up.
    /// A warning that cannot tell an overspeed from an over-q is not a warning.
    var machNumber: Float = 0.0
    /// Dynamic pressure `q = ½ρV²` at the last physics substep, Pa.
    var dynamicPressurePa: Float = 0.0
    /// Equivalent airspeed, m/s — the sea-level speed that would give this dynamic
    /// pressure. At Mach 1.8 and 18 km an aircraft's true airspeed is 530 m/s and this
    /// is under 190; the structure only ever feels the second number.
    var equivalentAirspeedMps: Float = 0.0
    /// Wave-drag contribution to CD at the last substep, kept separate from the total
    /// so the drag breakdown the diagnostics need does not have to be inferred.
    var waveDragCoefficient: Float = 0.0
    /// Thrust actually applied to the airframe at the last substep, N.
    ///
    /// Published because it stopped being derivable from the throttle lever. A jet's
    /// thrust now depends on Mach, ambient pressure and what its intake recovers, so
    /// "throttle × rating" is no longer an answer — and the fuel model needs the real
    /// number rather than its own second guess at it.
    var propulsionThrustNewtons: Float = 0.0
    /// Total-pressure recovery the intake is achieving, 0...1. One for anything with a
    /// propeller and for any jet below Mach 1.
    var inletPressureRecovery: Float = 1.0

    /// Strength of the standing condensation cloud, 0-1.
    ///
    /// Purely a visual quantity — it changes nothing about the flight — but it is derived
    /// from the flow state and the air's water content rather than from a Mach threshold,
    /// so it appears when the air can actually condense and not merely when the aircraft
    /// is going fast.
    var condensationConeStrength: Float = 0.0
    /// Normal load factor, n = L/W, positive up. One in level flight, zero in free fall.
    ///
    /// Not the mass ratio that `FlightBaselineResolver.normalizedLoadFactor` carries
    /// under a similar name — that one is payload bookkeeping. This is the aerodynamic
    /// quantity a structural limit is written against.
    var loadFactor: Float = 1.0
    /// Skin, nose, leading-edge and intake-lip temperatures.
    var aeroThermal: AeroThermalState = .standard
    /// Where the aircraft sits inside its own limits, and which limit is closest.
    var flightEnvelope: FlightEnvelopeState = .nominal

    /// Actual (servo-rate-limited) control surface positions, -1...1
    /// fraction of max deflection — distinct from the instantaneously
    /// *commanded* fraction, since a real actuator can't snap to a new
    /// position in one tick. Applies to manual and autopilot input alike
    /// (it's a property of the servo, not of who is commanding it).
    /// Fixed-wing only.
    var elevatorDeflection: Float = 0.0
    var aileronDeflection: Float = 0.0
    var rudderDeflection: Float = 0.0

    /// Accumulated elevator trim, -1...1 fraction, held by the attitude loop.
    ///
    /// A pure proportional attitude loop always settles *short* of its commanded pitch: the
    /// airframe's own restoring moment (cmAlpha) grows with the angle, so there is an equilibrium
    /// where P output balances it. Measured on the eBee-class wing: commanded 11°, achieved 7.9° —
    /// a 28 % droop, which is the difference between a 1.4 m/s climb and a 0.35 m/s one. Real
    /// aircraft cancel it with trim; this is that trim, integrated and anti-wound.
    /// Fixed-wing only.
    var elevatorTrim: Float = 0.0

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
        attitudeQuat: identityOrientationQuat,
        bodyAngularVelocity: .zero,
        angleOfAttack: 0.0,
        sideslipAngle: 0.0,
        elevatorDeflection: 0.0,
        aileronDeflection: 0.0,
        rudderDeflection: 0.0
    )
}
