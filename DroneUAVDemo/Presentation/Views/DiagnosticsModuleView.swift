import SwiftUI

struct DiagnosticsModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var appLanguage: AppLanguage
    @State private var activePanel: DiagnosticsDetailPanel = .overview

    private static let distanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DiagnosticsPinnedHeaderView(viewModel: viewModel)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            DiagnosticsPanelSelectorView(activePanel: $activePanel)
                .padding(.horizontal, 14)

            DiagnosticsDetailScrollView(resetToken: activePanel.rawValue) {
                activePanelContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            activePanel = .overview
        }
    }

    @ViewBuilder
    private var activePanelContent: some View {
        switch activePanel {
        case .overview:
            overviewPanel
        case .telemetry:
            telemetryPanel
        case .fleet:
            fleetPanel
        case .service:
            servicePanel
        }
    }

    private var overviewPanel: some View {
        Group {
            ModuleSection(
                titleKey: "module.diagnostics.overlay",
                subtitleKey: "module.diagnostics.overlay.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    DiagnosticsOverlayModeStrip(
                        activeMode: viewModel.diagnosticMode,
                        onSelect: viewModel.setDiagnosticMode
                    )

                    Toggle("diagnostic.collision_debug", isOn: $viewModel.collisionDebugEnabled)
                        .toggleStyle(.switch)
                        .foregroundStyle(GroundControlPalette.textPrimary)

                    ModuleMetricGrid {
                        ModuleMetricCell(
                            labelKey: "telemetry.frame_time",
                            value: String(format: "%.2f ms", viewModel.telemetry.frameTimeMs)
                        )
                        ModuleMetricCell(
                            labelKey: "telemetry.physics_time",
                            value: String(format: "%.2f ms", viewModel.telemetry.physicsTimeMs)
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.last_collision_source",
                            value: viewModel.lastCollisionSource
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.last_collision_detail",
                            value: viewModel.lastCollisionDetail
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.weather_dof_status",
                            value: viewModel.weatherDepthOfFieldAppliedStatus
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.active_physics",
                            value: "\(viewModel.diagnostics.activePhysicsBodyCount)"
                        )
                    }
                }
            }

            ModuleSection(
                titleKey: "module.diagnostics.warning_bus",
                subtitleKey: "module.diagnostics.warning_bus.subtitle"
            ) {
                if viewModel.warnings.isEmpty {
                    Text("warnings.none")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.warnings, id: \.self) { warning in
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(GroundControlPalette.warning)
                                Text(LocalizedStringKey(warning))
                                    .font(.caption)
                                    .foregroundStyle(GroundControlPalette.textPrimary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(GroundControlPalette.inset)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(GroundControlPalette.border, lineWidth: 1)
                            )
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "module.diagnostics.mission",
                subtitleKey: "module.diagnostics.mission.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    MissionSafetyPanel(
                        snapshot: viewModel.missionStatusSnapshot,
                        showsWarningList: true
                    )

                    if let explanation = viewModel.missionStatusSnapshot.primaryExplanation {
                        MissionFailureView(explanation: explanation)
                    }
                }
            }

            ModuleSection(
                titleKey: "module.diagnostics.mission_history",
                subtitleKey: "module.diagnostics.mission_history.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    MissionTimelineView(timeline: viewModel.missionTimeline)
                    MissionDebriefView(debrief: viewModel.missionDebrief)
                }
            }

            BlackBoxReplaySection(viewModel: viewModel)
        }
    }

    private var telemetryPanel: some View {
        ModuleSection(
            titleKey: "module.diagnostics.telemetry",
            subtitleKey: "module.diagnostics.telemetry.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                TelemetryPanelView(telemetry: viewModel.telemetry)

                HStack(spacing: 8) {
                    OperationalActionButton(
                        titleKey: "telemetry.export",
                        systemImage: "square.and.arrow.up",
                        prominent: true
                    ) {
                        viewModel.exportTelemetry()
                    }

                    OperationalActionButton(
                        titleKey: "ui.toggle_telemetry_hud",
                        systemImage: "rectangle.badge.waveform"
                    ) {
                        viewModel.toggleCompactTelemetryHUD()
                    }
                }
            }
        }
    }

    private var fleetPanel: some View {
        ModuleSection(
            titleKey: "module.diagnostics.fleet",
            subtitleKey: "module.diagnostics.fleet.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("diagnostic.fleet_mode", isOn: Binding(
                    get: { viewModel.fleetStatus.enabled },
                    set: { _ in viewModel.toggleFleetEnabled() }
                ))
                .toggleStyle(.switch)
                .foregroundStyle(GroundControlPalette.textPrimary)

                Picker("fleet.formation", selection: Binding(
                    get: { viewModel.fleetStatus.mode },
                    set: { viewModel.setFormationMode($0) }
                )) {
                    ForEach(FormationMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ModuleSliderRow(
                    titleKey: "fleet.separation",
                    value: Binding(
                        get: { Double(viewModel.fleetStatus.separationDistance) },
                        set: { viewModel.setSeparationDistance($0) }
                    ),
                    range: 1.0...20.0,
                    step: 0.1,
                    formatter: Self.distanceFormatter
                )
            }
        }
    }

    private var servicePanel: some View {
        Group {
            ModuleSection(
                titleKey: "module.diagnostics.damage",
                subtitleKey: "module.diagnostics.damage.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OperationalActionButton(
                            titleKey: "diagnostic.toggle_thermal",
                            systemImage: "thermometer.medium"
                        ) {
                            viewModel.toggleThermalOverlay()
                        }

                        OperationalActionButton(
                            titleKey: "diagnostic.toggle_damage",
                            systemImage: "bolt.shield"
                        ) {
                            viewModel.toggleDamageOverlay()
                        }
                    }

                    HStack(spacing: 8) {
                        OperationalActionButton(
                            titleKey: "damage.reset",
                            systemImage: "cross.case.circle",
                            tint: GroundControlPalette.warning
                        ) {
                            viewModel.resetDamageState()
                        }

                        OperationalActionButton(
                            titleKey: "damage.clear_selection",
                            systemImage: "xmark.circle"
                        ) {
                            viewModel.selectComponent(nil)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(DamageComponent.allCases.prefix(6)), id: \.id) { component in
                            HStack(spacing: 10) {
                                Button {
                                    viewModel.selectComponent(component)
                                } label: {
                                    Text(LocalizedStringKey(component.titleKey))
                                        .font(.caption.weight(viewModel.damageState.selectedComponent == component ? .bold : .regular))
                                        .foregroundStyle(GroundControlPalette.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Text("\(Int(viewModel.damageState.health(for: component) * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(componentHealthTint(component))

                                Toggle("", isOn: Binding(
                                    get: { viewModel.damageState.hiddenComponents.contains(component) },
                                    set: { viewModel.setComponentHidden(component, hidden: $0) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(GroundControlPalette.inset)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(
                                        viewModel.damageState.selectedComponent == component ? GroundControlPalette.accent.opacity(0.55) : GroundControlPalette.border,
                                        lineWidth: 1
                                    )
                            )
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "module.diagnostics.station",
                subtitleKey: "module.diagnostics.station.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("language.section", selection: $appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.titleKey)).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private func componentHealthTint(_ component: DamageComponent) -> Color {
        let health = viewModel.damageState.health(for: component)
        if health <= 0.4 {
            return GroundControlPalette.danger
        }
        if health <= 0.7 {
            return GroundControlPalette.warning
        }
        return GroundControlPalette.success
    }
}

private struct BlackBoxReplaySection: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        ModuleSection(
            titleKey: "module.diagnostics.blackbox",
            subtitleKey: "module.diagnostics.blackbox.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.isMissionReplayRecording
                              ? GroundControlPalette.danger
                              : GroundControlPalette.textSecondary)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isMissionReplayRecording ? "Recording: ON" : "Recording: OFF")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(viewModel.isMissionReplayRecording
                                         ? GroundControlPalette.danger
                                         : GroundControlPalette.textSecondary)
                    Spacer()
                    Text("Session source: ARM → DISARM")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                if let report = viewModel.lastMissionReport {
                    BlackBoxReportView(report: report)
                } else {
                    Text("No black box replay recorded yet.")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
        }
    }
}

private struct BlackBoxReportView: View {
    let report: MissionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ModuleMetricGrid {
                ModuleMetricCell(
                    labelKey: "blackbox.duration",
                    value: String(format: "%.1f s", report.summary.durationSeconds)
                )
                ModuleMetricCell(
                    labelKey: "blackbox.frames",
                    value: "\(report.summary.frameCount)"
                )
                ModuleMetricCell(
                    labelKey: "blackbox.events",
                    value: "\(report.summary.eventCount)"
                )
                ModuleMetricCell(
                    labelKey: "blackbox.warnings",
                    value: "\(report.summary.warningCount)"
                )
                ModuleMetricCell(
                    labelKey: "blackbox.max_speed",
                    value: String(format: "%.1f m/s", report.summary.maxSpeedMetersPerSecond)
                )
                ModuleMetricCell(
                    labelKey: "blackbox.avg_speed",
                    value: String(format: "%.1f m/s", report.summary.averageSpeedMetersPerSecond)
                )
                ModuleMetricCell(
                    labelKey: "blackbox.max_alt",
                    value: String(format: "%.1f m", report.summary.maxAltitudeMeters)
                )
                ModuleMetricCell(
                    labelKey: "blackbox.battery_used",
                    value: report.summary.batteryUsedPercent.map { String(format: "%.1f %%", $0) } ?? "n/a"
                )
            }

            ScrollView(.vertical, showsIndicators: true) {
                Text(report.textSummary)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
        }
    }
}

private enum DiagnosticsDetailPanel: String, CaseIterable, Identifiable {
    case overview
    case telemetry
    case fleet
    case service

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .overview:
            return "module.diagnostics.panel.overview"
        case .telemetry:
            return "module.diagnostics.panel.telemetry"
        case .fleet:
            return "module.diagnostics.panel.fleet"
        case .service:
            return "module.diagnostics.panel.service"
        }
    }
}

private struct DiagnosticsDetailScrollView<Content: View>: View {
    let resetToken: String
    @ViewBuilder let content: Content
    private let topAnchorID = "diagnostics.detail.top"

    init(resetToken: String, @ViewBuilder content: () -> Content) {
        self.resetToken = resetToken
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                Color.clear
                    .frame(height: 1)
                    .id(topAnchorID)

                VStack(alignment: .leading, spacing: 8) {
                    content
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .id(resetToken)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                scrollToTop(using: proxy)
            }
        }
    }

    private func scrollToTop(using proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(topAnchorID, anchor: .top)
        }
    }
}

