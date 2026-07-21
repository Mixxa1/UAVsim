import SceneKit
import simd

/// Builds a visible surface from the same triangles the physics uses.
///
/// Sharing the corner list with the collision index is deliberate. Terrain assembled separately for
/// the eye and for the flight model is terrain that will eventually disagree with itself, and a
/// disagreement of even a metre reads to the pilot as landing on nothing or colliding with air.
enum TerrainMeshFactory {

    @MainActor
    static func makeNode(corners: [SIMD3<Float>]) -> SCNNode? {
        guard corners.count >= 3, corners.count % 3 == 0 else { return nil }

        // Flat shading, via non-indexed geometry: each triangle keeps its own face normal, so the
        // relief reads as landform rather than as a smoothly shaded blob.
        var normals: [SCNVector3] = []
        normals.reserveCapacity(corners.count)
        for index in stride(from: 0, to: corners.count, by: 3) {
            let n = simd_normalize(simd_cross(
                corners[index + 1] - corners[index],
                corners[index + 2] - corners[index]
            ))
            let normal = SCNVector3(n.x, n.y, n.z)
            normals.append(contentsOf: [normal, normal, normal])
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: corners.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: normals)
            ],
            elements: [
                SCNGeometryElement(indices: Array(0..<Int32(corners.count)), primitiveType: .triangles)
            ]
        )

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.28, green: 0.29, blue: 0.26, alpha: 1)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "world.terrain.surface"
        node.castsShadow = false
        return node
    }
}
