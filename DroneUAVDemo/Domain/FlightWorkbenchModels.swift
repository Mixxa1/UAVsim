import Foundation
import simd

/// Fixed capacity history: no per-frame array shifting or unbounded memory growth.
struct FlightHistory<Value> {
    struct Entry { let time: Float; let value: Value }
    private var storage: [Entry?]
    private var next = 0
    private(set) var count = 0
    init(capacity: Int = 1201) { storage = Array(repeating: nil, count: max(2, capacity)) }
    var entries: [Entry] {
        let first = (next - count + storage.count) % storage.count
        return (0..<count).compactMap { storage[(first + $0) % storage.count] }
    }
    var oldestTime: Float? { guard count > 0 else { return nil }; return storage[(next - count + storage.count) % storage.count]?.time }
    mutating func append(time: Float, value: Value) {
        storage[next] = Entry(time: time, value: value)
        next = (next + 1) % storage.count
        count = min(count + 1, storage.count)
    }
    mutating func discard(after time: Float) {
        let kept = entries.filter { $0.time <= time }
        removeAll()
        for entry in kept { append(time: entry.time, value: entry.value) }
    }
    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count); next = 0; count = 0
    }
    func entry(at time: Float) -> Entry? {
        guard count > 0 else { return nil }
        for offset in 1...count {
            let index = (next - offset + storage.count) % storage.count
            if let entry = storage[index], entry.time <= time { return entry }
        }
        return storage[(next - count + storage.count) % storage.count]
    }
    func bracket(at time: Float) -> (earlier: Entry, later: Entry)? {
        guard count > 0 else { return nil }
        var later = storage[(next - 1 + storage.count) % storage.count]!
        for offset in 1...count {
            let entry = storage[(next - offset + storage.count) % storage.count]!
            if entry.time <= time { return (entry, later) }
            later = entry
        }
        return (later, later)
    }
}

extension TerrainPreset {
    var supportsRelief: Bool { self == .field || self == .forest || self == .gridDemo }
}

