import SwiftUI

struct OnlineTrialRuntimeOverlay: View {
    let context: OnlineTrialRuntimeContext?
    let fleetState: OnlineTrialFleetState?
    let remoteStates: [OnlineVehicleInterpolatedState]
    let snapshotTargetHz: Int
    var isExpanded: Bool = false
    var trialPhase: LANTrialPhase = .running
    var participantCount: Int = 1
    var staleCount: Int = 0
    var damageState: OnlineVehicleDamageState = OnlineVehicleDamageState()
    var recentSharedEvents: [OnlineSharedEvent] = []
    var diagnostics: OnlineRuntimeNetworkDiagnostics = OnlineRuntimeNetworkDiagnostics()
    var onEndTrial: (() -> Void)? = nil
    var onLeaveTrial: (() -> Void)? = nil

    private var roleLabel: String {
        guard let context else { return "—" }
        if context.isHost && context.isSpectator { return L10n.s("online.runtime.role.host_admin") }
        if context.isHost { return L10n.s("online.runtime.role.host_pilot") }
        if context.isSpectator { return L10n.s("online.runtime.role.spectator") }
        return L10n.s("online.runtime.role.pilot")
    }

    private var roleIsHost: Bool { context?.isHost == true }
    private var vehicleIDText: String { shortID(context?.localVehicleID) }
    private var vehicleCount: Int { fleetState?.vehicles.count ?? 0 }
    private var remoteCount: Int { remoteStates.count }

    private var lastSharedEvent: OnlineSharedEvent? { recentSharedEvents.last }

    private var localVehicleDamageRecord: OnlineVehicleDamageRecord? {
        guard let vid = context?.localVehicleID else { return nil }
        return damageState.record(for: vid)
    }

    private var localVehicleIsAffected: Bool {
        guard let vid = context?.localVehicleID else { return false }
        return damageState.isControlDisabled(vehicleID: vid)
    }

    private var localAuthorityText: String {
        guard let ctx = context else { return "—" }
        if ctx.isSpectator { return "none" }
        guard let vid = ctx.localVehicleID else { return "none" }
        return "UAV \(String(vid.uuidString.prefix(8)))"
    }

    private var statusLabel: String {
        switch trialPhase {
        case .lobby:     return L10n.s("online.runtime.status.lobby")
        case .launching: return L10n.s("online.runtime.status.launching")
        case .running:   return staleCount > 0 ? L10n.s("online.runtime.status.degraded") : L10n.s("online.runtime.status.running")
        case .ended:     return L10n.s("online.runtime.status.ended")
        }
    }

    private var statusColor: Color {
        switch trialPhase {
        case .lobby, .launching: return GroundControlPalette.warning
        case .running:           return staleCount > 0 ? GroundControlPalette.warning : GroundControlPalette.success
        case .ended:             return GroundControlPalette.textSecondary
        }
    }

    var body: some View {
        if isExpanded {
            expandedPanel
        }
    }

    // MARK: – Expanded panel

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            separator

            authoritySection
            separator

            infoRow(L10n.s("online.runtime.participants"), "\(participantCount)")
            infoRow(L10n.s("online.runtime.vehicles"), "\(vehicleCount)")
            if staleCount > 0 {
                infoRow(L10n.s("online.runtime.stale"), "\(staleCount)", valueColor: GroundControlPalette.warning)
            }
            infoRow(L10n.s("online.runtime.snapshot"), "\(snapshotTargetHz) Hz")
            separator

            statusSection
            separator

            collisionEventSection

            diagnosticsSection

