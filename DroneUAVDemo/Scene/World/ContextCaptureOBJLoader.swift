import SceneKit
import AppKit
import simd

/// Loads one ContextCapture quadtree node — an OBJ, its MTL and its texture — into SceneKit.
///
/// A purpose-built parser rather than Model I/O, for two reasons. A city tile is thousands of
/// small OBJs (one 2 km tile holds over five thousand), so per-file framework overhead dominates;
/// and the files are extremely regular, using only `v`, `vt`, `usemtl` and triangular `f`, which
/// makes a direct reader short and predictable.
enum ContextCaptureOBJLoader {

    struct LoadedNode {
        let geometry: SCNGeometry
        let triangleCount: Int
        /// Bounds in the loader's output space (metres, relative to the export origin).
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
    }

    /// Some quadtree slots exist as **zero-byte** OBJ files — five of them appear in a single
    /// Helsinki tile. They are a normal condition of the export, not corruption, so callers
    /// should skip them rather than treat them as load failures.
    static func isEmptyPlaceholder(_ node: ContextCaptureTileIndex.Node) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: node.objectURL.path)[.size])
            .flatMap { $0 as? NSNumber }?.intValue
        return (size ?? 0) == 0
    }

    enum LoadError: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return L10n.f("world.mesh.error.obj_unreadable", name)
            case .empty(let name):
                return L10n.f("world.mesh.error.obj_empty", name)
            }
        }
    }

    /// Parsed material: the texture file a material name maps to.
    ///
    /// Uses `enumerateLines` rather than splitting on `"\n"`. The export is written with **CRLF**
    /// terminators, and `CharacterSet.whitespaces` contains only space and tab — not carriage
    /// return — so trimming with it leaves a trailing `\r` on every material name and texture
    /// filename. That produced silently untextured geometry: the OBJ's `usemtl` names, read
    /// through `enumerateLines`, came out clean and never matched the `\r`-suffixed keys here.
    private static func parseMaterials(at url: URL) -> [String: URL] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: URL] = [:]
        var current: String?
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("newmtl ") {
                current = String(trimmed.dropFirst("newmtl ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if trimmed.hasPrefix("map_Kd "), let name = current {
                let file = String(trimmed.dropFirst("map_Kd ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                result[name] = url.deletingLastPathComponent().appendingPathComponent(file)
            }
        }
        return result
    }

    /// Loads a node's geometry.
    ///
    /// - Parameter originOffset: added to every vertex, in the OBJ's own axes, before the
    ///   conversion to scene axes. Callers pass the offset that re-anchors the export's origin
    ///   onto the simulator's world origin, so vertices arrive already in local metres.
    static func load(
        node: ContextCaptureTileIndex.Node,
        originOffset: SIMD3<Double>
    ) throws -> LoadedNode {
        guard let data = try? Data(contentsOf: node.objectURL),
              let text = String(data: data, encoding: .utf8) else {
            throw LoadError.unreadable(node.objectURL.lastPathComponent)
        }

        var positions: [SIMD3<Float>] = []
        var textureCoordinates: [SIMD2<Float>] = []
        // Faces as (positionIndex, textureIndex) corners, plus the material in force.
        var corners: [(position: Int, texture: Int)] = []
        var activeMaterial: String?
        var firstTexturedMaterial: String?

        positions.reserveCapacity(4096)
        textureCoordinates.reserveCapacity(4096)
        corners.reserveCapacity(8192)

        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 3,
                      let x = Double(parts[0]),
                      let y = Double(parts[1]),
                      let z = Double(parts[2]) else { return }
                // OBJ is Z-up with x east and y north; the simulator uses Y-up with +Z north.
                // Re-anchoring happens here in double precision, before the values are narrowed
                // to Float — the raw coordinates are tens of thousands of metres from the export
                // origin and would lose millimetre precision if narrowed first.
                let east = x + originOffset.x
                let north = y + originOffset.y
                let up = z + originOffset.z
                positions.append(SIMD3<Float>(Float(east), Float(up), Float(north)))
            } else if line.hasPrefix("vt ") {
                let parts = line.dropFirst(3).split(separator: " ")
                guard parts.count >= 2,
                      let u = Float(parts[0]),
                      let v = Float(parts[1]) else { return }
                // OBJ texture space has v increasing upward; SceneKit's is flipped.
                textureCoordinates.append(SIMD2<Float>(u, 1.0 - v))
            } else if line.hasPrefix("usemtl ") {
                let name = String(line.dropFirst("usemtl ".count)).trimmingCharacters(in: .whitespaces)
                activeMaterial = name
                if firstTexturedMaterial == nil, !name.hasSuffix("_untextured") {
                    firstTexturedMaterial = name
                }
            } else if line.hasPrefix("f ") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 3 else { return }
                var face: [(Int, Int)] = []
                for part in parts.prefix(3) {
                    let indices = part.split(separator: "/", omittingEmptySubsequences: false)
                    guard let positionIndex = Int(indices[0]) else { return }
                    let textureIndex = indices.count > 1 ? Int(indices[1]) ?? 0 : 0
                    // OBJ indices are 1-based.
                    face.append((positionIndex - 1, textureIndex - 1))
                }
                // Swapping the Y and Z axes above reverses triangle orientation, so the winding
                // is reversed here to keep outward faces outward. Without this the entire city
                // renders inside-out and vanishes under back-face culling.
                corners.append((face[0].0, face[0].1))
                corners.append((face[2].0, face[2].1))
                corners.append((face[1].0, face[1].1))
            }
            _ = activeMaterial
        }

        guard corners.count >= 3, !positions.isEmpty else {
            throw LoadError.empty(node.objectURL.lastPathComponent)
        }

        // Smooth normals, accumulated per position. Photogrammetric meshes are organic surfaces
        // rather than architectural planes, and flat shading makes them look faceted and
        // artificial even though the texture already carries most of the visual information.
        var accumulatedNormals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for index in stride(from: 0, to: corners.count, by: 3) {
            let i0 = corners[index].position
            let i1 = corners[index + 1].position
            let i2 = corners[index + 2].position
            guard i0 >= 0, i1 >= 0, i2 >= 0,
                  i0 < positions.count, i1 < positions.count, i2 < positions.count else {
                continue
            }
            // Un-normalised cross product weights each face by its area, which is the standard
            // way to keep large faces from being outvoted by clusters of small ones.
            let faceNormal = simd_cross(
                positions[i1] - positions[i0],
                positions[i2] - positions[i0]
            )
            accumulatedNormals[i0] += faceNormal
            accumulatedNormals[i1] += faceNormal
            accumulatedNormals[i2] += faceNormal
        }

        // De-index into unique (position, texcoord) pairs. The two index streams are
        // independent in OBJ, so a position shared by faces with different texture coordinates
        // has to become several vertices.
        var vertexMap: [Int64: Int32] = [:]
        var outPositions: [SCNVector3] = []
        var outNormals: [SCNVector3] = []
        var outTexCoords: [CGPoint] = []
        var indices: [Int32] = []
        indices.reserveCapacity(corners.count)

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

        for corner in corners {
            guard corner.position >= 0, corner.position < positions.count else { continue }
            let key = Int64(corner.position) << 32 | Int64(UInt32(bitPattern: Int32(corner.texture)))
            if let existing = vertexMap[key] {
                indices.append(existing)
                continue
            }

            let position = positions[corner.position]
            let accumulated = accumulatedNormals[corner.position]
            let length = simd_length(accumulated)
            let normal = length > 1e-9 ? accumulated / length : SIMD3<Float>(0, 1, 0)
            let uv = (corner.texture >= 0 && corner.texture < textureCoordinates.count)
                ? textureCoordinates[corner.texture]
                : SIMD2<Float>(0, 0)

            let newIndex = Int32(outPositions.count)
            vertexMap[key] = newIndex
            outPositions.append(SCNVector3(position.x, position.y, position.z))
            outNormals.append(SCNVector3(normal.x, normal.y, normal.z))
            outTexCoords.append(CGPoint(x: CGFloat(uv.x), y: CGFloat(uv.y)))
            indices.append(newIndex)

            minimum = simd_min(minimum, position)
            maximum = simd_max(maximum, position)
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: outPositions),
                SCNGeometrySource(normals: outNormals),
                SCNGeometrySource(textureCoordinates: outTexCoords)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )

        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        if let materialURL = node.materialURL,
           let name = firstTexturedMaterial,
           let textureURL = parseMaterials(at: materialURL)[name],
           let image = NSImage(contentsOf: textureURL) {
            material.diffuse.contents = image
        } else {
            material.diffuse.contents = NSColor(calibratedWhite: 0.55, alpha: 1)
        }
        // Photogrammetric texture already contains baked lighting and material response, so the
        // surface is treated as a plain diffuse sample rather than given invented specularity.
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8
        material.isDoubleSided = false
        geometry.materials = [material]

        return LoadedNode(
            geometry: geometry,
            triangleCount: indices.count / 3,
            minimum: minimum,
            maximum: maximum
        )
    }
}
