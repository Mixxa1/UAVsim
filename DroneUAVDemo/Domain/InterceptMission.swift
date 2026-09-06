import Foundation
import simd

// The attached-payload interception scenario's vocabulary: who is in the air, what the mission
// director is currently doing, what the carried module is worth, and what the run finally decided.
//
// Nothing here flies an aircraft, resolves a contact or draws a frame. Every type in this file is
// either a value the simulation hands to the scenario rules, or a value the scenario rules hand
// back to the HUD and the mission log. That split is the whole point of the stage: the mission
// knows about *attempts, states and events*, never about a launched projectile.

// MARK: - Roles and call signs

enum InterceptVehicleRole: String, Codable {
    /// The aircraft the operator flies. Carries the attached module up to physical contact.
    case attacker
    /// The aircraft being intercepted. May carry a module of its own.
    case target
    /// Already airborne before the run starts; watches the area and never continues the attack.
    case observer
}

/// Stable call signs for the three actors. The mission log, the observation source list, the HUD
/// and the scene labels all address vehicles by these, so they live in one place rather than as a
/// string literal at every call site.
enum InterceptCallsign {
    static let attacker = "ATK-01"
    static let target = "TGT-01"
    static let observer = "OBS-01"
}

extension InterceptVehicleRole {
    var callsign: String {
        switch self {
        case .attacker: return InterceptCallsign.attacker
        case .target: return InterceptCallsign.target
        case .observer: return InterceptCallsign.observer
        }
    }
}

// MARK: - Mission and observation phases

enum InterceptMissionPhase: String, Codable {
    case idle
    case preparing
    case acquiringTarget
    case intercepting
    case attackRun
    case reattack
    case impactResolution
    case assessingResult
    case completed
    case failed

    var titleKey: String { "intercept.phase.\(rawValue)" }
}

/// What the operator's screen is currently showing, and why. Deliberately separate from
/// `InterceptMissionPhase`: losing video does not by itself advance the scenario.
enum InterceptObservationPhase: String, Codable {
    case watchingAttacker
    case attackerLinkDegrading
    case noSignal
    case observationHandoff
    case watchingObserver
    /// Video is gone and no observer can take over yet.
    case unavailable

    var titleKey: String { "intercept.observation.\(rawValue)" }
}

// MARK: - Vehicle functional state

/// Minimal component-level condition, in the wording the stage plan uses. Not a health bar: it is
/// derived from the component graph the damage system already maintains.
enum InterceptFunctionalState: String, Codable {
    case nominal
    case damaged
    case degraded
    case uncontrolled
    case disabled
    case destroyed
    case crashed

    /// Terminal for the purposes of the result: the aircraft is not coming back from this.
    var isTerminal: Bool { self == .disabled || self == .destroyed || self == .crashed }

    /// Still able to fly another approach. `uncontrolled` is excluded on purpose — an aircraft
    /// that no longer answers the sticks is not making a second run.
    var canAttempt: Bool { self == .nominal || self == .damaged || self == .degraded }

    /// How the target's condition is announced. The attacker's condition is reported by the
    /// aircraft's own instruments, so only the target needs a phrase of its own.
    var targetTitleKey: String { "intercept.target.\(rawValue)" }
}

// MARK: - Scenario options

enum InterceptTargetBehavior: String, Codable, CaseIterable, Identifiable {
    /// Flies its route and never reacts to the attacker.
    case routeFollower
    /// Varies course and altitude on a scripted profile.
    case evasiveBasic
    /// Heads out of the mission area; letting it leave is a failure.
    case escapeBoundary
    /// Tries to stabilise and hold position once it has taken damage.
    case damagedRecovery

    var id: String { rawValue }
    var titleKey: String { "intercept.behavior.\(rawValue)" }
}

/// Who is allowed to call the target neutralised.
enum InterceptConfirmationPolicy: String, Codable, CaseIterable, Identifiable {
    /// The resolved world state is enough.
    case authoritativeWorld
    /// An observer with a working camera and line of sight has to see it.
    case observerRequired

    var id: String { rawValue }
    var titleKey: String { "intercept.confirmation.\(rawValue)" }
    var hintKey: String { "intercept.confirmation.\(rawValue).hint" }
}

