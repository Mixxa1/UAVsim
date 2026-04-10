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

        for waypoint in draft.waypoints {
            if simd_distance(waypoint.position, .zero) > viewport.signalBoundaryRadius {
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

            if simd_distance(zone.center, .zero) > viewport.signalBoundaryRadius {
                issues.append(
                    MissionDraftIssue(
                        severity: .error,
                        reason: .zoneInvalid,
                        messageKey: "tactical.map.issue.zone_out_of_bounds"
                    )
                )
            }
        }

        if draft.noFlyZones.contains(where: { noFlyZone in
            noFlyZone.contains(viewport.dockPosition) ||
                draft.waypoints.contains(where: { noFlyZone.contains($0.position) }) ||
                previewRouteIntersectsNoFly(previewRoute, zone: noFlyZone)
        }) {
            issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .routeInvalid,
                    messageKey: "tactical.map.issue.route_intersects_no_fly"
                )
            )
        }

        if let dropZone = draft.dropZone,
           simd_distance(dropZone.center, .zero) > viewport.signalBoundaryRadius {
            issues.append(
                MissionDraftIssue(
                    severity: .error,
                    reason: .zoneInvalid,
                    messageKey: "tactical.map.issue.zone_out_of_bounds"
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

    private func unique(_ issues: [MissionDraftIssue]) -> [MissionDraftIssue] {
        var seen = Set<String>()
        return issues.filter { issue in
            seen.insert(issue.id).inserted
        }
    }

    private func previewRouteIntersectsNoFly(
        _ previewRoute: MissionPreviewRoute?,
        zone: MissionZone
    ) -> Bool {
        guard let previewRoute else {
            return false
        }

        for point in previewRoute.points where zone.contains(point, tolerance: -0.05) {
            return true
        }

        for pair in zip(previewRoute.points, previewRoute.points.dropFirst()) {
            if segmentIntersectsCircle(
                from: pair.0,
                to: pair.1,
                center: zone.center,
                radius: max(0.0, zone.radius - 0.05)
            ) {
                return true
            }
        }

        return false
    }

    private func segmentIntersectsCircle(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.0001 else {
            return simd_distance(start, center) <= radius
        }

        let t = simd_dot(center - start, delta) / lengthSquared
        let clampedT = min(1.0, max(0.0, t))
        let closestPoint = start + delta * clampedT
        return simd_distance(closestPoint, center) <= radius
    }
}
