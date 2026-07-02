import SceneKit

struct AbandonedCityCompositionResult {
    let descriptors: [EnvironmentObjectDescriptor]
    let nodesByID: [UUID: SCNNode]
}

final class AbandonedCitySceneComposer {
    static let rootName = "environment.abandonedCity.root"

    private enum PhysicsCategory {
        static let environment = 1 << 1
        static let drone = 1 << 2
    }

    private static let legacyRootNames: Set<String> = [
        "environment.city.root",
        "environment.urban.root",
        rootName,
        "cityRoot",
        "urbanRoot",
        "oldCityDebugRoot",
        "proceduralCityRoot",
        "roadRoot",
        "sidewalkRoot",
        "blockRoot"
    ]

    private let buildingLoader: AbandonedCityBuildingLoader

    init(
        buildingLoader: AbandonedCityBuildingLoader = .shared
    ) {
        self.buildingLoader = buildingLoader
    }

    func rebuild(
        in sceneRoot: SCNNode,
        terrain: TerrainConfiguration
    ) -> AbandonedCityCompositionResult {
        let removedCount = removeLegacyRoots(from: sceneRoot)
        BuildingColliderRegistry.shared.reset()

        let root = SCNNode()
        root.name = Self.rootName
        sceneRoot.addChildNode(root)

        #if DEBUG
        print("[AbandonedCity] selected map=city")
        print("[AbandonedCity] old procedural city roots removed count=\(removedCount)")
        print("[AbandonedCity] procedural objects disabled=true")
        print("[AbandonedCity] excluded heavy building denysHroshko=true")
        print("[AbandonedCity] mapSize=\(Int(terrain.mapScale.numericPreset))")
        #endif

        for kind in AbandonedCityBuildingKind.allCases {
            let loaded = buildingLoader.isAvailable(kind)
            #if DEBUG
            print("[AbandonedCity] loaded building \(kind.rawValue)=\(loaded)")
            #endif
        }

        let layout = AbandonedCityLayout.makeLayout(
            terrain: terrain,
            loader: buildingLoader
        )
        var descriptors: [EnvironmentObjectDescriptor] = []
        var nodesByID: [UUID: SCNNode] = [:]
        var meshColliders = 0

        for placement in layout.placements {
            guard let buildingNode = buildingLoader.makeBuildingNode(
                kind: placement.kind,
                targetHeightMeters: placement.targetHeightMeters,
                yaw: placement.yaw
            ) else {
                continue
            }

            buildingNode.simdPosition = placement.position
            let collisionMeshParts = buildingLoader.collisionMeshParts(
                kind: placement.kind,
                targetHeightMeters: placement.targetHeightMeters
            )
            let supportSurfaceTriangleParts = buildingLoader.supportSurfaceTriangleParts(
                kind: placement.kind,
                targetHeightMeters: placement.targetHeightMeters
            )
            if let meshCollisionNode = makeMeshCollisionNode(for: placement) {
                buildingNode.addChildNode(meshCollisionNode)
                meshColliders += 1
            }
            if let collisionDebugNode = buildingLoader.makeCollisionDebugNode(
                kind: placement.kind,
                targetHeightMeters: placement.targetHeightMeters
            ) {
                buildingNode.addChildNode(collisionDebugNode)
            }
            root.addChildNode(buildingNode)

            let descriptor = EnvironmentObjectDescriptor(
                id: placement.id,
                kind: .building,
                biome: .city,
                position: placement.position,
                yawRadians: placement.yaw,
                size: SIMD3<Float>(
                    placement.normalizedSize.x,
                    placement.normalizedSize.y,
                    placement.normalizedSize.z
                ),
                boundingRadius: max(
                    placement.normalizedSize.x,
                    placement.normalizedSize.z
                ) * 0.5,
                isCollidable: true,
                collisionParts: [],
                supportSurfaceParts: [],
                collisionMeshParts: collisionMeshParts,
                supportSurfaceTriangleParts: supportSurfaceTriangleParts,
                usesScenePhysicsCollision: true
            )
            descriptors.append(descriptor)
            nodesByID[placement.id] = buildingNode
        }

        #if DEBUG
        print("[AbandonedCity] targetBuildings=\(layout.targetCount)")
        print("[AbandonedCity] placements requested=\(layout.targetCount)")
        print("[AbandonedCity] placements added=\(descriptors.count)")
        print("[AbandonedCity] skippedSpawnOverlap=\(layout.skippedSpawnOverlap)")
        print("[AbandonedCity] skippedFootprintOverlap=\(layout.skippedFootprintOverlap)")
        print("[AbandonedCity] skippedOutOfBounds=\(layout.skippedOutOfBounds)")
        print("[AbandonedCity] meshColliders=\(meshColliders)")
        print("[AbandonedCity] treesSkipped=true roadsSkipped=true placeholdersSkipped=true")
        if descriptors.count < AbandonedCityOptions.minimumBuildingCount(for: terrain.mapScale) {
            print("[AbandonedCity] WARNING placed buildings below minimum count")
        }
        #endif

        return AbandonedCityCompositionResult(
            descriptors: descriptors,
            nodesByID: nodesByID
        )
    }

    @discardableResult
    func removeLegacyRoots(from sceneRoot: SCNNode) -> Int {
        var removedCount = 0
        removeLegacyRoots(in: sceneRoot, removedCount: &removedCount)
        return removedCount
    }

    private func removeLegacyRoots(
        in node: SCNNode,
        removedCount: inout Int
    ) {
        for child in node.childNodes {
            if let name = child.name, Self.legacyRootNames.contains(name) {
                child.removeFromParentNode()
                removedCount += 1
            } else {
                removeLegacyRoots(in: child, removedCount: &removedCount)
            }
        }
    }

    private func makeMeshCollisionNode(
        for placement: AbandonedCityPlacement
    ) -> SCNNode? {
        guard let shape = buildingLoader.makeCollisionShape(
            kind: placement.kind,
            targetHeightMeters: placement.targetHeightMeters
        ) else {
            return nil
        }

        let node = SCNNode()
        node.name = "environment.abandonedCity.meshCollision.\(placement.kind.rawValue).\(placement.id.uuidString)"
        let body = SCNPhysicsBody(type: .static, shape: shape)
        body.isAffectedByGravity = false
        body.friction = 0.82
        body.restitution = 0.0
        body.categoryBitMask = PhysicsCategory.environment |
            BuildingPhysicsCategory.allBuildingParts
        body.collisionBitMask = PhysicsCategory.drone
        body.contactTestBitMask = PhysicsCategory.drone
        node.physicsBody = body
        BuildingColliderRegistry.shared.register(
            buildingID: placement.id,
            instance: BuildingColliderInstance(
                partID: "mesh",
                role: .wall,
                hitPoints: 9999.0,
                crashSpeedThreshold: 3.0,
                isBreakable: false,
                blocksUAV: true,
                node: node,
                buildingID: placement.id
            )
        )
        return node
    }
}
