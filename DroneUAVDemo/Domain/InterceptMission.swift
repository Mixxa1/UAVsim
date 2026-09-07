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

/// Which side of an interception the operator is flying.
///
/// The two are the same mission read from opposite ends: one aircraft carries something to a place
/// and another aircraft exists to stop it. Everything the scenario already owns — the actors, the
/// contact model, the damage graph, the observation handoff — serves both, so this is a side rather
/// than a second scenario.
enum InterceptMissionSide: String, Codable, CaseIterable, Identifiable {
    /// The operator carries the module and closes on the target.
    case interceptor
    /// The operator carries a delivery to a zone while an interceptor hunts them.
    case delivery

    var id: String { rawValue }
    var titleKey: String { "intercept.side.\(rawValue)" }
    var hintKey: String { "intercept.side.\(rawValue).hint" }
}

enum InterceptTargetBehavior: String, Codable, CaseIterable, Identifiable {
    /// Flies its route and never reacts to the attacker.
    case routeFollower
    /// Varies course and altitude on a scripted profile.
    case evasiveBasic
    /// Heads out of the mission area; letting it leave is a failure.
    case escapeBoundary
    /// Tries to stabilise and hold position once it has taken damage.
    case damagedRecovery
    /// Runs the operator down. The delivery side's aircraft, and not offered as a choice on the
    /// interceptor side — a target that hunts the interceptor is a different mission.
    case interceptorPursuit

    var id: String { rawValue }
    var titleKey: String { "intercept.behavior.\(rawValue)" }

    /// The profiles an operator may pick for the aircraft they are hunting.
    static var selectable: [InterceptTargetBehavior] { allCases.filter { $0 != .interceptorPursuit } }
}

/// Where the operator's delivery is, on the side of the mission that has one.
///
/// The whole outcome of a delivery run is here: the aircraft's own condition never decides it. A
/// wrecked aircraft whose load still reached the zone succeeded; an untouched one whose load did
/// not, failed.
enum InterceptDeliveryState: String, Codable {
    /// Still on the aircraft.
    case carried
    /// Released and on its way down.
    case falling
    case landedInside
    case landedOutside
    /// Destroyed before it could arrive — taken apart with the aircraft, or on the ground.
    case destroyed

    var isResolved: Bool { self == .landedInside || self == .landedOutside || self == .destroyed }
    var titleKey: String { "intercept.delivery.\(rawValue)" }
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
    /// The module fouls the rotors of both aircraft — the one it touches and the one it came off.
    case equipmentDisruption
    /// A dense mass driven through one point of the target's structure. The target comes apart;
    /// the aircraft that delivered it is wrecked but not scattered.
    case kineticPenetration
    /// The module takes both airframes apart — the one it hit and the one carrying it. There is no
    /// standing off from something bolted to your own aircraft.
    case structuralDestruction

    var id: String { rawValue }

    /// Whether the module wrecks its own carrier along with what it touched.
    var destroysCarrier: Bool { self == .structuralDestruction }

    /// Whether the operator's aircraft is still flyable after the module has gone off.
    ///
    /// Only the two inert modules leave it flying. Anything that actually does something does it
    /// at contact range, on a mount bolted to the operator's own airframe — "I set it off and flew
    /// home" is not an outcome this mission has.
    var sparesCarrier: Bool { self == .contactOnly }
}

/// What is actually bolted under the aircraft.
///
/// Named as things, because they are things. An earlier version listed them by shape — "compact
/// module", "cylindrical module" — which told the operator the silhouette and nothing about what
/// they were loading.
///
/// Each carries its own mass, its own silhouette and the effect that belongs to it, so choosing one
/// is a single decision rather than a shape and an unrelated effect picked separately. What the
/// effect *does* stays an abstract game rule on named components (see `AttachedPayloadProfile`);
/// nothing here describes how any of it is built.
enum AttachedModuleShape: String, Codable, CaseIterable, Identifiable {
    /// A compact charge. The lightest thing that disables the aircraft it touches.
    case charge
    /// A folded net. Fouls rotors instead of striking the airframe — both aircraft's, since it
    /// deploys off a mount on the operator's own. The bulkiest option.
    case net
    /// A dense faired slug. No charge in it — it takes the target apart by arriving, and takes
    /// the aircraft that carried it out of the air doing so.
    case kineticSlug
    /// Inert mass for practice. Behaves like a loaded aircraft and does nothing on contact.
    case ballast
    /// A crate of supplies. The heaviest thing on the list and the reason the delivery side is
    /// flown with an aircraft that can lift something.
    case supplyCrate
    /// A field medical pack. Bulky rather than dense, and the load a delivery run is usually for.
    case medicalPack
    /// A sensor left behind at the zone — a ground station rather than something carried back.
    case sensorPod

    var id: String { rawValue }
    var titleKey: String { "intercept.module.\(rawValue)" }
    var detailKey: String { "intercept.module.\(rawValue).detail" }

