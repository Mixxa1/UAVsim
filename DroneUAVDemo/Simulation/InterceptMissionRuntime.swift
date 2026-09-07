import Foundation
import simd

/// The mission director: the scenario's state machine, its attempt log and its result.
///
/// It consumes resolved world state and typed impact events. It neither flies aircraft, nor
/// applies damage, nor sets RSSI, nor moves a camera — every one of those belongs to a subsystem
/// that already exists, and the whole point of the stage is that the mission reads their output
/// instead of reaching past them.
struct InterceptMissionRuntime {
    let runID: UUID
    let configuration: InterceptMissionConfiguration
    /// Who owns this run's events. Anything stamped by anyone else is somebody else's run.
    let authorityID: String

    private(set) var phase: InterceptMissionPhase = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var attempts: [InterceptAttackAttempt] = []
    private(set) var result: InterceptMissionResult?
    private(set) var events: [InterceptMissionEvent] = []

    private var sequence: UInt64 = 0
    private var knownImpacts: Set<UUID> = []
    private var previousStates: [String: InterceptFunctionalState] = [:]
    private var assessmentStarted: TimeInterval?
    private var targetTerminalAt: TimeInterval?

    /// An approach counts as flown past once the aircraft is this far outside the attempt range.
    private static let passedRangeMultiplier: Float = 1.5

    init(configuration: InterceptMissionConfiguration, runID: UUID = UUID(), authorityID: String = "local") {
        self.configuration = configuration.validated
        self.runID = runID
        self.authorityID = authorityID
        transition(.preparing)
    }

    var remaining: TimeInterval { max(0, configuration.timeLimit - elapsed) }
    var activeAttempt: InterceptAttackAttempt? { attempts.last.flatMap { $0.outcome == nil ? $0 : nil } }
    var isActive: Bool { result == nil }

    // MARK: - Operator- and world-driven transitions

    mutating func worldReady() {
        guard phase == .preparing else { return }
        transition(.acquiringTarget)
    }

    mutating func acquireTarget() {
        guard phase == .acquiringTarget, isActive else { return }
        transition(.intercepting)
    }

    /// Whether another approach is allowed. This is the stage plan's `canReattack`: a miss costs
    /// nothing, so what limits approaches is the airframe, the module, the clock and the policy.
    func canBeginAttempt(vehicles: [InterceptVehicleSnapshot]) -> Bool {
        guard isActive,
              phase == .intercepting || phase == .reattack,
              let attacker = vehicles.first(where: { $0.role == .attacker }),
              attacker.functionalState.canAttempt,
              attacker.payloadState?.canTrigger == true else { return false }
        return configuration.maximumAttempts == 0 || attempts.count < configuration.maximumAttempts
    }

    mutating func beginAttempt(vehicles: [InterceptVehicleSnapshot]) {
        guard canBeginAttempt(vehicles: vehicles) else { return }
        let attempt = InterceptAttackAttempt(
            id: UUID(),
            number: attempts.count + 1,
            startedAt: elapsed,
            closestApproach: distance(vehicles),
            before: vehicles
        )
        attempts.append(attempt)
        emit(.attemptStarted(attempt.id, attempt.number))
        transition(.attackRun)
    }

    mutating func abortAttempt(vehicles: [InterceptVehicleSnapshot]) {
        guard activeAttempt != nil, isActive else { return }
        endAttempt(.aborted, vehicles: vehicles)
        transition(.reattack)
    }

    // MARK: - Step

