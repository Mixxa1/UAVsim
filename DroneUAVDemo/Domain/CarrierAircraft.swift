import Foundation
import simd

/// The aeroplane that carries the UAV to its release point.
///
/// Four of the six supersonic reference aircraft are air-launched, and until now the
/// carrier was an implicit fact: the UAV simply appeared at ten kilometres, hanging in
/// nothing, before anyone had armed it. That looked like a bug because half the picture
/// was missing — a carried aircraft *is* at altitude before release, but it is attached to
/// something.
///
/// The carrier is scenery with a state machine, not a flight model. It flies a straight
/// line at a constant speed, opens its bay, lets go, and leaves. Nothing about it is
/// simulated aerodynamically, because nothing about it needs to be: the moment that
/// matters is the release, and after that the carrier is only there so the operator can
/// watch it go.
enum CarrierAircraftKind: String, CaseIterable, Hashable {
    /// Lockheed C-130 in its drone-controller fit. The DC-130 carried Firebees under the
    /// wings; the GC-130A did the same for the Q-4.
    case c130
    /// Boeing B-52. NASA's NB-52B dropped HiMAT from the right wing pylon, the same pylon
    /// that had carried the X-15.
    case b52

    var resourceName: String {
        switch self {
        case .c130: return "C130"
        case .b52: return "B52_Stratofortress"
        }
    }

    /// Real overall length, m. The loaded asset is scaled to this rather than trusted,
    /// because a downloaded model's units are whatever its author felt like.
    var lengthMeters: Float {
        switch self {
        case .c130: return 29.8
        case .b52: return 48.5
        }
    }

    /// What the carrier sounds like.
    ///
    /// A C-130 is four turboprops and a B-52 is eight turbojets, so each borrows the loop its
    /// own engine class already has in the pack. Not a separate recording per aircraft: what
    /// distinguishes them acoustically at the distance the operator hears them is the kind of
    /// engine, not the airframe wrapped around it.
    var audioLoop: AudioAssetID {
        switch self {
        case .c130: return .turbopropLoop
        case .b52: return .turbojetLoop
        }
    }

    /// Level relative to the asset's authored gain. Eight jets are louder than four
    /// turboprops, and both are far louder than anything else in this simulation — which the
    /// distance law then takes most of back, because a carrier is never close.
    var audioTrimDb: Float {
        switch self {
        case .c130: return 3.0
        case .b52: return 6.0
        }
    }

    /// Playback rate for the loop.
    ///
    /// A four-engine turboprop transport runs its propellers slower than the airliner the
    /// recording came from, and a B-52's engines are much larger than the turbine that was
    /// recorded. Neither is a measurement; both are the direction the tone should move.
    var audioPitchRatio: Float {
        switch self {
        case .c130: return 0.88
        case .b52: return 0.78
        }
    }

    /// Does it have propellers to spin?
    ///
    /// None of them, now. The C-130 had four drawn in, because its asset's own propellers are
    /// part of one merged mesh with no hub to turn — but four synthesised discs read as four
    /// black crosses stuck to an aeroplane rather than as propellers, which is worse than the
    /// still ones the model already has.
    var hasPropellers: Bool { false }

    /// Where the UAV hangs, relative to the carrier and in metres: right of centreline,
    /// below, and forward. A wing pylon, not a bomb bay — every one of these aircraft
    /// carried its drone externally.
    var pylonOffset: SIMD3<Float> {
        switch self {
        case .c130: return SIMD3<Float>(6.8, -1.9, 1.0)
        case .b52: return SIMD3<Float>(9.4, -2.4, 2.0)
        }
    }

    /// How long the carrier stays in the scene after letting go, s. Long enough to watch
    /// it fly away, short enough that it is not still being drawn ten minutes into a
    /// flight.
    var departureSeconds: Float { 26.0 }

    /// How far back and how high the chase camera sits while the aircraft is still attached.
    ///
    /// Scaled off the carrier rather than off the drone. A twenty-two metre chase is right
    /// for looking at a Firebee and wrong for looking at the aeroplane carrying it: from
    /// there the C-130 is a wing filling one edge of the screen, and the two read as separate
    /// objects that happen to be near each other rather than as one aircraft hanging under
    /// another. From two and a half carrier-lengths back the whole thing is in frame, seen
    /// from behind — which is what an air launch is watched from.
    var attachedCameraDistance: Float { lengthMeters * 2.5 }
    var attachedCameraHeight: Float { lengthMeters * 0.28 }

    var localizationKey: String { "carrier.\(rawValue)" }

