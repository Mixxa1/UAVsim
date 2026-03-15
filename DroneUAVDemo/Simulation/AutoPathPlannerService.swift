import Foundation
import simd

enum NavigationPathStatus: String {
    case idle
    case valid
    case recomputing
    case blocked
}

struct NavigationPathSnapshot {
    var status: NavigationPathStatus
    var currentWaypointIndex: Int
    var remainingWaypoints: Int
    var pathLengthMeters: Float
    var remainingDistanceMeters: Float
    var waypoints: [SIMD3<Float>]
    var start: SIMD3<Float>?
    var goal: SIMD3<Float>?
    var reason: String

    static let idle = NavigationPathSnapshot(
        status: .idle,
        currentWaypointIndex: 0,
        remainingWaypoints: 0,
        pathLengthMeters: 0.0,
        remainingDistanceMeters: 0.0,
        waypoints: [],
        start: nil,
        goal: nil,
        reason: "idle"
    )
}

final class AutoPathPlannerService {
    private struct GridSignature: Equatable {
        let terrain: TerrainPreset
        let mapScale: MapScale
        let densityBucket: Int
        let seed: UInt64
        let worldExtentBucket: Int
        let obstacleHash: Int
    }

    private struct PlanSignature: Equatable {
        let modeTag: String
        let goalCell: NavigationGrid.Cell
    }

    private struct NavigationGrid {
        struct Cell: Hashable {
            let x: Int
            let z: Int
        }

        let cellSize: Float
        let halfExtent: Float
        let width: Int
        let height: Int
        let originX: Float
        let originZ: Float
        var blocked: [UInt8]
        var penalty: [Float]

        init(cellSize: Float, halfExtent: Float) {
            self.cellSize = max(0.75, cellSize)
            self.halfExtent = max(4.0, halfExtent)
            self.originX = -self.halfExtent
            self.originZ = -self.halfExtent

            let side = max(3, Int(ceil((self.halfExtent * 2.0) / self.cellSize)) + 1)
            self.width = side
            self.height = side
            self.blocked = Array(repeating: 0, count: side * side)
            self.penalty = Array(repeating: 0.0, count: side * side)
        }

        func index(_ cell: Cell) -> Int {
            cell.z * width + cell.x
        }

        func contains(_ cell: Cell) -> Bool {
            cell.x >= 0 && cell.z >= 0 && cell.x < width && cell.z < height
        }

        func worldXZ(for cell: Cell) -> SIMD2<Float> {
            SIMD2<Float>(
                originX + Float(cell.x) * cellSize,
                originZ + Float(cell.z) * cellSize
            )
        }

        func cell(forWorldXZ world: SIMD2<Float>) -> Cell? {
            let fx = (world.x - originX) / cellSize
            let fz = (world.y - originZ) / cellSize
            let cx = Int(round(fx))
            let cz = Int(round(fz))
            let cell = Cell(x: cx, z: cz)
            return contains(cell) ? cell : nil
        }

        func cell(forWorld position: SIMD3<Float>) -> Cell? {
            cell(forWorldXZ: SIMD2<Float>(position.x, position.z))
        }

        func nearestFreeCell(to world: SIMD3<Float>, maxSearchRadius: Int = 24) -> Cell? {
            guard let seed = cell(forWorld: world) else {
                return nil
            }
            if !isBlocked(seed) {
                return seed
            }

            for ring in 1...maxSearchRadius {
                let x0 = seed.x - ring
                let x1 = seed.x + ring
                let z0 = seed.z - ring
                let z1 = seed.z + ring
                for x in x0...x1 {
                    let top = Cell(x: x, z: z0)
                    if contains(top), !isBlocked(top) { return top }
                    let bottom = Cell(x: x, z: z1)
                    if contains(bottom), !isBlocked(bottom) { return bottom }
                }
                if z1 - z0 > 1 {
                    for z in (z0 + 1)..<z1 {
                        let left = Cell(x: x0, z: z)
                        if contains(left), !isBlocked(left) { return left }
                        let right = Cell(x: x1, z: z)
                        if contains(right), !isBlocked(right) { return right }
                    }
                }
            }
            return nil
        }

