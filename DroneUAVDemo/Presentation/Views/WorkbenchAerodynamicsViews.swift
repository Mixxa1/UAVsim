import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WorkbenchAerodynamicsPanel: View {
    @ObservedObject var viewModel: WorkbenchViewModel
    @State private var expanded = false
    @State private var toolsExpanded = false
    @State private var historyExpanded = false
    @State private var inputProblems: [String: String] = [:]
    private var inputProblem: String? { inputProblems.sorted { $0.key < $1.key }.first?.value }
    @State private var selectedRunID: UUID?

    private var settings: WorkbenchAeroSettings { viewModel.aerodynamicSettings }
    private var selectedRun: WorkbenchAeroRun? {
        viewModel.build.aerodynamicRuns.first { $0.id == selectedRunID } ?? viewModel.build.aerodynamicRuns.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.s("cfd.title")).font(.system(size: 17, weight: .semibold))
            Text(L10n.s("cfd.pipeline"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Picker(L10n.s("cfd.flow"), selection: Binding(get: { settings.model }, set: { model in
                viewModel.updateAerodynamicSettings {
                    $0.selectModel(model)
                    if !model.hasSuffix("sst") { $0.transition = "none" }
                    if model == "euler" { $0.layerHeightsM = [] }
                    else if $0.layerHeightsM.isEmpty { $0.layerHeightsM = WorkbenchAeroSettings.initial(for: viewModel.build).layerHeightsM }
                }
            })) {
                Text("RANS SST").tag("sst")
                Text(L10n.s("cfd.urans")).tag("urans_sst")
                Text(L10n.s("cfd.laminar")).tag("laminar")
                Text(L10n.s("cfd.euler")).tag("euler")
            }
            if settings.model.hasSuffix("sst") {
                Picker(L10n.s("cfd.wall_mode"), selection: Binding(get: { settings.wallTreatment }, set: { treatment in
                    viewModel.updateAerodynamicSettings {
                        $0.wallTreatment = treatment
                        // γ-Reθ needs the laminar sublayer meshed; wall functions have none.
                        if treatment != "resolved" { $0.transition = "none" }
                    }
                })) {
                    Text(L10n.s("cfd.wall_resolved")).tag("resolved")
                    Text(L10n.s("cfd.wall_functions")).tag("functions")
                }
                if settings.wallTreatment == "resolved" {
                    Picker(L10n.s("cfd.transition"), selection: Binding(get: { settings.transition }, set: { value in
                        viewModel.updateAerodynamicSettings { $0.transition = value }
                    })) {
                        Text(L10n.s("cfd.transition_none")).tag("none")
                        Text(L10n.s("cfd.transition_lm")).tag("lm")
                    }
                }
                HStack {
                    Text(L10n.s("cfd.turbulence"))
                    Spacer()
                    TextField("%", value: Binding(get: { settings.turbulenceIntensity * 100 }, set: { value in
                        viewModel.updateAerodynamicSettings { $0.turbulenceIntensity = value / 100 }
                    }), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                }
                Text(L10n.s("cfd.transition_hint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if settings.model == "urans_sst" { timePlan }
            if settings.model != "euler" { wallPlan }
            angleEditor("α, °", key: \.alphaDeg)
            angleEditor("β, °", key: \.betaDeg)
            Text(L10n.s("cfd.angles_hint"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            number(L10n.s("cfd.speed"), key: \.speedMps)
            reference(L10n.s("cfd.area"), key: \.areaM2)
            reference(L10n.s("cfd.span"), key: \.spanM)
            reference(L10n.s("cfd.chord"), key: \.chordM)
            DisclosureGroup(L10n.s("cfd.advanced"), isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 9) {
                    number(L10n.s("cfd.density"), key: \.densityKgM3)
                    number(L10n.s("cfd.viscosity"), key: \.viscosityPaS)
                    number(L10n.s("cfd.wall"), key: \.wallSizeM)
                    number(L10n.s("cfd.far"), key: \.farfieldSizeM)
                    number(L10n.s("cfd.boundary"), key: \.farfieldLengths)
                    number(L10n.s("cfd.grading"), key: \.grading)
                    arrayEditor(L10n.s("cfd.layers"), key: \.layerHeightsM)
                    integer(L10n.s("cfd.iterations"), key: \.iterations)
                    integer(L10n.s("cfd.window"), key: \.convergenceWindow)
                    integer(L10n.s("cfd.threads"), key: \.threads)
                    number(L10n.s("cfd.residual"), key: \.residualTarget)
                    number(L10n.s("cfd.abs"), key: \.coefficientAbsoluteTolerance)
                    number(L10n.s("cfd.rel"), key: \.coefficientRelativeTolerance)
                    number(L10n.s("cfd.timeout"), key: \.timeoutSeconds)
                    ForEach(0..<3) { i in
                        HStack {
                            Text(L10n.f("cfd.moment", L10n.s(["cfd.axis_x", "cfd.axis_y", "cfd.axis_z"][i])))
                            Spacer()
                            TextField(L10n.s("cfd.metres"), value: Binding(get: { settings.reference.momentCenterModelM[safeAero: i] ?? 0 }, set: { value in
                                viewModel.updateAerodynamicSettings {
                                    if $0.reference.momentCenterModelM.count != 3 { $0.reference.momentCenterModelM = [0, 0, 0] }
                                    $0.reference.momentCenterModelM[i] = value
                                }
                            }), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                    }
                    Text(L10n.s("cfd.mesh_hint"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }
            if let problem = inputProblem ?? settings.problem {
                Text(problem).font(.system(size: 11)).foregroundStyle(GroundControlPalette.warning)
            }
            if let progress = viewModel.aerodynamicProgress {
                HStack { ProgressView().controlSize(.small); Text(progress).font(.system(size: 11)) }
                Button(L10n.s("cfd.cancel")) { viewModel.cancelAerodynamics() }
            } else {
                HStack {
                    Button(L10n.s("cfd.run")) { viewModel.runAerodynamics() }
                        .disabled(settings.problem != nil || inputProblem != nil || viewModel.exactBodies.isEmpty || viewModel.aerodynamicTool == nil || viewModel.aerodynamicSolver == nil)
                }
            }
            if viewModel.exactBodies.isEmpty {
                Text(L10n.s("cfd.geometry_hint"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.s("cfd.tools"), isExpanded: $toolsExpanded) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Button(viewModel.aerodynamicTool == nil ? L10n.s("cfd.choose_adapter") : L10n.s("cfd.adapter_ready")) { chooseTool("CADNEXT_CFD_TOOL") }
                        Button(viewModel.aerodynamicSolver == nil ? L10n.s("cfd.choose_solver") : L10n.s("cfd.solver_ready")) { chooseTool("CADNEXT_SU2_CFD") }
                    }
                    Button(L10n.s("cfd.import")) { importTable() }
                }
                .font(.system(size: 10))
                .padding(.top, 6)
            }
            if !viewModel.build.aerodynamicRuns.isEmpty {
                DisclosureGroup(isExpanded: $historyExpanded) {
                    history
                } label: {
                    HStack {
                        Label(L10n.s("cfd.history"), systemImage: "clock.arrow.circlepath")
                        Spacer(minLength: 4)
                        Text("\(viewModel.build.aerodynamicRuns.count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker(L10n.s("cfd.run_label"), selection: Binding(get: { selectedRun?.id }, set: { selectedRunID = $0 })) {
                ForEach(viewModel.build.aerodynamicRuns.reversed()) { run in
                    Text(run.record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.currentLanguage().locale)) + " · " + run.record.outcome.rawValue.uppercased()).tag(Optional(run.id))
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
                    Text(L10n.f("cfd.point_count", table.points.count, table.usableForFlight ? L10n.s("cfd.flight_usable") : L10n.s("cfd.diagnostics")))
                    if let bracket = table.possibleStallBracketDeg {
                        Text(String(format: L10n.s("cfd.stall"), bracket.lowerBound, bracket.upperBound))
                            .font(.system(size: 11)).foregroundStyle(GroundControlPalette.warning)
                    }
                    HStack {
                        Button(L10n.s("cfd.export")) { exportTable(table) }
                        if let setup = run.settings {
                            Button(L10n.s("cfd.repeat")) { viewModel.updateAerodynamicSettings { $0 = setup } }
                        }
                        Button(L10n.s("cfd.report")) {
                            WorkbenchAerodynamicsReportWindowHost.open(run: run)
                        }
                    }
                    AeroRunComparison(current: run, runs: viewModel.build.aerodynamicRuns)
                }
                if let directory = run.artifactDirectory, FileManager.default.fileExists(atPath: directory) {
                    HStack {
                        Button(L10n.s("cfd.files")) { NSWorkspace.shared.open(URL(fileURLWithPath: directory)) }
                    }
                }
            }
        }
    }

    private func millimetres(_ value: Double) -> String { String(format: value * 1000 >= 1 ? "%.2f" : "%.4f", value * 1000) }

    /// What the flow at this speed needs at the wall, next to what is currently set. The estimate is
    /// a flat-plate correlation; the run measures the y+ it actually got.
    @ViewBuilder private var wallPlan: some View {
        let planned = WorkbenchWallLayers.plan(wallTreatment: settings.wallTreatment, speedMps: settings.speedMps,
                                               lengthM: settings.reference.chordM, densityKgM3: settings.densityKgM3,
                                               viscosityPaS: settings.viscosityPaS)
        let reynolds = WorkbenchWallLayers.reynolds(speedMps: settings.speedMps, lengthM: settings.reference.chordM,
                                                    densityKgM3: settings.densityKgM3, viscosityPaS: settings.viscosityPaS)
        let thickness = WorkbenchWallLayers.boundaryLayerM(reynolds: reynolds, lengthM: settings.reference.chordM)
        let unit = WorkbenchWallLayers.heightForYPlus(1, speedMps: settings.speedMps, lengthM: settings.reference.chordM,
                                                      densityKgM3: settings.densityKgM3, viscosityPaS: settings.viscosityPaS)
        let current = settings.layerHeightsM.first ?? 0
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.f("cfd.wall_plan", String(format: "%.3g", reynolds), millimetres(planned.first ?? 0), String(planned.count),
                        millimetres(thickness), millimetres(current), String(format: "%.2g", unit > 0 ? current / unit : 0)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Button(L10n.s("cfd.wall_apply")) {
                viewModel.updateAerodynamicSettings {
                    $0.layerHeightsM = planned
                    $0.wallSizeM = max($0.reference.chordM / 60, 1e-4)
                }
            }.disabled(planned.isEmpty)
        }
    }

    /// The time-accurate part of a URANS run, with what the entered numbers amount to in the units
    /// that decide whether it means anything: chord passages covered and steps per passage.
    @ViewBuilder private var timePlan: some View {
        let duration = settings.timeStepSeconds * Double(settings.timeSteps)
        let passage = settings.speedMps > 0 ? settings.reference.chordM / settings.speedMps : 0
        let innerIterations = Double(settings.timeSteps) * Double(settings.innerIterations)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(L10n.s("cfd.time_step"))
                Spacer()
                TextField(L10n.s("cfd.time_step"), value: Binding(get: { settings.timeStepSeconds * 1000 }, set: { value in
                    viewModel.updateAerodynamicSettings { $0.timeStepSeconds = value / 1000 }
                }), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            integer(L10n.s("cfd.time_steps"), key: \.timeSteps)
            integer(L10n.s("cfd.inner_iterations"), key: \.innerIterations)
            integer(L10n.s("cfd.averaging_steps"), key: \.averagingSteps)
            Text(L10n.f("cfd.time_plan", String(format: "%.3g", duration),
                        String(format: "%.3g", passage > 0 ? duration / passage : 0),
                        String(format: "%.3g", settings.timeStepSeconds > 0 ? passage / settings.timeStepSeconds : 0),
                        String(format: "%.0f", innerIterations),
                        String(format: "%.2g", innerIterations > 0 ? settings.timeoutSeconds / innerIterations : 0)))
                .font(.system(size: 11)).foregroundStyle(.secondary)
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
        panel.message = L10n.f("cfd.executable", key == "CADNEXT_CFD_TOOL" ? "cadnext_cfd" : "SU2_CFD")
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: key)
            viewModel.objectWillChange.send()
        }
    }
    private func importTable() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = L10n.s("cfd.import_hint")
        if panel.runModal() == .OK, let url = panel.url { viewModel.importAerodynamicTable(from: url) }
    }
    private func exportTable(_ table: EngineeringAeroTable) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "aerodynamics.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(table).write(to: url, options: .atomic) }
            catch { viewModel.statusMessage = L10n.f("cfd.export_error", error.localizedDescription) }
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
            DisclosureGroup(L10n.s("cfd.compare")) {
                Picker(L10n.s("cfd.baseline"), selection: Binding(get: { baseline?.id }, set: { baselineID = $0 })) {
                    ForEach(candidates) { run in
                        Text(run.record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.currentLanguage().locale))).tag(Optional(run.id))
                    }
                }
                if let table = current.record.aerodynamicTable, let other = baseline?.record.aerodynamicTable {
                    if table.reference != other.reference || table.frame != other.frame {
                        Text(L10n.s("cfd.compare_hint")).foregroundStyle(.secondary)
                    } else {
                        let pairs = table.points.compactMap { p in other.points.first { $0.alphaDeg == p.alphaDeg && $0.betaDeg == p.betaDeg }.map { (p, $0) } }
                        Text(L10n.f("cfd.shared_points", pairs.count)).font(.system(size: 11))
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
                    if focused && text != encoded { problem(L10n.f("cfd.apply_list", title)) }
                }
        }
    }
    private func commit() {
        let tokens = draft.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        let numbers = tokens.compactMap { Double($0) }
        guard numbers.count == tokens.count, numbers.allSatisfy(\.isFinite) else {
            problem(L10n.f("cfd.number_list", title)); return
        }
        values = numbers
        draft = encoded
        problem(nil)
    }
}

// MARK: - Native CFD report

/// A full native report window backed by the solver's structured JSON and field artifacts.
final class WorkbenchAerodynamicsReportWindowHost: NSObject, NSWindowDelegate {
    private static var current: WorkbenchAerodynamicsReportWindowHost?
    private var window: NSWindow?

    static func open(run: WorkbenchAeroRun) {
        current?.closeWindow()
        let host = WorkbenchAerodynamicsReportWindowHost()
        current = host
        host.openWindow(run: run)
    }

    private func openWindow(run: WorkbenchAeroRun) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(max(980, visible.width - 80), 1480)
        let height = min(max(720, visible.height - 80), 980)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = L10n.s("cfd.report.title")
        win.minSize = NSSize(width: 900, height: 640)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: WorkbenchAerodynamicsReportView(run: run, onDismiss: { [weak self] in self?.closeWindow() }))
        self.window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        Self.current = nil
    }
}

private enum AeroReportMetric: String, CaseIterable, Identifiable {
    case cl, cd, cm, cy, cRoll, cYaw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cl: return "CL"
        case .cd: return "CD"
        case .cm: return "Cm"
        case .cy: return "CY"
        case .cRoll: return "Croll"
        case .cYaw: return "Cyaw"
        }
    }

    func value(_ point: EngineeringAeroTable.Point) -> Double {
        switch self {
        case .cl: return point.cl
        case .cd: return point.cd
        case .cm: return point.cm
        case .cy: return point.cy
        case .cRoll: return point.cRoll
        case .cYaw: return point.cYaw
        }
    }
}

private struct AeroReportChart: View {
    let table: EngineeringAeroTable
    let metric: AeroReportMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                Canvas { context, size in
                    let left: CGFloat = 46
                    let right: CGFloat = 14
                    let top: CGFloat = 12
                    let bottom: CGFloat = 28
                    let plot = CGRect(x: left, y: top,
                                      width: max(1, size.width - left - right),
                                      height: max(1, size.height - top - bottom))
                    let points = table.points
                    guard let minAlpha = table.alphaDeg.min(), let maxAlpha = table.alphaDeg.max(),
                          let minValue = points.map({ metric.value($0) }).min(),
                          let maxValue = points.map({ metric.value($0) }).max() else { return }
                    let xSpan = max(maxAlpha - minAlpha, 1e-9)
                    let valueSpan = max(maxValue - minValue, 1e-9)
                    func x(_ alpha: Double) -> CGFloat {
                        plot.minX + CGFloat((alpha - minAlpha) / xSpan) * plot.width
                    }
                    func y(_ value: Double) -> CGFloat {
                        plot.maxY - CGFloat((value - minValue) / valueSpan) * plot.height
                    }

                    context.stroke(Path(CGRect(origin: plot.origin, size: plot.size)),
                                   with: .color(GroundControlPalette.borderStrong), lineWidth: 1)
                    for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
                        let yy = plot.minY + CGFloat(fraction) * plot.height
                        var grid = Path(); grid.move(to: CGPoint(x: plot.minX, y: yy)); grid.addLine(to: CGPoint(x: plot.maxX, y: yy))
                        context.stroke(grid, with: .color(Color.white.opacity(0.08)), lineWidth: 1)
                    }

                    let groups = Dictionary(grouping: points, by: { $0.betaDeg })
                        .sorted { $0.key < $1.key }
                    let colors: [Color] = [.accentColor, .orange, .green, .pink, .purple, .cyan]
                    for (index, group) in groups.enumerated() {
                        let ordered = group.value.sorted { $0.alphaDeg < $1.alphaDeg }
                        guard !ordered.isEmpty else { continue }
                        var path = Path()
                        for (pointIndex, point) in ordered.enumerated() {
                            let position = CGPoint(x: x(point.alphaDeg), y: y(metric.value(point)))
                            if pointIndex == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        context.stroke(path, with: .color(colors[index % colors.count]), lineWidth: 2)
                    }
                }
            }
            .frame(height: 250)
            HStack {
                Text(table.alphaDeg.first.map { String(format: "α %.1f°", $0) } ?? "")
                Spacer()
                Text(metric.title).fontWeight(.semibold)
                Spacer()
                Text(table.alphaDeg.last.map { String(format: "α %.1f°", $0) } ?? "")
            }
            .font(.system(size: 9))
            .foregroundStyle(GroundControlPalette.textSecondary)
        }
    }
}