    /// What an aircraft on this side of the mission would actually be carrying.
    ///
    /// An interceptor does not fly out with a medical pack taped to it, and a delivery run is not
    /// normally made with a net. The two lists overlap where they should: a charge or a slug can be
    /// what is being delivered, and both still go off where they land.
    static func selectable(for side: InterceptMissionSide) -> [AttachedModuleShape] {
        switch side {
        case .interceptor:
            return [.charge, .net, .kineticSlug, .ballast]
        case .delivery:
            return [.supplyCrate, .medicalPack, .sensorPod, .charge, .kineticSlug]
        }
    }

    /// Mounted mass, kilograms. Fed to the mass model, so a heavier module really is a slower,
    /// less agile interceptor.
    var massKg: Float {
        switch self {
        case .charge: return 0.35
        case .net: return 0.9
        case .kineticSlug: return 0.75
        case .ballast: return 0.6
        case .supplyCrate: return 2.4
        case .medicalPack: return 1.6
        case .sensorPod: return 1.1
        }
    }

    /// Bounding size in metres, for whoever draws it.
    var sizeMeters: SIMD3<Float> {
        switch self {
        case .charge: return SIMD3<Float>(0.18, 0.12, 0.24)
        case .net: return SIMD3<Float>(0.34, 0.10, 0.30)
        case .kineticSlug: return SIMD3<Float>(0.14, 0.14, 0.52)
        case .ballast: return SIMD3<Float>(0.13, 0.13, 0.42)
        case .supplyCrate: return SIMD3<Float>(0.36, 0.26, 0.40)
        case .medicalPack: return SIMD3<Float>(0.30, 0.22, 0.34)
        case .sensorPod: return SIMD3<Float>(0.16, 0.18, 0.30)
        }
    }

