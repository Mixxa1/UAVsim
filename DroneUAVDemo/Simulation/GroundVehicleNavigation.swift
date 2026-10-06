import Foundation
import simd

/// Imported-world mesh cells are broad-phase buckets, not solid blocks. Separate walls
/// from road support once, then use narrow wall sections for route planning. Wheels must
/// not collide continuously with the very triangles supporting them.
struct GroundVehicleObstacleField {
    let collisionObstacles: [CollisionObstacle]
    let contactIndex: CollisionObstacleSpatialIndex
    let navigationObstacles: [CollisionObstacle]
    let index: GroundVehicleNavigationIndex

    init(obstacles: [CollisionObstacle], groundY: Float, height: Float) {
        var contacts: [CollisionObstacle] = []
        var blockers: [CollisionObstacle] = []
        var sections = Set<[Int]>()
        for obstacle in obstacles where obstacle.topY > groundY + 0.25 && obstacle.baseY < groundY + height {
            guard let triangles = obstacle.meshTriangles, !triangles.isEmpty else {
                // The shared padded-box sweep is a conservative aircraft envelope: at a box
                // corner its square padding extends beyond the contact sphere. The car needs
                // the actual box faces/edges, otherwise a slender trunk produces a phantom hit.
                if let half = obstacle.planarHalfExtents {
                    let c = cos(obstacle.yawRadians), s = sin(obstacle.yawRadians)
                    var vertices: [SIMD3<Float>] = []
                    for y in [obstacle.baseY, obstacle.topY] {
                        for z in [-half.y, half.y] { for x in [-half.x, half.x] {
                            vertices.append(SIMD3<Float>(obstacle.center.x + c * x - s * z, y,
                                obstacle.center.z + s * x + c * z))
                        } }
                    }
                    let faces = [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1],
                        [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]]
                    let triangles = faces.flatMap { face in
                        [[face[0], face[1], face[2]], [face[0], face[2], face[3]]].compactMap { ids in
                            CollisionMeshTriangle(point0: vertices[ids[0]], point1: vertices[ids[1]], point2: vertices[ids[2]])
                        }
                    }
                    contacts.append(CollisionObstacle(id: obstacle.id, center: obstacle.center,
                        radius: obstacle.radius, source: obstacle.source, baseY: obstacle.baseY, topY: obstacle.topY,
                        planarHalfExtents: half, yawRadians: obstacle.yawRadians, meshTriangles: triangles,
                        planarFootprint: obstacle.planarFootprint, acousticSurface: obstacle.acousticSurface))
                } else { contacts.append(obstacle) }
                blockers.append(obstacle); continue
            }
            let walls = triangles.filter {
                abs($0.normal.y) < 0.94 && $0.maximum.y > groundY + 0.25 && $0.minimum.y < groundY + height
            }
            guard !walls.isEmpty else { continue }
            contacts.append(CollisionObstacle(id: obstacle.id, center: obstacle.center,
                radius: obstacle.radius, source: obstacle.source, baseY: obstacle.baseY, topY: obstacle.topY,
                planarHalfExtents: obstacle.planarHalfExtents, yawRadians: obstacle.yawRadians,
                meshTriangles: walls, planarFootprint: obstacle.planarFootprint, acousticSurface: obstacle.acousticSurface))
            if !obstacle.source.hasPrefix("world.mesh.cell") {
                blockers.append(obstacle); continue
            }
            for triangle in walls {
                // A facade cut at body height becomes a narrow 2D segment. This preserves
                // streets passing through a mesh bucket without opening a path through walls.
                let y = min(triangle.maximum.y - 0.01, max(triangle.minimum.y + 0.01, groundY + height * 0.5))
                let vertices = [triangle.point0, triangle.point1, triangle.point2]
                var points: [SIMD2<Float>] = []
                for i in 0..<3 {
                    let a = vertices[i], b = vertices[(i + 1) % 3]
                    if abs(a.y - y) < 0.001 { points.append(SIMD2<Float>(a.x, a.z)) }
                    if (a.y < y) != (b.y < y) {
                        let p = a + (b - a) * ((y - a.y) / (b.y - a.y))
                        points.append(SIMD2<Float>(p.x, p.z))
                    }
                }
                guard points.count >= 2 else { continue }
                var a = points[0], b = points[1]
                for p in points { for q in points where simd_distance(p, q) > simd_distance(a, b) { a = p; b = q } }
                if a.x > b.x || (a.x == b.x && a.y > b.y) { swap(&a, &b) }
                let key = [a.x, a.y, b.x, b.y].map { Int(($0 * 5).rounded()) }
                guard sections.insert(key).inserted else { continue }
                let delta = b - a, centre = (a + b) * 0.5
                blockers.append(CollisionObstacle(id: obstacle.id, center: SIMD3<Float>(centre.x, y, centre.y),
                    radius: simd_length(delta) * 0.5 + 0.08, source: obstacle.source,
                    baseY: triangle.minimum.y, topY: triangle.maximum.y,
                    planarHalfExtents: SIMD2<Float>(simd_length(delta) * 0.5 + 0.08, 0.08),
                    yawRadians: atan2(delta.y, delta.x)))
            }
        }
        collisionObstacles = contacts; navigationObstacles = blockers
        contactIndex = CollisionObstacleSpatialIndex(obstacles: contacts)
        index = GroundVehicleNavigationIndex(blockers)
    }
}