        func isBlocked(_ cell: Cell) -> Bool {
            guard contains(cell) else { return true }
            return blocked[index(cell)] != 0
        }

        func penaltyAt(_ cell: Cell) -> Float {
            guard contains(cell) else { return 1.0 }
            return penalty[index(cell)]
        }

        func neighbors(for cell: Cell, allowDiagonal: Bool) -> [Cell] {
            var result: [Cell] = []
            result.reserveCapacity(8)

            for dz in -1...1 {
                for dx in -1...1 {
                    if dx == 0, dz == 0 { continue }
                    if !allowDiagonal, dx != 0, dz != 0 { continue }

                    let candidate = Cell(x: cell.x + dx, z: cell.z + dz)
                    if !contains(candidate) || isBlocked(candidate) {
                        continue
                    }

                    if dx != 0, dz != 0 {
                        let sideA = Cell(x: cell.x + dx, z: cell.z)
                        let sideB = Cell(x: cell.x, z: cell.z + dz)
                        if isBlocked(sideA) || isBlocked(sideB) {
                            continue
                        }
                    }

                    result.append(candidate)
                }
            }

            return result
        }

        func hasLineOfSight(_ start: Cell, _ end: Cell) -> Bool {
            let startWorld = worldXZ(for: start)
            let endWorld = worldXZ(for: end)
            let direction = endWorld - startWorld
            let distance = simd_length(direction)
            if distance < 0.0001 { return true }

            let step = max(cellSize * 0.5, 0.4)
            let steps = max(1, Int(ceil(distance / step)))
            for index in 0...steps {
                let t = Float(index) / Float(steps)
                let sample = startWorld + direction * t
                guard let cell = cell(forWorldXZ: sample) else {
                    return false
                }
                if isBlocked(cell) {
                    return false
                }
            }
            return true
        }
    }

    private var gridSignature: GridSignature?
    private var grid: NavigationGrid?
    private var planSignature: PlanSignature?

    private var waypoints: [SIMD3<Float>] = []
    private var currentIndex: Int = 0
    private var pathLengthMeters: Float = 0.0
    private var startPoint: SIMD3<Float>?
    private var goalPoint: SIMD3<Float>?
    private var status: NavigationPathStatus = .idle
    private var statusReason: String = "idle"

    private(set) var lastPlanDurationMs: Double = 0.0
    private(set) var activeWaypointCount: Int = 0

    func invalidate() {
        planSignature = nil
        waypoints.removeAll(keepingCapacity: false)
        currentIndex = 0
        pathLengthMeters = 0.0
        startPoint = nil
        goalPoint = nil
        status = .idle
        statusReason = "idle"
        activeWaypointCount = 0
        lastPlanDurationMs = 0.0
    }

