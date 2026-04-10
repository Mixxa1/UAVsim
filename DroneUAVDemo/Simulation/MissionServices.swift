import Foundation
import simd

struct MissionPlanningContext {
    var homePoint: SIMD3<Float>
    var terrain: TerrainConfiguration
    var obstacles: [CollisionObstacle]
    var droneRadius: Float
    var selectedDroneProfile: DroneModelProfile
    var activeUAVProfile: UAVProfile?
    var payloadState: PayloadState
    var payloadCapabilityCheck: PayloadCapabilityCheck
    var vehicleMassModel: VehicleMassModel
    var batteryState: BatteryState
    var weather: WeatherModel
    var damageState: DamageState
}

struct MissionExecutionInput {
    var executionState: MissionExecutionState
    var missionPlan: MissionPlan?
    var isArmed: Bool
    var flightMode: DroneFlightMode
    var airframeClass: AirframeClass
    var physicalState: DronePhysicalState
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var payloadState: PayloadState
    var batteryState: BatteryState
    var linkState: LinkState
    var inDropZone: Bool
    var isOutsideOperationalBounds: Bool
    var routeAvailable: Bool
    var distanceToActiveWaypoint: Float?
    var distanceRemaining: Float
    var estimatedTimeRemaining: Float
    var hasReachedActiveWaypoint: Bool
}

struct MissionExecutionResult {
    var state: MissionExecutionState
    var requestedCommand: MissionCommand?
    var requestedFailsafe: MissionFailsafeAction?
    var warningKeys: [String]
}

struct MissionDebriefInput {
    var missionPlan: MissionPlan
    var timeline: MissionTimeline?
    var events: [MissionEvent]
    var missionStartTime: TimeInterval
    var missionEndTime: TimeInterval
    var outcome: MissionOutcome
    var executionEndReason: String
    var distanceMeters: Float
    var maxAltitudeMeters: Float
    var averageAltitudeMeters: Float
    var energyConsumedPercent: Float
    var actualBatteryRemainingPercent: Float
    var routeMetrics: MissionRouteMetrics
    var energyEstimate: MissionEnergyEstimate
    var waypointProgress: MissionWaypointProgress
    var finalVehicleState: String
    var payloadTaskStatus: String
    var warnings: [String]
}

private final class MissionEnergyEstimator {
    private let batteryService = BatteryThermalSimulationService()

    func estimate(
        planningState: MissionPlanningState,
        route: MissionRoute,
        context: MissionPlanningContext
    ) -> MissionEnergyEstimate {
        let cruiseSpeed = max(
            3.5,
            min(
                planningState.speedLimitMps ?? context.selectedDroneProfile.maxHorizontalSpeedMps * 0.58,
                context.selectedDroneProfile.maxHorizontalSpeedMps
            )
        )
        let routeDuration = max(route.metrics.estimatedFlightTimeSec, route.metrics.lengthMeters / max(cruiseSpeed, 0.1))
        let missionTaskPenalty: Float
        switch planningState.missionType {
        case .delivery:
            missionTaskPenalty = 38.0
        case .recon, .observation:
            missionTaskPenalty = 24.0
        case .relay:
            missionTaskPenalty = 30.0
        case .freeRoute:
            missionTaskPenalty = 18.0
        }

        let returnReserveFactor: Float = planningState.returnMode == .holdPosition ? 1.06 : 1.18
        let weatherPenaltyFactor = max(1.0, context.weather.effectiveFactors.batteryDrainMultiplier)
        let payloadPenaltyFactor = 1.0 + context.vehicleMassModel.payloadLoadRatio * 0.14
        let missionDuration = (routeDuration + missionTaskPenalty) * returnReserveFactor
        let effectiveDuration = missionDuration * weatherPenaltyFactor * payloadPenaltyFactor

        let baselineThrottle: Float
        switch context.selectedDroneProfile.airframeClass {
        case .fixedWing:
            baselineThrottle = 0.56
        case .multirotor:
            baselineThrottle = 0.62
        }

        let batteryProjection = batteryService.updateBattery(
            current: context.batteryState,
            input: BatteryComputationInput(
                droneProfile: context.selectedDroneProfile,
                weather: context.weather,
                damageState: context.damageState,
                speedMps: cruiseSpeed,
                verticalSpeedMps: planningState.missionType == .delivery ? 1.2 : 0.8,
                throttle: baselineThrottle,
                maneuverAggressiveness: min(1.0, 0.18 + route.metrics.estimatedComplexity * 0.72 + route.metrics.obstacleRiskScore * 0.20)
            ),
            deltaTime: effectiveDuration
        )

        let reserveRequired = max(
            10.0,
            min(
                48.0,
                planningState.reservePercent + (planningState.returnMode == .holdPosition ? -4.0 : 0.0)
            )
        )
        let remainingAfterMission = max(0.0, batteryProjection.chargePercent)
        let predictedConsumption = max(0.0, context.batteryState.chargePercent - remainingAfterMission)
        let safetyMargin = remainingAfterMission - reserveRequired
        let status: MissionFeasibilityStatus
        if safetyMargin >= 10.0 {
            status = .safe
        } else if safetyMargin >= 0.0 {
            status = .marginal
        } else {
            status = .unsafe
        }

        return MissionEnergyEstimate(
            predictedConsumptionPercent: predictedConsumption,
            projectedRemainingPercent: remainingAfterMission,
            safetyReservePercent: reserveRequired,
            estimatedDurationSec: effectiveDuration,
            reserveRequiredPercent: reserveRequired,
            remainingAfterMissionPercent: remainingAfterMission,
            safetyMarginPercent: safetyMargin,
            status: status
        )
    }
}