extension TerrainConfiguration {
    var usesRelief: Bool { reliefEnabled && preset.supportsRelief }
    var reliefResolution: Int { 384 }
    var reliefCellSize: Float { (beltOuterRadius + 24) * 2 / Float(reliefResolution) }
    /// Seeded gradient-free lattice noise. No periodic waves or repeated hill tiles.
    private func reliefNoise(_ x: Float, _ z: Float, salt: UInt64) -> Float {
        let ix = Int64(floor(x)), iz = Int64(floor(z))
        func hash(_ a: Int64, _ b: Int64) -> Float {
            var n = UInt64(bitPattern: a) &* 0x9E3779B185EBCA87 ^ UInt64(bitPattern: b) &* 0xC2B2AE3D27D4EB4F ^ seed ^ salt
            n = (n ^ (n >> 30)) &* 0xBF58476D1CE4E5B9
            n = (n ^ (n >> 27)) &* 0x94D049BB133111EB
            n ^= n >> 31
            return Float(n & 0xFFFFFF) / Float(0xFFFFFF)
        }
        func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
        let u = fade(x - Float(ix)), v = fade(z - Float(iz))
        let a = hash(ix, iz), b = hash(ix + 1, iz), c = hash(ix, iz + 1), d = hash(ix + 1, iz + 1)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }
    private func heightAtVertex(x: Float, z: Float) -> Float {
        guard usesRelief else { return 0 }
        let distance = simd_length(SIMD2<Float>(x, z))
        let plateau = max(70, safeSpawnRadius * 2)
        let t = min(1, max(0, (distance - plateau) / max(65, worldHalfExtent * 0.08)))
        guard t > 0 else { return 0 }
        let fade = t * t * (3 - 2 * t)
        let scale = max(180, worldHalfExtent * 0.28)
        let px = x / scale, pz = z / scale
        // Domain warping breaks lattice alignment. Different frequency bands form
        // mountain chains, shoulders, small gullies and broad lowland patches.
        let wx = px + (reliefNoise(px * 0.5, pz * 0.5, salt: 31) - 0.5) * 1.8
        let wz = pz + (reliefNoise(px * 0.5, pz * 0.5, salt: 79) - 0.5) * 1.8
        let continental = reliefNoise(wx * 0.45, wz * 0.45, salt: 101)
        let mountainWeight = min(1, max(0, (continental - 0.26) / 0.42))
        var ridges: Float = 0, amplitude: Float = 0.55, frequency: Float = 1
        for octave in 0..<5 {
            // Attenuate features smaller than the mesh can resolve. Sampling them
            // without a low-pass filter produces diagonal dents along grid edges.
            let samples = scale / (frequency * reliefCellSize)
            let resolutionBlend = min(1, max(0, (samples - 3) / 3))
            guard resolutionBlend > 0 else { break }
            let weight = resolutionBlend * resolutionBlend * (3 - 2 * resolutionBlend)
            let noise = reliefNoise(wx * frequency, wz * frequency, salt: UInt64(301 + octave * 53))
            let centered = noise * 2 - 1
            let ridge = 1 - sqrt(centered * centered + 0.025) / sqrt(1.025)
            ridges += ridge * ridge * amplitude * weight
            amplitude *= 0.48; frequency *= 2.05
        }
        let valleyNoise = reliefNoise(wx * 0.72 + 12, wz * 0.72 - 5, salt: 907)
        let valleyDistance = (valleyNoise - 0.5) * 12
        let valley = exp(-valleyDistance * valleyDistance)
        let lowlands = reliefNoise(wx * 1.6, wz * 1.6, salt: 499) * 0.13
        let shape = max(0.015, (0.12 + ridges * (0.24 + mountainWeight * 0.9) + lowlands) * (1 - valley * 0.78))
        return min(250, max(10, reliefAmplitude)) * shape * fade
    }
    func reliefVegetationDensity(x: Float, z: Float) -> Float {
        let patch = reliefNoise(x / 95, z / 95, salt: 1301)
        let altitude = surfaceHeight(x: x, z: z) / max(10, reliefAmplitude)
        return max(0.03, patch * (1 - min(0.9, altitude * 0.7)))
    }
    /// Interpolates the very same two triangles emitted by `reliefCorners`.
    func surfaceHeight(x: Float, z: Float) -> Float {
        guard usesRelief, x.isFinite, z.isFinite else { return 0 }
        let step = reliefCellSize
        let origin = -(beltOuterRadius + 24)
        let gx = (x - origin) / step, gz = (z - origin) / step
        let ix = floor(gx), iz = floor(gz)
        let u = gx - ix, v = gz - iz
        let x0 = origin + ix * step, z0 = origin + iz * step
        let a = heightAtVertex(x: x0, z: z0)
        let b = heightAtVertex(x: x0 + step, z: z0)
        let c = heightAtVertex(x: x0, z: z0 + step)
        let d = heightAtVertex(x: x0 + step, z: z0 + step)
        return u + v <= 1 ? a + (b - a) * u + (c - a) * v
            : d + (c - d) * (1 - u) + (b - d) * (1 - v)
    }
    func surfaceNormal(x: Float, z: Float) -> SIMD3<Float> {
        let epsilon: Float = 0.2
        return simd_normalize(SIMD3<Float>(
            surfaceHeight(x: x - epsilon, z: z) - surfaceHeight(x: x + epsilon, z: z),
            2 * epsilon,
            surfaceHeight(x: x, z: z - epsilon) - surfaceHeight(x: x, z: z + epsilon)))
    }
    var reliefVertices: [SIMD3<Float>] {
        guard usesRelief else { return [] }
        let n = reliefResolution, origin = -(beltOuterRadius + 24), step = reliefCellSize
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity((n + 1) * (n + 1))
        for iz in 0...n { for ix in 0...n {
            let x = origin + Float(ix) * step, z = origin + Float(iz) * step
            vertices.append(SIMD3(x, heightAtVertex(x: x, z: z), z))
        }}
        return vertices
    }
    /// Exact intersections with the rendered grid, visiting only cells crossed by the ray.
    /// Heights are cached by the scene; sensor queries never regenerate noise or test the full mesh.
    func reliefRayDistance(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float, heights: [Float]) -> Float? {
        let n = reliefResolution, side = n + 1, extent = beltOuterRadius + 24, cell = reliefCellSize
        guard usesRelief, heights.count == side * side, maxDistance > 0, simd_length_squared(direction) > 0.000001 else { return nil }
        let d = simd_normalize(direction)
        var entry: Float = 0, exit = maxDistance
        for axis in [0, 2] {
            if abs(d[axis]) < 0.000001 {
                if abs(origin[axis]) > extent { return nil }
            } else {
                let a = (-extent - origin[axis]) / d[axis], b = (extent - origin[axis]) / d[axis]
                entry = max(entry, min(a, b)); exit = min(exit, max(a, b))
            }
        }
        guard entry <= exit else { return nil }
        let first = origin + d * min(exit, entry + 0.0001)
        var x = min(n - 1, max(0, Int(floor((first.x + extent) / cell))))
        var z = min(n - 1, max(0, Int(floor((first.z + extent) / cell))))
        let sx = d.x >= 0 ? 1 : -1, sz = d.z >= 0 ? 1 : -1
        let tx = abs(d.x) > 0.000001 ? cell / abs(d.x) : Float.infinity
        let tz = abs(d.z) > 0.000001 ? cell / abs(d.z) : Float.infinity
        var nextX = tx.isFinite ? (-extent + Float(x + (sx > 0 ? 1 : 0)) * cell - origin.x) / d.x : Float.infinity
        var nextZ = tz.isFinite ? (-extent + Float(z + (sz > 0 ? 1 : 0)) * cell - origin.z) / d.z : Float.infinity
        func hit(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
            let e1 = b - a, e2 = c - a, p = simd_cross(d, e2), det = simd_dot(e1, p)
            guard abs(det) > 0.000001 else { return nil }
            let v = origin - a, u = simd_dot(v, p) / det
            guard u >= -0.00001, u <= 1.00001 else { return nil }
            let q = simd_cross(v, e1), w = simd_dot(d, q) / det
            guard w >= -0.00001, u + w <= 1.00001 else { return nil }
            let distance = simd_dot(e2, q) / det
            return distance >= entry - 0.001 && distance <= exit && distance > 0.0001 ? distance : nil
        }
        var t = entry
        for _ in 0...(n * 2 + 2) {
            guard x >= 0, x < n, z >= 0, z < n, t <= exit else { break }
            let i = z * side + x, px = -extent + Float(x) * cell, pz = -extent + Float(z) * cell
            let a = SIMD3(px, heights[i], pz), b = SIMD3(px + cell, heights[i + 1], pz)
            let c = SIMD3(px, heights[i + side], pz + cell), e = SIMD3(px + cell, heights[i + side + 1], pz + cell)
            if t == entry {
                let u = min(1, max(0, (first.x - px) / cell)), v = min(1, max(0, (first.z - pz) / cell))
                let h = u + v <= 1 ? a.y + (b.y - a.y) * u + (c.y - a.y) * v : e.y + (c.y - e.y) * (1 - u) + (b.y - e.y) * (1 - v)
                if first.y < h - 0.001 { return max(0.0001, entry) }
            }
            let left = hit(a, c, b), right = hit(b, c, e)
            if let left { return min(left, right ?? left) }
            if let right { return right }
            if nextX < nextZ { t = nextX; nextX += tx; x += sx }
            else if nextZ < nextX { t = nextZ; nextZ += tz; z += sz }
            else {
                if !nextX.isFinite { break }
                t = nextX; nextX += tx; nextZ += tz; x += sx; z += sz
            }
        }
        return nil
    }