    /// All consequences of one physics step are assessed together. A simultaneous terminal
    /// target/attacker contact cannot change the result merely because callbacks were reordered.
    mutating func step(
        deltaTime: TimeInterval,
        vehicles: [InterceptVehicleSnapshot],
        impacts: [InterceptImpactEvent],
        observerCanConfirm: Bool,
        targetEscaped: Bool = false,
        delivery: InterceptDeliveryState = .carried
    ) {
        guard isActive, phase != .preparing, deltaTime.isFinite, deltaTime >= 0 else { return }
        elapsed += deltaTime

        // Sorted so the log reads the same way on every machine that replays this run.
        for vehicle in vehicles.sorted(by: { $0.id < $1.id }) where previousStates[vehicle.id] != vehicle.functionalState {
            emit(.vehicleState(vehicle.id, vehicle.functionalState))
            previousStates[vehicle.id] = vehicle.functionalState
        }

        guard let attacker = vehicles.first(where: { $0.role == .attacker }),
              let target = vehicles.first(where: { $0.role == .target }) else { return }

        if configuration.side == .delivery {
            // Impacts on this side are log entries, not approaches. There is no attempt to open:
            // the operator is not trying to reach anything, they are trying to arrive.
            for impact in impacts where impact.runID == runID && impact.authorityID == authorityID {
                guard knownImpacts.insert(impact.id).inserted else { continue }
                emit(.impact(impact))
            }
            resolveDelivery(attacker: attacker, delivery: delivery, vehicles: vehicles)
            return
        }

        consume(impacts: impacts, attacker: attacker, target: target, vehicles: vehicles)

        if activeAttempt != nil {
            let index = attempts.count - 1
            attempts[index].closestApproach = min(attempts[index].closestApproach, distance(vehicles))
        }

        if target.functionalState.isTerminal, targetTerminalAt == nil { targetTerminalAt = elapsed }
        if targetTerminalAt != nil {
            assessmentStarted = assessmentStarted ?? elapsed
            transition(.assessingResult)
            if configuration.confirmationPolicy == .authoritativeWorld || observerCanConfirm {
                finish(success: true, reason: .targetNeutralized, vehicles: vehicles)
                return
            }
        } else if attacker.functionalState.isTerminal || attacker.functionalState == .uncontrolled {
            // There is nothing left to finish the job with. The observer watches; it never takes
            // over the attack.
            endAttempt(.attackerLost, vehicles: vehicles)
            finish(success: false, reason: .attackerLost, vehicles: vehicles)
            return
        }

        if targetEscaped, targetTerminalAt == nil {
            finish(success: false, reason: .targetEscaped, vehicles: vehicles)
        } else if remaining <= 0 {
            finish(success: false, reason: .timeExpired, vehicles: vehicles)
        } else if let start = assessmentStarted {
            resolveAssessment(startedAt: start, attacker: attacker, target: target, vehicles: vehicles)
        } else if let attempt = activeAttempt {
            resolveApproach(attempt, vehicles: vehicles)
        } else if phase == .reattack || phase == .intercepting {
            if attacker.payloadState?.canTrigger != true {
                if target.functionalState == .nominal {
                    finish(success: false, reason: .payloadUnavailable, vehicles: vehicles)
                } else {
                    // Nothing left to send at it, but it is not flying like an aircraft that was
                    // missed either. Watch it down: writing the run off over the target's shoulder
                    // while it falls is how a success gets recorded as a failure.
                    assessmentStarted = elapsed
                    transition(.assessingResult)
                }
            } else if configuration.maximumAttempts > 0, attempts.count >= configuration.maximumAttempts {
                finish(success: false, reason: .attemptsExhausted, vehicles: vehicles)
            }
        }
    }

    /// The delivery side's whole rule set: the load decides, and only the load.
    ///
    /// Written this way on purpose, because the four cases the mission is specified in reduce to
    /// one question. A wrecked aircraft whose load still reached the zone succeeded; an untouched
    /// aircraft whose load did not, failed. What the operator's own airframe went through changes
    /// how the run is *described* — a load that came down short after the hunter got to them reads
    /// as a lost aircraft, not a bad drop — but never whether it was won.
    private mutating func resolveDelivery(
        attacker: InterceptVehicleSnapshot,
        delivery: InterceptDeliveryState,
        vehicles: [InterceptVehicleSnapshot]
    ) {
        switch delivery {
        case .landedInside:
            finish(success: true, reason: .payloadDelivered, vehicles: vehicles)
        case .landedOutside, .destroyed:
            let carrierLost = attacker.functionalState.isTerminal || attacker.functionalState == .uncontrolled
            finish(success: false, reason: carrierLost ? .attackerLost : .payloadLost, vehicles: vehicles)
        case .falling:
            // In the air and still able to arrive. Nothing that happens to the aircraft from here
            // can change the answer, and the clock must not take it away either — the load is
            // seconds from the ground and the run is already decided in fact.
            transition(.assessingResult)
        case .carried:
            if remaining <= 0 {
                finish(success: false, reason: .timeExpired, vehicles: vehicles)
            } else if attacker.functionalState.isTerminal {
                // Still aboard a finished aircraft. The session lets go for a wreck that is coming
                // apart, so reaching here means the load went with it.
                finish(success: false, reason: .attackerLost, vehicles: vehicles)
            } else {
                transition(.intercepting)
            }
        }
    }

    /// Logs every impact exactly once, and turns an attacker-target contact into the end of the
    /// current approach. Impacts from another run or another authority are not this run's.
    private mutating func consume(
        impacts: [InterceptImpactEvent],
        attacker: InterceptVehicleSnapshot,
        target: InterceptVehicleSnapshot,
        vehicles: [InterceptVehicleSnapshot]
    ) {
        for impact in impacts where impact.runID == runID && impact.authorityID == authorityID {
            guard knownImpacts.insert(impact.id).inserted else { continue }
            emit(.impact(impact))
            let participants = Set([impact.firstVehicleID, impact.secondEntityID])
            guard participants.contains(attacker.id), participants.contains(target.id) else { continue }
            if phase == .acquiringTarget { acquireTarget() }
            if activeAttempt == nil { beginAttempt(vehicles: vehicles) }
            if activeAttempt != nil { attempts[attempts.count - 1].hadContact = true }
            endAttempt(.contact, vehicles: vehicles)
            transition(.impactResolution)
            assessmentStarted = elapsed
        }
    }

