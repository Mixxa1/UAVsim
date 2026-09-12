import Foundation
import simd

/// The wood inside a tree's crown: the stem running up through it and the branches off it.
///
/// A crown used to be a volume of viscous drag. Flying into one slowed an aircraft the same
/// way whatever it weighed and never struck it, because there was nothing in it to strike —
/// and a real crown is mostly empty air with wood in it, and the wood is what an aircraft
/// meets. This builds that wood for a conifer (the scene's trees are pines) from the crown's
/// own box, the same way every time for the same tree, so a replay hits the same branches.
///
/// ⚠️ Every constant is a stated property of a real pine, not a tuning knob:
///
/// - stem slenderness `H/DBH = 50` — open-grown conifers run 40–50, stand-grown 60–80; the
///   scene's trees stand in the open;
/// - one whorl every 0.6 m — a mature pine's annual leader growth is 0.3–0.8 m, and it sets
///   one whorl a year; five branches to a whorl (Scots pine 4–6, spruce 4–7);
/// - branch base diameter a quarter of the stem's at that height;
/// - branches the length of the crown's radius at their height (a conical crown), drooping
///   20° at its base and rising 30° at its top;
/// - four laterals per branch, 0.45 of the parent's diameter where they leave it;
/// - green pine wood (Wood Handbook, green values for the pines): modulus of rupture 35 MPa,
///   modulus of elasticity 7 GPa, density with its water 800 kg/m³.
struct TreeCrownStructure {
    struct Branch {
        let key: TreeBranchKey
        /// Where it leaves its parent (the stem, or the branch it is a lateral of) and its tip.
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let baseDiameter: Float
        let tipDiameter: Float
        /// Length of cantilever below `start` that the branch is built into (none: it is built
        /// in where it starts).
        let rootBelowStart: Float
        /// The stem: what is above a load point on it carries the crown's branches as well.
        var isStem: Bool = false

        var length: Float { simd_distance(start, end) }

        func diameter(at s: Float) -> Float {
            baseDiameter + (tipDiameter - baseDiameter) * min(1, max(0, s))
        }

        func point(at s: Float) -> SIMD3<Float> { start + (end - start) * min(1, max(0, s)) }

        /// A transverse load at `s` along the branch, as a tapered cantilever built in at its
        /// root: the load at which the most-stressed section reaches the modulus of rupture,
        /// the stiffness the load point sees, and its lever arm.
        func mechanics(at s: Float) -> (breakingForce: Float, stiffness: Float, lever: Float) {
            let lever = max(0.02, rootBelowStart + length * min(1, max(0, s)))
            let samples = 12
            var breaking = Float.greatestFiniteMagnitude
            var compliance: Float = 0
            for index in 0..<samples {
                // x measured from the root, over [0, lever].
                let x = lever * (Float(index) + 0.5) / Float(samples)
                let d = diameterFromRoot(x)
                let arm = lever - x
                let modulus = Float.pi * d * d * d / 32
                if arm > 1e-4 { breaking = min(breaking, TreeCrownStructure.modulusOfRupturePa * modulus / arm) }
                let inertia = Float.pi * d * d * d * d / 64
                compliance += arm * arm / (TreeCrownStructure.elasticModulusPa * inertia) * (lever / Float(samples))
            }
            return (breaking, 1 / max(1e-9, compliance), lever)
        }

        /// Mass the struck point carries with it: Rayleigh's kinetic-energy equivalent over the
        /// cantilever's static deflection shape inboard of the load, `φ(x) = x²(3a − x)/(2a³)`,
        /// and everything outboard moving with the load point. The outboard part is not given
        /// the larger swing the static shape would: an impact is over long before the far end
        /// of a branch — or the top of a tree — has heard of it. On the stem, what is above the
        /// load point carries its branches too: a conifer's branch wood is 15–25 % of its stem
        /// wood, taken at the top of that range.
        func effectiveMass(at s: Float) -> Float {
            let lever = max(0.02, rootBelowStart + length * min(1, max(0, s)))
            let total = rootBelowStart + length
            let samples = 16
            var mass: Float = 0
            for index in 0..<samples {
                let x = total * (Float(index) + 0.5) / Float(samples)
                let d = diameterFromRoot(x)
                let perMetre = TreeCrownStructure.greenDensity * Float.pi * d * d / 4
                let shape: Float = x <= lever ? x * x * (3 * lever - x) / (2 * lever * lever * lever) : 1
                let carried: Float = x > lever && isStem ? 1.25 : 1
                mass += perMetre * shape * shape * carried * (total / Float(samples))
            }
            return max(0.002, mass)
        }

