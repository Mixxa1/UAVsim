import Foundation
import simd

/// The scene answering "what is under this falling object".
///
/// `BallisticProjectileRuntime` cannot call into the scene directly — it lives in `Simulation`,
/// which the headless probes in `Tools` compile on its own, and a reference from there into
/// `Scene`/`Services` breaks the build of every probe in the directory. So the world side of the
/// query is implemented here instead, and the runtime only ever sees the protocol.
///
/// Two levels of fidelity are offered, and which one applies depends on the world:
///
/// - An imported mesh world can cast an arbitrary segment, so a projectile thrown forward into a
///   façade stops at the façade.
/// - A procedural scene has only the column query, so a projectile is caught when it drops below
///   the surface under its own position. That still stops it on a building, but reports the
///   contact on the roof rather than the wall it flew into.
extension DroneSceneController: BallisticSurfaceProbe {

    /// Small enough that a projectile is only considered over a surface when it really is over it.
    /// The aircraft query uses a fraction of the airframe's collision radius for the same reason;
    /// a capsule is a 16 cm ball, so there is nothing to widen it by.
    private static let ballisticSurfaceClearanceRadius: Float = 0.05

    func ballisticSurfaceHeight(x: Float, z: Float, maximumHeight: Float) -> Float? {
        supportSurfaceHeight(
            at: SIMD2<Float>(x, z),
            clearanceRadius: Self.ballisticSurfaceClearanceRadius,
            maximumHeight: maximumHeight
        )
    }

    func ballisticSegmentHit(from: SIMD3<Float>, to: SIMD3<Float>) -> BallisticSurfaceHit? {
        let delta = to - from
        let distance = simd_length(delta)
        guard distance > 1e-6 else {
            return nil
        }

        if let meshCollision {
            guard let hit = meshCollision.raycast(origin: from, direction: delta, maxDistance: distance) else {
                return nil
            }
            var normal = hit.normal
            if normal.y < 0 {
                normal = -normal
            }
            // Open-data water carries no collision geometry, so anything the mesh reports here is
            // ground or structure. A splash is decided by `ballisticWaterLevel` instead.
            return BallisticSurfaceHit(point: hit.point, normal: normal, isWater: false)
        }

        // Procedural scene: no triangle index, but the obstacles it does have are vertical prisms
        // with a known footprint, and testing the segment against those catches the case the column
        // query structurally cannot — a projectile flying into a wall rather than down onto a roof.
        let candidates = environmentObstacleIndex.query(from: from, to: to, margin: 1.0)
        guard !candidates.isEmpty else {
            return nil
        }
        guard let hit = BallisticObstacleIntersection.nearestHit(
            from: from,
            to: to,
            obstacles: candidates
        ) else {
            return nil
        }
        return BallisticSurfaceHit(point: hit.point, normal: hit.normal, isWater: false)
    }

    func ballisticWaterLevel(x: Float, z: Float) -> Float? {
        guard let meshWater, meshWater.isWater(x: x, z: z) else {
            return nil
        }
        return meshWater.level
    }
}
