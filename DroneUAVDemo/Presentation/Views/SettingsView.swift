import SwiftUI
import AppKit

/// Application settings overlay reached from the start menu: graphics quality, resolution/window,
/// language, third-party credits and the legal documents. Persists through the same `@AppStorage`
/// keys the scene/render layers read via `AppGraphicsSettings` / `L10n`.
struct SettingsView: View {
    let onClose: () -> Void
    /// Applies a window-size preset through the app's bound main window (ContentView wires this to
    /// `AppShell.applyWindowSizePreset` — more reliable than reaching for `NSApp.mainWindow` here).
    var onApplyWindowSize: (WindowSizePreset) -> Void = { _ in }
    private let onStartInstructor: ((InstructorLaunchMode) -> Void)?
    @AppStorage(InstructorProgressStore.flightCourseCompletedKey) private var flightCourseCompleted = false

    @StateObject private var bindings: BindingsViewModel
    @State private var selected: SettingsPage = .guide
    private let simulationViewModel: DroneSimulationViewModel?

    init(onClose: @escaping () -> Void, onApplyWindowSize: @escaping (WindowSizePreset) -> Void = { _ in },
         simulationViewModel: DroneSimulationViewModel? = nil,
         onStartInstructor: ((InstructorLaunchMode) -> Void)? = nil,
         initialPage: SettingsPage = .guide) {
        self.onClose = onClose
        self.onApplyWindowSize = onApplyWindowSize
        self.simulationViewModel = simulationViewModel
        self.onStartInstructor = onStartInstructor
        _selected = State(initialValue: initialPage)
        if let simulationViewModel {
            _bindings = StateObject(wrappedValue: simulationViewModel.bindingsViewModel)
        } else {
            let keyboard = KeyboardInputService()
            _bindings = StateObject(wrappedValue: BindingsViewModel(store: InputBindingsStore(keyboardInputService: keyboard),
                captureCoordinator: InputCaptureCoordinator(keyboardInputService: keyboard, inputManager: InputManager())))
        }
    }
    enum SettingsPage: String, CaseIterable, Identifiable {
        case training, guide, keys, controller, video, audio, language, about
        var id: String { rawValue }
        var key: String { "settings.page." + rawValue }
        var icon: String {
            switch self {
            case .training: return "graduationcap.fill"
            case .guide: return "book.closed"
            case .keys: return "keyboard"
            case .controller: return "gamecontroller"
            case .video: return "display"
            case .audio: return "speaker.wave.2"
            case .language: return "globe"
            case .about: return "info.circle"
            }
        }
    }

    @AppStorage(AppGraphicsSettings.qualityKey) private var qualityRaw: String = GraphicsQualityPreset.high.rawValue
    @AppStorage(AppGraphicsSettings.renderScaleKey) private var renderScale: Double = 0.0
    @AppStorage(AppGraphicsSettings.windowSizeKey) private var windowSizeRaw: String = WindowSizePreset.native.rawValue
    @AppStorage("app.language") private var languageRaw: String = AppLanguage.system.rawValue
    @AppStorage(AppAudioSettings.masterVolumeKey) private var masterVolume: Double = AppAudioSettings.defaultMasterVolume
    @AppStorage(AppAudioSettings.mutedKey) private var isAudioMuted: Bool = false

    private var quality: GraphicsQualityPreset {
        GraphicsQualityPreset(rawValue: qualityRaw) ?? .high
    }

    private var qualityBinding: Binding<GraphicsQualityPreset> {
        Binding(
            get: { GraphicsQualityPreset(rawValue: qualityRaw) ?? .high },
            set: { newValue in
                qualityRaw = newValue.rawValue
                // Render scale follows the tier default unless the user explicitly nudges it.
                renderScale = newValue.defaultRenderScale
            }
        )
    }

