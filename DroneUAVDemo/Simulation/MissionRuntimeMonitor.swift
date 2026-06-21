import Foundation

struct MissionRuntimeMonitorReport: Equatable {
    var isTargetMissing: Bool
    var isStalled: Bool
    var isRuntimeMismatch: Bool
    var progressHealthy: Bool
    var warnings: [MissionWarning]

    static let idle = MissionRuntimeMonitorReport(
        isTargetMissing: false,
        isStalled: false,
        isRuntimeMismatch: false,
        progressHealthy: true,
        warnings: []
    )
}

final class MissionRuntimeMonitor {
    private let stallTimeout: TimeInterval
    private let distanceProgressEpsilon: Float
    private let targetMissingConfirmationDelay: TimeInterval
    private let runtimeMismatchConfirmationDelay: TimeInterval
    private var lastObservedTargetID: UUID?
    private var lastObservedDistance: Float?
    private var closestObservedDistance: Float?
    private var lastProgressAt: Date?
    private var targetMissingObservedAt: Date?
    private var runtimeMismatchObservedAt: Date?

    init(
        stallTimeout: TimeInterval = 6.0,
        distanceProgressEpsilon: Float = 0.35,
        targetMissingConfirmationDelay: TimeInterval = 0.8,
        runtimeMismatchConfirmationDelay: TimeInterval = 1.2
    ) {
        self.stallTimeout = max(2.0, stallTimeout)
        self.distanceProgressEpsilon = max(0.05, distanceProgressEpsilon)
        self.targetMissingConfirmationDelay = max(0.15, targetMissingConfirmationDelay)
        self.runtimeMismatchConfirmationDelay = max(0.2, runtimeMismatchConfirmationDelay)
    }

    func evaluate(
        executionState: MissionExecutionState,
        autoNavigationStatus: AutoNavigationStatus,
        currentMarker: TargetMarkerState?,
        missionOwnsTargetSource: Bool,
        flightMode: DroneFlightMode,
        launchState: LaunchState,
        airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?,
        fixedWingDebugState: FixedWingAutopilotDebugState?
    ) -> MissionRuntimeMonitorReport {
        guard executionState.status == .running,
              let activeTarget = executionState.activeTarget else {
            reset()
            return .idle
        }

        let now = Date()
        let fixedWingRouteActive = airframeClass == .fixedWing &&
            isFixedWingRouteActive(debugState: fixedWingDebugState)
        let observedDistance: Float? = {
            guard airframeClass == .fixedWing,
                  fixedWingRouteActive,
                  let fixedWingDebugState else {
                return executionState.distanceToActiveTarget
            }
            return max(0.0, fixedWingDebugState.remainingDistance)
        }()
        if lastObservedTargetID != activeTarget.id {
            lastObservedTargetID = activeTarget.id
            lastObservedDistance = observedDistance
            closestObservedDistance = observedDistance
            lastProgressAt = now
            targetMissingObservedAt = nil
            runtimeMismatchObservedAt = nil
        }

        if let distance = observedDistance {
            let previousDistance = lastObservedDistance ?? distance
            let previousClosest = closestObservedDistance ?? distance
            let progressEpsilon = effectiveProgressEpsilon(for: airframeClass)
            if previousDistance - distance >= progressEpsilon || previousClosest - distance >= progressEpsilon {
                lastProgressAt = now
            }
            if distance < previousClosest {
                closestObservedDistance = distance
            }
            if airframeClass == .fixedWing,
               autoNavigationStatus.phase == .approach,
               distance <= fixedWingFlyByDistanceWindow(fixedWingParameters: fixedWingParameters) {
                lastProgressAt = now
            }
            lastObservedDistance = distance
        }
        if airframeClass == .fixedWing,
           let fixedWingDebugState,
           fixedWingDebugState.currentWaypointIndex > activeTarget.index {
            lastProgressAt = now
        }

        let rawTargetMissing: Bool = {
            if airframeClass == .fixedWing {
                return !missionOwnsTargetSource || !fixedWingRouteActive
            }
            return !missionOwnsTargetSource ||
                currentMarker == nil ||
                !executionState.hasBoundAutopilotTarget
        }()
        let launchCorridorActive = flightMode == .takeoff || launchState.blocksRouteCapture
        let rawRuntimeMismatch: Bool = {
            guard !launchCorridorActive, missionOwnsTargetSource else {
                return false
            }
            if airframeClass == .fixedWing {
                return !fixedWingRouteActive || flightMode != .autoPath
            }
            return currentMarker != nil &&
                executionState.hasBoundAutopilotTarget &&
                (!autoNavigationStatus.isActive || flightMode != .autoPath)
        }()
        let isTargetMissing = confirmedState(
            isDetected: rawTargetMissing,
            observedAt: &targetMissingObservedAt,
            now: now,
            delay: targetMissingConfirmationDelay
        )
        let isRuntimeMismatch = confirmedState(
            isDetected: rawRuntimeMismatch,
            observedAt: &runtimeMismatchObservedAt,
            now: now,
            delay: runtimeMismatchConfirmationDelay
        )
        let isStalled: Bool = {
            guard !isTargetMissing,
                  let distance = observedDistance,
                  distance > 1.4,
                  let lastProgressAt else {
                return false
            }
            if airframeClass == .fixedWing {
                let flyByDistanceWindow = fixedWingFlyByDistanceWindow(fixedWingParameters: fixedWingParameters)
                let distanceSlack = fixedWingDistanceSlack(fixedWingParameters: fixedWingParameters)
                if launchCorridorActive {
                    return false
                }
                if autoNavigationStatus.phase == .approach && distance <= flyByDistanceWindow {
                    return false
                }
                if let fixedWingDebugState,
                   fixedWingDebugState.missionState == .loitering ||
                    fixedWingDebugState.missionState == .completed {
                    return false
                }
                if let closestObservedDistance,
                   distance <= closestObservedDistance + distanceSlack {
                    return false
                }
            }
            return now.timeIntervalSince(lastProgressAt) >= effectiveStallTimeout(
                for: airframeClass,
                fixedWingParameters: fixedWingParameters
            )
        }()

        var warnings: [MissionWarning] = []
        if isTargetMissing {
            warnings.append(
                MissionWarning(
                    reason: .noMissionTarget,
                    severity: .critical,
                    detailKey: "mission.status.reason.no_mission_target"
                )
            )
        }
        if isRuntimeMismatch {
            warnings.append(
                MissionWarning(
                    reason: .unknownRuntimeMismatch,
                    severity: .warning,
                    detailKey: "mission.status.reason.unknown_runtime_mismatch"
                )
            )
        }
        if isStalled {
            warnings.append(
                MissionWarning(
                    reason: .runtimeStallDetected,
                    severity: .critical,
                    detailKey: "mission.status.reason.runtime_stall_detected"
                )
            )
        }

        return MissionRuntimeMonitorReport(
            isTargetMissing: isTargetMissing,
            isStalled: isStalled,
            isRuntimeMismatch: isRuntimeMismatch,
            progressHealthy: !(isStalled || isRuntimeMismatch),
            warnings: unique(warnings)
        )
    }

