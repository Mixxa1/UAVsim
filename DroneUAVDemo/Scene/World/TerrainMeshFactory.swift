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

    @MainActor
    static func makeNode(corners: [SIMD3<Float>]) -> SCNNode? {
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

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: normals)
            ],
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
}
