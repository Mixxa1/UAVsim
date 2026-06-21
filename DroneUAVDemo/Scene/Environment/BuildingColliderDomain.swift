import SceneKit

// MARK: - Collider role

enum BuildingColliderRole: String, Codable, CaseIterable {
    case floor
    case wall
    case roof
    case beam
    case railing
    case door
    case glass
    case debris
    case landingSurface
}

// MARK: - Collider part

struct BuildingColliderPart: Codable {
    let id: String
    let role: BuildingColliderRole
    let localCenter: [Float]
    let size: [Float]
    let yawDegrees: Float
    let isBreakable: Bool
    let hitPoints: Float
    let crashSpeedThreshold: Float
    let blocksUAV: Bool

    var center3D: SIMD3<Float> {
        SIMD3<Float>(localCenter[0], localCenter[1], localCenter[2])
    }

    var size3D: SIMD3<Float> {
        SIMD3<Float>(size[0], size[1], size[2])
    }
}

// MARK: - Preset (loaded from JSON)

struct BuildingColliderPreset: Codable {
    let kind: String
    let parts: [BuildingColliderPart]
}

struct BuildingColliderPresetFile: Codable {
    let shopOldHouse: [BuildingColliderPart]
    let aspectHouse: [BuildingColliderPart]
    let sengchorHouse: [BuildingColliderPart]
}

// MARK: - Runtime collider instance

struct BuildingColliderInstance {
    let partID: String
    let role: BuildingColliderRole
    var hitPoints: Float
    let crashSpeedThreshold: Float
    let isBreakable: Bool
    let blocksUAV: Bool
    weak var node: SCNNode?
    let buildingID: UUID

    var isDestroyed: Bool { hitPoints <= 0 }

    mutating func applyDamage(_ damage: Float) -> Bool {
        guard isBreakable else { return false }
        hitPoints -= damage
        return hitPoints <= 0
    }
}

// MARK: - Impact event

struct BuildingImpact {
    let buildingID: UUID
    let colliderPartID: String
    let role: BuildingColliderRole
    let impactSpeed: Float
    let verticalSpeed: Float
    let horizontalSpeed: Float
    let contactPoint: SIMD3<Float>
}

// MARK: - Physics categories for building parts

enum BuildingPhysicsCategory {
    static let wall: Int       = 1 << 3
    static let floor: Int      = 1 << 4
    static let roof: Int       = 1 << 5
    static let beam: Int       = 1 << 6
    static let glass: Int      = 1 << 7
    static let debris: Int     = 1 << 8
    static let door: Int       = 1 << 9
    static let railing: Int    = 1 << 10

    static let allBuildingParts: Int =
        wall | floor | roof | beam | glass | debris | door | railing

    static func categoryBitMask(for role: BuildingColliderRole) -> Int {
        switch role {
        case .wall:           return wall
        case .floor, .landingSurface: return floor
        case .roof:           return roof
        case .beam, .railing: return beam
        case .glass:          return glass
        case .debris:         return debris
        case .door:           return door
        }
    }
}

// MARK: - Debug color per role

enum BuildingColliderDebugColor {
    static func color(for role: BuildingColliderRole) -> NSColor {
        switch role {
        case .floor, .landingSurface:
            return NSColor(calibratedRed: 0.2, green: 0.8, blue: 0.2, alpha: 0.28)
        case .wall:
            return NSColor(calibratedRed: 0.9, green: 0.3, blue: 0.1, alpha: 0.28)
        case .roof:
            return NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.9, alpha: 0.28)
        case .beam, .railing:
            return NSColor(calibratedRed: 0.9, green: 0.9, blue: 0.1, alpha: 0.32)
        case .glass:
            return NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.95, alpha: 0.22)
        case .door:
            return NSColor(calibratedRed: 0.7, green: 0.5, blue: 0.2, alpha: 0.25)
        case .debris:
            return NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.6, alpha: 0.20)
        }
    }
}

// MARK: - Collider registry

final class BuildingColliderRegistry {
    static let shared = BuildingColliderRegistry()

    private var entries: [UUID: [String: BuildingColliderInstance]] = [:]
    private let lock = NSLock()

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func register(buildingID: UUID, instance: BuildingColliderInstance) {
        lock.lock()
        if entries[buildingID] == nil {
            entries[buildingID] = [:]
        }
        entries[buildingID]?[instance.partID] = instance
        lock.unlock()
    }

    func unregister(buildingID: UUID, partID: String) {
        lock.lock()
        entries[buildingID]?.removeValue(forKey: partID)
        if entries[buildingID]?.isEmpty == true {
            entries.removeValue(forKey: buildingID)
        }
        lock.unlock()
    }

    func colliderInfo(for node: SCNNode) -> BuildingColliderInstance? {
        guard let name = node.name else { return nil }
        lock.lock()
        defer { lock.unlock() }
        for (_, parts) in entries {
            for (_, instance) in parts {
                if instance.node === node {
                    return instance
                }
            }
        }
        return nil
    }

    func colliderInfo(buildingID: UUID, partID: String) -> BuildingColliderInstance? {
        lock.lock()
        defer { lock.unlock() }
        return entries[buildingID]?[partID]
    }

    func allInstances(for buildingID: UUID) -> [BuildingColliderInstance] {
        lock.lock()
        defer { lock.unlock() }
        return Array((entries[buildingID] ?? [:]).values)
    }