struct WorkbenchAerodynamicsReportView: View {
    let run: WorkbenchAeroRun
    let onDismiss: () -> Void
    @State private var metric: AeroReportMetric = .cl

    private var table: EngineeringAeroTable? { run.record.aerodynamicTable }
    private var outcomeColor: Color {
        switch run.record.outcome {
        case .pass: return GroundControlPalette.success
        case .warning: return GroundControlPalette.warning
        case .fail, .error: return GroundControlPalette.danger
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.s("cfd.report.title"))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(run.record.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.currentLanguage().locale)))
                        .font(.system(size: 11))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                Spacer()
                Text(run.record.outcome.rawValue.uppercased())
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(outcomeColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(outcomeColor.opacity(0.12), in: Capsule())
                Button(L10n.s("cfd.report.close"), action: onDismiss)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summary
                    if let table {
                        reportSection(L10n.s("cfd.report.coefficients"), icon: "chart.xyaxis.line") {
                            Picker(L10n.s("cfd.report.metric"), selection: $metric) {
                                ForEach(AeroReportMetric.allCases) { metric in
                                    Text(metric.title).tag(metric)
                                }
                            }
                            .pickerStyle(.segmented)
                            AeroReportChart(table: table, metric: metric)
                            coefficientTable(table)
                        }
                    } else {
                        reportSection(L10n.s("cfd.report.coefficients"), icon: "exclamationmark.triangle") {
                            Text(L10n.s("cfd.report.no_table"))
                                .foregroundStyle(GroundControlPalette.warning)
                        }
                    }
                    conditions
                    messages
                }
                .padding(20)
            }
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .background(GroundControlPalette.shell)
        .frame(minWidth: 900, minHeight: 640)
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
            reportValue(L10n.s("cfd.report.model"), run.settings?.model.uppercased() ?? table?.model.uppercased() ?? "—")
            reportValue(L10n.s("cfd.report.solver"), "\(run.record.solverID) · \(run.record.solverVersion)")
            reportValue(L10n.s("cfd.report.points"), table.map { "\($0.points.count)" } ?? "—")
            reportValue(L10n.s("cfd.report.source"), WorkbenchValidationText.source(run.record.source))
        }
    }

    private var conditions: some View {
        reportSection(L10n.s("cfd.report.conditions"), icon: "thermometer.medium") {
            let reference = table?.reference ?? run.settings?.reference
            let speed = table?.speedMps ?? run.settings?.speedMps
            let density = table?.densityKgM3 ?? run.settings?.densityKgM3
            let viscosity = table?.viscosityPaS ?? run.settings?.viscosityPaS
            HStack(spacing: 22) {
                reportLine(L10n.s("cfd.speed"), speed.map { String(format: "%.2f м/с", $0) } ?? "—")
                reportLine(L10n.s("cfd.density"), density.map { String(format: "%.4f кг/м³", $0) } ?? "—")
                reportLine(L10n.s("cfd.viscosity"), viscosity.map { String(format: "%.3e Па·с", $0) } ?? "—")
            }
            if let reference {
                HStack(spacing: 22) {
                    reportLine(L10n.s("cfd.area"), String(format: "%.4f м²", reference.areaM2))
                    reportLine(L10n.s("cfd.span"), String(format: "%.4f м", reference.spanM))
                    reportLine(L10n.s("cfd.chord"), String(format: "%.4f м", reference.chordM))
                }
            }
        }
    }

    private var messages: some View {
        reportSection(L10n.s("cfd.report.messages"), icon: "text.alignleft") {
            ForEach(run.record.failureReasons, id: \.self) { Text("• " + $0).foregroundStyle(GroundControlPalette.danger) }
            ForEach(run.record.warnings, id: \.self) { Text("• " + $0).foregroundStyle(GroundControlPalette.warning) }
            if run.record.failureReasons.isEmpty && run.record.warnings.isEmpty {
                Text(L10n.s("cfd.report.no_messages")).foregroundStyle(GroundControlPalette.textSecondary)
            }
            if let directory = run.artifactDirectory, FileManager.default.fileExists(atPath: directory) {
                HStack {
                    Text(L10n.s("cfd.report.artifacts"))
                        .font(.system(size: 10))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Spacer()
                    Button(L10n.s("cfd.report.open_files")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private func coefficientTable(_ table: EngineeringAeroTable) -> some View {
        let columns = ["α, °", "β, °", "CL", "CD", "Cm", "CY", "Croll", "Cyaw"].map {
            GridItem(.fixed($0.count > 4 ? 82 : 64), alignment: .trailing)
        }
        return ScrollView([.horizontal, .vertical]) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(["α, °", "β, °", "CL", "CD", "Cm", "CY", "Croll", "Cyaw"], id: \.self) { Text($0).fontWeight(.bold) }
                ForEach(Array(table.points.enumerated()), id: \.offset) { _, point in
                    Text(String(format: "%.2f", point.alphaDeg))
                    Text(String(format: "%.2f", point.betaDeg))
                    Text(String(format: "%.5f", point.cl))
                    Text(String(format: "%.5f", point.cd))
                    Text(String(format: "%.5f", point.cm))
                    Text(String(format: "%.5f", point.cy))
                    Text(String(format: "%.5f", point.cRoll))
                    Text(String(format: "%.5f", point.cYaw))
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .padding(10)
        }
        .frame(minHeight: 150, maxHeight: 310)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 8))
    }

    private func reportValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary)
            Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 11)
        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 9))
    }

    private func reportLine(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(GroundControlPalette.textSecondary)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }

    private func reportSection<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(GroundControlPalette.border))
    }
}
