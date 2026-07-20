import SceneKit
import simd

/// Builds renderable and collidable geometry for one imported building.
///
/// Geometry is emitted **non-indexed**: every triangle carries its own three vertices. Buildings
/// want flat shading — a shared vertex between two wall planes would average their normals and
/// round off the corner, which reads as a soft, inflated blob instead of masonry. At these
/// counts (about 37 triangles for a typical 13-vertex footprint) the duplication costs nothing.
///
/// Walls and roof are separate geometry elements over shared sources, so the facade material and
/// the roof material can differ while the building stays a single node and a single draw setup.
enum UAVWorldBuildingGeometryFactory {

    /// Distinguishes the two material slots on the returned geometry.
    enum MaterialSlot: Int {
        case walls = 0
        case roof = 1
    }

    // MARK: - Visual geometry

    /// Returns geometry in the building's own local space, centred on its footprint centroid.
    ///
    /// Centring matters: SceneKit transforms are applied about the node origin, and a building
    /// whose vertices sit a kilometre from its own origin loses float precision in the transform
    /// and gets a bounding sphere far larger than the building, wrecking frustum culling. The
    /// caller positions the node at the centroid.
    static func makeGeometry(for building: UAVWorldBuilding) -> SCNGeometry? {
        let centroid = building.centroid
        let footprint = building.footprint.map { $0 - centroid }
        guard footprint.count >= 3 else { return nil }

        let base = building.baseElevationMeters
        let eaveHeight = base + building.heightMeters

        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var uvs: [CGPoint] = []

        let wallTriangleCount = appendWalls(
            footprint: footprint,
            baseY: base,
            topY: eaveHeight,
            positions: &positions,
            normals: &normals,
            uvs: &uvs
        )
        let wallVertexCount = positions.count

        let roofTriangleCount = appendRoof(
            footprint: footprint,
            eaveY: eaveHeight,
            building: building,
            positions: &positions,
            normals: &normals,
            uvs: &uvs
        )

        guard wallTriangleCount > 0 || roofTriangleCount > 0 else { return nil }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let normalSource = SCNGeometrySource(normals: normals)
        let uvSource = SCNGeometrySource(textureCoordinates: uvs)

        var elements: [SCNGeometryElement] = []
        if wallTriangleCount > 0 {
            let indices = Array(Int32(0)..<Int32(wallVertexCount))
            elements.append(
                SCNGeometryElement(indices: indices, primitiveType: .triangles)
            )
        }
        if roofTriangleCount > 0 {
            let indices = Array(Int32(wallVertexCount)..<Int32(positions.count))
            elements.append(
                SCNGeometryElement(indices: indices, primitiveType: .triangles)
            )
        }

        return SCNGeometry(
            sources: [vertexSource, normalSource, uvSource],
            elements: elements
        )
    }

    // MARK: - Walls

    /// Outward-facing wall quads, one per footprint edge.
    ///
    /// UVs are in **metres**, not normalised 0…1: `u` runs along the wall from the edge's start
    /// and `v` runs up from the base. Real-world-scale mapping is what lets a procedural facade
    /// place a window every 3 m and a floor line every storey regardless of how wide the
    /// building happens to be — normalised UVs would stretch the same window count across a 6 m
    /// townhouse and a 60 m block.
    @discardableResult
    private static func appendWalls(
        footprint: [SIMD2<Float>],
        baseY: Float,
        topY: Float,
        positions: inout [SCNVector3],
        normals: inout [SCNVector3],
        uvs: inout [CGPoint]
    ) -> Int {
        guard topY > baseY else { return 0 }
        var triangleCount = 0

        for index in footprint.indices {
            let start = footprint[index]
            let end = footprint[(index + 1) % footprint.count]
            let delta = end - start
            let edgeLength = simd_length(delta)
            guard edgeLength > 0.001 else { continue }

            // For a footprint wound counter-clockwise in the XZ plane, the outward normal of the
            // edge running start→end is (dz, 0, -dx). Derived rather than guessed: an inward
            // normal makes every building render inside-out and invisible under back-face
            // culling.
            let normal = simd_normalize(SIMD3<Float>(delta.y, 0, -delta.x))
            let scnNormal = SCNVector3(normal.x, normal.y, normal.z)

            let bottomLeft = SCNVector3(start.x, baseY, start.y)
            let bottomRight = SCNVector3(end.x, baseY, end.y)
            let topLeft = SCNVector3(start.x, topY, start.y)
            let topRight = SCNVector3(end.x, topY, end.y)

            let height = topY - baseY
            let uvBottomLeft = CGPoint(x: 0, y: 0)
            let uvBottomRight = CGPoint(x: CGFloat(edgeLength), y: 0)
            let uvTopLeft = CGPoint(x: 0, y: CGFloat(height))
            let uvTopRight = CGPoint(x: CGFloat(edgeLength), y: CGFloat(height))

            // Winding chosen so the face normal matches `normal` above.
            positions.append(contentsOf: [bottomLeft, topRight, bottomRight])
            uvs.append(contentsOf: [uvBottomLeft, uvTopRight, uvBottomRight])
            positions.append(contentsOf: [bottomLeft, topLeft, topRight])
            uvs.append(contentsOf: [uvBottomLeft, uvTopLeft, uvTopRight])
            normals.append(contentsOf: Array(repeating: scnNormal, count: 6))
            triangleCount += 2
        }

        return triangleCount
    }