/// A small spatial lookup keeps the bounded A* search independent of mesh triangle count.
struct GroundVehicleNavigationIndex {
    private let obstacles: [CollisionObstacle]
    private var cells: [SIMD2<Int>: [Int]] = [:]
    private static let cell: Float = 16

    init(_ obstacles: [CollisionObstacle]) {
        self.obstacles = obstacles
        for (i, obstacle) in obstacles.enumerated() {
            let extent: SIMD2<Float>
            if let outline = obstacle.planarFootprint, !outline.isEmpty {
                let low = outline.reduce(outline[0], simd_min), high = outline.reduce(outline[0], simd_max)
                extent = simd_max(abs(low - obstacle.planarCenter), abs(high - obstacle.planarCenter))
            } else if let h = obstacle.planarHalfExtents {
                let c = abs(cos(obstacle.yawRadians)), s = abs(sin(obstacle.yawRadians))
                extent = SIMD2<Float>(h.x * c + h.y * s, h.x * s + h.y * c)
            } else { extent = SIMD2<Float>(repeating: obstacle.radius) }
            let low = Self.key(obstacle.planarCenter - extent), high = Self.key(obstacle.planarCenter + extent)
            for x in low.x...high.x { for z in low.y...high.y { cells[SIMD2<Int>(x, z), default: []].append(i) } }
        }
    }

    func clear(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ margin: Float) -> Bool {
        let low = Self.key(simd_min(a, b) - SIMD2<Float>(repeating: margin))
        let high = Self.key(simd_max(a, b) + SIMD2<Float>(repeating: margin))
        var seen = Set<Int>()
        for x in low.x...high.x { for z in low.y...high.y {
            for i in cells[SIMD2<Int>(x, z)] ?? [] where seen.insert(i).inserted {
                if GroundVehicleNavigation.distance(a, b, obstacles[i]) < margin { return false }
            }
        } }
        return true
    }

    private static func key(_ p: SIMD2<Float>) -> SIMD2<Int> {
        SIMD2<Int>(Int(floor(p.x / cell)), Int(floor(p.y / cell)))
    }
}

/// Bounded local A*, with swept-clearance edges and no diagonal corner cutting.
/// Replanning is deliberately much slower than the physics loop.
struct GroundVehicleNavigation {
    private(set) var path: [SIMD2<Float>] = []
    private var countdown: Float = 0
    private var lastGoal = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
    private(set) var expandedNodes = 0
    static let cellSize: Float = 5
    static let halfCells = 24
    static let maximumExpansions = 2200

    mutating func reset() { path = []; countdown = 0 }