    func planIfNeeded(
        start: SIMD3<Float>,
        goal: SIMD3<Float>,
        terrain: TerrainConfiguration,
        obstacles: [CollisionObstacle],
        droneRadius: Float,
        modeTag: String,
        forceRecompute: Bool = false,
        reason: String = "periodic"
    ) {
        status = .recomputing
        statusReason = reason

        let gridBuildStart = CFAbsoluteTimeGetCurrent()
        guard ensureGrid(terrain: terrain, obstacles: obstacles, droneRadius: droneRadius) else {
            status = .blocked
            statusReason = "grid_build_failed"
            waypoints.removeAll(keepingCapacity: false)
            activeWaypointCount = 0
            lastPlanDurationMs = (CFAbsoluteTimeGetCurrent() - gridBuildStart) * 1000.0
            return
        }
        guard let grid else {
            status = .blocked
            statusReason = "missing_grid"
            waypoints.removeAll(keepingCapacity: false)
            activeWaypointCount = 0
            lastPlanDurationMs = (CFAbsoluteTimeGetCurrent() - gridBuildStart) * 1000.0
            return
        }

        guard let startCell = grid.nearestFreeCell(to: start),
              let goalCell = grid.nearestFreeCell(to: goal) else {
            status = .blocked
            statusReason = "no_free_start_or_goal"
            waypoints.removeAll(keepingCapacity: false)
            activeWaypointCount = 0
            planSignature = nil
            lastPlanDurationMs = (CFAbsoluteTimeGetCurrent() - gridBuildStart) * 1000.0
            return
        }

        let nextPlanSignature = PlanSignature(
            modeTag: modeTag,
            goalCell: goalCell
        )

        let shouldReplan = forceRecompute || planSignature != nextPlanSignature || waypoints.isEmpty || status == .blocked
        guard shouldReplan else {
            status = .valid
            statusReason = "cached"
            lastPlanDurationMs = 0.0
            return
        }

        let planStart = CFAbsoluteTimeGetCurrent()
        guard let cellPath = astar(grid: grid, start: startCell, goal: goalCell) else {
            status = .blocked
            statusReason = "astar_blocked"
            waypoints.removeAll(keepingCapacity: false)
            currentIndex = 0
            pathLengthMeters = 0.0
            startPoint = start
            goalPoint = goal
            activeWaypointCount = 0
            planSignature = nextPlanSignature
            lastPlanDurationMs = (CFAbsoluteTimeGetCurrent() - planStart) * 1000.0
            return
        }

        let simplifiedCells = simplifyPath(cellPath, grid: grid)
        let altitude = max(2.0, max(start.y, goal.y))
        let route = worldPath(
            from: simplifiedCells,
            grid: grid,
            start: start,
            goal: goal,
            travelAltitude: altitude
        )
        let smoothed = smoothPath(route, maxStep: max(1.0, grid.cellSize * 0.9))

        waypoints = smoothed
        currentIndex = smoothed.count > 1 ? 1 : 0
        pathLengthMeters = pathLength(of: smoothed)
        startPoint = smoothed.first ?? start
        goalPoint = smoothed.last ?? goal
        status = .valid
        statusReason = reason
        activeWaypointCount = waypoints.count
        planSignature = nextPlanSignature

        let planEnd = CFAbsoluteTimeGetCurrent()
        lastPlanDurationMs = (planEnd - planStart) * 1000.0
    }

    func updateProgress(currentPosition: SIMD3<Float>, arrivalRadius: Float = 1.8) {
        guard !waypoints.isEmpty else { return }
        let radius = max(0.4, arrivalRadius)

        while currentIndex < (waypoints.count - 1) {
            let target = waypoints[currentIndex]
            if simd_distance(currentPosition, target) <= radius {
                currentIndex += 1
            } else {
                break
            }
        }
    }

    func currentTarget() -> SIMD3<Float>? {
        guard !waypoints.isEmpty else { return nil }
        return waypoints[min(currentIndex, max(0, waypoints.count - 1))]
    }

    func replanReasonIfNeeded(
        currentPosition: SIMD3<Float>,
        collisionRisk: Float,
        deviationTolerance: Float
    ) -> String? {
        if waypoints.isEmpty {
            return "no_waypoints"
        }

        if collisionRisk >= 0.72 {
            return "high_collision_risk"
        }

        let offPath = distanceToPath2D(currentPosition: currentPosition) > max(2.0, deviationTolerance)
        if offPath {
            return "off_path"
        }

        if let grid, let target = currentTarget(), let cell = grid.cell(forWorld: target), grid.isBlocked(cell) {
            return "target_cell_blocked"
        }

        return nil
    }

    func snapshot(currentPosition: SIMD3<Float>) -> NavigationPathSnapshot {
        let clampedIndex = waypoints.isEmpty ? 0 : min(currentIndex, max(0, waypoints.count - 1))
        let remaining = remainingDistance(from: currentPosition)
        let remainingCount = max(0, waypoints.count - clampedIndex)

        return NavigationPathSnapshot(
            status: status,
            currentWaypointIndex: clampedIndex,
            remainingWaypoints: remainingCount,
            pathLengthMeters: pathLengthMeters,
            remainingDistanceMeters: remaining,
            waypoints: waypoints,
            start: startPoint,
            goal: goalPoint,
            reason: statusReason
        )
    }

    func hasReachedGoal(currentPosition: SIMD3<Float>, threshold: Float = 2.0) -> Bool {
        guard let goal = goalPoint else {
            return false
        }
        return simd_distance(currentPosition, goal) <= max(0.3, threshold)
    }