    // MARK: - Roof

    /// Roofs are built as a **vertical displacement field over the triangulated footprint**
    /// rather than as a separate construction per roof form.
    ///
    /// A gabled roof is a rise that falls off with distance from a ridge line; a pyramidal one
    /// falls off from the centroid; a dome follows a spherical profile. Expressing all of them as
    /// "how high is the roof above this point" means one code path handles any footprint shape,
    /// including the concave and L-shaped blocks that a per-form constructor would need special
    /// cases for — and a flat roof is simply the zero field.
    @discardableResult
    private static func appendRoof(
        footprint: [SIMD2<Float>],
        eaveY: Float,
        building: UAVWorldBuilding,
        positions: inout [SCNVector3],
        normals: inout [SCNVector3],
        uvs: inout [CGPoint]
    ) -> Int {
        guard let indices = PolygonTriangulator.triangulate(footprint) else {
            // A footprint that survived import but will not triangulate is self-intersecting.
            // Leaving the roof open is the honest outcome; inventing a cap would put a surface
            // where the source data does not support one.
            return 0
        }

        let rise = building.roofForm.hasRaisedProfile ? building.roofHeightMeters : 0
        let field = DisplacementField(
            form: building.roofForm,
            footprint: footprint,
            rise: rise
        )

        var triangleCount = 0
        for index in stride(from: 0, to: indices.count, by: 3) {
            let a2 = footprint[indices[index]]
            let b2 = footprint[indices[index + 1]]
            let c2 = footprint[indices[index + 2]]

            let a = SIMD3<Float>(a2.x, eaveY + field.height(at: a2), a2.y)
            let b = SIMD3<Float>(b2.x, eaveY + field.height(at: b2), b2.y)
            let c = SIMD3<Float>(c2.x, eaveY + field.height(at: c2), c2.y)

            // The triangulator returns triangles wound counter-clockwise in 2D (x, y); mapping
            // y onto z flips the handedness, so the order is reversed here to make the face
            // normal point up rather than into the building.
            let normal = faceNormal(a, c, b)
            let scnNormal = SCNVector3(normal.x, normal.y, normal.z)

            positions.append(contentsOf: [
                SCNVector3(a.x, a.y, a.z),
                SCNVector3(c.x, c.y, c.z),
                SCNVector3(b.x, b.y, b.z)
            ])
            normals.append(contentsOf: [scnNormal, scnNormal, scnNormal])
            // Roof UVs are plan-projected metres, so roofing texture scale matches the walls.
            uvs.append(contentsOf: [
                CGPoint(x: CGFloat(a2.x), y: CGFloat(a2.y)),
                CGPoint(x: CGFloat(c2.x), y: CGFloat(c2.y)),
                CGPoint(x: CGFloat(b2.x), y: CGFloat(b2.y))
            ])
            triangleCount += 1
        }

        return triangleCount
    }

    /// Height of the roof surface above the eaves, as a function of position in the footprint.
    private struct DisplacementField {
        let form: UAVWorldRoofForm
        let rise: Float
        let center: SIMD2<Float>
        /// Unit vector along the ridge, for the forms that have one.
        let ridgeAxis: SIMD2<Float>
        /// Half the extent measured across the ridge — the distance over which the rise decays.
        let halfSpan: Float
        /// Extent along the ridge, used by the forms that also taper end-to-end.
        let longExtent: Float

        init(form: UAVWorldRoofForm, footprint: [SIMD2<Float>], rise: Float) {
            self.form = form
            self.rise = rise

            if let bounds = PolygonTriangulator.orientedBounds(of: footprint) {
                self.center = bounds.center
                self.ridgeAxis = bounds.longAxis
                self.halfSpan = max(bounds.shortExtent * 0.5, 0.5)
                self.longExtent = bounds.longExtent
            } else {
                self.center = footprint.reduce(SIMD2<Float>(0, 0), +) / Float(footprint.count)
                self.ridgeAxis = SIMD2<Float>(1, 0)
                self.halfSpan = 1.0
                self.longExtent = 1.0
            }
        }

