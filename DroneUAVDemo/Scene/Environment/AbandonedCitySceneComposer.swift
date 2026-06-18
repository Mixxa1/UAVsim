import AppKit
import SceneKit

struct AbandonedCityCompositionResult {
    let descriptors: [EnvironmentObjectDescriptor]
    let nodesByID: [UUID: SCNNode]
}

final class AbandonedCitySceneComposer {
    static let rootName = "environment.abandonedCity.root"

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

    init(buildingLoader: AbandonedCityBuildingLoader = .shared) {
        self.buildingLoader = buildingLoader
    }

    func rebuild(
        in sceneRoot: SCNNode,
        terrain: TerrainConfiguration
    ) -> AbandonedCityCompositionResult {
        let removedCount = removeLegacyRoots(from: sceneRoot)
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
        var collisionBoxes = 0

        for placement in layout.placements {
            guard let buildingNode = buildingLoader.makeBuildingNode(
                kind: placement.kind,
                targetHeightMeters: placement.targetHeightMeters,
                yaw: placement.yaw
            ) else {
                continue
            }

            buildingNode.simdPosition = placement.position
            buildingNode.addChildNode(makeCollisionNode(for: placement))
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
                isCollidable: true
            )
            descriptors.append(descriptor)
            nodesByID[placement.id] = buildingNode
            collisionBoxes += 1
        }

        #if DEBUG
        print("[AbandonedCity] targetBuildings=\(layout.targetCount)")
        print("[AbandonedCity] placements requested=\(layout.targetCount)")
        print("[AbandonedCity] placements added=\(descriptors.count)")
        print("[AbandonedCity] skippedSpawnOverlap=\(layout.skippedSpawnOverlap)")
        print("[AbandonedCity] skippedFootprintOverlap=\(layout.skippedFootprintOverlap)")
        print("[AbandonedCity] skippedOutOfBounds=\(layout.skippedOutOfBounds)")
        print("[AbandonedCity] collisionBoxes=\(collisionBoxes)")
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

    private func makeCollisionNode(
        for placement: AbandonedCityPlacement
    ) -> SCNNode {
        let width = max(1.0, placement.normalizedSize.x)
        let height = max(1.0, placement.normalizedSize.y)
        let depth = max(1.0, placement.normalizedSize.z)
        let box = SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: 0.0
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.systemRed
        material.transparency = AbandonedCityOptions.enableDebugCollisionBoxes ? 0.22 : 0.0
        material.writesToDepthBuffer = false
        box.materials = [material]

        let node = SCNNode(geometry: box)
        node.name = "environment.abandonedCity.collision.\(placement.kind.rawValue).\(placement.id.uuidString)"
        node.position = SCNVector3(0.0, height * 0.5, 0.0)
        let shape = SCNPhysicsShape(
            geometry: box,
            options: [SCNPhysicsShape.Option.type: SCNPhysicsShape.ShapeType.boundingBox]
        )
        let body = SCNPhysicsBody(type: .static, shape: shape)
        body.isAffectedByGravity = false
        body.friction = 0.82
        body.restitution = 0.0
        body.categoryBitMask = 1 << 1
        body.collisionBitMask = 1 << 2
        body.contactTestBitMask = 1 << 2
        node.physicsBody = body
        return node
    }
}
