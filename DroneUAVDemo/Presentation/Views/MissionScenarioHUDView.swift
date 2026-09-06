import SwiftUI

/// In-simulation overlay for an active mission scenario: shows the objective, a countdown,
/// detection lock-on progress, and the final outcome banner.
struct MissionScenarioHUDView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

    private var isFireResponse: Bool { viewModel.activeMissionScenarioKind == .fireResponse }
    private var isAgriSpraying: Bool { viewModel.activeMissionScenarioKind == .agriculturalSpraying }
    private var isRacing: Bool { viewModel.activeMissionScenarioKind == .droneRacing }
    private var isIntercepting: Bool { viewModel.activeMissionScenarioKind == .attachedPayloadIntercept }

    var body: some View {
        if viewModel.hasMissionScenario {
            VStack(spacing: 8) {
                header
                if isIntercepting {
                    interceptObjectiveRow
                } else if isRacing {
                    raceObjectiveRow
                } else if isAgriSpraying {
                    if let outcome = viewModel.agriSprayOutcome {
                        agriOutcomeBanner(outcome)
                    } else {
                        agriObjectiveRow
                    }
                } else if isFireResponse {
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
            Text(timeString(remainingSeconds))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(timerColor)
        }
    }

    private var remainingSeconds: Double {
        if isIntercepting { return viewModel.interceptHUD.remaining }
        // Racing counts up, not down: the header shows the running lap instead of a budget.
        if isRacing { return viewModel.raceCurrentLapSeconds }
        if isAgriSpraying { return viewModel.agriSprayRemainingSeconds }
        if isFireResponse { return viewModel.fireResponseRemainingSeconds }
        return viewModel.missionScenarioRemainingSeconds
    }

    // MARK: - Attached payload interception

    /// Status only. Everything the operator can *press* during this mission lives in
    /// `InterceptMissionPanelView`, because this HUD is drawn over the viewport with hit testing
    /// off so it never eats a mouse-look drag.
    @ViewBuilder
    private var interceptObjectiveRow: some View {
        let state = viewModel.interceptHUD
        VStack(alignment: .leading, spacing: 7) {
            if let result = state.result {
                interceptOutcomeBanner(result)
            } else {
                Label {
                    Text(LocalizedStringKey(state.phase.titleKey))
                        .font(.caption.weight(.semibold))
                } icon: {
                    Image(systemName: interceptPhaseIcon(state.phase))
                }
                .foregroundStyle(GroundControlPalette.accent)
            }

            HStack {
                Text(state.sourceID)
                    .font(.caption.weight(.bold).monospaced())
                    .foregroundStyle(state.isObservingObserver ? GroundControlPalette.warning : .white)
                Spacer()
                // With the readouts hidden the operator judges the closure by eye, which is the
                // whole point of the option — so there is no approximate figure here either.
                if !state.hidesRanges {
                    Text(String(
                        format: NSLocalizedString("intercept.hud.range", comment: ""),
                        Double(state.distance)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                }
            }

            Text(LocalizedStringKey(state.observationPhase.titleKey))
                .font(.caption2)
                .foregroundStyle(interceptObservationTint(state.observationPhase))
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(interceptAttemptsText(state))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text(LocalizedStringKey(state.payloadState.titleKey))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(interceptPayloadTint(state.payloadState))
            }

            Text(LocalizedStringKey(state.targetState.targetTitleKey))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(interceptTargetTint(state.targetState))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func interceptAttemptsText(_ state: InterceptMissionHUDState) -> String {
        // An unlimited run says how many approaches have been flown; a capped one says how many
        // are left, because that is the number the operator is actually flying against.
        state.maximumAttempts > 0
            ? String(
                format: NSLocalizedString("intercept.hud.attempts_limited", comment: ""),
                state.attempts,
                state.maximumAttempts
            )
            : String(format: NSLocalizedString("intercept.hud.attempts", comment: ""), state.attempts)
    }

    private func interceptOutcomeBanner(_ result: InterceptMissionResult) -> some View {
        let tint = result.success ? GroundControlPalette.success : GroundControlPalette.danger
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: result.success ? "checkmark.seal.fill" : "xmark.octagon.fill")
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(result.success ? "intercept.success" : "intercept.failure"))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if result.success {
                    Text(String(format: NSLocalizedString("intercept.hud.score", comment: ""), result.score))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(GroundControlPalette.success)
                }
            }
            Text(LocalizedStringKey(result.reason.titleKey))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private func interceptPhaseIcon(_ phase: InterceptMissionPhase) -> String {
        switch phase {
        case .idle, .preparing: return "hourglass"
        case .acquiringTarget: return "binoculars.fill"
        case .intercepting, .reattack: return "arrow.triangle.merge"
        case .attackRun: return "scope"
        case .impactResolution: return "burst.fill"
        case .assessingResult: return "checklist"
        case .completed: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func interceptObservationTint(_ phase: InterceptObservationPhase) -> Color {
        switch phase {
        case .noSignal, .unavailable: return GroundControlPalette.danger
        case .attackerLinkDegrading, .observationHandoff: return GroundControlPalette.warning
        case .watchingObserver: return GroundControlPalette.accent
        case .watchingAttacker: return .white.opacity(0.6)
        }
    }

    private func interceptPayloadTint(_ state: AttachedPayloadState) -> Color {
        switch state {
        case .attachedReady, .armedByMission: return .white.opacity(0.75)
        case .degraded: return GroundControlPalette.warning
        case .contactTriggered, .consumed: return GroundControlPalette.accent
        case .inert, .destroyed: return GroundControlPalette.danger
        }
    }

    /// Tinted from the operator's point of view: a target that has stopped flying is progress.
    private func interceptTargetTint(_ state: InterceptFunctionalState) -> Color {
        switch state {
        case .nominal: return .white.opacity(0.6)
        case .damaged, .degraded: return GroundControlPalette.warning
        case .uncontrolled: return GroundControlPalette.accent
        case .disabled, .destroyed, .crashed: return GroundControlPalette.success
        }
    }

    // MARK: - Drone racing

    /// What a racing pilot needs at 30 m/s and nothing else: which gate is next and how far, the
    /// lap, and the times. Gate *state* is shown on the gates themselves, not here.
    private var raceObjectiveRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            if viewModel.raceGateTotal == 0 {
                Text("race.hud.no_track")
                    .font(.caption2)
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let outcome = raceFinishSummary {
                Text(outcome)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(GroundControlPalette.success)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    if let gate = viewModel.raceNextGateNumber {
                        Label {
                            Text(String(
                                format: NSLocalizedString("race.hud.next_gate", comment: ""),
                                gate,
                                viewModel.raceNextGateDistanceMeters
                            ))
                            .font(.caption.weight(.semibold).monospacedDigit())
                        } icon: {
                            Image(systemName: "arrow.forward.circle.fill")
                        }
                        .foregroundStyle(GroundControlPalette.accent)
                    } else {
                        Text("race.hud.free_flight")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }

                if viewModel.raceLapCount > 0, viewModel.raceCurrentLap > 0 {
                    HStack {
                        Text(String(
                            format: NSLocalizedString("race.hud.lap", comment: ""),
                            viewModel.raceCurrentLap,
                            viewModel.raceLapCount
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                        Spacer()
                        Text(String(
                            format: NSLocalizedString("race.hud.gates", comment: ""),
                            viewModel.raceGatesTaken,
                            viewModel.raceGateTotal
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                    }
                } else if viewModel.raceObjectiveState == .armed {
                    Text("race.hud.armed")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let best = viewModel.raceBestLapSeconds {
                    Text(String(
                        format: NSLocalizedString("race.hud.best_lap", comment: ""),
                        best
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(GroundControlPalette.success)
                }
            }

            if viewModel.raceWrongWayFlashSeconds > 0.0 {
                Label {
                    Text("race.hud.wrong_way")
                        .font(.caption2.weight(.bold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(GroundControlPalette.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var raceFinishSummary: String? {
        guard viewModel.raceObjectiveState == .finished,
              let best = viewModel.raceBestLapSeconds else {
            return nil
        }
        return String(
            format: NSLocalizedString("race.hud.finished", comment: ""),
            viewModel.raceTotalSeconds,
            best
        )
    }

    // MARK: - Agricultural spraying

    /// Coverage first, then the one thing keeping the spray from landing, then the refill state.
    /// Deliberately not a second tank gauge — the sprayer payload already carries its own
    /// (`AgriculturalSprayerStatusHUDView`), and two disagreeing gauges are worse than one.
    private var agriObjectiveRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("mission.hud.objective.agri_spraying")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text(String(format: "%.0f%%", viewModel.agriSprayCoverageFraction * 100.0))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(coverageTint)
            }

            ProgressView(value: Double(min(1.0, viewModel.agriSprayCoverageFraction)))
                .tint(coverageTint)

            if let inhibitorKey = agriInhibitorKey {
                Label {
                    Text(LocalizedStringKey(inhibitorKey))
                        .font(.caption2.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(GroundControlPalette.warning)
            } else if viewModel.agriSpraySwathMeters > 0.001 {
                Text(String(
                    format: NSLocalizedString("mission.hud.agri.swath", comment: ""),
                    viewModel.agriSpraySwathMeters
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
            }

            agriRefillRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var agriRefillRow: some View {
        switch viewModel.agriSprayRefillState {
        case .away:
            Text(String(
                format: NSLocalizedString("mission.hud.agri.station_distance", comment: ""),
                viewModel.agriSprayStationDistanceMeters
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        case .inRangeUnstable:
            Text("mission.hud.agri.refill_hold_still")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.warning)
        case let .filling(progress):
            VStack(alignment: .leading, spacing: 3) {
                Text("mission.hud.agri.refilling")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroundControlPalette.accent)
                ProgressView(value: Double(progress))
                    .tint(GroundControlPalette.accent)
            }
        case .full:
            Text("mission.hud.agri.tank_full")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroundControlPalette.success)
        }
    }

    private var agriInhibitorKey: String? {
        switch viewModel.agriSprayInhibitor {
        case .none: return nil
        case .offField: return "mission.hud.agri.inhibitor.off_field"
        case .tooHigh: return "mission.hud.agri.inhibitor.too_high"
        case .tooLow: return "mission.hud.agri.inhibitor.too_low"
        case .tooFast: return "mission.hud.agri.inhibitor.too_fast"
        case .windy: return "mission.hud.agri.inhibitor.windy"
        case .tankEmpty: return "mission.hud.agri.inhibitor.tank_empty"
        }
    }

    private var coverageTint: Color {
        viewModel.agriSprayCoverageFraction >= AgriSprayTuning.successCoverageFraction
            ? GroundControlPalette.success
            : GroundControlPalette.accent
    }

    private func agriOutcomeBanner(_ outcome: AgriSprayOutcome) -> some View {
        let (titleKey, tint, detail): (String, Color, String?) = {
            switch outcome {
            case let .success(_, coverage, used, wasted):
                return (
                    "mission.hud.outcome.success",
                    GroundControlPalette.success,
                    String(
                        format: NSLocalizedString("mission.hud.agri.result", comment: ""),
                        coverage * 100.0, used, wasted
                    )
                )
            case let .failureTimeout(coverage):
                return (
                    "mission.hud.outcome.failure",
                    GroundControlPalette.danger,
                    String(format: "%.0f%%", coverage * 100.0)
                )
            case .aborted:
                return ("mission.hud.outcome.aborted", GroundControlPalette.textSecondary, nil)
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: agriOutcomeIcon(outcome))
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(titleKey))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
            }
            if let detail {
                Text(detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
    }

    private func agriOutcomeIcon(_ outcome: AgriSprayOutcome) -> String {
        switch outcome {
        case .success: return "checkmark.seal.fill"
        case .failureTimeout: return "xmark.octagon.fill"
        case .aborted: return "minus.circle.fill"
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
        if isIntercepting {
            if viewModel.interceptHUD.result != nil { return .white.opacity(0.7) }
            return viewModel.interceptHUD.remaining <= 60 ? GroundControlPalette.danger : .white
        }
        if isRacing {
            return viewModel.raceObjectiveState == .finished ? GroundControlPalette.success : .white
        }
        if isAgriSpraying {
            if viewModel.agriSprayOutcome != nil { return .white.opacity(0.7) }
            return viewModel.agriSprayRemainingSeconds <= 60 ? GroundControlPalette.danger : .white
        }
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