    mutating func waypoint(position: SIMD2<Float>, goal: SIMD2<Float>, clearance: Float,
                           deltaTime: Float, obstacles: [CollisionObstacle],
                           obstacleIndex: GroundVehicleNavigationIndex? = nil,
                           traversable: (SIMD2<Float>) -> Bool) -> SIMD2<Float>? {
        countdown -= deltaTime
        let index = obstacleIndex ?? GroundVehicleNavigationIndex(obstacles)
        // Advance the aim point as soon as the next complete corridor opens. Keeping an
        // already passed grid corner made the car circle it; proximity alone cut corners.
        while path.count > 1, index.clear(position, path[1], clearance) {
            let next = path[1]
            let samples = max(1, Int(ceil(simd_distance(position, next) / Self.cellSize)))
            guard (1...samples).allSatisfy({ traversable(position + (next - position) * (Float($0) / Float(samples))) }) else { break }
            path.removeFirst()
        }
        let nextBlocked = path.first.map {
            !index.clear(position, $0, clearance)
        } ?? false
        let reachedPartial = path.count == 1 && simd_distance(path[0], position) < 4
            && simd_distance(path[0], goal) > 0.5
        // Keep an existing clear route. Recentring the grid every 0.8 s moved its corners
        // under the truck and alternated steering/braking in front of a single trunk.
        if (countdown <= 0 && path.isEmpty) || simd_distance(lastGoal, goal) > 12 || nextBlocked || reachedPartial {
            path = plan(position: position, goal: goal, clearance: clearance,
                        obstacles: obstacles, obstacleIndex: index, traversable: traversable)
            lastGoal = goal
            countdown = path.isEmpty ? 1.2 : 0.8
        }
        return path.first
    }

    static func clear(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ margin: Float, _ obstacles: [CollisionObstacle]) -> Bool {
        !obstacles.contains { distance(a, b, $0) < margin }
    }

