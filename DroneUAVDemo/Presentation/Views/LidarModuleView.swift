import SwiftUI

/// Ground-control panel for the LiDAR survey payload. Unlike the camera/rangefinder optics
/// overlays, LiDAR is flown like a normal sortie while the geo-referenced cloud builds up — so this
/// is a control-and-status panel (scan enable, filter, colour view, live statistics, clear, export)
/// rather than a through-the-optics viewport.
struct LidarModuleView: View {
    let state: PayloadLidarOpticsState
    let onToggleScan: () -> Void
    let onPitchDelta: (Double) -> Void
    let onVoxelSize: (LidarVoxelSize) -> Void
    let onRetainRaw: (Bool) -> Void
    let onColorMode: (LidarColorMode) -> Void
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
            statRow(L10n.s("lidar.hud.returns_per_point"), value: returnsText)
            statRow(L10n.s("lidar.hud.scans"), value: "\(state.scanCount)")
            statRow(L10n.s("lidar.hud.pitch"), value: String(format: "%.0f°", state.gimbalPitchDegrees))

            Divider().overlay(GroundControlPalette.border)

            // Filter: voxel edge length, or raw returns with no filtering at all.
            Text(L10n.s("lidar.hud.filter"))
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 3) {
                ForEach(LidarVoxelSize.allCases) { size in
                    segmentButton(
                        size.label,
                        isSelected: state.voxelSize == size,
                        action: { onVoxelSize(size) }
                    )
                }
            }
            // Raw retention is independent of the filter: the map is always built, the raw cloud is
            // an additional product exported beside it.
            segmentButton(
                L10n.f("lidar.hud.raw_toggle", rawCountText),
                isSelected: state.retainsRawReturns,
                action: { onRetainRaw(!state.retainsRawReturns) }
            )

            Text(L10n.s("lidar.hud.color"))
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundStyle(GroundControlPalette.textSecondary)
            HStack(spacing: 3) {
                ForEach(LidarColorMode.allCases) { mode in
                    segmentButton(
                        L10n.s(mode.shortLabelKey),
                        isSelected: state.colorMode == mode,
                        action: { onColorMode(mode) }
                    )
                }
            }

            Divider().overlay(GroundControlPalette.border)

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
                        exportNote = L10n.f("lidar.hud.saved", "\(urls.count)× \(first.deletingPathExtension().lastPathComponent)")
                    }
                })
            }

            if let exportNote {
                Text(exportNote)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: 210, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 238, alignment: .leading)
        .background(GroundControlPalette.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private var pointText: String {
        let count = state.capturedPointCount
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        }
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

    private var returnsText: String {
        String(format: "%.1f", state.meanReturnsPerPoint)
    }

    private var rawCountText: String {
        guard state.retainsRawReturns else { return "" }
        let count = state.rawReturnCount
        if count >= 1_000_000 { return String(format: " %.2fM", Double(count) / 1_000_000.0) }
        if count >= 1_000 { return String(format: " %.0fk", Double(count) / 1_000.0) }
        return " \(count)"
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

    private func segmentButton(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundStyle(isSelected ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isSelected ? GroundControlPalette.accent.opacity(0.30) : GroundControlPalette.inset,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(
                            isSelected ? GroundControlPalette.accent.opacity(0.65) : GroundControlPalette.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
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
