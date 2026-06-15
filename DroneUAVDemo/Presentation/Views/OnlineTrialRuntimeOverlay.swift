import SwiftUI

struct OnlineTrialRuntimeOverlay: View {
    let context: OnlineTrialRuntimeContext?
    let fleetState: OnlineTrialFleetState?
    let remoteStates: [OnlineVehicleInterpolatedState]
    let snapshotTargetHz: Int
    var isExpanded: Bool = false

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

    var body: some View {
        if isExpanded {
            expandedPanel
        }
    }

    // MARK: – Expanded panel (Tab hold)

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            separator
            infoRow("Участник", context?.localParticipant.displayName ?? "—")
            infoRow("UAV ID", vehicleIDText)
            infoRow("Vehicles", "\(vehicleCount)")
            infoRow("Remote", "\(remoteCount) vis")
            infoRow("Snapshot", "\(snapshotTargetHz) Hz")
            separator
            statusSection
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 210, alignment: .leading)
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

            Text(roleLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(roleIsHost ? Color.black : GroundControlPalette.textPrimary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(roleIsHost ? GroundControlPalette.warning : GroundControlPalette.accent.opacity(0.28))
                )
        }
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
            if ctx.isSpectator && ctx.isHost {
                statusLine("HOST ADMIN · без UAV")
            } else if ctx.isSpectator {
                if remoteStates.isEmpty {
                    statusLine("Нет активных UAV")
                    statusLine("Ожидание pilot snapshots...")
                } else {
                    statusLine("Наблюдение активно")
                    statusLine("Управление БЛА отключено")
                }
            } else {
                if remoteStates.isEmpty {
                    statusLine("Remote vehicles: 0")
                    statusLine("Ожидание других участников...")
                } else {
                    statusLine("Управление: локальный UAV")
                    statusLine("Remote: \(remoteCount) ghost(s) visible")
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(GroundControlPalette.textPrimary)
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
