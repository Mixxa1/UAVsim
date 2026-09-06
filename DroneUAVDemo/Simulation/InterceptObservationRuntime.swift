import Foundation
import simd

// MARK: - Observation

/// One thing the operator could be watching through. Registered every tick from the live world;
/// selecting one never creates an aircraft and never moves a camera.
struct InterceptObservationSource {
    let vehicleID: String
    let role: InterceptVehicleRole
    var position: SIMD3<Float>
    var orientation: simd_quatf
    var video: RFVideoPresentationState
    var hasLineOfSight: Bool
    var cameraFunctional: Bool
    /// Control-link readings, for the overlay that has to explain why the picture went. Optional
    /// because a source whose radio is not being evaluated has no honest number to show.
    var controlRSSIDBm: Double?
    var controlLQ: Int?

    /// Usable as a feed right now. A frozen or lost picture is not a feed, however healthy the
    /// aircraft carrying the camera happens to be.
    var available: Bool { cameraFunctional && video.health != .lost && !video.isFrozen }
}

/// Which source the operator is watching, and how the mission got there.
///
/// The handoff is deliberately slow: the picture degrades, then it is lost, then NO SIGNAL holds
/// for a moment, and only then does the observer take over. An immediate cut on the frame of
/// contact would be cinematography, not a video system.
struct InterceptObservationRuntime {
    private(set) var sources: [String: InterceptObservationSource] = [:]
    private(set) var activeVehicleID = InterceptCallsign.attacker
    private(set) var phase: InterceptObservationPhase = .watchingAttacker
    /// Bumped on every source change. The render pipeline keys its reset on this, so a switch
    /// restarts exposure and the video processor instead of carrying the old camera's state over.
    private(set) var revision: UInt64 = 0

    private var lossStartedAt: TimeInterval?
    private var wasLost = false
    /// Sources knocked off the air by an event, and the world time they come back at. The stage
    /// plan allows a short interference burst as a *consequence* of a contact; the link budget
    /// still decides whether the picture returns afterwards.
    private var disruptedUntil: [String: TimeInterval] = [:]

    var active: InterceptObservationSource? { sources[activeVehicleID] }

    /// Takes a source off the air for a moment. Called when the attached module goes off next to
    /// the aircraft carrying it — the operator loses the picture at the instant of contact, which
    /// is the whole reason the observer exists.
    mutating func disrupt(vehicleID: String, until: TimeInterval) {
        disruptedUntil[vehicleID] = max(disruptedUntil[vehicleID] ?? 0, until)
    }

    func isDisrupted(_ vehicleID: String, now: TimeInterval) -> Bool {
        (disruptedUntil[vehicleID] ?? 0) > now
    }

    /// Whether some observer can actually see the target right now. The strict confirmation
    /// policy needs this; the permissive one does not consult it at all.
    var observerCanConfirm: Bool {
        sources.values.contains { $0.role == .observer && $0.available && $0.hasLineOfSight }
    }

    var isObservingRemoteSource: Bool { activeVehicleID != InterceptCallsign.attacker }

    mutating func register(_ source: InterceptObservationSource) { sources[source.vehicleID] = source }

    /// Manual selection. Never creates an actor and never relocates its camera; an unavailable
    /// source simply refuses.
    @discardableResult
    mutating func select(_ vehicleID: String) -> Bool {
        guard let source = sources[vehicleID], source.available else { return false }
        guard activeVehicleID != vehicleID else { return true }
        activeVehicleID = vehicleID
        revision &+= 1
        lossStartedAt = nil
        wasLost = false
        phase = source.role == .observer ? .watchingObserver : .watchingAttacker
        return true
    }

    /// Advances the video-loss ladder and returns the events worth logging.
    mutating func step(now: TimeInterval, noSignalHold: TimeInterval) -> [InterceptMissionEventKind] {
        guard let source = active else { return [] }
        var events: [InterceptMissionEventKind] = []

        if source.available, !isDisrupted(source.vehicleID, now: now) {
            lossStartedAt = nil
            wasLost = false
            phase = source.role == .observer ? .watchingObserver
                : source.video.health == .degraded ? .attackerLinkDegrading
                : .watchingAttacker
            return events
        }

        if !wasLost {
            events.append(.videoLost(source.vehicleID))
            wasLost = true
        }
        lossStartedAt = lossStartedAt ?? now
        phase = .noSignal

        // Only loss of the currently watched attacker initiates an automatic handoff — an
        // observer that drops out while nobody is watching it must not reshuffle the feed.
        guard source.role == .attacker, now - (lossStartedAt ?? now) >= noSignalHold else { return events }

        // Chosen by call sign, not by which angle looks best.
        let candidate = sources.values
            .sorted { $0.vehicleID < $1.vehicleID }
            .first { $0.role == .observer && $0.available && $0.hasLineOfSight }
        guard let observer = candidate else {
            phase = .unavailable
            return events
        }
        phase = .observationHandoff
        select(observer.vehicleID)
        events.append(.observationSource(observer.vehicleID))
        return events
    }
}

