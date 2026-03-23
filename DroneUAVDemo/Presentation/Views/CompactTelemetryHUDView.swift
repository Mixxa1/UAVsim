import SwiftUI

struct CompactTelemetryHUDView: View {
    let telemetry: TelemetrySnapshot
    let warningKeys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hud.telemetry")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)

            Text(String(format: "POS  x %.1f  y %.1f  z %.1f", telemetry.x, telemetry.y, telemetry.z))
                .font(.caption2.monospaced())
            Text(String(format: "SPD  %.1f m/s   BAT %.0f%%", telemetry.speed, telemetry.batteryPercent))
                .font(.caption2.monospaced())
            Text(LocalizedStringKey(telemetry.modeKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.textPrimary)

            if let warning = warningKeys.first {
                Text(LocalizedStringKey(warning))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.warning)
            }
        }
        .foregroundStyle(GroundControlPalette.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }
}
