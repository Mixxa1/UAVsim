import AppKit
import SceneKit
import simd

enum EnvironmentObjectFactory {
    static func makeNode(for descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        switch descriptor.kind {
        case .tree:
            return makeTreeNode(descriptor: descriptor)
        case .building:
            return makeBuildingNode(descriptor: descriptor)
        case .pole:
            return makePoleNode(descriptor: descriptor)
        case .crate:
            return makeCrateNode(descriptor: descriptor)
        case .rock:
            return makeRockNode(descriptor: descriptor)
        case .marker:
            return makeMarkerNode(descriptor: descriptor)
        case .distantBelt:
            return makeDistantMaskNode(descriptor: descriptor)
        }
    }

    private static func makeTreeNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))
        let archetype = TreeArchetype.allCases[Int(rng.nextFloat() * Float(TreeArchetype.allCases.count)) % TreeArchetype.allCases.count]

        let parent = SCNNode()
        parent.name = "obstacle_tree_\(descriptor.id.uuidString)"
        parent.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        parent.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        let baseHeight = descriptor.size.y.clamped(to: 5.0...24.0)
        let baseWidth = descriptor.size.x.clamped(to: 1.4...6.4)
        let trunkHeight = baseHeight * archetype.trunkHeightFactor * (0.92 + rng.nextFloat() * 0.16)
        let trunkRadius = max(0.08, baseWidth * archetype.trunkRadiusFactor * (0.92 + rng.nextFloat() * 0.16))
        let crownScale = (baseWidth * archetype.crownScaleFactor).clamped(to: 1.2...8.0)

        let alternationIndex = Int(abs(descriptor.position.x).rounded(.toNearestOrAwayFromZero) + abs(descriptor.position.z).rounded(.toNearestOrAwayFromZero))
        let barkVariant = alternationIndex % 3
        let leafVariant = (alternationIndex / 2 + Int(rng.next() % 3)) % 3

        let bark = EnvironmentMaterialRegistry.barkMaterial(variant: barkVariant)
        let leaf = EnvironmentMaterialRegistry.leafMaterial(variant: leafVariant, biome: descriptor.biome)
        let modelVariant = (alternationIndex + Int(rng.next() % 3)) % 3

        if let lowPolyTree = makeLowPolyTreeNode(
            variant: modelVariant,
            baseHeight: baseHeight,
            baseWidth: baseWidth,
            barkMaterial: bark,
            leafMaterial: leaf,
            rng: &rng
        ) {
            parent.addChildNode(lowPolyTree)
            return parent
        }

        let trunk = SCNNode(geometry: SCNCylinder(radius: CGFloat(trunkRadius), height: CGFloat(trunkHeight)))
        trunk.position = SCNVector3(0, trunkHeight * 0.5, 0)
        trunk.geometry?.materials = [bark]
        parent.addChildNode(trunk)

        switch archetype {
        case .oak:
            let crownA = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.42)))
            crownA.position = SCNVector3(0, trunkHeight + crownScale * 0.36, 0)
            crownA.scale = SCNVector3(1.10, 0.82, 1.08)
            crownA.geometry?.materials = [leaf]

            let crownB = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.28)))
            crownB.position = SCNVector3(crownScale * 0.14, trunkHeight + crownScale * 0.58, -crownScale * 0.10)
            crownB.geometry?.materials = [leaf]

            parent.addChildNode(crownA)
            parent.addChildNode(crownB)

        case .pine:
            let crownLower = SCNNode(geometry: SCNCone(topRadius: 0.08, bottomRadius: CGFloat(crownScale * 0.38), height: CGFloat(crownScale * 1.1)))
            crownLower.position = SCNVector3(0, trunkHeight + crownScale * 0.40, 0)
            crownLower.geometry?.materials = [leaf]

            let crownUpper = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: CGFloat(crownScale * 0.26), height: CGFloat(crownScale * 0.9)))
            crownUpper.position = SCNVector3(0, trunkHeight + crownScale * 0.92, 0)
            crownUpper.geometry?.materials = [leaf]

            parent.addChildNode(crownLower)
            parent.addChildNode(crownUpper)

        case .birch:
            let crown = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.34)))
            crown.scale = SCNVector3(1.0, 1.24, 0.95)
            crown.position = SCNVector3(0, trunkHeight + crownScale * 0.48, 0)
            crown.geometry?.materials = [leaf]
            parent.addChildNode(crown)

        case .acacia:
            let canopy = SCNNode(geometry: SCNCylinder(radius: CGFloat(crownScale * 0.46), height: CGFloat(crownScale * 0.18)))
            canopy.position = SCNVector3(0, trunkHeight + crownScale * 0.62, 0)
            canopy.geometry?.materials = [leaf]

            let canopyLobe = SCNNode(geometry: SCNSphere(radius: CGFloat(crownScale * 0.24)))
            canopyLobe.position = SCNVector3(crownScale * 0.22, trunkHeight + crownScale * 0.64, -crownScale * 0.12)
            canopyLobe.geometry?.materials = [leaf]

            parent.addChildNode(canopy)
            parent.addChildNode(canopyLobe)
        }

        return parent
    }

    private static func makeBuildingNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))
        let facadeFamily = pickFacadeFamily(for: descriptor.biome, random: rng.nextFloat())
        let roofFamily = pickRoofFamily(random: rng.nextFloat())
        let width = max(6.0, descriptor.size.x)
        let depth = max(6.0, descriptor.size.z)
        let height = max(9.0, descriptor.size.y)

        let facadeMaterials = EnvironmentMaterialRegistry.buildingFacadeMaterials(
            family: facadeFamily,
            variant: Int(rng.next() % 4),
            width: width,
            depth: depth,
            height: height,
            seed: descriptorSeed(descriptor)
        )
        let roofMaterial = EnvironmentMaterialRegistry.roofMaterial(family: roofFamily, variant: Int(rng.next() % 3))

        let root = SCNNode()
        root.name = "obstacle_building_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        let body = SCNNode(geometry: SCNBox(
            width: CGFloat(width),
            height: CGFloat(height),
            length: CGFloat(depth),
            chamferRadius: CGFloat(min(width, depth) * 0.02)
        ))
        body.position = SCNVector3(0, height * 0.5, 0)
        body.geometry?.materials = facadeMaterials

        let roofHeight = max(0.5, min(2.4, height * 0.05))
        let roof = SCNNode(geometry: SCNBox(
            width: CGFloat(width * 1.02),
            height: CGFloat(roofHeight),
            length: CGFloat(depth * 1.02),
            chamferRadius: 0.0
        ))
        roof.position = SCNVector3(0, height + roofHeight * 0.5, 0)
        roof.geometry?.materials = [roofMaterial]

        root.addChildNode(body)
        root.addChildNode(roof)
        return root
    }

    private static func makePoleNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNCylinder(radius: CGFloat(descriptor.size.x * 0.28), height: CGFloat(descriptor.size.y))
        geometry.materials = [EnvironmentMaterialRegistry.utilityPoleMaterial]

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
        geometry.materials = [EnvironmentMaterialRegistry.crateMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_crate_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeRockNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNSphere(radius: CGFloat(descriptor.size.x * 0.46))
        geometry.materials = [EnvironmentMaterialRegistry.rockMaterial]

        let node = SCNNode(geometry: geometry)
        node.scale = SCNVector3(1.0, descriptor.size.y / max(0.01, descriptor.size.x), 1.0)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y * 0.45, descriptor.position.z)
        node.name = "obstacle_rock_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeMarkerNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        let geometry = SCNCone(topRadius: 0.0, bottomRadius: CGFloat(descriptor.size.x * 0.55), height: CGFloat(descriptor.size.y))
        geometry.materials = [EnvironmentMaterialRegistry.markerMaterial]

        let node = SCNNode(geometry: geometry)
        node.position = SCNVector3(descriptor.position.x, descriptor.position.y + descriptor.size.y / 2.0, descriptor.position.z)
        node.name = "obstacle_marker_\(descriptor.id.uuidString)"
        return node
    }

    private static func makeDistantMaskNode(descriptor: EnvironmentObjectDescriptor) -> SCNNode {
        var rng = DeterministicRNG(seed: descriptorSeed(descriptor))

        let root = SCNNode()
        root.name = "distant_mask_\(descriptor.id.uuidString)"
        root.position = SCNVector3(descriptor.position.x, descriptor.position.y, descriptor.position.z)
        root.eulerAngles = SCNVector3(0, rng.nextFloat() * .pi * 2.0, 0)

        switch descriptor.biome {
        case .forest:
            for index in 0..<3 {
                let cone = SCNNode(geometry: SCNCone(
                    topRadius: 0.02,
                    bottomRadius: CGFloat(descriptor.size.x * (0.32 + Float(index) * 0.10)),
                    height: CGFloat(descriptor.size.y * (0.34 + Float(index) * 0.18))
                ))
                cone.position = SCNVector3(
                    Float(index - 1) * descriptor.size.x * 0.18,
                    descriptor.size.y * (0.16 + Float(index) * 0.20),
                    0
                )
                cone.geometry?.materials = [EnvironmentMaterialRegistry.farForestMaterial]
                root.addChildNode(cone)
            }

        case .city:
            for _ in 0..<3 {
                let width = descriptor.size.x * (0.26 + rng.nextFloat() * 0.18)
                let depth = descriptor.size.z * (0.24 + rng.nextFloat() * 0.22)
                let height = descriptor.size.y * (0.62 + rng.nextFloat() * 0.48)
                let block = SCNNode(geometry: SCNBox(
                    width: CGFloat(width),
                    height: CGFloat(height),
                    length: CGFloat(depth),
                    chamferRadius: 0.0
                ))
                block.position = SCNVector3(
                    (rng.nextFloat() - 0.5) * descriptor.size.x * 0.65,
                    height * 0.5,
                    (rng.nextFloat() - 0.5) * descriptor.size.z * 0.45
                )
                block.geometry?.materials = [EnvironmentMaterialRegistry.farCityMaterial]
                root.addChildNode(block)
            }

        case .field, .gridDemo:
            let mound = SCNNode(geometry: SCNBox(
                width: CGFloat(descriptor.size.x),
                height: CGFloat(max(1.2, descriptor.size.y * 0.45)),
                length: CGFloat(descriptor.size.z),
                chamferRadius: CGFloat(descriptor.size.x * 0.08)
            ))
            mound.position = SCNVector3(0, max(1.2, descriptor.size.y * 0.45) * 0.5, 0)
            mound.geometry?.materials = [EnvironmentMaterialRegistry.farFieldMaterial]
            root.addChildNode(mound)
        }

        return root
    }

    private static func descriptorSeed(_ descriptor: EnvironmentObjectDescriptor) -> UInt64 {
        var hasher = Hasher()
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

    private static func makeLowPolyTreeNode(
        variant: Int,
        baseHeight: Float,
        baseWidth: Float,
        barkMaterial: SCNMaterial,
        leafMaterial: SCNMaterial,
        rng: inout DeterministicRNG
    ) -> SCNNode? {
        guard let template = loadLowPolyTreeTemplate(variant: variant) else {
            return nil
        }

        let instance = template.clone()
        instance.name = "tree_lowpoly_variant_\(variant)"
        applyTreeMaterialHints(on: instance, bark: barkMaterial, leaf: leafMaterial)

        let bounds = nodeBounds(instance)
        let rawHeight = max(0.001, bounds.max.y - bounds.min.y)
        let rawWidth = max(0.001, max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z))
        let targetHeight = baseHeight.clamped(to: 4.0...22.0) * (0.88 + rng.nextFloat() * 0.24)
        let targetWidth = baseWidth.clamped(to: 1.2...7.0) * (0.82 + rng.nextFloat() * 0.22)
        let heightScale = targetHeight / rawHeight
        let widthScale = targetWidth / rawWidth
        let uniformScale = ((heightScale * 0.55) + (widthScale * 0.45)).clamped(to: 0.35...3.2)
        instance.scale = SCNVector3(uniformScale, uniformScale, uniformScale)

        let centerX = (bounds.min.x + bounds.max.x) * 0.5
        let centerZ = (bounds.min.z + bounds.max.z) * 0.5
        instance.position = SCNVector3(-centerX * uniformScale, -bounds.min.y * uniformScale, -centerZ * uniformScale)
        return instance
    }

    private static func loadLowPolyTreeTemplate(variant: Int) -> SCNNode? {
        let candidates = lowPolyTreeSlots[variant % lowPolyTreeSlots.count]
        for candidate in candidates {
            if let cached = lowPolyTreeTemplateCache[candidate] {
                return cached
            }
            guard let scene = loadSceneResource(named: candidate) else {
                continue
            }

            let template = SCNNode()
            template.name = "tree_template_\(candidate)"
            for child in scene.rootNode.childNodes {
                template.addChildNode(child.clone())
            }
            lowPolyTreeTemplateCache[candidate] = template
            return template
        }
        return nil
    }

    private static func loadSceneResource(named name: String) -> SCNScene? {
        for sceneName in sceneFileNameCandidates(for: name) {
            if let bundled = SCNScene(named: sceneName) {
                return bundled
            }
        }

        for url in sceneFileURLCandidates(for: name) {
            if let scene = try? SCNScene(url: url, options: nil) {
                return scene
            }
        }
        return nil
    }

    private static func sceneFileNameCandidates(for name: String) -> [String] {
        if URL(fileURLWithPath: name).pathExtension.isEmpty == false {
            return [name]
        }
        return sceneFileExtensions.map { "\(name).\($0)" }
    }

    private static func sceneFileURLCandidates(for name: String) -> [URL] {
        let relativePaths = sceneFileNameCandidates(for: name)
        var urls: [URL] = []
        let resourceRoot = Bundle.main.resourceURL
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        for relative in relativePaths {
            if let resourceRoot {
                urls.append(resourceRoot.appendingPathComponent(relative))
                urls.append(resourceRoot.appendingPathComponent("DroneUAVDemo").appendingPathComponent(relative))
            }
            urls.append(cwd.appendingPathComponent(relative))
            urls.append(cwd.appendingPathComponent("DroneUAVDemo").appendingPathComponent(relative))
        }
        return urls
    }

    private static func nodeBounds(_ node: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let box = node.boundingBox
        return (
            min: SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z)),
            max: SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
        )
    }

    private static func applyTreeMaterialHints(on root: SCNNode, bark: SCNMaterial, leaf: SCNMaterial) {
        let geometryNodes = collectGeometryNodes(root)
        guard !geometryNodes.isEmpty else {
            return
        }

        var barkAssigned = false
        var leafAssigned = false
        for node in geometryNodes {
            let token = (node.name ?? "").lowercased()
            if token.contains("trunk") || token.contains("bark") || token.contains("stem") {
                node.geometry?.materials = [bark]
                barkAssigned = true
            } else if token.contains("leaf") || token.contains("foliage") || token.contains("crown") || token.contains("canopy") {
                node.geometry?.materials = [leaf]
                leafAssigned = true
            }
        }

        if barkAssigned && leafAssigned {
            return
        }

        if !barkAssigned, let first = geometryNodes.first {
            first.geometry?.materials = [bark]
            barkAssigned = true
        }

        if !leafAssigned {
            for node in geometryNodes.dropFirst(barkAssigned ? 1 : 0) {
                node.geometry?.materials = [leaf]
            }
        }
    }

    private static func collectGeometryNodes(_ node: SCNNode) -> [SCNNode] {
        var result: [SCNNode] = []
        if node.geometry != nil {
            result.append(node)
        }
        for child in node.childNodes {
            result.append(contentsOf: collectGeometryNodes(child))
        }
        return result
    }

    private static var lowPolyTreeTemplateCache: [String: SCNNode] = [:]
    private static let lowPolyTreeSlots: [[String]] = [
        [
            "Assets/Trees/Models/tree_lowpoly_01",
            "Assets/Trees/Models/tree_01",
            "Assets/Trees/Models/lowpoly_tree_01"
        ],
        [
            "Assets/Trees/Models/tree_lowpoly_02",
            "Assets/Trees/Models/tree_02",
            "Assets/Trees/Models/lowpoly_tree_02"
        ],
        [
            "Assets/Trees/Models/tree_lowpoly_03",
            "Assets/Trees/Models/tree_03",
            "Assets/Trees/Models/lowpoly_tree_03"
        ]
    ]
    private static let sceneFileExtensions = ["scn", "dae", "usdz", "obj"]

    private static func pickFacadeFamily(for biome: TerrainPreset, random: Float) -> BuildingFacadeFamily {
        let value = random.clamped(to: 0.0...1.0)
        switch biome {
        case .city:
            if value < 0.30 { return .concretePanel }
            if value < 0.52 { return .brick }
            if value < 0.76 { return .plaster }
            return .glassAccent
        case .field:
            if value < 0.46 { return .brick }
            if value < 0.78 { return .plaster }
            return .concretePanel
        case .forest:
            if value < 0.34 { return .brick }
            if value < 0.78 { return .plaster }
            return .concretePanel
        case .gridDemo:
            if value < 0.5 { return .concretePanel }
            return .brick
        }
    }

    private static func pickRoofFamily(random: Float) -> BuildingRoofFamily {
        random < 0.42 ? .tile : .flatMetal
    }
}