    /// What this module does on contact. Not a separate setting any more: a net fouls rotors and a
    /// slug does not, and asking the operator to pick the object and its behaviour independently
    /// only made it possible to describe something that does not exist.
    var effectProfile: AttachedPayloadProfile {
        switch self {
        case .charge: return .structuralDestruction
        case .net: return .equipmentDisruption
        case .kineticSlug: return .kineticPenetration
        // Cargo. It has no effect on anything it touches, which is the point of carrying it.
        case .ballast, .supplyCrate, .medicalPack, .sensorPod: return .contactOnly
        }
    }
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
    /// The component id the operator's own module occupies when it is taped to the nose. Its own
    /// entry in the component graph, so its mass sits where the module sits and its condition is
    /// the module's own rather than the belly bay's.
    static let noseMountPointID = "missionNoseModule"

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
    /// Which end of the interception the operator flies.
    var side: InterceptMissionSide = .interceptor
    var targetBehavior: InterceptTargetBehavior = .routeFollower
    var targetCarriesPayload = true
    var targetPayloadInert = false
    /// Derived from `moduleShape` — see `AttachedModuleShape.effectProfile`. Kept as a stored
    /// value because the session and the log read it directly, but `validated` is what sets it.
    var payloadProfile: AttachedPayloadProfile = .equipmentDisruption
    /// What the module is: its mass, its silhouette and its behaviour.
    var moduleShape: AttachedModuleShape = .charge
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
    ///
    /// This is how long a stricken aircraft is given to reach the ground, not how long the mission
    /// is willing to wait for a verdict. An aircraft whose rotors have been fouled at the 52 m
    /// patrol altitude comes down under a partly-working disc, not in free fall: fifteen to twenty
    /// seconds. Twelve — the value this started at — expired first and called a run that was about
    /// to succeed a failure.
    var assessmentTimeout: TimeInterval = 25
    /// How long the picture has to stay gone before the observer takes over.
    ///
    /// Long enough that a hiccup is not a handoff: a link that stumbles for a second and comes
    /// back should leave the operator on their own aircraft, because being thrown onto somebody
    /// else's camera mid-approach is worse than a second of interference. A real loss outlasts
    /// this comfortably.
    var noSignalHold: TimeInterval = 4
    /// Zero means unlimited; airframe, payload and mission time still constrain attempts.
    var maximumAttempts = 0
    var timeLimit: TimeInterval = 600
    /// Scales how hard the target works its behaviour profile.
    var targetAgility: Float = 1
    /// Hides every distance readout in the mission's own overlays, for an operator who would
    /// rather judge range by eye. Deliberately not tied to difficulty: it is a preference about
    /// how the mission is flown, not a rung on the ladder.
    var hidesRangeReadouts = false
    /// Centre of the drop zone on the delivery side, relative to the dock, with y above the local
    /// ground. Far enough out that the run is a transit with a hunter on it rather than a hop.
    var deliveryZoneOffset = SIMD3<Float>(0, 0, -1500)
    /// How close to that centre the load has to come to rest to count as delivered.
    var deliveryZoneRadius: Float = 45

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
            // How far the load has to be carried, with a hunter on it the whole way. This is the
            // delivery side's difficulty: a longer run is more time inside somebody's turn circle.
            configuration.deliveryZoneOffset = SIMD3<Float>(0, 0, -950)
            configuration.deliveryZoneRadius = 70
        case .medium:
            configuration.areaRadius = 280
            configuration.acquisitionRange = 160
            configuration.attemptRange = 22
            configuration.targetAgility = 1
            configuration.maximumAttempts = 0
            configuration.deliveryZoneOffset = SIMD3<Float>(0, 0, -1500)
            configuration.deliveryZoneRadius = 45
        case .hard:
            configuration.areaRadius = 380
            configuration.acquisitionRange = 120
            configuration.attemptRange = 18
            configuration.targetAgility = 1.6
            // The one difficulty where running out of approaches is a real way to lose.
            configuration.maximumAttempts = 3
            configuration.deliveryZoneOffset = SIMD3<Float>(0, 0, -2200)
            configuration.deliveryZoneRadius = 28
        }
        return configuration
    }

    /// A configuration that reached here from a saved file, a network peer or a slider that was
    /// dragged to an extreme is still a configuration the mission has to survive.
    var validated: InterceptMissionConfiguration {
        var copy = self
        copy.areaRadius = areaRadius.isFinite ? max(80, min(areaRadius, 2000)) : 240
        copy.deliveryZoneRadius = deliveryZoneRadius.isFinite ? max(12, min(deliveryZoneRadius, 300)) : 45
        if !deliveryZoneOffset.x.isFinite || !deliveryZoneOffset.y.isFinite || !deliveryZoneOffset.z.isFinite {
            copy.deliveryZoneOffset = SIMD3<Float>(0, 0, -1500)
        }
        if side == .delivery {
            // The aircraft the operator is running from hunts them. Nothing else it could be doing
            // is this mission, so it is not left to the setup screen to get right.
            copy.targetBehavior = .interceptorPursuit
            // A zone the run cannot legally reach is not a mission. The boundary has to contain it
            // with room to manoeuvre around it.
            let reach = simd_length(SIMD2<Float>(copy.deliveryZoneOffset.x, copy.deliveryZoneOffset.z))
            copy.areaRadius = max(copy.areaRadius, reach + copy.deliveryZoneRadius + 80)
        } else if targetBehavior == .interceptorPursuit {
            copy.targetBehavior = .routeFollower
        }
        copy.acquisitionRange = acquisitionRange.isFinite ? max(20, min(acquisitionRange, copy.areaRadius)) : 160
        copy.attemptRange = attemptRange.isFinite ? max(2, min(attemptRange, 80)) : 22
        copy.attemptTimeout = attemptTimeout.isFinite ? max(2, min(attemptTimeout, 120)) : 25
        copy.assessmentTimeout = assessmentTimeout.isFinite ? max(1, min(assessmentTimeout, 120)) : 25
        copy.noSignalHold = noSignalHold.isFinite ? max(0.5, min(noSignalHold, 15)) : 4
        copy.timeLimit = timeLimit.isFinite ? max(10, min(timeLimit, 7200)) : 600
        copy.targetAgility = targetAgility.isFinite ? max(0, min(targetAgility, 4)) : 1
        copy.maximumAttempts = max(0, maximumAttempts)
        // A load that belongs to the other side of the mission — a net on a delivery run, a
        // medical pack on an interception — is a configuration that could only have come from
        // switching sides with one already chosen.
        let allowed = AttachedModuleShape.selectable(for: copy.side)
        if !allowed.contains(copy.moduleShape) {
            copy.moduleShape = allowed.first ?? .charge
        }
        // One source of truth: the module decides what the module does.
        copy.payloadProfile = copy.moduleShape.effectProfile
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
    /// Delivery side: the load came to rest inside the zone. The only way that run is won.
    case payloadDelivered
    /// Delivery side: it came down somewhere else, or did not survive the trip.
    case payloadLost

    var titleKey: String { "intercept.result.\(rawValue)" }
}

/// How the run ended. Deliberately without a score: this is a rehearsal of an interception, and
/// what matters afterwards is whether it worked, why, and how many approaches it took — not a
/// number that turns those into a leaderboard.
struct InterceptMissionResult: Codable, Equatable {
    let success: Bool
    let reason: InterceptResultReason
    let timestamp: TimeInterval
    let attempts: Int
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
    /// Which end of the mission is being flown, and — on the delivery side — where the load is,
    /// how far the zone still is, and whether it can be let go right now.
    var side: InterceptMissionSide = .interceptor
    var delivery: InterceptDeliveryState = .carried
    var deliveryZoneRange: Float = 0
    var isOverDeliveryZone = false
    var canRelease = false

    var isObservingObserver: Bool { sourceID == InterceptCallsign.observer }
}
