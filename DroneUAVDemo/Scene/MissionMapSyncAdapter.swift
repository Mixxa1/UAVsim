import Foundation
import simd

struct MissionSceneOverlayState: Equatable {
    var validatedRoute: [SIMD3<Float>]
    var waypoints: [TargetMarkerState]
    var zones: [MissionZone]
    var activeSegment: MissionRouteSegment?
    var activeWaypointIndex: Int?
    var reachedWaypointCount: Int
    var isVisible: Bool

    static let empty = MissionSceneOverlayState(
        validatedRoute: [],
        waypoints: [],
        zones: [],
        activeSegment: nil,
        activeWaypointIndex: nil,
        reachedWaypointCount: 0,
        isVisible: false
    )
}

final class MissionMapSyncAdapter {
    func makeSceneOverlayState(from mapState: TacticalMapState) -> MissionSceneOverlayState {
        let validatedRoute = mapState.routeState.validatedRoute?.polyline ?? []
        let waypoints: [TargetMarkerState] = {
            if mapState.routeState.validatedRoute != nil {
                return mapState.validatedPlan?.waypoints ?? mapState.committedDraft.waypoints
            }
            return mapState.committedDraft.waypoints
        }()
        let zones = mapState.zoneState.zones.filter { $0.type != .dropZone }
        let isVisible =
            !validatedRoute.isEmpty ||
            !waypoints.isEmpty ||
            !zones.isEmpty ||
            mapState.routeState.activeSegment != nil

        return MissionSceneOverlayState(
            validatedRoute: validatedRoute,
            waypoints: waypoints,
            zones: zones,
            activeSegment: mapState.routeState.activeSegment?.segment,
            activeWaypointIndex: mapState.routeState.activeWaypointIndex,
            reachedWaypointCount: mapState.routeState.reachedWaypointCount,
            isVisible: isVisible
        )
    }
}
