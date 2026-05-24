import Foundation

// MARK: - Profile Area

struct SketchProfileArea: Identifiable, Equatable {
    var id: UUID
    var outerLoop: [SketchPoint2D]   // CCW or CW ordered, no repeated last vertex
    var holes: [[SketchPoint2D]]     // inner loops at odd nesting depth
    var areaMeters2: Double
    var centroid: SketchPoint2D

    var isExtrudable: Bool { outerLoop.count >= 3 }
    var hasHoles: Bool { !holes.isEmpty }

    var areaMM2: Double { areaMeters2 * 1_000_000 }
}

// MARK: - Profile Graph

struct SketchProfileGraph: Equatable {
    var areas: [SketchProfileArea]

    var isEmpty: Bool { areas.isEmpty }
    var count: Int { areas.count }

    func area(with id: UUID) -> SketchProfileArea? {
        areas.first { $0.id == id }
    }

    /// Returns the innermost (smallest) profile area that contains `point`.
    func containingArea(for point: SketchPoint2D) -> SketchProfileArea? {
        areas
            .filter { SketchProfileEngine.pointInPolygon(point, polygon: $0.outerLoop) }
            .min(by: { $0.areaMeters2 < $1.areaMeters2 })
    }
}

// MARK: - Profile Engine

enum SketchProfileEngine {

    private static let tolerance: Double = 0.0005
    private static let minArea: Double = 1e-6

    // MARK: - Entry point

    static func buildProfileGraph(from sketch: DesignSketch) -> SketchProfileGraph {
        let mainEntities = sketch.entities.filter { $0.constructionStyle == .main }

        var allLoops: [[SketchPoint2D]] = []

        // Lines → connected closed loops
        let mainLines = mainEntities.compactMap(\.line)
        if !mainLines.isEmpty {
            allLoops += findClosedLineLoops(mainLines, tol: tolerance)
        }

        // Non-line entities each produce one closed loop
        for entity in mainEntities {
            switch entity {
            case .line: break
            case let .rectangle(r) where r.isValidProfile:
                allLoops.append(r.corners)
            case let .circle(c) where c.isValidProfile:
                allLoops.append(c.profilePoints())
            case let .polyline(p):
                if let loop = closedPolylineLoop(p) { allLoops.append(loop) }
            default: break
            }
        }

        // Validate and measure
        let validLoops: [(pts: [SketchPoint2D], area: Double)] = allLoops.compactMap { pts in
            guard pts.count >= 3 else { return nil }
            let a = DesignSketch.polygonAreaMeters2(pts)
            guard a > minArea else { return nil }
            return (pts, a)
        }

        guard !validLoops.isEmpty else { return SketchProfileGraph(areas: []) }

        // Sort largest → smallest (outer loops before inner)
        let sorted = validLoops.sorted { $0.area > $1.area }

        // Build containment tree
        let n = sorted.count
        // directParent[i] = index of the smallest loop that strictly contains sorted[i]
        var directParent: [Int?] = Array(repeating: nil, count: n)
        for i in 0..<n {
            let c = polygonCentroid(sorted[i].pts)
            var bestJ: Int? = nil
            var bestArea = Double.infinity
            for j in 0..<n {
                guard j != i, sorted[j].area > sorted[i].area else { continue }
                if pointInPolygon(c, polygon: sorted[j].pts), sorted[j].area < bestArea {
                    bestArea = sorted[j].area
                    bestJ = j
                }
            }
            directParent[i] = bestJ
        }

        // Nesting depth: 0 = top-level outer, 1 = hole, 2 = inner profile, ...
        func depth(_ i: Int) -> Int {
            var d = 0
            var cur = directParent[i]
            while let p = cur { d += 1; cur = directParent[p] }
            return d
        }

        // Build SketchProfileArea for every even-depth loop
        var areas: [SketchProfileArea] = []
        for i in 0..<n {
            guard depth(i) % 2 == 0 else { continue }
            // Collect direct odd-depth children as holes
            var holes: [[SketchPoint2D]] = []
            for j in 0..<n {
                if directParent[j] == i, depth(j) % 2 == 1 {
                    holes.append(sorted[j].pts)
                }
            }
            areas.append(SketchProfileArea(
                id: UUID(),
                outerLoop: sorted[i].pts,
                holes: holes,
                areaMeters2: sorted[i].area,
                centroid: polygonCentroid(sorted[i].pts)
            ))
        }

        // Sort areas largest → smallest for consistent display ordering
        areas.sort { $0.areaMeters2 > $1.areaMeters2 }
        return SketchProfileGraph(areas: areas)
    }

