import AppKit
import SceneKit
import simd

enum EnvironmentProceduralVisualFactory {
    static func makeNode(
        for descriptor: EnvironmentObjectDescriptor,
        quality: EnvironmentVisualQuality = .detailed
    ) -> SCNNode {
        if quality == .simplified {
            return makeSimplifiedNode(descriptor: descriptor)
        }

        switch descriptor.kind {
        case .tree:
            return makeTreeNode(descriptor: descriptor)
        case .building:
            return makeBuildingNode(descriptor: descriptor)
        case .pole:
            return makePoleNode(descriptor: descriptor)
        case .crate:
            return makeCrateNode(descriptor: descriptor)
        case .cargoContainer:
            return makeCargoContainerNode(descriptor: descriptor)
        case .rock:
            return makeRockNode(descriptor: descriptor)
        case .marker:
            return makeMarkerNode(descriptor: descriptor)
        }
    }

    private static func makeSimplifiedNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        switch descriptor.kind {
        case .tree:
            return makeSimplifiedTreeNode(descriptor: descriptor)
        case .building:
            return makeSimplifiedBuildingNode(descriptor: descriptor)
        case .pole:
            return makeSimplifiedPoleNode(descriptor: descriptor)
        case .crate:
            return makeSimplifiedBoxNode(
                descriptor: descriptor,
                color: NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.20, alpha: 1.0),
                namePrefix: "fast_crate"
            )
        case .cargoContainer:
            return makeCargoContainerNode(descriptor: descriptor)
        case .rock:
            return makeSimplifiedBoxNode(
                descriptor: descriptor,
                color: NSColor(calibratedRed: 0.38, green: 0.40, blue: 0.42, alpha: 1.0),
                namePrefix: "fast_rock"
            )
        case .marker:
            return makeSimplifiedMarkerNode(descriptor: descriptor)
        }
    }

    private static func makeSimplifiedTreeNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let root = SCNNode()
        root.name = "fast_tree_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)

        let height = descriptor.size.y.clamped(to: 8.0...28.0)
        let width = descriptor.size.x.clamped(to: 3.0...11.0)
        let trunkHeight = max(2.2, height * 0.48)
        let trunkWidth = max(0.32, width * 0.16)
        let crownWidth = max(2.2, width * 0.92)
        let crownHeight = max(2.4, height * 0.38)

        let trunk = SCNNode(geometry: SCNBox(
            width: CGFloat(trunkWidth),
            height: CGFloat(trunkHeight),
            length: CGFloat(trunkWidth),
            chamferRadius: 0.0
        ))
        trunk.position = SCNVector3(0, trunkHeight * 0.5, 0)
        trunk.geometry?.materials = [simplifiedMaterial(
            key: "fastTreeTrunk",
            color: NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.13, alpha: 1.0)
        )]
        root.addChildNode(trunk)

        let crownColor: NSColor
        switch descriptor.biome {
        case .forest:
            crownColor = NSColor(calibratedRed: 0.13, green: 0.40, blue: 0.16, alpha: 1.0)
        case .field:
            crownColor = NSColor(calibratedRed: 0.28, green: 0.52, blue: 0.20, alpha: 1.0)
        case .city, .cargoYard:
            crownColor = NSColor(calibratedRed: 0.23, green: 0.42, blue: 0.20, alpha: 1.0)
        case .gridDemo:
            crownColor = NSColor(calibratedRed: 0.24, green: 0.50, blue: 0.24, alpha: 1.0)
        }

        let crown = SCNNode(geometry: SCNBox(
            width: CGFloat(crownWidth),
            height: CGFloat(crownHeight),
            length: CGFloat(crownWidth),
            chamferRadius: 0.0
        ))
        crown.position = SCNVector3(0, trunkHeight + crownHeight * 0.48, 0)
        crown.geometry?.materials = [simplifiedMaterial(key: "fastTreeLeaf-\(descriptor.biome.rawValue)", color: crownColor)]
        root.addChildNode(crown)

        configureLightweightEnvironmentNode(root)
        return root
    }

    private static func makeSimplifiedBuildingNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let width = max(6.0, descriptor.size.x)
        let depth = max(6.0, descriptor.size.z)
        let height = max(8.0, descriptor.size.y)

        let root = SCNNode()
        root.name = "fast_building_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)

        let body = SCNNode(geometry: SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: 0.0
        ))
        body.position = SCNVector3(0, height * 0.5, 0)
        body.geometry?.materials = [simplifiedMaterial(
            key: "fastBuilding-\(descriptor.biome.rawValue)",
            color: descriptor.biome == .city
                ? NSColor(calibratedRed: 0.32, green: 0.35, blue: 0.39, alpha: 1.0)
                : NSColor(calibratedRed: 0.40, green: 0.38, blue: 0.32, alpha: 1.0)
        )]
        root.addChildNode(body)

        let roofHeight = max(0.4, min(1.4, height * 0.05))
        let roof = SCNNode(geometry: SCNBox(
            width: CGFloat(width * 1.02),
            height: CGFloat(roofHeight),
            length: CGFloat(depth * 1.02),
            chamferRadius: 0.0
        ))
        roof.position = SCNVector3(0, height + roofHeight * 0.5, 0)
        roof.geometry?.materials = [simplifiedMaterial(
            key: "fastRoof",
            color: NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.25, alpha: 1.0)
        )]
        root.addChildNode(roof)

        configureLightweightEnvironmentNode(root)
        return root
    }

    private static func makeSimplifiedPoleNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let width = max(0.18, descriptor.size.x * 0.24)
        let height = max(2.0, descriptor.size.y)
        let node = SCNNode(geometry: SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(width),
            chamferRadius: 0.0
        ))
        node.name = "fast_pole_\(descriptor.id.uuidString)"
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + height * 0.5, descriptor.position.z)
        node.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)
        node.geometry?.materials = [simplifiedMaterial(
            key: "fastPole",
            color: NSColor(calibratedRed: 0.58, green: 0.58, blue: 0.62, alpha: 1.0)
        )]
        configureLightweightEnvironmentNode(node)
        return node
    }

    private static func makeSimplifiedMarkerNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let node = SCNNode(geometry: SCNPyramid(
            width: CGFloat(max(0.7, descriptor.size.x)),
            height: CGFloat(max(1.2, descriptor.size.y)),
            length: CGFloat(max(0.7, descriptor.size.z))
        ))
        node.name = "fast_marker_\(descriptor.id.uuidString)"
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y * 0.5, descriptor.position.z)
        node.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)
        node.geometry?.materials = [simplifiedMaterial(
            key: "fastMarker",
            color: NSColor.systemOrange
        )]
        configureLightweightEnvironmentNode(node)
        return node
    }

    private static func makeSimplifiedBoxNode(
        descriptor: EnvironmentObjectDescriptor,
        color: NSColor,
        namePrefix: String
    ) -> SCNNode {
        let node = SCNNode(geometry: SCNBox(
            width: CGFloat(max(0.6, descriptor.size.x)),
            height: CGFloat(max(0.6, descriptor.size.y)),
            length: CGFloat(max(0.6, descriptor.size.z)),
            chamferRadius: 0.0
        ))
        node.name = "\(namePrefix)_\(descriptor.id.uuidString)"
        node.position = SCNVector3(
            descriptor.position.x,
            descriptor.position.y + max(0.6, descriptor.size.y) * 0.5,
            descriptor.position.z
        )
        node.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)
        node.geometry?.materials = [simplifiedMaterial(key: namePrefix, color: color)]
        configureLightweightEnvironmentNode(node)
        return node
    }

    private static func configureLightweightEnvironmentNode(_ node: SCNNode) {
        node.castsShadow = false
        node.geometry?.materials.forEach { material in
            material.lightingModel = .constant
            material.writesToDepthBuffer = true
        }
        node.enumerateChildNodes { child, _ in
            child.castsShadow = false
            child.geometry?.materials.forEach { material in
                material.lightingModel = .constant
                material.writesToDepthBuffer = true
            }
        }
    }

    private static func simplifiedMaterial(key: String, color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.ambient.contents = color
        material.emission.contents = color.withAlphaComponent(0.12)
        material.isDoubleSided = true
        material.writesToDepthBuffer = true
        return material
    }

    static func roofHeight(for buildingHeight: Float) -> Float {
        max(0.6, min(2.2, buildingHeight * 0.06))
    }

    private static func makeTreeNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))
        let archetype = treeArchetype(for: descriptor.biome, using: &rng)

        let parent = SCNNode()
        parent.name = "obstacle_tree_\(descriptor.id.uuidString)"
        parent.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        parent.eulerAngles = SCNVector3(
            (rng.nextFloat() - 0.5) * 0.05,
            rng.nextFloat() * .pi * 2.0,
            (rng.nextFloat() - 0.5) * 0.07
        )

        let baseHeight = descriptor.size.y.clamped(to: 10.0...34.0)
        let baseWidth = descriptor.size.x.clamped(to: 3.2...10.8)
        let trunkHeight = baseHeight * archetype.trunkHeightFactor * (0.90 + rng.nextFloat() * 0.18)
        let trunkRadius = max(0.12, baseWidth * archetype.trunkRadiusFactor * (0.94 + rng.nextFloat() * 0.18))
        let crownScale = max(
            baseWidth * archetype.crownScaleFactor * 1.92,
            baseHeight * archetype.crownHeightFactor * 1.18
        ).clamped(to: 3.4...15.0)

        let bark = EnvironmentProceduralMaterials.barkMaterial(variant: Int(rng.next() % 3))
        let leaf = EnvironmentProceduralMaterials.leafMaterial(variant: Int(rng.next() % 3), biome: descriptor.biome)

        let trunk = SCNNode(geometry: lowPolyCylinder(radius: trunkRadius, height: trunkHeight))
        trunk.position = SCNVector3(0, trunkHeight * 0.5, 0)
        trunk.geometry?.materials = [bark]
        parent.addChildNode(trunk)

        switch archetype {
        case .oak:
            let crowns: [(Float, SIMD3<Float>, SIMD3<Float>)] = [
                (0.50, SIMD3<Float>(0, trunkHeight + crownScale * 0.36, 0), SIMD3<Float>(1.26, 0.92, 1.20)),
                (0.34, SIMD3<Float>(crownScale * 0.20, trunkHeight + crownScale * 0.62, -crownScale * 0.16), SIMD3<Float>(1, 1, 1)),
                (0.30, SIMD3<Float>(-crownScale * 0.22, trunkHeight + crownScale * 0.58, crownScale * 0.12), SIMD3<Float>(1, 1, 1)),
                (0.28, SIMD3<Float>(0, trunkHeight + crownScale * 0.82, crownScale * 0.05), SIMD3<Float>(1, 1, 1)),
                (0.24, SIMD3<Float>(-crownScale * 0.06, trunkHeight + crownScale * 0.46, -crownScale * 0.22), SIMD3<Float>(1, 1, 1))
            ]
            for crown in crowns {
                parent.addChildNode(makeFoliageSphere(
                    radius: crown.0 * crownScale,
                    position: crown.1,
                    scale: crown.2,
                    material: leaf
                ))
            }
            addBranchRing(
                count: 3,
                anchorHeight: trunkHeight * 0.86,
                branchLength: crownScale * 0.48,
                branchRadius: trunkRadius * 0.54,
                tilt: 1.02,
                bark: bark,
                rng: &rng,
                parent: parent
            )

        case .pine:
            let tiers: [(Float, Float, Float)] = [
                (0.44, 1.18, 0.34),
                (0.36, 0.98, 0.72),
                (0.30, 0.94, 1.04)
            ]
            for tier in tiers {
                let node = SCNNode(geometry: lowPolyCone(
                    topRadius: 0.02,
                    bottomRadius: crownScale * tier.0,
                    height: crownScale * tier.1
                ))
                node.position = SCNVector3(0, trunkHeight + crownScale * tier.2, 0)
                node.geometry?.materials = [leaf]
                parent.addChildNode(node)
            }
            parent.addChildNode(makeFoliageSphere(
                radius: crownScale * 0.14,
                position: SIMD3<Float>(0, trunkHeight + crownScale * 1.28, 0),
                scale: SIMD3<Float>(0.58, 1.44, 0.58),
                material: leaf
            ))

        case .birch:
            parent.addChildNode(makeFoliageSphere(
                radius: crownScale * 0.38,
                position: SIMD3<Float>(0, trunkHeight + crownScale * 0.48, 0),
                scale: SIMD3<Float>(1.06, 1.42, 0.98),
                material: leaf
            ))
            parent.addChildNode(makeFoliageSphere(
                radius: crownScale * 0.28,
                position: SIMD3<Float>(crownScale * 0.10, trunkHeight + crownScale * 0.82, -crownScale * 0.05),
                scale: SIMD3<Float>(0.96, 1.24, 0.92),
                material: leaf
            ))
            parent.addChildNode(makeFoliageSphere(
                radius: crownScale * 0.18,
                position: SIMD3<Float>(-crownScale * 0.12, trunkHeight + crownScale * 0.22, crownScale * 0.10),
                scale: SIMD3<Float>(1.18, 0.92, 1.04),
                material: leaf
            ))

        case .acacia:
            addBranchRing(
                count: 4,
                anchorHeight: trunkHeight * 0.94,
                branchLength: crownScale * 0.56,
                branchRadius: trunkRadius * 0.48,
                tilt: 1.10,
                bark: bark,
                rng: &rng,
                parent: parent
            )

            let crownCenterY = trunkHeight + crownScale * 0.32
            let lobes: [(Float, SIMD3<Float>, SIMD3<Float>)] = [
                (0.36, SIMD3<Float>(0, crownCenterY, 0), SIMD3<Float>(1.48, 0.34, 1.18)),
                (0.30, SIMD3<Float>(crownScale * 0.34, crownCenterY + crownScale * 0.06, -crownScale * 0.12), SIMD3<Float>(1.18, 0.42, 1.02)),
                (0.28, SIMD3<Float>(-crownScale * 0.32, crownCenterY + crownScale * 0.10, crownScale * 0.18), SIMD3<Float>(1.12, 0.40, 1.04)),
                (0.22, SIMD3<Float>(crownScale * 0.08, crownCenterY + crownScale * 0.20, crownScale * 0.26), SIMD3<Float>(1.00, 0.56, 0.92))
            ]
            for lobe in lobes {
                parent.addChildNode(makeFoliageSphere(
                    radius: lobe.0 * crownScale,
                    position: lobe.1,
                    scale: lobe.2,
                    material: leaf
                ))
            }
        }

        return parent
    }

    private static func treeArchetype(
        for biome: TerrainPreset,
        using rng: inout DeterministicRNG
    ) -> TreeArchetype {
        let roll = rng.nextFloat()
        switch biome {
        case .forest:
            if roll < 0.54 { return .pine }
            if roll < 0.78 { return .birch }
            if roll < 0.96 { return .oak }
            return .acacia
        case .field:
            if roll < 0.62 { return .oak }
            if roll < 0.92 { return .birch }
            return .pine
        case .cargoYard:
            if roll < 0.66 { return .birch }
            if roll < 0.96 { return .oak }
            return .pine
        case .city:
            if roll < 0.58 { return .birch }
            if roll < 0.94 { return .oak }
            return .pine
        case .gridDemo:
            return roll < 0.5 ? .oak : .pine
        }
    }

    private static func makeFoliageSphere(
        radius: Float,
        position: SIMD3<Float>,
        scale: SIMD3<Float>,
        material: SCNMaterial
    ) -> SCNNode {
        let node = SCNNode(geometry: lowPolySphere(radius: radius))
        node.position = SCNVector3(position.x, position.y, position.z)
        node.scale = SCNVector3(scale.x, scale.y, scale.z)
        node.geometry?.materials = [material]
        return node
    }

    private static func addBranchRing(
        count: Int,
        anchorHeight: Float,
        branchLength: Float,
        branchRadius: Float,
        tilt: Float,
        bark: SCNMaterial,
        rng: inout DeterministicRNG,
        parent: SCNNode
    ) {
        guard count > 0 else {
            return
        }

        for index in 0..<count {
            let yaw = (Float(index) / Float(count)) * (.pi * 2.0) + (rng.nextFloat() - 0.5) * 0.34
            let branch = SCNNode(geometry: lowPolyCylinder(
                radius: max(0.06, branchRadius * (0.90 + rng.nextFloat() * 0.18)),
                height: branchLength * (0.88 + rng.nextFloat() * 0.18)
            ))
            branch.geometry?.materials = [bark]
            branch.position = SCNVector3(
                cos(yaw) * branchRadius * 0.30,
                anchorHeight,
                sin(yaw) * branchRadius * 0.30
            )
            branch.eulerAngles = SCNVector3(0, yaw, tilt + (rng.nextFloat() - 0.5) * 0.18)
            parent.addChildNode(branch)
        }
    }

    private static func makeBuildingNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let width = max(6.0, descriptor.size.x)
        let depth = max(6.0, descriptor.size.z)
        let height = max(9.0, descriptor.size.y)
        let seed = descriptorSeed(descriptor)
        let roofHeight = roofHeight(for: height)

        let root = SCNNode()
        root.name = "obstacle_building_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, descriptor.yawRadians, 0)

        let body = SCNNode(geometry: SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: CGFloat(min(width, depth) * 0.02)
        ))
        body.position = SCNVector3(0, height * 0.5, 0)
        body.geometry?.materials = EnvironmentProceduralMaterials.buildingFacadeMaterials(
            biome: descriptor.biome,
            width: width,
            depth: depth,
            height: height,
            seed: seed
        )
        root.addChildNode(body)

        let roof = SCNNode(geometry: SCNBox(
            width: CGFloat(width * 1.02),
            height: CGFloat(roofHeight),
            length: CGFloat(depth * 1.02),
            chamferRadius: 0.0
        ))
        roof.position = SCNVector3(0, height + roofHeight * 0.5, 0)
        roof.geometry?.materials = [EnvironmentProceduralMaterials.roofMaterial(height: height, seed: seed)]
        root.addChildNode(roof)

        let parapetThickness = max(0.28, min(0.54, min(width, depth) * 0.04))
        let parapetHeight = max(0.28, min(0.65, roofHeight * 0.72))
        let parapetMaterial = roof.geometry?.firstMaterial?.copy() as? SCNMaterial ?? EnvironmentProceduralMaterials.roofMaterial(height: height, seed: seed)
        let parapetY = height + roofHeight + parapetHeight * 0.5

        let parapets: [(CGFloat, CGFloat, Float, Float)] = [
            (CGFloat(width * 1.02), CGFloat(parapetHeight), 0, depth * 0.51),
            (CGFloat(width * 1.02), CGFloat(parapetHeight), 0, -depth * 0.51),
            (CGFloat(parapetThickness), CGFloat(parapetHeight), width * 0.51, 0),
            (CGFloat(parapetThickness), CGFloat(parapetHeight), -width * 0.51, 0)
        ]
        for parapet in parapets {
            let wall = SCNNode(geometry: SCNBox(
                width: parapet.0,
                height: parapet.1,
                length: parapet.0 > parapet.1 ? CGFloat(parapetThickness) : CGFloat(depth * 1.02),
                chamferRadius: 0.0
            ))
            if parapet.0 == CGFloat(parapetThickness) {
                wall.geometry = SCNBox(width: parapet.0, height: parapet.1, length: CGFloat(depth * 1.02), chamferRadius: 0.0)
            }
            wall.position = SCNVector3(parapet.2, parapetY, parapet.3)
            wall.geometry?.materials = [parapetMaterial]
            root.addChildNode(wall)
        }

        var rng = DeterministicRNG(seed: seed &+ 0x51)
        if height > 16.0 {
            let roofModuleCount = 1 + Int(rng.next() % 2)
            for index in 0..<roofModuleCount {
                let module = SCNNode(geometry: SCNBox(
                    width: CGFloat(1.6 + rng.nextFloat() * 2.0),
                    height: CGFloat(0.8 + rng.nextFloat() * 1.2),
                    length: CGFloat(1.2 + rng.nextFloat() * 1.8),
                    chamferRadius: 0.04
                ))
                module.position = SCNVector3(
                    (Float(index) - 0.5) * min(width * 0.28, 3.2),
                    height + roofHeight + Float(module.boundingBox.max.y - module.boundingBox.min.y) * 0.5,
                    (rng.nextFloat() - 0.5) * min(depth * 0.24, 2.8)
                )
                module.geometry?.materials = [EnvironmentProceduralMaterials.roofMaterial(height: height, seed: seed &+ UInt64(index) &+ 0x91)]
                root.addChildNode(module)
            }
        }

        return root
    }

    private static func makePoleNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = lowPolyCylinder(radius: descriptor.size.x * 0.28, height: descriptor.size.y)
        geometry.materials = [EnvironmentProceduralMaterials.utilityPoleMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_pole_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeCrateNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNBox(
            width: CGFloat(descriptor.size.x),
            height: CGFloat(descriptor.size.y),
            length: CGFloat(descriptor.size.z),
            chamferRadius: CGFloat(min(descriptor.size.x, descriptor.size.z) * 0.06)
        )
        geometry.materials = [EnvironmentProceduralMaterials.crateMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_crate_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeCargoContainerNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let root = SCNNode()
        root.name = "fallback_cargo_container_\(descriptor.id.uuidString)"
        root.position = SCNVector3(
            descriptor.position.x,
            descriptor.position.y,
            descriptor.position.z
        )
        root.eulerAngles.y = CGFloat(descriptor.yawRadians)

        let material = EnvironmentProceduralMaterials.crateMaterial
        let length = max(2.0, descriptor.size.x)
        let height = max(1.8, descriptor.size.y)
        let width = max(1.6, descriptor.size.z)

        if descriptor.cargoAsset?.hasFlyableInterior == true {
            let wallThickness: Float = 0.12
            let parts: [(SIMD3<Float>, SIMD3<Float>)] = [
                (SIMD3<Float>(0.0, wallThickness * 0.5, 0.0), SIMD3<Float>(length, wallThickness, width)),
                (SIMD3<Float>(0.0, height - wallThickness * 0.5, 0.0), SIMD3<Float>(length, wallThickness, width)),
                (SIMD3<Float>(0.0, height * 0.5, -width * 0.5 + wallThickness * 0.5), SIMD3<Float>(length, height, wallThickness)),
                (SIMD3<Float>(0.0, height * 0.5, width * 0.5 - wallThickness * 0.5), SIMD3<Float>(length, height, wallThickness)),
                (SIMD3<Float>(-length * 0.5 + wallThickness * 0.5, height * 0.5, 0.0), SIMD3<Float>(wallThickness, height, width))
            ]
            for part in parts {
                let node = SCNNode(geometry: SCNBox(
                    width: CGFloat(part.1.x),
                    height: CGFloat(part.1.y),
                    length: CGFloat(part.1.z),
                    chamferRadius: 0.0
                ))
                node.simdPosition = part.0
                node.geometry?.materials = [material]
                root.addChildNode(node)
            }
        } else {
            let box = SCNBox(
                width: CGFloat(length),
                height: CGFloat(height),
                length: CGFloat(width),
                chamferRadius: 0.04
            )
            box.materials = [material]
            let body = SCNNode(geometry: box)
            body.position.y = CGFloat(height * 0.5)
            root.addChildNode(body)
        }

        return root
    }

    private static func makeRockNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let root = SCNNode()
        root.name = "obstacle_rock_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)

        let geometry = lowPolySphere(radius: descriptor.size.x * 0.46)
        geometry.materials = [EnvironmentProceduralMaterials.rockMaterial]

        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(1.0, descriptor.size.y / max(0.01, descriptor.size.x), 1.18)
        node.position = SCNVector3(0, descriptor.size.y * 0.45, 0)
        root.addChildNode(node)

        return root
    }

    private static func makeMarkerNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = lowPolyCone(topRadius: 0.0, bottomRadius: descriptor.size.x * 0.55, height: descriptor.size.y)
        geometry.materials = [EnvironmentProceduralMaterials.markerMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_marker_\(descriptor.id.uuidString)"
        return node
    }

    private static func lowPolySphere(radius: Float) -> SCNSphere {
        let geometry = SCNSphere(radius: CGFloat(radius))
        geometry.segmentCount = 8
        return geometry
    }

    private static func lowPolyCylinder(radius: Float, height: Float) -> SCNCylinder {
        let geometry = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
        geometry.radialSegmentCount = 8
        geometry.heightSegmentCount = 1
        return geometry
    }

    private static func lowPolyCone(topRadius: Float, bottomRadius: Float, height: Float) -> SCNCone {
        let geometry = SCNCone(
            topRadius: CGFloat(topRadius),
            bottomRadius: CGFloat(bottomRadius),
            height: CGFloat(height)
        )
        geometry.radialSegmentCount = 8
        geometry.heightSegmentCount = 1
        return geometry
    }

    private static func descriptorSeed(_ descriptor: EnvironmentObjectDescriptor) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(descriptor.id)
        hasher.combine(descriptor.position.x.bitPattern)
        hasher.combine(descriptor.position.y.bitPattern)
        hasher.combine(descriptor.position.z.bitPattern)
        hasher.combine(descriptor.size.x.bitPattern)
        hasher.combine(descriptor.size.y.bitPattern)
        hasher.combine(descriptor.size.z.bitPattern)
        hasher.combine(descriptor.kind.rawValue)
        hasher.combine(descriptor.biome.rawValue)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

private enum TreeArchetype: CaseIterable {
    case oak
    case pine
    case birch
    case acacia

    var trunkHeightFactor: Float {
        switch self {
        case .oak: return 0.58
        case .pine: return 0.52
        case .birch: return 0.68
        case .acacia: return 0.64
        }
    }

    var trunkRadiusFactor: Float {
        switch self {
        case .oak: return 0.14
        case .pine: return 0.11
        case .birch: return 0.09
        case .acacia: return 0.12
        }
    }

    var crownScaleFactor: Float {
        switch self {
        case .oak: return 0.86
        case .pine: return 0.78
        case .birch: return 0.70
        case .acacia: return 0.82
        }
    }

    var crownHeightFactor: Float {
        switch self {
        case .oak: return 0.28
        case .pine: return 0.40
        case .birch: return 0.30
        case .acacia: return 0.24
        }
    }
}

private struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xBEEF_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1442695040888963407
        return state
    }

    mutating func nextFloat() -> Float {
        Float(next() & 0xFFFF) / Float(0xFFFF)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
