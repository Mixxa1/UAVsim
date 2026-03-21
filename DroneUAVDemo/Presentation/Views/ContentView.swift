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

private enum ToolstripTab: String, CaseIterable, Identifiable {
    case simulation
    case flight
    case camera
    case environment
    case debug
    case projects

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .simulation:
            return "toolstrip.tab.simulation"
        case .flight:
            return "toolstrip.tab.flight"
        case .camera:
            return "toolstrip.tab.camera"
        case .environment:
            return "toolstrip.tab.environment"
        case .debug:
            return "toolstrip.tab.debug"
        case .projects:
            return "toolstrip.tab.projects"
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

                ZStack {
                    Color.black
                        .opacity(presentation.state.isInteractionBlocking ? 0.74 : 0.10)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.04 + presentation.intensity * 0.12),
                                    Color.black.opacity(0.0),
                                    Color.white.opacity(0.02 + presentation.intensity * 0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(0.55 + abs(sin(time * 4.2)) * 0.18)

                    SignalInterferenceCanvas(
                        intensity: presentation.intensity,
                        time: time,
                        isSignalLost: presentation.state.isInteractionBlocking
                    )

                    VStack(spacing: 24) {
                        if let countdownText = presentation.countdownText {
                            Text(countdownText)
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(Color.black.opacity(0.72), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(0.78), lineWidth: 1.2)
                                )
                                .shadow(color: Color.black.opacity(0.34), radius: 18, y: 8)
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

                        Spacer()
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
}

private struct SignalInterferenceCanvas: View {
    let intensity: Double
    let time: TimeInterval
    let isSignalLost: Bool

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let clampedIntensity = max(0.0, min(1.0, intensity))
            let spacing = max(2.0, 7.0 - clampedIntensity * 3.5)
            let scanAlpha = 0.04 + clampedIntensity * 0.16

            for y in stride(from: 0.0, through: size.height, by: spacing) {
                let rect = CGRect(x: 0.0, y: y, width: size.width, height: 1.0)
                context.fill(Path(rect), with: .color(Color.white.opacity(scanAlpha)))
            }

            let bandCount = isSignalLost ? 18 : 7
            for index in 0..<bandCount {
                let seed = time * 7.1 + Double(index) * 19.37
                let y = size.height * Self.noise(seed)
                let height = size.height * CGFloat(0.02 + Self.noise(seed + 1.7) * (isSignalLost ? 0.18 : 0.08))
                let widthScale = CGFloat(0.62 + Self.noise(seed + 3.3) * 0.38)
                let xOffset = size.width * CGFloat((Self.noise(seed + 5.1) - 0.5) * clampedIntensity * 0.22)
                let rect = CGRect(x: xOffset, y: y, width: size.width * widthScale, height: height)
                let opacity = 0.05 + clampedIntensity * (isSignalLost ? 0.28 : 0.14)
                context.fill(Path(rect), with: .color(Color.white.opacity(opacity)))
            }

            let noiseCount = isSignalLost ? 180 : Int(40 + clampedIntensity * 36.0)
            let timeBucket = floor(time * (isSignalLost ? 18.0 : 9.0))
            for index in 0..<noiseCount {
                let seed = timeBucket + Double(index) * 13.11
                let x = size.width * Self.noise(seed)
                let y = size.height * Self.noise(seed + 2.4)
                let width = max(1.0, size.width * CGFloat(0.002 + Self.noise(seed + 4.2) * 0.012))
                let height = max(1.0, size.height * CGFloat(0.002 + Self.noise(seed + 6.8) * 0.018))
                let opacity = (0.03 + clampedIntensity * (isSignalLost ? 0.42 : 0.18)) * Self.noise(seed + 8.5)
                context.fill(
                    Path(CGRect(x: x, y: y, width: width, height: height)),
                    with: .color(Color.white.opacity(opacity))
                )
            }

            let flashCount = isSignalLost ? 4 : 2
            for index in 0..<flashCount {
                let seed = time * 2.8 + Double(index) * 11.0
                let x = size.width * Self.noise(seed + 0.7)
                let width = size.width * CGFloat(0.10 + Self.noise(seed + 1.9) * 0.20)
                let opacity = (0.04 + clampedIntensity * 0.20) * abs(sin(time * (2.0 + Double(index))))
                let rect = CGRect(x: x, y: 0.0, width: width, height: size.height)
                context.fill(Path(rect), with: .color(Color.white.opacity(opacity)))
            }
        }
    }

