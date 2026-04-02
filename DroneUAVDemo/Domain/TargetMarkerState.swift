import Foundation
import simd

struct TargetMarkerState: Identifiable, Equatable {
    let id: UUID
    var position: SIMD2<Float>
    let createdAt: Date

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.position = position
        self.createdAt = createdAt
    }

    func worldPosition(altitude: Float) -> SIMD3<Float> {
        SIMD3<Float>(position.x, altitude, position.y)
    }

    func distance(from origin: SIMD2<Float>) -> Float {
        simd_distance(position, origin)
    }

    func bearingRadians(from origin: SIMD2<Float>) -> Float {
        let delta = position - origin
        guard simd_length_squared(delta) > 0.0001 else {
            return 0.0
        }
        return atan2(-delta.x, delta.y)
    }

    func bearingDegrees(from origin: SIMD2<Float>) -> Float {
        normalizedCompassDegrees(bearingRadians(from: origin) * 180.0 / .pi)
    }
}

func normalizedCompassDegrees(_ degrees: Float) -> Float {
    let wrapped = degrees.truncatingRemainder(dividingBy: 360.0)
    return wrapped >= 0.0 ? wrapped : wrapped + 360.0
}

func bodyHeadingDegrees(fromYawRadians yawRadians: Float) -> Float {
    normalizedCompassDegrees((yawRadians + .pi) * 180.0 / .pi)
}
