import Foundation

/// What an external solver hands back: the solver half of a TestRecord (spec §4, §16).
///
/// The solver concludes — outcome, metrics, warnings, the settings it ran with. It does not
/// know which configuration inputs and upstream results it consumed; the Validation Engine
/// stamps those on (`EngineeringValidationEngine.makeRecord(from:…)`), so a solver cannot
/// claim a snapshot it was never given.
///
/// Wire formats, both written by `cadnext_structural` and sharing this envelope:
/// `cadnext-structural-result/1` (static strength) and `cadnext-modal-result/1` (natural modes
/// against excitation bands; its modes and resonance findings ride along for display). The
/// examples in `CADNext/fea/schema/` are decoded by `Tools/EngineeringValidationProbe` and matched
/// key-for-key by the C++ tests that produce them.
struct EngineeringSolverResult: Decodable, Hashable {
    /// Each schema belongs to exactly one test, so a file cannot be filed under the wrong test by
    /// its `testType` alone.
    static let schemaTests: [String: EngineeringTestType] = [
        "cadnext-structural-result/1": .structuralStatic,
        "cadnext-modal-result/1": .modalVibration,
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
        return record
    }
}
