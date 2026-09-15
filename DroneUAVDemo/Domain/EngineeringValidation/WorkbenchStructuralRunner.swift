import Foundation

// Running `cadnext_structural` from the Workbench, keeping each run, and turning the runs into the
// aircraft's «Статическая прочность» record.
//
// A run is stamped when it finishes, against the snapshot and upstream results it was prepared
// from — its own test record, persisted with the run. The aircraft's record is then derived on
// every evaluation, never stored: only case records that are still current enter it, so a changed
// part, material, thrust or equipment mass drops the affected cases out by the same staleness rules
// as everything else.

/// One finished calculation of one load case.
struct WorkbenchStructuralRun: Codable, Hashable {
    static let fileName = "run.json"

    var caseID: UUID
    var caseName: String
    var bodyID: String
    var bodyName: String
    /// Fingerprint of the case as prepared (`WorkbenchStructuralJob.settings`): a case edited since
    /// is a different calculation.
    var caseSettingsFingerprint: String
    var record: EngineeringTestRecord
    /// Folder of the run (job, part, result, field, report), relative to the store's root.
    var directory: String
}

enum WorkbenchStructuralToolLocator {
    static let environmentKey = "CADNEXT_STRUCTURAL_TOOL"
    static let defaultsKey = "engineering.cadnextStructuralPath"