    /// Which carrier this aircraft is dropped from.
    ///
    /// Historical pairings, not a default: the Firebee came off a DC-130's wing, the Q-4
    /// off a B-50D or GC-130A, HiMAT off NASA's NB-52B, and a small rocket target off a
    /// fighter.
    static func carrier(forProfileID id: String) -> CarrierAircraftKind {
        switch id {
        case "rockwell-himat":
            return .b52
        default:
            // A DC-130 for anything not otherwise spoken for. It is the aeroplane that
            // carried more drones than any other, and every air-launched aircraft in the
            // catalogue except HiMAT came off one.
            return .c130
        }
    }
}

/// Where the carrier is in its one and only sequence.
enum CarrierPhase: String, Equatable {
    /// Flying level with the UAV attached, waiting for the release command.
    case carrying
    /// The bay or pylon is opening. Brief, and the only part of the sequence with any
    /// animation to it.
    case releasing
    /// Empty and flying away.
    case departing
    /// Gone from the scene.
    case gone
}

/// The carrier's kinematic state.
///
/// Deliberately a plain integrator over a straight line. Giving the carrier a flight model
/// would mean maintaining a second aircraft's aerodynamics to no purpose — what the
/// simulation needs from it is a position, a heading and a moment when it lets go.
struct CarrierAircraftState: Equatable {
    let kind: CarrierAircraftKind
    var phase: CarrierPhase
    var position: SIMD3<Float>
    /// Constant through the whole sequence. A carrier does not manoeuvre around a drop.
    var velocity: SIMD3<Float>
    var headingRadians: Float
    /// 0 closed, 1 fully open.
    var bayOpenFraction: Float
    /// Seconds since the release command.
    var elapsedSinceRelease: Float

    var isVisible: Bool { phase != .gone }

    /// Where the UAV sits while it is still attached.
    func attachedUAVPosition() -> SIMD3<Float> {
        let offset = kind.pylonOffset
        // The pylon offset is in the carrier's own frame, so it turns with the heading.
        let sinYaw = sin(headingRadians)
        let cosYaw = cos(headingRadians)
        let rotated = SIMD3<Float>(
            offset.x * cosYaw - offset.z * sinYaw,
            offset.y,
            offset.x * sinYaw + offset.z * cosYaw
        )
        return position + rotated
    }

    static func staged(
        kind: CarrierAircraftKind,
        releasePosition: SIMD3<Float>,
        releaseVelocity: SIMD3<Float>,
        headingRadians: Float
    ) -> CarrierAircraftState {
        // The carrier is placed so that its *pylon* is at the release point, not its own
        // origin — otherwise the UAV would appear offset from where the mission planner
        // put it, by the width of an aeroplane.
        var staged = CarrierAircraftState(
            kind: kind,
            phase: .carrying,
            position: .zero,
            velocity: releaseVelocity,
            headingRadians: headingRadians,
            bayOpenFraction: 0.0,
            elapsedSinceRelease: 0.0
        )
        staged.position = releasePosition - (staged.attachedUAVPosition() - staged.position)
        return staged
    }

    /// Advances the carrier one tick.
    mutating func advance(deltaTime: Float) {
        guard phase != .gone else { return }
        let dt = max(0.0, deltaTime)
        position += velocity * dt

        switch phase {
        case .carrying:
            bayOpenFraction = max(0.0, bayOpenFraction - dt * 1.5)
        case .releasing:
            bayOpenFraction = min(1.0, bayOpenFraction + dt * 1.2)
            elapsedSinceRelease += dt
            // The UAV is let go once the pylon is actually clear. A release through a
            // closed bay is the sort of thing that looks wrong even to someone who could
            // not say why.
            if bayOpenFraction >= 1.0 {
                phase = .departing
            }
        case .departing:
            elapsedSinceRelease += dt
            // The breakaway. Without it the carrier and the drone leave the pylon at the
            // same speed on the same heading and simply fly in formation until the carrier
            // is deleted — which is what the operator was seeing, and it is not what a drop
            // looks like. A real carrier turns away from the side the store came off and
            // climbs, both to open the distance and to stay out of the store's way.
            let turnRate: Float = 6.0 * .pi / 180.0
            // Away from the pylon: the store hangs on the right, so the carrier goes left.
            headingRadians -= turnRate * dt * (kind.pylonOffset.x >= 0.0 ? 1.0 : -1.0)
            let speed = max(1.0, simd_length(velocity))
            let climbRate: Float = 8.0
            let horizontal = sqrt(max(0.0, speed * speed - climbRate * climbRate))
            velocity = SIMD3<Float>(
                sin(headingRadians) * horizontal,
                climbRate,
                cos(headingRadians) * horizontal
            )
            if elapsedSinceRelease >= kind.departureSeconds {
                phase = .gone
            }
        case .gone:
            break
        }
    }

    /// Has the UAV physically left the pylon?
    var hasReleased: Bool { phase == .departing || phase == .gone }
}