    private var windowSizeBinding: Binding<WindowSizePreset> {
        Binding(
            get: { WindowSizePreset(rawValue: windowSizeRaw) ?? .native },
            set: { newValue in
                windowSizeRaw = newValue.rawValue
                onApplyWindowSize(newValue)
            }
        )
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageRaw) ?? .system },
            set: { languageRaw = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(SettingsPage.allCases) { page in
                        Button { selected = page } label: {
                            Label(LocalizedStringKey(page.key), systemImage: page.icon)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(selected == page ? GroundControlPalette.accent.opacity(0.3) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }.padding(12).frame(width: 185)
                Divider()
                if selected == .keys {
                    KeyBindingsSettingsView(simulationViewModel: simulationViewModel, bindingsViewModel: bindings)
                        .padding(18)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            switch selected {
                            case .training: instructorSection
                            case .guide: guideSection
                            case .controller: controlsSection
                            case .video: videoSection; resolutionSection
                            case .audio: audioSection
                            case .language: languageSection
                            case .about: creditsSection
                            case .keys: EmptyView()
                            }
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: .infinity)

            footer
        }
        .frame(minWidth: 720, idealWidth: 980, maxWidth: 1080, minHeight: 560, idealHeight: 720, maxHeight: 820)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onAppear {
            if renderScale <= 0.0 {
                renderScale = quality.defaultRenderScale
            }
        }
    }

    private var guideSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("settings.guide.intro").font(.title3.bold())
            Text("settings.guide.context").font(.callout).foregroundStyle(.secondary)
            guideCard("settings.guide.flight", icon: "airplane", detail: "settings.guide.flight.detail",
                      commands: [.ascend, .descend, .moveForward, .moveBackward, .moveLeft, .moveRight, .yawLeft, .yawRight, .hover])
            guideCard("settings.guide.camera", icon: "camera", detail: "settings.guide.camera.detail",
                      commands: [.cycleCameraMode, .toggleFPV, .cameraYawLeft, .cameraYawRight, .cameraPitchUp, .cameraPitchDown, .zoomIn, .zoomOut, .resetCameraOrientation])
            guideCard("settings.guide.vtol", icon: "arrow.triangle.2.circlepath", detail: "settings.guide.vtol.detail",
                      commands: [.vtolTransitionForward, .vtolTransitionBack])
            guideCard("settings.guide.mechanization", icon: "airplane.arrival", detail: "settings.guide.mechanization.detail",
                      commands: [.toggleLandingGear, .stepFlaps])
            guideCard("settings.guide.tools", icon: "slider.horizontal.3", detail: "settings.guide.tools.detail",
                      commands: [.toggleMissionMap, .togglePayloadPanel, .toggleTelemetryHUD, .releasePayload, .resetDrone])
            sectionCard(titleKey: "settings.guide.cfd") {
                Text("settings.guide.cfd.detail").fixedSize(horizontal: false, vertical: true)
            }
            Button("settings.guide.edit") { selected = .keys }.buttonStyle(.borderedProminent)
        }
    }

    private var instructorSection: some View {
        InstructorSettingsView(completed: flightCourseCompleted, isEnabled: onStartInstructor != nil,
            onFlight: { onClose(); onStartInstructor?(.flightCourse) },
            onTour: { onClose(); onStartInstructor?(.appTour) })
    }

    private func guideCard(_ title: String, icon: String, detail: String, commands: [KeyboardCommand]) -> some View {
        sectionCard(titleKey: title) {
            Label(LocalizedStringKey(detail), systemImage: icon).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], spacing: 8) {
                ForEach(commands) { command in
                    HStack(spacing: 9) {
                        Text(bindings.sections.flatMap(\.bindings).first { $0.command == command }?.keyLabel ?? "—")
                            .font(.system(.body, design: .monospaced).bold())
                            .frame(minWidth: 36).padding(6)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                        Text(LocalizedStringKey(command.titleKey)).font(.caption)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings.title")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
            Text("settings.subtitle")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    /// Sticks, rates and the throttle curve. Lives here rather than behind its own main-menu
    /// button: it is a setting like graphics or audio, and it is also reachable mid-flight from
    /// the key-bindings screen — both edit the one shared store.
    private var controlsSection: some View {
        sectionCard(titleKey: "settings.section.controls") {
            ControllerAxisSettingsView(store: .shared)
        }
    }

    private var videoSection: some View {
        sectionCard(titleKey: "settings.section.video") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("settings.graphics.quality") {
                    Picker("", selection: qualityBinding) {
                        ForEach(GraphicsQualityPreset.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if quality.showsHeatWarning {
                    heatWarning
                }

                Text("settings.graphics.apply_note")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var heatWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "thermometer.sun.fill")
                .foregroundStyle(.orange)
            Text("settings.graphics.heat_warning")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private var resolutionSection: some View {
        sectionCard(titleKey: "settings.section.resolution") {
            VStack(alignment: .leading, spacing: 14) {
                labeledRow("settings.window_size") {
                    Picker("", selection: windowSizeBinding) {
                        ForEach(WindowSizePreset.allCases) { value in
                            Text(LocalizedStringKey(value.titleKey)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.render_scale")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f%%", renderScale * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                    Slider(value: $renderScale, in: 0.5...1.0, step: 0.05)
                    Text("settings.render_scale.hint")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }

                Button(action: { WindowFullscreenController.toggle() }) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("settings.fullscreen")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Master level for everything the simulation plays.
    ///
    /// One control rather than a per-category mixer: the pack is authored with its relative
    /// levels already decided (see `AudioAssetDescriptor.defaultGainDb`), and handing the
    /// operator sliders that undo that is how a simulation ends up with a rotor louder than
    /// the crash it flew into.
    private var audioSection: some View {
        sectionCard(titleKey: "settings.section.audio") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("settings.audio.master_volume")
                            .font(.caption).foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f%%", masterVolume * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                    }
                    Slider(value: $masterVolume, in: 0.0...1.0, step: 0.05)
                        .disabled(isAudioMuted)
                        .opacity(isAudioMuted ? 0.45 : 1.0)
                }

                Toggle(isOn: $isAudioMuted) {
                    Text("settings.audio.mute")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .toggleStyle(.switch)
                .tint(.white.opacity(0.65))

                Text("settings.audio.hint")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var languageSection: some View {
        sectionCard(titleKey: "settings.section.language") {
            Picker("", selection: languageBinding) {
                ForEach(AppLanguage.allCases) { language in
                    Text(LocalizedStringKey(language.titleKey)).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var creditsSection: some View {
        sectionCard(titleKey: "settings.section.credits") {
            VStack(alignment: .leading, spacing: 12) {
                Text("credits.copyright_line")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                CreditsView()
                    .frame(height: 320)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("common.done")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(GroundControlPalette.accent, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(Color.white.opacity(0.04))
    }

    // MARK: Helpers

    @ViewBuilder
    private func sectionCard<Content: View>(
        titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(.white.opacity(0.6))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func labeledRow<Content: View>(
        _ titleKey: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.caption).foregroundStyle(.white.opacity(0.8))
            content()
        }
    }
}
