import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

// Keeps the SceneKit scene alive across SwiftUI body re-evaluations.
private final class ReplaySceneHolder: ObservableObject {
    let controller = MissionReplaySceneController()
}

// MARK: - WASD keyboard state

private final class WASDMonitor: ObservableObject {
    var pressedKeys: Set<UInt16> = []
    var shiftActive = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // Fullscreen replay viewer handles its own keyboard via FullscreenReplayWindow.sendEvent — don't touch it
            if event.window is FullscreenReplayWindow { return event }
            switch event.type {
            case .keyDown:
                let kc = event.keyCode
                if [13, 1, 0, 2, 12, 14].contains(Int(kc)) {
                    self.pressedKeys.insert(kc)
                    self.shiftActive = event.modifierFlags.contains(.shift)
                    return nil
                }
            case .keyUp:
                self.pressedKeys.remove(event.keyCode)
                self.shiftActive = event.modifierFlags.contains(.shift)
            case .flagsChanged:
                self.shiftActive = event.modifierFlags.contains(.shift)
            default:
                break
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        pressedKeys = []
    }
}

struct ReplayCenterView: View {
    @ObservedObject var viewModel: ReplayLibraryViewModel
    var availableDroneProfiles: [DroneModelProfile] = []
    var onDismiss: (() -> Void)? = nil

    @StateObject private var replayPlayer = MissionReplayPlayer()
    @StateObject private var sceneHolder = ReplaySceneHolder()
    @StateObject private var videoExportService = ReplayVideoExportService()
    @StateObject private var wasdMonitor = WASDMonitor()
    @Environment(\.dismiss) private var dismiss
    @State private var deleteCandidate: MissionReplayRecordSummary?
    @State private var cameraMode: ReplayCameraMode = .freeObserver
    @State private var topDownHeight: Double = 120
    @State private var reconstructionStatus: ReplayReconstructionStatus = .none
    @State private var fullscreenSession: MissionReplaySession?
    @State private var selectedReplayEvent: MissionReplayEvent?
    @State private var trimRange = ReplayTrimRange(startTime: 0, endTime: 0)
    @State private var telemetrySeries: [ReplayTelemetrySeries] = []
    @State private var exportSettings = ReplayVideoExportSettings.defaultSettings
    @State private var exportCameraMode: ReplayCameraMode = .freeObserver
    @State private var exportUsesTrimRange = true
    @State private var lastExportURL: URL?
    @State private var comparisonReplayID: UUID?
    @State private var comparisonResult: ReplayComparisonResult?