final class MissionValidationService {
    private let energyEstimator = MissionEnergyEstimator()

    func validatePlan(
        planningState: MissionPlanningState,
        route: MissionRoute,
        context: MissionPlanningContext
    ) -> MissionValidationResult {
        var issues: [MissionValidationIssue] = []
        let routeMetrics = route.metrics
        let routePath = route.validatedPath
        let effectiveWaypoints = resolvedWaypoints(for: planningState)

        if !context.homePoint.x.isFinite || !context.homePoint.y.isFinite || !context.homePoint.z.isFinite {
            issues.append(issue(.error, .missingHomePoint, "mission.validation.home_missing"))
        }

        if effectiveWaypoints.isEmpty {
            issues.append(issue(.error, .missingWaypoints, "mission.validation.no_route"))
        }

        if effectiveWaypoints.count > 1 {
            for index in 1..<effectiveWaypoints.count {
                let distance = simd_distance(effectiveWaypoints[index - 1].position, effectiveWaypoints[index].position)
                if distance < 1.5 {
                    issues.append(issue(.warning, .invalidWaypointSequence, "mission.validation.waypoint_sequence"))
                    break
                }
            }
        }

        if planningState.activeZones.contains(where: { zone in
            if case let .circle(_, radius) = zone.geometry {
                return radius < 2.0
            }
            return zone.contour.count < 3
        }) {
            issues.append(issue(.error, .invalidZoneGeometry, "mission.validation.zone_invalid"))
        }

        if planningState.minAltitudeMeters < 0.0 {
            issues.append(issue(.error, .invalidAltitudeWindow, "mission.validation.altitude_window"))
        }
        if let maxAltitude = planningState.altitudeLimitMeters {
            if maxAltitude <= planningState.minAltitudeMeters || maxAltitude > context.terrain.maxFlightAltitude {
                issues.append(issue(.error, .invalidAltitudeWindow, "mission.validation.altitude_window"))
            }
        }
        if let speedLimit = planningState.speedLimitMps,
           speedLimit <= 0.0 || speedLimit > context.selectedDroneProfile.maxHorizontalSpeedMps {
            issues.append(issue(.error, .invalidSpeedLimit, "mission.validation.speed_limit"))
        }

        if route.plannerStatus == .blocked {
            issues.append(issue(.error, .plannerBlocked, route.blockedReasonKey ?? "mission.preview.blocked.generic"))
        } else if routePath.isEmpty && !effectiveWaypoints.isEmpty {
            issues.append(issue(.error, .plannerBlocked, "mission.validation.no_route"))
        }

        if routePath.contains(where: { point in
            planningState.noFlyZones.contains(where: { $0.contains(SIMD2<Float>(point.x, point.z)) })
        }) {
            issues.append(issue(.error, .routeConflict, "mission.validation.route_conflict"))
        }

        let payloadSummary = buildPayloadSummary(
            planningState: planningState,
            context: context,
            issues: &issues
        )
        let energyEstimate = energyEstimator.estimate(
            planningState: planningState,
            route: route,
            context: context
        )

        switch energyEstimate.status {
        case .safe:
            break
        case .marginal:
            issues.append(issue(.warning, .energyReserveMarginal, "mission.validation.energy_marginal"))
        case .unsafe:
            issues.append(issue(.error, .energyReserveUnsafe, "mission.validation.energy_unsafe"))
        }

        if energyEstimate.remainingAfterMissionPercent < energyEstimate.reserveRequiredPercent {
            issues.append(issue(.error, .returnReserveInsufficient, "mission.validation.return_reserve"))
        }

        if routeMetrics.riskZoneIntersections > 0 {
            issues.append(issue(.warning, .routeConflict, "mission.validation.risk_zone_intersections"))
        }

        if context.weather.severityScore >= 0.6 {
            issues.append(issue(.warning, .weatherPenalty, "mission.validation.weather_penalty"))
        }

        issues = deduplicatedIssues(issues)

        let hasError = issues.contains { $0.severity == .error }
        let hasWarning = issues.contains { $0.severity == .warning }
        let feasibility: MissionFeasibilityStatus
        let planStatus: MissionPlanStatus
        if hasError {
            feasibility = .unsafe
            planStatus = .blocked
        } else if hasWarning || energyEstimate.status == .marginal {
            feasibility = .marginal
            planStatus = .marginal
        } else {
            feasibility = .safe
            planStatus = .ready
        }

        return MissionValidationResult(
            feasibility: feasibility,
            issues: issues,
            routeMetrics: routeMetrics,
            energyEstimate: energyEstimate,
            payloadCheckSummary: payloadSummary,
            isLaunchAllowed: planStatus != .blocked,
            planStatus: planStatus
        )
    }

