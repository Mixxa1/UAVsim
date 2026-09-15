import Foundation

/// Why a record no longer describes the configuration. Specific on purpose: spec §11 asks for
/// "Wing material changed", not a grey badge.
enum EngineeringStalenessReason: Hashable {
    case inputChanged(EngineeringInputCategory, items: [String])
    /// An upstream result this record read is itself not current (outdated, missing, error,
    /// running). It may turn out unchanged once recalculated — see `upstreamResultChanged`.
    case upstreamNotCurrent(EngineeringTestType)
    /// The upstream was recalculated and its numbers differ from the ones this record read.
    case upstreamResultChanged(EngineeringTestType)
    /// A required upstream is absent from the record — it was computed without an input its
    /// own definition says it cannot do without.
    case requiredUpstreamMissing(EngineeringTestType)
    case definitionChanged(recorded: Int, current: Int)
    /// Written by a newer schema than this build understands (spec §17 "incompatible").
    case schemaIncompatible(recorded: Int, supported: Int)

    var displayText: String {
        switch self {
        case let .inputChanged(category, items):
            let list = items.isEmpty ? "" : ": " + items.joined(separator: ", ")
            return "Изменились \(category.displayName)\(list)"
        case let .upstreamNotCurrent(test):
            return "Зависит от неактуального результата «\(test.displayName)»"
        case let .upstreamResultChanged(test):
            return "Пересчитан «\(test.displayName)», результат изменился"
        case let .requiredUpstreamMissing(test):
            return "Посчитан без обязательного «\(test.displayName)»"
        case let .definitionChanged(recorded, current):
            return "Изменилась методика испытания (v\(recorded) → v\(current))"
        case let .schemaIncompatible(recorded, supported):
            return "Формат записи v\(recorded) новее поддерживаемого v\(supported)"
        }
    }
}

struct EngineeringTestEvaluation: Hashable {
    let type: EngineeringTestType
    let status: EngineeringTestStatus
    let record: EngineeringTestRecord?
    let reasons: [EngineeringStalenessReason]
    let isRequiredForReadiness: Bool
}

/// Aggregate state of one configuration (spec §4 ValidationState).
struct EngineeringValidationState: Hashable {
    let vehicleID: String
    let snapshotID: String
    let airframe: EngineeringAirframeKind
    let readiness: EngineeringReadiness
    /// Applicable tests only, in dependency order.
    let evaluations: [EngineeringTestEvaluation]

    func evaluation(_ type: EngineeringTestType) -> EngineeringTestEvaluation? {
        evaluations.first { $0.type == type }
    }

    var outdatedTests: [EngineeringTestType] {
        evaluations.filter { $0.status == .outdated }.map(\.type)
    }

    func count(_ status: EngineeringTestStatus) -> Int {
        evaluations.filter { $0.status == status }.count
    }
}

/// Decides, for a snapshot and the records on hand, what is still true (spec §10).
///
/// Pure and cheap: a pass over ten definitions comparing fingerprints. Nothing is recomputed
/// and nothing is written — the answer is derived every time from what the records say they
/// consumed, so it cannot drift from the data.
enum EngineeringValidationEngine {
    static func evaluate(
        snapshot: EngineeringConfigurationSnapshot,
        records: [EngineeringTestRecord],
        running: Set<EngineeringTestType> = [],
        inspectionRequired: Bool = false,
        definitions: [EngineeringTestDefinition] = EngineeringTestCatalog.definitions
    ) -> EngineeringValidationState {
        guard let order = EngineeringTestCatalog.topologicalOrder(definitions) else {
            preconditionFailure("engineering test definitions contain a cycle")
        }
        let airframe = snapshot.airframe
        let latest = latestRecords(records, vehicleID: snapshot.vehicleID)
        var byType: [EngineeringTestType: EngineeringTestEvaluation] = [:]
        var evaluations: [EngineeringTestEvaluation] = []

        for type in order {
            guard let definition = definitions.first(where: { $0.type == type }),
                  definition.applies(to: airframe) else { continue }
            let evaluation = evaluateOne(
                definition: definition,
                snapshot: snapshot,
                record: latest[type],
                running: running.contains(type),
                upstreamEvaluations: byType)
            byType[type] = evaluation
            evaluations.append(evaluation)
        }

        return EngineeringValidationState(
            vehicleID: snapshot.vehicleID,
            snapshotID: snapshot.snapshotID,
            airframe: airframe,
            readiness: readiness(evaluations, inspectionRequired: inspectionRequired),
            evaluations: evaluations)
    }