// MARK: - Attached payload

enum AttachedPayloadState: String, Codable {
    case attachedReady
    /// Simulation state only. No real-world arming procedure is modelled.
    case armedByMission
    case contactTriggered
    case degraded
    case inert
    case consumed
    case destroyed

    var canTrigger: Bool { self == .attachedReady || self == .armedByMission || self == .degraded }

    var titleKey: String { "intercept.payload.\(rawValue)" }
}

/// Dimensionless game effects. These do not describe explosives or a physical damage radius.
enum AttachedPayloadProfile: String, Codable, CaseIterable, Identifiable {
    /// The module changes nothing; only the contact itself damages the two airframes.
    case contactOnly
    /// The module knocks out named equipment on the vehicle it contacts.
    case equipmentDisruption

    var id: String { rawValue }
    var titleKey: String { "intercept.effect.\(rawValue)" }
}

/// The one situation in which a module's effect is allowed to occur.
enum AttachedPayloadTriggerPolicy: String, Codable {
    case targetContact
    case ownerCritical
    case never
}

/// A module that stays bolted to its aircraft until contact, destruction or a scenario event.
/// A miss costs nothing: the module is still there for the next approach.
struct AttachedPayloadComponent: Codable, Equatable, Identifiable {
    let id: UUID
    let ownerVehicleID: String
    let mountPointID: String
    var state: AttachedPayloadState
    let effectProfileID: AttachedPayloadProfile
    let triggerPolicy: AttachedPayloadTriggerPolicy
    let canProduceSecondaryEffect: Bool
    /// Mirrors the mount's integrity. Zero means the module went with the mount.
    var survivability: Float
    let visualModelID: String
    /// Set exactly once, by the impact that spent the module. Its presence is what makes the
    /// effect one-shot regardless of how many times the same contact is reported.
    private(set) var triggeringImpactID: UUID?

    static let defaultMountPointID = "payloadMount"

    init(
        ownerVehicleID: String,
        mountPointID: String = AttachedPayloadComponent.defaultMountPointID,
        state: AttachedPayloadState = .armedByMission,
        profile: AttachedPayloadProfile = .equipmentDisruption,
        triggerPolicy: AttachedPayloadTriggerPolicy = .targetContact,
        secondary: Bool = false,
        visualModelID: String = "cargoBox"
    ) {
        id = UUID()
        self.ownerVehicleID = ownerVehicleID
        self.mountPointID = mountPointID
        self.state = state
        effectProfileID = profile
        self.triggerPolicy = triggerPolicy
        canProduceSecondaryEffect = secondary
        survivability = 1
        self.visualModelID = visualModelID
    }

    /// Functional consumption does not detach the mount or subtract its physical mass — the box is
    /// still bolted on and still weighs what it weighed.
    mutating func trigger(impactID: UUID, policy: AttachedPayloadTriggerPolicy) -> Bool {
        guard state.canTrigger,
              survivability > 0,
              triggeringImpactID == nil,
              triggerPolicy == policy,
              policy != .never else { return false }
        triggeringImpactID = impactID
        state = .contactTriggered
        return true
    }

    mutating func consume() {
        if state == .contactTriggered { state = .consumed }
    }

    /// Follows the mount's condition. Survivability only ever falls, so a module that has already
    /// been shaken apart cannot be repaired by a later, gentler reading of the same mount.
    mutating func updateMount(integrity: Float, attached: Bool) {
        survivability = min(survivability, max(0, min(1, integrity)))
        guard state.canTrigger else { return }
        if !attached || survivability <= 0 {
            state = .destroyed
        } else if survivability < AttachedPayloadComponent.inertSurvivability {
            state = .inert
        } else if survivability < AttachedPayloadComponent.degradedSurvivability {
            state = .degraded
        }
    }

    /// Below this the module is scrap and will not do anything on contact.
    private static let inertSurvivability: Float = 0.25
    /// Below this it still works, but the HUD says so.
    private static let degradedSurvivability: Float = 0.75
}

// MARK: - Mission configuration

