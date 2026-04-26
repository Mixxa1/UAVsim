import SwiftUI
import AppKit

private enum ProjectSortOrder: String, CaseIterable, Identifiable {
    case newest
    case name
    case recentlyOpened

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .newest:
            return "project.sort.newest"
        case .name:
            return "project.sort.name"
        case .recentlyOpened:
            return "project.sort.recent"
        }
    }
}

private enum NameDialogMode: String, Identifiable {
    case create
    case saveAs
    case duplicate

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .create:
            return "project.create.title"
        case .saveAs:
            return "project.save_as.title"
        case .duplicate:
            return "project.duplicate.title"
        }
    }

    var actionKey: String {
        switch self {
        case .create:
            return "project.create.action"
        case .saveAs:
            return "project.save_as.action"
        case .duplicate:
            return "project.duplicate.action"
        }
    }
}

private enum PendingExitAction {
    case closeWindow
    case returnToMenu
}

@MainActor
private final class AppShellViewModel: NSObject, ObservableObject, NSWindowDelegate {
    @Published var activeSimulation: DroneSimulationViewModel?
    @Published var projects: [ProjectRecordSummary] = []
    @Published var searchQuery: String = ""
    @Published var sortOrder: ProjectSortOrder = .newest
    @Published var showUnsavedPrompt: Bool = false
    @Published var globalAlert: TelemetryExportAlert?

    private let projectStorage: ProjectStorageManaging
    private weak var window: NSWindow?
    private var pendingExitAction: PendingExitAction?
    private var allowWindowClose = false

    init(projectStorage: ProjectStorageManaging = ProjectStorageService()) {
        self.projectStorage = projectStorage
        super.init()
        refreshProjects()
    }

    var visibleProjects: [ProjectRecordSummary] {
        let filtered: [ProjectRecordSummary]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = projects
        } else {
            let query = searchQuery.lowercased()
            filtered = projects.filter { $0.name.lowercased().contains(query) }
        }

        switch sortOrder {
        case .newest:
            return filtered.sorted { $0.modifiedAt > $1.modifiedAt }
        case .name:
            return filtered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .recentlyOpened:
            return filtered.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
        }
    }

    func bind(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.delegate = self
    }

    func refreshProjects() {
        projects = projectStorage.listProjects()
    }

    func createProject(named name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let finalName = trimmed.isEmpty ? projectStorage.defaultProjectName() : trimmed
        let projectID = projectStorage.createProjectID()

        let vm = DroneSimulationViewModel(
            projectStorage: projectStorage,
            initialProjectID: projectID,
            initialProjectName: finalName
        )
        activeSimulation = vm

        switch vm.saveProject() {
        case .success:
            refreshProjects()
        case let .failure(error):
            globalAlert = TelemetryExportAlert(
                titleKey: "project.save.failure",
                message: error.localizedDescription
            )
        }
    }

    func openProject(_ summary: ProjectRecordSummary) {
        let vm = DroneSimulationViewModel(
            projectStorage: projectStorage,
            initialProjectID: summary.id,
            initialProjectName: summary.name
        )
        switch vm.loadProject(id: summary.id) {
        case .success:
            activeSimulation = vm
            refreshProjects()
        case let .failure(error):
            globalAlert = TelemetryExportAlert(
                titleKey: "project.open.failure",
                message: error.localizedDescription
            )
        }
    }

    func saveActiveProject() {
        guard let vm = activeSimulation else { return }
        switch vm.saveProject() {
        case .success:
            refreshProjects()
            globalAlert = TelemetryExportAlert(
                titleKey: "project.save.success",
                message: vm.currentProjectName
            )
        case let .failure(error):
            globalAlert = TelemetryExportAlert(
                titleKey: "project.save.failure",
                message: error.localizedDescription
            )
        }
    }

    func saveActiveProjectAs(name: String) {
        guard let vm = activeSimulation else { return }
        switch vm.saveProjectAs(name: name) {
        case .success:
            refreshProjects()
            globalAlert = TelemetryExportAlert(
                titleKey: "project.save.success",
                message: vm.currentProjectName
            )
        case let .failure(error):
            globalAlert = TelemetryExportAlert(
                titleKey: "project.save.failure",
                message: error.localizedDescription
            )
        }
    }

    func duplicateActiveProject(name: String) {
        guard let vm = activeSimulation else { return }
        switch vm.duplicateCurrentProject(newName: name) {
        case let .success(duplicated):
            refreshProjects()
            globalAlert = TelemetryExportAlert(
                titleKey: "project.duplicate.success",
                message: duplicated.name
            )
        case let .failure(error):
            globalAlert = TelemetryExportAlert(
                titleKey: "project.duplicate.failure",
                message: error.localizedDescription
            )
        }
    }

    func deleteProject(_ summary: ProjectRecordSummary) {
        do {
            try projectStorage.deleteProject(id: summary.id)
            if activeSimulation?.currentProjectID == summary.id {
                activeSimulation = nil
            }
            refreshProjects()
        } catch {
            globalAlert = TelemetryExportAlert(
                titleKey: "project.delete.failure",
                message: error.localizedDescription
            )
        }
    }

    func requestReturnToMenu() {
        guard let vm = activeSimulation else {
            activeSimulation = nil
            return
        }
        if vm.hasUnsavedChanges {
            pendingExitAction = .returnToMenu
            showUnsavedPrompt = true
        } else {
            activeSimulation = nil
            refreshProjects()
        }
    }

    func saveOnlyFromUnsavedDialog() {
        saveActiveProject()
        pendingExitAction = nil
    }

    func saveAndExecutePendingAction() {
        saveActiveProject()
        executePendingAction()
    }

    func executePendingActionWithoutSave() {
        executePendingAction()
    }

    func cancelPendingAction() {
        pendingExitAction = nil
    }

    private func executePendingAction() {
        defer { pendingExitAction = nil }
        switch pendingExitAction {
        case .none:
            break
        case .returnToMenu:
            activeSimulation = nil
            refreshProjects()
        case .closeWindow:
            allowWindowClose = true
            window?.performClose(nil)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowWindowClose {
            allowWindowClose = false
            return true
        }

        guard let vm = activeSimulation, vm.hasUnsavedChanges else {
            return true
        }

        pendingExitAction = .closeWindow
        showUnsavedPrompt = true
        return false
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowResolveView {
        let view = WindowResolveView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: WindowResolveView, context: Context) {
        nsView.onResolve = onResolve
    }
}

private final class WindowResolveView: NSView {
    var onResolve: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onResolve?(window)
        }
    }
}