enum EnvironmentMaterialRegistry {
    static func groundMaterial(for terrain: TerrainPreset) -> SCNMaterial {
        if let cached = groundMaterialCache[terrain] {
            return cached
        }

        let material: SCNMaterial
        switch terrain {
        case .gridDemo:
            material = terrainMaterial(
                albedo: ["Assets/Terrain/Ground/field_ground_01", "Assets/Terrain/Field/field_ground_01"],
                detail: ["Assets/Terrain/Ground/field_dirt_01", "Assets/Terrain/Field/field_dirt_01"],
                fallback: NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1.0),
                roughness: 0.88,
                metalness: 0.04
            )
        case .field:
            material = terrainMaterial(
                albedo: [
                    "Assets/Terrain/Ground/field_ground_01",
                    "Assets/Terrain/Ground/field_ground_02",
                    "Assets/Terrain/Field/field_ground_01",
                    "Assets/Terrain/Field/field_ground_02"
                ],
                detail: ["Assets/Terrain/Ground/field_dirt_01", "Assets/Terrain/Field/field_dirt_01"],
                fallback: NSColor(calibratedRed: 0.24, green: 0.31, blue: 0.20, alpha: 1.0),
                roughness: 0.94,
                metalness: 0.02
            )
        case .forest:
            material = terrainMaterial(
                albedo: [
                    "Assets/Terrain/Forest/forest_ground_01",
                    "Assets/Terrain/Forest/forest_ground_02"
                ],
                detail: ["Assets/Terrain/Forest/forest_leaf_scatter_01"],
                fallback: NSColor(calibratedRed: 0.17, green: 0.22, blue: 0.14, alpha: 1.0),
                roughness: 0.96,
                metalness: 0.01
            )
        case .city:
            material = terrainMaterial(
                albedo: [
                    "Assets/Terrain/Asphalt/city_ground_asphalt_01",
                    "Assets/Terrain/Asphalt/city_ground_concrete_01",
                    "Assets/Terrain/City/city_ground_asphalt_01",
                    "Assets/Terrain/City/city_ground_concrete_01"
                ],
                detail: [
                    "Assets/Terrain/Asphalt/city_ground_pavement_01",
                    "Assets/Terrain/City/city_ground_pavement_01"
                ],
                fallback: NSColor(calibratedRed: 0.19, green: 0.20, blue: 0.23, alpha: 1.0),
                roughness: 0.78,
                metalness: 0.08
            )
        }

