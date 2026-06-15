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
    var recentCollisionEvents: [OnlineCollisionEvent] = []
    var onEndTrial: (() -> Void)? = nil
    var onLeaveTrial: (() -> Void)? = nil

    private var roleLabel: String {
        guard let context else { return "—" }
        if context.isHost && context.isSpectator { return "HOST ADMIN" }
        if context.isHost { return "HOST / PILOT" }
        if context.isSpectator { return "SPECTATOR" }
        return "PILOT"
    }

    private var roleIsHost: Bool { context?.isHost == true }
    private var vehicleIDText: String { shortID(context?.localVehicleID) }
    private var vehicleCount: Int { fleetState?.vehicles.count ?? 0 }
    private var remoteCount: Int { remoteStates.count }

    private var lastCollisionEvent: OnlineCollisionEvent? { recentCollisionEvents.last }

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
        case .lobby:     return "LOBBY"
        case .launching: return "LAUNCHING"
        case .running:   return staleCount > 0 ? "DEGRADED" : "RUNNING"
        case .ended:     return "ENDED"
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

            infoRow("Participants", "\(participantCount)")
            infoRow("Vehicles", "\(vehicleCount)")
            if staleCount > 0 {
                infoRow("Stale", "\(staleCount)", valueColor: GroundControlPalette.warning)
            }
            infoRow("Snapshot", "\(snapshotTargetHz) Hz")
            separator

            statusSection
            separator

            collisionEventSection

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
            Text("LAN TRIAL")
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
        infoRow("Authority", "Distributed Object")
        if let ctx = context {
            let localColor: Color = ctx.isSpectator ? GroundControlPalette.textSecondary : GroundControlPalette.textPrimary
            infoRow("Local auth", localAuthorityText, valueColor: localColor)
            if ctx.isWorldAuthorityHost {
                infoRow("World auth", "host (local)", valueColor: GroundControlPalette.success)
            }
        }
        infoRow("Участник", context?.localParticipant.displayName ?? "—")
        infoRow("Replicas", "\(remoteCount)")
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
                statusLine("Испытание завершено")
            } else if ctx.isSpectator && ctx.isHost {
                statusLine("HOST ADMIN · без UAV")
            } else if ctx.isSpectator {
                statusLine("Receive-only spectator")
                if remoteStates.isEmpty {
                    statusLine("Ожидание pilot snapshots...")
                } else {
                    statusLine("Наблюдение: \(remoteCount) ghost(s)")
                }
            } else {
                if remoteStates.isEmpty {
                    statusLine("Ожидание других участников...")
                } else {
                    statusLine("Remote: \(remoteCount) ghost(s)")
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if context?.isHost == true, trialPhase == .running, let onEndTrial {
            overlayButton("Завершить испытание", systemImage: "stop.circle", isDestructive: true, action: onEndTrial)
        }
        if let onLeaveTrial {
            overlayButton("Выйти", systemImage: "arrow.left", isDestructive: false, action: onLeaveTrial)
        }
    }

    private var localDamageLabel: String {
        switch localVehicleDamageRecord?.operationalState {
        case .disabled: return "LOCAL UAV DISABLED"
        case .crashed:  return "LOCAL UAV CRASHED"
        default:        return "LOCAL UAV DAMAGED"
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

        if let event = lastCollisionEvent {
            VStack(alignment: .leading, spacing: 2) {
                Text("Events")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                HStack(spacing: 4) {
                    Text(event.severity.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(severityColor(event.severity))
                    Text("→")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Text(event.result.rawValue.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(resultColor(event.result))
                }
                Text(event.participants.map(\.displayName).joined(separator: " × "))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(1)
            }
            separator
        }
    }

    private func severityColor(_ severity: OnlineCollisionSeverity) -> Color {
        switch severity {
        case .contact:  return GroundControlPalette.textSecondary
        case .minor:    return GroundControlPalette.warning
        case .major:    return Color(red: 1.0, green: 0.55, blue: 0.2)
        case .critical: return Color(red: 1.0, green: 0.25, blue: 0.25)
        }
    }

    private func resultColor(_ result: OnlineCollisionResult) -> Color {
        switch result {
        case .ignored:  return GroundControlPalette.textSecondary
        case .damaged:  return GroundControlPalette.warning
        case .disabled: return Color(red: 1.0, green: 0.55, blue: 0.2)
        case .crashed:  return Color(red: 1.0, green: 0.25, blue: 0.25)
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
