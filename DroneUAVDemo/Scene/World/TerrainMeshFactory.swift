import SceneKit
import simd

/// Builds a visible surface from the same triangles the physics uses.
///
/// Sharing the corner list with the collision index is deliberate. Terrain assembled separately for
/// the eye and for the flight model is terrain that will eventually disagree with itself, and a
/// disagreement of even a metre reads to the pilot as landing on nothing or colliding with air.
enum TerrainMeshFactory {

    /// Millimetre-quantised identity for vertices duplicated by the non-indexed triangle list.
    /// Positions generated from the same grid point are exact in practice; quantisation also joins
    /// the harmless last-bit differences introduced by midpoint arithmetic.
    private struct VertexKey: Hashable {
        let x: Int
        let y: Int
        let z: Int

        init(_ point: SIMD3<Float>) {
            x = Int((point.x * 1_000).rounded())
            y = Int((point.y * 1_000).rounded())
            z = Int((point.z * 1_000).rounded())
        }
    }

    /// Flat-shaded variant for architectural geometry — bridge towers, piers, cables.
    ///
    /// `makeNode`'s vertex welding + normal averaging is exactly right for terrain and exactly
    /// wrong for boxes: a box corner shared by three perpendicular faces receives one diagonal
    /// averaged normal, and the whole face shades with a soft rounded gradient that reads as a
    /// strange shadow smeared across flat masonry. Per-face normals keep every face crisp.
    @MainActor
    static func makeFlatNode(corners: [SIMD3<Float>]) -> SCNNode? {
        guard corners.count >= 3, corners.count % 3 == 0 else { return nil }
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(corners.count)
        normals.reserveCapacity(corners.count)
        for index in stride(from: 0, to: corners.count, by: 3) {
            let cross = simd_cross(
                corners[index + 1] - corners[index],
                corners[index + 2] - corners[index]
            )
            let areaSquared = simd_length_squared(cross)
            guard areaSquared.isFinite, areaSquared > 0.000_000_01 else { continue }
            let face = simd_normalize(cross)
            for vertex in corners[index...(index + 2)] {
                positions.append(vertex)
                normals.append(face)
            }
        }
        guard !positions.isEmpty else { return nil }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
            ],
            elements: [
                SCNGeometryElement(
                    indices: Array(0..<Int32(positions.count)),
                    primitiveType: .triangles
                )
            ]
        )

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.26, alpha: 1)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "world.structure.surface"
        node.castsShadow = false
        return node
    }

    @MainActor
    static func makeNode(corners: [SIMD3<Float>], textureTileMeters: Float? = nil) -> SCNNode? {
        guard corners.count >= 3, corners.count % 3 == 0 else { return nil }

        // Boundary clipping intentionally creates an occasional zero-area triangle where an outer
        // sample clamps onto the world edge. Passing its NaN normal to SceneKit can corrupt a much
        // larger primitive on some GPUs, so discard it before building either positions or normals.
        //
        // Build an indexed mesh at the same time. Adjacent terrain pieces arrive as a non-indexed
        // triangle list, but a duplicated common edge is not guaranteed to rasterise without a
        // hairline crack on every GPU. One index for each millimetre-quantised position makes the
        // shared edge genuinely shared and also cuts the memory cost of the conforming shoreline.
        var vertices: [SIMD3<Float>] = []
        var indices: [Int32] = []
        var indexByVertex: [VertexKey: Int32] = [:]
        var normalSums: [SIMD3<Float>] = []
        vertices.reserveCapacity(corners.count / 2)
        indices.reserveCapacity(corners.count)
        normalSums.reserveCapacity(corners.count / 2)

        for index in stride(from: 0, to: corners.count, by: 3) {
            let cross = simd_cross(
                corners[index + 1] - corners[index],
                corners[index + 2] - corners[index]
            )
            let areaSquared = simd_length_squared(cross)
            guard areaSquared.isFinite, areaSquared > 0.000_000_01 else { continue }
            let face = simd_normalize(cross)
            for vertex in corners[index...(index + 2)] {
                let key = VertexKey(vertex)
                let vertexIndex: Int32
                if let existing = indexByVertex[key] {
                    vertexIndex = existing
                } else {
                    vertexIndex = Int32(vertices.count)
                    indexByVertex[key] = vertexIndex
                    vertices.append(vertex)
                    normalSums.append(SIMD3<Float>(repeating: 0))
                }
                indices.append(vertexIndex)
                normalSums[Int(vertexIndex)] += face
            }

        }
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }

        // Average face normals at each shared vertex. The old per-triangle normals turned a
        // two-metre-high, nearly flat waterfront into a patchwork of visibly different triangles;
        // this keeps the measured relief while removing facets caused only by tessellation.
        let normals = normalSums.map { sum -> SCNVector3 in
            let lengthSquared = simd_length_squared(sum)
            let normal = lengthSquared > 0.000_000_01
                ? simd_normalize(sum)
                : SIMD3<Float>(0, 1, 0)
            return SCNVector3(normal.x, normal.y, normal.z)
        }

        var sources = [SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }), SCNGeometrySource(normals: normals)]
        if let tile = textureTileMeters, tile > 0 {
            sources.append(SCNGeometrySource(textureCoordinates: vertices.map { CGPoint(x: CGFloat($0.x / tile), y: CGFloat($0.z / tile)) }))
        }
        let geometry = SCNGeometry(
            sources: sources,
            elements: [
                SCNGeometryElement(
                    indices: indices,
                    primitiveType: .triangles
                )
            ]
        )

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.26, alpha: 1)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "world.terrain.surface"
        node.castsShadow = false
        return node
    }

    @MainActor static func makeReliefNode(configuration: TerrainConfiguration, snow: Bool = false) -> SCNNode? {
        let vertices = configuration.reliefVertices
        guard !vertices.isEmpty else { return nil }
        let n = configuration.reliefResolution, side = n + 1
        let normals = reliefNormals(vertices: vertices, side: side)
        var indices: [Int32] = []; indices.reserveCapacity(n * n * 6)
        for z in 0..<n { for x in 0..<n {
            let a = Int32(z * side + x), b = a + 1, c = a + Int32(side), d = c + 1
            indices.append(contentsOf: [a, c, b, b, c, d])
        }}
        let geometry = SCNGeometry(sources: [
            SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) }),
            SCNGeometrySource(textureCoordinates: vertices.map { CGPoint(x: CGFloat($0.x / 8), y: CGFloat($0.z / 8)) })
        ], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [makeReliefMaterial(configuration: configuration, snow: snow, vertices: vertices)]
        let node = SCNNode(geometry: geometry)
        node.name = "world.procedural.relief"
        return node
    }

    private static func reliefNormals(vertices: [SIMD3<Float>], side: Int) -> [SIMD3<Float>] {
        vertices.indices.map { i in
            let x = i % side, z = i / side
            let left = vertices[z * side + max(0, x - 1)], right = vertices[z * side + min(side - 1, x + 1)]
            let back = vertices[max(0, z - 1) * side + x], front = vertices[min(side - 1, z + 1) * side + x]
            return simd_normalize(SIMD3(-(right.y - left.y) / max(0.001, right.x - left.x), 1,
                                       -(front.y - back.y) / max(0.001, front.z - back.z)))
        }
    }

    private static var cachedReliefMask: (key: String, property: SCNMaterialProperty)?
    /// Blur material coverage in world space, independent of how the mesh's quads are split.
    /// Bilinear sampling of this field prevents grass/soil boundaries from tracing triangle edges.
    @MainActor static func reliefMaterialMask(configuration: TerrainConfiguration, vertices: [SIMD3<Float>]? = nil) -> SCNMaterialProperty {
        let key = "\(configuration.preset.rawValue)-\(configuration.seed)-\(configuration.mapScale.rawValue)-\(configuration.reliefAmplitude)-\(configuration.safeSpawnRadius)-\(configuration.reliefResolution)"
        if let cachedReliefMask, cachedReliefMask.key == key { return cachedReliefMask.property }
        let vertices = vertices ?? configuration.reliefVertices
        let side = configuration.reliefResolution + 1
        let normals = reliefNormals(vertices: vertices, side: side)
        func smooth(_ low: Float, _ high: Float, _ value: Float) -> Float {
            let t = min(1, max(0, (value - low) / (high - low))); return t * t * (3 - 2 * t)
        }
        var weights = vertices.indices.map { i -> SIMD2<Float> in
            let slope = 1 - normals[i].y
            let altitude = vertices[i].y / max(10, configuration.reliefAmplitude)
            return SIMD2(min(1, smooth(0.025, 0.40, slope) * 0.70 + (1 - smooth(0.02, 0.25, altitude)) * 0.28),
                         smooth(0.18, 0.60, slope))
        }
        let kernel: [Float] = [1, 4, 6, 4, 1]
        for horizontal in [true, false] {
            let source = weights
            for z in 0..<side { for x in 0..<side {
                var sum = SIMD2<Float>(repeating: 0)
                for tap in -2...2 {
                    let sx = horizontal ? min(side - 1, max(0, x + tap)) : x
                    let sz = horizontal ? z : min(side - 1, max(0, z + tap))
                    sum += source[sz * side + sx] * kernel[tap + 2]
                }
                weights[z * side + x] = sum / 16
            }}
        }
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for i in weights.indices {
            pixels[i * 4] = UInt8((weights[i].x * 255).rounded())
            pixels[i * 4 + 1] = UInt8((weights[i].y * 255).rounded())
            pixels[i * 4 + 2] = 0
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let property = SCNMaterialProperty(contents: image)
        property.wrapS = .clamp; property.wrapT = .clamp
        property.minificationFilter = .linear; property.magnificationFilter = .linear; property.mipFilter = .linear
        cachedReliefMask = (key, property)
        return property
    }

    @MainActor static func makeReliefMaterial(configuration: TerrainConfiguration, snow: Bool, vertices: [SIMD3<Float>]? = nil) -> SCNMaterial {
        let grass = snow ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: 8) : GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: 8)
        let stone = AbandonedCityMaterialLoader.makeBrittleStoneMaterial(mapSizeMeters: 8)
        let dirt = reliefDirtMaterial()
        let material = SCNMaterial(); material.lightingModel = .lambert
        material.roughness.contents = 0.96
        func texture(_ contents: Any?) -> SCNMaterialProperty {
            let property: SCNMaterialProperty
            if let color = contents as? NSColor {
                let image = NSImage(size: NSSize(width: 2, height: 2))
                image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
                property = SCNMaterialProperty(contents: image)
            } else {
                property = SCNMaterialProperty(contents: contents ?? NSImage())
            }
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.minificationFilter = .linear
            property.magnificationFilter = .linear
            property.mipFilter = .linear
            property.maxAnisotropy = 8
            return property
        }
        material.setValue(texture(grass.diffuse.contents), forKey: "reliefGrass")
        material.setValue(texture(dirt.diffuse.contents), forKey: "reliefDirt")
        material.setValue(texture(stone.diffuse.contents), forKey: "reliefStone")
        material.setValue(reliefMaterialMask(configuration: configuration, vertices: vertices), forKey: "reliefMask")
        material.setValue(NSNumber(value: configuration.beltOuterRadius + 24), forKey: "reliefExtent")
        material.shaderModifiers = [.geometry: reliefGeometryShader, .surface: reliefSurfaceShader]
        return material
    }

    private static let reliefGeometryShader = """
    #pragma varyings
    float3 reliefPosition;
    float3 reliefNormal;
    float2 reliefUV;
    #pragma body
    out.reliefPosition = _geometry.position.xyz;
    out.reliefNormal = _geometry.normal;
    out.reliefUV = _geometry.texcoords[0];
    """
    private static let reliefSurfaceShader = """
    #pragma arguments
    texture2d<float> reliefGrass;
    texture2d<float> reliefDirt;
    texture2d<float> reliefStone;
    texture2d<float> reliefMask;
    float reliefExtent;
    #pragma body
    constexpr sampler terrainSampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 coverage = reliefMask.sample(maskSampler, (in.reliefPosition.xz + reliefExtent) / (2.0 * reliefExtent)).rg;
    float dirtWeight = coverage.r;
    float rockWeight = coverage.g;
    float3 projectionWeights = pow(abs(normalize(in.reliefNormal)), float3(4.0));
    projectionWeights /= max(0.0001, projectionWeights.x + projectionWeights.y + projectionWeights.z);
    float3 p = in.reliefPosition / 8.0;
    float3 grass = reliefGrass.sample(terrainSampler, p.zy).rgb * projectionWeights.x
        + reliefGrass.sample(terrainSampler, p.xz).rgb * projectionWeights.y
        + reliefGrass.sample(terrainSampler, p.xy).rgb * projectionWeights.z;
    float3 dirt = reliefDirt.sample(terrainSampler, p.zy).rgb * projectionWeights.x
        + reliefDirt.sample(terrainSampler, p.xz).rgb * projectionWeights.y
        + reliefDirt.sample(terrainSampler, p.xy).rgb * projectionWeights.z;
    float3 rock = reliefStone.sample(terrainSampler, p.zy).rgb * projectionWeights.x
        + reliefStone.sample(terrainSampler, p.xz).rgb * projectionWeights.y
        + reliefStone.sample(terrainSampler, p.xy).rgb * projectionWeights.z;
    float3 colour = mix(mix(grass, dirt, clamp(dirtWeight, 0.0, 1.0)), rock, rockWeight);
    _surface.diffuse = float4(colour, 1.0);
    """

    private static var cachedDirtMaterial: SCNMaterial?
    @MainActor private static func reliefDirtMaterial() -> SCNMaterial {
        if let cachedDirtMaterial { return cachedDirtMaterial }
        let material = SCNMaterial(); material.lightingModel = .lambert
        material.diffuse.contents = NSColor(calibratedRed: 0.36, green: 0.29, blue: 0.20, alpha: 1)
        if let url = Bundle.main.url(forResource: "Dirt_2", withExtension: "usdz"), let scene = try? SCNScene(url: url) {
            scene.rootNode.enumerateChildNodes { node, stop in
                guard let source = node.geometry?.firstMaterial, let albedo = source.diffuse.contents else { return }
                material.diffuse.contents = albedo; stop.pointee = true
            }
        }
        material.diffuse.wrapS = .repeat; material.diffuse.wrapT = .repeat
        material.diffuse.maxAnisotropy = 8; material.roughness.contents = 0.98
        cachedDirtMaterial = material
        return material
    }
}
