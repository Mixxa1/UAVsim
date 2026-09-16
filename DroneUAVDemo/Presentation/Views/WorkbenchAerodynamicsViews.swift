import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkbenchAerodynamicsPanel: View {
    @ObservedObject var viewModel: WorkbenchViewModel
    @State private var expanded = false
    @State private var inputProblems: [String: String] = [:]
    private var inputProblem: String? { inputProblems.sorted { $0.key < $1.key }.first?.value }
    @State private var selectedRunID: UUID?

    private var settings: WorkbenchAeroSettings { viewModel.aerodynamicSettings }
    private var selectedRun: WorkbenchAeroRun? {
        viewModel.build.aerodynamicRuns.first { $0.id == selectedRunID } ?? viewModel.build.aerodynamicRuns.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Аэродинамика / CFD").font(.system(size: 17, weight: .semibold))
            Text("Точная геометрия рамы → SU2 → аэротаблица → физика полёта")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker("Течение", selection: Binding(get: { settings.model }, set: { model in
                viewModel.updateAerodynamicSettings {
                    $0.model = model
                    if model == "euler" { $0.layerHeightsM = [] }
                    else if $0.layerHeightsM.isEmpty { $0.layerHeightsM = WorkbenchAeroSettings.initial(for: viewModel.build).layerHeightsM }
                }
            })) {
                Text("RANS SST").tag("sst")
                Text("Ламинарное").tag("laminar")
                Text("Euler · диагностика").tag("euler")
            }
            angleEditor("α, °", key: \.alphaDeg)
            angleEditor("β, °", key: \.betaDeg)
            Text("Один угол — точка; несколько — серия. При нескольких α и β рассчитываются все сочетания.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            number("Скорость, м/с", key: \.speedMps)
            reference("Площадь S, м²", key: \.areaM2)
            reference("Размах b, м", key: \.spanM)
            reference("Хорда c, м", key: \.chordM)
            DisclosureGroup("Сетка, среда и точность", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    number("Плотность, кг/м³", key: \.densityKgM3)
                    number("Вязкость, Па·с", key: \.viscosityPaS)
                    number("Элемент у стенки, м", key: \.wallSizeM)
                    number("Элемент в дальнем поле, м", key: \.farfieldSizeM)
                    number("Удаление границы, габаритов", key: \.farfieldLengths)
                    number("Grading", key: \.grading)
                    arrayEditor("Высоты слоёв, м", key: \.layerHeightsM)
                    integer("Итерации", key: \.iterations)
                    integer("Окно сходимости", key: \.convergenceWindow)
                    integer("Потоки", key: \.threads)
                    number("log₁₀ RMS ≤", key: \.residualTarget)
                    number("Допуск коэффициентов, abs", key: \.coefficientAbsoluteTolerance)
                    number("Допуск коэффициентов, rel", key: \.coefficientRelativeTolerance)
                    number("Лимит на точку, с", key: \.timeoutSeconds)
                    ForEach(0..<3) { i in
                        HStack {
                            Text("Точка момента \(["X влево", "Y вверх", "Z вперёд"][i]), м")
                            Spacer()
                            TextField("м", value: Binding(get: { settings.reference.momentCenterModelM[safeAero: i] ?? 0 }, set: { value in
                                viewModel.updateAerodynamicSettings {
                                    if $0.reference.momentCenterModelM.count != 3 { $0.reference.momentCenterModelM = [0, 0, 0] }
                                    $0.reference.momentCenterModelM[i] = value
                                }
                            }), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                    }
                    Text("Заданные размеры сетки — начальные. Для оценки погрешности повторите расчёт с более мелкой сеткой и более удалённой границей. Внешнее оборудование моделируется габаритными телами.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            if let problem = inputProblem ?? settings.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(GroundControlPalette.warning)
            }
            if let progress = viewModel.aerodynamicProgress {
                HStack { ProgressView().controlSize(.small); Text(progress).font(.system(size: 11)) }
                Button("Отменить расчёт") { viewModel.cancelAerodynamics() }
            } else {
                HStack {
                    Button("Рассчитать CFD") { viewModel.runAerodynamics() }
                        .disabled(settings.problem != nil || inputProblem != nil || viewModel.exactBodies.isEmpty || viewModel.aerodynamicTool == nil || viewModel.aerodynamicSolver == nil)
                    Button("Импорт таблицы…") { importTable() }
                }
            }
            if viewModel.exactBodies.isEmpty {
                Text("Для расчёта импортируйте .uavframe v2 с точными телами. Готовую таблицу можно привязать к любой сборке.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button(viewModel.aerodynamicTool == nil ? "Указать cadnext_cfd…" : "cadnext_cfd ✓") { chooseTool("CADNEXT_CFD_TOOL") }
                Button(viewModel.aerodynamicSolver == nil ? "Указать SU2_CFD…" : "SU2_CFD ✓") { chooseTool("CADNEXT_SU2_CFD") }
            }.font(.system(size: 10))
            if !viewModel.build.aerodynamicRuns.isEmpty { history }
        }
        .font(.system(size: 12))
        .padding(14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text("История CFD").font(.system(size: 13, weight: .semibold))
            Picker("Запуск", selection: Binding(get: { selectedRun?.id }, set: { selectedRunID = $0 })) {
                ForEach(viewModel.build.aerodynamicRuns.reversed()) { run in
                    Text(run.record.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + run.record.outcome.rawValue.uppercased()).tag(Optional(run.id))
                }
            }
            if let run = selectedRun {
                let snapshot = WorkbenchEngineeringSnapshot.make(from: viewModel.build)
                let evaluation = EngineeringValidationEngine.evaluate(snapshot: snapshot, records: [run.record]).evaluation(.aerodynamics)
                Text((evaluation.map { WorkbenchValidationText.status($0.status) } ?? "ERROR") + " · " + run.record.solverVersion)
                    .foregroundStyle(evaluation.map { WorkbenchValidationText.color($0.status) } ?? .secondary)
                ForEach(evaluation?.reasons.map(\.displayText) ?? [], id: \.self) { Text($0).foregroundStyle(GroundControlPalette.warning) }
                ForEach(run.record.failureReasons + run.record.warnings, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let table = run.record.aerodynamicTable {
                    Text("\(table.points.count) точек · \(table.usableForFlight ? "может использоваться в физике при актуальной конфигурации" : "только диагностика")")
                    if let bracket = table.possibleStallBracketDeg {
                        Text(String(format: "Возможная зона срыва при β = 0: %.1f…%.1f°. Требует проверки сетки и нестационарности.", bracket.lowerBound, bracket.upperBound))
                            .font(.system(size: 11)).foregroundStyle(GroundControlPalette.warning)
                    }
                    HStack {
                        Button("Экспорт таблицы…") { exportTable(table) }
                        if let setup = run.settings {
                            Button("Повторить настройки") { viewModel.updateAerodynamicSettings { $0 = setup } }
                        }
                    }
                    AeroRunComparison(current: run, runs: viewModel.build.aerodynamicRuns)
                }
                if let directory = run.artifactDirectory, FileManager.default.fileExists(atPath: directory) {
                    HStack {
                        Button("Графики и поля") { NSWorkspace.shared.open(URL(fileURLWithPath: directory).appendingPathComponent("report.html")) }
                            .disabled(!FileManager.default.fileExists(atPath: directory + "/report.html"))
                        Button("Файлы и журнал") { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) }
                    }
                }
            }
        }
    }

    private func number(_ title: String, key: WritableKeyPath<WorkbenchAeroSettings, Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: Binding(get: { settings[keyPath: key] }, set: { v in viewModel.updateAerodynamicSettings { $0[keyPath: key] = v } }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder) }
    }
    private func integer(_ title: String, key: WritableKeyPath<WorkbenchAeroSettings, Int>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: Binding(get: { settings[keyPath: key] }, set: { v in viewModel.updateAerodynamicSettings { $0[keyPath: key] = v } }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder) }
    }
    private func reference(_ title: String, key: WritableKeyPath<EngineeringAeroTable.Reference, Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: Binding(get: { settings.reference[keyPath: key] }, set: { v in viewModel.updateAerodynamicSettings { $0.reference[keyPath: key] = v } }), format: .number).frame(width: 100).textFieldStyle(.roundedBorder) }
    }
    private func angleEditor(_ title: String, key: WritableKeyPath<WorkbenchAeroSettings, [Double]>) -> some View { arrayEditor(title, key: key) }
    private func arrayEditor(_ title: String, key: WritableKeyPath<WorkbenchAeroSettings, [Double]>) -> some View {
        AeroNumberListField(title: title, values: Binding(get: { settings[keyPath: key] }, set: { values in
            viewModel.updateAerodynamicSettings { $0[keyPath: key] = values }
        }), problem: { inputProblems[title] = $0 })
    }
    private func chooseTool(_ key: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите исполняемый файл \(key == "CADNEXT_CFD_TOOL" ? "cadnext_cfd" : "SU2_CFD")"
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: key)
            viewModel.objectWillChange.send()
        }
    }
    private func importTable() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Выбранная аэротаблица будет привязана к текущей конфигурации аппарата. Проверьте её геометрию, оси и опорные размеры."
        if panel.runModal() == .OK, let url = panel.url { viewModel.importAerodynamicTable(from: url) }
    }
    private func exportTable(_ table: EngineeringAeroTable) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "aerodynamics.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(table).write(to: url, options: .atomic) }
            catch { viewModel.statusMessage = "Не удалось экспортировать аэротаблицу: \(error.localizedDescription)" }
        }
    }
}

