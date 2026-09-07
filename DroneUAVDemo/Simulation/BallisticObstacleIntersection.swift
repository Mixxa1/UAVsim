import Foundation
import simd

/// Segment-versus-obstacle intersection for falling objects in procedural scenes.
///
/// An imported mesh world answers this with a triangle raycast. A procedural scene has no such
/// index — only `CollisionObstacle`s — so a projectile there was caught by the column query alone:
/// it counted as having hit when it dropped below the surface reported for its own position. That
/// stops a capsule on a building, but reports the contact on the roof even when it flew into the
/// wall, and it cannot see a wall at all while the projectile is still above roof height.
///
/// Every obstacle here is treated as a vertical prism — a planar outline extruded between `baseY`
/// and `topY`. That is what these obstacles actually are (buildings, containers, trees as columns),
/// and it makes one algorithm cover the polygon-footprint, rotated-box and bare-radius cases: only
/// the outline differs.
enum BallisticObstacleIntersection {

    struct Hit {
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
        /// Position along the segment, 0...1.
        let fraction: Float
    }

    /// Nearest obstacle entry along `from` → `to`, or `nil` if the segment stays in clear air.
    static func nearestHit(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        obstacles: [CollisionObstacle]
    ) -> Hit? {
        var best: Hit?
        for obstacle in obstacles {
            guard let hit = intersect(from: from, to: to, obstacle: obstacle) else {
                continue
            }
            if best == nil || hit.fraction < best!.fraction {
                best = hit
            }
        }
        return best
    }

    /// Entry point of the segment into one obstacle's prism.
    static func intersect(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        obstacle: CollisionObstacle
    ) -> Hit? {
        let outline = planarOutline(of: obstacle)
        guard outline.count >= 3 else {
            return nil
        }

        // Vertical slab first: the range of the segment that is between the prism's floor and roof.
        let dy = to.y - from.y
        var tEnterY: Float = 0.0
        var tExitY: Float = 1.0
        var enteredThroughRoof = false
        if abs(dy) < 1e-6 {
            guard from.y >= obstacle.baseY, from.y <= obstacle.topY else {
                return nil
            }
        } else {
            let tBase = (obstacle.baseY - from.y) / dy
            let tTop = (obstacle.topY - from.y) / dy
            tEnterY = min(tBase, tTop)
            tExitY = max(tBase, tTop)
            // Falling onto the roof is the common case: the segment descends, so the top plane is
            // the entry and the contact normal points up.
            enteredThroughRoof = dy < 0.0 && tTop >= 0.0
            if tExitY < 0.0 || tEnterY > 1.0 {
                return nil
            }
            tEnterY = max(0.0, tEnterY)
            tExitY = min(1.0, tExitY)
        }

        // Planar outline second.
        let start2D = SIMD2<Float>(from.x, from.z)
        let end2D = SIMD2<Float>(to.x, to.z)
        var tEnterXZ: Float = 0.0
        var entryNormal2D: SIMD2<Float>?

        if contains(point: start2D, outline: outline) {
            tEnterXZ = 0.0
        } else {
            guard let crossing = firstEdgeCrossing(from: start2D, to: end2D, outline: outline) else {
                return nil
            }
            tEnterXZ = crossing.fraction
            entryNormal2D = crossing.normal
        }

        let tEnter = max(tEnterY, tEnterXZ)
        guard tEnter <= tExitY, tEnter >= 0.0, tEnter <= 1.0 else {
            return nil
        }

        // The segment might leave the outline before the vertical slab is entered — a projectile
        // that passes over a building's footprint while still above its roof.
        if tEnterXZ < tEnterY, !contains(point: simd_mix(start2D, end2D, SIMD2<Float>(repeating: tEnter)), outline: outline) {
            return nil
        }

        let point = from + (to - from) * tEnter
        let normal: SIMD3<Float>
        if tEnterY >= tEnterXZ, enteredThroughRoof {
            normal = SIMD3<Float>(0, 1, 0)
        } else if let entryNormal2D {
            normal = SIMD3<Float>(entryNormal2D.x, 0, entryNormal2D.y)
        } else {
            normal = SIMD3<Float>(0, 1, 0)
        }
        return Hit(point: point, normal: normal, fraction: tEnter)
    }

