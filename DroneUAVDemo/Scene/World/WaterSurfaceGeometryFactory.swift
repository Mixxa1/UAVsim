import SceneKit
import simd

/// Turns a water mask into something the pilot can see.
///
/// Water in this project started life as physics only — a mask driving immersion, the spawn search's
/// refusal to start on water, and the sinking of a lost airframe. On a photogrammetric world that was
/// enough, because the mesh is a photograph and the sea is simply *in* it. On a world built from open
/// vector data there is no imagery at all, so a river was something the aircraft could drown in and
/// the pilot could not see. That is worse than having no water: it punishes the pilot for missing
/// something that was never drawn.
enum WaterSurfaceGeometryFactory {

    /// A flat surface covering exactly the masked cells.
    ///
    /// Cells are merged into horizontal runs before being emitted. A four-metre mask over a
    /// kilometre-and-a-half world is nearly two hundred thousand cells, and a quad each would cost
    /// more triangles than the entire city; runs collapse a river into a few hundred long strips
    /// because water is contiguous by nature.
    @MainActor
    static func makeNode(for model: WaterSurfaceModel) -> SCNNode? {
        var corners: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        let y = model.level

        for row in 0..<model.rows {
            var column = 0
            while column < model.columns {
                guard model.isWaterCell(column: column, row: row) else {
                    column += 1
                    continue
                }
                var runEnd = column
                while runEnd + 1 < model.columns, model.isWaterCell(column: runEnd + 1, row: row) {
                    runEnd += 1
                }

                let x0 = model.minimum.x + Float(column) * model.cellSize
                let x1 = model.minimum.x + Float(runEnd + 1) * model.cellSize
                let z0 = model.minimum.y + Float(row) * model.cellSize
                let z1 = z0 + model.cellSize

                let a = SIMD3<Float>(x0, y, z0)
                let b = SIMD3<Float>(x1, y, z0)
                let c = SIMD3<Float>(x1, y, z1)
                let d = SIMD3<Float>(x0, y, z1)
                corners.append(contentsOf: [a, c, b, a, d, c])
                normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 6))

                column = runEnd + 1
            }
        }

        guard !corners.isEmpty else { return nil }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: corners.map { SCNVector3($0.x, $0.y, $0.z) }),
                SCNGeometrySource(normals: normals.map { SCNVector3($0.x, $0.y, $0.z) })
            ],
            elements: [
                SCNGeometryElement(
                    indices: Array(0..<Int32(corners.count)),
                    primitiveType: .triangles
                )
            ]
        )

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Deliberately not a mirror. A perfectly smooth surface reflects the sky so completely that
        // it reads as a hole in the world, and at the altitudes flown here the pilot needs to
        // recognise water at a glance rather than admire it.
        material.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.21, blue: 0.26, alpha: 1)
        material.roughness.contents = 0.18
        material.metalness.contents = 0.0
        material.isDoubleSided = true
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.name = "world.water.surface"
        node.castsShadow = false
        return node
    }
}
