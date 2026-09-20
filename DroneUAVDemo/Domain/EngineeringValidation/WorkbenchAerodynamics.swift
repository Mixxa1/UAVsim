import Foundation

/// Near-wall sizing, the same formulas the solver side states in CADNext/cfd/.../WallResolution.hpp:
/// a turbulent flat-plate friction correlation used to place the first prism layer inside the regime
/// the turbulence model needs. It is an estimate; the run measures the y+ it actually got and the
/// result says whether the coefficients may be used.
enum WorkbenchWallLayers {
    /// Threads worth giving SU2 on this machine: the performance cores. On a hybrid CPU the efficiency
    /// cores are several times slower, and every OpenMP barrier waits for the slowest thread.
    static var solverThreads: Int {
        var cores = 0
        var size = MemoryLayout<Int32>.size
        var value: Int32 = 0
        if sysctlbyname("hw.perflevel0.logicalcpu", &value, &size, nil, 0) == 0, value > 0 { cores = Int(value) }
        return max(1, cores > 0 ? cores : ProcessInfo.processInfo.activeProcessorCount)
    }

    static func reynolds(speedMps: Double, lengthM: Double, densityKgM3: Double, viscosityPaS: Double) -> Double {
        viscosityPaS > 0 ? densityKgM3 * speedMps * lengthM / viscosityPaS : 0
    }
    static func skinFriction(reynolds: Double) -> Double { reynolds > 0 ? 0.026 * pow(reynolds, -1.0 / 7.0) : 0 }
    static func boundaryLayerM(reynolds: Double, lengthM: Double) -> Double {
        reynolds > 0 && lengthM > 0 ? 0.37 * lengthM * pow(reynolds, -0.2) : 0
    }
    static func heightForYPlus(_ yPlus: Double, speedMps: Double, lengthM: Double, densityKgM3: Double, viscosityPaS: Double) -> Double {
        let re = reynolds(speedMps: speedMps, lengthM: lengthM, densityKgM3: densityKgM3, viscosityPaS: viscosityPaS)
        let friction = skinFriction(reynolds: re)
        guard friction > 0, densityKgM3 > 0 else { return 0 }
        let frictionVelocity = speedMps * (friction / 2).squareRoot()
        guard frictionVelocity > 0 else { return 0 }
        return yPlus * viscosityPaS / (densityKgM3 * frictionVelocity)
    }
    /// Layer heights for the wall treatment: first layer at y+ 1 (resolved) or 50 (wall functions),
    /// geometric growth, enough layers to reach the boundary layer (at most 60).
    static func plan(wallTreatment: String, speedMps: Double, lengthM: Double, densityKgM3: Double, viscosityPaS: Double) -> [Double] {
        let resolved = wallTreatment != "functions"
        let re = reynolds(speedMps: speedMps, lengthM: lengthM, densityKgM3: densityKgM3, viscosityPaS: viscosityPaS)
        let thickness = boundaryLayerM(reynolds: re, lengthM: lengthM)
        var height = heightForYPlus(resolved ? 1 : 50, speedMps: speedMps, lengthM: lengthM, densityKgM3: densityKgM3, viscosityPaS: viscosityPaS)
        guard height > 0, thickness > 0 else { return [] }
        let growth = resolved ? 1.2 : 1.3
        var heights: [Double] = []
        var total = 0.0
        while total < thickness, heights.count < 60 {
            heights.append(height); total += height; height *= growth
        }
        return heights
    }
}

struct WorkbenchAeroSettings: Codable, Hashable {
    var model = "sst"
    /// "resolved" (y+ ≈ 1) or "functions" (y+ 30…300, SU2 standard wall function).
    var wallTreatment = "resolved"
    /// "none" (SST alone, turbulent from the leading edge) or "lm" (Langtry–Menter γ-Reθ transition).
    var transition = "none"
    /// Free-stream turbulence intensity, a fraction; with transition it decides where the layer turns turbulent.
    var turbulenceIntensity = 0.01
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

    init() {}