private struct DiagnosticsPinnedHeaderView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("module.diagnostics.title")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("module.diagnostics.subtitle")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 8)

                StatusBadge(
                    titleKey: viewModel.telemetry.armStateKey,
                    tint: viewModel.isArmed ? GroundControlPalette.success : GroundControlPalette.warning
                )
            }

            LazyVGrid(columns: columns, spacing: 6) {
                DiagnosticsSummaryTile(
                    labelKey: "sidebar.metric.mode",
                    value: localized(viewModel.telemetry.modeKey)
                )
                DiagnosticsSummaryTile(
                    labelKey: "sidebar.metric.state",
                    value: localized(viewModel.telemetry.flightStateKey)
                )
                DiagnosticsSummaryTile(
                    labelKey: "sidebar.metric.platform",
                    value: viewModel.selectedDroneProfile.uiDisplayName
                )
                DiagnosticsSummaryTile(
                    labelKey: "sidebar.metric.battery",
                    value: String(format: "%.0f %%", viewModel.telemetry.batteryPercent)
                )
                DiagnosticsSummaryTile(
                    labelKey: "diagnostic.active_objects",
                    value: "\(viewModel.diagnostics.activeObjectCount)"
                )
            }

            if let warningKey = viewModel.warnings.first {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(GroundControlPalette.warning)
                    Text(LocalizedStringKey(warningKey))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(GroundControlPalette.warning.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(GroundControlPalette.warning.opacity(0.28), lineWidth: 1)
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

private struct DiagnosticsPanelSelectorView: View {
    @Binding var activePanel: DiagnosticsDetailPanel

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(DiagnosticsDetailPanel.allCases) { panel in
                Button {
                    activePanel = panel
                } label: {
                    Text(LocalizedStringKey(panel.titleKey))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .foregroundStyle(activePanel == panel ? Color.white : GroundControlPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(activePanel == panel ? GroundControlPalette.accent : GroundControlPalette.panelRaised)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(activePanel == panel ? GroundControlPalette.accent.opacity(0.8) : GroundControlPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DiagnosticsSummaryTile: View {
    let labelKey: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(labelKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(GroundControlPalette.inset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }
}

private struct DiagnosticsOverlayModeStrip: View {
    let activeMode: DiagnosticOverlayMode
    let onSelect: (DiagnosticOverlayMode) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(DiagnosticOverlayMode.allCases) { mode in
                Button {
                    onSelect(mode)
                } label: {
                    Text(LocalizedStringKey(mode.titleKey))
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(activeMode == mode ? Color.white : GroundControlPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(activeMode == mode ? GroundControlPalette.accent : GroundControlPalette.inset)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(activeMode == mode ? GroundControlPalette.accent.opacity(0.8) : GroundControlPalette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