/// Everything the scenario needs that is not a live world value. Built by the setup screen,
/// clamped by `validated`, and then constant for the whole run.
struct InterceptMissionConfiguration: Codable, Equatable {
    var missionID = "attached-payload-v2"
    var targetBehavior: InterceptTargetBehavior = .routeFollower
    var targetCarriesPayload = true
    var targetPayloadInert = false
    var payloadProfile: AttachedPayloadProfile = .equipmentDisruption
    var confirmationPolicy: InterceptConfirmationPolicy = .authoritativeWorld
    var targetProfileID = ""
    var observerProfileID = ""
    /// Spawn offsets from the dock, in metres, with y measured above the local ground.
    ///
    /// Both sit clear of the canopy on purpose. A dense forest in this simulator grows to 28 m,
    /// and the target used to patrol at 18 — inside it. No amount of obstacle avoidance makes
    /// threading a rotorcraft between trees at patrol speed look like anything but flying into
    /// them, and an aircraft transiting an area has no reason to be down there in the first place.
    var targetOffset = SIMD3<Float>(0, 52, -65)
    var observerOffset = SIMD3<Float>(24, 62, -35)
    /// Leaving this horizontal radius around the dock counts as an escape.
    var areaRadius: Float = 240
    /// Line of sight closer than this counts as having acquired the target.
    var acquisitionRange: Float = 160
    /// Inside this the run counts as an approach, whether or not the operator pressed anything.
    var attemptRange: Float = 22
    /// How long one approach may last before it is written off as a miss.
    var attemptTimeout: TimeInterval = 25
    /// How long the result may stay unconfirmed before the run fails.
    var assessmentTimeout: TimeInterval = 12
    /// NO SIGNAL is shown for at least this long before the observer takes over, so the handoff
    /// never looks like a cut made at the moment of contact.
    var noSignalHold: TimeInterval = 1.2
    /// Zero means unlimited; airframe, payload and mission time still constrain attempts.
    var maximumAttempts = 0
    var timeLimit: TimeInterval = 600
    /// Scales how hard the target works its behaviour profile.
    var targetAgility: Float = 1
    /// Hides every distance readout in the mission's own overlays, for an operator who would
    /// rather judge range by eye. Deliberately not tied to difficulty: it is a preference about
    /// how the mission is flown, not a rung on the ladder.
    var hidesRangeReadouts = false

    /// Difficulty is the same lever it is in every other scenario: how much room the target has,
    /// how late it can be acquired, how sharply it moves and how many approaches are allowed.
    /// It never picks the target's behaviour — that stays the operator's choice.
    static func make(difficulty: MissionDifficulty) -> InterceptMissionConfiguration {
        var configuration = InterceptMissionConfiguration()
        switch difficulty {
        case .easy:
            configuration.areaRadius = 200
            configuration.acquisitionRange = 190
            configuration.attemptRange = 26
            configuration.targetAgility = 0.65
            configuration.maximumAttempts = 0
        case .medium:
            configuration.areaRadius = 280
            configuration.acquisitionRange = 160
            configuration.attemptRange = 22
            configuration.targetAgility = 1
            configuration.maximumAttempts = 0
        case .hard:
            configuration.areaRadius = 380
            configuration.acquisitionRange = 120
            configuration.attemptRange = 18
            configuration.targetAgility = 1.6
            // The one difficulty where running out of approaches is a real way to lose.
            configuration.maximumAttempts = 3
        }
        return configuration
    }

    /// A configuration that reached here from a saved file, a network peer or a slider that was
    /// dragged to an extreme is still a configuration the mission has to survive.
    var validated: InterceptMissionConfiguration {
        var copy = self
        copy.areaRadius = areaRadius.isFinite ? max(80, min(areaRadius, 2000)) : 240
        copy.acquisitionRange = acquisitionRange.isFinite ? max(20, min(acquisitionRange, copy.areaRadius)) : 160
        copy.attemptRange = attemptRange.isFinite ? max(2, min(attemptRange, 80)) : 22
        copy.attemptTimeout = attemptTimeout.isFinite ? max(2, min(attemptTimeout, 120)) : 25
        copy.assessmentTimeout = assessmentTimeout.isFinite ? max(1, min(assessmentTimeout, 120)) : 12
        copy.noSignalHold = noSignalHold.isFinite ? max(0.2, min(noSignalHold, 5)) : 1.2
        copy.timeLimit = timeLimit.isFinite ? max(10, min(timeLimit, 7200)) : 600
        copy.targetAgility = targetAgility.isFinite ? max(0, min(targetAgility, 4)) : 1
        copy.maximumAttempts = max(0, maximumAttempts)
        if !targetOffset.x.isFinite || !targetOffset.y.isFinite || !targetOffset.z.isFinite {
            copy.targetOffset = SIMD3<Float>(0, 18, -65)
        }
        if !observerOffset.x.isFinite || !observerOffset.y.isFinite || !observerOffset.z.isFinite {
            copy.observerOffset = SIMD3<Float>(24, 35, -35)
        }
        return copy
    }
}

