import Foundation

struct WorkbenchAeroSettings: Codable, Hashable {
    var model = "sst"
    var alphaDeg: [Double] = [-10, -5, 0, 5, 10, 15, 20]
    var betaDeg: [Double] = [0]
    var speedMps = 20.0
    var densityKgM3 = 1.225
    var viscosityPaS = 1.7894e-5
    var reference = EngineeringAeroTable.Reference(areaM2: 0, spanM: 0, chordM: 0, momentCenterModelM: [0, 0, 0])
    var iterations = 2000
    var convergenceWindow = 100
    var threads = 2
    var residualTarget = -6.0
    var coefficientAbsoluteTolerance = 1e-4
    var coefficientRelativeTolerance = 1e-3
    var timeoutSeconds = 3600.0
    var farfieldLengths = 10.0
    var wallSizeM = 0.0
    var farfieldSizeM = 0.0
    var grading = 0.3
    var layerHeightsM: [Double] = []

    static func initial(for build: WorkbenchBuild) -> Self {
        var s = Self()
        let frame = build.resolvedFrame
        s.reference.areaM2 = frame.wingAreaM2
        s.reference.spanM = Double(frame.sizeMeters.x)
        s.reference.chordM = s.reference.areaM2 / max(s.reference.spanM, 1e-6)
        let length = max(Double(frame.sizeMeters.x), Double(frame.sizeMeters.z))
        s.wallSizeM = length / 50
        s.farfieldSizeM = length
        // These are editable starting values. The result remains WARNING until grid/domain
        // sensitivity and wall resolution have been established by the analyst.
        s.layerHeightsM = (0..<12).map { length * 1e-5 * pow(1.25, Double($0)) }
        return s
    }

    var canonical: EngineeringCanonicalValue {
        guard let data = try? JSONEncoder().encode(self), let value = try? JSONDecoder().decode(EngineeringCanonicalValue.self, from: data) else {
            return .string("invalid-settings")
        }
        return value
    }

    var problem: String? {
        guard !alphaDeg.isEmpty, !betaDeg.isEmpty, alphaDeg.count <= 181, betaDeg.count <= 181,
              alphaDeg.count * betaDeg.count <= 256 else { return "Задайте от 1 до 256 расчётных точек." }
        let table = EngineeringAeroTable(schema: "uavsim-aerodynamics/1", frame: "flight-body-rhu", reference: reference,
            speedMps: speedMps, densityKgM3: densityKgM3, viscosityPaS: viscosityPaS, model: model,
            alphaDeg: alphaDeg, betaDeg: betaDeg,
            points: alphaDeg.flatMap { a in betaDeg.map { b in .init(alphaDeg: a, betaDeg: b, cl: 0, cd: 0, cm: 0, cy: 0, cRoll: 0, cYaw: 0) } })
        if let problem = table.problem { return problem }
        guard ["euler", "laminar", "sst"].contains(model) else { return "Выберите Euler, laminar или SST." }
        guard [wallSizeM, farfieldSizeM, farfieldLengths, grading, timeoutSeconds, coefficientAbsoluteTolerance, coefficientRelativeTolerance].allSatisfy({ $0.isFinite && $0 > 0 }), grading <= 1 else { return "Задайте положительные размеры сетки, время и допуски." }
        guard convergenceWindow >= 5, iterations >= convergenceWindow + 2, iterations <= 1_000_000, (1...256).contains(threads), residualTarget.isFinite, (-15 ... -3).contains(residualTarget) else { return "Некорректные параметры сходимости или число потоков." }
        guard layerHeightsM.count <= 100, layerHeightsM.allSatisfy({ $0.isFinite && $0 > 0 }),
              layerHeightsM.reduce(0, +) <= farfieldLengths * reference.spanM,
              (model == "euler") == layerHeightsM.isEmpty else { return "Вязкий расчёт требует слоёв; Euler — сетки без слоёв." }
        return nil
    }
}

struct WorkbenchAeroRun: Codable, Hashable, Identifiable {
    var id: UUID { record.id }
    var record: EngineeringTestRecord
    var settings: WorkbenchAeroSettings?
    /// Optional local artifacts; the record and runtime table travel inside .uavbuild.
    var artifactDirectory: String?
}

enum WorkbenchAeroError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(text) = self { return text }; return "CFD error" }
}

