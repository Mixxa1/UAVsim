import SwiftUI

struct MissionStatusPanel: View {
    let snapshot: MissionStatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusGrid
            MissionSafetyPanel(snapshot: snapshot)
            capabilityRow
            primaryExplanationRow
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("mission.panel.section.status")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
            Spacer(minLength: 8)
            statusBadge(LocalizedStringKey(snapshot.truthStatus.titleKey), tint: truthTint)
            statusBadge(LocalizedStringKey(snapshot.planStatus.titleKey), tint: planTint)
            statusBadge(LocalizedStringKey(snapshot.executionReadiness.titleKey), tint: readinessTint)
            statusBadge(LocalizedStringKey(snapshot.executionStatus.titleKey), tint: executionTint)
        }
    }

    private var statusGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                summaryRow("mission.status.field.control", value: localized(snapshot.controlAuthority.titleKey))
                summaryRow("mission.status.field.active_target", value: snapshot.activeTargetLabel ?? localized("mission.status.value.none"))
            }
            HStack(spacing: 10) {
                summaryRow("mission.status.field.distance", value: distanceText)
                summaryRow(
                    "mission.status.field.progress",
                    value: "\(snapshot.completedWaypointCount) / \(max(snapshot.totalWaypointCount, 0))"
                )
            }
            HStack(spacing: 10) {
                summaryRow("mission.status.field.validated_plan", value: boolValue(snapshot.hasValidatedPlan))
                summaryRow("mission.status.field.binding", value: localized(snapshot.executionBindingState.titleKey))
            }
            HStack(spacing: 10) {
                summaryRow("mission.status.field.execution_contour", value: boundValue(snapshot.hasExecutionContour))
                summaryRow("mission.status.field.execution_target", value: boolValue(snapshot.hasActiveExecutionTarget))
            }
            HStack(spacing: 10) {
                summaryRow("mission.status.field.runtime_distance", value: availabilityValue(snapshot.hasRuntimeDistance))
                summaryRow("mission.status.field.start_permission", value: permissionValue(snapshot.startPermissionGranted))
            }
        }
    }

    private var capabilityRow: some View {
        let chips = capabilityChips

        guard !chips.isEmpty else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: 8) {
                ForEach(chips, id: \.titleKey) { item in
                    chip(item.titleKey, active: item.active)
                }
                Spacer(minLength: 0)
            }
        )
    }

    private var primaryExplanationRow: some View {
        let explanation = snapshot.primaryExplanation

        return Group {
            if let explanation {
                MissionFailureView(explanation: explanation)
            } else {
                MissionFailureView(
                    detailKey: "tactical.map.issue.none",
                    severity: .info
                )
            }
        }
    }

    private var capabilityChips: [(titleKey: String, active: Bool)] {
        var chips: [(String, Bool)] = []
        if snapshot.safetyState.failsafeMode != .none {
            chips.append(("mission.status.chip.failsafe", true))
        }
        if snapshot.canPrepare {
            chips.append(("mission.status.chip.prepare", true))
        }
        if snapshot.canStart {
            chips.append(("mission.status.chip.start", true))
        }
        if snapshot.hasBoundAutopilotTarget {
            chips.append(("mission.status.chip.bound", true))
        }
        if chips.isEmpty && snapshot.executionStatus == .running {
            chips.append(("mission.status.chip.bound", true))
        }
        return chips
    }

    private func summaryRow(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
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

    private var distanceText: String {
        guard let distance = snapshot.distanceToActiveTarget else {
            return localized("mission.status.value.none")
        }
        return String(format: "%.1f m", distance)
    }

    private var planTint: Color {
        switch snapshot.planStatus {
        case .draft:
            return GroundControlPalette.warning
        case .invalid:
            return GroundControlPalette.danger
        case .validated:
            return GroundControlPalette.success
        }
    }

    private var readinessTint: Color {
        switch snapshot.executionReadiness {
        case .draft:
            return GroundControlPalette.borderStrong
        case .validated:
            return GroundControlPalette.warning
        case .executionUnbound, .failedBinding:
            return GroundControlPalette.danger
        case .ready:
            return GroundControlPalette.accent
        }
    }

    private var truthTint: Color {
        switch snapshot.truthStatus {
        case .draft:
            return GroundControlPalette.borderStrong
        case .validated:
            return GroundControlPalette.warning
        case .invalid, .executionUnbound, .blocked, .noAuthority, .noTarget, .routeInvalid, .runtimeDistanceUnavailable, .failedBinding, .runtimeUnsafe, .failed:
            return GroundControlPalette.danger
        case .ready:
            return GroundControlPalette.accent
        case .running, .completed:
            return GroundControlPalette.success
        case .paused, .returningHome, .aborted:
            return GroundControlPalette.warning
        }
    }

    private var executionTint: Color {
        switch snapshot.executionStatus {
        case .idle:
            return GroundControlPalette.borderStrong
        case .ready:
            return GroundControlPalette.accent
        case .running:
            return GroundControlPalette.success
        case .paused:
            return GroundControlPalette.warning
        case .completed:
            return GroundControlPalette.success
        case .aborted, .blocked, .failed:
            return GroundControlPalette.danger
        }
    }

    private func statusBadge(_ title: LocalizedStringKey, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.75), lineWidth: 1)
            )
    }

    private func chip(_ titleKey: String, active: Bool) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(active ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill((active ? GroundControlPalette.accent : GroundControlPalette.inset).opacity(active ? 0.18 : 1.0))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke((active ? GroundControlPalette.accent : GroundControlPalette.border).opacity(0.8), lineWidth: 1)
            )
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func boolValue(_ value: Bool) -> String {
        localized(value ? "mission.status.value.present" : "mission.status.value.absent")
    }

    private func boundValue(_ value: Bool) -> String {
        localized(value ? "mission.status.value.bound" : "mission.status.value.unbound")
    }

    private func availabilityValue(_ value: Bool) -> String {
        localized(value ? "mission.status.value.available" : "mission.status.value.unavailable")
    }

    private func permissionValue(_ value: Bool) -> String {
        localized(value ? "mission.status.value.granted" : "mission.status.value.blocked")
    }
}