    /// Buildings imported from OSM can have concave outlines. Keep those streets usable;
    /// their bounding rectangle is only a query proxy, not the actual road boundary.
    static func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ obstacle: CollisionObstacle) -> Float {
        guard let outline = obstacle.planarFootprint, outline.count >= 3 else {
            return obstacle.planarSignedDistance(fromSegment: a, to: b)
        }
        if obstacle.containsPoint(SIMD3<Float>(a.x, obstacle.center.y, a.y)) ||
            obstacle.containsPoint(SIMD3<Float>(b.x, obstacle.center.y, b.y)) { return -1 }
        var distance: Float = .greatestFiniteMagnitude
        func pointDistance(_ p: SIMD2<Float>, _ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float {
            let d = v - u
            return simd_distance(p, u + d * max(0, min(1, simd_dot(p - u, d) / max(0.000001, simd_length_squared(d)))))
        }
        func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Float { u.x * v.y - u.y * v.x }
        for i in outline.indices {
            let u = outline[i], v = outline[(i + 1) % outline.count]
            if cross(b - a, u - a) * cross(b - a, v - a) <= 0,
               cross(v - u, a - u) * cross(v - u, b - u) <= 0,
               min(a.x, b.x) <= max(u.x, v.x), max(a.x, b.x) >= min(u.x, v.x),
               min(a.y, b.y) <= max(u.y, v.y), max(a.y, b.y) >= min(u.y, v.y) { return 0 }
            distance = min(distance, pointDistance(a, u, v), pointDistance(b, u, v),
                pointDistance(u, a, b), pointDistance(v, a, b))
        }
        return distance
    }

    private mutating func plan(position: SIMD2<Float>, goal: SIMD2<Float>, clearance: Float,
                               obstacles: [CollisionObstacle], obstacleIndex: GroundVehicleNavigationIndex?,
                               traversable: (SIMD2<Float>) -> Bool) -> [SIMD2<Float>] {
        expandedNodes = 0
        let index = obstacleIndex ?? GroundVehicleNavigationIndex(obstacles)
        func supported(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Bool {
            let samples = max(1, Int(ceil(simd_distance(a, b) / Self.cellSize)))
            return (1...samples).allSatisfy { traversable(a + (b - a) * (Float($0) / Float(samples))) }
        }
        if simd_distance(position, goal) < 100, index.clear(position, goal, clearance), supported(position, goal) {
            return [goal]
        }
        let width = Self.halfCells * 2 + 1
        let count = width * width
        let origin = position - SIMD2<Float>(repeating: Float(Self.halfCells) * Self.cellSize)
        func point(_ index: Int) -> SIMD2<Float> {
            origin + SIMD2<Float>(Float(index % width), Float(index / width)) * Self.cellSize
        }
        func gridIndex(_ point: SIMD2<Float>) -> Int {
            let offset = (point - origin) / Self.cellSize
            let x = min(width - 1, max(0, Int(offset.x.rounded())))
            let z = min(width - 1, max(0, Int(offset.y.rounded())))
            return z * width + x
        }
        let start = Self.halfCells * width + Self.halfCells
        let end = gridIndex(goal)
        var cost = [Float](repeating: .infinity, count: count)
        var parent = [Int](repeating: -1, count: count)
        var closed = [Bool](repeating: false, count: count)
        var walkable = [Int8](repeating: -1, count: count)
        func isFree(_ i: Int) -> Bool {
            if walkable[i] >= 0 { return walkable[i] == 1 }
            let p = point(i)
            let free = traversable(p) && index.clear(p, p, clearance)
            walkable[i] = free ? 1 : 0
            return free
        }
        struct Entry { var index: Int; var score: Float }
        var heap: [Entry] = []
        func push(_ entry: Entry) {
            heap.append(entry)
            var i = heap.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                if heap[p].score <= heap[i].score { break }
                heap.swapAt(p, i); i = p
            }
        }
        func pop() -> Entry {
            let best = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while i * 2 + 1 < heap.count {
                    var child = i * 2 + 1
                    if child + 1 < heap.count, heap[child + 1].score < heap[child].score { child += 1 }
                    if heap[i].score <= heap[child].score { break }
                    heap.swapAt(i, child); i = child
                }
            }
            return best
        }
        cost[start] = 0
        push(Entry(index: start, score: simd_distance(point(start), point(end))))
        var closest = start
        var closestRange = simd_distance(point(start), point(end))
        while !heap.isEmpty, expandedNodes < Self.maximumExpansions {
            let current = pop().index
            if closed[current] { continue }
            closed[current] = true
            expandedNodes += 1
            let range = simd_distance(point(current), point(end))
            if range < closestRange { closest = current; closestRange = range }
            if current == end { closest = end; break }
            let x = current % width, z = current / width
            for dz in -1...1 {
                for dx in -1...1 where dx != 0 || dz != 0 {
                    let nx = x + dx, nz = z + dz
                    guard nx >= 0, nx < width, nz >= 0, nz < width else { continue }
                    let next = nz * width + nx
                    guard !closed[next], isFree(next) else { continue }
                    if dx != 0, dz != 0, (!isFree(z * width + nx) || !isFree(nz * width + x)) { continue }
                    guard index.clear(point(current), point(next), clearance) else { continue }
                    let g = cost[current] + simd_distance(point(current), point(next))
                    if g < cost[next] {
                        cost[next] = g; parent[next] = current
                        push(Entry(index: next, score: g + simd_distance(point(next), point(end))))
                    }
                }
            }
        }
        guard closest != start else { return [] }
        var result: [SIMD2<Float>] = []
        var cursor = closest
        while cursor != start, cursor >= 0 {
            result.append(point(cursor)); cursor = parent[cursor]
        }
        result.reverse()
        // Skip grid corners only when the whole swept corridor is free.
        while result.count > 1, index.clear(position, result[1], clearance), supported(position, result[1]) { result.removeFirst() }
        return result
    }
}

/// Checks attainable steering and braking trajectories before the driver commits to a turn.
/// The three overlapping swept body discs include both overhangs; a clear centre line alone
/// is insufficient for an eight-metre truck passing a thin tree or turning beside a wall.
enum GroundVehicleDrivingSafety {
    struct Command { var speed: Float; var steering: Float }
    private struct Forecast { var position: SIMD2<Float>; var yaw: Float }