    // MARK: - Closed line loop detection

    static func findClosedLineLoops(_ lines: [SketchLine], tol: Double) -> [[SketchPoint2D]] {
        // Deduplicate vertices
        var verts: [SketchPoint2D] = []

        func vertexIndex(_ pt: SketchPoint2D) -> Int {
            if let idx = verts.firstIndex(where: { $0.distance(to: pt) <= tol }) { return idx }
            verts.append(pt)
            return verts.count - 1
        }

        var adj: [[Int]] = [] // adj[v] = list of neighboring vertex indices

        for line in lines {
            let a = vertexIndex(line.start)
            let b = vertexIndex(line.end)
            guard a != b else { continue }
            // Grow adj if needed
            while adj.count <= max(a, b) { adj.append([]) }
            adj[a].append(b)
            adj[b].append(a)
        }

        guard !verts.isEmpty else { return [] }
        while adj.count < verts.count { adj.append([]) }

        // Find connected components via BFS
        var visited = Array(repeating: false, count: verts.count)
        var components: [[Int]] = []

        for start in 0..<verts.count {
            guard !visited[start] else { continue }
            var comp: [Int] = []
            var queue = [start]
            visited[start] = true
            while !queue.isEmpty {
                let v = queue.removeFirst()
                comp.append(v)
                for nb in adj[v] where !visited[nb] {
                    visited[nb] = true
                    queue.append(nb)
                }
            }
            components.append(comp)
        }

        var loops: [[SketchPoint2D]] = []

        for comp in components {
            guard comp.count >= 3 else { continue }
            // Only handle simple loops: all vertices must have degree exactly 2
            guard comp.allSatisfy({ adj[$0].count == 2 }) else { continue }

            // Traverse loop
            let startV = comp[0]
            var path: [Int] = [startV]
            var prev = -1
            var cur = startV

            for _ in 0..<(comp.count + 1) {
                let neighbors = adj[cur].filter { $0 != prev }
                guard let next = neighbors.first else { break }
                if next == startV { break }
                path.append(next)
                prev = cur
                cur = next
            }

            if path.count == comp.count {
                loops.append(path.map { verts[$0] })
            }
        }

        return loops
    }

    // MARK: - Closed polyline helper

    private static func closedPolylineLoop(_ p: SketchPolyline) -> [SketchPoint2D]? {
        var pts = p.points
        guard pts.count >= 3 else { return nil }
        let endDist = pts.first?.distance(to: pts.last ?? .zero) ?? .infinity
        guard p.isClosed || endDist <= tolerance else { return nil }
        // Remove duplicate last point
        if let first = pts.first, let last = pts.last,
           first.distance(to: last) <= tolerance {
            pts.removeLast()
        }
        return pts.count >= 3 ? pts : nil
    }

    // MARK: - Point in polygon (ray-casting)

    static func pointInPolygon(_ pt: SketchPoint2D, polygon: [SketchPoint2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].u, yi = polygon[i].v
            let xj = polygon[j].u, yj = polygon[j].v
            if ((yi > pt.v) != (yj > pt.v)) &&
               (pt.u < (xj - xi) * (pt.v - yi) / (yj - yi) + xi) {
                inside = !inside
            }
            j = i
        }
        return inside
    }

    // MARK: - Centroid

    static func polygonCentroid(_ pts: [SketchPoint2D]) -> SketchPoint2D {
        guard pts.count >= 3 else {
            let su = pts.reduce(0.0) { $0 + $1.u }
            let sv = pts.reduce(0.0) { $0 + $1.v }
            let n = Double(max(pts.count, 1))
            return SketchPoint2D(u: su / n, v: sv / n)
        }
        var cx = 0.0, cy = 0.0, area = 0.0
        let n = pts.count
        for i in 0..<n {
            let j = (i + 1) % n
            let cross = pts[i].u * pts[j].v - pts[j].u * pts[i].v
            area += cross
            cx += (pts[i].u + pts[j].u) * cross
            cy += (pts[i].v + pts[j].v) * cross
        }
        area /= 2.0
        guard abs(area) > 1e-12 else {
            let su = pts.reduce(0.0) { $0 + $1.u } / Double(n)
            let sv = pts.reduce(0.0) { $0 + $1.v } / Double(n)
            return SketchPoint2D(u: su, v: sv)
        }
        return SketchPoint2D(u: cx / (6 * area), v: cy / (6 * area))
    }
}
