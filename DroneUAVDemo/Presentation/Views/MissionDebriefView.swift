import SwiftUI

struct MissionDebriefView: View {
    let debrief: MissionDebrief?
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("mission.debrief.title")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Spacer(minLength: 8)
                if let debrief {
                    outcomeBadge(debrief.summary.outcome)
                }
            }

            if let debrief {
                summaryGrid(debrief)
                details(debrief)
            } else {
                Text("mission.debrief.empty")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelCard()
    }

    private func summaryGrid(_ debrief: MissionDebrief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                metric("mission.debrief.metric.duration", value: durationText(debrief.performance.durationSec))
                metric("mission.debrief.metric.route", value: String(format: "%.0f m", debrief.performance.routeLengthMeters))
            }
            HStack(spacing: 8) {
                metric(
                    "mission.debrief.metric.progress",
                    value: "\(debrief.execution.reachedWaypointCount) / \(debrief.execution.totalWaypointCount)"
                )
                metric(
                    "mission.debrief.metric.energy",
                    value: debrief.energy.consumedBatteryPercent.map { String(format: "%.0f%%", $0) } ?? "—"
                )
            }
        }
    }

    private func details(_ debrief: MissionDebrief) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(debrief.summary.verdictKey))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)

            Text(LocalizedStringKey(debrief.summary.finalReasonKey))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !compact {
                HStack(spacing: 8) {
                    metric("mission.debrief.metric.warnings", value: "\(debrief.warnings.warningCount)")
                    metric("mission.debrief.metric.critical", value: "\(debrief.warnings.criticalCount)")
                }

                if !debrief.keyEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(debrief.keyEvents.suffix(4))) { event in
                            Text(LocalizedStringKey(event.detailKey))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(GroundControlPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func metric(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func outcomeBadge(_ outcome: MissionOutcome) -> some View {
        Text(LocalizedStringKey(outcome.titleKey))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(outcomeColor(outcome).opacity(0.14), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(outcomeColor(outcome).opacity(0.8), lineWidth: 1)
            )
    }

    private func outcomeColor(_ outcome: MissionOutcome) -> Color {
        switch outcome {
        case .success:
            return GroundControlPalette.success
        case .partialSuccess, .returnedHome:
            return GroundControlPalette.warning
        case .aborted, .failed, .safetyTerminated:
            return GroundControlPalette.danger
        }
    }
}