    static func command(preferred: Command, position: SIMD3<Float>, yaw: Float,
                        speed: Float, lateralSpeed: Float, steering: Float, waypoint: SIMD2<Float>,
                        profile: GroundVehicleProfile, acceleration: Float, braking: Float, friction: Float,
                        steeringRange: ClosedRange<Float>,
                        index: GroundVehicleNavigationIndex, ground: (SIMD3<Float>, Float) -> Float) -> Command {
        func forecast(_ command: Command) -> Forecast? {
            var p = SIMD2<Float>(position.x, position.z), a = yaw, v = speed, slip = lateralSpeed, s = steering
            var elapsed: Float = 0
            let offsets: [Float] = [-profile.size.z * 0.32, 0, profile.size.z * 0.32]
            func centres(_ p: SIMD2<Float>, _ yaw: Float) -> [SIMD2<Float>] {
                let forward = SIMD2<Float>(-sin(yaw), -cos(yaw))
                return offsets.map { p + forward * $0 }
            }
            var previous = centres(p, a)
            // Drive through the near manoeuvre, then require room to come to a complete stop.
            // This also checks a brake command's curved path while its wheels straighten.
            for _ in 0..<120 {
                let dt = max(0.025, min(0.15, 1.75 / max(1, abs(v))))
                let targetSpeed: Float = elapsed < 1.2 ? command.speed : 0
                s += max(-profile.steeringRate * dt, min(profile.steeringRate * dt, command.steering - s))
                let rate = abs(targetSpeed) > abs(v) && targetSpeed * v >= 0 ? acceleration : braking
                v += max(-rate * dt, min(rate * dt, targetSpeed - v))
                let yawRate = max(-friction * 9.81 / max(1, abs(v)),
                    min(friction * 9.81 / max(1, abs(v)), v * tan(s) / profile.wheelbase))
                a = GroundVehicleRuntime.angle(a + yawRate * dt)
                slip *= exp(-friction * 5 * dt)
                let forward = SIMD2<Float>(-sin(a), -cos(a)), side = SIMD2<Float>(cos(a), -sin(a))
                let next = p + (forward * v + side * slip) * dt
                let body = centres(next, a)
                for i in body.indices where !index.clear(previous[i], body[i], profile.clearance) { return nil }
                let floor = ground(SIMD3<Float>(next.x, position.y, next.y), 0.3)
                guard floor.isFinite, abs(floor - position.y) < 5 else { return nil }
                let nose = next + forward * (v < 0 ? -profile.size.z * 0.5 : profile.size.z * 0.5)
                let noseHeight = ground(SIMD3<Float>(nose.x, position.y, nose.y), 0.3)
                guard noseHeight.isFinite, abs(noseHeight - position.y) < 5 else { return nil }
                p = next; previous = body; elapsed += dt
                if elapsed >= 1.2 && abs(v) < 0.01 { return Forecast(position: p, yaw: a) }
            }
            return nil
        }
        if forecast(preferred) != nil { return preferred }
        let candidates = [preferred.steering, preferred.steering + 0.2, preferred.steering - 0.2,
            preferred.steering + 0.4, preferred.steering - 0.4, steering, 0, steeringRange.lowerBound, steeringRange.upperBound]
            .map { max(steeringRange.lowerBound, min(steeringRange.upperBound, $0)) }
        var best: (Command, Float)?
        for targetSpeed in [preferred.speed, preferred.speed * 0.5, preferred.speed * 0.2, 0] {
            for targetSteering in candidates {
                let curveSpeed = sqrt(friction * 9.81 / max(0.002, abs(tan(targetSteering) / profile.wheelbase))) * 0.82
                let candidate = Command(speed: max(-curveSpeed, min(curveSpeed, targetSpeed)), steering: targetSteering)
                guard let future = forecast(candidate) else { continue }
                let delta = waypoint - future.position
                let headingError = abs(GroundVehicleRuntime.angle(atan2(-delta.x, -delta.y) - future.yaw))
                let score = simd_length(delta) + headingError * 2
                    + abs(targetSteering - preferred.steering) * 3
                    + (abs(preferred.speed) - abs(candidate.speed)) * 0.35
                if best == nil || score < best!.1 { best = (candidate, score) }
            }
        }
        // An external impact, lost brakes or a suddenly blocked road can leave no attainable
        // safe trajectory. Apply the brakes; the physical collision solver still owns the hit.
        return best?.0 ?? Command(speed: 0, steering: preferred.steering)
    }
}