            actionButtons
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 230, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.76))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text("online.runtime.title")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(GroundControlPalette.warning)
                .tracking(1)

            Spacer()

            Text(statusLabel)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(statusColor.opacity(0.55), lineWidth: 1)
                )

            Text(roleLabel)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(roleIsHost ? Color.black : GroundControlPalette.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(roleIsHost ? GroundControlPalette.warning : GroundControlPalette.accent.opacity(0.28))
                )
        }
    }

    @ViewBuilder
    private var authoritySection: some View {
        infoRow(L10n.s("online.runtime.authority"), L10n.s("online.runtime.authority.distributed_object"))
        if let ctx = context {
            let localColor: Color = ctx.isSpectator ? GroundControlPalette.textSecondary : GroundControlPalette.textPrimary
            infoRow(L10n.s("online.runtime.local_authority"), localAuthorityText, valueColor: localColor)
            if ctx.isWorldAuthorityHost {
                infoRow(L10n.s("online.runtime.world_authority"), L10n.s("online.runtime.world_authority.host_local"), valueColor: GroundControlPalette.success)
            }
        }
        infoRow(L10n.s("online.runtime.participant_label"), context?.localParticipant.displayName ?? "—")
        infoRow(L10n.s("online.runtime.replicas"), "\(remoteCount)")
    }

    private var separator: some View {
        Rectangle()
            .fill(GroundControlPalette.borderStrong)
            .frame(height: 1)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let ctx = context {
            if trialPhase == .ended {
                statusLine(L10n.s("online.runtime.trial_ended"))
            } else if ctx.isSpectator && ctx.isHost {
                statusLine(L10n.s("online.runtime.host_admin.no_uav"))
            } else if ctx.isSpectator {
                statusLine(L10n.s("online.runtime.spectator.receive_only"))
                if remoteStates.isEmpty {
                    if participantCount < 2 {
                        statusLine(L10n.s("online.runtime.waiting_second_participant"))
                    } else {
                        statusLine(L10n.s("online.runtime.spectator.no_snapshot"))
                    }
                } else {
                    statusLine(L10n.f("online.runtime.spectator_replicas.count", remoteCount))
                }
            } else {
                if remoteStates.isEmpty {
                    if participantCount < 2 {
                        statusLine(L10n.s("online.runtime.waiting_second_participant"))
                    } else {
                        statusLine(L10n.s("online.runtime.connected.waiting_snapshot"))
                    }
                } else {
                    statusLine(L10n.f("online.runtime.remote_replicas.count", remoteCount))
                }
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        let hasData = diagnostics.outgoingSnapshotCount > 0
            || diagnostics.incomingSnapshotCount > 0
            || diagnostics.lastPingRoundtripMs != nil
            || diagnostics.renderFPS > 0
        if hasData {
            VStack(alignment: .leading, spacing: 4) {
                // Network counters
                Text("NET")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .tracking(0.8)

                HStack(spacing: 6) {
                    diagCell("TX", "\(diagnostics.outgoingSnapshotCount)")
                    diagCell("RX", "\(diagnostics.incomingSnapshotCount)")
                    diagCell("REPS", "\(diagnostics.remoteReplicaVisibleCount)")
                    if diagnostics.remoteReplicaStaleCount > 0 {
                        diagCell("STALE", "\(diagnostics.remoteReplicaStaleCount)", color: GroundControlPalette.warning)
                    }
                    diagCell("EVT", "\(diagnostics.sharedEventReceivedCount)")
                    diagCell("PING", diagnostics.pingLabel)
                }

                // Performance section
                Text("PERF")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .tracking(0.8)
                    .padding(.top, 2)

                HStack(spacing: 6) {
                    if diagnostics.renderFPS > 0 {
                        let fpsColor: Color = diagnostics.renderFPS < 20 ? GroundControlPalette.warning : GroundControlPalette.textPrimary
                        diagCell("FPS", String(format: "%.0f", diagnostics.renderFPS), color: fpsColor)
                    }
                    if diagnostics.outgoingSnapshotHz > 0 {
                        diagCell("TX Hz", String(format: "%.0f", diagnostics.outgoingSnapshotHz))
                    }
                    if diagnostics.incomingSnapshotHz > 0 {
                        diagCell("RX Hz", String(format: "%.0f", diagnostics.incomingSnapshotHz))
                    }
                    if diagnostics.sceneApplyHz > 0 {
                        diagCell("Apply", String(format: "%.0f", diagnostics.sceneApplyHz))
                    }
                }

                if remoteCount > 0 {
                    HStack(spacing: 6) {
                        if let lagMs = diagnostics.remoteVisualLagMs, lagMs >= 0, lagMs < 10_000 {
                            let lagColor: Color = lagMs > 1500 ? Color(red: 1.0, green: 0.25, blue: 0.25)
                                : lagMs > 500 ? GroundControlPalette.warning
                                : GroundControlPalette.success
                            diagCell("LAG", String(format: "%.0f ms", lagMs), color: lagColor)
                        }
                        if let recvAgo = diagnostics.lastSnapshotReceivedAgoMs {
                            let recvColor: Color = recvAgo > 500 ? GroundControlPalette.warning : GroundControlPalette.textPrimary
                            diagCell("RECV", String(format: "%.0f ms", recvAgo), color: recvColor)
                        }
                        diagCell("BUF", "\(diagnostics.remoteSnapshotBufferDepthMax)")
                        if diagnostics.remoteOutOfOrderDropCount > 0 {
                            diagCell("OOO", "\(diagnostics.remoteOutOfOrderDropCount)", color: GroundControlPalette.warning)
                        }
                    }
                }

                HStack(spacing: 6) {
                    // ACT = RuntimeActivityState; VIS = window visibility (active/inactive/minimized/hidden)
                    diagCell("ACT", diagnostics.visibilityStateLabel)
                    diagCell("VIS", diagnostics.windowVisibilityLabel)
                    diagCell("ScFPS", "\(diagnostics.scenePreferredFPS)")
                    if !diagnostics.sceneIsPlaying {
                        diagCell("PLAY", "off", color: GroundControlPalette.warning)
                    }
                }
            }
            separator
        }
    }

    private func diagCell(_ label: String, _ value: String, color: Color = GroundControlPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if context?.isHost == true, trialPhase == .running, let onEndTrial {
            overlayButton(L10n.s("online.runtime.end_trial"), systemImage: "stop.circle", isDestructive: true, action: onEndTrial)
        }
        if let onLeaveTrial {
            overlayButton(L10n.s("online.runtime.leave"), systemImage: "arrow.left", isDestructive: false, action: onLeaveTrial)
        }
    }

    private var localDamageLabel: String {
        switch localVehicleDamageRecord?.operationalState {
        case .disabled: return L10n.s("online.runtime.local_uav_disabled")
        case .crashed:  return L10n.s("online.runtime.local_uav_crashed")
        default:        return L10n.s("online.runtime.local_uav_damaged")
        }
    }

    @ViewBuilder
    private var collisionEventSection: some View {
        if localVehicleIsAffected {
            Text(localDamageLabel)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.25, blue: 0.25))
                .padding(.vertical, 2)
            separator
        }

        if let event = lastSharedEvent {
            VStack(alignment: .leading, spacing: 2) {
                Text("online.runtime.events")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                HStack(spacing: 4) {
                    Text(event.kind.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.warning)
                    Text("→")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Text(event.result.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(sharedEventResultColor(event.result))
                }
                Text(event.participants.map(\.displayName).joined(separator: " × "))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(1)
            }
            separator
        }
    }

    private func sharedEventResultColor(_ result: OnlineSharedEventResult) -> Color {
        switch result {
        case .none, .ignored, .completed: return GroundControlPalette.textSecondary
        case .damaged:                    return GroundControlPalette.warning
        case .disabled:                   return Color(red: 1.0, green: 0.55, blue: 0.2)
        case .crashed, .failed:           return Color(red: 1.0, green: 0.25, blue: 0.25)
        }
    }

    private func overlayButton(
        _ title: String,
        systemImage: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Spacer()
            }
            .foregroundStyle(isDestructive ? Color(red: 1.0, green: 0.55, blue: 0.42) : .white.opacity(0.82))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isDestructive ? 0.055 : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(isDestructive ? 0.20 : 0.16), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = GroundControlPalette.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .frame(width: 68, alignment: .leading)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(valueColor)
                .lineLimit(1)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .lineLimit(1)
    }

    private func shortID(_ id: UUID?) -> String {
        guard let id else { return "нет UAV" }
        return String(id.uuidString.prefix(8))
    }
}
