import Foundation
import simd

struct MapViewportState: Equatable {
    var center: SIMD2<Float>
    var worldHalfExtent: Float
    var signalBoundaryRadius: Float
    var dronePosition: SIMD2<Float>
    var dockPosition: SIMD2<Float>
    var droneAltitudeMeters: Float
    var dockAltitudeMeters: Float
    var terrainMaxAltitudeMeters: Float
    var airframeClass: AirframeClass
    var profileMaxHorizontalSpeedMps: Float

    static let empty = MapViewportState(
        center: .zero,
        worldHalfExtent: 0.0,
        signalBoundaryRadius: 0.0,
        dronePosition: .zero,
        dockPosition: .zero,
        droneAltitudeMeters: 0.0,
        dockAltitudeMeters: 0.0,
        terrainMaxAltitudeMeters: 0.0,
        airframeClass: .multirotor,
        profileMaxHorizontalSpeedMps: 0.0
    )

    func clampedToWorld(_ position: SIMD2<Float>) -> SIMD2<Float> {
        let extent = max(1.0, worldHalfExtent)
        return SIMD2<Float>(
            min(max(position.x, -extent), extent),
            min(max(position.y, -extent), extent)
        )
    }
}
