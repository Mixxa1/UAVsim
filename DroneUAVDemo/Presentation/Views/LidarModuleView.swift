import SwiftUI

/// Compact ground-control panel for the LiDAR survey payload. Unlike the camera/rangefinder optics
/// overlays, LiDAR is flown like a normal sortie while the geo-referenced cloud builds up in the
/// main 3-D view — so this is a control-and-status panel (scan enable, live point count and
/// coverage, gimbal pitch, clear, export), not a through-the-optics viewport.
struct LidarModuleView: View {
    let state: PayloadLidarOpticsState
    let onToggleScan: () -> Void
    let onPitchDelta: (Double) -> Void
    let onClear: () -> Void
    let onExport: () -> [URL]?

    @State private var exportNote: String?

    private var statusText: String {
        if state.isBufferFull { return L10n.s("lidar.hud.full") }
        return state.isScanning ? L10n.s("lidar.hud.scanning") : L10n.s("lidar.hud.standby")
    }

    private var statusColor: Color {
        if state.isBufferFull { return GroundControlPalette.warning }
        return state.isScanning ? GroundControlPalette.success : GroundControlPalette.textSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(state.feedLabel)
                    .font(.system(size: 12, weight: .bold).monospaced())
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Spacer(minLength: 12)
                Text(statusText)
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(statusColor)
            }

            statRow(L10n.s("lidar.hud.points"), value: pointText)
            statRow(L10n.s("lidar.hud.coverage"), value: coverageText)
            statRow(L10n.s("lidar.hud.pitch"), value: String(format: "%.0f°", state.gimbalPitchDegrees))

            HStack(spacing: 6) {
                actionButton(
                    state.isScanning ? L10n.s("lidar.hud.stop") : L10n.s("lidar.hud.scan"),
                    tint: state.isScanning ? GroundControlPalette.warning : GroundControlPalette.success,
                    action: onToggleScan
                )
                stepper
            }

            HStack(spacing: 6) {
                actionButton(L10n.s("lidar.hud.clear"), tint: GroundControlPalette.danger, action: {
                    exportNote = nil
                    onClear()
                })
                actionButton(L10n.s("lidar.hud.export"), tint: GroundControlPalette.accent, action: {
                    if let urls = onExport(), let first = urls.first {
                        exportNote = L10n.f("lidar.hud.saved", first.deletingLastPathComponent().lastPathComponent + "/" + first.lastPathComponent)
                    }
                })
            }

            if let exportNote {
                Text(exportNote)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 190, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 214, alignment: .leading)
        .background(GroundControlPalette.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private var pointText: String {
        let count = state.capturedPointCount
        if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private var coverageText: String {
        let squareMeters = state.coverageSquareMeters
        if squareMeters >= 10_000 {
            return String(format: "%.2f %@", squareMeters / 10_000.0, L10n.s("lidar.hud.hectares"))
        }
        return String(format: "%.0f %@", squareMeters, L10n.s("lidar.hud.square_meters"))
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
    }

    private func actionButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold).monospaced())
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(tint.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var stepper: some View {
        HStack(spacing: 0) {
            Button(action: { onPitchDelta(5) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            Button(action: { onPitchDelta(-5) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }
}