// MARK: - World snapshots

/// What the scenario rules are allowed to see of an aircraft. Deliberately narrow: position,
/// motion, functional condition and the state of whatever is bolted to it. No component integrity
/// table — nothing in the rules reads one, and building one three times per physics tick was pure
/// allocation. The live component graph is still there for anyone who needs the detail.
struct InterceptVehicleSnapshot: Codable, Equatable, Identifiable {
    let id: String
    let role: InterceptVehicleRole
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var functionalState: InterceptFunctionalState
    var payloadState: AttachedPayloadState?
}

// MARK: - Impacts

enum InterceptContactKind: String, Codable { case vehicle, terrain, environment }

/// `ImpactReport.obstacleSource` values this mission produces itself. The player's aircraft runs
/// the app's normal impact pipeline, so the mission has to be able to tell a contact it already
/// resolved apart from one the app is reporting back to it — otherwise the same touch is logged,
/// and damaged, twice.
enum InterceptContactSource {
    static let vehicle = "mission-vehicle"
    static let terrain = "mission-terrain"
}

enum InterceptImpactClass: String, Codable { case touch, scrape, heavy, critical }

/// One normalised physical contact. Produced by the collision pipeline, never by a mission timer.
struct InterceptImpactEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let timestamp: TimeInterval
    /// Which authority resolved it. Replicas that disagree are dropped rather than applied twice.
    let authorityID: String
    let firstVehicleID: String
    let secondEntityID: String
    let kind: InterceptContactKind
    let position: SIMD3<Float>
    let normal: SIMD3<Float>
    let firstComponentID: String
    let secondComponentID: String?
    let impactClass: InterceptImpactClass
    let surface: String
    /// Modules this contact spent, if any.
    var payloadIDs: [UUID] = []
}

// MARK: - Attempts and results

enum InterceptAttemptOutcome: String, Codable { case miss, contact, aborted, attackerLost }

/// Aggregates one approach for the log and the debrief. It never drives physics.
struct InterceptAttackAttempt: Codable, Equatable, Identifiable {
    let id: UUID
    let number: Int
    let startedAt: TimeInterval
    var endedAt: TimeInterval?
    var closestApproach: Float
    var hadContact = false
    var outcome: InterceptAttemptOutcome?
    let before: [InterceptVehicleSnapshot]
    var after: [InterceptVehicleSnapshot] = []
}

enum InterceptResultReason: String, Codable {
    case targetNeutralized
    case attackerLost
    case targetEscaped
    case timeExpired
    case assessmentExpired
    case attemptsExhausted
    case payloadUnavailable

    var titleKey: String { "intercept.result.\(rawValue)" }
}

struct InterceptMissionResult: Codable, Equatable {
    let success: Bool
    let reason: InterceptResultReason
    let timestamp: TimeInterval
    let attempts: Int
    let score: Int
}

// MARK: - Mission events

enum InterceptMissionEventKind: Codable, Equatable {
    case phase(InterceptMissionPhase)
    case attemptStarted(UUID, Int)
    case attemptEnded(UUID, InterceptAttemptOutcome)
    case impact(InterceptImpactEvent)
    case vehicleState(String, InterceptFunctionalState)
    case payload(String, AttachedPayloadState)
    case videoLost(String)
    case observationSource(String)
    case effect(InterceptWorldEffect)
    case result(InterceptMissionResult)

