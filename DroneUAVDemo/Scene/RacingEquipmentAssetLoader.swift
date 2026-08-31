import AppKit
import SceneKit

private enum RacingAssetConstants {
    static let resourceExtension = "usdz"
    static let nodeNamePrefix = "race.element."
    /// The pack is authored in centimetres (no `metersPerUnit` metadata, so USD's centimetre
    /// default applies) and SceneKit does not convert it, so every model is scaled here.
    static let modelUnitsToMeters: Float = 0.01
}

/// Loads the racing-equipment pack and normalises every piece into one frame:
/// origin on the ground under the element's centre, **+Z is the direction the pilot flies
/// through it**, +Y up.
///
/// That normalisation is the whole point of this loader. The pack is authored with the gate ring
/// in the model's ZY plane (so the pass direction is model X), except for the tower, which is
/// flown vertically, and the open cube, which is authored along model Z. Without one shared
/// convention, the editor would have to know each model's quirks, and pass detection would need a
/// per-model special case — the exact kind of hidden per-asset knowledge that produces gates that
/// score when you fly past them and stay silent when you fly through them.
final class RacingEquipmentAssetLoader {
    static let shared = RacingEquipmentAssetLoader()

    private var cachedTemplates: [String: SCNNode] = [:]
    private var cachedModelBounds: [String: (min: SIMD3<Float>, max: SIMD3<Float>)] = [:]
    private var cachedCollisionBoxes: [String: [RaceElementCollisionBox]] = [:]
    private var failedResources: Set<String> = []

    private init() {}

    // MARK: Node construction