// MARK: - Effects

/// World-space effects with their own lifetimes. Bounded on purpose: a long run full of contacts
/// must not accumulate emitters, and a restart must leave nothing behind.
struct InterceptEffectRuntime {
    private(set) var effects: [InterceptWorldEffect] = []
    private var seen: Set<String> = []

    /// The most effects allowed to exist at once. Older ones are dropped rather than queued.
    private static let capacity = 48
    /// Anything claiming to outlive this is a malformed effect, not a long-burning fire.
    private static let maximumLifetime: TimeInterval = 60

    /// One effect per impact, per vehicle, per kind — the same replicated event arriving twice
    /// produces one fire, not two.
    @discardableResult
    mutating func add(_ effect: InterceptWorldEffect, runID: UUID) -> Bool {
        guard effect.runID == runID,
              effect.lifetime.isFinite,
              effect.lifetime > 0,
              effect.lifetime <= Self.maximumLifetime else { return false }
        let key = "\(effect.impactID)/\(effect.vehicleID)/\(effect.kind.rawValue)"
        guard seen.insert(key).inserted else { return false }
        effects.append(effect)
        if effects.count > Self.capacity { effects.removeFirst(effects.count - Self.capacity) }
        return true
    }

    mutating func step(now: TimeInterval) {
        effects.removeAll { now - $0.startedAt >= $0.lifetime }
    }
}

// MARK: - RF adapter

/// Maps actual component failures onto radio equipment, so a damaged aircraft loses its picture
/// for a physical reason. Propagation, packet delivery and video decoding remain RF Core's job —
/// this only says which devices are still there and how badly they are hurt.
enum InterceptRFDamageAdapter {
    /// A device below this fraction of nominal is off, not merely weak.
    private static let deadThreshold: Float = 0.05
    /// Extra insertion loss a fully wrecked-but-still-powered device carries, in dB.
    private static let maximumDamageLossDB: Double = 18

    static func configuration(
        base: RFSystemConfiguration,
        graph: VehicleComponentGraph,
        failures: ComponentFailureRuntime
    ) -> RFSystemConfiguration {
        var result = base
        let power = factor("battery", graph, failures)
        let radio = factor("radio", graph, failures)
        let camera = cameraFactor(graph: graph, failures: failures)
        let videoTX = base.logicalLinks.video?.transmitterDeviceID

        for index in result.devices.indices where result.devices[index].endpoint == .airborne {
            // The video transmitter is only as good as the camera feeding it; everything else on
            // the airframe depends on the radio module.
            let isVideo = result.devices[index].id == videoTX
            let functional = min(power, isVideo ? camera : radio)
            result.devices[index].enabled = base.devices[index].enabled && functional > deadThreshold
            result.devices[index].connectorLossDB = base.devices[index].connectorLossDB
                + Double(1 - functional) * maximumDamageLossDB
        }
        for index in result.antennas.indices {
            let deviceID = result.antennas[index].deviceID
            guard base.devices.contains(where: { $0.id == deviceID && $0.endpoint == .airborne }) else { continue }
            result.antennas[index].damageFraction = max(base.antennas[index].damageFraction, Double(1 - radio))
        }
        return result
    }

    /// The worst camera on the aircraft, because one dead gimbal is enough to lose the picture it
    /// was the source of.
    static func cameraFactor(graph: VehicleComponentGraph, failures: ComponentFailureRuntime) -> Float {
        let cameras = graph.components.filter { $0.kind == .cameraGimbal }
        return cameras.map { $0.isAttached ? min($0.integrity, failures.functionalFactor(componentID: $0.id)) : 0 }.min() ?? 1
    }

    /// How much of a named component is still doing its job: physical integrity and simulated
    /// functional failure, whichever is worse. A detached component contributes nothing.
    static func factor(_ id: String, _ graph: VehicleComponentGraph, _ failures: ComponentFailureRuntime) -> Float {
        guard let component = graph.component(id: id) else { return 1 }
        return component.isAttached ? min(component.integrity, failures.functionalFactor(componentID: id)) : 0
    }
}