        /// Diameter at a distance from the cantilever root. For the stem that root is the
        /// ground; the part below the crown is the stem's own taper down there.
        private func diameterFromRoot(_ x: Float) -> Float {
            guard rootBelowStart > 0 else { return diameter(at: x / max(0.01, length)) }
            let fromStart = x - rootBelowStart
            if fromStart >= 0 { return diameter(at: fromStart / max(0.01, length)) }
            let groundDiameter = baseDiameter + (baseDiameter - tipDiameter) * rootBelowStart / max(0.01, length)
            return baseDiameter + (groundDiameter - baseDiameter) * (-fromStart / rootBelowStart)
        }
    }

    static let modulusOfRupturePa: Float = 35e6
    /// Green pine wood with its water, kg/m³.
    static let greenDensity: Float = 800
    static let elasticModulusPa: Float = 7e9
    static let whorlSpacing: Float = 0.6
    static let branchesPerWhorl = 5
    static let slenderness: Float = 50

    let treeID: UUID
    let branches: [Branch]
    let bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    /// Where the crown's foliage starts, and the ground the stem stands on.
    let crownBase: Float
    let ground: Float

    /// The tree of a crown obstacle. Its box (or cylinder) is the crown; the stem runs up its
    /// planar centre from the ground, and the crown is the top 60 % of the tree — the
    /// proportion the scene builds its trees with (`ScenePopulationService.treeCollisionParts`,
    /// crown from 0.40 H) and the open-data world sizes its crowns to (from 0.42 H).
    ///
    /// The whole stem is modelled here, the part under the crown included, so a tree is one
    /// piece of wood whichever way it is described: the scene's separate trunk box is left to
    /// navigation, and a world that only knows the crown still has a trunk to fly into.
    static func build(canopy: CollisionObstacle) -> TreeCrownStructure {
        let top = canopy.topY
        let crownBase = min(canopy.baseY, top - 0.5)
        let height = max(1.5, (top - crownBase) / 0.6)
        let ground = top - height
        let axis = SIMD2<Float>(canopy.center.x, canopy.center.z)
        let crownRadius: Float = {
            if let half = canopy.planarHalfExtents { return max(0.3, min(half.x, half.y)) }
            return max(0.3, canopy.radius)
        }()
        let breastHeight = min(1.3, height * 0.5)
        let dbh = min(1.2, max(0.06, height / slenderness))
        func stemDiameter(atHeight h: Float) -> Float {
            let fraction = (top - (ground + h)) / max(0.1, height - breastHeight)
            return max(0.02, dbh * min(1.2, fraction))
        }

        var random = SeededRandom(seed: canopy.id)
        var branches: [Branch] = []
        var index = 0
        // The stem, from the ground to the top: a tapered cantilever built into the ground.
        branches.append(Branch(
            key: TreeBranchKey(treeID: canopy.id, index: index),
            start: SIMD3<Float>(axis.x, ground, axis.y),
            end: SIMD3<Float>(axis.x, top, axis.y),
            baseDiameter: stemDiameter(atHeight: 0),
            tipDiameter: 0.02,
            rootBelowStart: 0,
            isStem: true))
        index += 1

        var y = crownBase + whorlSpacing * random.unit()
        while y < top - 0.25 {
            let relative = (y - crownBase) / max(0.1, top - crownBase)
            let radiusHere = crownRadius * max(0.12, 1 - relative)
            let stem = stemDiameter(atHeight: y - ground)
            let phase = random.unit() * 2 * .pi
            let slotAngle: Float = 2 * Float.pi / Float(branchesPerWhorl)
            let degree: Float = Float.pi / 180
            for slot in 0..<branchesPerWhorl {
                let azimuthJitter: Float = (random.unit() - 0.5) * 0.5
                let azimuth: Float = phase + Float(slot) * slotAngle + azimuthJitter
                let elevationJitter: Float = (random.unit() - 0.5) * 16
                let elevationDegrees: Float = -20 + 50 * relative + elevationJitter
                let elevation: Float = elevationDegrees * degree
                let lengthScale: Float = 0.8 + 0.3 * random.unit()
                let length: Float = max(0.3, radiusHere * lengthScale)
                let horizontal: Float = cos(elevation)
                let direction = SIMD3<Float>(cos(azimuth) * horizontal, sin(elevation), sin(azimuth) * horizontal)
                let start = SIMD3<Float>(axis.x, y, axis.y) + direction * (stem * 0.5)
                let base = max(0.01, min(0.15, stem * 0.25))
                let main = Branch(key: TreeBranchKey(treeID: canopy.id, index: index), start: start,
                                  end: start + direction * length, baseDiameter: base, tipDiameter: 0.004,
                                  rootBelowStart: 0)
                branches.append(main)
                index += 1
                let lateralPositions: [Float] = [0.3, 0.5, 0.7, 0.85]
                for (lateral, s) in lateralPositions.enumerated() {
                    let side: Float = lateral % 2 == 0 ? 1 : -1
                    let spread: Float = 0.95 + (random.unit() - 0.5) * 0.4
                    let turn: Float = azimuth + side * spread
                    let lateralElevation: Float = elevation - 0.1
                    let lateralHorizontal: Float = cos(lateralElevation)
                    let lateralDirection = SIMD3<Float>(cos(turn) * lateralHorizontal, sin(lateralElevation),
                                                        sin(turn) * lateralHorizontal)
                    let lateralLength: Float = max(0.12, 0.4 * (1 - s) * length + 0.15)
                    let root = main.point(at: s)
                    branches.append(Branch(key: TreeBranchKey(treeID: canopy.id, index: index), start: root,
                                           end: root + lateralDirection * lateralLength,
                                           baseDiameter: max(0.006, 0.45 * main.diameter(at: s)), tipDiameter: 0.003,
                                           rootBelowStart: 0))
                    index += 1
                }
            }
            y += whorlSpacing
        }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for branch in branches {
            low = simd_min(low, simd_min(branch.start, branch.end))
            high = simd_max(high, simd_max(branch.start, branch.end))
        }
        return TreeCrownStructure(treeID: canopy.id, branches: branches, bounds: (low, high),
                                  crownBase: crownBase, ground: ground)
    }

