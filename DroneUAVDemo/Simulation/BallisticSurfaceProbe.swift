import Foundation
import simd

/// What a falling object hit.
struct BallisticSurfaceHit {
    /// World-space point of contact.
    let point: SIMD3<Float>
    /// Upward surface normal at the contact point.
    let normal: SIMD3<Float>
    /// True when the contact is a water surface rather than ground or structure — the caller
    /// wants a splash there, not a burst, and a capsule that lands in a river puts out nothing.
    let isWater: Bool
}

/// The world's answer to "what is under this point, and did the projectile just pass through it".
///
/// This is a protocol, not a direct call into the scene, for a concrete build reason:
/// `Tools/probe-sources.sh` compiles the headless probes from `Domain` and `Simulation` only —
/// `MeshCollisionIndex` lives in `Services/World` and `DroneSceneController` in `Scene`, neither of
/// which is on that list. A file in `Simulation` that reaches into either one does not merely fail
/// to be testable, it breaks the build of *every* probe in `Tools`, because the source list is a
/// `find` over the whole directory. The two names already in that script's `EXCLUDED` array are
/// there for exactly this reason. Routing the world query through a protocol keeps
/// `BallisticProjectileRuntime` compiling headless, with `FlatGroundBallisticSurfaceProbe` standing
/// in for the city.
protocol BallisticSurfaceProbe: AnyObject {
    /// Height of the highest surface in the column at (`x`, `z`), searching downward from
    /// `maximumHeight`.
    ///
    /// Returning `nil` means *unknown* — outside the loaded world, or over a hole in the mesh — and
    /// must never be conflated with "the surface is at zero". Collapsing those two is what once
    /// dropped an aircraft to sea level for a tick, and for a projectile it is worse: a capsule
    /// released over a streamed-out chunk would fall straight through a real city to y = 0.
    func ballisticSurfaceHeight(x: Float, z: Float, maximumHeight: Float) -> Float?

    /// Exact intersection of the segment `from` → `to` with the world, when this world can answer
    /// one. `nil` means either no hit or no segment-casting capability; callers must fall back to
    /// the column query and cannot tell the two apart (nor do they need to).
    func ballisticSegmentHit(from: SIMD3<Float>, to: SIMD3<Float>) -> BallisticSurfaceHit?

    /// Water level in the column at (`x`, `z`), or `nil` where this world has no water there.
    func ballisticWaterLevel(x: Float, z: Float) -> Float?
}

/// A featureless plane at a fixed height.
///
/// The stand-in the headless probes fly against, and the safe fallback for any scene that has not
/// wired a real probe yet: it reproduces exactly the old drop behaviour (flat ground, no
/// structures), so falling back to it can never be worse than what the code did before.
final class FlatGroundBallisticSurfaceProbe: BallisticSurfaceProbe {
    let groundHeight: Float
    /// Optional water plane, for probing splash handling without a world.
    let waterLevel: Float?
    /// Axis-aligned boxes standing on the ground, so a probe run can exercise rooftop impacts and
    /// the "fell past the eave" case without loading a city.
    let boxes: [Box]

    struct Box {
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
        let topHeight: Float

        func contains(x: Float, z: Float) -> Bool {
            x >= minimum.x && x <= maximum.x && z >= minimum.y && z <= maximum.y
        }
    }

    init(groundHeight: Float = 0.0, waterLevel: Float? = nil, boxes: [Box] = []) {
        self.groundHeight = groundHeight
        self.waterLevel = waterLevel
        self.boxes = boxes
    }

    func ballisticSurfaceHeight(x: Float, z: Float, maximumHeight: Float) -> Float? {
        var best = groundHeight
        for box in boxes where box.contains(x: x, z: z) {
            // Same rule as the real world query: a roof counts only when the caller was looking
            // from at or above it, so a projectile already below the eave is not caught by it.
            if box.topHeight <= maximumHeight + 0.08, box.topHeight > best {
                best = box.topHeight
            }
        }
        return best
    }

    func ballisticSegmentHit(from: SIMD3<Float>, to: SIMD3<Float>) -> BallisticSurfaceHit? {
        nil
    }

    func ballisticWaterLevel(x: Float, z: Float) -> Float? {
        waterLevel
    }
}

/// A surface probe backed by a height function.
///
/// Bridges callers that already know how to sample their own ground — the intercept mission session
/// carries a `ground(position, radius)` closure — without them having to own a collision index.
final class ClosureBallisticSurfaceProbe: BallisticSurfaceProbe {
    private let heightAt: (SIMD3<Float>, Float) -> Float

    init(heightAt: @escaping (SIMD3<Float>, Float) -> Float) {
        self.heightAt = heightAt
    }

    func ballisticSurfaceHeight(x: Float, z: Float, maximumHeight: Float) -> Float? {
        heightAt(SIMD3<Float>(x, maximumHeight, z), 0.1)
    }

    func ballisticSegmentHit(from: SIMD3<Float>, to: SIMD3<Float>) -> BallisticSurfaceHit? {
        nil
    }

    func ballisticWaterLevel(x: Float, z: Float) -> Float? {
        nil
    }
}