enum WorkbenchAeroToolLocator {
    static func locate(_ name: String, environment: String, relative: String) -> URL? {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates = [ProcessInfo.processInfo.environment[environment], UserDefaults.standard.string(forKey: environment)].compactMap { $0 }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/" + name).path)
        candidates.append(contentsOf: ["build-netgen", "build-gui-occt", "build"].map { repo.appendingPathComponent("CADNext/\($0)/" + relative).path })
        if name == "SU2_CFD" { candidates.append(repo.appendingPathComponent("CADNext/third_party/su2/install/bin/SU2_CFD").path) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
    static var adapter: URL? { locate("cadnext_cfd", environment: "CADNEXT_CFD_TOOL", relative: "cfd/occt/cadnext_cfd") }
    static var solver: URL? { locate("SU2_CFD", environment: "CADNEXT_SU2_CFD", relative: "SU2_CFD") }
}

enum WorkbenchAeroRunner {
    struct Prepared {
        var job: Data
        var bodies: [WorkbenchConstruction.Body]
    }

    static func prepare(build: WorkbenchBuild, settings: WorkbenchAeroSettings, solver: URL) throws -> Prepared {
        if let problem = settings.problem { throw WorkbenchAeroError.message(problem) }
        guard case let .imported(frame) = build.frame, let axes = frame.cadAxes, let bodies = frame.bodies, !bodies.isEmpty,
              axes.lengthUnit == "m" else { throw WorkbenchAeroError.message("Нужна рама .uavframe v2 с точными BRep-телами и осями CAD.") }
        if let problem = frame.exactGeometryProblem() { throw WorkbenchAeroError.message(problem) }
        guard EngineeringFrameConvention.Axis(rawValue: axes.forward) != nil,
              EngineeringFrameConvention.Axis(rawValue: axes.up) != nil,
              axes.forward.last != axes.up.last else { throw WorkbenchAeroError.message("Неверные оси CAD.") }
        let geometry: [[String: Any]] = bodies.enumerated().map { i, body in
            ["id": body.id, "path": "body-\(i).brep", "sha256": body.geometry.sha256]
        }
        let settingsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        // External equipment is represented explicitly by its resolved envelope. Its approximation
        // is reported in the result; it must never silently disappear from the wetted airframe.
        let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
        var proxies: [[String: Any]] = []
        for (id, item) in snapshot.items(.outerGeometry).sorted(by: { $0.key < $1.key }) where id != "frame" && id != "cadAxes" {
            guard case let .object(fields) = item, case let .array(center)? = fields["position"],
                  case let .array(size)? = fields["envelope"] else { throw WorkbenchAeroError.message("Не задано размещение внешнего компонента \(id).") }
            func numbers(_ values: [EngineeringCanonicalValue]) throws -> [Double] {
                try values.map { value in guard case let .number(v) = value, v.isFinite else { throw WorkbenchAeroError.message("Неверный габарит \(id).") }; return v }
            }
            proxies.append(["id": id, "centerModelM": try numbers(center), "sizeModelM": try numbers(size)])
        }
        let object: [String: Any] = ["schema": "cadnext-aerodynamics-job/1", "solverPath": solver.path,
            "resultPath": "result.json", "workDirectory": "flow", "cadAxes": ["forward": axes.forward, "up": axes.up, "lengthUnit": "m"],
            "geometry": geometry, "proxies": proxies, "settings": settingsObject]
        return Prepared(job: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), bodies: bodies)
    }

    static func importTable(_ data: Data, build: WorkbenchBuild) throws -> WorkbenchAeroRun {
        let table = try JSONDecoder().decode(EngineeringAeroTable.self, from: data)
        if let problem = table.problem { throw WorkbenchAeroError.message(problem) }
        let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: [])
        var record = EngineeringValidationEngine.makeRecord(.aerodynamics, snapshot: snapshot, state: state, outcome: .warning,
            metrics: ["completedPoints": .init(Double(table.points.count), unit: "1")], source: .imported,
            solverID: "aero-table-import", solverVersion: table.schema, settings: .string(table.fingerprint),
            warnings: ["Импортированная таблица привязана пользователем к текущей конфигурации; сеточная погрешность и происхождение коэффициентов не проверены.",
                       "Рули, динамические производные и режимы вне таблицы используют исходный профиль."], consumedUpstream: [])
        record.aerodynamicTable = table
        return WorkbenchAeroRun(record: record, settings: nil, artifactDirectory: nil)
    }