    func activeCount(for buildingID: UUID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return (entries[buildingID] ?? [:]).values.filter { !$0.isDestroyed }.count
    }

    var totalActiveParts: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.reduce(0) { sum, parts in
            sum + parts.values.filter { !$0.isDestroyed }.count
        }
    }

    func removePart(buildingID: UUID, partID: String) {
        lock.lock()
        entries[buildingID]?[partID]?.node?.removeFromParentNode()
        entries[buildingID]?.removeValue(forKey: partID)
        if entries[buildingID]?.isEmpty == true {
            entries.removeValue(forKey: buildingID)
        }
        lock.unlock()
    }

    func summaryByRole(for buildingID: UUID) -> [BuildingColliderRole: Int] {
        lock.lock()
        defer { lock.unlock() }
        var counts: [BuildingColliderRole: Int] = [:]
        for instance in (entries[buildingID] ?? [:]).values where !instance.isDestroyed {
            counts[instance.role, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Swept collision helper

struct SweptCollisionResult {
    let hit: Bool
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let partID: String?
    let role: BuildingColliderRole?
    let buildingID: UUID?
    let hitFraction: Float
}

enum BuildingSweptCollision {
    static func checkSphereSweep(
        from previousPosition: SIMD3<Float>,
        to currentPosition: SIMD3<Float>,
        sphereRadius: Float,
        registry: BuildingColliderRegistry
    ) -> SweptCollisionResult {
        let direction = currentPosition - previousPosition
        let travelLength = simd_length(direction)
        guard travelLength > 0.001 else {
            return SweptCollisionResult(
                hit: false, contactPoint: .zero, contactNormal: .zero,
                partID: nil, role: nil, buildingID: nil, hitFraction: 1.0
            )
        }

        let rayDir = direction / travelLength
        let segmentEnd = currentPosition

        var bestHitFraction: Float = 1.0
        var bestResult = SweptCollisionResult(
            hit: false, contactPoint: .zero, contactNormal: .zero,
            partID: nil, role: nil, buildingID: nil, hitFraction: 1.0
        )

        let allBuildings = registry.allBuildingsSnapshot()
        for (buildingID, instances) in allBuildings {
            for instance in instances where !instance.isDestroyed && instance.blocksUAV {
                guard let node = instance.node else { continue }
                guard let box = node.geometry as? SCNBox else { continue }

                let worldPos = node.worldPosition
                let halfW = Float(box.width) * 0.5
                let halfH = Float(box.height) * 0.5
                let halfD = Float(box.length) * 0.5

                let boxMin = SIMD3<Float>(
                    Float(worldPos.x) - halfW,
                    Float(worldPos.y) - halfH,
                    Float(worldPos.z) - halfD
                )
                let boxMax = SIMD3<Float>(
                    Float(worldPos.x) + halfW,
                    Float(worldPos.y) + halfH,
                    Float(worldPos.z) + halfD
                )

                if let hitFraction = rayBoxIntersect(
                    origin: previousPosition,
                    direction: rayDir,
                    boxMin: boxMin - SIMD3<Float>(repeating: sphereRadius),
                    boxMax: boxMax + SIMD3<Float>(repeating: sphereRadius)
                ), hitFraction < bestHitFraction && hitFraction >= 0.0 {
                    bestHitFraction = hitFraction
                    let hitPoint = previousPosition + rayDir * (hitFraction * travelLength)
                    let center = (boxMin + boxMax) * 0.5
                    var normal = simd_normalize(hitPoint - center)
                    if simd_length_squared(normal) < 0.001 {
                        normal = -rayDir
                    }
                    bestResult = SweptCollisionResult(
                        hit: true,
                        contactPoint: hitPoint,
                        contactNormal: normal,
                        partID: instance.partID,
                        role: instance.role,
                        buildingID: buildingID,
                        hitFraction: hitFraction
                    )
                }
            }
        }

        return bestResult
    }

    private static func rayBoxIntersect(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        boxMin: SIMD3<Float>,
        boxMax: SIMD3<Float>
    ) -> Float? {
        var tmin: Float = -.greatestFiniteMagnitude
        var tmax: Float = .greatestFiniteMagnitude

        for i in 0..<3 {
            let o = origin[i]
            let d = direction[i]
            let bmin = boxMin[i]
            let bmax = boxMax[i]

            guard abs(d) > 1e-8 else {
                if o < bmin || o > bmax { return nil }
                continue
            }

            let invD = 1.0 / d
            var t1 = (bmin - o) * invD
            var t2 = (bmax - o) * invD

            if t1 > t2 { swap(&t1, &t2) }

            tmin = max(tmin, t1)
            tmax = min(tmax, t2)

            if tmin > tmax { return nil }
        }

        if tmax < 0 { return nil }
        return tmin >= 0 ? tmin : tmax
    }
}

// MARK: - Registry snapshot extension

extension BuildingColliderRegistry {
    func allBuildingsSnapshot() -> [UUID: [BuildingColliderInstance]] {
        lock.lock()
        defer { lock.unlock() }
        var result: [UUID: [BuildingColliderInstance]] = [:]
        for (id, parts) in entries {
            result[id] = Array(parts.values)
        }
        return result
    }
}
