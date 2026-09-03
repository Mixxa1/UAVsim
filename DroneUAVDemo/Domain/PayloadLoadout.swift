import Foundation
import simd

/// Where a payload hangs. Real airframes have distinct, non-interchangeable stations: a Matrice
/// takes two downward gimbals and one upward, a fixed wing takes a nose ball and a belly bay.
/// Modelling them as one anonymous "payload slot" is what made overlapping fits impossible to
/// reason about.
enum PayloadMount: String, Codable, CaseIterable, Hashable, Sendable {
    case bellyForward
    case bellyAft
    case top
    case nose

    var titleKey: String { "payload.mount.\(rawValue)" }

    /// Offset from the airframe's payload origin, in metres, for an aircraft about a metre across.
    /// The scene scales these to the actual airframe — a Reaper's nose ball is not twenty
    /// centimetres from its belly bay.
    ///
    /// Upward stations are handled separately by the scene, because "on top" has to clear the
    /// body rather than sit a fixed distance above the belly mount.
    var localOffset: SIMD3<Float> {
        switch self {
        case .bellyForward: return SIMD3<Float>(0.0, 0.0, -0.13)
        case .bellyAft: return SIMD3<Float>(0.0, 0.0, 0.17)
        case .top: return SIMD3<Float>(0.0, 0.24, 0.0)
        case .nose: return SIMD3<Float>(0.0, 0.03, -0.36)
        }
    }

    /// Whether this station sits above the airframe rather than under it.
    var isUpward: Bool { self == .top }
}

/// What one airframe can carry, and where.
struct PayloadMountCapability: Hashable, Sendable {
    let mount: PayloadMount
    /// Mass this station alone can take, kg. The airframe's total budget still applies on top.
    let massLimitKg: Double
    /// Envelope available at the station, metres. A module larger than this in any axis fouls the
    /// airframe and is rejected before flight rather than clipping through it.
    let envelopeM: SIMD3<Float>
}

enum PayloadMountCatalog {
    /// Enterprise multirotors with a proper gimbal bay: two downward stations and one upward.
    /// Confirmed for the Matrice 350, which publishes single-down, dual-down and single-up
    /// configurations at 2.7 kg total.
    private static let dualDownPlusUp: Set<String> = [
        "dji-matrice-350-rtk",
        "dji-matrice-400",
        "skydio-x10",
    ]

    /// Fixed wings and VTOLs: a nose ball and an under-fuselage bay.
    private static let noseAndBelly: Set<String> = [
        "mq-9b-skyguardian",
        "mq-9a-reaper",
        "hermes-900",
        "rq-21-integrator",
        "aerosonde-mk-4-7",
        "rq-7b-shadow",
        "ft5-los",
        "wingtraone-gen-ii",
        "quantum-systems-trinity-pro",
        "sensefly-ebee-tac",
    ]

    static func capabilities(
        profileID: String,
        maxPayloadMassKg: Double?,
        capabilityMode: UAVPayloadCapabilityMode
    ) -> [PayloadMountCapability] {
        let total = maxPayloadMassKg ?? 0
        guard total > 0 else { return [] }

        if dualDownPlusUp.contains(profileID) {
            // A station's own limit is what it can take *alone*, and a single downward gimbal is
            // rated for the aircraft's whole budget — the Matrice 350 carries a 920 g H30T on one
            // downward mount against a 960 g limit. What constrains two payloads at once is the
            // airframe total, checked separately in `PayloadLoadout.rejection`. Splitting the
            // budget across stations here instead rejected the single-gimbal fit that is the
            // common configuration.
            let upward = total * 0.5   // estimated: DJI rates the upward mount for lighter heads
            return [
                PayloadMountCapability(
                    mount: .bellyForward,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(0.24, 0.26, 0.24)
                ),
                PayloadMountCapability(
                    mount: .bellyAft,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(0.22, 0.24, 0.22)
                ),
                PayloadMountCapability(
                    mount: .top,
                    massLimitKg: upward,
                    envelopeM: SIMD3<Float>(0.18, 0.18, 0.18)
                ),
            ]
        }

        if noseAndBelly.contains(profileID) {
            return [
                PayloadMountCapability(
                    mount: .nose,
                    // A nose ball is physically smaller than the belly bay, so it caps out below
                    // the airframe total even when nothing else is fitted.
                    massLimitKg: total * 0.45,
                    envelopeM: SIMD3<Float>(0.30, 0.30, 0.40)
                ),
                PayloadMountCapability(
                    mount: .bellyForward,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(0.50, 0.40, 0.90)
                ),
            ]
        }

        switch capabilityMode {
        case .sensor:
            // One fixed gimbal bay and nothing else — the camera is already in it.
            return [
                PayloadMountCapability(
                    mount: .bellyForward,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(0.16, 0.16, 0.16)
                ),
            ]
        case .cargo:
            // Freight platforms hang everything from one central point under the frame.
            return [
                PayloadMountCapability(
                    mount: .bellyForward,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(1.20, 1.00, 1.20)
                ),
            ]
        case .modular:
            return [
                PayloadMountCapability(
                    mount: .bellyForward,
                    massLimitKg: total,
                    envelopeM: SIMD3<Float>(0.40, 0.35, 0.40)
                ),
            ]
        }
    }
}