private struct SimulationViewModelObserver<Content: View>: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    let content: (DroneSimulationViewModel) -> Content

    var body: some View {
        content(viewModel)
    }
}

private struct SignalInterferenceOverlayView: View {
    let presentation: SignalInterferencePresentation
    let onRecover: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 18.0)) { timeline in
            GeometryReader { geometry in
                let time = timeline.date.timeIntervalSinceReferenceDate

                ZStack(alignment: .topTrailing) {
                    if presentation.state.isInteractionBlocking {
                        Color.black
                            .opacity(0.74)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.08 + presentation.intensity * 0.12),
                                        Color.black.opacity(0.0),
                                        Color.white.opacity(0.04 + presentation.intensity * 0.08)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .opacity(0.55 + abs(sin(time * 4.2)) * 0.18)
                    }

                    SignalInterferenceCanvas(
                        state: presentation.state,
                        intensity: presentation.intensity,
                        time: time
                    )

                    VStack(spacing: 24) {
                        HStack {
                            Spacer()

                            if let warningTitle = presentation.warningTitle {
                                signalWarningCard(
                                    title: warningTitle,
                                    detail: presentation.warningDetail,
                                    countdownText: presentation.countdownText,
                                    state: presentation.state
                                )
                            }
                        }

                        Spacer()

                        if presentation.state.isInteractionBlocking {
                            VStack(spacing: 12) {
                                if let lostTitle = presentation.lostTitle {
                                    Text(lostTitle)
                                        .font(.title2.weight(.bold))
                                        .foregroundStyle(.white)
                                }

                                if let lostMessage = presentation.lostMessage {
                                    Text(lostMessage)
                                        .font(.body)
                                        .foregroundStyle(Color.white.opacity(0.88))
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: 360)
                                }

                                if let recoveryButtonTitle = presentation.recoveryButtonTitle {
                                    Button(recoveryButtonTitle, action: onRecover)
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                        .tint(Color.white.opacity(0.92))
                                        .foregroundStyle(.black)
                                        .padding(.top, 6)
                                }
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 24)
                            .background(Color.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 20))
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 1.0)
                            )
                            .shadow(color: Color.black.opacity(0.38), radius: 22, y: 14)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(presentation.isInteractionBlocking)
    }

    @ViewBuilder
    private func signalWarningCard(
        title: String,
        detail: String?,
        countdownText: String?,
        state: UAVSignalState
    ) -> some View {
        let tint: Color = switch state {
        case .outOfBoundsWarning:
            Color(red: 0.98, green: 0.73, blue: 0.28)
        case .signalDegrading:
            Color(red: 0.96, green: 0.58, blue: 0.22)
        case .boundaryCountdown:
            Color(red: 0.98, green: 0.42, blue: 0.28)
        case .normal, .signalLost, .recoveryPending:
            GroundControlPalette.warning
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.76))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let countdownText {
                Text(countdownText)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tint.opacity(0.18), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(0.72), lineWidth: 1.0)
                    )
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.54), lineWidth: 1.0)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 18, y: 10)
    }
}