    var reliefCorners: [SIMD3<Float>] {
        guard usesRelief else { return [] }
        let n = reliefResolution, vertices = reliefVertices
        var corners: [SIMD3<Float>] = []; corners.reserveCapacity(n * n * 6)
        for iz in 0..<n { for ix in 0..<n {
            let i = iz * (n + 1) + ix
            let a = vertices[i], b = vertices[i + 1], c = vertices[i + n + 1], d = vertices[i + n + 2]
            corners.append(contentsOf: [a, c, b, b, c, d])
        }}
        return corners
    }

}

extension WeatherModel {
    /// Continuous, deterministic wind field. Sampling is independent of frame rate and rewind.
    func wind(at position: SIMD3<Float>, time: Float, groundHeight: Float = 0,
              groundNormal: SIMD3<Float> = SIMD3(0, 1, 0)) -> SIMD3<Float> {
        guard spatialWindEnabled else { return windVector }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite, time.isFinite else { return .zero }
        let speed = max(0, windSpeedMps.isFinite ? windSpeedMps : 0)
        guard speed > 0 else { return .zero }
        let theta = windDirectionDeg * .pi / 180
        let direction = SIMD3<Float>(sin(theta), 0, cos(theta))
        let height = max(0, position.y - groundHeight)
        let shear = min(1.5, 0.45 + 0.55 * pow(max(0.2, height) / 10, 0.14))
        let strength = min(1, max(0, gusts))
        let phase = position.x * 0.013 + position.z * 0.009 - time * 0.6
        let gust = 1 + strength * (0.28 * sin(phase) + 0.17 * sin(position.z * 0.027 + time * 1.1))
        let cross = SIMD3<Float>(direction.z, 0, -direction.x)
            * speed * strength * 0.16 * sin(position.x * 0.019 - time * 0.7)
        let slopeLift = groundNormal.y > 0.1 ? -simd_dot(direction, groundNormal) / groundNormal.y : 0
        let vertical = speed * min(0.45, max(-0.45, slopeLift)) * exp(-height / 80)
            + speed * strength * 0.08 * sin(phase * 1.7)
        return direction * speed * shear * gust + cross + SIMD3(0, vertical, 0)
    }
}