    /// `root` is injectable for headless tests. Every attempt gets a UUID directory and a record,
    /// including launch failure and cancellation. Successful artifacts are never reused.
    static func run(build: WorkbenchBuild, settings: WorkbenchAeroSettings, tool: URL, solver: URL, root: URL,
                    progress: @escaping @Sendable (String) -> Void = { _ in }) async -> WorkbenchAeroRun {
        let snapshot = WorkbenchEngineeringSnapshot.make(from: build)
        let state = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: build.aerodynamicRuns.map(\.record))
        let directory = root.appendingPathComponent(build.id.uuidString.lowercased()).appendingPathComponent(UUID().uuidString.lowercased())
        var record: EngineeringTestRecord
        do {
            try Task.checkCancellation()
            let prepared = try prepare(build: build, settings: settings, solver: solver)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (i, body) in prepared.bodies.enumerated() {
                try Data(body.geometry.text.utf8).write(to: directory.appendingPathComponent("body-\(i).brep"))
            }
            try prepared.job.write(to: directory.appendingPathComponent("job.json"))
            let status = try await execute(tool: tool, directory: directory, progress: progress)
            try Task.checkCancellation()
            let data = try Data(contentsOf: directory.appendingPathComponent("result.json"))
            let result = try EngineeringSolverResult.decode(data, expecting: .aerodynamics)
            guard status == 0 || result.outcome == .error else { throw WorkbenchAeroError.message("Процесс завершился с кодом \(status); результат не принят.") }
            if result.outcome != .error {
                guard let resultObject = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let echo = resultObject["settings"] as? [String: Any] else { throw WorkbenchAeroError.message("Нет подтверждения настроек расчёта.") }
                let echoed = try JSONDecoder().decode(WorkbenchAeroSettings.self, from: JSONSerialization.data(withJSONObject: echo))
                guard let table = result.aeroTable, table.reference == settings.reference,
                      table.model == settings.model, table.alphaDeg == settings.alphaDeg, table.betaDeg == settings.betaDeg,
                      table.speedMps == settings.speedMps, table.densityKgM3 == settings.densityKgM3,
                      table.viscosityPaS == settings.viscosityPaS else { throw WorkbenchAeroError.message("Аэротаблица не соответствует настройкам результата.") }
                guard let input = try JSONSerialization.jsonObject(with: prepared.job) as? [String: Any],
                      let axes = input["cadAxes"] as? [String: String],
                      echo["cadForward"] as? String == axes["forward"], echo["cadUp"] as? String == axes["up"] else {
                    throw WorkbenchAeroError.message("Результат использует другую систему осей.")
                }
                let expectedProxies = try JSONSerialization.data(withJSONObject: input["proxies"] ?? [])
                let actualProxies = try JSONSerialization.data(withJSONObject: echo["proxies"] ?? [])
                guard try JSONDecoder().decode(EngineeringCanonicalValue.self, from: expectedProxies)
                        == JSONDecoder().decode(EngineeringCanonicalValue.self, from: actualProxies) else {
                    throw WorkbenchAeroError.message("Решатель не учёл внешнее оборудование.")
                }
                guard echoed == settings else { throw WorkbenchAeroError.message("Решатель проигнорировал настройки задания; результат не принят.") }
                let expected = prepared.bodies.map { ["id": $0.id, "sha256": $0.geometry.sha256] }
                guard let actual = echo["geometry"] as? [[String: String]], actual == expected else { throw WorkbenchAeroError.message("Результат относится к другой геометрии.") }
            }
            record = EngineeringValidationEngine.makeRecord(from: result, snapshot: snapshot, state: state, consumedUpstream: [])
        } catch {
            record = EngineeringValidationEngine.makeRecord(.aerodynamics, snapshot: snapshot, state: state, outcome: .error,
                metrics: [:], solverID: "cadnext-su2", solverVersion: "adapter/1", settings: settings.canonical,
                failureReasons: [Task.isCancelled ? "Расчёт отменён." : String(describing: error)], consumedUpstream: [])
        }
        record.reportRef = directory.appendingPathComponent("report.html").path
        let run = WorkbenchAeroRun(record: record, settings: settings, artifactDirectory: directory.path)
        // Durable history also survives switching to another blueprint during a calculation.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(to: directory.appendingPathComponent("aero-run.json"), options: .atomic)
        } catch { progress("Не удалось сохранить локальную историю: \(error.localizedDescription)") }
        return run
    }

    private final class ProcessState: @unchecked Sendable {
        let lock = NSLock()
        let process = Process()
        var cancelled = false
        var buffer = Data()
        func cancel() {
            lock.lock(); cancelled = true; let running = process.isRunning; lock.unlock()
            if running { process.terminate() }
        }
    }
    private static func execute(tool: URL, directory: URL, progress: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let state = ProcessState(), output = Pipe()
        let process = state.process
        process.executableURL = tool; process.arguments = [directory.appendingPathComponent("job.json").path]
        process.currentDirectoryURL = directory; process.standardOutput = output
        let log = directory.appendingPathComponent("adapter.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: log); process.standardError = errorHandle
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.lock.lock(); state.buffer.append(data)
            var lines: [String] = []
            while let end = state.buffer.firstIndex(of: 10) {
                lines.append(String(decoding: state.buffer.prefix(upTo: end), as: UTF8.self)); state.buffer.removeSubrange(...end)
            }
            // Native meshers also write stdout. Avoid keeping an unbounded line in memory.
            if state.buffer.count > 65536 { state.buffer.removeAll() }
            state.lock.unlock()
            for line in lines where line.hasPrefix("progress ") { progress(line) }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil; try? errorHandle.close() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.lock.lock()
                if state.cancelled { state.lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
                do { try process.run(); state.lock.unlock() }
                catch { process.terminationHandler = nil; state.lock.unlock(); continuation.resume(throwing: error) }
            }
        } onCancel: {
            state.cancel()
        }
    }
}