    private func ensureGrid(
        terrain: TerrainConfiguration,
        obstacles: [CollisionObstacle],
        droneRadius: Float
    ) -> Bool {
        let nextSignature = GridSignature(
            terrain: terrain.preset,
            mapScale: terrain.mapScale,
            densityBucket: Int((terrain.density.clamped(to: 0.0...1.0) * 100.0).rounded()),
            seed: terrain.seed,
            worldExtentBucket: Int((terrain.worldHalfExtent * 10.0).rounded()),
            obstacleHash: Self.obstacleHash(obstacles)
        )

        if nextSignature == gridSignature, grid != nil {
            return true
        }

        var newGrid = NavigationGrid(
            cellSize: preferredCellSize(for: terrain),
            halfExtent: terrain.worldHalfExtent
        )

        // Block a thin ring near world bounds to avoid paths touching walls.
        let borderPadding = max(newGrid.cellSize, droneRadius + 0.6)
        for z in 0..<newGrid.height {
            for x in 0..<newGrid.width {
                let cell = NavigationGrid.Cell(x: x, z: z)
                let world = newGrid.worldXZ(for: cell)
                if abs(world.x) > (newGrid.halfExtent - borderPadding) || abs(world.y) > (newGrid.halfExtent - borderPadding) {
                    newGrid.blocked[newGrid.index(cell)] = 1
                }
            }
        }

        for obstacle in obstacles {
            rasterizeObstacle(
                obstacle,
                droneRadius: droneRadius,
                grid: &newGrid
            )
        }

        self.grid = newGrid
        self.gridSignature = nextSignature
        self.planSignature = nil
        return true
    }

    private func rasterizeObstacle(
        _ obstacle: CollisionObstacle,
        droneRadius: Float,
        grid: inout NavigationGrid
    ) {
        let inflation = obstacleInflation(for: obstacle.source, droneRadius: droneRadius)
        let blockedRadius = max(0.4, obstacle.radius + inflation)
        let penaltyRadius = blockedRadius + max(1.5, blockedRadius * 0.9)

        let center = SIMD2<Float>(obstacle.center.x, obstacle.center.z)
        let minXFloat = (center.x - penaltyRadius - grid.originX) / grid.cellSize
        let maxXFloat = (center.x + penaltyRadius - grid.originX) / grid.cellSize
        let minZFloat = (center.y - penaltyRadius - grid.originZ) / grid.cellSize
        let maxZFloat = (center.y + penaltyRadius - grid.originZ) / grid.cellSize

        let minX = max(0, Int(floor(minXFloat)))
        let maxX = min(grid.width - 1, Int(ceil(maxXFloat)))
        let minZ = max(0, Int(floor(minZFloat)))
        let maxZ = min(grid.height - 1, Int(ceil(maxZFloat)))

        if minX > maxX || minZ > maxZ {
            return
        }

        let xRange = minX...maxX
        let zRange = minZ...maxZ

        let blockedRadiusSq = blockedRadius * blockedRadius
        for z in zRange {
            for x in xRange {
                let cell = NavigationGrid.Cell(x: x, z: z)
                if !grid.contains(cell) { continue }

                let world = grid.worldXZ(for: cell)
                let d = simd_distance(world, center)
                let idx = grid.index(cell)

                if d * d <= blockedRadiusSq {
                    grid.blocked[idx] = 1
                    grid.penalty[idx] = max(grid.penalty[idx], 1.0)
                    continue
                }

                if d < penaltyRadius {
                    let normalized = (1.0 - ((d - blockedRadius) / max(0.001, penaltyRadius - blockedRadius))).clamped(to: 0.0...1.0)
                    grid.penalty[idx] = max(grid.penalty[idx], normalized * 0.85)
                }
            }
        }
    }

    private func obstacleInflation(for source: String, droneRadius: Float) -> Float {
        let base: Float
        switch source {
        case let value where value.contains("building"):
            base = 1.4
        case let value where value.contains("tree"):
            base = 1.1
        case let value where value.contains("barrier"):
            base = 1.6
        case let value where value.contains("dock"):
            base = 0.9
        case let value where value.contains("terrain"):
            base = 0.8
        default:
            base = 1.0
        }
        return base + droneRadius * 0.6
    }

