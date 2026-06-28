import Foundation
import simd

final class MissionDraftValidator {
    func validate(
        draft: MissionDraft,
        previewRoute: MissionPreviewRoute?,
        viewport: MapViewportState
    ) -> MissionDraftStatus {
        var issues: [MissionDraftIssue] = []

        if !draft.hasContent {
            return .empty
        }

        if draft.waypoints.isEmpty {
            issues.append(
                MissionDraftIssue(
                    severity: .warning,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.route_missing"
                )
            )
        }

        if draft.selectedLaunchMode.requiresLaunchObject {
            if let launchIssue = validateLaunchObject(
                draft: draft,
                viewport: viewport
            ) {
                issues.append(launchIssue)
            }
        }

        for waypoint in draft.waypoints {
            if !viewport.isWithinWorldBounds(waypoint.position, tolerance: 0.05) {
                issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.waypoint_out_of_bounds"
                )
                )
                break
            }
        }

        if draft.waypoints.count > 1 {
            for pair in zip(draft.waypoints, draft.waypoints.dropFirst()) {
                if simd_distance(pair.0.position, pair.1.position) < draft.constraints.minimumWaypointSpacing {
                    issues.append(
                        MissionDraftIssue(
                            severity: .error,
                            reason: .routeInvalid,
                            messageKey: "tactical.map.issue.waypoint_spacing"
                        )
                    )
                    break
                }
            }
        }

        if draft.constraints.altitude.minimumMeters < 0.0 ||
            draft.constraints.altitude.maximumMeters <= 0.0 ||
            draft.constraints.altitude.maximumMeters < draft.constraints.altitude.minimumMeters {
            issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .invalidAltitudeWindow,
                    messageKey: "tactical.map.issue.invalid_altitude_window"
                )
            )
        } else {
            let executionCeiling = max(2.0, viewport.terrainMaxAltitudeMeters - 2.0)
            let baselineAltitude = draft.constraints.baselineTravelAltitude(
                currentAltitude: viewport.droneAltitudeMeters,
                dockAltitude: viewport.dockAltitudeMeters,
                terrainMaxAltitude: executionCeiling,
                airframeClass: viewport.airframeClass
            )
            let altitudeWindow = draft.constraints.altitude.clamped(to: executionCeiling)
            if baselineAltitude < altitudeWindow.lowerBound - 0.05 ||
                baselineAltitude > altitudeWindow.upperBound + 0.05 {
                issues.append(
                    MissionDraftIssue(
                        severity: .error,
                        reason: .targetAltitudeOutOfRange,
                        messageKey: "tactical.map.issue.target_altitude_out_of_range"
                    )
                )
            }
        }

        if draft.constraints.speed.minimumMetersPerSecond < 0.0 ||
            draft.constraints.speed.maximumMetersPerSecond <= 0.0 ||
            draft.constraints.speed.maximumMetersPerSecond < draft.constraints.speed.minimumMetersPerSecond ||
            (
                viewport.profileMaxHorizontalSpeedMps > 0.0 &&
                draft.constraints.speed.minimumMetersPerSecond > viewport.profileMaxHorizontalSpeedMps + 0.05
            ) {
            issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .invalidSpeedWindow,
                    messageKey: "tactical.map.issue.invalid_speed_window"
                )
            )
        }

        for zone in draft.zones {
            let maxRadius = draft.constraints.maximumZoneRadius(for: viewport)
            if zone.radius < draft.constraints.minimumZoneRadius || zone.radius > maxRadius {
                issues.append(
                    MissionDraftIssue(
                        severity: .error,
                        reason: .zoneInvalid,
                        messageKey: "tactical.map.issue.zone_radius_invalid"
                    )
                )
            }

            if !viewport.isWithinWorldBounds(zone.center, tolerance: 0.05) {
                issues.append(
                    MissionDraftIssue(
                        severity: .error,
                        reason: .zoneInvalid,
                        messageKey: "tactical.map.issue.zone_out_of_bounds"
                    )
                )
            }
        }

        if let dropZone = draft.dropZone,
           !viewport.isWithinWorldBounds(dropZone.center, tolerance: 0.05) {
            issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .zoneInvalid,
                    messageKey: "tactical.map.issue.zone_out_of_bounds"
                )
            )
        }

        if let previewRoute {
            let routeDistanceWithReturn = previewRoute.totalLengthMeters +
                missionReturnDistance(previewRoute: previewRoute, viewport: viewport)
            let furthestMissionRadius = maxMissionRadius(draft: draft, previewRoute: previewRoute, viewport: viewport)

            if routeDistanceWithReturn > viewport.estimatedSafeReturnRangeM + 0.05 {
                issues.append(
                    MissionDraftIssue(
                        severity: .error,
                        reason: .batteryUnsafe,
                        messageKey: "tactical.map.issue.route_exceeds_safe_return"
                    )
                )
            } else if routeDistanceWithReturn > viewport.estimatedSafeReturnRangeM * 0.86 {
                issues.append(
                    MissionDraftIssue(
                        severity: .warning,
                        reason: .batteryUnsafe,
                        messageKey: "tactical.map.issue.route_margin_tight"
                    )
                )
            }

            if furthestMissionRadius > viewport.operationalRadius + 0.05 {
                issues.append(
                    MissionDraftIssue(
                        severity: .warning,
                        reason: .routeInvalid,
                        messageKey: "tactical.map.issue.route_exceeds_operational_radius"
                    )
                )
            }

            if furthestMissionRadius > viewport.degradedLinkRadius + 0.05 {
                issues.append(
                    MissionDraftIssue(
                        severity: .warning,
                        reason: .runtimeUnsafe,
                        messageKey: "tactical.map.issue.link_degraded"
                    )
                )
            }
        }

        if viewport.currentMapSuitability == .tight {
            issues.append(
                MissionDraftIssue(
                    severity: .warning,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.map_tight"
                )
            )
        } else if viewport.currentMapSuitability == .unsuitable {
            issues.append(
                MissionDraftIssue(
                    severity: .warning,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.map_unsuitable"
                )
            )
        }

        let hasBlockingIssue = issues.contains { $0.severity == .error }
        let hasPreview = previewRoute != nil && !hasBlockingIssue

        if hasBlockingIssue {
            return MissionDraftStatus(
                kind: .invalid,
                titleKey: "tactical.map.status.invalid.title",
                detailKey: "tactical.map.status.invalid.detail",
                issues: unique(issues),
                isPreviewAvailable: false,
                canSave: false
            )
        }

        if !hasPreview {
            return MissionDraftStatus(
                kind: .previewUnavailable,
                titleKey: "tactical.map.status.preview_unavailable.title",
                detailKey: "tactical.map.status.preview_unavailable.detail",
                issues: unique(issues),
                isPreviewAvailable: false,
                canSave: false
            )
        }

        return MissionDraftStatus(
            kind: .ready,
            titleKey: "tactical.map.status.ready.title",
            detailKey: "tactical.map.status.ready.detail",
            issues: unique(issues),
            isPreviewAvailable: true,
            canSave: true
        )
    }

    private func validateLaunchObject(
        draft: MissionDraft,
        viewport: MapViewportState
    ) -> MissionDraftIssue? {
        guard let launchObject = draft.launchObject else {
            return MissionDraftIssue(
                severity: .error,
                reason: .routeInvalid,
                messageKey: "tactical.map.issue.launch_object_required"
            )
        }

        if !viewport.isWithinWorldBounds(launchObject.position, tolerance: 0.05) {
            return MissionDraftIssue(
                severity: .error,
                reason: .routeInvalid,
                messageKey: "tactical.map.issue.launch_object_out_of_bounds"
            )
        }

        let corridorLength = launchCorridorLength(
            for: draft.selectedLaunchMode,
            viewport: viewport
        )
        guard corridorLength > 0.05 else {
            return nil
        }

        let headingRadians = (launchObject.transitionHeadingDegrees ?? launchObject.headingDegrees) * .pi / 180.0
        let corridorEnd = launchObject.position + SIMD2<Float>(sin(headingRadians), cos(headingRadians)) * corridorLength
        guard viewport.isWithinWorldBounds(corridorEnd, tolerance: 0.05) else {
            return MissionDraftIssue(
                severity: .error,
                reason: .routeInvalid,
                messageKey: "tactical.map.issue.launch_corridor_invalid"
            )
        }

        if draft.selectedLaunchMode == .runway || draft.selectedLaunchMode == .catapult {
            let edgeMargin = min(
                viewport.distanceToNearestMapEdge(for: launchObject.position),
                viewport.distanceToNearestMapEdge(for: corridorEnd)
            )
            if edgeMargin < max(4.0, corridorLength * 0.12) {
                return MissionDraftIssue(
                    severity: .error,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.launch_space_insufficient"
                )
            }
        }

        return nil
    }

    private func launchCorridorLength(
        for launchMode: LaunchMode,
        viewport: MapViewportState
    ) -> Float {
        switch launchMode {
        case .standard:
            return 0.0
        case .handLaunch:
            return max(12.0, viewport.minimumTurnRadiusM * 0.42)
        case .catapult:
            return max(18.0, viewport.minimumTurnRadiusM * 0.72)
        case .runway:
            return max(24.0, viewport.minimumTurnRadiusM * 1.15)
        case .vtol:
            return max(8.0, viewport.minimumTurnRadiusM * 0.32)
        }
    }

    private func unique(_ issues: [MissionDraftIssue]) -> [MissionDraftIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert(issue.id).inserted
        }
    }

    private func missionReturnDistance(
        previewRoute: MissionPreviewRoute,
        viewport: MapViewportState
    ) -> Float {
        guard let endPoint = previewRoute.points.last else {
            return 0.0
        }
        return simd_distance(endPoint, viewport.dockPosition)
    }

    private func maxMissionRadius(
        draft: MissionDraft,
        previewRoute: MissionPreviewRoute,
        viewport: MapViewportState
    ) -> Float {
        let previewMax = previewRoute.points.map { simd_distance($0, viewport.dockPosition) }.max() ?? 0.0
        let waypointMax = draft.waypoints.map { simd_distance($0.position, viewport.dockPosition) }.max() ?? 0.0
        let zoneMax = draft.zones.map { simd_distance($0.center, viewport.dockPosition) + $0.radius }.max() ?? 0.0
        return max(previewMax, waypointMax, zoneMax)
    }
}