    // MARK: - Outline

    /// The obstacle's footprint in world X/Z.
    ///
    /// Three sources, in descending order of truth: a real polygon outline, an oriented rectangle
    /// from the planar half-extents, or — for obstacles that carry neither — a polygon approximating
    /// the broad-phase radius. The last is coarse, but a coarse column is still far closer to a tree
    /// or a pole than the flat plane the projectile would otherwise fall through.
    private static func planarOutline(of obstacle: CollisionObstacle) -> [SIMD2<Float>] {
        if let footprint = obstacle.planarFootprint, footprint.count >= 3 {
            return footprint
        }
        let center = SIMD2<Float>(obstacle.center.x, obstacle.center.z)
        if let halfExtents = obstacle.planarHalfExtents {
            let cosYaw = cos(obstacle.yawRadians)
            let sinYaw = sin(obstacle.yawRadians)
            let corners: [SIMD2<Float>] = [
                SIMD2<Float>(-halfExtents.x, -halfExtents.y),
                SIMD2<Float>(halfExtents.x, -halfExtents.y),
                SIMD2<Float>(halfExtents.x, halfExtents.y),
                SIMD2<Float>(-halfExtents.x, halfExtents.y)
            ]
            return corners.map { corner in
                center + SIMD2<Float>(
                    corner.x * cosYaw - corner.y * sinYaw,
                    corner.x * sinYaw + corner.y * cosYaw
                )
            }
        }
        let radius = max(0.05, obstacle.radius)
        return (0..<8).map { index in
            let angle = Float(index) / 8.0 * 2.0 * .pi
            return center + SIMD2<Float>(cos(angle) * radius, sin(angle) * radius)
        }
    }

    // MARK: - Planar geometry

    /// Even-odd containment. Works for concave outlines, which real building footprints are.
    private static func contains(point: SIMD2<Float>, outline: [SIMD2<Float>]) -> Bool {
        var isInside = false
        var j = outline.count - 1
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[j]
            if (a.y > point.y) != (b.y > point.y) {
                let denominator = b.y - a.y
                if abs(denominator) > 1e-12 {
                    let crossX = a.x + (point.y - a.y) / denominator * (b.x - a.x)
                    if point.x < crossX {
                        isInside.toggle()
                    }
                }
            }
            j = i
        }
        return isInside
    }

    /// Nearest crossing of the outline's edges, with the outward normal of the edge crossed.
    private static func firstEdgeCrossing(
        from: SIMD2<Float>,
        to: SIMD2<Float>,
        outline: [SIMD2<Float>]
    ) -> (fraction: Float, normal: SIMD2<Float>)? {
        let direction = to - from
        guard simd_length_squared(direction) > 1e-12 else {
            return nil
        }

        var best: (fraction: Float, normal: SIMD2<Float>)?
        var j = outline.count - 1
        for i in 0..<outline.count {
            let a = outline[j]
            let b = outline[i]
            j = i

            let edge = b - a
            let denominator = direction.x * edge.y - direction.y * edge.x
            guard abs(denominator) > 1e-12 else {
                continue  // Parallel.
            }
            let delta = a - from
            let t = (delta.x * edge.y - delta.y * edge.x) / denominator
            let u = (delta.x * direction.y - delta.y * direction.x) / denominator
            guard t >= 0.0, t <= 1.0, u >= 0.0, u <= 1.0 else {
                continue
            }
            if best == nil || t < best!.fraction {
                // Outward normal of the edge, flipped to oppose the direction of travel so it
                // always faces the incoming projectile.
                var normal = simd_normalize(SIMD2<Float>(edge.y, -edge.x))
                if simd_dot(normal, direction) > 0 {
                    normal = -normal
                }
                best = (t, normal)
            }
        }
        return best
    }
}
