import Foundation
import simd

final class MissionDraftBuilder {
    func setLaunchMode(
        _ launchMode: LaunchMode,
        in draft: MissionDraft
    ) -> MissionDraft {
        var nextDraft = draft
        nextDraft.selectedLaunchMode = launchMode

        if launchMode == .standard {
            return nextDraft
        }

        guard let requiredType = launchMode.defaultLaunchObjectType else {
            return nextDraft
        }

        if let existing = nextDraft.launchObject,
           existing.type != requiredType {
            nextDraft.launchObject = MissionLaunchObject(
                id: existing.id,
                type: requiredType,
                position: existing.position,
                headingDegrees: existing.headingDegrees,
                railAngleDegrees: existing.railAngleDegrees,
                transitionHeadingDegrees: existing.transitionHeadingDegrees
            )
        }

        return nextDraft
    }

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

    func upsertLaunchObject(
        at position: SIMD2<Float>,
        headingDegrees: Float,
        type: MissionLaunchObjectType,
        in draft: MissionDraft,
        viewport: MapViewportState
    ) -> MissionDraft {
        var nextDraft = draft
        let clampedPosition = viewport.clampedToWorld(position)
        let heading = normalizedHeadingDegrees(headingDegrees)
        nextDraft.launchObject = MissionLaunchObject(
            id: nextDraft.launchObject?.id ?? UUID(),
            type: type,
            position: clampedPosition,
            headingDegrees: heading,
            railAngleDegrees: nextDraft.launchObject?.railAngleDegrees ?? defaultRailAngleDegrees(for: type),
            transitionHeadingDegrees: nextDraft.launchObject?.transitionHeadingDegrees ?? heading
        )
        nextDraft.selectedLaunchMode = type.launchMode
        return nextDraft
    }

    func setLaunchHeading(
        _ headingDegrees: Float,
        in draft: MissionDraft
    ) -> MissionDraft {
        var nextDraft = draft
        guard var launchObject = nextDraft.launchObject else {
            return nextDraft
        }
        launchObject.headingDegrees = normalizedHeadingDegrees(headingDegrees)
        if launchObject.transitionHeadingDegrees == nil || launchObject.type == .catapultLine {
            launchObject.transitionHeadingDegrees = launchObject.headingDegrees
        }
        nextDraft.launchObject = launchObject
        return nextDraft
    }

    func clearLaunchObject(from draft: MissionDraft) -> MissionDraft {
        var nextDraft = draft
        nextDraft.launchObject = nil
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

    private func normalizedHeadingDegrees(_ headingDegrees: Float) -> Float {
        var normalized = headingDegrees.truncatingRemainder(dividingBy: 360.0)
        if normalized < 0.0 {
            normalized += 360.0
        }
        return normalized
    }

    private func defaultRailAngleDegrees(for type: MissionLaunchObjectType) -> Float {
        switch type {
        case .catapultLine:
            return 12.0
        case .runwayStrip:
            return 3.0
        case .handLaunchPoint, .vtolStartPoint:
            return 0.0
        }
    }
}
