import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsModuleView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    @Binding var appLanguage: AppLanguage
    @State private var activePanel: DiagnosticsDetailPanel = .overview
    @State private var rfExportStatusKey: String?

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
        case .radio:
            rfPanel
        case .aerodynamics:
            AeroDiagnosticsPanelView(
                profile: viewModel.selectedDroneProfile,
                liveMach: Float(viewModel.telemetry.machNumber),
                liveAlphaRad: Float(viewModel.telemetry.angleOfAttackRad)
            )
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

                ModuleMetricGrid {
                    ModuleMetricCell(
                        labelKey: "telemetry.battery_voltage",
                        value: String(format: "%.1fV", viewModel.batteryState.packVoltage)
                    )
                    ModuleMetricCell(
                        labelKey: "telemetry.cell_voltage",
                        value: String(format: "%.2fV/S", viewModel.batteryState.cellVoltage)
                    )
                    ModuleMetricCell(
                        labelKey: "telemetry.current_draw",
                        value: String(format: "%.1fA", viewModel.batteryState.currentDrawA)
                    )
                    ModuleMetricCell(
                        labelKey: "telemetry.mah_drawn",
                        value: String(format: "%.0f mAh", viewModel.batteryState.mahDrawn)
                    )
                }

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

    private var rfPanel: some View {
        Group {
            ModuleSection(
                titleKey: "module.diagnostics.rf",
                subtitleKey: "module.diagnostics.rf.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("diagnostic.rf.physical_authoritative_hint")
                        .font(.caption2)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ModuleMetricGrid {
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.rollout",
                            value: "PHYSICAL RF CORE",
                            tint: GroundControlPalette.success
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.configuration_origin",
                            value: viewModel.activeRFConfigurationOrigin.rawValue
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.configuration_version",
                            value: "v\(viewModel.activeRFConfigurationVersion)"
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.physical_state",
                            value: viewModel.rfControlAvailability.rawValue.uppercased(),
                            tint: rfAvailabilityTint(viewModel.rfControlAvailability)
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.command_age",
                            value: String(format: "%.3f s", viewModel.rfControlCommandAgeSeconds)
                        )
                    }

                    if viewModel.rfConfigurationIssues.isEmpty {
                        Text("diagnostic.rf.configuration_valid")
                            .font(.caption)
                            .foregroundStyle(GroundControlPalette.success)
                    } else {
                        ForEach(Array(viewModel.rfConfigurationIssues.enumerated()), id: \.offset) { _, issue in
                            Text("\(issue.code): \(issue.detail)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(issue.severity == .error
                                    ? GroundControlPalette.danger
                                    : GroundControlPalette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            ModuleSection(
                titleKey: "diagnostic.rf.baseline",
                subtitleKey: "diagnostic.rf.baseline.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ModuleMetricGrid {
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.environment",
                            value: viewModel.rfEnvironmentContext.scene.rawValue
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.weather",
                            value: viewModel.rfEnvironmentContext.weather.rawValue
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.environment_density",
                            value: String(format: "%.0f %%", viewModel.rfEnvironmentContext.density * 100)
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.seed",
                            value: "\(viewModel.rfEnvironmentContext.deterministicSeed)"
                        )
                    }

                    HStack(spacing: 8) {
                        OperationalActionButton(
                            titleKey: "diagnostic.rf.export_baseline",
                            systemImage: "square.and.arrow.up"
                        ) {
                            exportRFCalibrationBaseline()
                        }
                        .disabled(viewModel.rfCalibrationBuckets.isEmpty)

                        OperationalActionButton(
                            titleKey: "diagnostic.rf.reset_baseline",
                            systemImage: "arrow.counterclockwise",
                            tint: GroundControlPalette.warning
                        ) {
                            viewModel.resetRFCalibrationBaseline()
                            rfExportStatusKey = nil
                        }
                        .disabled(viewModel.rfCalibrationBuckets.isEmpty)
                    }

                    if let rfExportStatusKey {
                        Text(LocalizedStringKey(rfExportStatusKey))
                            .font(.caption2)
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }

                    ForEach(viewModel.rfCalibrationBuckets) { bucket in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                "\(bucket.key.scene.rawValue) · "
                                    + "\(bucket.key.weather.rawValue) · #\(bucket.key.deterministicSeed)"
                            )
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(GroundControlPalette.textPrimary)
                            ModuleMetricGrid {
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.baseline_samples",
                                    value: "\(bucket.sampleCount)"
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.mean_rssi",
                                    value: String(format: "%.1f dBm", bucket.meanRSSIDBm)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.rssi_sigma",
                                    value: String(format: "%.2f dB", bucket.rssiStandardDeviationDB)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.mean_margin",
                                    value: String(format: "%.1f dB", bucket.meanMarginDB)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.mean_per",
                                    value: String(format: "%.2f %%", bucket.meanPacketErrorRate * 100)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.nlos_ratio",
                                    value: String(format: "%.1f %%", bucket.nlosRatio * 100)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.bucket_agreement",
                                    value: String(format: "%.1f %%", bucket.stateAgreementRatio * 100)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.mean_command_age",
                                    value: String(format: "%.3f s", bucket.meanCommandAgeSeconds)
                                )
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(GroundControlPalette.inset)
                        )
                    }
                }
            }

            ModuleSection(
                titleKey: "diagnostic.rf.acceptance",
                subtitleKey: "diagnostic.rf.acceptance.subtitle"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    OperationalActionButton(
                        titleKey: "diagnostic.rf.run_acceptance",
                        systemImage: "checkmark.seal"
                    ) {
                        viewModel.runRFAcceptanceSuite()
                    }
                    .disabled(!viewModel.canRunRFAcceptanceSuite)

                    ForEach(viewModel.rfAcceptanceResults) { result in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(result.scenarioID)
                                    .font(.caption.monospaced().weight(.bold))
                                Spacer()
                                Text(result.passed ? "PASS" : "FAIL")
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(result.passed
                                        ? GroundControlPalette.success
                                        : GroundControlPalette.danger)
                            }
                            ModuleMetricGrid {
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.packet_delivery",
                                    value: String(format: "%.2f %%", result.deliveryRatio * 100)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.max_command_age",
                                    value: String(format: "%.3f s", result.maximumCommandAgeSeconds)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.min_margin",
                                    value: String(format: "%.1f dB", result.minimumLinkMarginDB)
                                )
                                ModuleMetricCell(
                                    labelKey: "diagnostic.rf.retry_recovered",
                                    value: "\(result.retryRecoveredPackets)"
                                )
                            }
                            if !result.failureCodes.isEmpty {
                                Text(result.failureCodes.joined(separator: ", "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(GroundControlPalette.danger)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(GroundControlPalette.inset)
                        )
                    }

                    if !viewModel.rfPerformanceResults.isEmpty {
                        Text("diagnostic.rf.performance_gate")
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)

                        ForEach(viewModel.rfPerformanceResults) { result in
                            HStack(spacing: 8) {
                                Text("\(result.activeEndpointCount) UAV")
                                    .font(.caption.monospaced().weight(.bold))
                                Text("\(result.evaluatedLinkCount) LINKS")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(GroundControlPalette.textSecondary)
                                Spacer()
                                Text(String(
                                    format: "%.2f / %.2f ms",
                                    result.elapsedMilliseconds,
                                    result.budgetMilliseconds
                                ))
                                .font(.caption2.monospaced())
                                Text(result.passed ? "PASS" : "FAIL")
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(result.passed
                                        ? GroundControlPalette.success
                                        : GroundControlPalette.danger)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(GroundControlPalette.inset)
                            )
                        }
                    }
                }
            }

            if !viewModel.rfSharedChannelStatistics.isEmpty {
                ModuleSection(
                    titleKey: "diagnostic.rf.shared_channels",
                    subtitleKey: "diagnostic.rf.shared_channels.subtitle"
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.rfSharedChannelStatistics) { channel in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(channel.transmitterDeviceID)
                                    .font(.caption.monospaced().weight(.bold))
                                    .foregroundStyle(GroundControlPalette.textPrimary)
                                ModuleMetricGrid {
                                    ModuleMetricCell(
                                        labelKey: "diagnostic.rf.channel_capacity",
                                        value: String(format: "%.1f kbit/s", channel.capacityBPS / 1_000)
                                    )
                                    ModuleMetricCell(
                                        labelKey: "diagnostic.rf.channel_utilization",
                                        value: String(format: "%.1f %%", channel.utilizationRatio * 100)
                                    )
                                    ModuleMetricCell(
                                        labelKey: "diagnostic.rf.qos_state",
                                        value: channel.dynamicControlBoostActive
                                            ? L10n.s("diagnostic.rf.qos_boost_active")
                                            : L10n.s("diagnostic.rf.qos_nominal")
                                    )
                                    ModuleMetricCell(
                                        labelKey: "diagnostic.rf.borrowing",
                                        value: channel.reservationBorrowingEnabled
                                            ? L10n.s("diagnostic.rf.enabled")
                                            : L10n.s("diagnostic.rf.disabled")
                                    )
                                    ModuleMetricCell(
                                        labelKey: "diagnostic.rf.backpressure",
                                        value: channel.backpressuredLinks.isEmpty
                                            ? "—"
                                            : channel.backpressuredLinks
                                                .map(\.rawValue)
                                                .sorted()
                                                .joined(separator: ", ")
                                    )
                                }
                                ForEach(LogicalLinkKind.allCases, id: \.self) { kind in
                                    if let allocated = channel.allocatedBitrateBPS[kind] {
                                        HStack {
                                            Text(kind.rawValue.uppercased())
                                            Spacer()
                                            VStack(alignment: .trailing, spacing: 1) {
                                                Text(String(format: "%.1f kbit/s", allocated / 1_000))
                                                Text(String(
                                                    format: "RES %.1f · BORROW %.1f",
                                                    (channel.reservedBitrateBPS[kind] ?? 0) / 1_000,
                                                    (channel.borrowedBitrateBPS[kind] ?? 0) / 1_000
                                                ))
                                                .foregroundStyle(GroundControlPalette.textSecondary)
                                            }
                                        }
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(channel.backpressuredLinks.contains(kind)
                                            ? GroundControlPalette.warning
                                            : GroundControlPalette.textSecondary)
                                    }
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(GroundControlPalette.inset)
                            )
                        }
                    }
                }
            }

            ForEach(LogicalLinkKind.allCases, id: \.self) { kind in
                if let evaluation = viewModel.rfLinkEvaluations[kind] {
                    RFLinkBudgetCard(
                        kind: kind,
                        evaluation: evaluation,
                        delivery: viewModel.rfPacketDeliveryStates[kind],
                        videoPresentation: kind == .video
                            ? viewModel.rfVideoPresentationState
                            : nil
                    )
                }
            }

            if viewModel.rfLinkEvaluations.isEmpty {
                ModuleSection(titleKey: "diagnostic.rf.links") {
                    Text("diagnostic.rf.no_data")
                        .font(.caption)
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
            }
        }
    }

    private func rfAvailabilityTint(_ availability: RFControlLinkAvailability) -> Color {
        switch availability {
        case .nominal: return GroundControlPalette.success
        case .warning: return GroundControlPalette.warning
        case .critical, .lost: return GroundControlPalette.danger
        }
    }

    private func exportRFCalibrationBaseline() {
        guard let data = viewModel.makeRFCalibrationReportData() else {
            rfExportStatusKey = "diagnostic.rf.export_failed"
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "uavsim-rf-shadow-baseline.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            rfExportStatusKey = "diagnostic.rf.export_complete"
        } catch {
            rfExportStatusKey = "diagnostic.rf.export_failed"
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

            if let rf = report.summary.rf {
                ModuleMetricGrid {
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.min_rssi",
                        value: rf.minimumRSSIDBm.map { String(format: "%.1f dBm", $0) } ?? "n/a"
                    )
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.min_sinr",
                        value: rf.minimumSINRDB.map { String(format: "%.1f dB", $0) } ?? "n/a"
                    )
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.max_age",
                        value: String(format: "%.3f s", rf.maximumCommandAgeSeconds)
                    )
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.delivery",
                        value: rf.averageDeliveryRatio.map {
                            String(format: "%.2f %%", $0 * 100)
                        } ?? "n/a"
                    )
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.retries",
                        value: "\(rf.retryAttempts)"
                    )
                    ModuleMetricCell(
                        labelKey: "blackbox.rf.backpressure",
                        value: "\(rf.backpressureSampleCount)"
                    )
                    if let bucketCount = rf.baselineBucketCount {
                        ModuleMetricCell(
                            labelKey: "blackbox.rf.baseline_buckets",
                            value: "\(bucketCount)"
                        )
                    }
                    if let scenarioCount = rf.acceptanceScenarioCount,
                       let passedCount = rf.acceptancePassedCount {
                        ModuleMetricCell(
                            labelKey: "blackbox.rf.acceptance",
                            value: "\(passedCount)/\(scenarioCount)"
                        )
                    }
                    if let policyCount = rf.qosPolicyCount {
                        ModuleMetricCell(
                            labelKey: "blackbox.rf.qos_policies",
                            value: "\(policyCount)"
                        )
                    }
                    if let gateCount = rf.performanceGateCount,
                       let passedCount = rf.performanceGatePassedCount {
                        ModuleMetricCell(
                            labelKey: "blackbox.rf.performance_gates",
                            value: "\(passedCount)/\(gateCount)"
                        )
                    }
                }
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