private struct SignalInterferenceCanvas: View {
    let state: UAVSignalState
    let intensity: Double
    let time: TimeInterval

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let clampedIntensity = max(0.0, min(1.0, intensity))
            switch state {
            case .normal:
                break
            case .outOfBoundsWarning, .signalDegrading, .boundaryCountdown:
                let bandCount = state == .outOfBoundsWarning ? 4 : state == .signalDegrading ? 8 : 11
                for index in 0..<bandCount {
                    let seed = time * 5.4 + Double(index) * 17.0
                    let width = size.width * CGFloat(0.16 + Self.noise(seed + 2.6) * 0.24)
                    let height = size.height * CGFloat(0.006 + Self.noise(seed + 1.3) * 0.024)
                    let x = (size.width - width) * CGFloat(Self.noise(seed + 3.8))
                    let y = (size.height - height) * CGFloat(Self.noise(seed + 0.9))
                    context.fill(
                        Path(CGRect(x: x, y: y, width: width, height: height)),
                        with: .color(Self.paletteColor(seed: seed + 5.0, isSignalLost: false).opacity(0.08 + clampedIntensity * 0.16))
                    )
                }

                let blockCount = state == .outOfBoundsWarning ? 18 : state == .signalDegrading ? 34 : 52
                let timeBucket = floor(time * 9.0)
                for index in 0..<blockCount {
                    let seed = timeBucket + Double(index) * 11.3
                    let width = max(4.0, size.width * CGFloat(0.006 + Self.noise(seed + 1.1) * 0.026))
                    let height = max(3.0, size.height * CGFloat(0.004 + Self.noise(seed + 2.7) * 0.018))
                    let x = (size.width - width) * CGFloat(Self.noise(seed + 4.4))
                    let y = (size.height - height) * CGFloat(Self.noise(seed + 5.9))
                    context.fill(
                        Path(CGRect(x: x, y: y, width: width, height: height)),
                        with: .color(Self.paletteColor(seed: seed + 7.2, isSignalLost: false).opacity((0.04 + clampedIntensity * 0.14) * Self.noise(seed + 8.5)))
                    )
                }

                let sweepCount = state == .outOfBoundsWarning ? 1 : 2
                for index in 0..<sweepCount {
                    let seed = time * (0.6 + Double(index) * 0.18)
                    let width = size.width * CGFloat(0.18 + Self.noise(seed + 1.7) * 0.12)
                    let x = (size.width - width) * CGFloat(Self.noise(seed + 2.4))
                    let opacity = (state == .outOfBoundsWarning ? 0.02 : 0.035) + clampedIntensity * 0.05
                    context.fill(
                        Path(CGRect(x: x, y: 0.0, width: width, height: size.height)),
                        with: .color(Self.paletteColor(seed: seed + 3.3, isSignalLost: false).opacity(opacity))
                    )
                }
            case .signalLost, .recoveryPending:
                let spacing = max(2.0, 7.0 - clampedIntensity * 3.5)
                let scanAlpha = 0.04 + clampedIntensity * 0.16

                for y in stride(from: 0.0, through: size.height, by: spacing) {
                    let rect = CGRect(x: 0.0, y: y, width: size.width, height: 1.0)
                    context.fill(
                        Path(rect),
                        with: .color(Self.paletteColor(seed: y * 0.17, isSignalLost: true).opacity(scanAlpha))
                    )
                }

                for index in 0..<18 {
                    let seed = time * 7.1 + Double(index) * 19.37
                    let y = size.height * Self.noise(seed)
                    let height = size.height * CGFloat(0.03 + Self.noise(seed + 1.7) * 0.16)
                    let widthScale = CGFloat(0.62 + Self.noise(seed + 3.3) * 0.38)
                    let xOffset = size.width * CGFloat((Self.noise(seed + 5.1) - 0.5) * clampedIntensity * 0.22)
                    let rect = CGRect(x: xOffset, y: y, width: size.width * widthScale, height: height)
                    context.fill(
                        Path(rect),
                        with: .color(Self.paletteColor(seed: seed + 9.4, isSignalLost: true).opacity(0.05 + clampedIntensity * 0.28))
                    )
                }

                let timeBucket = floor(time * 18.0)
                for index in 0..<180 {
                    let seed = timeBucket + Double(index) * 13.11
                    let x = size.width * Self.noise(seed)
                    let y = size.height * Self.noise(seed + 2.4)
                    let width = max(1.0, size.width * CGFloat(0.002 + Self.noise(seed + 4.2) * 0.012))
                    let height = max(1.0, size.height * CGFloat(0.002 + Self.noise(seed + 6.8) * 0.018))
                    let opacity = (0.03 + clampedIntensity * 0.42) * Self.noise(seed + 8.5)
                    context.fill(
                        Path(CGRect(x: x, y: y, width: width, height: height)),
                        with: .color(Self.paletteColor(seed: seed + 11.0, isSignalLost: true).opacity(opacity))
                    )
                }

                for index in 0..<4 {
                    let seed = time * 2.8 + Double(index) * 11.0
                    let x = size.width * Self.noise(seed + 0.7)
                    let width = size.width * CGFloat(0.10 + Self.noise(seed + 1.9) * 0.20)
                    let opacity = (0.04 + clampedIntensity * 0.20) * abs(sin(time * (2.0 + Double(index))))
                    context.fill(
                        Path(CGRect(x: x, y: 0.0, width: width, height: size.height)),
                        with: .color(Self.paletteColor(seed: seed + 14.0, isSignalLost: true).opacity(opacity))
                    )
                }

                for index in 0..<12 {
                    let seed = time * 5.3 + Double(index) * 8.7
                    let y = size.height * Self.noise(seed + 0.8)
                    let height = size.height * CGFloat(0.008 + Self.noise(seed + 2.1) * 0.04)
                    let shift = size.width * CGFloat((Self.noise(seed + 3.7) - 0.5) * 0.08)
                    let baseRect = CGRect(x: 0.0, y: y, width: size.width, height: height)
                    for offsetIndex in 0..<3 {
                        let channelRect = baseRect.offsetBy(dx: shift * CGFloat(offsetIndex - 1), dy: 0.0)
                        context.fill(
                            Path(channelRect),
                            with: .color(Self.signalLossChannelColor(offsetIndex).opacity(0.08 + clampedIntensity * 0.10))
                        )
                    }
                }
            }
        }
    }

    private static func noise(_ input: Double) -> Double {
        let value = sin(input * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private static func paletteColor(seed: Double, isSignalLost: Bool) -> Color {
        let palette = isSignalLost ? signalLossPalette : interferencePalette
        let index = Int(floor(noise(seed) * Double(palette.count))) % palette.count
        return palette[max(0, index)]
    }

    private static func signalLossChannelColor(_ index: Int) -> Color {
        signalLossPalette[index % signalLossPalette.count]
    }

    private static let interferencePalette: [Color] = [
        Color.white,
        Color(red: 0.78, green: 0.92, blue: 1.0),
        Color(red: 0.96, green: 0.88, blue: 0.74)
    ]

    private static let signalLossPalette: [Color] = [
        Color(red: 0.44, green: 0.92, blue: 1.0),
        Color(red: 1.0, green: 0.38, blue: 0.78),
        Color(red: 0.84, green: 1.0, blue: 0.28),
        Color(red: 1.0, green: 0.72, blue: 0.26)
    ]
}

private struct SimulationToolstripView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private static let selectorButtonWidth: CGFloat = 142
    private static let selectorButtonHeight: CGFloat = 46

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ControlModule.allCases) { module in
                    moduleButton(module)
                }

                PayloadToolbarEntry(
                    isPresented: viewModel.isPayloadPanelVisible,
                    payloadState: viewModel.payloadState,
                    payloadMountState: viewModel.payloadMountState
                ) {
                    viewModel.togglePayloadPanel()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(GroundControlPalette.shell)
    }

    private func moduleButton(_ module: ControlModule) -> some View {
        Button {
            viewModel.toggleActiveControlModule(module)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: module.iconSystemName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 16)

                Text(LocalizedStringKey(module.toolbarTitleKey))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 4)

                if viewModel.activeControlModule == module {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(GroundControlPalette.accent)
                }
            }
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 10)
            .frame(width: Self.selectorButtonWidth, height: Self.selectorButtonHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(viewModel.activeControlModule == module ? GroundControlPalette.accent.opacity(0.18) : GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(viewModel.activeControlModule == module ? GroundControlPalette.accent.opacity(0.58) : GroundControlPalette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: "toolbar.module.\(module.id)") {
            viewModel.toggleActiveControlModule(module)
        }
    }
}

