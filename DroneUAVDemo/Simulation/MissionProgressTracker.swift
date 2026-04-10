import Foundation
import simd

struct MissionProgressUpdate: Equatable {
    var distanceToActiveTarget: Float?
    var hasReachedActiveTarget: Bool
    var hasBoundTarget: Bool
}

final class MissionProgressTracker {
    func evaluate(
        executionState: MissionExecutionState,
        planarPosition: SIMD2<Float>,
        currentMarker: TargetMarkerState?,
        autoNavigationStatus: AutoNavigationStatus,
        flightMode: DroneFlightMode,
        airframeClass: AirframeClass,
        adapter: MissionAutopilotAdapter
    ) -> MissionProgressUpdate {
        guard let activeTarget = executionState.activeTarget else {
            return MissionProgressUpdate(
                distanceToActiveTarget: nil,
                hasReachedActiveTarget: false,
                hasBoundTarget: false
            )
        }

        let distance = simd_distance(planarPosition, activeTarget.position)
        let arrivalRadius: Float = {
            switch airframeClass {
            case .multirotor:
                return 0.95
            case .fixedWing:
                return 5.8
            }
        }()
        let hasBoundTarget = adapter.isBound(
            activeTarget: activeTarget,
            currentMarker: currentMarker
        )
        let autopilotSettled = !autoNavigationStatus.isActive || autoNavigationStatus.phase == .hold || flightMode != .autoPath
        let hasReachedActiveTarget = hasBoundTarget &&
            distance <= arrivalRadius &&
            autopilotSettled

        return MissionProgressUpdate(
            distanceToActiveTarget: distance,
            hasReachedActiveTarget: hasReachedActiveTarget,
            hasBoundTarget: hasBoundTarget
        )
    }
}