    /// The localisation key the mission log shows for this event. Without it every row in the
    /// timeline reads "Interception event", which is a log nobody can debrief from.
    var detailKey: String {
        switch self {
        case let .phase(phase): return "intercept.log.phase.\(phase.rawValue)"
        case .attemptStarted: return "intercept.log.attempt_started"
        case let .attemptEnded(_, outcome): return "intercept.log.attempt.\(outcome.rawValue)"
        case let .impact(impact): return "intercept.log.impact.\(impact.kind.rawValue)"
        case let .vehicleState(_, state): return "intercept.log.vehicle.\(state.rawValue)"
        case let .payload(_, state): return "intercept.log.payload.\(state.rawValue)"
        case .videoLost: return "intercept.log.video_lost"
        case .observationSource: return "intercept.log.observation_source"
        case let .effect(effect): return "intercept.log.effect.\(effect.kind.rawValue)"
        case let .result(result): return result.success ? "intercept.log.result.success" : "intercept.log.result.failure"
        }
    }

    /// How loudly the timeline should show it. A lost aircraft and a routine phase change are not
    /// the same kind of entry.
    var severity: MissionEventSeverity {
        switch self {
        case let .result(result):
            return result.success ? .info : .critical
        case let .vehicleState(_, state):
            return state.isTerminal ? .critical : state.canAttempt ? .info : .warning
        case let .impact(impact):
            return impact.impactClass == .critical ? .critical
                : impact.impactClass == .heavy ? .warning : .info
        case let .payload(_, state):
            return state == .destroyed || state == .inert ? .warning : .info
        case .videoLost:
            return .warning
        case .phase, .attemptStarted, .attemptEnded, .observationSource, .effect:
            return .info
        }
    }
}

/// This is distinct from the existing `MissionEvent` timeline record: it is the mission's own
/// ordered, authority-stamped log, and the timeline entry is built from it.
struct InterceptMissionEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let sequence: UInt64
    let timestamp: TimeInterval
    let authorityID: String
    let kind: InterceptMissionEventKind
}

// MARK: - World effects

enum InterceptEffectKind: String, Codable { case contact, smoke, fire, secondary }

/// A world-space effect. It lives at the contact point, not in front of a camera, so it is still
/// there — and still in the right place — after the feed switches to the observer.
struct InterceptWorldEffect: Codable, Equatable, Identifiable {
    let id: UUID
    let runID: UUID
    let impactID: UUID
    let vehicleID: String
    let kind: InterceptEffectKind
    let position: SIMD3<Float>
    /// The contact normal that produced it. Sparks and fragments leave a strike along this, so an
    /// effect that has lost it would throw its debris in an arbitrary direction.
    var normal = SIMD3<Float>(0, 1, 0)
    let startedAt: TimeInterval
    let lifetime: TimeInterval
}

// MARK: - HUD projection

/// The whole of what the HUD is allowed to know. Published at a fixed low rate rather than every
/// physics tick, so the scenario's own state can move as fast as it likes without redrawing
/// SwiftUI 60 times a second.
struct InterceptMissionHUDState: Equatable {
    var phase: InterceptMissionPhase = .preparing
    var observationPhase: InterceptObservationPhase = .watchingAttacker
    var sourceID = InterceptCallsign.attacker
    var remaining: TimeInterval = 0
    var attempts = 0
    var maximumAttempts = 0
    var payloadState: AttachedPayloadState = .attachedReady
    var targetState: InterceptFunctionalState = .nominal
    var distance: Float = 0
    var canAttempt = false
    var observerAvailable = false
    var result: InterceptMissionResult?
    /// Link readings for the source currently on screen. The feed overlay shows the numbers the
    /// operator would use to decide whether the picture is coming back — it never invents them.
    var sourceRSSIDBm: Double?
    var sourceLinkQuality: Int?
    var isSourceFrozen = false
    /// Where the watching source is and what it can see. An observer feed is a surveillance
    /// downlink, not a pilot's view, so it is captioned with the observer's own numbers.
    var sourceAltitude: Float = 0
    var sourceToTargetRange: Float = 0
    var sourceHasTargetInView = false
    /// Whether the operator asked for the distances to be left off the screen.
    var hidesRanges = false

    var isObservingObserver: Bool { sourceID == InterceptCallsign.observer }
}