private struct KeyBindingsSheetHost: View {
    @ObservedObject var simulationViewModel: DroneSimulationViewModel
    @ObservedObject private var bindingsViewModel: BindingsViewModel

    init(simulationViewModel: DroneSimulationViewModel) {
        self.simulationViewModel = simulationViewModel
        _bindingsViewModel = ObservedObject(wrappedValue: simulationViewModel.bindingsViewModel)
    }

    var body: some View {
        EmptyView()
            .sheet(isPresented: Binding(
                get: { bindingsViewModel.isPresented },
                set: { simulationViewModel.setBindingsPanelVisible($0) }
            ), onDismiss: {
                simulationViewModel.setBindingsPanelVisible(false)
            }) {
                ControllerInteractionSurface(
                    bridge: simulationViewModel.controllerUIBridge,
                    surfaceID: "keybindings-sheet",
                    secondaryAction: {
                        simulationViewModel.setBindingsPanelVisible(false)
                    }
                ) {
                    KeyBindingsSettingsView(
                        simulationViewModel: simulationViewModel,
                        bindingsViewModel: bindingsViewModel
                    )
                }
                .frame(width: 760, height: 720)
            }
    }
}

struct ContentView: View {
    @StateObject private var appShell = AppShellViewModel()
    @AppStorage("app.language") private var appLanguageRawValue: String = AppLanguage.system.rawValue