    /// `$CADNEXT_STRUCTURAL_TOOL`, a path set in the app, the app bundle, then the CADNext build trees
    /// next to this source file (the solver needs a build with CADNEXT_WITH_NETGEN=ON).
    static func locate() -> URL? {
        var candidates: [String] = []
        if let path = ProcessInfo.processInfo.environment[environmentKey] { candidates.append(path) }
        if let path = UserDefaults.standard.string(forKey: defaultsKey) { candidates.append(path) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cadnext_structural").path)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for tree in ["build-netgen", "build-gui-occt", "build"] {
            candidates.append(repository.appendingPathComponent("CADNext/\(tree)/fea/occt/cadnext_structural").path)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

/// Runs, per vehicle, under Application Support/UAVSim/Engineering Runs/<vehicle>/.
struct WorkbenchStructuralRunStore {
    let root: URL

    static func standard() throws -> WorkbenchStructuralRunStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return WorkbenchStructuralRunStore(root: base.appendingPathComponent("UAVSim/Engineering Runs", isDirectory: true))
    }

    func vehicleDirectory(_ vehicleID: String) -> URL {
        root.appendingPathComponent(vehicleID, isDirectory: true)
    }

    func makeRunDirectory(vehicleID: String, caseID: UUID, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let directory = vehicleDirectory(vehicleID)
            .appendingPathComponent(caseID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func save(_ run: WorkbenchStructuralRun) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(run).write(to: root.appendingPathComponent(run.directory).appendingPathComponent(WorkbenchStructuralRun.fileName), options: .atomic)
    }

    /// Every run of the vehicle that can still be read; unreadable ones are skipped.
    func runs(vehicleID: String) -> [WorkbenchStructuralRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let enumerator = FileManager.default.enumerator(at: vehicleDirectory(vehicleID), includingPropertiesForKeys: nil) else { return [] }
        var runs: [WorkbenchStructuralRun] = []
        for case let url as URL in enumerator where url.lastPathComponent == WorkbenchStructuralRun.fileName {
            if let data = try? Data(contentsOf: url), let run = try? decoder.decode(WorkbenchStructuralRun.self, from: data) {
                runs.append(run)
            }
        }
        return runs.sorted { $0.record.createdAt < $1.record.createdAt }
    }
}

enum WorkbenchStructuralRunner {
    /// Prepares, runs and records one case. `progress(level, stage)` follows the tool's
    /// "progress <level> <stage>" lines; cancelling the task terminates the process.
    static func run(
        _ loadCase: WorkbenchStructuralCase,
        build: WorkbenchBuild,
        snapshot: EngineeringConfigurationSnapshot,
        state: EngineeringValidationState,
        store: WorkbenchStructuralRunStore,
        tool: URL,
        progress: @escaping @Sendable (Int, String) -> Void = { _, _ in }
    ) async -> Result<WorkbenchStructuralRun, WorkbenchStructuralError> {
        let prepared: WorkbenchStructuralJob
        switch WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) {
        case let .success(job): prepared = job
        case let .failure(error): return .failure(error)
        }
        let directory: URL
        do {
            directory = try store.makeRunDirectory(vehicleID: snapshot.vehicleID, caseID: loadCase.id)
            try Data(prepared.body.geometry.text.utf8).write(to: directory.appendingPathComponent(WorkbenchStructuralJob.partFileName))
            try prepared.jobJSON.write(to: directory.appendingPathComponent("job.json"))
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let exit = await execute(tool: tool, job: directory.appendingPathComponent("job.json"), in: directory, progress: progress)
        let resultURL = directory.appendingPathComponent(WorkbenchStructuralJob.resultFileName)
        guard let data = try? Data(contentsOf: resultURL) else {
            switch exit {
            case let .failure(error): return .failure(error)
            case let .success(status): return .failure(.solverFailed("код завершения \(status), файла результата нет"))
            }
        }
        let result: EngineeringSolverResult
        do {
            result = try EngineeringSolverResult.decode(data, expecting: prepared.testType)
        } catch {
            return .failure(.resultUnreadable(String(describing: error)))
        }

        if let problem = unhonouredJobSettings(job: prepared.jobJSON, result: data) {
            return .failure(.solverFailed(problem))
        }
        var record = EngineeringValidationEngine.makeRecord(
            prepared.testType, snapshot: snapshot, state: state, outcome: result.outcome, metrics: result.metrics,
            source: .computed, solverID: result.solverID, solverVersion: result.solverVersion,
            settings: .object(["case": prepared.settings, "solver": result.settings]),
            warnings: result.warnings, failureReasons: result.failureReasons,
            consumedUpstream: prepared.consumedUpstream)
        let relative = directory.path.replacingOccurrences(of: store.root.path + "/", with: "")
        record.reportRef = relative + "/" + (result.fieldRef ?? WorkbenchStructuralJob.fieldFileName)
        let run = WorkbenchStructuralRun(
            caseID: loadCase.id, caseName: loadCase.name, bodyID: prepared.body.id, bodyName: prepared.body.name,
            caseSettingsFingerprint: prepared.settings.fingerprint, record: record, directory: relative)
        do {
            try store.save(run)
        } catch {
            return .failure(.launchFailed("результат не сохранён: \(error.localizedDescription)"))
        }
        return .success(run)
    }

    /// A solver older than the job format ignores keys it does not know instead of refusing them.
    /// What the job asked for that changes the answer must come back in the result's settings;
    /// otherwise the result is of a different calculation than the record would claim.
    static func unhonouredJobSettings(job: Data, result: Data) -> String? {
        guard let jobObject = try? JSONSerialization.jsonObject(with: job) as? [String: Any],
              let resultObject = try? JSONSerialization.jsonObject(with: result) as? [String: Any] else { return nil }
        let stale = "решатель cadnext_structural устарел и проигнорировал часть задания — пересоберите его"
        if let modal = jobObject["modal"] as? [String: Any], let masses = modal["attachedMasses"] as? [[String: Any]], !masses.isEmpty {
            let echoed = ((resultObject["settings"] as? [String: Any])?["modal"] as? [String: Any])?["attachedMasses"] as? [[String: Any]]
            guard let echoed, echoed.count == masses.count else { return stale + " (присоединённые массы)" }
        }
        return nil
    }

    private final class Box: @unchecked Sendable {
        var buffer = Data()
        let lock = NSLock()
    }

    private static func execute(
        tool: URL,
        job: URL,
        in directory: URL,
        progress: @escaping @Sendable (Int, String) -> Void
    ) async -> Result<Int32, WorkbenchStructuralError> {
        let process = Process()
        process.executableURL = tool
        process.arguments = [job.path]
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let box = Box()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            box.lock.lock()
            box.buffer.append(chunk)
            var lines: [String] = []
            while let newline = box.buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: box.buffer[box.buffer.startIndex..<newline], as: UTF8.self))
                box.buffer.removeSubrange(box.buffer.startIndex...newline)
            }
            box.lock.unlock()
            for line in lines {
                let parts = line.split(separator: " ")
                if parts.count == 3, parts[0] == "progress", let level = Int(parts[1]) {
                    progress(level, String(parts[2]))
                }
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { finished in
                    output.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: .success(finished.terminationStatus))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(returning: .failure(.launchFailed(error.localizedDescription)))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// The aircraft's «Статическая прочность» and «Модальный анализ и вибрации», each derived from the
/// current records of its cases.
///
/// Rule (user's decision, 2026-09-15): the worst result over every solid of the frame. A solid with
/// no current case, or a case that is no longer current, keeps the verdict at WARNING at best — the
/// aircraft is not shown strong, or clear of resonance, where nobody calculated it.
enum WorkbenchStructuralAggregate {
    struct CaseStatus: Hashable {
        let loadCase: WorkbenchStructuralCase
        let run: WorkbenchStructuralRun?
        /// Why the latest run does not count, when it does not.
        let staleReasons: [String]
        var isCurrent: Bool { run != nil && staleReasons.isEmpty }
    }

    /// Per case of the blueprint: its latest run and whether that run still describes the build.
    /// `testType` nil: every case of the blueprint.
    static func caseStatuses(
        build: WorkbenchBuild,
        snapshot: EngineeringConfigurationSnapshot,
        upstreamRecords: [EngineeringTestRecord],
        runs: [WorkbenchStructuralRun],
        testType: EngineeringTestType? = nil
    ) -> [CaseStatus] {
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: upstreamRecords)
        return build.structuralCases.filter { testType == nil || $0.testType == testType }.map { loadCase in
            guard let run = runs.last(where: { $0.caseID == loadCase.id && $0.record.testType == loadCase.testType }) else {
                return CaseStatus(loadCase: loadCase, run: nil, staleReasons: [])
            }
            var reasons: [String] = []
            switch WorkbenchStructuralJob.prepare(loadCase, build: build, state: state) {
            case let .success(job):
                if job.settings.fingerprint != run.caseSettingsFingerprint {
                    reasons.append("вариант нагрузок изменён после расчёта")
                }
            case let .failure(error):
                reasons.append(error.description)
            }
            if run.record.outcome == .error {
                reasons.append("расчёт не выполнен: " + (run.record.failureReasons.first ?? "причина не указана"))
                return CaseStatus(loadCase: loadCase, run: run, staleReasons: reasons)
            }
            let evaluation = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: upstreamRecords + [run.record])
                .evaluation(loadCase.testType)
            if let evaluation, !evaluation.status.isCurrent {
                reasons.append(contentsOf: evaluation.reasons.map(\.displayText))
                if evaluation.reasons.isEmpty { reasons.append("результат не актуален") }
            }
            return CaseStatus(loadCase: loadCase, run: run, staleReasons: reasons)
        }
    }

    static func record(
        _ testType: EngineeringTestType = .structuralStatic,
        build: WorkbenchBuild,
        snapshot: EngineeringConfigurationSnapshot,
        upstreamRecords: [EngineeringTestRecord],
        runs: [WorkbenchStructuralRun]
    ) -> EngineeringTestRecord? {
        guard case let .imported(construction) = build.frame, let bodies = construction.bodies, !bodies.isEmpty else { return nil }
        let statuses = caseStatuses(build: build, snapshot: snapshot, upstreamRecords: upstreamRecords, runs: runs, testType: testType)
        let current = statuses.filter(\.isCurrent)
        guard !current.isEmpty else { return nil }

        // Coverage caveats decide the verdict; the cases' own notes are carried along but do not —
        // a PASS case may well note something informational.
        var caveats: [String] = []
        var warnings: [String] = []
        var failures: [String] = []
        let uncovered = bodies.filter { body in !current.contains { $0.loadCase.bodyID == body.id } }
        if !uncovered.isEmpty {
            caveats.append("не проверены детали: " + uncovered.map { "«\($0.name)»" }.joined(separator: ", "))
        }
        for status in statuses where status.run != nil && !status.isCurrent {
            caveats.append("вариант «\(status.loadCase.name)» не учтён: " + status.staleReasons.joined(separator: "; "))
        }
        var governing: CaseStatus?
        var outcomes: [EngineeringTestOutcome] = []
        for status in current {
            guard let run = status.run else { continue }
            let record = run.record
            outcomes.append(record.outcome)
            let label = "«\(status.loadCase.name)» (\(run.bodyName))"
            failures.append(contentsOf: record.failureReasons.map { "\(label): \($0)" })
            warnings.append(contentsOf: record.warnings.map { "\(label): \($0)" })
            if record.outcome == .error { continue }
            // Strength: the smallest reserve factor governs. Modes: the smallest separation from an
            // excitation band, or without bands the lowest first frequency.
            func key(_ r: EngineeringTestRecord) -> Double {
                if testType == .modalVibration {
                    return r.metrics["minimumBandSeparation"]?.value ?? r.metrics["firstFrequencyHz"]?.value ?? .infinity
                }
                return r.metrics["reserveFactor"]?.value ?? .infinity
            }
            if governing == nil || key(record) < key(governing!.run!.record) { governing = status }
        }

        let outcome: EngineeringTestOutcome
        if outcomes.contains(.fail) {
            outcome = .fail
        } else if outcomes.allSatisfy({ $0 == .error }) {
            outcome = .error
        } else if outcomes.contains(.warning) || outcomes.contains(.error) || !caveats.isEmpty {
            outcome = .warning
        } else {
            outcome = .pass
        }

        var metrics: [String: EngineeringMetric] = [
            "checkedBodies": EngineeringMetric(Double(bodies.count - uncovered.count), unit: "1"),
            "totalBodies": EngineeringMetric(Double(bodies.count), unit: "1"),
        ]
        if let record = governing?.run?.record {
            let carried = testType == .modalVibration
                ? ["firstFrequencyHz", "minimumBandSeparation"]
                : ["reserveFactor", "maxVonMisesPa", "maxDisplacementM"]
            for key in carried {
                if let metric = record.metrics[key] { metrics[key] = metric }
            }
            warnings.insert("определяющий вариант: «\(governing!.loadCase.name)» (\(governing!.run!.bodyName))", at: 0)
        }
        warnings.insert(contentsOf: caveats, at: 0)
        let consumed = Set(current.flatMap { $0.run!.record.upstream.keys }.compactMap(EngineeringTestType.init(rawValue:)))
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: upstreamRecords)
        var record = EngineeringValidationEngine.makeRecord(
            testType, snapshot: snapshot, state: state, outcome: outcome, metrics: metrics,
            source: .computed,
            solverID: current.first!.run!.record.solverID,
            solverVersion: current.first!.run!.record.solverVersion,
            settings: .array(current.map { .string($0.run!.caseSettingsFingerprint) }.sorted { $0.fingerprint < $1.fingerprint }),
            warnings: warnings, failureReasons: failures,
            consumedUpstream: consumed,
            createdAt: current.map { $0.run!.record.createdAt }.max()!)
        record.reportRef = governing?.run?.record.reportRef
        return record
    }
}
