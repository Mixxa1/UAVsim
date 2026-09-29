import Foundation

/// What an external solver hands back: the solver half of a TestRecord (spec §4, §16).
///
/// The solver concludes — outcome, metrics, warnings, the settings it ran with. It does not
/// know which configuration inputs and upstream results it consumed; the Validation Engine
/// stamps those on (`EngineeringValidationEngine.makeRecord(from:…)`), so a solver cannot
/// claim a snapshot it was never given.
///
/// Wire formats, both written by `cadnext_structural` and sharing this envelope:
/// `cadnext-structural-result/1` (static strength), `cadnext-modal-result/1` (natural modes
/// against excitation bands; its modes and resonance findings ride along for display) and
/// `cadnext-shock-result/1` (one acceleration pulse: the response histories and the input's shock
/// response spectrum ride along). The
/// examples in `CADNext/fea/schema/` are decoded by `Tools/EngineeringValidationProbe` and matched
/// key-for-key by the C++ tests that produce them.
struct EngineeringSolverResult: Decodable, Hashable {
    /// Each schema belongs to exactly one test, so a file cannot be filed under the wrong test by
    /// its `testType` alone.
    static let schemaTests: [String: EngineeringTestType] = [
        "cadnext-structural-result/1": .structuralStatic,
        "cadnext-modal-result/1": .modalVibration,
        // Sine and random are the same test as the modes: one verdict on vibration, three kinds of case.
        "cadnext-harmonic-result/1": .modalVibration,
        "cadnext-random-result/1": .modalVibration,
        "cadnext-shock-result/1": .mechanicalShock,
        "cadnext-climate-result/1": .climatic,
        "cadnext-fire-result/1": .fireResistance,
        "cadnext-lightning-result/1": .lightningDirect,
        "cadnext-emc-result/1": .radiatedSusceptibility,
        "cadnext-icing-result/1": .icing,
        "cadnext-flutter-result/1": .flutter,
        "cadnext-bird-result/1": .birdStrike,
        "cadnext-aerodynamics-result/1": .aerodynamics,
    ]
    static var supportedSchemas: Set<String> { Set(schemaTests.keys) }

    let schema: String
    let testType: EngineeringTestType
    let outcome: EngineeringTestOutcome
    let solverID: String
    let solverVersion: String
    let metrics: [String: EngineeringMetric]
    let warnings: [String]
    let failureReasons: [String]
    /// Everything that defines the calculation (material, mesh, load case, mesher). Fingerprinted
    /// into the record, so the same part under a different load case is a different result.
    let settings: EngineeringCanonicalValue
    let fieldRef: String?
    let aeroTable: EngineeringAeroTable?

    enum DecodeError: Error, CustomStringConvertible {
        case unsupportedSchema(String)
        case wrongTest(expected: EngineeringTestType, found: EngineeringTestType)

        var description: String {
            switch self {
            case let .unsupportedSchema(schema):
                return "unsupported solver result schema \(schema)"
            case let .wrongTest(expected, found):
                return "result is for \(found.rawValue), expected \(expected.rawValue)"
            }
        }
    }

    static func decode(_ data: Data, expecting test: EngineeringTestType) throws -> EngineeringSolverResult {
        let result = try JSONDecoder().decode(EngineeringSolverResult.self, from: data)
        guard let schemaTest = schemaTests[result.schema] else { throw DecodeError.unsupportedSchema(result.schema) }
        guard result.testType == test else { throw DecodeError.wrongTest(expected: test, found: result.testType) }
        guard schemaTest == test else { throw DecodeError.wrongTest(expected: schemaTest, found: result.testType) }
        // A CFD result may legitimately have no table: the run finished and wrote its fields, but a
        // point did not converge or the near-wall mesh was not in a valid y+ regime, and the solver
        // says so instead of exporting coefficients. The table, when present, must still be sound.
        if test == .aerodynamics, result.outcome != .error, let table = result.aeroTable,
           let problem = table.problem {
            throw WorkbenchAeroError.message(problem)
        }
        return result
    }
}

extension EngineeringValidationEngine {
    static func makeRecord(
        from result: EngineeringSolverResult,
        snapshot: EngineeringConfigurationSnapshot,
        state: EngineeringValidationState,
        consumedUpstream: Set<EngineeringTestType>? = nil,
        createdAt: Date = Date()
    ) -> EngineeringTestRecord {
        var record = makeRecord(
            result.testType,
            snapshot: snapshot,
            state: state,
            outcome: result.outcome,
            metrics: result.metrics,
            source: .computed,
            solverID: result.solverID,
            solverVersion: result.solverVersion,
            settings: result.settings,
            warnings: result.warnings,
            failureReasons: result.failureReasons,
            consumedUpstream: consumedUpstream,
            createdAt: createdAt)
        record.reportRef = result.fieldRef
        record.aerodynamicTable = result.aeroTable
        return record
    }
}