    struct Crossing {
        let branch: Branch
        /// Along the branch, and the fraction of the step at which the part reached it.
        let s: Float
        let t: Float
        /// Struck point on the part's surface, world frame.
        let pointWorld: SIMD3<Float>
    }

    /// The first branch a box meets while it moves from `from` to `to` (world centres) at a
    /// fixed orientation, or nil. Continuous in time: a 2 cm twig against a 3 cm-thick wing
    /// moving a third of a metre per tick is crossed between samples, never found inside.
    ///
    /// In the box's frame a branch sweeps a parallelogram over the step, `(s, t) ↦ A + s·(B−A)
    /// + (1−t)·d`. It touches the box, grown by the branch's radius, wherever all six slab
    /// inequalities hold — a convex polygon in `(s, t)`, cut out of the unit square one
    /// half-plane at a time. Its lowest `t` is the moment of contact.
    ///
    /// A branch already touching at the start of the step is not a new strike: it is one the
    /// part is still pushing past, and was dealt with when it was met.
    func firstCrossing(
        from: SIMD3<Float>,
        to: SIMD3<Float>,
        orientation: simd_quatf,
        halfExtents: SIMD3<Float>,
        isBroken: (TreeBranchKey) -> Bool
    ) -> Crossing? {
        let reach = simd_length(halfExtents) + 0.1
        let sweepLow = simd_min(from, to) - SIMD3<Float>(repeating: reach)
        let sweepHigh = simd_max(from, to) + SIMD3<Float>(repeating: reach)
        guard all(sweepHigh .>= bounds.min), all(sweepLow .<= bounds.max) else { return nil }
        let conjugate = orientation.conjugate
        let drift = simd_act(conjugate, to - from)
        var best: Crossing?
        for branch in branches {
            let low = simd_min(branch.start, branch.end), high = simd_max(branch.start, branch.end)
            guard all(high .>= sweepLow), all(low .<= sweepHigh), !isBroken(branch.key) else { continue }
            let a = simd_act(conjugate, branch.start - to)
            let b = simd_act(conjugate, branch.end - to)
            let radius = max(0.002, branch.baseDiameter * 0.5)
            guard let hit = Self.sweptSegmentBoxContact(a: a, b: b, drift: drift,
                                                        halfExtents: halfExtents + SIMD3<Float>(repeating: radius)) else { continue }
            guard hit.t > 1e-4, best == nil || hit.t < best!.t else { continue }
            // The struck point: the branch point at contact, pulled onto the part's surface.
            let local = a + (b - a) * hit.s + drift * (1 - hit.t)
            let onSurface = simd_min(halfExtents, simd_max(-halfExtents, local))
            let centerAtHit = from + (to - from) * hit.t
            best = Crossing(branch: branch, s: hit.s, t: hit.t, pointWorld: centerAtHit + simd_act(orientation, onSurface))
        }
        return best
    }