    private func preferredCellSize(for terrain: TerrainConfiguration) -> Float {
        let base: Float
        switch terrain.mapScale {
        case .x4:
            base = 1.0
        case .x8:
            base = 1.3
        case .x16:
            base = 1.8
        case .x32:
            base = 2.4
        }

        let densityAdjustment: Float = terrain.density > 0.75 ? 0.28 : (terrain.density > 0.55 ? 0.14 : 0.0)
        return base + densityAdjustment
    }

    private func astar(
        grid: NavigationGrid,
        start: NavigationGrid.Cell,
        goal: NavigationGrid.Cell
    ) -> [NavigationGrid.Cell]? {
        if start == goal {
            return [start]
        }

        var openSet: Set<NavigationGrid.Cell> = [start]
        var openList: [NavigationGrid.Cell] = [start]
        var cameFrom: [NavigationGrid.Cell: NavigationGrid.Cell] = [:]
        var gScore: [NavigationGrid.Cell: Float] = [start: 0.0]
        var fScore: [NavigationGrid.Cell: Float] = [start: heuristic(from: start, to: goal)]

        let maxIterations = max(2_000, grid.width * grid.height * 2)
        var iterations = 0

        while !openList.isEmpty && iterations < maxIterations {
            iterations += 1

            var bestIndex = 0
            var bestCell = openList[0]
            var bestScore = fScore[bestCell] ?? .greatestFiniteMagnitude
            for index in 1..<openList.count {
                let cell = openList[index]
                let score = fScore[cell] ?? .greatestFiniteMagnitude
                if score < bestScore {
                    bestIndex = index
                    bestCell = cell
                    bestScore = score
                }
            }

            let current = bestCell
            openList.remove(at: bestIndex)
            openSet.remove(current)

            if current == goal {
                return reconstructPath(cameFrom: cameFrom, current: current)
            }

            let neighbors = grid.neighbors(for: current, allowDiagonal: true)
            for neighbor in neighbors {
                let stepDistance = stepCost(from: current, to: neighbor)
                let softPenalty = grid.penaltyAt(neighbor) * 0.9
                let tentativeG = (gScore[current] ?? .greatestFiniteMagnitude) + stepDistance * (1.0 + softPenalty)
                let existing = gScore[neighbor] ?? .greatestFiniteMagnitude
                if tentativeG >= existing {
                    continue
                }

                cameFrom[neighbor] = current
                gScore[neighbor] = tentativeG
                fScore[neighbor] = tentativeG + heuristic(from: neighbor, to: goal) + grid.penaltyAt(neighbor) * 0.6

                if !openSet.contains(neighbor) {
                    openSet.insert(neighbor)
                    openList.append(neighbor)
                }
            }
        }

        return nil
    }

    private func reconstructPath(
        cameFrom: [NavigationGrid.Cell: NavigationGrid.Cell],
        current: NavigationGrid.Cell
    ) -> [NavigationGrid.Cell] {
        var output: [NavigationGrid.Cell] = [current]
        var node = current

        while let previous = cameFrom[node] {
            output.append(previous)
            node = previous
        }

        return output.reversed()
    }

    private func simplifyPath(
        _ cells: [NavigationGrid.Cell],
        grid: NavigationGrid
    ) -> [NavigationGrid.Cell] {
        guard cells.count > 2 else {
            return cells
        }

        var simplified: [NavigationGrid.Cell] = [cells[0]]
        var anchor = 0
        while anchor < cells.count - 1 {
            var candidate = cells.count - 1
            while candidate > anchor + 1 {
                if grid.hasLineOfSight(cells[anchor], cells[candidate]) {
                    break
                }
                candidate -= 1
            }
            simplified.append(cells[candidate])
            anchor = candidate
        }

        return simplified
    }

    private func worldPath(
        from cells: [NavigationGrid.Cell],
        grid: NavigationGrid,
        start: SIMD3<Float>,
        goal: SIMD3<Float>,
        travelAltitude: Float
    ) -> [SIMD3<Float>] {
        guard !cells.isEmpty else {
            return []
        }

        var points: [SIMD3<Float>] = cells.map { cell in
            let pointXZ = grid.worldXZ(for: cell)
            return SIMD3<Float>(pointXZ.x, travelAltitude, pointXZ.y)
        }

        if !points.isEmpty {
            points[0] = SIMD3<Float>(start.x, travelAltitude, start.z)
            points[points.count - 1] = SIMD3<Float>(goal.x, travelAltitude, goal.z)
        }

        return points
    }