    func reset() {
        lastObservedTargetID = nil
        lastObservedDistance = nil
        closestObservedDistance = nil
        lastProgressAt = nil
        targetMissingObservedAt = nil
        runtimeMismatchObservedAt = nil
    }

    private func effectiveProgressEpsilon(for airframeClass: AirframeClass) -> Float {
        switch airframeClass {
        case .multirotor:
            return distanceProgressEpsilon
        case .fixedWing:
            return max(0.14, distanceProgressEpsilon * 0.55)
        }
    }

    private func effectiveStallTimeout(
        for airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?
    ) -> TimeInterval {
        switch airframeClass {
        case .multirotor:
            return stallTimeout
        case .fixedWing:
            let wing = resolvedFixedWingParameters(fixedWingParameters)
            let baseTurnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseSpeedMps)
            let turnTime = Double((baseTurnRadius * .pi) / max(wing.cruiseSpeedMps, 1.0))
            return max(stallTimeout + 4.0, min(14.0, turnTime + 5.0))
        }
    }

    private func fixedWingFlyByDistanceWindow(
        fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseSpeedMps)
        return max(turnRadius * 1.35, wing.waypointAcceptanceRadiusMeters * 2.2)
    }

    private func fixedWingDistanceSlack(
        fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseSpeedMps)
        return max(turnRadius * 0.55, wing.waypointAcceptanceRadiusMeters * 0.75)
    }

    private func resolvedFixedWingParameters(
        _ fixedWingParameters: FixedWingParameters?
    ) -> FixedWingParameters {
        fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
    }

    private func isFixedWingRouteActive(
        debugState: FixedWingAutopilotDebugState?
    ) -> Bool {
        guard let debugState else {
            return false
        }
        switch debugState.missionState {
        case .idle, .failed:
            return false
        case .aligningToLaunch,
             .climbout,
             .capturingLeg,
             .trackingLeg,
             .flyByTurn,
             .loitering,
             .completed,
             .recoveringSpeed:
            return true
        }
    }

    private func confirmedState(
        isDetected: Bool,
        observedAt: inout Date?,
        now: Date,
        delay: TimeInterval
    ) -> Bool {
        guard isDetected else {
            observedAt = nil
            return false
        }
        if observedAt == nil {
            observedAt = now
        }
        let duration = now.timeIntervalSince(observedAt ?? now)
        return duration >= delay
    }

    private func unique(_ warnings: [MissionWarning]) -> [MissionWarning] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0.id).inserted }
    }
}