    /// Earliest `(s, t)` at which the moving segment touches the box, by clipping the unit
    /// square against the six slab half-planes.
    static func sweptSegmentBoxContact(
        a: SIMD3<Float>, b: SIMD3<Float>, drift: SIMD3<Float>, halfExtents: SIMD3<Float>
    ) -> (s: Float, t: Float)? {
        var polygon: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let along = b - a
        for axis in 0..<3 {
            // value(s, t) = (a + drift) + s·along − t·drift
            let offset = a[axis] + drift[axis]
            let ds = along[axis], dt = -drift[axis]
            // value ≤ h  and  −value ≤ h
            polygon = clip(polygon, offset: offset - halfExtents[axis], ds: ds, dt: dt)
            if polygon.isEmpty { return nil }
            polygon = clip(polygon, offset: -offset - halfExtents[axis], ds: -ds, dt: -dt)
            if polygon.isEmpty { return nil }
        }
        guard let first = polygon.min(by: { $0.y < $1.y }) else { return nil }
        return (first.x, first.y)
    }

    /// Keeps the part of a convex polygon where `offset + ds·s + dt·t ≤ 0`.
    private static func clip(_ polygon: [SIMD2<Float>], offset: Float, ds: Float, dt: Float) -> [SIMD2<Float>] {
        func value(_ p: SIMD2<Float>) -> Float { offset + ds * p.x + dt * p.y }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(polygon.count + 2)
        for index in polygon.indices {
            let current = polygon[index], next = polygon[(index + 1) % polygon.count]
            let vc = value(current), vn = value(next)
            if vc <= 0 { result.append(current) }
            if (vc <= 0) != (vn <= 0) {
                let f = vc / (vc - vn)
                result.append(current + (next - current) * f)
            }
        }
        return result
    }
}

struct TreeBranchKey: Hashable {
    let treeID: UUID
    let index: Int
}

/// Branches that have been broken off. A snapped branch stays snapped for the life of the
/// world; the next aircraft through the gap it left does not meet it again.
final class TreeBranchRegistry: @unchecked Sendable {
    static let shared = TreeBranchRegistry()
    private var broken: Set<TreeBranchKey> = []
    private let lock = NSLock()

    func isBroken(_ key: TreeBranchKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return broken.contains(key)
    }

    func markBroken(_ key: TreeBranchKey) {
        lock.lock(); defer { lock.unlock() }
        broken.insert(key)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        broken.removeAll()
    }
}

/// SplitMix64 seeded from a tree's identity: the same tree grows the same crown every time.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UUID) {
        let bytes = seed.uuid
        var value: UInt64 = 0x9E37_79B9_7F4A_7C15
        withUnsafeBytes(of: bytes) { raw in
            for byte in raw { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        }
        state = value
    }

    mutating func unit() -> Float {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