    private func smoothPath(_ path: [SIMD3<Float>], maxStep: Float) -> [SIMD3<Float>] {
        guard path.count > 1 else {
            return path
        }

        var output: [SIMD3<Float>] = []
        output.reserveCapacity(path.count * 2)

        for index in 0..<(path.count - 1) {
            let a = path[index]
            let b = path[index + 1]
            output.append(a)

            let delta = b - a
            let distance = simd_length(delta)
            let segments = max(1, Int(ceil(distance / max(0.5, maxStep))))
            if segments > 1 {
                for step in 1..<segments {
                    let t = Float(step) / Float(segments)
                    let p = a + delta * t
                    output.append(p)
                }
            }
        }

        output.append(path[path.count - 1])
        return output
    }

    private func pathLength(of path: [SIMD3<Float>]) -> Float {
        guard path.count > 1 else { return 0.0 }
        var total: Float = 0.0
        for index in 1..<path.count {
            total += simd_distance(path[index - 1], path[index])
        }
        return total
    }

    private func remainingDistance(from currentPosition: SIMD3<Float>) -> Float {
        guard !waypoints.isEmpty else {
            return 0.0
        }

        let index = min(currentIndex, max(0, waypoints.count - 1))
        var total = simd_distance(currentPosition, waypoints[index])
        if index < waypoints.count - 1 {
            for idx in (index + 1)..<waypoints.count {
                total += simd_distance(waypoints[idx - 1], waypoints[idx])
            }
        }
        return total
    }

    private func distanceToPath2D(currentPosition: SIMD3<Float>) -> Float {
        guard waypoints.count >= 2 else {
            if let first = waypoints.first {
                let delta = SIMD2<Float>(currentPosition.x - first.x, currentPosition.z - first.z)
                return simd_length(delta)
            }
            return .greatestFiniteMagnitude
        }

        let p = SIMD2<Float>(currentPosition.x, currentPosition.z)
        var best = Float.greatestFiniteMagnitude
        for index in 1..<waypoints.count {
            let a = SIMD2<Float>(waypoints[index - 1].x, waypoints[index - 1].z)
            let b = SIMD2<Float>(waypoints[index].x, waypoints[index].z)
            let d = distanceFromPoint(p, toSegmentA: a, segmentB: b)
            best = min(best, d)
        }
        return best
    }

    private func distanceFromPoint(_ p: SIMD2<Float>, toSegmentA a: SIMD2<Float>, segmentB b: SIMD2<Float>) -> Float {
        let ab = b - a
        let lenSq = simd_length_squared(ab)
        if lenSq < 0.000001 {
            return simd_distance(p, a)
        }
        let t = simd_dot(p - a, ab) / lenSq
        let clamped = t.clamped(to: 0.0...1.0)
        let projection = a + ab * clamped
        return simd_distance(p, projection)
    }

    private func heuristic(from: NavigationGrid.Cell, to: NavigationGrid.Cell) -> Float {
        let dx = Float(to.x - from.x)
        let dz = Float(to.z - from.z)
        return sqrt(dx * dx + dz * dz)
    }

    private func stepCost(from: NavigationGrid.Cell, to: NavigationGrid.Cell) -> Float {
        let dx = abs(to.x - from.x)
        let dz = abs(to.z - from.z)
        if dx == 1, dz == 1 {
            return 1.4142135
        }
        return 1.0
    }

    private static func obstacleHash(_ obstacles: [CollisionObstacle]) -> Int {
        var hasher = Hasher()
        hasher.combine(obstacles.count)
        for obstacle in obstacles.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            hasher.combine(obstacle.id)
            hasher.combine(Int((obstacle.center.x * 10.0).rounded()))
            hasher.combine(Int((obstacle.center.y * 10.0).rounded()))
            hasher.combine(Int((obstacle.center.z * 10.0).rounded()))
            hasher.combine(Int((obstacle.radius * 10.0).rounded()))
            hasher.combine(obstacle.source)
        }
        return hasher.finalize()
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