    private func resolvedWaypoints(for planningState: MissionPlanningState) -> [TargetMarkerState] {
        if planningState.waypoints.isEmpty, let dropZone = planningState.dropZone {
            return [TargetMarkerState(position: dropZone.center)]
        }
        return planningState.waypoints
    }

    private func buildPayloadSummary(
        planningState: MissionPlanningState,
        context: MissionPlanningContext,
        issues: inout [MissionValidationIssue]
    ) -> MissionPayloadCheckSummary {
        let hasPayload = context.payloadState == .attached
        let capabilityAllowed = context.payloadCapabilityCheck.isAllowed
        let payloadMass = context.vehicleMassModel.payloadMass

        if planningState.missionType == .delivery {
            if planningState.dropZone == nil {
                issues.append(issue(.error, .payloadDropUnavailable, "mission.validation.delivery_requires_drop_zone"))
            }
            if !hasPayload {
                issues.append(issue(.error, .payloadRequired, "mission.validation.delivery_requires_payload"))
            }
            if !capabilityAllowed {
                issues.append(issue(.error, .payloadIncompatible, "mission.validation.payload_incompatible"))
            }
        } else if hasPayload && !capabilityAllowed {
            issues.append(issue(.warning, .payloadIncompatible, "mission.validation.payload_incompatible"))
        }

        let summaryKey: String
        if planningState.missionType == .delivery && !hasPayload {
            summaryKey = "mission.payload.summary.delivery_missing"
        } else if hasPayload && capabilityAllowed {
            summaryKey = "mission.payload.summary.ready"
        } else if hasPayload {
            summaryKey = context.payloadCapabilityCheck.rejectReason?.messageKey ?? "mission.payload.summary.incompatible"
        } else {
            summaryKey = "mission.payload.summary.none"
        }

        return MissionPayloadCheckSummary(
            isConfigured: hasPayload,
            isCapable: capabilityAllowed || planningState.missionType != .delivery,
            payloadMassKg: payloadMass,
            summaryKey: summaryKey
        )
    }

    private func deduplicatedIssues(_ issues: [MissionValidationIssue]) -> [MissionValidationIssue] {
        var seen: Set<String> = []
        var output: [MissionValidationIssue] = []
        for issue in issues {
            let token = "\(issue.severity.rawValue):\(issue.code.rawValue):\(issue.message)"
            guard !seen.contains(token) else {
                continue
            }
            seen.insert(token)
            output.append(issue)
        }
        return output
    }

