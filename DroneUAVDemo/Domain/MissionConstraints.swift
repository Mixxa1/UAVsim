import Foundation

struct MissionAltitudeConstraints: Equatable {
    var minimumMeters: Float
    var maximumMeters: Float

    func clamped(to terrainMaxAltitude: Float) -> ClosedRange<Float> {
        let lowerBound = max(0.0, minimumMeters)
        let upperBound = max(lowerBound, min(maximumMeters, max(0.0, terrainMaxAltitude)))
        return lowerBound...upperBound
    }

    func hasCustomWindow(terrainMaxAltitude: Float) -> Bool {
        let terrainCeiling = max(0.0, terrainMaxAltitude)
        return minimumMeters > 0.05 || maximumMeters < terrainCeiling - 0.05
    }
}

struct MissionSpeedConstraints: Equatable {
    var minimumMetersPerSecond: Float
    var maximumMetersPerSecond: Float

    func effectiveMaximum(profileMaxSpeed: Float) -> Float {
        min(maximumMetersPerSecond, max(0.0, profileMaxSpeed))
    }

    func hasCustomMaximum(profileMaxSpeed: Float) -> Bool {
        effectiveMaximum(profileMaxSpeed: profileMaxSpeed) < max(0.0, profileMaxSpeed) - 0.05
    }
}

struct MissionConstraints: Equatable {
    var maxWaypointCount: Int
    var minimumWaypointSpacing: Float
    var minimumZoneRadius: Float
    var zoneRadiusFractionOfSignalBoundary: Float
    var includeReturnHomePreview: Bool
    var altitude: MissionAltitudeConstraints
    var speed: MissionSpeedConstraints

    static let stageOneDefault = MissionConstraints(
        maxWaypointCount: 12,
        minimumWaypointSpacing: 2.0,
        minimumZoneRadius: 4.0,
        zoneRadiusFractionOfSignalBoundary: 0.55,
        includeReturnHomePreview: false,
        altitude: MissionAltitudeConstraints(
            minimumMeters: 0.0,
            maximumMeters: 80.0
        ),
        speed: MissionSpeedConstraints(
            minimumMetersPerSecond: 0.0,
            maximumMetersPerSecond: 60.0
        )
    )

    func maximumZoneRadius(for viewport: MapViewportState) -> Float {
        max(
            minimumZoneRadius,
            min(
                viewport.hardWorldBoundsRadius * zoneRadiusFractionOfSignalBoundary,
                viewport.operationalRadius * 0.78
            )
        )
    }

    func baselineTravelAltitude(
        currentAltitude: Float,
        dockAltitude: Float,
        terrainMaxAltitude: Float,
        airframeClass: AirframeClass
    ) -> Float {
        let terrainCeiling = max(0.0, terrainMaxAltitude)
        let baseline: Float
        switch airframeClass {
        case .multirotor:
            baseline = max(
                3.4,
                dockAltitude + 4.0,
                currentAltitude + (currentAltitude <= 0.05 ? 3.0 : 0.8)
            )
        case .fixedWing:
            baseline = max(
                10.0,
                dockAltitude + 8.0,
                currentAltitude + 3.4
            )
        }
        return min(terrainCeiling, max(0.0, baseline))
    }

    func clampedMissionAltitude(
        _ altitudeMeters: Float,
        terrainMaxAltitude: Float
    ) -> Float {
        let window = altitude.clamped(to: terrainMaxAltitude)
        return min(window.upperBound, max(window.lowerBound, altitudeMeters))
    }
}