    private static func noise(_ input: Double) -> Double {
        let value = sin(input * 12.9898) * 43758.5453
        return value - floor(value)
    }
}

private struct SimulationToolstripView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var selectedTab: ToolstripTab

    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onDuplicate: () -> Void
    let onOpenProjects: () -> Void
    let onDeleteProject: () -> Void
    let onToggleFullscreen: () -> Void

    private static let throttleFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $selectedTab) {
                ForEach(ToolstripTab.allCases) { tab in
                    Text(LocalizedStringKey(tab.titleKey)).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    sectionsForSelectedTab
                }
                .padding(.vertical, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var sectionsForSelectedTab: some View {
        switch selectedTab {
        case .simulation:
            sectionCard("toolstrip.section.run") {
                HStack(spacing: 8) {
                    Button(viewModel.isSimulationRunning ? String(localized: "command.stop_animation") : String(localized: "command.start_animation")) {
                        viewModel.toggleSimulation()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("command.reset") {
                        viewModel.reset()
                    }
                    .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("command.takeoff") { viewModel.takeoff() }
                    Button("command.hover") { viewModel.hover() }
                    Button("command.land") { viewModel.land() }
                }
                .buttonStyle(.bordered)

                HStack(spacing: 8) {
                    if viewModel.isArmed {
                        Button("command.arm") { viewModel.arm() }
                            .buttonStyle(.bordered)
                        Button("command.disarm") { viewModel.disarm() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("command.arm") { viewModel.arm() }
                            .buttonStyle(.borderedProminent)
                        Button("command.disarm") { viewModel.disarm() }
                            .buttonStyle(.bordered)
                    }
                }

                Button("command.emergency_stop") {
                    viewModel.activateEmergencyStop()
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

        case .flight:
            sectionCard("toolstrip.section.flight_model") {
                Picker("panel.model", selection: Binding(
                    get: { viewModel.selectedDroneProfile.id },
                    set: { viewModel.selectDroneModel(id: $0) }
                )) {
                    ForEach(viewModel.availableDroneProfiles, id: \.id) { profile in
                        Text(profile.uiDisplayName).tag(profile.id)
                    }
                }
                .frame(width: 230)

                Picker("control_mode.title", selection: Binding(
                    get: { viewModel.flightControlMode },
                    set: { viewModel.setFlightControlMode($0) }
                )) {
                    ForEach(FlightControlMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }
                .frame(width: 230)

                Button("payload.select") {
                    viewModel.showPayloadSelectionPlaceholder()
                }
                .buttonStyle(.bordered)
            }

            sectionCard("toolstrip.section.throttle") {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("panel.throttle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField(
                            String(localized: "panel.throttle"),
                            value: Binding(
                                get: { viewModel.controlValues.throttle },
                                set: { viewModel.setThrottle($0) }
                            ),
                            formatter: Self.throttleFormatter
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 86)
                    }

                    Slider(
                        value: Binding(
                            get: { viewModel.controlValues.throttle },
                            set: { viewModel.setThrottle($0) }
                        ),
                        in: 0.0...1.0,
                        step: 0.01
                    )
                    .frame(width: 220)
                }
            }

        case .camera:
            sectionCard("toolstrip.section.camera_modes") {
                HStack(spacing: 8) {
                    cameraModeButton("1", mode: .free)
                    cameraModeButton("2", mode: .follow)
                    cameraModeButton("3", mode: .orbit)
                    cameraModeButton("4", mode: .fpv)
                    cameraModeButton("5", mode: .top)
                }

                HStack(spacing: 8) {
                    Button("camera.reset_orientation") {
                        viewModel.resetCameraToPreset()
                    }
                    .buttonStyle(.bordered)

                    Button("camera.zoom_in") {
                        viewModel.setActiveCameraDistance(max(viewModel.activeCameraDistanceRange.lowerBound, viewModel.activeCameraDistance - 0.9))
                    }
                    .buttonStyle(.bordered)

                    Button("camera.zoom_out") {
                        viewModel.setActiveCameraDistance(min(viewModel.activeCameraDistanceRange.upperBound, viewModel.activeCameraDistance + 0.9))
                    }
                    .buttonStyle(.bordered)
                }
            }

            sectionCard("toolstrip.section.camera_quick") {
                Picker("camera.preset.title", selection: Binding(
                    get: { viewModel.selectedCameraPreset },
                    set: { viewModel.setCameraPreset($0) }
                )) {
                    ForEach(CameraPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .frame(width: 220)
            }

        case .environment:
            sectionCard("toolstrip.section.weather") {
                Picker("panel.weather", selection: Binding(
                    get: { viewModel.weather.preset },
                    set: { viewModel.setWeatherPreset($0) }
                )) {
                    ForEach(WeatherPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .frame(width: 170)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.weather.intensity) },
                        set: { viewModel.setWeatherIntensity($0) }
                    ),
                    in: 0.0...1.0,
                    step: 0.01
                )
                .frame(width: 170)
            }

            sectionCard("toolstrip.section.terrain") {
                Picker("panel.terrain", selection: Binding(
                    get: { viewModel.terrain.preset },
                    set: { viewModel.setTerrainPreset($0) }
                )) {
                    ForEach(TerrainPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                    }
                }
                .frame(width: 170)

                Picker("terrain.scale", selection: Binding(
                    get: { viewModel.terrain.mapScale },
                    set: { viewModel.setTerrainMapScale($0) }
                )) {
                    ForEach(MapScale.allCases) { scale in
                        Text(LocalizedStringKey(scale.titleKey)).tag(scale)
                    }
                }
                .frame(width: 170)

                Slider(
                    value: Binding(
                        get: { Double(viewModel.terrain.density) },
                        set: { viewModel.setTerrainDensity($0) }
                    ),
                    in: 0.1...1.0,
                    step: 0.01,
                    onEditingChanged: { editing in
                        viewModel.setTerrainDensityEditing(editing)
                        if !editing {
                            viewModel.commitTerrainDensityChange()
                        }
                    }
                )
                .frame(width: 170)
            }

        case .debug:
            sectionCard("toolstrip.section.debug") {
                Toggle("panel.collision_debug", isOn: $viewModel.collisionDebugEnabled)
                    .toggleStyle(.switch)

                HStack(spacing: 8) {
                    Button("diagnostic.toggle_thermal") { viewModel.toggleThermalOverlay() }
                        .buttonStyle(.bordered)
                    Button("diagnostic.toggle_damage") { viewModel.toggleDamageOverlay() }
                        .buttonStyle(.bordered)
                }

                Button("ui.toggle_telemetry_hud") { viewModel.toggleCompactTelemetryHUD() }
                    .buttonStyle(.bordered)
            }

        case .projects:
            sectionCard("toolstrip.section.projects") {
                HStack(spacing: 8) {
                    Button("project.save.action") { onSave() }
                        .buttonStyle(.borderedProminent)
                    Button("project.save_as.action") { onSaveAs() }
                        .buttonStyle(.bordered)
                    Button("project.duplicate.action") { onDuplicate() }
                        .buttonStyle(.bordered)
                }

                HStack(spacing: 8) {
                    Button("project.open.action") { onOpenProjects() }
                        .buttonStyle(.bordered)
                    Button("project.delete.action", role: .destructive) { onDeleteProject() }
                        .buttonStyle(.bordered)
                    Button("window.fullscreen") { onToggleFullscreen() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func cameraModeButton(_ title: String, mode: CameraMode) -> some View {
        if viewModel.cameraConfiguration.mode == mode {
            Button(title) {
                viewModel.setCameraMode(mode)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button(title) {
                viewModel.setCameraMode(mode)
            }
            .buttonStyle(.bordered)
        }
    }

    private func sectionCard<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ContentView: View {
    @StateObject private var appShell = AppShellViewModel()
    @AppStorage("app.language") private var appLanguageRawValue: String = AppLanguage.system.rawValue

    @State private var nameDialogMode: NameDialogMode?
    @State private var nameDraft: String = ""
    @State private var deleteCandidate: ProjectRecordSummary?
    @State private var selectedToolstripTab: ToolstripTab = .simulation
    @State private var showBindingsSettings: Bool = false

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
        ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    Text(viewModel.currentProjectName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    if viewModel.hasUnsavedChanges {
                        Text("•")
                            .foregroundStyle(.orange)
                    }

                    Spacer()
                    Text("workspace.toolstrip")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Divider()
                        .frame(height: 18)

                    Toggle(isOn: parametersVisibilityBinding(for: viewModel)) {
                        Text(viewModel.isParametersPanelVisible ? "panel.parameters.on" : "panel.parameters.off")
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .frame(width: 168, alignment: .leading)

                    Button {
                        viewModel.setToolPanelVisible(false)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isToolPanelVisible)
                    .help(String(localized: "panel.hide"))

                    Button {
                        viewModel.setToolPanelVisible(true)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isToolPanelVisible)
                    .help(String(localized: "panel.show"))

                    Button("keybind.open") {
                        showBindingsSettings = true
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(nsColor: .windowBackgroundColor))

                if viewModel.isToolPanelVisible {
                    Divider()

                    SimulationToolstripView(
                        viewModel: viewModel,
                        selectedTab: $selectedToolstripTab,
                        onSave: {
                            appShell.saveActiveProject()
                        },
                        onSaveAs: {
                            nameDraft = "\(viewModel.currentProjectName) Copy"
                            nameDialogMode = .saveAs
                        },
                        onDuplicate: {
                            nameDraft = "\(viewModel.currentProjectName) Clone"
                            nameDialogMode = .duplicate
                        },
                        onOpenProjects: {
                            appShell.requestReturnToMenu()
                        },
                        onDeleteProject: {
                            deleteCandidate = ProjectRecordSummary(
                                id: viewModel.currentProjectID,
                                name: viewModel.currentProjectName,
                                createdAt: Date(),
                                modifiedAt: Date(),
                                lastOpenedAt: Date(),
                                lastSavedAt: Date()
                            )
                        },
                        onToggleFullscreen: {
                            toggleFullscreen()
                        }
                    )

                    Divider()
                }

                HStack(spacing: 0) {
                    if viewModel.isParametersPanelVisible {
                        ControlPanelView(
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

            if viewModel.signalInterferencePresentation.isVisible {
                SignalInterferenceOverlayView(
                    presentation: viewModel.signalInterferencePresentation,
                    onRecover: {
                        viewModel.recoverSignal()
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .sheet(isPresented: $showBindingsSettings) {
            KeyBindingsSettingsView(viewModel: viewModel)
        }
        .alert("payload.select", isPresented: Binding(
            get: { viewModel.showPayloadPlaceholder },
            set: { viewModel.showPayloadPlaceholder = $0 }
        )) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text("payload.placeholder.message")
        }
    }

    private func parametersVisibilityBinding(for viewModel: DroneSimulationViewModel) -> Binding<Bool> {
        Binding(
            get: { viewModel.isParametersPanelVisible },
            set: { viewModel.setControlPanelVisible($0) }
        )
    }

    @ViewBuilder
    private func projectNameSheet(mode: NameDialogMode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LocalizedStringKey(mode.titleKey))
                .font(.headline)

            TextField(String(localized: "project.name"), text: $nameDraft)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("common.cancel") {
                    nameDialogMode = nil
                }
                Button(LocalizedStringKey(mode.actionKey)) {
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
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 420)
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
        return "Project \(formatter.string(from: Date()))"
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
