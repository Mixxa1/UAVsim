import Foundation
import simd

struct MissionPlanValidation: Equatable {
    var status: MissionPlanStatus
    var explanations: [MissionStatusExplanation]
}

final class MissionPlanValidator {
    func validate(
        draft: MissionDraft,
        previewRoute: MissionPreviewRoute?,
        launchPreview: MissionLaunchPreview? = nil,
        viewport: MapViewportState,
        fixedWingParameters: FixedWingParameters? = nil,
        supportedLaunchModes: [LaunchMode] = LaunchMode.allCases
    ) -> MissionPlanValidation {
        guard draft.hasContent else {
            return MissionPlanValidation(
                status: .draft,
                explanations: [
                    MissionStatusExplanation(
                        reason: .draftEmpty,
                        severity: .info,
                        detailKey: "mission.status.reason.draft_empty",
                        isBlocking: false
                    )
                ]
            )
        }

        var explanations: [MissionStatusExplanation] = []

        if draft.waypoints.isEmpty {
            explanations.append(
                MissionStatusExplanation(
                    reason: .routeInvalid,
                    severity: .critical,
                    detailKey: "mission.status.reason.route_missing"
                )
            )
        }

        if !draft.selectedLaunchMode.isRuntimeImplemented ||
            !supportedLaunchModes.contains(draft.selectedLaunchMode) {
            explanations.append(
                MissionStatusExplanation(
                    reason: .routeInvalid,
                    severity: .critical,
                    detailKey: "tactical.map.issue.launch_mode_unsupported"
                )
            )
        } else if draft.selectedLaunchMode.requiresLaunchObject,
           let launchExplanation = validateLaunchObject(
                draft: draft,
                launchPreview: launchPreview,
                viewport: viewport,
                fixedWingParameters: fixedWingParameters
           ) {
            explanations.append(launchExplanation)
        }

        if previewRoute == nil || (previewRoute?.executionPoints.count ?? 0) < 2 {
            explanations.append(
                MissionStatusExplanation(
                    reason: .previewUnavailable,
                    severity: .critical,
                    detailKey: "mission.status.reason.preview_unavailable"
                )
            )
        }

        if draft.waypoints.count > 1 {
            for pair in zip(draft.waypoints, draft.waypoints.dropFirst()) {
                if simd_distance(pair.0.position, pair.1.position) < 0.25 {
                    explanations.append(
                        MissionStatusExplanation(
                            reason: .routeInvalid,
                            severity: .critical,
                            detailKey: "mission.status.reason.route_invalid"
                        )
                    )
                    break
                }
            }
        }

        let executionCeiling = max(2.0, viewport.terrainMaxAltitudeMeters - 2.0)
        if draft.constraints.altitude.minimumMeters < 0.0 ||
            draft.constraints.altitude.maximumMeters <= 0.0 ||
            draft.constraints.altitude.maximumMeters < draft.constraints.altitude.minimumMeters {
            explanations.append(
                MissionStatusExplanation(
                    reason: .invalidAltitudeWindow,
                    severity: .critical,
                    detailKey: "mission.status.reason.invalid_altitude_window"
                )
            )
        } else {
            let baselineAltitude = draft.constraints.baselineTravelAltitude(
                currentAltitude: viewport.droneAltitudeMeters,
                dockAltitude: viewport.dockAltitudeMeters,
                terrainMaxAltitude: executionCeiling,
                airframeClass: viewport.airframeClass
            )
            let altitudeWindow = draft.constraints.altitude.clamped(to: executionCeiling)
            if baselineAltitude < altitudeWindow.lowerBound - 0.05 ||
                baselineAltitude > altitudeWindow.upperBound + 0.05 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .targetAltitudeOutOfRange,
                        severity: .critical,
                        detailKey: "mission.status.reason.target_altitude_out_of_range"
                    )
                )
            } else if draft.constraints.altitude.hasCustomWindow(terrainMaxAltitude: executionCeiling) {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .altitudeConstraintsApplied,
                        severity: .info,
                        detailKey: "mission.status.reason.altitude_constraints_applied",
                        isBlocking: false
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
            explanations.append(
                MissionStatusExplanation(
                    reason: .invalidSpeedWindow,
                    severity: .critical,
                    detailKey: "mission.status.reason.invalid_speed_window"
                )
            )
        } else {
            if viewport.profileMaxHorizontalSpeedMps > 0.0 &&
                draft.constraints.speed.hasCustomMaximum(
                    profileMaxSpeed: viewport.profileMaxHorizontalSpeedMps
                ) {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .speedMaxConstraintApplied,
                        severity: .info,
                        detailKey: "mission.status.reason.speed_max_constraint_applied",
                        isBlocking: false
                    )
                )
            }
            if draft.constraints.speed.minimumMetersPerSecond > 0.05 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .speedMinConstraintAdvisory,
                        severity: .warning,
                        detailKey: "mission.status.reason.speed_min_constraint_advisory",
                        isBlocking: false
                    )
                )
            }
        }

        let maxZoneRadius = draft.constraints.maximumZoneRadius(for: viewport)
        for zone in draft.zones {
            if zone.radius < draft.constraints.minimumZoneRadius || zone.radius > maxZoneRadius {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .zoneInvalid,
                        severity: .critical,
                        detailKey: "mission.status.reason.zone_invalid"
                    )
                )
                break
            }

            if !viewport.isWithinWorldBounds(zone.center, tolerance: 0.05) {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .zoneInvalid,
                        severity: .critical,
                        detailKey: "mission.status.reason.zone_invalid"
                    )
                )
                break
            }
        }

        if let previewRoute {
            let routeDistanceWithReturn = previewRoute.totalLengthMeters +
                missionReturnDistance(previewRoute: previewRoute, viewport: viewport)
            let furthestMissionRadius = maxMissionRadius(draft: draft, previewRoute: previewRoute, viewport: viewport)

            if routeDistanceWithReturn > viewport.estimatedSafeReturnRangeM + 0.05 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .batteryUnsafe,
                        severity: .critical,
                        detailKey: "mission.status.reason.route_exceeds_safe_return"
                    )
                )
            } else if routeDistanceWithReturn > viewport.estimatedSafeReturnRangeM * 0.86 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .batteryUnsafe,
                        severity: .warning,
                        detailKey: "mission.status.reason.route_margin_tight",
                        isBlocking: false
                    )
                )
            }

            if furthestMissionRadius > viewport.operationalRadius + 0.05 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .routeInvalid,
                        severity: .warning,
                        detailKey: "mission.status.reason.route_exceeds_operational_radius",
                        isBlocking: false
                    )
                )
            }

            if furthestMissionRadius > viewport.degradedLinkRadius + 0.05 {
                explanations.append(
                    MissionStatusExplanation(
                        reason: .runtimeUnsafe,
                        severity: .warning,
                        detailKey: "mission.status.reason.link_degraded",
                        isBlocking: false
                    )
                )
            }
        }

        if viewport.currentMapSuitability == .tight {
            explanations.append(
                MissionStatusExplanation(
                    reason: .routeInvalid,
                    severity: .warning,
                    detailKey: "mission.status.reason.map_tight",
                    isBlocking: false
                )
            )
        } else if viewport.currentMapSuitability == .unsuitable {
            explanations.append(
                MissionStatusExplanation(
                    reason: .routeInvalid,
                    severity: .warning,
                    detailKey: "mission.status.reason.map_unsuitable",
                    isBlocking: false
                )
            )
        }

        explanations = unique(explanations)
        let status: MissionPlanStatus = explanations.contains(where: \.isBlocking) ? .invalid : .validated
        return MissionPlanValidation(
            status: status,
            explanations: explanations
        )
    }

    private func validateLaunchObject(
        draft: MissionDraft,
        launchPreview: MissionLaunchPreview?,
        viewport: MapViewportState,
        fixedWingParameters: FixedWingParameters?
    ) -> MissionStatusExplanation? {
        guard let launchObject = draft.launchObject else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_object_required"
            )
        }

        guard launchObject.type.launchMode == draft.selectedLaunchMode else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_object_type_mismatch"
            )
        }

        guard launchObject.headingDegrees.isFinite,
              launchObject.railAngleDegrees.isFinite else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_geometry_invalid"
            )
        }

        guard launchObject.type.launchAngleRange.contains(launchObject.railAngleDegrees) else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_angle_invalid"
            )
        }
        if let fixedWingParameters {
            let profileAngle = draft.selectedLaunchMode == .handLaunch
                ? fixedWingParameters.handLaunchAngleDegrees
                : fixedWingParameters.catapultRailAngleDegrees
            guard profileAngle.isFinite else {
                return MissionStatusExplanation(
                    reason: .routeInvalid,
                    severity: .critical,
                    detailKey: "tactical.map.issue.launch_angle_invalid"
                )
            }
        }

        if !viewport.isWithinWorldBounds(launchObject.position, tolerance: 0.05) {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_object_out_of_bounds"
            )
        }

        guard let launchPreview else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_geometry_invalid"
            )
        }
        guard launchPreview.isWithinWorldBounds else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_corridor_invalid"
            )
        }
        guard launchPreview.hasSafeEdgeMargin else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_space_insufficient"
            )
        }
        guard launchPreview.avoidsNoFlyZones else {
            return MissionStatusExplanation(
                reason: .routeInvalid,
                severity: .critical,
                detailKey: "tactical.map.issue.launch_corridor_no_fly"
            )
        }

        return nil
    }

    private func unique(_ explanations: [MissionStatusExplanation]) -> [MissionStatusExplanation] {
        var seen = Set<String>()
        return explanations.filter { explanation in
            seen.insert(explanation.id).inserted
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
