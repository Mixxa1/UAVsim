import simd

enum PropulsionRole: String, CaseIterable, Hashable {
    case liftRotor   // fixed-vertical, e.g. a lift+cruise hybrid's vertical rotors
    case cruiseProp  // fixed-forward pusher/tractor
    case tiltRotor   // servo-actuated, sweeps 0 (vertical/lift) -> pi/2 (forward/cruise)
}

/// A single controllable rotor/propeller/motor unit — role, mount position, tilt
/// servo state, spin state, and the resulting thrust direction. Physics and
/// (eventually) visuals both read from this instead of treating props as
/// purely decorative spinning meshes.
struct PropulsionUnit: Hashable {
    let id: String
    let role: PropulsionRole
    /// Body-relative mount position, meters. Not consumed by the force model
    /// (thrust is summed as if acting through the CG); carried for a future
    /// visual rig (nacelle placement) and per-unit moment-arm effects.
    let mountOffset: SIMD3<Float>

    /// 0 = fully vertical (rotor plane horizontal, lift-borne), pi/2 = fully
    /// forward (cruise). `liftRotor` stays pinned at 0, `cruiseProp` pinned at
    /// pi/2 — only `tiltRotor` units actually move.
    var tiltAngleRad: Float
    var targetTiltAngleRad: Float
    /// Servo slew rate, rad/s. 0 for liftRotor/cruiseProp (their tilt never changes).
    let tiltRateLimitRadPerSec: Float

    /// Current spin rate, rad/s — mirrors DroneState.rotorAngularSpeed's role
    /// for multirotors, but per-unit and not limited to 4 channels.
    var rotationalSpeedRadPerSec: Float
    let maxRotationalSpeedRadPerSec: Float

    /// Body-frame unit thrust direction, +Y up / -Z forward (matches the
    /// convention `stepFixedWingAerodynamic` uses for `thrustForceBody`).
    /// tiltAngleRad = 0 => thrust along +Y (hover lift); pi/2 => thrust along
    /// -Z (forward cruise thrust). This single vector is what lets one force
    /// term smoothly cover the whole hover-to-cruise sweep for a tiltRotor
    /// unit, with no separate hover/cruise force terms needed.
    var thrustDirectionBody: SIMD3<Float> {
        SIMD3<Float>(0, cos(tiltAngleRad), -sin(tiltAngleRad))
    }

    static func liftRotor(
        id: String,
        mountOffset: SIMD3<Float>,
        maxRotationalSpeedRadPerSec: Float = 900
    ) -> PropulsionUnit {
        PropulsionUnit(
            id: id,
            role: .liftRotor,
            mountOffset: mountOffset,
            tiltAngleRad: 0,
            targetTiltAngleRad: 0,
            tiltRateLimitRadPerSec: 0,
            rotationalSpeedRadPerSec: 0,
            maxRotationalSpeedRadPerSec: maxRotationalSpeedRadPerSec
        )
    }

    static func cruiseProp(
        id: String,
        mountOffset: SIMD3<Float>,
        maxRotationalSpeedRadPerSec: Float = 700
    ) -> PropulsionUnit {
        PropulsionUnit(
            id: id,
            role: .cruiseProp,
            mountOffset: mountOffset,
            tiltAngleRad: .pi / 2,
            targetTiltAngleRad: .pi / 2,
            tiltRateLimitRadPerSec: 0,
            rotationalSpeedRadPerSec: 0,
            maxRotationalSpeedRadPerSec: maxRotationalSpeedRadPerSec
        )
    }

    static func tiltRotor(
        id: String,
        mountOffset: SIMD3<Float>,
        // ~18deg/s -> a full 0-90deg sweep takes ~5s, matching real tilt-rotor
        // transition durations. pi/2 (a 1s full sweep) let the physics hand
        // off full aero-moment authority before the aircraft had picked up
        // any real forward airspeed, producing an extreme angle-of-attack
        // and an uncontrolled tumble.
        tiltRateLimitRadPerSec: Float = .pi / 10,
        maxRotationalSpeedRadPerSec: Float = 900
    ) -> PropulsionUnit {
        PropulsionUnit(
            id: id,
            role: .tiltRotor,
            mountOffset: mountOffset,
            tiltAngleRad: 0,
            targetTiltAngleRad: 0,
            tiltRateLimitRadPerSec: tiltRateLimitRadPerSec,
            rotationalSpeedRadPerSec: 0,
            maxRotationalSpeedRadPerSec: maxRotationalSpeedRadPerSec
        )
    }
}