/// One payload at one station.
struct PayloadMountEntry: Hashable, Sendable {
    var mount: PayloadMount
    var configuration: PayloadConfiguration
    /// Set when the payload is a camera, so the optics come from a real module rather than from
    /// the generic payload type.
    var cameraModuleID: String?

    var cameraModule: CameraModule? {
        cameraModuleID.flatMap(CameraModuleCatalog.module(id:))
    }
}

/// Everything currently fitted to the aircraft.
///
/// Deliberately a list rather than a single configuration: an airframe that publishes three
/// stations should be able to use them. The single-payload accessors below keep every existing
/// consumer working while the runtime is migrated station by station.
struct PayloadLoadout: Hashable, Sendable {
    var entries: [PayloadMountEntry]

    init(entries: [PayloadMountEntry] = []) {
        self.entries = entries
    }

    init(single configuration: PayloadConfiguration, mount: PayloadMount = .bellyForward) {
        self.entries = [PayloadMountEntry(mount: mount, configuration: configuration, cameraModuleID: nil)]
    }

    /// The payload the existing single-payload code paths mean when they say "the payload".
    var primary: PayloadConfiguration? {
        entries.first?.configuration
    }

    func entry(at mount: PayloadMount) -> PayloadMountEntry? {
        entries.first { $0.mount == mount }
    }

    /// Missions ask by kind — "is a hose fitted?" — rather than assuming the single payload is
    /// theirs. This is what lets a fire mission coexist with a camera on another station.
    func entry(ofType type: PayloadType) -> PayloadMountEntry? {
        entries.first { $0.configuration.payloadType == type }
    }

    func contains(_ type: PayloadType) -> Bool {
        entry(ofType: type) != nil
    }

    var totalMassKg: Double {
        entries.reduce(0) { $0 + Double($1.configuration.payloadMass) }
    }

    /// Whether another payload can go on a station, and why not when it cannot.
    func rejection(
        forAdding configuration: PayloadConfiguration,
        at mount: PayloadMount,
        capabilities: [PayloadMountCapability],
        airframeMassLimitKg: Double
    ) -> PayloadLoadoutRejection? {
        guard let capability = capabilities.first(where: { $0.mount == mount }) else {
            return .mountUnavailable
        }
        if entry(at: mount) != nil {
            return .mountOccupied
        }
        let mass = Double(configuration.payloadMass)
        if mass > capability.massLimitKg + 0.0001 {
            return .stationMassExceeded(limitKg: capability.massLimitKg)
        }
        if totalMassKg + mass > airframeMassLimitKg + 0.0001 {
            return .airframeMassExceeded(limitKg: airframeMassLimitKg)
        }
        return nil
    }
}

enum PayloadLoadoutRejection: Equatable, Hashable, Sendable {
    case mountUnavailable
    case mountOccupied
    case stationMassExceeded(limitKg: Double)
    case airframeMassExceeded(limitKg: Double)

    var messageKey: String {
        switch self {
        case .mountUnavailable: return "payload.mount.reject.unavailable"
        case .mountOccupied: return "payload.mount.reject.occupied"
        case .stationMassExceeded: return "payload.mount.reject.station_mass"
        case .airframeMassExceeded: return "payload.mount.reject.airframe_mass"
        }
    }
}