private struct AeroRunComparison: View {
    let current: WorkbenchAeroRun
    let runs: [WorkbenchAeroRun]
    @State private var baselineID: UUID?
    private var candidates: [WorkbenchAeroRun] { runs.filter { $0.id != current.id && $0.record.aerodynamicTable != nil }.reversed() }
    private var baseline: WorkbenchAeroRun? { candidates.first { $0.id == baselineID } ?? candidates.first }
    private let keys: [KeyPath<EngineeringAeroTable.Point, Double>] = [\.cl, \.cd, \.cm, \.cy, \.cRoll, \.cYaw]
    private let labels = ["CL", "CD", "Cm", "CY", "Croll", "Cyaw"]
    var body: some View {
        if !candidates.isEmpty {
            DisclosureGroup("Сравнить с другим запуском") {
                Picker("Базовый запуск", selection: Binding(get: { baseline?.id }, set: { baselineID = $0 })) {
                    ForEach(candidates) { run in
                        Text(run.record.createdAt.formatted(date: .abbreviated, time: .shortened)).tag(Optional(run.id))
                    }
                }
                if let table = current.record.aerodynamicTable, let other = baseline?.record.aerodynamicTable {
                    if table.reference != other.reference || table.frame != other.frame {
                        Text("Для сравнения коэффициентов нужны одинаковые S, b, c, оси и точка момента.").foregroundStyle(.secondary)
                    } else {
                        let pairs = table.points.compactMap { p in other.points.first { $0.alphaDeg == p.alphaDeg && $0.betaDeg == p.betaDeg }.map { (p, $0) } }
                        Text("Общих точек α/β: \(pairs.count). Максимальная |Δ|; условия расчётов сравните в отчётах.").font(.system(size: 11))
                        if !pairs.isEmpty {
                            ForEach(0..<keys.count, id: \.self) { i in
                                HStack {
                                    Text(labels[i]); Spacer()
                                    Text(String(format: "%.5f", pairs.map { abs($0.0[keyPath: keys[i]] - $0.1[keyPath: keys[i]]) }.max() ?? 0))
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
private extension Array {
    subscript(safeAero index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Keep partially typed numbers ("-", "1e-") in the editor until Enter or focus loss. A pending
/// edit disables Run, so the job can never silently use the previous value still in the model.
private struct AeroNumberListField: View {
    let title: String
    @Binding var values: [Double]
    let problem: (String?) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var encoded: String { values.map { String($0) }.joined(separator: ", ") }
    var body: some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            TextField("0, 5, 10", text: $draft).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(commit)
                .onAppear { draft = encoded }
                .onChange(of: values) { _, _ in if !focused { draft = encoded } }
                .onChange(of: focused) { _, active in if !active { commit() } }
                .onChange(of: draft) { _, text in
                    if focused && text != encoded { problem("\(title): нажмите Enter, чтобы применить список.") }
                }
        }
    }
    private func commit() {
        let tokens = draft.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        let numbers = tokens.compactMap { Double($0) }
        guard numbers.count == tokens.count, numbers.allSatisfy(\.isFinite) else {
            problem("\(title): введите числа через запятую; десятичный разделитель — точка."); return
        }
        values = numbers
        draft = encoded
        problem(nil)
    }
}