    /// After a contact the mission waits to see what the target actually does. Contact is not a
    /// kill: a target that is still flying and controllable puts the run back into `reattack`.
    private mutating func resolveAssessment(
        startedAt: TimeInterval,
        attacker: InterceptVehicleSnapshot,
        target: InterceptVehicleSnapshot,
        vehicles: [InterceptVehicleSnapshot]
    ) {
        let spent = attacker.payloadState?.canTrigger != true

        if targetTerminalAt == nil, target.functionalState.canAttempt, !spent {
            assessmentStarted = nil
            transition(.reattack)
            return
        }

        // Nothing left to send at it, and it is flying as if nothing had happened. That — not a
        // clock — is what ended the run, and the operator has to be told so.
        //
        // Only an untouched target counts here. A hit aircraft passes through `damaged` and
        // `degraded` on its way down, and both of those still answer `canAttempt`: ending the run
        // the moment one was seen declared a failure while the target was already falling, and the
        // crash that followed a second later could no longer change the verdict.
        if targetTerminalAt == nil, spent, target.functionalState == .nominal {
            finish(success: false, reason: .payloadUnavailable, vehicles: vehicles)
            return
        }

        if elapsed - startedAt >= configuration.assessmentTimeout {
            // Nothing confirmed it in time. That is a failure, never an assumed success — and its
            // reason is the module, if the module is what the operator has run out of.
            finish(success: false, reason: spent ? .payloadUnavailable : .assessmentExpired, vehicles: vehicles)
            return
        }

        transition(.assessingResult)
    }

    /// An approach ends when the aircraft has flown past the target, or when it has been running
    /// long enough that it clearly is not going to connect.
    private mutating func resolveApproach(_ attempt: InterceptAttackAttempt, vehicles: [InterceptVehicleSnapshot]) {
        let flewPast = attempt.closestApproach < configuration.attemptRange
            && distance(vehicles) > configuration.attemptRange * Self.passedRangeMultiplier
        guard flewPast || elapsed - attempt.startedAt >= configuration.attemptTimeout else { return }
        endAttempt(.miss, vehicles: vehicles)
        transition(.reattack)
    }

    // MARK: - Events

    mutating func record(_ kind: InterceptMissionEventKind) { emit(kind) }

    mutating func drainEvents() -> [InterceptMissionEvent] {
        let pending = events
        events.removeAll(keepingCapacity: true)
        return pending
    }

    private func distance(_ vehicles: [InterceptVehicleSnapshot]) -> Float {
        guard let attacker = vehicles.first(where: { $0.role == .attacker }),
              let target = vehicles.first(where: { $0.role == .target }) else { return .greatestFiniteMagnitude }
        return simd_distance(attacker.position, target.position)
    }

    private mutating func endAttempt(_ outcome: InterceptAttemptOutcome, vehicles: [InterceptVehicleSnapshot]) {
        guard activeAttempt != nil else { return }
        let index = attempts.count - 1
        attempts[index].outcome = outcome
        attempts[index].endedAt = elapsed
        attempts[index].after = vehicles
        emit(.attemptEnded(attempts[index].id, outcome))
    }

    /// The result is written once. A later event — including the target finally hitting the
    /// ground after the attacker was already lost — cannot rewrite it.
    private mutating func finish(success: Bool, reason: InterceptResultReason, vehicles: [InterceptVehicleSnapshot]) {
        guard result == nil else { return }
        endAttempt(.aborted, vehicles: vehicles)
        let value = InterceptMissionResult(
            success: success,
            reason: reason,
            timestamp: elapsed,
            attempts: attempts.count
        )
        result = value
        transition(success ? .completed : .failed)
        emit(.result(value))
    }

    private mutating func transition(_ newPhase: InterceptMissionPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        emit(.phase(newPhase))
    }

    private mutating func emit(_ kind: InterceptMissionEventKind) {
        sequence += 1
        events.append(InterceptMissionEvent(
            id: UUID(),
            runID: runID,
            sequence: sequence,
            timestamp: elapsed,
            authorityID: authorityID,
            kind: kind
        ))
    }
}

// MARK: - Event gate

/// Session-long, ordered idempotency for mission events, shared by every consumer of the log —
/// the local timeline recorder today, a LAN transport adapter tomorrow.
///
/// Two rules the stage plan is explicit about. A UI history limit must never serve as the
/// deduplication ledger: the timeline keeps the last 256 entries, and an event that fell off the
/// end is still an event that already happened. And a restart constructs a fresh gate, so events
/// from the previous run cannot reach the new one.
struct InterceptEventGate {
    let runID: UUID
    let authorityID: String
    private var accepted: Set<UUID> = []
    private var lastSequence: UInt64 = 0

    init(runID: UUID, authorityID: String) {
        self.runID = runID
        self.authorityID = authorityID
    }

    mutating func accept(_ event: InterceptMissionEvent) -> Bool {
        guard event.runID == runID,
              event.authorityID == authorityID,
              event.sequence > lastSequence,
              !accepted.contains(event.id) else { return false }
        lastSequence = event.sequence
        accepted.insert(event.id)
        return true
    }
}
