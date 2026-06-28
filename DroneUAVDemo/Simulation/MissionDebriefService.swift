import Foundation
import simd

struct MissionDebriefInput {
    var timeline: MissionTimeline
    var plan: MissionPlan?
    var executionState: MissionExecutionState
    var statusSnapshot: MissionStatusSnapshot
    var safetyState: MissionSafetyState
    var batteryState: BatteryState
    var payloadState: PayloadState
    var totalDistanceMeters: Float
    var maxAltitudeMeters: Float
    var averageAltitudeMeters: Float
    var startBatteryPercent: Float?
}

final class MissionDebriefService {
    func buildDebrief(from input: MissionDebriefInput) -> MissionDebrief {
        let outcome = resolveOutcome(for: input)
        let timeline = input.timeline
        let routeLength = routeLengthMeters(for: input.plan)
        let missionStartedAt = timeline.events.first(where: { $0.code == .missionStarted })?.timestamp ?? timeline.startedAt
        let missionEndedAt = timeline.endedAt ?? timeline.lastUpdatedAt
        let durationSec = max(0.0, missionEndedAt.timeIntervalSince(missionStartedAt))
        let averageSpeed = durationSec > 0.0 ? input.totalDistanceMeters / Float(durationSec) : 0.0
        let reachedWaypointCount = input.executionState.waypointProgress.filter { $0.state == .completed }.count
        let totalWaypointCount = input.plan?.waypoints.count ?? input.executionState.waypointProgress.count
        let warnings = timeline.events.filter { $0.severity == .warning }
        let criticalEvents = timeline.events.filter { $0.severity == .critical }
        let keyEvents = Array(timeline.events.suffix(12))
        let finalReasonKey = input.executionState.explanations.first?.detailKey
            ?? input.statusSnapshot.primaryExplanation?.detailKey
            ?? outcome.verdictKey

        return MissionDebrief(
            generatedAt: Date(),
            timelineID: timeline.id,
            summary: MissionDebriefSummary(
                outcome: outcome,
                missionTypeKey: missionTypeKey(for: input.plan),
                finalReasonKey: finalReasonKey,
                verdictKey: outcome.verdictKey
            ),
            performance: MissionPerformanceSnapshot(
                durationSec: durationSec,
                routeLengthMeters: routeLength,
                flownDistanceEstimateMeters: max(0.0, input.totalDistanceMeters),
                averageSpeedMps: max(0.0, averageSpeed),
                maxAltitudeMeters: max(0.0, input.maxAltitudeMeters),
                averageAltitudeMeters: max(0.0, input.averageAltitudeMeters)
            ),
            execution: MissionExecutionSummary(
                reachedWaypointCount: reachedWaypointCount,
                totalWaypointCount: totalWaypointCount,
                finalTruthStatusRaw: input.statusSnapshot.truthStatus.rawValue,
                finalExecutionStatusRaw: input.executionState.status.rawValue,
                finalFailsafeModeRaw: input.safetyState.failsafeMode == .none
                    ? nil
                    : input.safetyState.failsafeMode.rawValue
            ),
            energy: MissionEnergySummary(
                startBatteryPercent: input.startBatteryPercent,
                endBatteryPercent: input.batteryState.chargePercent,
                consumedBatteryPercent: input.startBatteryPercent.map { max(0.0, $0 - input.batteryState.chargePercent) },
                batteryUnsafeTriggered: input.safetyState.blockReason == .batteryUnsafe ||
                    timeline.events.contains(where: { $0.code == .returnHomeTriggered && $0.detailKey == "mission.status.reason.battery_unsafe" })
            ),
            payload: MissionPayloadSummary(
                triggeredActionCount: timeline.events.filter { $0.code == .payloadActionTriggered }.count,
                completedActionCount: timeline.events.filter { $0.code == .payloadActionCompleted }.count,
                finalPayloadStateRaw: input.payloadState.rawValue
            ),
            warnings: MissionWarningSnapshot(
                warningCount: warnings.count,
                criticalCount: criticalEvents.count,
                latestWarningKey: warnings.last?.detailKey,
                latestCriticalKey: criticalEvents.last?.detailKey
            ),
            keyEvents: keyEvents
        )
    }

    func resolveOutcome(for input: MissionDebriefInput) -> MissionOutcome {
        if input.statusSnapshot.truthStatus == .completed {
            return input.safetyState.failsafeMode == .none && input.timeline.criticalCount == 0
                ? .success
                : .partialSuccess
        }
        if input.statusSnapshot.truthStatus == .returningHome ||
            input.timeline.events.contains(where: { $0.code == .returnHomeTriggered }) {
            return .returnedHome
        }
        if input.executionState.status == .aborted {
            return input.executionState.abortReason == .operatorRequested
                ? .aborted
                : .safetyTerminated
        }
        if input.executionState.status == .failed || input.statusSnapshot.truthStatus == .failed {
            return .failed
        }
        return input.timeline.criticalCount == 0 ? .partialSuccess : .failed
    }

    private func routeLengthMeters(for plan: MissionPlan?) -> Float {
        guard let plan else {
            return 0.0
        }

        return zip(plan.routePoints, plan.routePoints.dropFirst())
            .reduce(into: 0.0) { partial, pair in
                partial += simd_distance(pair.0, pair.1)
            }
    }

    private func missionTypeKey(for plan: MissionPlan?) -> String {
        guard let plan else {
            return "mission.debrief.type.route"
        }
        if plan.zones.contains(where: { $0.type == .dropZone }) {
            return "mission.debrief.type.delivery"
        }
        return "mission.debrief.type.route"
    }
}