    // Settings saved inside a .uavbuild before a field existed must still open: every key is
    // optional on the way in and falls back to the default above.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        wallTreatment = try c.decodeIfPresent(String.self, forKey: .wallTreatment) ?? d.wallTreatment
        transition = try c.decodeIfPresent(String.self, forKey: .transition) ?? d.transition
        turbulenceIntensity = try c.decodeIfPresent(Double.self, forKey: .turbulenceIntensity) ?? d.turbulenceIntensity
        alphaDeg = try c.decodeIfPresent([Double].self, forKey: .alphaDeg) ?? d.alphaDeg
        betaDeg = try c.decodeIfPresent([Double].self, forKey: .betaDeg) ?? d.betaDeg
        speedMps = try c.decodeIfPresent(Double.self, forKey: .speedMps) ?? d.speedMps
        densityKgM3 = try c.decodeIfPresent(Double.self, forKey: .densityKgM3) ?? d.densityKgM3
        viscosityPaS = try c.decodeIfPresent(Double.self, forKey: .viscosityPaS) ?? d.viscosityPaS
        reference = try c.decodeIfPresent(EngineeringAeroTable.Reference.self, forKey: .reference) ?? d.reference
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? d.iterations
        convergenceWindow = try c.decodeIfPresent(Int.self, forKey: .convergenceWindow) ?? d.convergenceWindow
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        residualTarget = try c.decodeIfPresent(Double.self, forKey: .residualTarget) ?? d.residualTarget
        coefficientAbsoluteTolerance = try c.decodeIfPresent(Double.self, forKey: .coefficientAbsoluteTolerance) ?? d.coefficientAbsoluteTolerance
        coefficientRelativeTolerance = try c.decodeIfPresent(Double.self, forKey: .coefficientRelativeTolerance) ?? d.coefficientRelativeTolerance
        timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        farfieldLengths = try c.decodeIfPresent(Double.self, forKey: .farfieldLengths) ?? d.farfieldLengths
        wallSizeM = try c.decodeIfPresent(Double.self, forKey: .wallSizeM) ?? d.wallSizeM
        farfieldSizeM = try c.decodeIfPresent(Double.self, forKey: .farfieldSizeM) ?? d.farfieldSizeM
        grading = try c.decodeIfPresent(Double.self, forKey: .grading) ?? d.grading
        layerHeightsM = try c.decodeIfPresent([Double].self, forKey: .layerHeightsM) ?? d.layerHeightsM
    }

    static func initial(for build: WorkbenchBuild) -> Self {
        var s = Self()
        let frame = build.resolvedFrame
        s.reference.areaM2 = frame.wingAreaM2
        s.reference.spanM = Double(frame.sizeMeters.x)
        s.reference.chordM = s.reference.areaM2 / max(s.reference.spanM, 1e-6)
        let length = max(Double(frame.sizeMeters.x), Double(frame.sizeMeters.z))
        // About sixty cells along the chord across the surface, and a prism stack that reaches the
        // boundary layer this speed actually has. These are editable starting values: the result
        // remains WARNING until grid and domain sensitivity have been established by the analyst.
        s.wallSizeM = max(s.reference.chordM / 60, 1e-4)
        s.farfieldSizeM = length
        s.layerHeightsM = WorkbenchWallLayers.plan(wallTreatment: s.wallTreatment, speedMps: s.speedMps,
                                                   lengthM: s.reference.chordM, densityKgM3: s.densityKgM3, viscosityPaS: s.viscosityPaS)
        s.threads = WorkbenchWallLayers.solverThreads
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
        guard ["euler", "laminar", "sst", "urans_sst"].contains(model) else { return "Выберите Euler, laminar, SST или URANS SST." }
        guard ["resolved", "functions"].contains(wallTreatment) else { return "Стенка: разрешённый слой или пристеночные функции." }
        guard wallTreatment == "resolved" || model.hasSuffix("sst") else { return "Пристеночные функции существуют только для турбулентных моделей." }
        guard ["none", "lm"].contains(transition) else { return "Переход: нет или γ-Reθ." }
        guard transition == "none" || model.hasSuffix("sst") else { return "Модель перехода γ-Reθ работает поверх SST: выберите SST или URANS SST." }
        guard transition == "none" || wallTreatment == "resolved" else { return "Модели перехода нужен разрешённый пограничный слой (y+ ≈ 1)." }
        guard turbulenceIntensity.isFinite, turbulenceIntensity > 0, turbulenceIntensity <= 0.2 else { return "Интенсивность турбулентности — доля от 0 до 0.2." }
        // Mirrors the solver's refusal: above Re ≈ 5·10^5 a laminar solution is a different flow,
        // not a coarse one. Caught here so the run is never launched.
        let reynolds = WorkbenchWallLayers.reynolds(speedMps: speedMps, lengthM: reference.chordM,
                                                    densityKgM3: densityKgM3, viscosityPaS: viscosityPaS)
        guard model != "laminar" || reynolds <= 5e5 else { return "Ламинарная модель при Re = \(Int(reynolds)) неприменима: возьмите SST или URANS." }
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
                // A completed run whose points failed convergence or near-wall resolution carries no
                // table on purpose: its fields and reasons are kept, its numbers are not flown with.
                // Everything else about the result is still checked, so the record can be trusted.
                if let table = result.aeroTable {
                    guard table.reference == settings.reference,
                          table.model == settings.model, table.alphaDeg == settings.alphaDeg, table.betaDeg == settings.betaDeg,
                          table.speedMps == settings.speedMps, table.densityKgM3 == settings.densityKgM3,
                          table.viscosityPaS == settings.viscosityPaS else { throw WorkbenchAeroError.message("Аэротаблица не соответствует настройкам результата.") }
                }
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
        record.reportRef = directory.appendingPathComponent("result.json").path
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