private struct RFLinkBudgetCard: View {
    let kind: LogicalLinkKind
    let evaluation: RFLinkEvaluation
    let delivery: RFPacketDeliveryState?
    let videoPresentation: RFVideoPresentationState?

    private var rf: RFLinkState { evaluation.rf }

    var body: some View {
        ModuleSection(
            titleKey: "RF \(kind.rawValue.uppercased())",
            subtitleKey: "diagnostic.rf.link.subtitle"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    StatusBadge(
                        titleKey: evaluation.quality.health.rawValue.uppercased(),
                        tint: healthTint
                    )
                    Spacer()
                    Text(rf.hasLineOfSight ? "LOS" : "NLOS")
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(rf.hasLineOfSight
                            ? GroundControlPalette.success
                            : GroundControlPalette.warning)
                }

                ModuleMetricGrid {
                    metric("diagnostic.rf.rssi", rf.receivedPowerDBm, "dBm")
                    metric("diagnostic.rf.sinr", rf.sinrDB, "dB")
                    metric("diagnostic.rf.margin", rf.linkMarginDB, "dB")
                    metric("diagnostic.rf.distance", rf.distanceM, "m", decimals: 1)
                    metric("diagnostic.rf.fspl", rf.freeSpaceLossDB, "dB")
                    metric("diagnostic.rf.antenna_gain", rf.txGainDBi + rf.rxGainDBi, "dBi")
                    metric("diagnostic.rf.material_loss", rf.materialLossDB, "dB")
                    metric("diagnostic.rf.clutter_loss", rf.clutterLossDB, "dB")
                    metric("diagnostic.rf.body_loss", rf.bodyShadowLossDB, "dB")
                    metric("diagnostic.rf.polarization_loss", rf.polarizationLossDB, "dB")
                    metric("diagnostic.rf.cable_loss", rf.cableLossDB, "dB")
                    metric("diagnostic.rf.atmospheric_loss", rf.atmosphericLossDB, "dB", decimals: 3)
                    metric("diagnostic.rf.weather_loss", rf.weatherLossDB, "dB", decimals: 3)
                    metric("diagnostic.rf.fading", rf.fadingAdjustmentDB, "dB")
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.interference",
                        value: rf.interferenceDBm.map { String(format: "%.1f dBm", $0) } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.per",
                        value: String(format: "%.2f %%", evaluation.quality.packetErrorRate * 100)
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.packet_delivery",
                        value: delivery.map { String(format: "%.2f %%", $0.deliveryRatio * 100) } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.packet_age",
                        value: delivery.map { String(format: "%.3f s", $0.secondsSinceLastDelivery) } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.mcs",
                        value: delivery?.selectedMCS.rawValue ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.queue",
                        value: delivery.map { "\($0.queueDepth) / \($0.queueCapacity)" } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.throughput",
                        value: delivery.map {
                            String(format: "%.1f kbit/s", $0.effectiveThroughputBPS / 1_000)
                        } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.retries",
                        value: delivery.map { "\($0.retryAttempts)" } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.retry_recovered",
                        value: delivery.map { "\($0.packetsRecoveredByRetry)" } ?? "—"
                    )
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.expired",
                        value: delivery.map { "\($0.packetsExpired)" } ?? "—"
                    )
                    if let videoPresentation {
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.video_mode",
                            value: videoPresentation.mode.rawValue.uppercased()
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.video_state",
                            value: videoPresentation.isFrozen ? "FROZEN" : "LIVE"
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.video_degradation",
                            value: String(
                                format: "%.1f %%",
                                (videoPresentation.mode == .analog
                                    ? videoPresentation.analogNoiseIntensity
                                    : videoPresentation.digitalArtifactIntensity) * 100
                            )
                        )
                        ModuleMetricCell(
                            labelKey: "diagnostic.rf.video_bitrate",
                            value: String(
                                format: "%.1f kbit/s",
                                videoPresentation.effectiveBitrateBPS / 1_000
                            )
                        )
                    }
                    ModuleMetricCell(
                        labelKey: "diagnostic.rf.queue_delay",
                        value: delivery.map {
                            String(format: "%.3f s", $0.meanQueueDelaySeconds)
                        } ?? "—"
                    )
                }
            }
        }
    }

    private var healthTint: Color {
        switch evaluation.quality.health {
        case .healthy: return GroundControlPalette.success
        case .degraded: return GroundControlPalette.warning
        case .critical, .lost: return GroundControlPalette.danger
        }
    }

    private func metric(
        _ labelKey: String,
        _ value: Double,
        _ unit: String,
        decimals: Int = 1
    ) -> ModuleMetricCell {
        ModuleMetricCell(
            labelKey: labelKey,
            value: String(format: "%.*f %@", decimals, value, unit)
        )
    }
}

private enum DiagnosticsDetailPanel: String, CaseIterable, Identifiable {
    case overview
    case telemetry
    case radio
    case aerodynamics
    case fleet
    case service

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .overview:
            return "module.diagnostics.panel.overview"
        case .telemetry:
            return "module.diagnostics.panel.telemetry"
        case .radio:
            return "module.diagnostics.panel.rf"
        case .aerodynamics:
            return "module.diagnostics.panel.aero"
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
