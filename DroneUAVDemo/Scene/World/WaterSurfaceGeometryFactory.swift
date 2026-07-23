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

    /// A flat surface whose *edge* follows the water boundary at 45°, not in grid stair-steps.
    ///
    /// Marching-squares area fill. Each set of four adjacent cell centres forms a square; the water
    /// boundary passes between the wet centres and the dry ones, and the square's water region is
    /// emitted with that boundary cut at the edge midpoints. Walking the square's perimeter in order
    /// — adding a corner when it is water and a midpoint whenever an edge changes state — yields a
    /// simple polygon in every connected case. The two diagonal-saddle cases are emitted as two
    /// separate triangles, because their water regions touch neither at an edge nor at the centre.
    /// That robustness is the reason for this over triangulating raw, occasionally self-touching OSM
    /// boundaries directly.
    static func makeTriangleCorners(for model: WaterSurfaceModel) -> [SIMD3<Float>] {
        var corners: [SIMD3<Float>] = []
        let y = model.level
        let cell = model.cellSize

        func centre(_ column: Int, _ row: Int) -> SIMD2<Float> {
            SIMD2<Float>(
                model.minimum.x + (Float(column) + 0.5) * cell,
                model.minimum.y + (Float(row) + 0.5) * cell
            )
        }

        func append(_ polygon: [SIMD2<Float>]) {
            guard polygon.count >= 3 else { return }
            // Positions walk counter-clockwise in XZ, which points down in SceneKit's
            // right-handed coordinates. Reverse each fan triangle so its face points up.
            for index in 1..<(polygon.count - 1) {
                corners.append(SIMD3<Float>(polygon[0].x, y, polygon[0].y))
                corners.append(SIMD3<Float>(polygon[index + 1].x, y, polygon[index + 1].y))
                corners.append(SIMD3<Float>(polygon[index].x, y, polygon[index].y))
            }
        }

        func appendBoundarySquare(column: Int, row: Int) {
            let cornerColumns = [column, column + 1, column + 1, column]
            let cornerRows = [row, row, row + 1, row + 1]
            let positions = (0..<4).map { centre(cornerColumns[$0], cornerRows[$0]) }
            let wet = (0..<4).map {
                model.isWaterCell(column: cornerColumns[$0], row: cornerRows[$0])
            }
            guard wet.contains(true) else { return }

            // Opposite wet corners are two disconnected water regions, not one hexagon through
            // the dry centre. Joining them was a subtle source of square diamonds along a
            // one-cell-wide bank, so emit one triangle around each wet centre instead.
            let diagonalSaddle = wet[0] == wet[2]
                && wet[1] == wet[3]
                && wet[0] != wet[1]
            if diagonalSaddle {
                for index in 0..<4 where wet[index] {
                    let previous = (index + 3) % 4
                    let next = (index + 1) % 4
                    append([
                        positions[index],
                        (positions[index] + positions[next]) * 0.5,
                        (positions[previous] + positions[index]) * 0.5
                    ])
                }
                return
            }

            var polygon: [SIMD2<Float>] = []
            for index in 0..<4 {
                if wet[index] { polygon.append(positions[index]) }
                let next = (index + 1) % 4
                if wet[index] != wet[next] {
                    polygon.append((positions[index] + positions[next]) * 0.5)
                }
            }
            append(polygon)
        }

        // At one-metre resolution, emitting two triangles for every square of open harbour would
        // spend nearly all geometry on a perfectly flat interior. Fixed blocks that are wet at
        // every corner collapse to one quad; only blocks touching a shoreline use marching
        // squares at full precision. Because all vertices remain on the same centre grid, the
        // coarse and detailed regions meet without cracks.
        let blockSize = 8
        var blockRow = -1
        while blockRow < model.rows {
            let endRow = min(blockRow + blockSize, model.rows)
            var blockColumn = -1
            while blockColumn < model.columns {
                let endColumn = min(blockColumn + blockSize, model.columns)
                var fullyWet = true
                for row in blockRow...endRow {
                    for column in blockColumn...endColumn
                    where !model.isWaterCell(column: column, row: row) {
                        fullyWet = false
                        break
                    }
                    if !fullyWet { break }
                }

                if fullyWet {
                    append([
                        centre(blockColumn, blockRow),
                        centre(endColumn, blockRow),
                        centre(endColumn, endRow),
                        centre(blockColumn, endRow)
                    ])
                } else {
                    for row in blockRow..<endRow {
                        for column in blockColumn..<endColumn {
                            appendBoundarySquare(column: column, row: row)
                        }
                    }
                }

                blockColumn = endColumn
            }
            blockRow = endRow
        }

        return corners
    }

    @MainActor
    static func makeNode(for model: WaterSurfaceModel) -> SCNNode? {
        let corners = makeTriangleCorners(for: model)

        guard !corners.isEmpty else { return nil }
        let normals = Array(repeating: SIMD3<Float>(0, 1, 0), count: corners.count)

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
