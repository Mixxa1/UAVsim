import SwiftUI

struct CompactTelemetryHUDView: View {
    let telemetry: TelemetrySnapshot
    let warningKeys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hud.telemetry")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroundControlPalette.textSecondary)

            Text(String(format: localized("hud.compact.position"), telemetry.x, telemetry.y, telemetry.z))
                .font(.caption2.monospaced())
            Text(String(
                format: localized("hud.compact.speed_battery"),
                telemetry.speed,
                telemetry.batteryPercent,
                telemetry.batteryVoltage
            ))
                .font(.caption2.monospaced())
            // Engine and fuel, for aircraft that have them. This is what makes the
            // start sequence visible: priming, cranking, warming up and ready are
            // otherwise indistinguishable from an unresponsive throttle.
            if let engineStateKey = telemetry.engineStateKey {
                Text(String(
                    format: localized("hud.compact.engine"),
                    localized(engineStateKey),
                    telemetry.engineShaftRPM,
                    telemetry.engineTemperatureC
                ))
                    .font(.caption2.monospaced())
                if telemetry.fuelCapacityKg > 0.01 {
                    Text(String(
                        format: localized("hud.compact.fuel"),
                        telemetry.fuelRemainingKg,
                        telemetry.fuelRemainingKg / telemetry.fuelCapacityKg * 100.0,
                        telemetry.fuelFlowKgPerHour
                    ))
                        .font(.caption2.monospaced())
                }
            }
            if telemetry.autoNavigationActive || telemetry.targetDistanceMeters.isFinite {
                Text(autoNavigationLine)
                    .font(.caption2.monospaced())
            }
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

    private var autoNavigationLine: String {
        let state = telemetry.autoNavigationActive
            ? localized("telemetry.auto_nav.active")
            : localized("telemetry.auto_nav.inactive")
        let distanceText = telemetry.targetDistanceMeters.isFinite
            ? String(format: "%.1f m", telemetry.targetDistanceMeters)
            : "—"
        let bearingText = telemetry.targetBearingDegrees.isFinite
            ? String(format: "%03.0f°", telemetry.targetBearingDegrees)
            : "—"

        return String(
            format: localized("hud.compact.auto_nav"),
            state,
            distanceText,
            bearingText
        )
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