    var body: some View {
        HStack(spacing: 0) {
            listPanel
            Divider()
            detailPanel
        }
        .frame(minWidth: 1020, minHeight: 660)
        .background(GroundControlPalette.shell)
        .onAppear {
            viewModel.refresh()
            wasdMonitor.start()
        }
        .onDisappear {
            wasdMonitor.stop()
        }
        .onChange(of: viewModel.selectedSummaryID) { _, newID in
            replayPlayer.unload()
            cameraMode = .freeObserver
            exportCameraMode = .freeObserver
            topDownHeight = 120
            selectedReplayEvent = nil
            trimRange = ReplayTrimRange(startTime: 0, endTime: 0)
            telemetrySeries = []
            comparisonResult = nil
            sceneHolder.controller.setCameraMode(.freeObserver)
            sceneHolder.controller.setTopDownHeight(Float(topDownHeight))
            sceneHolder.controller.setSelectedEvent(nil)
            if let id = newID, let session = viewModel.loadSession(id: id) {
                fullscreenSession = session
                replayPlayer.load(session: session)
                trimRange = ReplayTrimRange(startTime: 0, endTime: replayPlayer.duration)
                rebuildTelemetrySeries(for: session)
                let events = viewModel.selectedReport?.events ?? []
                sceneHolder.controller.loadSession(
                    session,
                    availableDroneProfiles: availableDroneProfiles,
                    events: events
                )
                reconstructionStatus = sceneHolder.controller.reconstructionStatus
            } else {
                fullscreenSession = nil
                reconstructionStatus = .none
            }
        }
        .onChange(of: cameraMode) { _, newMode in
            sceneHolder.controller.setCameraMode(newMode)
            sceneHolder.controller.setTopDownHeight(Float(topDownHeight))
            sceneHolder.controller.setSelectedEvent(selectedReplayEvent)
            if let frame = replayPlayer.currentFrame {
                sceneHolder.controller.update(frame: frame)
            }
        }
        .onChange(of: topDownHeight) { _, newHeight in
            sceneHolder.controller.setTopDownHeight(Float(newHeight))
            if let frame = replayPlayer.currentFrame {
                sceneHolder.controller.update(frame: frame)
            }
        }
        .onChange(of: selectedReplayEvent) { _, event in
            sceneHolder.controller.setSelectedEvent(event)
            if let event, cameraMode == .cinematicEvent {
                replayPlayer.seek(to: event.timestamp)
                sceneHolder.controller.update(frame: replayPlayer.currentFrame)
            }
        }
        .onChange(of: trimRange) { _, _ in
            guard let session = fullscreenSession else { return }
            trimRange = trimRange.clamped(to: replayPlayer.duration)
            rebuildTelemetrySeries(for: session)
        }
        .onReceive(Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()) { _ in
            replayPlayer.update(deltaTime: 1.0 / 60.0)
            if replayPlayer.isPlaying {
                sceneHolder.controller.update(frame: replayPlayer.currentFrame)
            }
            if cameraMode == .freeObserver {
                let keys = wasdMonitor.pressedKeys
                guard !keys.isEmpty else { return }
                let speed: Float = wasdMonitor.shiftActive ? 48.0 : 16.0
                var delta = SIMD3<Float>.zero
                if keys.contains(13) { delta.z -= 1 }  // W
                if keys.contains(1)  { delta.z += 1 }  // S
                if keys.contains(0)  { delta.x -= 1 }  // A
                if keys.contains(2)  { delta.x += 1 }  // D
                if keys.contains(12) { delta.y -= 1 }  // Q
                if keys.contains(14) { delta.y += 1 }  // E
                let len = simd_length(delta)
                if len > 0.001 {
                    sceneHolder.controller.moveCamera(localDelta: (delta / len) * speed / 60.0)
                }
            }
        }
        .alert(item: $deleteCandidate) { candidate in
            Alert(
                title: Text("Удалить запись?"),
                message: Text("\"\(candidate.title)\" будет безвозвратно удалена."),
                primaryButton: .destructive(Text("Удалить")) {
                    replayPlayer.unload()
                    viewModel.delete(id: candidate.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    // MARK: - List panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            if viewModel.summaries.isEmpty {
                emptyListState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.summaries) { summary in
                            recordRow(summary)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            retentionFooter
        }
        .frame(width: 300)
        .background(GroundControlPalette.panel)
    }

    private var listHeader: some View {
        HStack {
            Image(systemName: "archivebox.fill")
                .foregroundStyle(GroundControlPalette.accent)
            Text("Бортовой самописец")
                .font(.headline)
            Spacer()
            Button { if let onDismiss { onDismiss() } else { dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(GroundControlPalette.panelRaised, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var emptyListState: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text("Нет записей")
                .font(.subheadline)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text("Записи сохраняются автоматически после каждого цикла ВООРУЖИТЬ \u{2192} РАЗОРУЖИТЬ.")
                .font(.caption)
                .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func recordRow(_ summary: MissionReplayRecordSummary) -> some View {
        let isSelected = viewModel.selectedSummaryID == summary.id
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? GroundControlPalette.accent : GroundControlPalette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label(formatDuration(summary.durationSeconds), systemImage: "clock")
                    Label("\(summary.frameCount) fr", systemImage: "square.stack")
                }
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
            }
            Spacer(minLength: 4)
            Button { deleteCandidate = summary } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1.0 : 0.0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? GroundControlPalette.accent.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                replayPlayer.unload()
                viewModel.clearSelection()
            } else {
                viewModel.select(id: summary.id)
            }
        }
    }

    private var retentionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Авто-удаление старых записей", isOn: $viewModel.retentionPolicy.isAutoDeleteEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
                .foregroundStyle(GroundControlPalette.textSecondary)
            if viewModel.retentionPolicy.isAutoDeleteEnabled {
                HStack(spacing: 8) {
                    Text("Хранить последние")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Stepper(value: $viewModel.retentionPolicy.maxStoredReplayCount, in: 1...100) {
                        Text("\(viewModel.retentionPolicy.maxStoredReplayCount)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(GroundControlPalette.textPrimary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Detail panel

    private var detailPanel: some View {
        Group {
            if viewModel.selectedSummaryID != nil {
                loadedDetailContent
            } else {
                noSelectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GroundControlPalette.shell)
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.5))
            Text("Выберите запись для просмотра отчёта")
                .font(.subheadline)
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
    }

    private var loadedDetailContent: some View {
        VStack(spacing: 0) {
            MissionReplaySceneViewRepresentable(
                sceneController: sceneHolder.controller,
                cameraMode: cameraMode
            )
            .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)

            Divider()

            playerControlsBar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(GroundControlPalette.panel)

            Divider()

            ReplayTimelineEditorView(
                duration: replayPlayer.duration,
                events: viewModel.selectedReport?.events ?? fullscreenSession?.events ?? [],
                currentTime: Binding(
                    get: { replayPlayer.currentTime },
                    set: { t in
                        replayPlayer.seek(to: t)
                        sceneHolder.controller.update(frame: replayPlayer.currentFrame)
                    }
                ),
                trimRange: $trimRange,
                onSeek: { t in
                    replayPlayer.seek(to: t)
                    sceneHolder.controller.update(frame: replayPlayer.currentFrame)
                }
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(GroundControlPalette.panel)

            Divider()

            frameInfoStrip
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(GroundControlPalette.panelRaised.opacity(0.6))

            Divider()

            reconstructionPanel
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(GroundControlPalette.panel.opacity(0.7))

            if let report = viewModel.selectedReport {
                Divider()
                reportScrollView(report)
                    .frame(minHeight: 120, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Visual Reconstruction panel

    private var reconstructionPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                Text("Визуальная реконструкция")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                qualityBadge(reconstructionStatus.quality)
            }

            if !reconstructionStatus.warningMessages.isEmpty {
                ForEach(reconstructionStatus.warningMessages, id: \.self) { warning in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(GroundControlPalette.warning)
                        Text(warning)
                            .font(.system(size: 9))
                            .foregroundStyle(GroundControlPalette.warning.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(spacing: 14) {
                reconstructionCell("БЛА", reconstructionStatus.uavDisplayName)
                reconstructionCell("Местность", reconstructionStatus.terrainDisplayName)
                reconstructionCell("Погода", reconstructionStatus.weatherDisplayName)
                reconstructionCell("Груз", reconstructionStatus.payloadDisplayName)
                Spacer()
            }
        }
    }

    private func qualityBadge(_ quality: ReplayReconstructionStatus.Quality) -> some View {
        let color: Color
        switch quality {
        case .full:     color = Color(red: 0.20, green: 0.85, blue: 0.35)
        case .partial:  color = Color(red: 1.00, green: 0.82, blue: 0.00)
        case .fallback: color = Color(red: 0.75, green: 0.40, blue: 0.15)
        }
        return Text(quality.rawValue)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(color.opacity(0.4), lineWidth: 1))
    }

    private func reconstructionCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Player controls

    private var playerControlsBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                transportButton(icon: "stop.fill", enabled: replayPlayer.isLoaded) {
                    replayPlayer.stop()
                    sceneHolder.controller.update(frame: replayPlayer.currentFrame)
                }

                transportButton(
                    icon: replayPlayer.isPlaying ? "pause.fill" : "play.fill",
                    enabled: replayPlayer.isLoaded,
                    accent: true
                ) {
                    replayPlayer.togglePlayPause()
                }

                Divider().frame(height: 18)

                transportButton(
                    icon: "backward.fill",
                    enabled: replayPlayer.isLoaded && replayPlayer.playbackSpeed > (MissionReplayPlayer.allowedSpeeds.first ?? 0)
                ) {
                    replayPlayer.slowDown()
                }

                Text(speedLabel(replayPlayer.playbackSpeed))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.accent)
                    .frame(minWidth: 38)

                transportButton(
                    icon: "forward.fill",
                    enabled: replayPlayer.isLoaded && replayPlayer.playbackSpeed < (MissionReplayPlayer.allowedSpeeds.last ?? 0)
                ) {
                    replayPlayer.speedUp()
                }

                Spacer(minLength: 12)

                if replayPlayer.isLoaded {
                    Text("\(fmtTime(replayPlayer.currentTime)) / \(fmtTime(replayPlayer.duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .monospacedDigit()
                }

                Button {
                    guard let session = fullscreenSession else { return }
                    FullscreenReplayWindowHost.open(
                        session: session,
                        report: viewModel.selectedReport,
                        availableDroneProfiles: availableDroneProfiles,
                        initialTime: replayPlayer.isLoaded ? replayPlayer.currentTime : 0,
                        initialCameraMode: cameraMode,
                        selectedEvent: selectedReplayEvent
                    )
                } label: {
                    Label("На весь экран", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GroundControlPalette.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(GroundControlPalette.accent.opacity(0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(GroundControlPalette.accent.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(fullscreenSession == nil)
                .opacity(fullscreenSession != nil ? 1.0 : 0.38)
                .help("Открыть воспроизведение во весь экран")
            }

            HStack(spacing: 10) {
                Text("Камера")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(width: 64, alignment: .leading)

                Picker("", selection: $cameraMode) {
                    ForEach(availableCameraModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(idealWidth: 690, maxWidth: 760, alignment: .leading)
                .layoutPriority(1)
                .disabled(!replayPlayer.isLoaded)

                if cameraMode == .topDown {
                    Divider().frame(height: 18)

                    Text("Высота \(Int(topDownHeight)) м")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .frame(width: 92, alignment: .leading)

                    Slider(value: $topDownHeight, in: 30...400)
                        .tint(GroundControlPalette.accent)
                        .frame(width: 150)
                        .disabled(!replayPlayer.isLoaded)
                }

                Spacer(minLength: 0)
            }

            if replayPlayer.isLoaded, replayPlayer.duration > 0 {
                Slider(
                    value: Binding(
                        get: { replayPlayer.currentTime },
                        set: { t in
                            replayPlayer.seek(to: t)
                            sceneHolder.controller.update(frame: replayPlayer.currentFrame)
                        }
                    ),
                    in: 0...replayPlayer.duration
                )
                .tint(GroundControlPalette.accent)
            }
        }
    }

    private func transportButton(icon: String, enabled: Bool, accent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent ? GroundControlPalette.accent : GroundControlPalette.textPrimary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(accent ? GroundControlPalette.accent.opacity(0.14) : GroundControlPalette.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(accent ? GroundControlPalette.accent.opacity(0.5) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.38)
    }

    // MARK: - Frame info strip

    private var frameInfoStrip: some View {
        Group {
            if let frame = replayPlayer.currentFrame {
                let vel = frame.velocity.simd
                let speed = (vel.x * vel.x + vel.y * vel.y + vel.z * vel.z).squareRoot()
                HStack(spacing: 16) {
                    frameCell("T", String(format: "%.1fs", frame.timestamp))
                    frameCell("X", String(format: "%.1f", frame.position.x))
                    frameCell("Y", String(format: "%.1f м", frame.position.y))
                    frameCell("Z", String(format: "%.1f", frame.position.z))
                    frameCell("Ск", String(format: "%.1f м/с", speed))
                    frameCell("Режим", frame.flightModeDescription)
                    frameCell("АП", frame.autopilotDescription ?? "н/д")
                    frameCell("Бат", frame.batteryPercent.map { String(format: "%.1f%%", $0) } ?? "н/д")
                    frameCell("Пред", "\(frame.warningCount)",
                              tint: frame.warningCount > 0 ? GroundControlPalette.warning : nil)
                    Spacer()
                }
            } else {
                Text(replayPlayer.isLoaded ? "Нет данных кадра" : "Сессия не загружена")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func frameCell(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(tint ?? GroundControlPalette.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - Report

    private func reportScrollView(_ report: MissionReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Отчёт о миссии")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)

                metricsGrid(report.summary)

                trimPanel

                telemetryPanel(events: report.events)

                exportPanel

                comparisonPanel

                if !report.events.isEmpty {
                    Divider()
                    eventListSection(report.events)
                }

                Divider()

                Text(report.textSummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }

    private func metricsGrid(_ s: MissionReportSummary) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 4),
            spacing: 8
        ) {
            metricCell("Длительность", formatDuration(s.durationSeconds), "clock")
            metricCell("Кадры", "\(s.frameCount)", "square.stack")
            metricCell("События", "\(s.eventCount)", "bolt")
            metricCell("Предупреждения", "\(s.warningCount)", "exclamationmark.triangle",
                       tint: s.warningCount > 0 ? GroundControlPalette.warning : nil)
            metricCell("Макс. скорость", String(format: "%.1f м/с", s.maxSpeedMetersPerSecond), "speedometer")
            metricCell("Ср. скорость", String(format: "%.1f м/с", s.averageSpeedMetersPerSecond), "gauge")
            metricCell("Макс. высота", String(format: "%.1f м", s.maxAltitudeMeters), "arrow.up")
            metricCell("Заряд батареи", s.batteryUsedPercent.map { String(format: "%.1f%%", $0) } ?? "н/д", "battery.75")
        }
    }

    private func metricCell(_ label: String, _ value: String, _ icon: String, tint: Color? = nil) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? GroundControlPalette.accent)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: - Analytics / trim / export

    private var trimPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Обрезка")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Button("Просмотр") {
                    replayPlayer.seek(to: trimRange.startTime)
                    sceneHolder.controller.update(frame: replayPlayer.currentFrame)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GroundControlPalette.accent)

                Button("Сброс") {
                    trimRange = ReplayTrimRange(startTime: 0, endTime: replayPlayer.duration)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GroundControlPalette.textSecondary)
            }

            HStack(spacing: 18) {
                frameCell("Начало", fmtTime(trimRange.startTime))
                frameCell("Конец", fmtTime(trimRange.endTime))
                frameCell("Выбрано", fmtTime(trimRange.duration))
                Text("Оригинальная запись сохраняется. Обрезка применяется к графикам и экспорту.")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
            }
        }
        .padding(10)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    private func telemetryPanel(events: [MissionReplayEvent]) -> some View {
        let graphEvents = normalizedEventsForTrim(events)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Телеметрия")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                telemetryGraph(title: "Высота", events: graphEvents)
                telemetryGraph(title: "Скорость", events: graphEvents)
                telemetryGraph(title: "Батарея", events: graphEvents)
                let attitude = telemetrySeries.filter { ["Крен", "Тангаж", "Рыскание"].contains($0.title) }
                ReplayTelemetryGraphView(
                    series: attitude,
                    events: graphEvents,
                    duration: max(0.001, trimRange.duration)
                )
            }
        }
    }

    private func telemetryGraph(title: String, events: [MissionReplayEvent]) -> some View {
        let series = telemetrySeries.filter { $0.title == title }
        return ReplayTelemetryGraphView(
            series: series,
            events: events,
            duration: max(0.001, trimRange.duration)
        )
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Экспорт видео")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                if videoExportService.isExporting {
                    Button("Отмена") { videoExportService.cancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    exportControl("Режим", width: 150) {
                        Picker("", selection: Binding(
                            get: { exportSettings.exportMode },
                            set: { applyExportMode($0) }
                        )) {
                            ForEach(ReplayVideoExportMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }

                    exportControl("Формат", width: 120) {
                        Picker("", selection: Binding(
                            get: { exportSettings.format },
                            set: { exportSettings.format = $0 }
                        )) {
                            ForEach(ReplayVideoExportFormat.allCases) { format in
                                Text(format.rawValue.uppercased()).tag(format)
                            }
                        }
                    }

                    exportControl("Разрешение", width: 130) {
                        Picker("", selection: resolutionPresetBinding) {
                            ForEach(availableResolutionPresets) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                    }

                    exportControl("FPS", width: 90) {
                        Picker("", selection: Binding(
                            get: { exportSettings.framesPerSecond },
                            set: {
                                exportSettings.framesPerSecond = $0
                                exportSettings = exportSettings.clamped
                            }
                        )) {
                            Text("24").tag(24)
                            if exportSettings.exportMode == .quality {
                                Text("30").tag(30)
                            }
                        }
                    }

                    exportControl("Битрейт", width: 140) {
                        Picker("", selection: bitratePresetBinding) {
                            ForEach(ReplayExportBitratePreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(alignment: .top, spacing: 12) {
                    exportControl("Камера", width: 260) {
                        Picker("", selection: $exportCameraMode) {
                            ForEach(availableCameraModes) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    }

                    if exportSettings.bitratePreset == .custom {
                        exportControl("Свой битрейт", width: 210) {
                            Stepper(
                                "\(String(format: "%.1f", customBitrateMbpsBinding.wrappedValue)) Mbps",
                                value: customBitrateMbpsBinding,
                                in: 0.5...40.0,
                                step: 0.5
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }
            }

            Text(exportSettings.exportMode.description)
                .font(.caption2)
                .foregroundStyle(exportSettings.exportMode == .quality ? .orange : GroundControlPalette.textSecondary)

            if exportSettings.exportMode == .fast && exportSettings.resolutionPreset == .p1080 {
                Text("1080p (Быстрый) доступен, однако 720p — более экономичный вариант.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Text(ReplayVideoExportSettings.performanceWarning)
                .font(.caption2)
                .foregroundStyle(.orange)

            Text(ReplayVideoExportSettings.debugBuildWarning)
                .font(.caption2)
                .foregroundStyle(.orange)

            HStack(spacing: 14) {
                if exportSettings.exportMode == .quality {
                    Toggle("Наложение", isOn: Binding(
                        get: { exportSettings.includeOverlay },
                        set: { exportSettings.includeOverlay = $0 }
                    ))
                    .toggleStyle(.checkbox)

                    Toggle("Трек пути", isOn: Binding(
                        get: { exportSettings.includePathTrail },
                        set: { exportSettings.includePathTrail = $0 }
                    ))
                    .toggleStyle(.checkbox)

                    Toggle("Метки событий", isOn: Binding(
                        get: { exportSettings.includeEventMarkers },
                        set: { exportSettings.includeEventMarkers = $0 }
                    ))
                    .toggleStyle(.checkbox)
                } else {
                    Text("Быстрый режим отключает наложения, трек пути и метки событий для снижения нагрузки.")
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 0)
            }
            .font(.caption)

            HStack(spacing: 14) {
                Toggle("Использовать обрезку", isOn: $exportUsesTrimRange)
                    .toggleStyle(.checkbox)

                Button {
                    startVideoExport()
                } label: {
                    Label("Экспортировать видео", systemImage: "square.and.arrow.down")
                }
                .disabled(videoExportService.isExporting || fullscreenSession == nil)

                if videoExportService.isExporting {
                    ProgressView(value: videoExportService.progress)
                        .frame(width: 180)
                }

                Spacer()
            }
            .font(.caption)

            HStack(spacing: 12) {
                Text("Фактический битрейт: \(String(format: "%.1f", resolvedExportBitrateMbps)) Мбит/с")
                if let estimatedExportSizeMB {
                    Text("Оценочный размер: ~\(String(format: "%.1f", estimatedExportSizeMB)) МБ")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(GroundControlPalette.textSecondary)

            if let url = lastExportURL {
                Text("Файл: \(url.path)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error = videoExportService.lastErrorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    private func exportControl<Content: View>(
        _ title: String,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .lineLimit(1)

            content()
                .controlSize(.small)
                .frame(width: width, alignment: .leading)
        }
    }

    private var comparisonPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Сравнение записей")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer()
                Picker("Вторая", selection: Binding(
                    get: { comparisonReplayID },
                    set: { comparisonReplayID = $0 }
                )) {
                    Text("Выберите запись").tag(Optional<UUID>.none)
                    ForEach(viewModel.summaries.filter { $0.id != viewModel.selectedSummaryID }) { summary in
                        Text(summary.title).tag(Optional(summary.id))
                    }
                }
                .frame(width: 260)

                Button("Сравнить") {
                    runComparison()
                }
                .disabled(comparisonReplayID == nil || fullscreenSession == nil)
            }

            if let result = comparisonResult {
                Text(result.summaryText)
                    .font(.caption)
                    .foregroundStyle(GroundControlPalette.textSecondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(result.metrics) { metric in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                            Text("\(formatMetric(metric.firstValue, unit: metric.unit)) → \(formatMetric(metric.secondValue, unit: metric.unit))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(GroundControlPalette.textPrimary)
                            Text("Δ \(formatMetric(metric.delta, unit: metric.unit))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle((metric.delta ?? 0) == 0 ? GroundControlPalette.textSecondary : GroundControlPalette.accent)
                        }
                        .padding(8)
                        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .padding(10)
        .background(GroundControlPalette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(GroundControlPalette.border, lineWidth: 1))
    }

    // MARK: - Event list

    private func eventListSection(_ events: [MissionReplayEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("События (\(events.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .padding(.bottom, 2)

            ForEach(events) { event in
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: MissionReplayEvent) -> some View {
        let isSelected = selectedReplayEvent?.id == event.id
        return HStack(spacing: 8) {
            Image(systemName: eventIcon(event.type))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(eventColor(event.type))
                .frame(width: 16, alignment: .center)

            Text(String(format: "T+%.1fs", event.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(width: 58, alignment: .leading)

            Text(event.message)
                .font(.system(size: 10))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button("Перейти") {
                jumpToEvent(event)
            }
            .font(.system(size: 10, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(GroundControlPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(GroundControlPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(GroundControlPalette.accent.opacity(0.3), lineWidth: 1))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            isSelected ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.panel.opacity(0.5),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedReplayEvent = event
        }
    }

    private func jumpToEvent(_ event: MissionReplayEvent) {
        selectedReplayEvent = event
        replayPlayer.seek(to: event.timestamp)
        sceneHolder.controller.setSelectedEvent(event)
        sceneHolder.controller.jumpCameraToFrame(replayPlayer.currentFrame)
    }

    // MARK: - Event type helpers

    private func eventIcon(_ type: MissionReplayEventType) -> String {
        switch type {
        case .sessionStarted:        return "record.circle"
        case .sessionStopped:        return "stop.circle"
        case .recordingLimitReached: return "exclamationmark.circle"
        case .armed:                 return "lock.open"
        case .disarmed:              return "lock"
        case .autopilotEnabled:      return "cpu"
        case .autopilotDisabled:     return "cpu"
        case .warning:               return "exclamationmark.triangle.fill"
        case .takeoff:               return "arrow.up.circle"
        case .landing:               return "arrow.down.circle"
        case .waypointReached:       return "mappin.circle"
        case .missionCompleted:      return "checkmark.circle.fill"
        case .missionAborted:        return "xmark.circle.fill"
        case .payloadAttached:       return "bag"
        case .payloadReleased:       return "bag.badge.minus"
        case .payloadImpact:         return "burst"
        }
    }

    private func eventColor(_ type: MissionReplayEventType) -> Color {
        switch type {
        case .sessionStarted, .sessionStopped, .recordingLimitReached:
            return Color(red: 0.20, green: 0.85, blue: 0.90)
        case .armed:
            return Color.green
        case .disarmed:
            return Color.yellow
        case .warning:
            return GroundControlPalette.warning
        case .autopilotEnabled:
            return Color(red: 0.25, green: 0.55, blue: 1.00)
        case .autopilotDisabled:
            return Color(white: 0.55)
        case .takeoff:
            return Color(white: 0.90)
        case .landing:
            return Color(white: 0.70)
        case .waypointReached:
            return Color(red: 0.10, green: 0.80, blue: 0.45)
        case .missionCompleted:
            return Color(red: 1.00, green: 0.82, blue: 0.00)
        case .missionAborted:
            return Color.red
        case .payloadAttached:
            return Color.orange
        case .payloadReleased:
            return Color(red: 0.95, green: 0.80, blue: 0.15)
        case .payloadImpact:
            return Color.red
        }
    }

    // MARK: - Helpers

    private var availableCameraModes: [ReplayCameraMode] {
        var modes: [ReplayCameraMode] = [.freeObserver, .chase, .orbit, .topDown, .fpvApproximation]
        let events = viewModel.selectedReport?.events ?? fullscreenSession?.events ?? []
        if events.contains(where: { $0.type == .payloadReleased || $0.type == .payloadImpact }) {
            modes.append(.payloadFollow)
        }
        if selectedReplayEvent != nil || !events.isEmpty {
            modes.append(.cinematicEvent)
        }
        return modes
    }

    private var availableResolutionPresets: [ReplayExportResolutionPreset] {
        switch exportSettings.exportMode {
        case .fast:
            return [.p360, .p480, .p720, .p1080]
        case .quality:
            return [.p720, .p1080, .p1440]
        }
    }

    private var resolutionPresetBinding: Binding<ReplayExportResolutionPreset> {
        Binding(
            get: { exportSettings.resolutionPreset },
            set: { applyResolutionPreset($0) }
        )
    }

    private var bitratePresetBinding: Binding<ReplayExportBitratePreset> {
        Binding(
            get: { exportSettings.bitratePreset },
            set: {
                exportSettings.bitratePreset = $0
                if $0 == .custom, exportSettings.customBitrateMbps == nil {
                    exportSettings.customBitrateMbps = resolvedExportBitrateMbps
                }
                exportSettings = exportSettings.clamped
            }
        )
    }

    private var customBitrateMbpsBinding: Binding<Double> {
        Binding(
            get: { exportSettings.customBitrateMbps ?? resolvedExportBitrateMbps },
            set: {
                exportSettings.customBitrateMbps = min(40.0, max(0.5, $0))
                exportSettings = exportSettings.clamped
            }
        )
    }

    private var resolvedExportBitrateBitsPerSecond: Int {
        exportSettings.clamped.resolvedBitrateBitsPerSecond
    }

    private var resolvedExportBitrateMbps: Double {
        Double(resolvedExportBitrateBitsPerSecond) / 1_000_000
    }

    private var estimatedExportSizeMB: Double? {
        let settings = exportSettings.clamped
        let duration = exportUsesTrimRange
            ? trimRange.clamped(to: replayPlayer.duration).duration
            : replayPlayer.duration
        guard duration > 0 else { return nil }
        let outputDuration = duration / max(0.25, settings.playbackSpeed)
        return Double(resolvedExportBitrateBitsPerSecond) * outputDuration / 8_000_000
    }

    private func applyResolutionPreset(_ preset: ReplayExportResolutionPreset) {
        exportSettings.resolutionPreset = preset
        exportSettings.width = preset.width
        exportSettings.height = preset.height
        exportSettings = exportSettings.clamped
    }

    private func applyExportMode(_ mode: ReplayVideoExportMode) {
        exportSettings.exportMode = mode
        switch mode {
        case .fast:
            if exportSettings.resolutionPreset == .p1440 {
                exportSettings.resolutionPreset = ReplayVideoExportSettings.fastResolutionPreset
            }
            exportSettings.width = exportSettings.resolutionPreset.width
            exportSettings.height = exportSettings.resolutionPreset.height
            exportSettings.framesPerSecond = ReplayVideoExportSettings.fastFramesPerSecond
            exportSettings.includeOverlay = false
            exportSettings.includePathTrail = false
            exportSettings.includeEventMarkers = false
        case .quality:
            if exportSettings.resolutionPreset == .p360 || exportSettings.resolutionPreset == .p480 {
                exportSettings.resolutionPreset = ReplayVideoExportSettings.qualityDefaultResolutionPreset
            }
            exportSettings.width = exportSettings.resolutionPreset.width
            exportSettings.height = exportSettings.resolutionPreset.height
            if ![24, 30].contains(exportSettings.framesPerSecond) {
                exportSettings.framesPerSecond = 24
            }
            exportSettings.includePathTrail = true
            exportSettings.includeEventMarkers = true
        }
        exportSettings = exportSettings.clamped
    }

    private func rebuildTelemetrySeries(for session: MissionReplaySession) {
        let builder = ReplayTelemetrySeriesBuilder()
        let duration = replayPlayer.duration > 0 ? replayPlayer.duration : (session.frames.last?.timestamp ?? session.duration)
        let range = trimRange.clamped(to: duration)
        telemetrySeries = [
            builder.buildAltitudeSeries(from: session, trimRange: range),
            builder.buildSpeedSeries(from: session, trimRange: range),
            builder.buildBatterySeries(from: session, trimRange: range),
            builder.buildRollSeries(from: session, trimRange: range),
            builder.buildPitchSeries(from: session, trimRange: range),
            builder.buildYawSeries(from: session, trimRange: range)
        ]
    }

    private func normalizedEventsForTrim(_ events: [MissionReplayEvent]) -> [MissionReplayEvent] {
        let range = trimRange.clamped(to: replayPlayer.duration)
        return events
            .filter { range.contains($0.timestamp) }
            .map { event in
                MissionReplayEvent(
                    id: event.id,
                    timestamp: event.timestamp - range.startTime,
                    type: event.type,
                    message: event.message,
                    position: event.position
                )
            }
    }

    private func startVideoExport() {
        guard let session = fullscreenSession else { return }
        var settings = exportSettings.clamped
        settings.trimRange = exportUsesTrimRange ? trimRange.clamped(to: replayPlayer.duration) : nil

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultExportFilename(format: settings.format, cameraMode: exportCameraMode)
        panel.allowedContentTypes = settings.format == .mp4 ? [.mpeg4Movie] : [.quickTimeMovie]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        lastExportURL = url

        Task {
            do {
                try await videoExportService.export(
                    session: session,
                    settings: settings,
                    outputURL: url,
                    cameraMode: exportCameraMode,
                    renderOverlay: settings.includeOverlay,
                    selectedEvent: selectedReplayEvent
                )
                lastExportURL = url
            } catch {
                lastExportURL = url
            }
        }
    }

    private func runComparison() {
        guard let first = fullscreenSession,
              let secondID = comparisonReplayID,
              let second = viewModel.loadSession(id: secondID) else { return }
        let secondReport = try? MissionReplayStorageService().loadReport(id: secondID)
        comparisonResult = ReplayComparisonBuilder().compare(
            first: first,
            firstReport: viewModel.selectedReport,
            second: second,
            secondReport: secondReport
        )
    }

    private func defaultExportFilename(format: ReplayVideoExportFormat, cameraMode: ReplayCameraMode) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let dateText = formatter.string(from: fullscreenSession?.startedAt ?? Date())
        return "replay_\(dateText)_\(cameraMode.rawValue).\(format.fileExtension)"
    }

    private func formatMetric(_ value: Double?, unit: String) -> String {
        guard let value else { return "н/д" }
        if unit.isEmpty { return String(format: "%.0f", value) }
        return String(format: "%.1f %@", value, unit)
    }

    private func speedLabel(_ speed: Double) -> String {
        switch speed {
        case 0.25: return "0.25x"
        case 0.5:  return "0.5x"
        case 1.0:  return "1x"
        case 2.0:  return "2x"
        case 4.0:  return "4x"
        case 8.0:  return "8x"
        default:   return String(format: "%.2fx", speed)
        }
    }

    private func fmtTime(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        let ms = Int((t - Double(total)) * 10)
        if total < 60 { return String(format: "%d.%ds", total, ms) }
        return String(format: "%dm%02ds", total / 60, total % 60)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
