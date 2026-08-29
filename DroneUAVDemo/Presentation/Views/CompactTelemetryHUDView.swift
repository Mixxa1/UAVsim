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
            // High-speed block. Appears only when there is something to say — an aircraft
            // below Mach 0.3 with plenty of envelope left has no use for three more lines
            // of numbers, and the entire existing fleet flies there.
            if showsHighSpeedBlock {
                Text(String(
                    format: localized("hud.compact.high_speed"),
                    telemetry.machNumber,
                    telemetry.equivalentAirspeedMps,
                    telemetry.dynamicPressurePa / 1000.0,
                    telemetry.loadFactor
                ))
                    .font(.caption2.monospaced())
                if telemetry.skinTemperatureK > 320.0 {
                    Text(String(
                        format: localized("hud.compact.skin_temperature"),
                        telemetry.skinTemperatureK - 273.15,
                        telemetry.recoveryTemperatureK - 273.15
                    ))
                        .font(.caption2.monospaced())
                }
                // The reason, not just the fact. Which limit is binding decides what the
                // operator should do about it, and the four answers point in different
                // directions — climbing fixes a dynamic-pressure limit and makes a Mach
                // limit worse.
                if telemetry.envelopeWorstFraction > 0.85 {
                    Text(String(
                        format: localized("hud.compact.envelope"),
                        localized(telemetry.envelopeLimitKey),
                        telemetry.envelopeWorstFraction * 100.0
                    ))
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(
                            telemetry.envelopeWorstFraction > 1.0
                                ? GroundControlPalette.danger
                                : GroundControlPalette.warning
                        )
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

    /// Is the aircraft anywhere the compressible numbers mean anything?
    ///
    /// Mach 0.3 is the same threshold the aerodynamics use for legacy equivalence, so the
    /// HUD starts showing these values exactly where they start affecting the flight. The
    /// envelope clause catches the other case: an aircraft that is slow but pulling hard,
    /// or one that has got hot and not yet cooled.
    private var showsHighSpeedBlock: Bool {
        telemetry.machNumber >= 0.30 || telemetry.envelopeWorstFraction > 0.85
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
