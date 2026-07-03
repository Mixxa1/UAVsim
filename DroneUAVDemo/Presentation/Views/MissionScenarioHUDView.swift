import SwiftUI

/// In-simulation overlay for an active mission scenario: shows the objective, a countdown,
/// detection lock-on progress, and the final outcome banner.
struct MissionScenarioHUDView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private var isFireResponse: Bool { viewModel.activeMissionScenarioKind == .fireResponse }

    var body: some View {
        if viewModel.hasMissionScenario {
            VStack(spacing: 8) {
                header
                if isFireResponse {
                    if let outcome = viewModel.fireResponseOutcome {
                        fireOutcomeBanner(outcome)
                    } else {
                        fireObjectiveRow
                    }
                } else if let outcome = viewModel.missionScenarioOutcome {
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
            Text(timeString(isFireResponse ? viewModel.fireResponseRemainingSeconds : viewModel.missionScenarioRemainingSeconds))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(timerColor)
        }
    }

    // MARK: - Fire response

    private var fireObjectiveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("mission.hud.objective.fire_response")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.8))

            HStack {
                Text(String(
                    format: NSLocalizedString("mission.hud.fires_remaining", comment: ""),
                    viewModel.fireResponseBurningCount,
                    viewModel.fireResponseTotalCount
                ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(viewModel.fireResponseBurningCount > 0 ? GroundControlPalette.warning : .white)
                Spacer()
            }

            // Increment-1 manual test hook — extinguishes the nearest fire without needing the
            // (not-yet-built) hose payload. Removed once the real hose aiming lands.
            Button(action: viewModel.debugExtinguishNearestFireResponseTree) {
                Text("mission.hud.fire_response.debug_extinguish")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fireOutcomeBanner(_ outcome: FireResponseOutcome) -> some View {
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
            Image(systemName: fireOutcomeIcon(outcome))
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

    private func fireOutcomeIcon(_ outcome: FireResponseOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.seal.fill"
        case .failureTimeout: return "xmark.octagon.fill"
        case .aborted: return "minus.circle.fill"
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
        if isFireResponse {
            if viewModel.fireResponseOutcome != nil { return .white.opacity(0.7) }
            return viewModel.fireResponseRemainingSeconds <= 30 ? GroundControlPalette.danger : .white
        }
        if viewModel.missionScenarioOutcome != nil { return .white.opacity(0.7) }
        return viewModel.missionScenarioRemainingSeconds <= 30 ? GroundControlPalette.danger : .white
    }

    private func timeString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
