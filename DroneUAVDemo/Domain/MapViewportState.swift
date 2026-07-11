import Foundation
import simd

/// Distance to the edge of the *authored/detailed* map — a purely visual-detail concept. Crossing
/// `.outside` is a benign notice (the procedural outer belt continues the world); it does not
/// mean radio signal is lost and does not mean a mission geofence has been breached — those are
/// separate, independent concepts (see the radio link-quality zones on `MissionOperationalStatus`
/// and `MissionGeofenceConfiguration`).
enum WorldDetailBoundaryState: String, Equatable {
    case nominal
    case warning
    case critical
    case outside

    var title: String {
        NSLocalizedString("tactical.map.geofence.\(rawValue)", comment: "")
    }
}

enum MapBoundaryDirection: String, Equatable {
    case north
    case south
    case east
    case west

    var title: String {
        NSLocalizedString("tactical.map.direction.\(rawValue)", comment: "")
    }
}

struct MapViewportState: Equatable {
    static let tacticalSectorDivisions = 6

    var center: SIMD2<Float>
    var mapScale: MapScale
    var worldHalfExtent: Float
    var worldPhysicalScale: Float
    var operationalRadius: Float
    var linkQualityRadius: Float
    var degradedLinkRadius: Float
    var lostLinkRadius: Float
    var hardWorldBoundsRadius: Float
    var dronePosition: SIMD2<Float>
    var dockPosition: SIMD2<Float>
    var droneAltitudeMeters: Float
    var dockAltitudeMeters: Float
    var terrainMaxAltitudeMeters: Float
    var airframeClass: AirframeClass
    var profileMaxHorizontalSpeedMps: Float
    var estimatedRemainingTimeSec: Float
    var estimatedRemainingRangeM: Float
    var estimatedSafeReturnRangeM: Float
    var canReachHomeSafely: Bool
    var currentLinkQuality: Float
    var currentMapSuitability: MapScaleSuitability
    var recommendedMapScaleMin: MapScale
    var recommendedMapScaleMax: MapScale
    var recommendedOperationalMapScale: MapScale
    var unsuitableMapScales: [MapScale]
    var minimumTurnRadiusM: Float
    var waypointAnticipationDistanceM: Float

    static let empty = MapViewportState(
        center: .zero,
        mapScale: .x16,
        worldHalfExtent: 0.0,
        worldPhysicalScale: 0.0,
        operationalRadius: 0.0,
        linkQualityRadius: 0.0,
        degradedLinkRadius: 0.0,
        lostLinkRadius: 0.0,
        hardWorldBoundsRadius: 0.0,
        dronePosition: .zero,
        dockPosition: .zero,
        droneAltitudeMeters: 0.0,
        dockAltitudeMeters: 0.0,
        terrainMaxAltitudeMeters: 0.0,
        airframeClass: .multirotor,
        profileMaxHorizontalSpeedMps: 0.0,
        estimatedRemainingTimeSec: 0.0,
        estimatedRemainingRangeM: 0.0,
        estimatedSafeReturnRangeM: 0.0,
        canReachHomeSafely: false,
        currentLinkQuality: 1.0,
        currentMapSuitability: .acceptable,
        recommendedMapScaleMin: .x16,
        recommendedMapScaleMax: .x32,
        recommendedOperationalMapScale: .x32,
        unsuitableMapScales: [],
        minimumTurnRadiusM: 0.0,
        waypointAnticipationDistanceM: 0.0
    )

    var mapSideLengthMeters: Float {
        worldHalfExtent * 2.0
    }

    var boundaryHalfExtent: Float {
        max(1.0, hardWorldBoundsRadius)
    }

    var warningBandDepth: Float {
        boundaryHalfExtent * 0.15
    }

    var criticalBandDepth: Float {
        boundaryHalfExtent * 0.05
    }

    var droneOffsetFromHome: SIMD2<Float> {
        dronePosition - dockPosition
    }

    var isInWarningLinkZone: Bool {
        distanceToHome > linkQualityRadius + 0.05
    }

    var isInCriticalLinkZone: Bool {
        distanceToHome > degradedLinkRadius + 0.05
    }

    var isLinkLost: Bool {
        distanceToHome > lostLinkRadius + 0.05 || currentLinkQuality <= 0.01
    }

    var distanceToHome: Float {
        simd_distance(dronePosition, dockPosition)
    }

    var distanceToNearestMapEdge: Float {
        distanceToNearestMapEdge(for: dronePosition)
    }

    var nearestBoundaryDirection: MapBoundaryDirection {
        nearestBoundaryDirection(for: dronePosition)
    }

    var worldDetailBoundaryState: WorldDetailBoundaryState {
        worldDetailBoundaryState(for: dronePosition)
    }

    func clampedToWorld(_ position: SIMD2<Float>) -> SIMD2<Float> {
        let extent = boundaryHalfExtent
        let local = position - dockPosition
        let clampedLocal = SIMD2<Float>(
            min(max(local.x, -extent), extent),
            min(max(local.y, -extent), extent)
        )
        return dockPosition + clampedLocal
    }

    func isWithinWorldBounds(_ position: SIMD2<Float>, tolerance: Float = 0.0) -> Bool {
        distanceToNearestMapEdge(for: position) >= -max(0.0, tolerance)
    }

    func distanceToNearestMapEdge(for position: SIMD2<Float>) -> Float {
        let local = position - dockPosition
        return boundaryHalfExtent - max(abs(local.x), abs(local.y))
    }

    func nearestBoundaryDirection(for position: SIMD2<Float>) -> MapBoundaryDirection {
        let local = position - dockPosition
        if abs(local.x) >= abs(local.y) {
            return local.x >= 0.0 ? .east : .west
        }
        return local.y >= 0.0 ? .north : .south
    }

    func worldDetailBoundaryState(for position: SIMD2<Float>) -> WorldDetailBoundaryState {
        let edgeDistance = distanceToNearestMapEdge(for: position)
        if edgeDistance < 0.0 {
            return .outside
        }
        if edgeDistance <= criticalBandDepth {
            return .critical
        }
        if edgeDistance <= warningBandDepth {
            return .warning
        }
        return .nominal
    }

    func sectorID(
        for position: SIMD2<Float>,
        divisions: Int = MapViewportState.tacticalSectorDivisions
    ) -> String {
        let safeDivisions = max(1, divisions)
        let halfExtent = boundaryHalfExtent
        let local = position - dockPosition
        let cellSize = (halfExtent * 2.0) / Float(safeDivisions)
        guard cellSize > 0.001 else {
            return "A1"
        }

        let normalizedX = ((local.x + halfExtent) / cellSize).clamped(to: 0.0...Float(safeDivisions) - 0.001)
        let normalizedY = ((halfExtent - local.y) / cellSize).clamped(to: 0.0...Float(safeDivisions) - 0.001)
        let columnIndex = min(safeDivisions - 1, max(0, Int(normalizedX)))
        let rowIndex = min(safeDivisions - 1, max(0, Int(normalizedY)))
        let columnLabel = String(UnicodeScalar(65 + columnIndex) ?? UnicodeScalar(65))
        return "\(columnLabel)\(rowIndex + 1)"
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
