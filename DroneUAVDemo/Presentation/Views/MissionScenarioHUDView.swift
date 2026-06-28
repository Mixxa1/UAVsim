import SwiftUI

/// In-simulation overlay for an active mission scenario: shows the objective, a countdown,
/// detection lock-on progress, and the final outcome banner.
struct MissionScenarioHUDView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    var body: some View {
        if viewModel.hasMissionScenario {
            VStack(spacing: 8) {
                header
                if let outcome = viewModel.missionScenarioOutcome {
                    outcomeBanner(outcome)
                } else {
                    objectiveRow
                }
            }
            .padding(12)
            .frame(width: 260)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var header: some View {
        HStack {
            if let kind = viewModel.activeMissionScenarioKind {
                Image(systemName: kind.iconSystemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(LocalizedStringKey(kind.titleKey))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Text(timeString(viewModel.missionScenarioRemainingSeconds))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(timerColor)
        }
    }

    private var objectiveRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mission.hud.objective.search")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))

            if viewModel.missionScenarioDetectionProgress > 0.001 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("mission.hud.locking")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroundControlPalette.warning)
                    ProgressView(value: min(1.0, viewModel.missionScenarioDetectionProgress))
                        .tint(GroundControlPalette.warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func outcomeBanner(_ outcome: MissionScenarioOutcome) -> some View {
        let (titleKey, tint): (String, Color) = {
            switch outcome {
            case .success:
                return ("mission.hud.outcome.success", GroundControlPalette.success)
            case .failureTimeout:
                return ("mission.hud.outcome.failure", GroundControlPalette.danger)
            case .aborted:
                return ("mission.hud.outcome.aborted", GroundControlPalette.textSecondary)
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: outcomeIcon(outcome))
                .foregroundStyle(tint)
            Text(LocalizedStringKey(titleKey))
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private func outcomeIcon(_ outcome: MissionScenarioOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.seal.fill"
        case .failureTimeout: return "xmark.octagon.fill"
        case .aborted: return "minus.circle.fill"
        }
    }

    private var timerColor: Color {
        if viewModel.missionScenarioOutcome != nil { return .white.opacity(0.7) }
        return viewModel.missionScenarioRemainingSeconds <= 30 ? GroundControlPalette.danger : .white
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