        groundMaterialCache[terrain] = material
        return material
    }

    static func barkMaterial(variant: Int) -> SCNMaterial {
        let normalizedVariant = variant % barkTextureSlots.count
        if let cached = barkMaterialCache[normalizedVariant] {
            return cached
        }

        let material = pbrMaterial(
            textureCandidates: [barkTextureSlots[variant % barkTextureSlots.count]],
            fallbackColor: barkFallbacks[variant % barkFallbacks.count],
            roughness: 0.88,
            metalness: 0.02
        )
        barkMaterialCache[normalizedVariant] = material
        return material
    }

    static func leafMaterial(variant: Int, biome: TerrainPreset) -> SCNMaterial {
        let normalizedVariant = variant % leafTextureSlots.count
        let cacheKey = "\(biome.rawValue)-\(normalizedVariant)"
        if let cached = leafMaterialCache[cacheKey] {
            return cached
        }

        let tone: NSColor
        switch biome {
        case .forest:
            tone = NSColor(calibratedRed: 0.18, green: 0.44, blue: 0.20, alpha: 1.0)
        case .field:
            tone = NSColor(calibratedRed: 0.33, green: 0.52, blue: 0.24, alpha: 1.0)
        case .city:
            tone = NSColor(calibratedRed: 0.24, green: 0.42, blue: 0.22, alpha: 1.0)
        case .gridDemo:
            tone = NSColor(calibratedRed: 0.24, green: 0.52, blue: 0.28, alpha: 1.0)
        }

        let material = pbrMaterial(
            textureCandidates: [leafTextureSlots[normalizedVariant]],
            fallbackColor: tone,
            roughness: 0.84,
            metalness: 0.0
        )
        material.isDoubleSided = true
        material.transparencyMode = SCNTransparencyMode.dualLayer
        leafMaterialCache[cacheKey] = material
        return material
    }

    fileprivate static func buildingFacadeMaterials(
        family: BuildingFacadeFamily,
        variant: Int,
        width: Float,
        depth: Float,
        height: Float,
        seed: UInt64
    ) -> [SCNMaterial] {
        let frontMaterial = facadeMaterial(family: family, variant: variant)
        configureBuildingFacade(frontMaterial, family: family, faceWidth: width, faceHeight: height, seed: seed &+ 0x11)

        let sideMaterial = facadeMaterial(family: family, variant: variant)
        configureBuildingFacade(sideMaterial, family: family, faceWidth: depth, faceHeight: height, seed: seed &+ 0x27)

        let capMaterial = facadeMaterial(family: family, variant: variant)
        capMaterial.multiply.contents = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        capMaterial.roughness.contents = family == .glassAccent ? 0.62 : 0.84
        capMaterial.emission.contents = NSColor.clear

        return [
            frontMaterial,
            sideMaterial,
            frontMaterial.copy() as? SCNMaterial ?? frontMaterial,
            sideMaterial.copy() as? SCNMaterial ?? sideMaterial,
            capMaterial,
            capMaterial.copy() as? SCNMaterial ?? capMaterial
        ]
    }

    fileprivate static func facadeMaterial(family: BuildingFacadeFamily, variant: Int) -> SCNMaterial {
        let slots = facadeTextureSlots[family] ?? facadeTextureSlots[.concretePanel]!
        let fallbacks = facadeFallbacks[family] ?? [NSColor(calibratedWhite: 0.52, alpha: 1.0)]
        let normalizedVariant = variant % slots.count
        let cacheKey = "\(family.cacheKey)-\(normalizedVariant)"
        if let cached = facadeMaterialCache[cacheKey] {
            return cached.copy() as? SCNMaterial ?? cached
        }

        let material = pbrMaterial(
            textureCandidates: [slots[normalizedVariant]],
            fallbackColor: fallbacks[normalizedVariant % fallbacks.count],
            roughness: 0.70,
            metalness: family == .glassAccent ? 0.22 : 0.08
        )
        facadeMaterialCache[cacheKey] = material
        return material.copy() as? SCNMaterial ?? material
    }

    fileprivate static func roofMaterial(family: BuildingRoofFamily, variant: Int) -> SCNMaterial {
        let slots = roofTextureSlots[family] ?? roofTextureSlots[.flatMetal]!
        let fallbacks = roofFallbacks[family] ?? [NSColor(calibratedWhite: 0.34, alpha: 1.0)]
        let normalizedVariant = variant % slots.count
        let cacheKey = "\(family.cacheKey)-\(normalizedVariant)"
        if let cached = roofMaterialCache[cacheKey] {
            return cached
        }

        let material = pbrMaterial(
            textureCandidates: [slots[normalizedVariant]],
            fallbackColor: fallbacks[normalizedVariant % fallbacks.count],
            roughness: family == .flatMetal ? 0.56 : 0.74,
            metalness: family == .flatMetal ? 0.24 : 0.06
        )
        roofMaterialCache[cacheKey] = material
        return material
    }

    static let utilityPoleMaterial = pbrMaterial(
        textureCandidates: [["Assets/Buildings/Facades/facade_concrete_01"]],
        fallbackColor: NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.70, alpha: 1.0),
        roughness: 0.58,
        metalness: 0.18
    )
    static let crateMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Field/field_dirt_01"]],
        fallbackColor: NSColor(calibratedRed: 0.35, green: 0.27, blue: 0.20, alpha: 1.0),
        roughness: 0.79,
        metalness: 0.02
    )
    static let rockMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Forest/forest_ground_02"]],
        fallbackColor: NSColor(calibratedRed: 0.38, green: 0.39, blue: 0.40, alpha: 1.0),
        roughness: 0.92,
        metalness: 0.0
    )
    static let markerMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/City/city_ground_pavement_01"]],
        fallbackColor: NSColor.systemOrange,
        roughness: 0.56,
        metalness: 0.04
    )
    static let farForestMaterial = pbrMaterial(
        textureCandidates: [[
            "Assets/Trees/Leaves/leaves_01_oak/leaves_albedo",
            "Assets/Trees/Leaves/leaf_forest_02"
        ]],
        fallbackColor: NSColor(calibratedRed: 0.14, green: 0.25, blue: 0.16, alpha: 1.0),
        roughness: 0.95,
        metalness: 0.0
    )
    static let farCityMaterial = pbrMaterial(
        textureCandidates: [["Assets/Buildings/Facades/facade_concrete_02"]],
        fallbackColor: NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.27, alpha: 0.96),
        roughness: 0.82,
        metalness: 0.06
    )
    static let farFieldMaterial = pbrMaterial(
        textureCandidates: [["Assets/Terrain/Field/field_ground_02"]],
        fallbackColor: NSColor(calibratedRed: 0.20, green: 0.28, blue: 0.18, alpha: 0.95),
        roughness: 0.90,
        metalness: 0.0
    )

    private static let barkTextureSlots: [[String]] = [
        [
            "Assets/Trees/Bark/bark_01_birch/bark_albedo",
            "Assets/Trees/Bark/bark_01",
            "bark_01"
        ],
        [
            "Assets/Trees/Bark/bark_02_pine/bark_albedo",
            "Assets/Trees/Bark/bark_02",
            "bark_02"
        ],
        [
            "Assets/Trees/Bark/bark_03_green_pine/bark_albedo",
            "Assets/Trees/Bark/bark_03",
            "bark_03"
        ]
    ]
    private static let barkFallbacks: [NSColor] = [
        NSColor(calibratedRed: 0.42, green: 0.30, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.36, green: 0.28, blue: 0.20, alpha: 1.0),
        NSColor(calibratedRed: 0.48, green: 0.36, blue: 0.24, alpha: 1.0)
    ]

    private static let leafTextureSlots: [[String]] = [
        [
            "Assets/Trees/Leaves/leaves_01_oak/leaves_albedo",
            "Assets/Trees/Leaves/leaf_01",
            "leaf_01",
            "leaf_forest_01"
        ],
        [
            "Assets/Trees/Leaves/leaves_02_rowan/leaves_albedo",
            "Assets/Trees/Leaves/leaf_02",
            "leaf_02",
            "leaf_forest_02"
        ],
        [
            "Assets/Trees/Leaves/leaves_03_elm/leaves_albedo",
            "Assets/Trees/Leaves/leaf_03",
            "leaf_03",
            "leaf_field_01"
        ]
    ]

    private static let facadeTextureSlots: [BuildingFacadeFamily: [[String]]] = [
        .brick: [
            ["Assets/Buildings/Facades/facade_brick_01", "facade_brick_01"],
            ["Assets/Buildings/Facades/facade_brick_02", "facade_brick_02"],
            ["Assets/Buildings/Facades/facade_brick_03", "facade_brick_03"],
            ["Assets/Buildings/Facades/facade_brick_04", "facade_brick_04"]
        ],
        .plaster: [
            ["Assets/Buildings/Facades/facade_plaster_01", "facade_plaster_01"],
            ["Assets/Buildings/Facades/facade_plaster_02", "facade_plaster_02"],
            ["Assets/Buildings/Facades/facade_plaster_03", "facade_plaster_03"],
            ["Assets/Buildings/Facades/facade_plaster_04", "facade_plaster_04"]
        ],
        .concretePanel: [
            ["Assets/Buildings/Facades/facade_concrete_01", "facade_concrete_01"],
            ["Assets/Buildings/Facades/facade_concrete_02", "facade_concrete_02"],
            ["Assets/Buildings/Facades/facade_concrete_03", "facade_concrete_03"],
            ["Assets/Buildings/Facades/facade_concrete_04", "facade_concrete_04"]
        ],
        .glassAccent: [
            ["Assets/Buildings/Facades/facade_glass_01", "facade_glass_01"],
            ["Assets/Buildings/Facades/facade_glass_02", "facade_glass_02"],
            ["Assets/Buildings/Facades/facade_glass_03", "facade_glass_03"],
            ["Assets/Buildings/Facades/facade_glass_04", "facade_glass_04"]
        ]
    ]

    private static let facadeFallbacks: [BuildingFacadeFamily: [NSColor]] = [
        .brick: [
            NSColor(calibratedRed: 0.52, green: 0.32, blue: 0.28, alpha: 1.0),
            NSColor(calibratedRed: 0.58, green: 0.36, blue: 0.31, alpha: 1.0)
        ],
        .plaster: [
            NSColor(calibratedRed: 0.72, green: 0.70, blue: 0.64, alpha: 1.0),
            NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.62, alpha: 1.0)
        ],
        .concretePanel: [
            NSColor(calibratedRed: 0.52, green: 0.55, blue: 0.58, alpha: 1.0),
            NSColor(calibratedRed: 0.46, green: 0.50, blue: 0.54, alpha: 1.0)
        ],
        .glassAccent: [
            NSColor(calibratedRed: 0.40, green: 0.47, blue: 0.56, alpha: 1.0),
            NSColor(calibratedRed: 0.34, green: 0.42, blue: 0.52, alpha: 1.0)
        ]
    ]

    private static let roofTextureSlots: [BuildingRoofFamily: [[String]]] = [
        .tile: [
            ["Assets/Buildings/Roofs/roof_tile_01", "roof_tile_01"],
            ["Assets/Buildings/Roofs/roof_tile_02", "roof_tile_02"],
            ["Assets/Buildings/Roofs/roof_tile_03", "roof_tile_03"]
        ],
        .flatMetal: [
            ["Assets/Buildings/Roofs/roof_metal_01", "roof_metal_01"],
            ["Assets/Buildings/Roofs/roof_metal_02", "roof_metal_02"],
            ["Assets/Buildings/Roofs/roof_metal_03", "roof_metal_03"]
        ]
    ]

    private static let roofFallbacks: [BuildingRoofFamily: [NSColor]] = [
        .tile: [
            NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.20, alpha: 1.0),
            NSColor(calibratedRed: 0.48, green: 0.29, blue: 0.22, alpha: 1.0)
        ],
        .flatMetal: [
            NSColor(calibratedRed: 0.28, green: 0.30, blue: 0.33, alpha: 1.0),
            NSColor(calibratedRed: 0.34, green: 0.36, blue: 0.38, alpha: 1.0)
        ]
    ]

    private static func terrainMaterial(
        albedo: [String],
        detail: [String],
        fallback: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        let material = pbrMaterial(
            textureCandidates: [albedo + detail],
            fallbackColor: fallback,
            roughness: roughness,
            metalness: metalness
        )
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(24.0, 24.0, 1.0)
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        return material
    }

    private static func pbrMaterial(
        textureCandidates: [[String]],
        fallbackColor: NSColor,
        roughness: CGFloat,
        metalness: CGFloat
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = resolveTexture(textureCandidates) ?? fallbackColor
        material.roughness.contents = roughness
        material.metalness.contents = metalness
        return material
    }

    private static func configureBuildingFacade(
        _ material: SCNMaterial,
        family: BuildingFacadeFamily,
        faceWidth: Float,
        faceHeight: Float,
        seed: UInt64
    ) {
        let tileX = CGFloat(max(1.0, faceWidth / 6.0))
        let tileY = CGFloat(max(1.0, faceHeight / 7.5))
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.diffuse.contentsTransform = SCNMatrix4MakeScale(tileX, tileY, 1.0)
        material.emission.contents = facadeWindowOverlay(
            family: family,
            faceWidth: faceWidth,
            faceHeight: faceHeight,
            seed: seed
        )
        material.emission.intensity = family == .glassAccent ? 0.52 : 0.72
    }

    private static func facadeWindowOverlay(
        family: BuildingFacadeFamily,
        faceWidth: Float,
        faceHeight: Float,
        seed: UInt64
    ) -> NSImage {
        let columns: Int
        let rows: Int
        switch family {
        case .glassAccent:
            columns = max(3, min(10, Int((faceWidth / 2.8).rounded())))
            rows = max(4, min(18, Int((faceHeight / 2.3).rounded())))
        case .brick, .plaster, .concretePanel:
            columns = max(3, min(9, Int((faceWidth / 3.2).rounded())))
            rows = max(4, min(16, Int((faceHeight / 2.9).rounded())))
        }

        let cacheKey = "\(family.cacheKey)-\(columns)x\(rows)-\(seed & 0xF)"
        if let cached = facadeWindowOverlayCache[cacheKey] {
            return cached
        }

        let canvasSize = NSSize(width: 512, height: 512)
        let image = NSImage(size: canvasSize)
        image.lockFocus()

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: canvasSize)).fill()

        let marginX = canvasSize.width * 0.08
        let marginY = canvasSize.height * 0.07
        let spacingX = family == .glassAccent ? canvasSize.width * 0.014 : canvasSize.width * 0.022
        let spacingY = family == .glassAccent ? canvasSize.height * 0.013 : canvasSize.height * 0.020
        let availableWidth = canvasSize.width - marginX * 2.0 - spacingX * CGFloat(max(columns - 1, 0))
        let availableHeight = canvasSize.height - marginY * 2.0 - spacingY * CGFloat(max(rows - 1, 0))
        let windowWidth = max(16.0, availableWidth / CGFloat(max(columns, 1)))
        let windowHeight = max(14.0, availableHeight / CGFloat(max(rows, 1)))
        let cornerRadius = min(windowWidth, windowHeight) * (family == .glassAccent ? 0.16 : 0.10)

        let dimColor = family == .glassAccent
            ? NSColor(calibratedRed: 0.38, green: 0.52, blue: 0.66, alpha: 0.22)
            : NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.42, alpha: 0.15)
        let litPalette: [NSColor] = family == .glassAccent
            ? [
                NSColor(calibratedRed: 0.78, green: 0.90, blue: 1.0, alpha: 0.78),
                NSColor(calibratedRed: 0.60, green: 0.80, blue: 1.0, alpha: 0.68)
            ]
            : [
                NSColor(calibratedRed: 0.98, green: 0.90, blue: 0.66, alpha: 0.72),
                NSColor(calibratedRed: 0.72, green: 0.84, blue: 1.0, alpha: 0.62)
            ]
        var rng = DeterministicRNG(seed: seed &+ UInt64(columns * 31 + rows * 17))

        for row in 0..<rows {
            if family != .glassAccent {
                let bandY = marginY + CGFloat(row) * (windowHeight + spacingY) - spacingY * 0.45
                let bandRect = NSRect(x: marginX * 0.75, y: bandY, width: canvasSize.width - marginX * 1.5, height: max(2.0, spacingY * 0.32))
                NSColor(calibratedWhite: 1.0, alpha: 0.045).setFill()
                NSBezierPath(roundedRect: bandRect, xRadius: 1.6, yRadius: 1.6).fill()
            }

            for column in 0..<columns {
                let originX = marginX + CGFloat(column) * (windowWidth + spacingX)
                let originY = marginY + CGFloat(row) * (windowHeight + spacingY)
                let rect = NSRect(x: originX, y: originY, width: windowWidth, height: windowHeight)
                let isLit = rng.nextFloat() < (family == .glassAccent ? 0.78 : 0.58)
                let fillColor = isLit ? litPalette[Int(rng.next() % UInt64(litPalette.count))] : dimColor
                fillColor.setFill()
                NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            }
        }

        image.unlockFocus()
        facadeWindowOverlayCache[cacheKey] = image
        return image
    }

    private static func resolveTexture(_ candidates: [[String]]) -> NSImage? {
        for entry in candidates {
            for name in entry {
                if let image = image(named: name) {
                    return image
                }
            }
        }
        return nil
    }

    private static func image(named name: String) -> NSImage? {
        if let cached = textureImageCache[name] {
            return cached
        }
        if missingTextureNames.contains(name) {
            return nil
        }

        if let direct = NSImage(named: NSImage.Name(name)) {
            textureImageCache[name] = direct
            return direct
        }
        if let shortName = name.split(separator: "/").last {
            if let short = NSImage(named: NSImage.Name(String(shortName))) {
                textureImageCache[name] = short
                return short
            }
        }
        for url in candidateTextureFileURLs(for: name) {
            if let fileImage = NSImage(contentsOf: url) {
                textureImageCache[name] = fileImage
                return fileImage
            }
        }
        missingTextureNames.insert(name)
        return nil
    }

    private static func candidateTextureFileURLs(for name: String) -> [URL] {
        let hasExtension = URL(fileURLWithPath: name).pathExtension.isEmpty == false
        let nameCandidates: [String]
        if hasExtension {
            nameCandidates = [name]
        } else {
            nameCandidates = textureFileExtensions.map { "\(name).\($0)" }
        }

        let resourceRoot = Bundle.main.resourceURL
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var urls: [URL] = []
        urls.reserveCapacity(nameCandidates.count * 5)

        for relative in nameCandidates {
            if let resourceRoot {
                urls.append(resourceRoot.appendingPathComponent(relative))
                urls.append(resourceRoot.appendingPathComponent("DroneUAVDemo").appendingPathComponent(relative))
            }
            urls.append(cwd.appendingPathComponent(relative))
            urls.append(cwd.appendingPathComponent("DroneUAVDemo").appendingPathComponent(relative))
        }

        return urls
    }

    private static let textureFileExtensions = ["png", "jpg", "jpeg"]
    private static var facadeWindowOverlayCache: [String: NSImage] = [:]
    private static var textureImageCache: [String: NSImage] = [:]
    private static var missingTextureNames: Set<String> = []
    private static var groundMaterialCache: [TerrainPreset: SCNMaterial] = [:]
    private static var barkMaterialCache: [Int: SCNMaterial] = [:]
    private static var leafMaterialCache: [String: SCNMaterial] = [:]
    private static var facadeMaterialCache: [String: SCNMaterial] = [:]
    private static var roofMaterialCache: [String: SCNMaterial] = [:]
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
}

fileprivate enum BuildingFacadeFamily {
    case brick
    case plaster
    case concretePanel
    case glassAccent

    var cacheKey: String {
        switch self {
        case .brick:
            return "brick"
        case .plaster:
            return "plaster"
        case .concretePanel:
            return "concrete"
        case .glassAccent:
            return "glass"
        }
    }
}

fileprivate enum BuildingRoofFamily {
    case tile
    case flatMetal

    var cacheKey: String {
        switch self {
        case .tile:
            return "tile"
        case .flatMetal:
            return "flat-metal"
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
