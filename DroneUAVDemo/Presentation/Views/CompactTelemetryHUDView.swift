import SwiftUI

struct CompactTelemetryHUDView: View {
    let telemetry: TelemetrySnapshot
    let warningKeys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("hud.telemetry")
                .font(.caption.weight(.semibold))

            Text(String(format: "x %.1f y %.1f z %.1f", telemetry.x, telemetry.y, telemetry.z))
                .font(.caption2.monospaced())
            Text(String(format: "%.1f m/s | %.0f%%", telemetry.speed, telemetry.batteryPercent))
                .font(.caption2.monospaced())

            if let warning = warningKeys.first {
                Text(LocalizedStringKey(warning))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(Color.white.opacity(0.94))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 10))
    }
}