    private func issue(
        _ severity: MissionValidationIssueSeverity,
        _ code: MissionValidationIssueCode,
        _ message: String
    ) -> MissionValidationIssue {
        MissionValidationIssue(
            severity: severity,
            code: code,
            message: message
        )
    }
}

final class MissionEventRecorder {
    private var standaloneEvents: [MissionEvent] = []
    private(set) var activeTimeline: MissionTimeline?
    private(set) var latestCriticalEvent: MissionEvent?
    private var emittedTokens: Set<String> = []

    func reset() {
        standaloneEvents.removeAll(keepingCapacity: false)
        activeTimeline = nil
        latestCriticalEvent = nil
        emittedTokens.removeAll(keepingCapacity: false)
    }

    func importHistory(events: [MissionEvent], timeline: MissionTimeline?) {
        activeTimeline = timeline
        standaloneEvents = timeline == nil ? events : []
        latestCriticalEvent = (timeline?.events ?? events).last(where: { $0.severity == .critical })
        emittedTokens.removeAll(keepingCapacity: false)
    }

    var eventsSnapshot: [MissionEvent] {
        activeTimeline?.events ?? standaloneEvents
    }

    func beginTimeline(for plan: MissionPlan, at startedAt: Date) {
        let seedEvents = activeTimeline?.events ?? standaloneEvents
        activeTimeline = MissionTimeline(
            id: UUID(),
            missionID: UUID(),
            planID: plan.id,
            missionType: plan.missionType,
            startedAt: startedAt,
            endedAt: nil,
            outcome: nil,
            events: seedEvents
        )
        standaloneEvents.removeAll(keepingCapacity: false)
        latestCriticalEvent = activeTimeline?.latestCriticalEvent
        emittedTokens.removeAll(keepingCapacity: false)
    }

    @discardableResult
    func finishTimeline(outcome: MissionOutcome, at endedAt: Date) -> MissionTimeline? {
        guard var activeTimeline else { return nil }
        activeTimeline.endedAt = endedAt
        activeTimeline.outcome = outcome
        self.activeTimeline = activeTimeline
        latestCriticalEvent = activeTimeline.latestCriticalEvent
        return activeTimeline
    }

    @discardableResult
    func record(
        severity: MissionEventSeverity,
        category: MissionEventCategory,
        code: String,
        title: String,
        message: String,
        payload: [String: String]? = nil,
        context: MissionEventContext? = nil,
        dedupeToken: String? = nil
    ) -> MissionEvent? {
        if let dedupeToken {
            guard !emittedTokens.contains(dedupeToken) else {
                return nil
            }
            emittedTokens.insert(dedupeToken)
        }

        let event = MissionEvent(
            severity: severity,
            category: category,
            code: code,
            title: title,
            message: message,
            payload: payload,
            context: context
        )

        if activeTimeline != nil {
            activeTimeline?.events.append(event)
            trim(events: &activeTimeline!.events)
        } else {
            standaloneEvents.append(event)
            trim(events: &standaloneEvents)
        }

        if severity == .critical {
            latestCriticalEvent = event
        }

        return event
    }

    func clearToken(_ token: String) {
        emittedTokens.remove(token)
    }

    private func trim(events: inout [MissionEvent]) {
        if events.count > 256 {
            events.removeFirst(events.count - 256)
        }
    }
}

