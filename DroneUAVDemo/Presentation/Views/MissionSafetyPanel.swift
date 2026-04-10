import SwiftUI

struct MissionSafetyPanel: View {
    let snapshot: MissionStatusSnapshot
    var showsWarningList: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                safetyMetric(
                    "mission.status.field.truth",
                    value: localized(snapshot.truthStatus.titleKey)
                )
                safetyMetric(
                    "mission.status.field.readiness",
                    value: localized(snapshot.safetyState.readiness.titleKey)
                )
            }

            HStack(spacing: 8) {
                safetyMetric(
                    "mission.status.field.authority_state",
                    value: authorityStateText
                )
                safetyMetric(
                    "mission.status.field.failsafe",
                    value: localized(snapshot.safetyState.failsafeMode.titleKey)
                )
            }

            if showsWarningList, !snapshot.safetyState.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(snapshot.safetyState.warnings.prefix(3))) { warning in
                        MissionFailureView(
                            detailKey: warning.detailKey,
                            severity: warning.severity
                        )
                    }
                }
            }
        }
    }

    private var authorityStateText: String {
        let authorityState = snapshot.safetyState.authorityState
        if !authorityState.requiresMissionAuthority {
            return localized("mission.authority.state.idle")
        }
        if authorityState.isAuthorityConfirmed {
            return localized("mission.authority.state.mission")
        }
        if authorityState.isAuthorityTransientLoss || authorityState.didRecoverTransientLoss {
            return localized("mission.authority.state.flap")
        }
        if authorityState.failureReason == .noMissionTarget {
            return localized("mission.authority.state.target_lost")
        }
        return localized("mission.authority.state.lost")
    }

    private func safetyMetric(_ titleKey: String, value: String) -> some View {
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

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
