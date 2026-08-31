import SceneKit

private enum WheatConstants {
    static let resourceName = "Wheat"
    static let resourceExtension = "usdz"
    static let templateNodeName = "agri.wheat_template"
    static let chunkNodeName = "agri.wheat_chunk"
    static let defaultHeightMeters: Float = 0.95
}

/// Loads `Wheat.usdz` and builds the crop cover of the agricultural spraying mission.
///
/// The asset is a crossed-billboard clump (four quads, 16 vertices, one alpha-masked texture),
/// which is what makes a *dense* field affordable at all: a hundred clumps cost about as much
/// geometry as a single tree. The expensive part of density is not vertices but draw calls, so
/// clumps are never added to the scene individually — `makeFieldChunk` merges a whole tile of
/// them into one flattened node (one geometry, one material, one draw call per tile).
///
/// Alpha is handled by an explicit cutout in the fragment shader rather than blending. Blended
/// vegetation has to be depth-sorted to look right, and thousands of mutually overlapping
/// billboards cannot be sorted correctly at any price; discarding transparent fragments keeps
/// the depth buffer honest and the field readable from every angle.
final class WheatFieldAssetLoader {
    static let shared = WheatFieldAssetLoader()

    /// One clump: position (metres, chunk-local), heading, and height.
    struct ClumpPlacement {
        var position: SIMD3<Float>
        var yaw: Float
        var heightMeters: Float