final class MissionDebriefService {
    func buildDebrief(from input: MissionDebriefInput) -> MissionDebrief {
        let effectiveEvents = input.timeline?.events ?? input.events
        let warningEvents = effectiveEvents
            .filter { $0.severity == .warning }
            .map(\.message)
        let criticalEvents = effectiveEvents
            .filter { $0.severity == .critical }
            .map(\.message)
        let missionDuration = max(0.0, input.missionEndTime - input.missionStartTime)
        let averageSpeed = missionDuration > 0.0 ? input.distanceMeters / Float(missionDuration) : 0.0
        let condensedEvents = effectiveEvents.filter { $0.severity != .info }.suffix(10)
        let outcome: MissionOutcome
        switch input.outcome {
        case .success where !criticalEvents.isEmpty:
            outcome = .partialSuccess
        default:
            outcome = input.outcome
        }
        let keyWarnings = Array(
            NSOrderedSet(array: input.warnings + warningEvents + criticalEvents)
        ) as? [String] ?? (input.warnings + warningEvents + criticalEvents)

        return MissionDebrief(
            generatedAt: Date(),
            summary: MissionDebriefSummary(
                outcome: outcome,
                missionType: input.missionPlan.missionType,
                executionEndReason: input.executionEndReason,
                verdictKey: outcome.verdictKey,
                keyWarnings: Array(keyWarnings.prefix(6))
            ),
            performanceSnapshot: MissionPerformanceSnapshot(
                totalDistanceFlownMeters: max(0.0, input.distanceMeters),
                missionDurationSec: missionDuration,
                averageSpeedMps: max(0.0, averageSpeed),
                maxAltitudeMeters: max(0.0, input.maxAltitudeMeters),
                averageAltitudeMeters: max(0.0, input.averageAltitudeMeters),
                estimatedEnergyUsedPercent: max(0.0, input.energyConsumedPercent),
                predictedEnergyUsedPercent: max(0.0, input.energyEstimate.predictedConsumptionPercent),
                reachedWaypointCount: input.waypointProgress.reachedCount,
                totalWaypointCount: input.waypointProgress.totalCount,
                payloadActionPerformed: input.payloadTaskStatus != NSLocalizedString("mission.debrief.payload.not_started", comment: ""),
                warningsCount: warningEvents.count,
                criticalCount: criticalEvents.count
            ),
            condensedEvents: Array(condensedEvents),
            routeMetrics: input.routeMetrics,
            energyEstimate: input.energyEstimate,
            actualEnergyConsumedPercent: max(0.0, input.energyConsumedPercent),
            payloadSummary: input.payloadTaskStatus,
            diagnosticsSummary: [
                "battery.remaining.\(Int(input.actualBatteryRemainingPercent.rounded()))",
                "critical.count.\(criticalEvents.count)",
                "warning.count.\(warningEvents.count)"
            ],
            finalVehicleState: input.finalVehicleState
        )
    }
}

final class LinkAssessmentService {
    func assess(
        position: SIMD3<Float>,
        home: SIMD3<Float>,
        terrain: TerrainConfiguration,
        zones: [MissionZone],
        obstacles: [CollisionObstacle]
    ) -> LinkState {
        let horizontalDistance = simd_length(SIMD2<Float>(position.x - home.x, position.z - home.z))
        let boundary = max(40.0, terrain.signalBoundaryRadius)
        var state: LinkState

        let distanceRatio = horizontalDistance / boundary
        switch distanceRatio {
        case ..<0.72:
            state = .nominal
        case ..<0.84:
            state = .degraded
        case ..<0.96:
            state = .critical
        default:
            state = .lost
        }

        let planarPosition = SIMD2<Float>(position.x, position.z)
        if zones.contains(where: { $0.isActive && ($0.type == .signalRiskZone || $0.type == .cautionZone) && $0.contains(planarPosition) }) {
            state = worsened(state)
        }

        let lineObstacles = obstacles.filter { obstacle in
            distanceFromPoint(
                SIMD2<Float>(obstacle.center.x, obstacle.center.z),
                toSegmentStart: SIMD2<Float>(home.x, home.z),
                end: planarPosition
            ) <= max(3.0, obstacle.radius * 1.35)
        }
        if lineObstacles.count >= 4 {
            state = worsened(state)
        }

        return state
    }

    private func worsened(_ state: LinkState) -> LinkState {
        switch state {
        case .nominal:
            return .degraded
        case .degraded:
            return .critical
        case .critical, .lost:
            return .lost
        }
    }

    private func distanceFromPoint(
        _ point: SIMD2<Float>,
        toSegmentStart start: SIMD2<Float>,
        end: SIMD2<Float>
    ) -> Float {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        if lengthSquared < 0.0001 {
            return simd_distance(point, start)
        }
        let t = simd_dot(point - start, delta) / lengthSquared
        let clamped = max(0.0, min(1.0, t))
        let projection = start + delta * clamped
        return simd_distance(point, projection)
    }
}