    /// A placed element. `scale` is a uniform size multiplier chosen in the editor (1.0 = the
    /// real-world size of the equipment).
    func makeElementNode(
        descriptor: RacingElementDescriptor,
        scale: Float = 1.0,
        yaw: Float = 0.0
    ) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = RacingAssetConstants.nodeNamePrefix + descriptor.id
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)

        guard let template = loadTemplate(named: descriptor.resourceName),
              let bounds = cachedModelBounds[descriptor.resourceName] else {
            wrapper.addChildNode(makeProceduralElement(descriptor: descriptor, scale: scale))
            return wrapper
        }

        let model = template.clone()
        makeMaterialsIndependent(model)
        applyDefaultMaterials(model)

        let s = RacingAssetConstants.modelUnitsToMeters * max(0.05, scale)
        model.scale = SCNVector3(s, s, s)
        model.eulerAngles = SCNVector3(0, rotationYRadians(for: descriptor.passAxis), 0)

        let mid = (bounds.min + bounds.max) * 0.5
        switch descriptor.passAxis {
        case .modelX:
            // Rotated -90° about Y: model X → node +Z, model Z → node −X.
            model.position = SCNVector3(s * mid.z, -s * bounds.min.y, -s * mid.x)
        case .modelY, .modelZ:
            model.position = SCNVector3(-s * mid.x, -s * bounds.min.y, -s * mid.z)
        }

        wrapper.addChildNode(model)
        return wrapper
    }

    /// Rotation that carries the model's pass axis onto node +Z.
    private func rotationYRadians(for axis: RacingModelPassAxis) -> CGFloat {
        switch axis {
        case .modelX:
            return CGFloat(-Float.pi / 2.0)
        case .modelY, .modelZ:
            return 0.0
        }
    }

    // MARK: Collision shape

    /// Solid boxes that follow the element's actual members, in the normalised node frame at unit
    /// scale (origin on the ground, +Z through the gate).
    ///
    /// Derived from the mesh, not from the bounding box. A gate is a thin frame around a large
    /// hole, so anything inferred from its outline is wrong in the way that matters: an earlier
    /// version built the frame from the gap between the opening and the bounding box and gave a
    /// 5 cm tube a 26 cm post — and, worse, the depth of the *stand* rather than of the frame, so
    /// the gate collided like a slab three quarters of a metre thick.
    ///
    /// Feeding the raw triangles to the collision system is not an option either: the pack runs
    /// from 800 triangles for a flag to 151,000 for the tower, and a nine-gate track would cost
    /// hundreds of thousands of collision triangles per tick. So the mesh is voxelised at roughly
    /// a tenth of a metre and the occupied cells are merged back into a handful of boxes — solid
    /// where the tubes are, empty everywhere else, which is exactly what a gate is.
    ///
    /// Computed once per equipment type and cached; a track places many copies of a few types.
    func collisionBoxes(for descriptor: RacingElementDescriptor) -> [RaceElementCollisionBox] {
        if let cached = cachedCollisionBoxes[descriptor.id] {
            return cached
        }
        let boxes = buildCollisionBoxes(for: descriptor)
        cachedCollisionBoxes[descriptor.id] = boxes
        return boxes
    }

    private func buildCollisionBoxes(for descriptor: RacingElementDescriptor) -> [RaceElementCollisionBox] {
        // A launch mat is painted on the ground. Nothing to hit, and a proxy there only produced a
        // debug marker floating over open grass with no visible object under it.
        guard descriptor.role != .startPad else { return [] }
        guard loadTemplate(named: descriptor.resourceName) != nil else { return [] }
        let node = makeElementNode(descriptor: descriptor, scale: 1.0, yaw: 0.0)
        let triangles = collisionTriangles(in: node)
        guard !triangles.isEmpty else { return [] }

        var minimum = triangles[0].0
        var maximum = triangles[0].0
        for triangle in triangles {
            for point in [triangle.0, triangle.1, triangle.2] {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
        }
        let extent = maximum - minimum
        let largest = max(extent.x, max(extent.y, extent.z))
        guard largest > 0.01 else { return [] }

        // Start near a tenth of a metre — finer than any member in the pack — and coarsen only if
        // the merge would produce an unreasonable number of boxes (diagonal legs voxelise into
        // staircases, and a track places a dozen of these).
        //
        // A flag is the exception: most of its mesh is cloth, which has no business being solid,
        // and resolving it finely spends a hundred boxes describing a sheet a pilot should be able
        // to brush. Coarse cells there leave the pole solid and the fabric roughly so.
        let isSmallDecor = descriptor.role == .decor && descriptor.sizeMeters.x <= 1.5
        var cell = isSmallDecor
            ? 0.18
            : min(0.14, max(0.07, largest / 48.0))
        for _ in 0..<3 {
            let boxes = voxelisedBoxes(
                triangles: triangles,
                minimum: minimum,
                maximum: maximum,
                cell: cell
            )
            if boxes.count <= 140 || cell >= 0.34 {
                return isSmallDecor ? poleOnly(from: boxes, height: extent.y) : boxes
            }
            cell *= 1.7
        }
        return []
    }

    /// Keeps only a flag's mast.
    ///
    /// Most of a flag's mesh is cloth, and cloth is not something a quad should bounce off — nor
    /// something worth a dozen collision boxes hanging in the air beside the pole, which is what
    /// the operator saw as stray markers over empty grass. The mast is the one member tall enough
    /// to survive this filter.
    private func poleOnly(from boxes: [RaceElementCollisionBox], height: Float) -> [RaceElementCollisionBox] {
        let threshold = height * 0.5
        let tall = boxes.filter { $0.size.y >= threshold }
        if !tall.isEmpty {
            return tall
        }
        guard let tallest = boxes.max(by: { $0.size.y < $1.size.y }) else { return [] }
        return [tallest]
    }

    /// Triangles of a built element, expressed in the element's own (normalised) frame.
    private func collisionTriangles(in root: SCNNode) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var result: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        root.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry,
                  let vertexSource = geometry.sources(for: .vertex).first,
                  vertexSource.usesFloatComponents,
                  vertexSource.bytesPerComponent == 4,
                  vertexSource.componentsPerVector >= 3 else {
                return
            }
            let transform = simd_float4x4(child.convertTransform(SCNMatrix4Identity, to: root))
            var points: [SIMD3<Float>] = []
            points.reserveCapacity(vertexSource.vectorCount)
            vertexSource.data.withUnsafeBytes { raw in
                for index in 0..<vertexSource.vectorCount {
                    let offset = vertexSource.dataOffset + index * vertexSource.dataStride
                    let x = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                    let p = transform * SIMD4<Float>(x, y, z, 1.0)
                    points.append(SIMD3<Float>(p.x, p.y, p.z))
                }
            }

            for element in geometry.elements where element.primitiveType == .triangles {
                let indexCount = element.primitiveCount * 3
                element.data.withUnsafeBytes { raw in
                    func index(at position: Int) -> Int {
                        switch element.bytesPerIndex {
                        case 2:
                            return Int(raw.loadUnaligned(fromByteOffset: position * 2, as: UInt16.self))
                        case 4:
                            return Int(raw.loadUnaligned(fromByteOffset: position * 4, as: UInt32.self))
                        default:
                            return -1
                        }
                    }
                    var position = 0
                    while position + 2 < indexCount {
                        let i0 = index(at: position)
                        let i1 = index(at: position + 1)
                        let i2 = index(at: position + 2)
                        position += 3
                        guard i0 >= 0, i1 >= 0, i2 >= 0,
                              i0 < points.count, i1 < points.count, i2 < points.count else {
                            continue
                        }
                        result.append((points[i0], points[i1], points[i2]))
                    }
                }
            }
        }
        return result
    }

    /// Marks every cell a triangle touches, then merges runs of occupied cells into boxes.
    private func voxelisedBoxes(
        triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)],
        minimum: SIMD3<Float>,
        maximum: SIMD3<Float>,
        cell: Float
    ) -> [RaceElementCollisionBox] {
        let extent = maximum - minimum
        let counts = SIMD3<Int>(
            max(1, Int(ceil(extent.x / cell))),
            max(1, Int(ceil(extent.y / cell))),
            max(1, Int(ceil(extent.z / cell)))
        )
        let total = counts.x * counts.y * counts.z
        guard total > 0, total <= 2_000_000 else { return [] }
        var occupied = [Bool](repeating: false, count: total)

        func mark(_ point: SIMD3<Float>) {
            let local = (point - minimum) / cell
            let x = min(counts.x - 1, max(0, Int(local.x)))
            let y = min(counts.y - 1, max(0, Int(local.y)))
            let z = min(counts.z - 1, max(0, Int(local.z)))
            occupied[(y * counts.z + z) * counts.x + x] = true
        }

        // Surface sampling: the members are thin, so marking the cells the triangles pass through
        // is the same thing as filling them. The step is half a cell, which cannot skip one.
        let step = cell * 0.5
        for triangle in triangles {
            let edge1 = triangle.1 - triangle.0
            let edge2 = triangle.2 - triangle.0
            let samples = max(
                1,
                min(24, Int(ceil(max(simd_length(edge1), simd_length(edge2)) / step)))
            )
            if samples == 1 {
                mark(triangle.0)
                mark(triangle.1)
                mark(triangle.2)
                continue
            }
            for i in 0...samples {
                let u = Float(i) / Float(samples)
                for j in 0...(samples - i) {
                    let v = Float(j) / Float(samples)
                    mark(triangle.0 + edge1 * u + edge2 * v)
                }
            }
        }

        // Greedy merge: run along X, then widen in Z, then stack in Y.
        var visited = [Bool](repeating: false, count: total)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (y * counts.z + z) * counts.x + x }

        var boxes: [RaceElementCollisionBox] = []
        for y in 0..<counts.y {
            for z in 0..<counts.z {
                var x = 0
                while x < counts.x {
                    let start = index(x, y, z)
                    guard occupied[start], !visited[start] else {
                        x += 1
                        continue
                    }
                    var width = 1
                    while x + width < counts.x,
                          occupied[index(x + width, y, z)],
                          !visited[index(x + width, y, z)] {
                        width += 1
                    }
                    var depth = 1
                    outerDepth: while z + depth < counts.z {
                        for dx in 0..<width {
                            let candidate = index(x + dx, y, z + depth)
                            if !occupied[candidate] || visited[candidate] { break outerDepth }
                        }
                        depth += 1
                    }
                    var height = 1
                    outerHeight: while y + height < counts.y {
                        for dz in 0..<depth {
                            for dx in 0..<width {
                                let candidate = index(x + dx, y + height, z + dz)
                                if !occupied[candidate] || visited[candidate] { break outerHeight }
                            }
                        }
                        height += 1
                    }
                    for dy in 0..<height {
                        for dz in 0..<depth {
                            for dx in 0..<width {
                                visited[index(x + dx, y + dy, z + dz)] = true
                            }
                        }
                    }
                    let size = SIMD3<Float>(Float(width), Float(height), Float(depth)) * cell
                    let corner = minimum + SIMD3<Float>(Float(x), Float(y), Float(z)) * cell
                    boxes.append(
                        RaceElementCollisionBox(
                            localCenter: corner + size * 0.5,
                            size: size
                        )
                    )
                    x += width
                }
            }
        }
        return boxes
    }

    // MARK: Highlighting

    /// Recolours a placed element. The pack ships untextured white geometry, which is why gate
    /// state can be shown on the equipment itself rather than as a HUD annotation: the emission
    /// channel of a white frame reads cleanly as a colour at any distance and in any light.
    ///
    /// Materials were already copied per instance in `makeElementNode`, so this never leaks into
    /// other gates sharing the same cached template.
    func applyHighlight(_ node: SCNNode, color: NSColor?, intensity: Float = 1.0) {
        node.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry else { return }
            for material in geometry.materials {
                guard let color else {
                    material.emission.contents = NSColor.black
                    material.diffuse.contents = RacingMaterialPalette.frameColor
                    continue
                }
                let clamped = max(0.0, min(1.0, intensity))
                // The frame keeps its own colour and only takes a wash of the state tint. The
                // direction chevrons beside the opening carry the actual message, so a gate that
                // is merely "next" should read as marked, not as painted.
                material.diffuse.contents = RacingMaterialPalette.frameColor
                    .blended(withFraction: CGFloat(clamped) * 0.55, of: color) ?? color
                material.emission.contents = color.withAlphaComponent(CGFloat(clamped) * 0.5)
            }
        }
    }

    // MARK: Loading

    private func loadTemplate(named resourceName: String) -> SCNNode? {
        if let cached = cachedTemplates[resourceName] {
            return cached
        }
        guard !failedResources.contains(resourceName) else {
            return nil
        }

        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: RacingAssetConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            failedResources.insert(resourceName)
            print("[Racing] \(resourceName).usdz unavailable; using procedural placeholder")
            return nil
        }

        let root = SCNNode()
        root.name = "race_template_" + resourceName
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }

        let (minBB, maxBB) = root.boundingBox
        cachedModelBounds[resourceName] = (
            SIMD3<Float>(Float(minBB.x), Float(minBB.y), Float(minBB.z)),
            SIMD3<Float>(Float(maxBB.x), Float(maxBB.y), Float(maxBB.z))
        )
        cachedTemplates[resourceName] = root
        return root
    }

    /// `SCNNode.clone()` shares geometry and materials by reference. Highlighting one gate would
    /// otherwise recolour every gate cut from the same template — the same trap the fire-response
    /// trees hit when charring one tree darkened the whole forest.
    private func makeMaterialsIndependent(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            guard let geometry = child.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.map { material in
                (material.copy() as? SCNMaterial) ?? material
            }
            child.geometry = geometry
        }
    }

    private func applyDefaultMaterials(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            child.castsShadow = true
            guard let geometry = child.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .physicallyBased
                material.diffuse.contents = RacingMaterialPalette.frameColor
                material.roughness.contents = NSNumber(value: 0.45)
                material.metalness.contents = NSNumber(value: 0.0)
                material.isDoubleSided = true
                material.emission.contents = NSColor.black
            }
        }
    }

    /// Stand-in so a track stays flyable (and testable) if the pack is missing from the bundle.
    private func makeProceduralElement(descriptor: RacingElementDescriptor, scale: Float) -> SCNNode {
        let size = descriptor.sizeMeters * max(0.05, scale)
        let node: SCNNode
        switch descriptor.role {
        case .gate, .verticalGate, .decor:
            let torus = SCNTorus(
                ringRadius: CGFloat(max(0.4, descriptor.apertureHalfExtents.x * scale)),
                pipeRadius: CGFloat(0.05 * max(1.0, scale))
            )
            torus.firstMaterial?.diffuse.contents = RacingMaterialPalette.frameColor
            node = SCNNode(geometry: torus)
            node.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
            node.position = SCNVector3(0, CGFloat(descriptor.apertureHeightMeters * scale), 0)
        case .startPad:
            let box = SCNBox(width: CGFloat(size.x), height: 0.02, length: CGFloat(size.z), chamferRadius: 0)
            box.firstMaterial?.diffuse.contents = RacingMaterialPalette.frameColor
            node = SCNNode(geometry: box)
            node.position = SCNVector3(0, 0.01, 0)
        }
        return node
    }
}

/// Shared colours for racing equipment, so the editor palette, the gate highlights and the HUD
/// legend cannot drift apart.
enum RacingMaterialPalette {
    static let frameColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
    /// The gate the pilot must take next.
    static let nextGate = NSColor(calibratedRed: 0.15, green: 0.65, blue: 1.0, alpha: 1.0)
    /// Already flown correctly this lap.
    static let passedGate = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.35, alpha: 1.0)
    /// Missed, or taken in the wrong direction.
    static let missedGate = NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.20, alpha: 1.0)
    /// Start/finish.
    static let startFinish = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.15, alpha: 1.0)
}
