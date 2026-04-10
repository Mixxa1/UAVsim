import Foundation
import simd

final class MissionDraftBuilder {
    func addWaypoint(
        at position: SIMD2<Float>,
        to draft: MissionDraft,
        viewport: MapViewportState
    ) -> MissionDraft {
        var nextDraft = draft
        guard nextDraft.waypoints.count < nextDraft.constraints.maxWaypointCount else {
            return nextDraft
        }

        let clamped = viewport.clampedToWorld(position)
        nextDraft.waypoints.append(
            MissionWaypoint(index: nextDraft.waypoints.count, position: clamped)
        )
        nextDraft.waypoints = reindexed(nextDraft.waypoints)
        return nextDraft
    }

    func removeLastWaypoint(from draft: MissionDraft) -> MissionDraft {
        var nextDraft = draft
        guard !nextDraft.waypoints.isEmpty else {
            return nextDraft
        }

        nextDraft.waypoints.removeLast()
        nextDraft.waypoints = reindexed(nextDraft.waypoints)
        return nextDraft
    }

    func clearRoute(from draft: MissionDraft) -> MissionDraft {
        var nextDraft = draft
        nextDraft.waypoints = []
        return nextDraft
    }

    func clearZones(from draft: MissionDraft) -> MissionDraft {
        var nextDraft = draft
        nextDraft.zones = []
        return nextDraft
    }

    func upsertZone(
        type: MissionZoneType,
        center: SIMD2<Float>,
        in draft: MissionDraft,
        viewport: MapViewportState
    ) -> MissionDraft {
        var nextDraft = draft
        let clampedCenter = viewport.clampedToWorld(center)
        let defaultRadius = defaultRadius(for: draft, viewport: viewport)

        if type == .noFlyZone {
            nextDraft.zones.append(
                MissionZone(
                    type: type,
                    center: clampedCenter,
                    radius: defaultRadius
                )
            )
            return nextDraft
        }

        if let index = nextDraft.zones.firstIndex(where: { $0.type == type }) {
            nextDraft.zones[index].center = clampedCenter
            if nextDraft.zones[index].radius <= 0.0 {
                nextDraft.zones[index].radius = defaultRadius
            }
        } else {
            nextDraft.zones.append(
                MissionZone(
                    type: type,
                    center: clampedCenter,
                    radius: defaultRadius
                )
            )
        }

        return nextDraft
    }

    func setZoneRadius(
        _ radius: Float,
        for type: MissionZoneType,
        in draft: MissionDraft,
        viewport: MapViewportState
    ) -> MissionDraft {
        var nextDraft = draft
        guard let index = nextDraft.zones.lastIndex(where: { $0.type == type }) else {
            return nextDraft
        }

        let maxRadius = draft.constraints.maximumZoneRadius(for: viewport)
        nextDraft.zones[index].radius = min(
            max(radius, draft.constraints.minimumZoneRadius),
            maxRadius
        )
        return nextDraft
    }

    private func reindexed(_ waypoints: [MissionWaypoint]) -> [MissionWaypoint] {
        waypoints.enumerated().map { index, waypoint in
            MissionWaypoint(id: waypoint.id, index: index, position: waypoint.position)
        }
    }

    private func defaultRadius(
        for draft: MissionDraft,
        viewport: MapViewportState
    ) -> Float {
        min(
            max(8.0, draft.constraints.minimumZoneRadius),
            draft.constraints.maximumZoneRadius(for: viewport)
        )
    }
}
