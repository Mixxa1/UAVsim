import SwiftUI
import simd

struct MissionStatusPanel: View {
    let snapshot: MissionStatusSnapshot
    let tacticalState: TacticalMapState
    let missionPlan: MissionPlan?
    let profileName: String

    private let columns = [
        GridItem(.flexible(minimum: 120), spacing: 8),
        GridItem(.flexible(minimum: 120), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("mission.panel.section.status")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                Spacer(minLength: 8)
                statusBadge(title: geofenceTitle, tint: geofenceTint)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                fieldCard("mission.status.field.mission_status", value: missionStatusText)
                fieldCard("mission.status.field.mission_type", value: missionTypeText)
                fieldCard("mission.status.field.waypoint_count", value: waypointCountText)
                fieldCard("mission.status.field.route_length", value: routeLengthText)
                fieldCard("mission.status.field.drop_zone", value: dropZoneText)
                fieldCard("mission.status.field.link_quality", value: linkQualityText)
                fieldCard("mission.status.field.home_distance", value: homeDistanceText)
                fieldCard("mission.status.field.edge_distance", value: edgeDistanceText)
                fieldCard("mission.status.field.safe_return_state", value: safeReturnStateText)
                fieldCard("mission.status.field.validation", value: validationText)
                fieldCard("mission.status.field.map_scale_active", value: mapScaleText)
                fieldCard("mission.status.field.profile", value: profileName)
                fieldCard("mission.status.field.feasibility", value: feasibilityText)
            }

            if let explanation = snapshot.primaryExplanation {
                VStack(alignment: .leading, spacing: 4) {
                    Text("mission.status.field.primary_issue")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    Text(localized(explanation.detailKey))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(borderTint(for: explanation.severity), lineWidth: 1)
                )
            }
        }
    }

    private var missionStatusText: String {
        localized(snapshot.truthStatus.titleKey)
    }

    private var missionTypeText: String {
        let draft = tacticalState.workingDraft
        if draft.dropZone != nil {
            return localized("mission.status.value.delivery")
        }
        if draft.hasWaypoints {
            return localized("mission.status.value.route")
        }
        return localized("mission.status.value.none")
    }

    private var waypointCountText: String {
        "\(tacticalState.workingDraft.waypoints.count)"
    }

    private var routeLengthText: String {
        let routeLength = tacticalState.previewRoute?.totalLengthMeters ?? fallbackRouteLengthMeters
        guard routeLength > 0.05 else {
            return localized("mission.status.value.none")
        }
        return meters(routeLength)
    }

    private var dropZoneText: String {
        guard let dropZone = tacticalState.workingDraft.dropZone else {
            return localized("mission.status.value.none")
        }
        return meters(dropZone.radius)
    }

    private var linkQualityText: String {
        let operational = snapshot.operationalStatus
        let statusKey: String
        if operational.isLinkLost {
            statusKey = "tactical.map.link.lost"
        } else if operational.isInCriticalLinkZone {
            statusKey = "tactical.map.link.critical"
        } else if operational.isInWarningLinkZone {
            statusKey = "tactical.map.link.warning"
        } else {
            statusKey = "tactical.map.link.nominal"
        }
        let percent = Int((max(0.0, min(1.0, operational.currentLinkQuality)) * 100.0).rounded())
        return "\(localized(statusKey)) \(percent)%"
    }

    private var homeDistanceText: String {
        meters(snapshot.operationalStatus.distanceToHomeM)
    }

    private var edgeDistanceText: String {
        let direction = localized("tactical.map.direction.\(snapshot.operationalStatus.nearestBoundaryDirection.rawValue)")
        return "\(direction) \(meters(max(0.0, snapshot.operationalStatus.distanceToNearestEdgeM)))"
    }

    private var safeReturnStateText: String {
        let qualifierKey = snapshot.operationalStatus.canReachHomeSafely
            ? "tactical.map.safe_return.ok"
            : "tactical.map.safe_return.limit"
        return "\(localized(qualifierKey)) \(meters(snapshot.operationalStatus.estimatedSafeReturnRangeM))"
    }

    private var validationText: String {
        let issueCount = tacticalState.draftStatus.issues.count
        if issueCount == 0, snapshot.hasValidatedPlan {
            return localized("mission.status.value.validated")
        }
        if issueCount == 0 {
            return localized(tacticalState.draftStatus.titleKey)
        }
        return String(format: localized("mission.status.value.issue_count"), issueCount)
    }

    private var mapScaleText: String {
        let preset = Int(tacticalState.viewport.mapScale.numericPreset.rounded())
        let side = Int(tacticalState.viewport.mapSideLengthMeters.rounded())
        return "\(preset) • \(side) m"
    }

    private var feasibilityText: String {
        if snapshot.operationalStatus.canCompleteMissionSafely &&
            snapshot.operationalStatus.geofenceState != .outside &&
            tacticalState.draftStatus.issues.isEmpty {
            return localized("mission.status.value.feasible")
        }
        if snapshot.operationalStatus.canReachHomeSafely {
            return localized("mission.status.value.limited")
        }
        return localized("mission.status.value.blocked")
    }

    private var geofenceTitle: String {
        snapshot.operationalStatus.geofenceState.title
    }

    private var geofenceTint: Color {
        switch snapshot.operationalStatus.geofenceState {
        case .nominal:
            return GroundControlPalette.success
        case .warning:
            return GroundControlPalette.warning
        case .critical, .outside:
            return GroundControlPalette.danger
        }
    }

    private var fallbackRouteLengthMeters: Float {
        guard let missionPlan else {
            return 0.0
        }
        return routeLength(of: missionPlan.routePoints)
    }

    private func fieldCard(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func statusBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.72), lineWidth: 1)
            )
    }

    private func borderTint(for severity: MissionStatusExplanationSeverity) -> Color {
        switch severity {
        case .critical:
            return GroundControlPalette.danger
        case .warning:
            return GroundControlPalette.warning
        case .info:
            return GroundControlPalette.border
        }
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    private func meters(_ value: Float) -> String {
        String(format: "%.0f m", value)
    }

    private func routeLength(of points: [SIMD2<Float>]) -> Float {
        guard points.count > 1 else {
            return 0.0
        }
        return zip(points, points.dropFirst()).reduce(into: Float.zero) { partial, segment in
            partial += simd_distance(segment.0, segment.1)
        }
    }
}
