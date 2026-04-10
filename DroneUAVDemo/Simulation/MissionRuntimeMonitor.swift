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
        flightMode: DroneFlightMode
    ) -> MissionRuntimeMonitorReport {
        guard executionState.status == .running,
              let activeTarget = executionState.activeTarget else {
            reset()
            return .idle
        }

        let now = Date()
        if lastObservedTargetID != activeTarget.id {
            lastObservedTargetID = activeTarget.id
            lastObservedDistance = executionState.distanceToActiveTarget
            lastProgressAt = now
            targetMissingObservedAt = nil
            runtimeMismatchObservedAt = nil
        }

        if let distance = executionState.distanceToActiveTarget {
            let previousDistance = lastObservedDistance ?? distance
            if previousDistance - distance >= distanceProgressEpsilon {
                lastProgressAt = now
            }
            lastObservedDistance = distance
        }

        let rawTargetMissing = !missionOwnsTargetSource ||
            currentMarker == nil ||
            !executionState.hasBoundAutopilotTarget
        let rawRuntimeMismatch = missionOwnsTargetSource &&
            currentMarker != nil &&
            executionState.hasBoundAutopilotTarget &&
            (!autoNavigationStatus.isActive || flightMode != .autoPath)
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
                  let distance = executionState.distanceToActiveTarget,
                  distance > 1.4,
                  let lastProgressAt else {
                return false
            }
            return now.timeIntervalSince(lastProgressAt) >= stallTimeout
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
        lastProgressAt = nil
        targetMissingObservedAt = nil
        runtimeMismatchObservedAt = nil
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