    /// Stamps a solver's output with what it consumed, reading upstream results from the
    /// current evaluation. The only sanctioned way to make a record: a record built by hand
    /// can claim inputs it never read.
    ///
    /// Only current upstream results are stamped. A solver must not be fed a stale one — and
    /// if it was, the record says it ran without it rather than pretending otherwise.
    static func makeRecord(
        _ type: EngineeringTestType,
        snapshot: EngineeringConfigurationSnapshot,
        state: EngineeringValidationState,
        outcome: EngineeringTestOutcome,
        metrics: [String: EngineeringMetric],
        source: EngineeringResultSource = .computed,
        solverID: String,
        solverVersion: String,
        settings: EngineeringCanonicalValue = .object([:]),
        warnings: [String] = [],
        failureReasons: [String] = [],
        /// Upstream results the solver actually read. `nil` means every current one; a
        /// clean-airframe CFD sweep passes its required set only, so the record does not
        /// claim a propwash it never modelled.
        consumedUpstream: Set<EngineeringTestType>? = nil,
        createdAt: Date = Date()
    ) -> EngineeringTestRecord {
        let definition = EngineeringTestCatalog.definition(type)
        var inputs: [String: [String: String]] = [:]
        for category in definition.inputs {
            inputs[category.rawValue] = snapshot.itemFingerprints(category)
        }
        var upstream: [String: String] = [:]
        for edge in definition.upstream where consumedUpstream?.contains(edge.test) ?? true {
            guard let evaluation = state.evaluation(edge.test),
                  evaluation.status.isCurrent,
                  let record = evaluation.record else { continue }
            upstream[edge.test.rawValue] = record.outputFingerprint
        }
        return EngineeringTestRecord(
            id: UUID(),
            schemaVersion: EngineeringTestRecord.currentSchemaVersion,
            testType: type,
            definitionVersion: definition.definitionVersion,
            validationRulesVersion: EngineeringTestCatalog.validationRulesVersion,
            outcome: outcome,
            source: source,
            vehicleID: snapshot.vehicleID,
            snapshotID: snapshot.snapshotID,
            inputs: inputs,
            upstream: upstream,
            settingsFingerprint: settings.fingerprint,
            metrics: metrics,
            warnings: warnings,
            failureReasons: failureReasons,
            solverID: solverID,
            solverVersion: solverVersion,
            createdAt: createdAt,
            reportRef: nil,
            override: nil)
    }

    // MARK: - Internals

    private static func latestRecords(
        _ records: [EngineeringTestRecord],
        vehicleID: String
    ) -> [EngineeringTestType: EngineeringTestRecord] {
        var latest: [EngineeringTestType: EngineeringTestRecord] = [:]
        for record in records where record.vehicleID == vehicleID {
            if let existing = latest[record.testType], existing.createdAt >= record.createdAt { continue }
            latest[record.testType] = record
        }
        return latest
    }

    private static func evaluateOne(
        definition: EngineeringTestDefinition,
        snapshot: EngineeringConfigurationSnapshot,
        record: EngineeringTestRecord?,
        running: Bool,
        upstreamEvaluations: [EngineeringTestType: EngineeringTestEvaluation]
    ) -> EngineeringTestEvaluation {
        let required = definition.isRequiredForReadiness(on: snapshot.airframe)
        func result(_ status: EngineeringTestStatus, _ reasons: [EngineeringStalenessReason]) -> EngineeringTestEvaluation {
            EngineeringTestEvaluation(
                type: definition.type,
                status: running ? .running : status,
                record: record,
                reasons: reasons,
                isRequiredForReadiness: required)
        }
        guard let record else { return result(.notRun, []) }

        if record.schemaVersion > EngineeringTestRecord.currentSchemaVersion {
            return result(.outdated, [.schemaIncompatible(
                recorded: record.schemaVersion,
                supported: EngineeringTestRecord.currentSchemaVersion)])
        }

        var reasons: [EngineeringStalenessReason] = []
        if record.definitionVersion != definition.definitionVersion {
            reasons.append(.definitionChanged(
                recorded: record.definitionVersion,
                current: definition.definitionVersion))
        }

        for category in EngineeringInputCategory.allCases where definition.inputs.contains(category) {
            let recorded = record.inputs[category.rawValue] ?? [:]
            let current = snapshot.itemFingerprints(category)
            guard recorded != current else { continue }
            let keys = Set(recorded.keys).union(current.keys)
            let changed = keys.filter { recorded[$0] != current[$0] }.sorted()
            reasons.append(.inputChanged(category, items: changed))
        }

        for edge in definition.upstream {
            let isRequired = edge.requiredFor.contains(snapshot.airframe)
            guard let consumed = record.upstream[edge.test.rawValue] else {
                if isRequired { reasons.append(.requiredUpstreamMissing(edge.test)) }
                continue
            }
            guard let upstream = upstreamEvaluations[edge.test],
                  upstream.status.isCurrent,
                  let upstreamRecord = upstream.record else {
                reasons.append(.upstreamNotCurrent(edge.test))
                continue
            }
            if upstreamRecord.outputFingerprint != consumed {
                reasons.append(.upstreamResultChanged(edge.test))
            }
        }

        guard reasons.isEmpty else { return result(.outdated, reasons) }
        switch record.outcome {
        case .pass: return result(.pass, [])
        case .warning: return result(.warning, [])
        case .fail: return result(.fail, [])
        case .error: return result(.error, [])
        }
    }

    /// Readiness rules, in order of precedence:
    /// 1. inspection pending → `inspectionRequired`;
    /// 2. a required test FAILs without an accepted override → `notReady` (from any source: a
    ///    closed-form estimate that finds no servo on an aeroplane is right about it);
    /// 3. no required test has a current *calculated* result → `notValidated` — fallback
    ///    estimates alone are not a validation;
    /// 4. every required test PASSes and none of them rests on a fallback estimate → `ready`;
    /// 5. anything else (WARNING, an overridden FAIL, OUTDATED, NOT_RUN, ERROR, RUNNING, a
    ///    fallback PASS) → `conditional`.
    ///
    /// ERROR is conditional, not `notReady`: a solver that did not finish has not shown the
    /// aircraft to be unsafe (spec §16).
    static func readiness(
        _ evaluations: [EngineeringTestEvaluation],
        inspectionRequired: Bool
    ) -> EngineeringReadiness {
        if inspectionRequired { return .inspectionRequired }
        let required = evaluations.filter(\.isRequiredForReadiness)
        if required.contains(where: { $0.status == .fail && $0.record?.override == nil }) {
            return .notReady
        }
        let calculated = { (evaluation: EngineeringTestEvaluation) in evaluation.record?.source != .fallback }
        if !required.contains(where: { $0.status.isCurrent && calculated($0) }) { return .notValidated }
        if required.allSatisfy({ $0.status == .pass && calculated($0) }) { return .ready }
        return .conditional
    }
}
