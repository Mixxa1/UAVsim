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

struct NavigationDirectPathAssessment {
    var blocked: Bool
    var maxPenalty: Float

    static let unavailable = NavigationDirectPathAssessment(
        blocked: true,
        maxPenalty: 1.0
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
        let startCell: NavigationGrid.Cell
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

        func nearestFreeCell(
            to world: SIMD3<Float>,
            preferredToward preferredWorld: SIMD3<Float>? = nil,
            maxSearchRadius: Int = 24
        ) -> Cell? {
            guard let seed = cell(forWorld: world) else {
                return nil
            }
            if !isBlocked(seed) {
                return seed
            }

            let worldPlanar = SIMD2<Float>(world.x, world.z)
            let preferredPlanar = preferredWorld.map { SIMD2<Float>($0.x, $0.z) }

            for ring in 1...maxSearchRadius {
                let x0 = seed.x - ring
                let x1 = seed.x + ring
                let z0 = seed.z - ring
                let z1 = seed.z + ring

                var bestCell: Cell?
                var bestDistance = Float.greatestFiniteMagnitude
                var bestPreferredDistance = Float.greatestFiniteMagnitude

                func consider(_ cell: Cell) {
                    guard contains(cell), !isBlocked(cell) else {
                        return
                    }

                    let candidateWorld = worldXZ(for: cell)
                    let distance = simd_length_squared(candidateWorld - worldPlanar)
                    let preferredDistance = preferredPlanar.map {
                        simd_length_squared(candidateWorld - $0)
                    } ?? 0.0
                    let isCloser = distance < bestDistance - 0.0001
                    let isBetterTie = abs(distance - bestDistance) <= 0.0001 &&
                        preferredDistance < bestPreferredDistance

                    if isCloser || isBetterTie {
                        bestCell = cell
                        bestDistance = distance
                        bestPreferredDistance = preferredDistance
                    }
                }

                for x in x0...x1 {
                    consider(Cell(x: x, z: z0))
                    consider(Cell(x: x, z: z1))
                }
                if z1 - z0 > 1 {
                    for z in (z0 + 1)..<z1 {
                        consider(Cell(x: x0, z: z))
                        consider(Cell(x: x1, z: z))
                    }
                }

                if let bestCell {
                    return bestCell
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
            appendNeighbors(for: cell, allowDiagonal: allowDiagonal, into: &result)
            return result
        }

        /// The same walk, writing into a caller-owned buffer. A* expands hundreds of thousands of
        /// cells on a city grid and a fresh array per expansion is pure allocator traffic.
        func appendNeighbors(for cell: Cell, allowDiagonal: Bool, into result: inout [Cell]) {
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
    /// The last search that returned nothing, with the grid it ran against. Repeating it is the
    /// worst case there is, so it is repeated only once the world, the start cell or the goal moves.
    private var failedPlan: PlanSignature?
    private var failedPlanGridSignature: GridSignature?
    /// Fraction of the navigation grid marked impassable by the current obstacle set.
    private(set) var lastGridBlockedFraction: Float = 0.0
    private(set) var lastGridCellSize: Float = 0.0
    /// When a timed-out search may be attempted again.
    private var searchRetryAfter: Double = 0.0
    /// Search scratch, sized to the grid and reused. Validity is per-cell via `searchStamp`, so a
    /// new search costs nothing to start no matter how large the grid is.
    private var searchGScore: [Float] = []
    private var searchCameFrom: [Int32] = []
    private var searchStamp: [Int32] = []
    private var searchClosed: [Bool] = []
    private var searchGeneration: Int32 = 0

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
        failedPlan = nil
        failedPlanGridSignature = nil
        searchRetryAfter = 0.0
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
        obstacleSignature: Int? = nil,
        droneRadius: Float,
        modeTag: String,
        forceRecompute: Bool = false,
        reason: String = "periodic"
    ) {
        status = .recomputing
        statusReason = reason

        let gridBuildStart = CFAbsoluteTimeGetCurrent()
        guard ensureGrid(
            terrain: terrain,
            obstacles: obstacles,
            obstacleSignature: obstacleSignature,
            droneRadius: droneRadius
        ) else {
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

        guard let startCell = grid.nearestFreeCell(to: start, preferredToward: goal),
              let goalCell = grid.nearestFreeCell(to: goal, preferredToward: start) else {
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
            startCell: startCell,
            goalCell: goalCell
        )

        let previousPlanSignature = planSignature
        let startMovedAwayFromCachedPath =
            previousPlanSignature?.modeTag == modeTag &&
            previousPlanSignature?.goalCell == goalCell &&
            previousPlanSignature?.startCell != startCell &&
            distanceToPath2D(currentPosition: start) > max(1.8, grid.cellSize * 1.25)
        let shouldReplan =
            forceRecompute ||
            previousPlanSignature?.modeTag != modeTag ||
            previousPlanSignature?.goalCell != goalCell ||
            waypoints.isEmpty ||
            status == .blocked ||
            startMovedAwayFromCachedPath
        guard shouldReplan else {
            status = .valid
            statusReason = "cached"
            lastPlanDurationMs = 0.0
            return
        }

        // A search that already failed against this exact grid, from this exact cell, to this exact
        // cell, will fail again — and failing is the expensive case, because A* has to exhaust the
        // whole reachable region to prove it. `status == .blocked` is itself a replan trigger, so
        // without this the tick loop re-ran the most expensive possible search every frame and the
        // simulation stopped moving.
        if failedPlan == nextPlanSignature, failedPlanGridSignature == gridSignature {
            status = .blocked
            statusReason = "astar_blocked_cached"
            lastPlanDurationMs = 0.0
            return
        }
        // A search that ran out of time says nothing about the world, so it cannot be cached
        // against it — but it must not be retried on the very next tick either, or the budget is
        // spent every frame and the stall it exists to prevent happens anyway.
        if CFAbsoluteTimeGetCurrent() < searchRetryAfter {
            status = .blocked
            statusReason = "astar_timeout_backoff"
            lastPlanDurationMs = 0.0
            return
        }

        let planStart = CFAbsoluteTimeGetCurrent()
        let outcome = astar(grid: grid, start: startCell, goal: goalCell)
        let cellPath: [NavigationGrid.Cell]
        switch outcome {
        case let .path(path):
            cellPath = path
        case .unreachable, .timedOut:
            status = .blocked
            statusReason = outcome.isTimeout ? "astar_timeout" : "astar_blocked"
            waypoints.removeAll(keepingCapacity: false)
            currentIndex = 0
            pathLengthMeters = 0.0
            startPoint = start
            goalPoint = goal
            activeWaypointCount = 0
            planSignature = nextPlanSignature
            if outcome.isTimeout {
                searchRetryAfter = CFAbsoluteTimeGetCurrent() + Self.searchTimeoutBackoffSeconds
            } else {
                failedPlan = nextPlanSignature
                failedPlanGridSignature = gridSignature
            }
            lastPlanDurationMs = (CFAbsoluteTimeGetCurrent() - planStart) * 1000.0
            return
        }

        failedPlan = nil
        failedPlanGridSignature = nil
        searchRetryAfter = 0.0

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

    func updateProgress(
        currentPosition: SIMD3<Float>,
        arrivalRadius: Float = 1.8,
        planarOnly: Bool = false
    ) {
        guard !waypoints.isEmpty else { return }
        let radius = max(0.4, arrivalRadius)
        let currentPlanar = SIMD2<Float>(currentPosition.x, currentPosition.z)

        while currentIndex < (waypoints.count - 1) {
            let target = waypoints[currentIndex]
            let distance = planarOnly
                ? simd_distance(currentPlanar, SIMD2<Float>(target.x, target.z))
                : simd_distance(currentPosition, target)
            if distance <= radius {
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

    func lookaheadTarget(currentPosition: SIMD3<Float>, minimumDistance: Float) -> SIMD3<Float>? {
        guard !waypoints.isEmpty else { return nil }

        let clampedIndex = min(currentIndex, max(0, waypoints.count - 1))
        var remaining = max(0.0, minimumDistance)
        var previous = currentPosition

        for index in clampedIndex..<waypoints.count {
            let waypoint = waypoints[index]
            let segment = waypoint - previous
            let segmentLength = simd_length(segment)

            if segmentLength >= max(0.001, remaining) {
                let t = remaining / segmentLength
                return previous + segment * t
            }

            remaining -= segmentLength
            previous = waypoint
        }

        return waypoints.last
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

    func assessDirectPath(
        from start: SIMD3<Float>,
        to goal: SIMD3<Float>,
        terrain: TerrainConfiguration,
        obstacles: [CollisionObstacle],
        obstacleSignature: Int? = nil,
        droneRadius: Float
    ) -> NavigationDirectPathAssessment {
        guard ensureGrid(
                  terrain: terrain,
                  obstacles: obstacles,
                  obstacleSignature: obstacleSignature,
                  droneRadius: droneRadius
              ),
              let grid,
              let startCell = grid.nearestFreeCell(to: start, preferredToward: goal),
              let goalCell = grid.nearestFreeCell(to: goal, preferredToward: start) else {
            return .unavailable
        }

        let hasLineOfSight = grid.hasLineOfSight(startCell, goalCell)
        let maxPenalty = maxPenaltyAlongDirectPath(
            from: startCell,
            to: goalCell,
            grid: grid
        )

        return NavigationDirectPathAssessment(
            blocked: !hasLineOfSight,
            maxPenalty: maxPenalty
        )
    }

    func hasReachedGoal(currentPosition: SIMD3<Float>, threshold: Float = 2.0) -> Bool {
        guard let goal = goalPoint else {
            return false
        }
        return simd_distance(currentPosition, goal) <= max(0.3, threshold)
    }

    /// `obstacleSignature` lets a caller that already knows when its obstacle set changed say so,
    /// instead of having this hash the whole array again. On an imported city that array is ~20 000
    /// obstacles and this runs several times per tick, so the caller's own knowledge is worth
    /// having; passing nil keeps the self-contained behaviour. The signature must change whenever
    /// the array does — a stale one means routing against a grid that no longer describes the world.
    private func ensureGrid(
        terrain: TerrainConfiguration,
        obstacles: [CollisionObstacle],
        obstacleSignature: Int?,
        droneRadius: Float
    ) -> Bool {
        let nextSignature = GridSignature(
            terrain: terrain.preset,
            mapScale: terrain.mapScale,
            densityBucket: Int((terrain.density.clamped(to: 0.0...1.0) * 100.0).rounded()),
            seed: terrain.seed,
            worldExtentBucket: Int((terrain.worldHalfExtent * 10.0).rounded()),
            obstacleHash: obstacleSignature ?? Self.obstacleHash(obstacles)
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
        // How much of the world the planner considers impassable. Published because "the autopilot
        // does nothing" and "the map rasterises as a solid block" look identical from the outside,
        // and telling them apart otherwise means attaching a debugger.
        var blockedCells = 0
        for value in newGrid.blocked where value != 0 { blockedCells += 1 }
        lastGridBlockedFraction = Float(blockedCells) / Float(max(1, newGrid.blocked.count))
        lastGridCellSize = newGrid.cellSize
        return true
    }

    private func rasterizeObstacle(
        _ obstacle: CollisionObstacle,
        droneRadius: Float,
        grid: inout NavigationGrid
    ) {
        if obstacle.source == "container.floor" || obstacle.source == "container.roof" {
            return
        }
        let inflation = obstacleInflation(for: obstacle.source, droneRadius: droneRadius)
        let blockedMargin = max(0.12, inflation)
        let penaltyMargin = blockedMargin + max(1.2, blockedMargin * 1.6)
        let queryRadius = obstacle.radius + penaltyMargin

        let center = SIMD2<Float>(obstacle.center.x, obstacle.center.z)
        let minXFloat = (center.x - queryRadius - grid.originX) / grid.cellSize
        let maxXFloat = (center.x + queryRadius - grid.originX) / grid.cellSize
        let minZFloat = (center.y - queryRadius - grid.originZ) / grid.cellSize
        let maxZFloat = (center.y + queryRadius - grid.originZ) / grid.cellSize

        let minX = max(0, Int(floor(minXFloat)))
        let maxX = min(grid.width - 1, Int(ceil(maxXFloat)))
        let minZ = max(0, Int(floor(minZFloat)))
        let maxZ = min(grid.height - 1, Int(ceil(maxZFloat)))

        if minX > maxX || minZ > maxZ {
            return
        }

        let xRange = minX...maxX
        let zRange = minZ...maxZ

        for z in zRange {
            for x in xRange {
                let cell = NavigationGrid.Cell(x: x, z: z)
                if !grid.contains(cell) { continue }

                let world = grid.worldXZ(for: cell)
                let distance = obstacle.planarSignedDistance(to: world)
                let idx = grid.index(cell)

                if distance <= blockedMargin {
                    grid.blocked[idx] = 1
                    grid.penalty[idx] = max(grid.penalty[idx], 1.0)
                    continue
                }

                if distance < penaltyMargin {
                    let normalized = (
                        1.0 - (
                            (distance - blockedMargin) /
                            max(0.001, penaltyMargin - blockedMargin)
                        )
                    ).clamped(to: 0.0...1.0)
                    grid.penalty[idx] = max(grid.penalty[idx], normalized * 0.85)
                }
            }
        }
    }

    private func obstacleInflation(for source: String, droneRadius: Float) -> Float {
        let base: Float
        switch source {
        case let value where value.contains("no_fly"):
            base = 2.2
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
        case let value where value.contains("container"):
            base = 0.12
        default:
            base = 1.0
        }
        let radiusFactor: Float = source.contains("container") ? 0.45 : 0.6
        return base + droneRadius * radiusFactor
    }

    private func preferredCellSize(for terrain: TerrainConfiguration) -> Float {
        let base: Float
        switch terrain.mapScale {
        case .x4:
            base = 1.25
        case .x8:
            base = 1.45
        case .x16:
            base = 1.85
        case .x32:
            base = 2.15
        case .x64:
            base = 2.35
        case .x128:
            base = 2.75
        case .x256:
            base = 3.35
        }

        let densityAdjustment: Float = terrain.density > 0.75 ? 0.28 : (terrain.density > 0.55 ? 0.14 : 0.0)
        let worldWidth = terrain.worldHalfExtent * 2.0
        // 1200 cells across, not 520.
        //
        // The old budget was written for procedural maps a few hundred metres wide, where it never
        // bound. On a 6.4 km imported city it decides everything: it gives 12.31 m cells, and a
        // 20 m street minus the obstacle inflation leaves barely one free cell centre per
        // cross-section. Consecutive rows then stagger, so the free space degenerates into a
        // diagonal chain — and a diagonal step past a blocked side cell is refused (rightly: it
        // would clip a building corner). Measured on the real Lower Manhattan package, reachable
        // area from the launch pad: **308 cells / 321 m at 12.31 m**, 580 383 cells / 4559 m at
        // 8 m, and the same 4.5 km at 6 m and below. The aircraft was sealed into a pocket three
        // blocks wide, which is why every route failed. 1200 gives 5.33 m here, with margin over
        // the 8 m cliff, and still never binds on a procedural map.
        // Deliberately left at the coarser 520 divisor, not the parked 1200.
        //
        // This is a *floor* on cell size, so a larger divisor means a finer grid — 2.3x finer
        // here, which is more cells, more expansions and better routes. It is a routing change,
        // not a performance one, and it is being restored specifically to stop a 0 FPS stall, so
        // the grid stays where it is and only the search itself gets faster.
        let gridBudgetCellSize = worldWidth / 520.0
        return max(base + densityAdjustment, gridBudgetCellSize)
    }

    /// Binary min-heap over cell indices, with lazy deletion.
    ///
    /// What stood here was a linear scan of the open list for its lowest score, with a dictionary
    /// lookup per element. That is O(n) per expansion against an open list that runs to thousands of
    /// cells on a city-sized grid, and a paused debugger caught the main thread inside exactly that
    /// loop — top frame `__RawDictionaryStorage.find` — while the simulation sat at zero frames.
    private struct OpenHeap {
        private var storage: [(score: Float, index: Int32)] = []

        var isEmpty: Bool { storage.isEmpty }

        mutating func reserveCapacity(_ capacity: Int) {
            storage.reserveCapacity(capacity)
        }

        mutating func push(index: Int32, score: Float) {
            storage.append((score, index))
            var child = storage.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                if storage[parent].score <= storage[child].score { break }
                storage.swapAt(parent, child)
                child = parent
            }
        }

        mutating func popMinimum() -> (score: Float, index: Int32)? {
            guard let minimum = storage.first else { return nil }
            let last = storage.removeLast()
            if !storage.isEmpty {
                storage[0] = last
                var parent = 0
                while true {
                    let left = parent * 2 + 1
                    let right = left + 1
                    var smallest = parent
                    if left < storage.count, storage[left].score < storage[smallest].score {
                        smallest = left
                    }
                    if right < storage.count, storage[right].score < storage[smallest].score {
                        smallest = right
                    }
                    if smallest == parent { break }
                    storage.swapAt(parent, smallest)
                    parent = smallest
                }
            }
            return minimum
        }
    }

    /// Wall-clock ceiling for one search. A goal enclosed by geometry makes A* explore its entire
    /// reachable region before it can answer "no" — a million cells on a city map — and that answer
    /// is worth at most one dropped frame, never a stalled simulation.
    private static let searchTimeBudgetSeconds: Double = 0.030
    /// How long a timed-out search is left alone. Unlike a proven-unreachable goal, a timeout says
    /// nothing about the world, so it cannot be cached on the grid — but retrying it every tick is
    /// exactly the stall it was meant to prevent.
    private static let searchTimeoutBackoffSeconds: Double = 0.75

    private enum SearchOutcome {
        case path([NavigationGrid.Cell])
        /// The reachable region was exhausted: this goal genuinely cannot be reached.
        case unreachable
        /// The budget ran out first — no conclusion about the world.
        case timedOut

        var isTimeout: Bool {
            if case .timedOut = self { return true }
            return false
        }
    }

    private func astar(
        grid: NavigationGrid,
        start: NavigationGrid.Cell,
        goal: NavigationGrid.Cell
    ) -> SearchOutcome {
        if start == goal {
            return .path([start])
        }

        // Flat arrays indexed by cell, not dictionaries keyed by cell. Every lookup in the inner
        // loop was hashing a struct, and a paused debugger caught the main thread doing exactly
        // that. They are also kept across searches and validated by a generation stamp, so a
        // million-cell grid costs no per-call clearing.
        let cellCount = grid.width * grid.height
        prepareSearchBuffers(cellCount: cellCount)
        searchGeneration &+= 1
        let generation = searchGeneration

        let startIndex = grid.index(start)
        let goalIndex = grid.index(goal)
        searchStamp[startIndex] = generation
        searchGScore[startIndex] = 0.0
        searchCameFrom[startIndex] = -1
        searchClosed[startIndex] = false

        var open = OpenHeap()
        open.reserveCapacity(min(cellCount, 8_192))
        open.push(index: Int32(startIndex), score: heuristic(from: start, to: goal))

        let deadline = CFAbsoluteTimeGetCurrent() + Self.searchTimeBudgetSeconds
        // One expansion per cell at most, so the grid itself is the bound.
        let maximumExpansions = max(2_000, cellCount)
        var expansions = 0
        var neighbors: [NavigationGrid.Cell] = []
        neighbors.reserveCapacity(8)

        while let entry = open.popMinimum() {
            let currentIndex = Int(entry.index)
            // A cell can be pushed several times; the stale copies are dropped here rather than
            // being hunted down in the heap.
            if searchClosed[currentIndex] { continue }
            searchClosed[currentIndex] = true

            if currentIndex == goalIndex {
                return .path(reconstructPath(goalIndex: goalIndex, grid: grid))
            }

            expansions += 1
            if expansions >= maximumExpansions { return .timedOut }
            if expansions & 0x3FF == 0, CFAbsoluteTimeGetCurrent() > deadline {
                return .timedOut
            }

            let current = NavigationGrid.Cell(
                x: currentIndex % grid.width,
                z: currentIndex / grid.width
            )
            neighbors.removeAll(keepingCapacity: true)
            grid.appendNeighbors(for: current, allowDiagonal: true, into: &neighbors)

            let currentG = searchGScore[currentIndex]
            for neighbor in neighbors {
                let neighborIndex = grid.index(neighbor)
                let penalty = grid.penaltyAt(neighbor)
                let tentativeG = currentG + stepCost(from: current, to: neighbor) * (1.0 + penalty * 0.9)
                let known = searchStamp[neighborIndex] == generation
                if known, tentativeG >= searchGScore[neighborIndex] { continue }

                searchStamp[neighborIndex] = generation
                searchCameFrom[neighborIndex] = entry.index
                searchGScore[neighborIndex] = tentativeG
                // The penalty term makes the estimate slightly inconsistent, so a closed cell that
                // turns out to be cheaper this way is genuinely reopened — the same freedom the
                // open-list version had.
                searchClosed[neighborIndex] = false
                open.push(
                    index: Int32(neighborIndex),
                    score: tentativeG + heuristic(from: neighbor, to: goal) + penalty * 0.6
                )
            }
        }

        return .unreachable
    }

    private func prepareSearchBuffers(cellCount: Int) {
        guard searchGScore.count != cellCount else { return }
        searchGScore = [Float](repeating: .greatestFiniteMagnitude, count: cellCount)
        searchCameFrom = [Int32](repeating: -1, count: cellCount)
        searchStamp = [Int32](repeating: 0, count: cellCount)
        searchClosed = [Bool](repeating: false, count: cellCount)
        searchGeneration = 0
    }

    private func reconstructPath(
        goalIndex: Int,
        grid: NavigationGrid
    ) -> [NavigationGrid.Cell] {
        var output: [NavigationGrid.Cell] = []
        var index = goalIndex
        while index >= 0 {
            output.append(NavigationGrid.Cell(x: index % grid.width, z: index / grid.width))
            let parent = searchCameFrom[index]
            if parent < 0 { break }
            index = Int(parent)
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

    private func maxPenaltyAlongDirectPath(
        from start: NavigationGrid.Cell,
        to end: NavigationGrid.Cell,
        grid: NavigationGrid
    ) -> Float {
        let startWorld = grid.worldXZ(for: start)
        let endWorld = grid.worldXZ(for: end)
        let direction = endWorld - startWorld
        let distance = simd_length(direction)
        if distance < 0.0001 {
            return max(grid.penaltyAt(start), grid.penaltyAt(end))
        }

        let step = max(grid.cellSize * 0.5, 0.4)
        let steps = max(1, Int(ceil(distance / step)))
        var maxPenalty: Float = 0.0

        for index in 0...steps {
            let t = Float(index) / Float(steps)
            let sample = startWorld + direction * t
            guard let cell = grid.cell(forWorldXZ: sample) else {
                return 1.0
            }
            if grid.isBlocked(cell) {
                return 1.0
            }
            maxPenalty = max(maxPenalty, grid.penaltyAt(cell))
        }

        return maxPenalty
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

    /// Identity of an obstacle set, for deciding whether the navigation grid may be reused.
    ///
    /// Order-independent by construction — each obstacle is hashed on its own and the results are
    /// combined commutatively — rather than by sorting the array first. The sort it replaces
    /// compared `id.uuidString`, which builds two 36-character strings per comparison: on an
    /// imported city's ~20 000 obstacles that is roughly 300 000 comparisons and 600 000 string
    /// allocations, **per call**, on the tick path. It was invisible while this only ever saw a few
    /// hundred procedural trees, and it is what made a real map unflyable the moment the world
    /// started publishing its buildings into the registry.
    private static func obstacleHash(_ obstacles: [CollisionObstacle]) -> Int {
        var combined: Int = obstacles.count.hashValue
        for obstacle in obstacles {
            var hasher = Hasher()
            hasher.combine(obstacle.id)
            hasher.combine(Int((obstacle.center.x * 10.0).rounded()))
            hasher.combine(Int((obstacle.center.y * 10.0).rounded()))
            hasher.combine(Int((obstacle.center.z * 10.0).rounded()))
            hasher.combine(Int((obstacle.radius * 10.0).rounded()))
            hasher.combine(Int((obstacle.baseY * 10.0).rounded()))
            hasher.combine(Int((obstacle.topY * 10.0).rounded()))
            if let halfExtents = obstacle.planarHalfExtents {
                hasher.combine(Int((halfExtents.x * 10.0).rounded()))
                hasher.combine(Int((halfExtents.y * 10.0).rounded()))
                hasher.combine(Int((obstacle.yawRadians * 100.0).rounded()))
            }
            hasher.combine(obstacle.source)
            combined ^= hasher.finalize()
        }
        return combined
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