        init(position: SIMD3<Float>, yaw: Float, heightMeters: Float = WheatConstants.defaultHeightMeters) {
            self.position = position
            self.yaw = yaw
            self.heightMeters = heightMeters
        }
    }

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var modelNativeMinY: Float = 0.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    /// A single clump, origin at its base so callers place it straight onto the ground.
    func makeClumpNode(
        targetHeightMeters: Float = WheatConstants.defaultHeightMeters,
        yaw: Float = 0.0
    ) -> SCNNode? {
        guard let template = loadTemplate() else {
            warnOnce()
            return nil
        }
        let height = max(0.1, targetHeightMeters)
        let scale = height / max(modelNativeHeight, 0.001)
        let model = template.clone()
        model.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(0, -modelNativeMinY * scale, 0)

        let wrapper = SCNNode()
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)
        wrapper.addChildNode(model)
        return wrapper
    }

    /// Merges `clumps` into a single geometry: one node, one draw call, however many clumps.
    /// Returns nil when the asset is unavailable, so the caller can fall back to a plain textured
    /// ground without a crop layer.
    ///
    /// The merge is done by hand rather than with `SCNNode.flattenedClone()`. That API returned an
    /// empty geometry for this content when measured (zero vertices, zero elements, zero-size
    /// bounding box), which would have left the field bare with nothing in the logs to say why;
    /// the one other place in this project that considered flattening also decided against it. The
    /// crop mesh is tiny and uniform — sixteen vertices, eight triangles, one material — so
    /// building the combined buffers directly is both short and exact.
    func makeFieldChunk(clumps: [ClumpPlacement]) -> SCNNode? {
        guard !clumps.isEmpty, let prototype = loadPrototype() else {
            warnOnce()
            return nil
        }

        // Written straight into packed float buffers rather than into arrays of `SCNVector3`.
        // A dense field is a hundred thousand clumps a mission, and on macOS an `SCNVector3` is
        // three `CGFloat`s — going through them would double the memory touched and add a
        // conversion per component for no gain, since SceneKit only wants tightly packed floats
        // in the end anyway.
        let vertexCount = prototype.positions.count
        let totalVertices = vertexCount * clumps.count
        var positions = [Float](repeating: 0, count: totalVertices * 3)
        var normals = [Float](repeating: 0, count: totalVertices * 3)
        var texcoords = [Float](repeating: 0, count: totalVertices * 2)
        var indices = [UInt32](repeating: 0, count: prototype.indices.count * clumps.count)

        var vertexCursor = 0
        var indexCursor = 0
        for clump in clumps {
            let base = UInt32(vertexCursor)
            let height = max(0.05, clump.heightMeters)
            let cosYaw = cos(clump.yaw)
            let sinYaw = sin(clump.yaw)

            for index in 0..<vertexCount {
                let p = prototype.positions[index] * height
                let x = p.x * cosYaw + p.z * sinYaw + clump.position.x
                let y = p.y + clump.position.y
                let z = -p.x * sinYaw + p.z * cosYaw + clump.position.z
                let base3 = (vertexCursor + index) * 3
                positions[base3] = x
                positions[base3 + 1] = y
                positions[base3 + 2] = z

                // Uniform scale, so the normal only needs the same rotation.
                let n = prototype.normals[index]
                normals[base3] = n.x * cosYaw + n.z * sinYaw
                normals[base3 + 1] = n.y
                normals[base3 + 2] = -n.x * sinYaw + n.z * cosYaw

                let uv = prototype.texcoords[index]
                let base2 = (vertexCursor + index) * 2
                texcoords[base2] = uv.x
                texcoords[base2 + 1] = uv.y
            }
            for value in prototype.indices {
                indices[indexCursor] = base + value
                indexCursor += 1
            }
            vertexCursor += vertexCount
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(
                    data: Data(bytes: positions, count: positions.count * MemoryLayout<Float>.size),
                    semantic: .vertex,
                    vectorCount: totalVertices,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * 3
                ),
                SCNGeometrySource(
                    data: Data(bytes: normals, count: normals.count * MemoryLayout<Float>.size),
                    semantic: .normal,
                    vectorCount: totalVertices,
                    usesFloatComponents: true,
                    componentsPerVector: 3,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * 3
                ),
                SCNGeometrySource(
                    data: Data(bytes: texcoords, count: texcoords.count * MemoryLayout<Float>.size),
                    semantic: .texcoord,
                    vectorCount: totalVertices,
                    usesFloatComponents: true,
                    componentsPerVector: 2,
                    bytesPerComponent: MemoryLayout<Float>.size,
                    dataOffset: 0,
                    dataStride: MemoryLayout<Float>.size * 2
                )
            ],
            elements: [
                SCNGeometryElement(
                    data: Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size),
                    primitiveType: .triangles,
                    primitiveCount: indices.count / 3,
                    bytesPerIndex: MemoryLayout<UInt32>.size
                )
            ]
        )
        geometry.materials = [prototype.material]

        let node = SCNNode(geometry: geometry)
        node.name = WheatConstants.chunkNodeName
        // Crop cover is a receiver, not a caster: thousands of alpha-cutout shadow casters cost
        // an entire extra depth pass over the whole field for shadows nobody reads from the air.
        node.castsShadow = false
        return node
    }

    // MARK: Merge prototype

    /// One clump's mesh, baked into plain arrays and normalised to unit height with its base at
    /// the origin, so a placement is nothing but scale-rotate-translate.
    private struct ClumpPrototype {
        var positions: [SIMD3<Float>]
        var normals: [SIMD3<Float>]
        var texcoords: [SIMD2<Float>]
        var indices: [UInt32]
        var material: SCNMaterial
    }

    private var cachedPrototype: ClumpPrototype?

    private func loadPrototype() -> ClumpPrototype? {
        if let cachedPrototype {
            return cachedPrototype
        }
        guard let template = loadTemplate() else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        var material: SCNMaterial?

        template.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let vertexSource = geometry.sources(for: .vertex).first,
                  let element = geometry.elements.first,
                  element.primitiveType == .triangles else {
                return
            }
            let transform = simd_float4x4(node.convertTransform(SCNMatrix4Identity, to: template))
            let normalMatrix = simd_float3x3(
                SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            )

            let localPositions = Self.readFloat3(vertexSource)
            let localNormals = geometry.sources(for: .normal).first.map(Self.readFloat3)
                ?? [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: localPositions.count)
            let localTexcoords = geometry.sources(for: .texcoord).first.map(Self.readFloat2)
                ?? [SIMD2<Float>](repeating: .zero, count: localPositions.count)

            let base = UInt32(positions.count)
            for index in 0..<localPositions.count {
                let p = transform * SIMD4<Float>(localPositions[index], 1.0)
                positions.append(SIMD3<Float>(p.x, p.y, p.z))
                let n = normalMatrix * (index < localNormals.count ? localNormals[index] : SIMD3<Float>(0, 1, 0))
                let length = simd_length(n)
                normals.append(length > 0.0001 ? n / length : SIMD3<Float>(0, 1, 0))
                texcoords.append(index < localTexcoords.count ? localTexcoords[index] : .zero)
            }
            for value in Self.readIndices(element) {
                indices.append(base + value)
            }
            if material == nil {
                material = geometry.firstMaterial
            }
        }

        guard !positions.isEmpty, !indices.isEmpty, let material else {
            print("[Agri] Wheat mesh could not be read; field will render without a crop layer")
            return nil
        }

        // Normalise to unit height with the base on the ground.
        var minY = Float.greatestFiniteMagnitude
        var maxY = -Float.greatestFiniteMagnitude
        for position in positions {
            minY = min(minY, position.y)
            maxY = max(maxY, position.y)
        }
        let height = max(0.0001, maxY - minY)
        for index in positions.indices {
            positions[index] = (positions[index] - SIMD3<Float>(0, minY, 0)) / height
        }

        let prototype = ClumpPrototype(
            positions: positions,
            normals: normals,
            texcoords: texcoords,
            indices: indices,
            material: material
        )
        cachedPrototype = prototype
        print("[Agri] wheat clump prototype: \(positions.count) vertices, \(indices.count / 3) triangles")
        return prototype
    }

    private static func readFloat3(_ source: SCNGeometrySource) -> [SIMD3<Float>] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else {
            return []
        }
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                let x = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                result.append(SIMD3<Float>(x, y, z))
            }
        }
        return result
    }

    private static func readFloat2(_ source: SCNGeometrySource) -> [SIMD2<Float>] {
        guard source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 2 else {
            return []
        }
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(source.vectorCount)
        source.data.withUnsafeBytes { raw in
            for index in 0..<source.vectorCount {
                let offset = source.dataOffset + index * source.dataStride
                let x = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                result.append(SIMD2<Float>(x, y))
            }
        }
        return result
    }

    private static func readIndices(_ element: SCNGeometryElement) -> [UInt32] {
        let count = element.primitiveCount * 3
        var result: [UInt32] = []
        result.reserveCapacity(count)
        element.data.withUnsafeBytes { raw in
            for index in 0..<count {
                switch element.bytesPerIndex {
                case 2:
                    result.append(UInt32(raw.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)))
                case 4:
                    result.append(raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                default:
                    break
                }
            }
        }
        return result
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: WheatConstants.resourceName,
            withExtension: WheatConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let root = SCNNode()
        root.name = WheatConstants.templateNodeName
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        applyCropMaterials(root)

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        modelNativeMinY = Float(minBB.y)
        print("[Agri] Wheat.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    private func applyCropMaterials(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry else { return }
            for material in geometry.materials {
                material.isDoubleSided = true
                material.lightingModel = .lambert
                material.writesToDepthBuffer = true
                material.readsFromDepthBuffer = true
                material.blendMode = .replace
                material.transparencyMode = .aOne
                material.shaderModifiers = [
                    .fragment: "#pragma transparent\nif (_output.color.a < 0.45) { discard_fragment(); }\n_output.color.a = 1.0;"
                ]
                material.diffuse.mipFilter = .linear
                material.diffuse.maxAnisotropy = 4.0
            }
        }
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Agri] Wheat asset unavailable; field will render without a crop layer")
    }
}
