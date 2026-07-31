import Foundation

struct MissionAltitudeConstraints: Equatable {
    var minimumMeters: Float
    var maximumMeters: Float

    /// The operator's window in world coordinates.
    ///
    /// **The window is height above the launch point, not above world zero.** That is what every
    /// ground station means by default — MAVLink's `GLOBAL_RELATIVE_ALT`, QGroundControl's
    /// "Relative To Launch", Mission Planner's "Relative" — and it is the only reading that
    /// survives launching from anywhere but the ground: a start on a 427 m roof made an absolute
    /// 80 m ceiling unsatisfiable before the aircraft had moved, and the mission was refused for
    /// an altitude the operator never asked for. The world ceiling still caps the result, because
    /// that limit is about the size of the map rather than about the task.
    func absolute(launchAltitude: Float, terrainMaxAltitude: Float) -> ClosedRange<Float> {
        let base = max(0.0, launchAltitude)
        let ceiling = max(0.0, terrainMaxAltitude)
        let lowerBound = min(max(0.0, minimumMeters) + base, ceiling)
        let upperBound = max(lowerBound, min(max(0.0, maximumMeters) + base, ceiling))
        return lowerBound...upperBound
    }

    /// Whether the operator narrowed the window himself, rather than inheriting the world's own
    /// headroom. Measured in the same relative terms the window is written in.
    func hasCustomWindow(launchAltitude: Float, terrainMaxAltitude: Float) -> Bool {
        let headroom = max(0.0, max(0.0, terrainMaxAltitude) - max(0.0, launchAltitude))
        return minimumMeters > 0.05 || maximumMeters < headroom - 0.05
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
        case .hybridVTOL:
            let cruiseFloor = max(10.0, dockAltitude + 8.0)
            baseline = currentAltitude <= cruiseFloor
                ? max(cruiseFloor, currentAltitude + 3.4)
                : cruiseFloor
        }
        return min(terrainCeiling, max(0.0, baseline))
    }

    func clampedMissionAltitude(
        _ altitudeMeters: Float,
        launchAltitude: Float,
        terrainMaxAltitude: Float
    ) -> Float {
        let window = altitude.absolute(
            launchAltitude: launchAltitude,
            terrainMaxAltitude: terrainMaxAltitude
        )
        return min(window.upperBound, max(window.lowerBound, altitudeMeters))
    }
}