    @State private var nameDialogMode: NameDialogMode?
    @State private var nameDraft: String = ""
    @State private var deleteCandidate: ProjectRecordSummary?

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: appLanguageRawValue) ?? .system
    }

    private var selectedLanguageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: appLanguageRawValue) ?? .system },
            set: { appLanguageRawValue = $0.rawValue }
        )
    }

    var body: some View {
        Group {
            if let viewModel = appShell.activeSimulation {
                SimulationViewModelObserver(viewModel: viewModel) { observedViewModel in
                    simulationWorkspace(observedViewModel)
                }
            } else {
                startScreen
            }
        }
        .environment(\.locale, selectedLanguage.locale)
        .background(
            WindowAccessor { window in
                appShell.bind(window: window)
            }
            .frame(width: 0, height: 0)
        )
        .sheet(item: $nameDialogMode) { mode in
            projectNameSheet(mode: mode)
        }
        .alert(
            Text("project.unsaved.title"),
            isPresented: $appShell.showUnsavedPrompt
        ) {
            Button("project.unsaved.save") {
                appShell.saveOnlyFromUnsavedDialog()
            }
            Button("project.unsaved.save_exit") {
                appShell.saveAndExecutePendingAction()
            }
            Button("project.unsaved.exit_without", role: .destructive) {
                appShell.executePendingActionWithoutSave()
            }
            Button("common.cancel", role: .cancel) {
                appShell.cancelPendingAction()
            }
        } message: {
            Text(unsavedMessage())
        }
        .alert(item: $appShell.globalAlert) { item in
            Alert(
                title: Text(LocalizedStringKey(item.titleKey)),
                message: Text(item.message),
                dismissButton: .default(Text("common.ok"))
            )
        }
        .alert(item: $deleteCandidate) { candidate in
            Alert(
                title: Text("project.delete.confirm.title"),
                message: Text(String(format: NSLocalizedString("project.delete.confirm.message", comment: ""), candidate.name)),
                primaryButton: .destructive(Text("project.delete.action")) {
                    appShell.deleteProject(candidate)
                },
                secondaryButton: .cancel(Text("common.cancel"))
            )
        }
        .onChange(of: nameDialogMode) { _, _ in
            if nameDialogMode != nil {
                appShell.activeSimulation?.setControllerHubVisible(false)
                appShell.activeSimulation?.setBindingsPanelVisible(false)
            }
            let isBindingsVisible = appShell.activeSimulation?.bindingsViewModel.isPresented ?? false
            appShell.activeSimulation?.setExternalControllerOverlayActive(
                nameDialogMode != nil || isBindingsVisible
            )
        }
    }

    private func unsavedMessage() -> String {
        let projectName = appShell.activeSimulation?.currentProjectName ?? "Project"
        return String(
            format: NSLocalizedString("project.unsaved.message", comment: ""),
            projectName
        )
    }

    private var startScreen: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("menu.saved_projects")
                    .font(.headline)
                    .padding(.bottom, 2)

                VStack(alignment: .leading, spacing: 8) {
                    TextField(String(localized: "menu.search"), text: $appShell.searchQuery)
                        .textFieldStyle(.roundedBorder)

                    Picker("menu.sort", selection: $appShell.sortOrder) {
                        ForEach(ProjectSortOrder.allCases) { order in
                            Text(LocalizedStringKey(order.titleKey)).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(appShell.visibleProjects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            .frame(width: 370, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.12, blue: 0.18),
                        Color(red: 0.05, green: 0.08, blue: 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    Text("menu.title")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Button {
                        nameDraft = projectDefaultName()
                        nameDialogMode = .create
                    } label: {
                        VStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 44, weight: .bold))
                            Text("menu.create_project")
                                .font(.headline)
                        }
                        .frame(width: 280, height: 220)
                        .foregroundStyle(.white)
                        .background(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.white.opacity(0.65), lineWidth: 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 22)
                                        .fill(Color.white.opacity(0.08))
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    if let recent = appShell.visibleProjects.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("menu.recent_project")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.75))
                            Text(recent.name)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .lineLimit(1)
                            Text(formattedDate(recent.modifiedAt))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
            }
        }
        .frame(minWidth: 1200, minHeight: 820)
    }

    private func simulationWorkspace(_ viewModel: DroneSimulationViewModel) -> some View {
        ControllerInteractionSurface(
            bridge: viewModel.controllerUIBridge,
            surfaceID: "simulation-workspace",
            secondaryAction: {
                viewModel.handleControllerUICancel()
            }
        ) {
            ZStack {
                VStack(spacing: 0) {
                simulationHeader(viewModel)

                if viewModel.isToolPanelVisible {
                    Divider()

                    SimulationToolstripView(
                        viewModel: viewModel
                    )

                    Divider()
                }

                HStack(spacing: 0) {
                    if viewModel.isParametersPanelVisible, viewModel.activeControlModule != nil {
                        SidebarModuleHostView(
                            viewModel: viewModel,
                            appLanguage: selectedLanguageBinding
                        )
                        .frame(width: 430)

                        Divider()
                    }

                    SceneViewportView(viewModel: viewModel)
                        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if viewModel.isPayloadPanelVisible {
                    payloadOverlay(for: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }

                if viewModel.isMissionMapVisible {
                    missionMapOverlay(for: viewModel)
                        .transition(.opacity)
                }

                if viewModel.isControllerHubVisible {
                    controllerHubOverlay(for: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if viewModel.signalInterferencePresentation.isVisible {
                    SignalInterferenceOverlayView(
                        presentation: viewModel.signalInterferencePresentation,
                        onRecover: {
                            viewModel.recoverSignal()
                        }
                    )
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: viewModel.isPayloadPanelVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyBindingsSheetHost(simulationViewModel: viewModel))
        .alert("battery.depleted.title", isPresented: Binding(
            get: { viewModel.showBatteryDepletedDialog },
            set: { viewModel.showBatteryDepletedDialog = $0 }
        )) {
            Button("battery.depleted.charge") {
                viewModel.chargeDroneAndContinue()
            }
            Button("battery.depleted.restart") {
                viewModel.simulateAgainFromStart()
            }
        } message: {
            Text("battery.depleted.message")
        }
        .alert(item: Binding(
            get: { viewModel.telemetryExportAlert },
            set: { viewModel.telemetryExportAlert = $0 }
        )) { item in
            Alert(
                title: Text(LocalizedStringKey(item.titleKey)),
                message: Text(item.message),
                dismissButton: .default(Text("common.ok"))
            )
        }
    }

    @ViewBuilder
    private func simulationHeader(_ viewModel: DroneSimulationViewModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                simulationHeaderTitle(viewModel)
                Spacer(minLength: 12)
                simulationHeaderUtilityRow(viewModel)
            }

            VStack(alignment: .leading, spacing: 10) {
                simulationHeaderTitle(viewModel)
                simulationHeaderUtilityRow(viewModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, viewModel.connectedGameControllers.isEmpty ? 9 : 11)
        .background(GroundControlPalette.panel)
    }

    @ViewBuilder
    private func simulationHeaderTitle(_ viewModel: DroneSimulationViewModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                projectTitleLabel(viewModel)
                simulationActiveModuleChip(viewModel)
                simulationControllerModeChip(viewModel)
            }

            VStack(alignment: .leading, spacing: 8) {
                projectTitleLabel(viewModel)

                HStack(spacing: 8) {
                    simulationActiveModuleChip(viewModel)
                    simulationControllerModeChip(viewModel)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectTitleLabel(_ viewModel: DroneSimulationViewModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(viewModel.currentProjectName)
                .font(.headline)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            if viewModel.hasUnsavedChanges {
                Text("•")
                    .foregroundStyle(GroundControlPalette.warning)
            }
        }
    }

    @ViewBuilder
    private func simulationActiveModuleChip(_ viewModel: DroneSimulationViewModel) -> some View {
        if let activeModule = viewModel.activeControlModule {
            HStack(spacing: 8) {
                Image(systemName: activeModule.iconSystemName)
                Text(LocalizedStringKey(activeModule.titleKey))
                    .lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(GroundControlPalette.panelRaised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func simulationControllerModeChip(_ viewModel: DroneSimulationViewModel) -> some View {
        if let controllerPresentation = controllerModePresentation(viewModel) {
            HStack(spacing: 7) {
                Image(systemName: controllerPresentation.icon)
                Text(controllerPresentation.label)
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(GroundControlPalette.accent.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(GroundControlPalette.accent.opacity(0.52), lineWidth: 1)
            )
        }
    }

    private func controllerModePresentation(
        _ viewModel: DroneSimulationViewModel
    ) -> (icon: String, label: String)? {
        let controllerCount = viewModel.connectedGameControllers.count
        guard controllerCount > 0 else {
            return nil
        }

        switch viewModel.controllerInteractionMode {
        case .flight:
            return (
                "gamecontroller",
                controllerCount == 1 ? "1P FLIGHT" : "\(controllerCount)P FLIGHT"
            )
        case .uiNavigation:
            return (
                "cursorarrow.motionlines",
                controllerCount == 1 ? "1P UI" : "\(controllerCount)P UI"
            )
        case .textInput:
            return (
                "keyboard",
                controllerCount == 1 ? "1P TEXT" : "\(controllerCount)P TEXT"
            )
        }
    }

    @ViewBuilder
    private func simulationHeaderUtilityRow(_ viewModel: DroneSimulationViewModel) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                parametersToggle(viewModel)
                simulationHeaderButtons(viewModel)
            }

            VStack(alignment: .leading, spacing: 8) {
                parametersToggle(viewModel)
                simulationHeaderButtons(viewModel)
            }
        }
    }

    private func parametersToggle(_ viewModel: DroneSimulationViewModel) -> some View {
        Toggle(isOn: parametersVisibilityBinding(for: viewModel)) {
            Text(viewModel.isParametersPanelVisible ? "panel.modules.on" : "panel.modules.off")
                .font(.caption)
        }
        .toggleStyle(.checkbox)
        .foregroundStyle(GroundControlPalette.textSecondary)
        .frame(width: 168, alignment: .leading)
    }

    private func simulationHeaderButtons(_ viewModel: DroneSimulationViewModel) -> some View {
        HStack(spacing: 8) {
            Menu {
                Button("project.save.action") {
                    appShell.saveActiveProject()
                }
                Button("project.save_as.action") {
                    nameDraft = projectDerivedName(from: viewModel.currentProjectName, suffixKey: "project.copy_suffix")
                    nameDialogMode = .saveAs
                }
                Button("project.duplicate.action") {
                    nameDraft = projectDerivedName(from: viewModel.currentProjectName, suffixKey: "project.clone_suffix")
                    nameDialogMode = .duplicate
                }
                Divider()
                Button("project.open.action") {
                    appShell.requestReturnToMenu()
                }
                Button("window.fullscreen") {
                    toggleFullscreen()
                }
                Button("project.delete.action", role: .destructive) {
                    deleteCandidate = ProjectRecordSummary(
                        id: viewModel.currentProjectID,
                        name: viewModel.currentProjectName,
                        createdAt: Date(),
                        modifiedAt: Date(),
                        lastOpenedAt: Date(),
                        lastSavedAt: Date()
                    )
                }
            } label: {
                headerUtilityButtonLabel(systemImage: "folder.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .help(String(localized: "toolbar.header.project"))

            Button {
                viewModel.setBindingsPanelVisible(true)
            } label: {
                headerUtilityButtonLabel(systemImage: "keyboard")
            }
            .buttonStyle(.plain)
            .help(String(localized: "keybind.open"))
            .controllerButtonTarget(id: "header.keybindings") {
                viewModel.setBindingsPanelVisible(true)
            }

            Button {
                viewModel.toggleMissionMap()
            } label: {
                headerUtilityButtonLabel(systemImage: "map")
            }
            .buttonStyle(.plain)
            .help(String(localized: "mission.map.open_help"))
            .controllerButtonTarget(id: "header.missionMap") {
                viewModel.toggleMissionMap()
            }

            Button {
                viewModel.setToolPanelVisible(false)
            } label: {
                headerUtilityButtonLabel(systemImage: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isToolPanelVisible)
            .help(String(localized: "panel.hide"))
            .controllerButtonTarget(id: "header.hideTools") {
                viewModel.setToolPanelVisible(false)
            }

            Button {
                viewModel.setToolPanelVisible(true)
            } label: {
                headerUtilityButtonLabel(systemImage: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isToolPanelVisible)
            .help(String(localized: "panel.show"))
            .controllerButtonTarget(id: "header.showTools") {
                viewModel.setToolPanelVisible(true)
            }
        }
    }

    @ViewBuilder
    private func payloadOverlay(for viewModel: DroneSimulationViewModel) -> some View {
        ControllerInteractionSurface(
            bridge: viewModel.controllerUIBridge,
            surfaceID: "payload-overlay",
            secondaryAction: {
                viewModel.handleControllerUICancel()
            }
        ) {
            ZStack(alignment: .top) {
                Color.black.opacity(0.34)
                    .ignoresSafeArea()
                    .onTapGesture {
                        viewModel.setPayloadPanelVisible(false)
                    }

                ControllerScrollableRegion(
                    id: "payload.overlay.scroll",
                    showsIndicators: false,
                    isPrimary: true
                ) {
                    PayloadView(
                        configuration: viewModel.payloadDraftConfiguration,
                        payloadState: viewModel.payloadState,
                        payloadMountState: viewModel.payloadMountState,
                        capabilityCheck: viewModel.payloadCapabilityCheck,
                        massModel: viewModel.vehicleMassModel,
                        statusMessageKey: viewModel.payloadStatusMessageKey,
                        activeUAVProfile: viewModel.activeUAVProfile,
                        onTypeChange: viewModel.setPayloadType,
                        onMassChange: viewModel.setPayloadMass,
                        onCustomNameChange: viewModel.setPayloadCustomName,
                        onAttach: viewModel.attachPayload,
                        onRelease: viewModel.releasePayload,
                        onRemove: viewModel.removePayload,
                        onClose: {
                            viewModel.setPayloadPanelVisible(false)
                        }
                    )
                    .frame(maxWidth: 1040)
                    .padding(.horizontal, 28)
                    .padding(.top, viewModel.isToolPanelVisible ? 132 : 88)
                    .padding(.bottom, 40)
                }
            }
            .zIndex(4)
        }
    }

    @ViewBuilder
    private func missionMapOverlay(for viewModel: DroneSimulationViewModel) -> some View {
        ControllerInteractionSurface(
            bridge: viewModel.controllerUIBridge,
            surfaceID: "mission-map-overlay",
            secondaryAction: {
                viewModel.handleControllerUICancel()
            }
        ) {
            TacticalMapHostView(
                snapshot: viewModel.terrainMapSnapshot,
                state: viewModel.tacticalMapState,
                missionPlan: viewModel.currentMissionPlan,
                profileName: viewModel.selectedDroneProfile.uiDisplayName,
                supportedLaunchModes: viewModel.selectedDroneProfile.supportedLaunchModes,
                executionState: viewModel.missionExecutionState,
                missionStatus: viewModel.missionStatusSnapshot,
                fixedWingAssistState: viewModel.fixedWingAssistState,
                fixedWingAssistWaypoints: viewModel.fixedWingAssistWaypointOptions,
                missionTimeline: viewModel.missionTimeline,
                missionDebrief: viewModel.missionDebrief,
                onSetMode: viewModel.setTacticalMapMode,
                onMapTap: viewModel.handleTacticalMapTap,
                onRemoveLastWaypoint: viewModel.removeLastTacticalWaypoint,
                onClearRoute: viewModel.clearTacticalRoute,
                onClearZones: viewModel.clearTacticalZones,
                onSetZoneRadius: viewModel.setTacticalZoneRadius,
                onSetMinimumAltitude: viewModel.setTacticalMinimumAltitude,
                onSetMaximumAltitude: viewModel.setTacticalMaximumAltitude,
                onSetMinimumSpeed: viewModel.setTacticalMinimumSpeed,
                onSetMaximumSpeed: viewModel.setTacticalMaximumSpeed,
                onSetLaunchMode: viewModel.setTacticalLaunchMode,
                onSetLaunchHeading: viewModel.setTacticalLaunchHeading,
                onClearLaunchObject: viewModel.clearTacticalLaunchObject,
                onSaveDraft: viewModel.saveTacticalMissionDraft,
                onPrepareMission: viewModel.prepareMission,
                onStartMission: viewModel.startMissionExecution,
                onPauseMission: viewModel.pauseMissionExecution,
                onResumeMission: viewModel.resumeMissionExecution,
                onAbortMission: viewModel.abortMissionExecution,
                onSelectFixedWingAssistWaypoint: viewModel.selectFixedWingAssistWaypoint,
                onSetFixedWingAutoAdvanceEnabled: viewModel.setFixedWingAutoAdvanceEnabled,
                onActivateFixedWingAssist: viewModel.activateFixedWingAssist,
                onCancel: viewModel.cancelMissionPlanningChanges,
                onExit: viewModel.exitMissionMap
            )
            .zIndex(5)
        }
    }

    @ViewBuilder
    private func controllerHubOverlay(
        for viewModel: DroneSimulationViewModel
    ) -> some View {
        ControllerInteractionSurface(
            bridge: viewModel.controllerUIBridge,
            surfaceID: "controller-hub-overlay",
            secondaryAction: {
                viewModel.setControllerHubVisible(false)
            }
        ) {
            ControllerHubOverlay(
                viewModel: viewModel,
                settingsStore: viewModel.controllerSettingsStore,
                onClose: {
                    viewModel.setControllerHubVisible(false)
                }
            )
        }
    }

    private func parametersVisibilityBinding(for viewModel: DroneSimulationViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.isParametersPanelVisible && viewModel.activeControlModule != nil },
            set: { viewModel.setControlPanelVisible($0) }
        )
    }

    private func headerUtilityButtonLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .frame(width: 30, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func projectNameSheet(mode: NameDialogMode) -> some View {
        let sheetContent = VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(mode.titleKey))
                .font(.headline)

            TextField(String(localized: "project.name"), text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .controllerTextInputTarget(
                    id: "project.name.input",
                    title: String(localized: "project.name"),
                    placeholder: String(localized: "project.name"),
                    currentText: { nameDraft },
                    onCommit: { nameDraft = $0 }
                )

            HStack {
                Spacer()
                Button("common.cancel") {
                    nameDialogMode = nil
                }
                .controllerButtonTarget(id: "project.name.cancel") {
                    nameDialogMode = nil
                }

                Button(LocalizedStringKey(mode.actionKey)) {
                    submitProjectNameDialog(mode)
                }
                .buttonStyle(.borderedProminent)
                .controllerButtonTarget(id: "project.name.confirm") {
                    submitProjectNameDialog(mode)
                }
            }
        }
        .padding(16)
        .frame(width: 420)

        if let controllerBridge = appShell.activeSimulation?.controllerUIBridge {
            ControllerInteractionSurface(
                bridge: controllerBridge,
                surfaceID: "project-name-sheet",
                secondaryAction: {
                    nameDialogMode = nil
                }
            ) {
                sheetContent
            }
        } else {
            sheetContent
        }
    }

    private func submitProjectNameDialog(_ mode: NameDialogMode) {
        switch mode {
        case .create:
            appShell.createProject(named: nameDraft)
        case .saveAs:
            appShell.saveActiveProjectAs(name: nameDraft)
        case .duplicate:
            appShell.duplicateActiveProject(name: nameDraft)
        }
        nameDialogMode = nil
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func projectDefaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return String(
            format: NSLocalizedString("project.default_name", comment: ""),
            formatter.string(from: Date())
        )
    }

    private func projectDerivedName(from baseName: String, suffixKey: String) -> String {
        "\(baseName) \(NSLocalizedString(suffixKey, comment: ""))"
    }

    private func projectCard(_ project: ProjectRecordSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                appShell.openProject(project)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                    Text(formattedDate(project.modifiedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                deleteCandidate = project
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