        func height(at point: SIMD2<Float>) -> Float {
            guard rise > 0 else { return 0 }
            let offset = point - center

            switch form {
            case .flat:
                return 0

            case .gabled, .mansard:
                // Distance measured perpendicular to the ridge.
                let across = abs(offset.x * -ridgeAxis.y + offset.y * ridgeAxis.x)
                let t = min(across / halfSpan, 1.0)
                // A mansard's lower slope is steeper, which reads as the rise being reached
                // sooner as you move in from the eaves.
                let profile = form == .mansard ? (1.0 - t * t) : (1.0 - t)
                return rise * max(profile, 0)

            case .hipped:
                // Like a gable, but also falling away towards the two ends.
                let across = abs(offset.x * -ridgeAxis.y + offset.y * ridgeAxis.x)
                let along = abs(offset.x * ridgeAxis.x + offset.y * ridgeAxis.y)
                let halfLong = max(longExtent * 0.5, 0.5)
                let acrossFactor = 1.0 - min(across / halfSpan, 1.0)
                // The hip only starts cutting in near the ends, so the ridge keeps a flat run.
                let endTaper = min(
                    max((halfLong - along) / max(halfSpan, 0.5), 0.0),
                    1.0
                )
                return rise * max(min(acrossFactor, endTaper), 0)

            case .pyramidal:
                let distance = simd_length(offset)
                let radius = max(halfSpan, 0.5)
                return rise * max(1.0 - distance / radius, 0)

            case .skillion:
                // A single slope: lowest at one end of the long axis, highest at the other.
                let along = offset.x * ridgeAxis.x + offset.y * ridgeAxis.y
                let halfLong = max(longExtent * 0.5, 0.5)
                let t = (along + halfLong) / (2.0 * halfLong)
                return rise * min(max(t, 0), 1)

            case .domed:
                let distance = simd_length(offset)
                let radius = max(halfSpan, 0.5)
                let t = min(distance / radius, 1.0)
                return rise * (1.0 - t * t).squareRoot()
            }
        }
    }

    private static func faceNormal(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> SIMD3<Float> {
        let normal = simd_cross(b - a, c - a)
        let length = simd_length(normal)
        // A degenerate triangle has no meaningful normal; pointing it up is the least wrong
        // answer for a roof and avoids emitting NaNs into the geometry source.
        return length > 1e-6 ? normal / length : SIMD3<Float>(0, 1, 0)
    }

    // MARK: - Collision proxy

    /// Simplified triangles for physics and sensors, in **world** local metres (not centred on
    /// the building), matching what `EnvironmentCollisionMeshPart` expects.
    ///
    /// The proxy deliberately ignores roof form and caps the building flat at its total height.
    /// A UAV needs to know it cannot pass through the volume and where it can settle; modelling
    /// the pitch would add triangles to every ray query for a distinction no sensor at flight
    /// range resolves. This is the visual/collision split the design calls for — detailed
    /// appearance, stable simplified physics.
    static func makeCollisionTriangles(
        for building: UAVWorldBuilding
    ) -> [EnvironmentCollisionMeshTriangle] {
        let footprint = building.footprint
        guard footprint.count >= 3 else { return [] }

        let base = building.baseElevationMeters
        let top = base + building.totalHeightMeters
        var triangles: [EnvironmentCollisionMeshTriangle] = []

        for index in footprint.indices {
            let start = footprint[index]
            let end = footprint[(index + 1) % footprint.count]
            guard simd_length(end - start) > 0.001 else { continue }

            let bottomLeft = SIMD3<Float>(start.x, base, start.y)
            let bottomRight = SIMD3<Float>(end.x, base, end.y)
            let topLeft = SIMD3<Float>(start.x, top, start.y)
            let topRight = SIMD3<Float>(end.x, top, end.y)

            triangles.append(
                EnvironmentCollisionMeshTriangle(
                    point0: bottomLeft,
                    point1: topRight,
                    point2: bottomRight,
                    supportsLanding: false
                )
            )
            triangles.append(
                EnvironmentCollisionMeshTriangle(
                    point0: bottomLeft,
                    point1: topLeft,
                    point2: topRight,
                    supportsLanding: false
                )
            )
        }

        // Flat cap, marked as landable so roof-landing behaves the same as it does for the
        // existing hand-authored city buildings.
        if let indices = PolygonTriangulator.triangulate(footprint) {
            for index in stride(from: 0, to: indices.count, by: 3) {
                let a = footprint[indices[index]]
                let b = footprint[indices[index + 1]]
                let c = footprint[indices[index + 2]]
                triangles.append(
                    EnvironmentCollisionMeshTriangle(
                        point0: SIMD3<Float>(a.x, top, a.y),
                        point1: SIMD3<Float>(c.x, top, c.y),
                        point2: SIMD3<Float>(b.x, top, b.y),
                        supportsLanding: true
                    )
                )
            }
        }

        return triangles
    }
}
