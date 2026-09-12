import SceneKit
import simd

enum VehicleDetachedPartPhysics {
    static let category = 1 << 3
    static let environmentCategory = 1 << 1

    static func snapshot(_ source: SCNNode, bodyFrame: SCNNode,
                         vehicleTransform: simd_float4x4, partTransform: simd_float4x4) -> SCNNode {
        let transform = vehicleTransform * bodyFrame.simdConvertTransform(matrix_identity_float4x4, from: source)
        let clone = source.clone()
        func freeze(_ node: SCNNode) {
            node.physicsBody = nil; node.camera = nil; node.light = nil
            node.removeAllActions(); node.removeAllAnimations(); node.constraints = nil
            node.isHidden = false; node.opacity = 1
            for child in node.childNodes { freeze(child) }
        }
        freeze(clone)
        clone.simdTransform = simd_inverse(partTransform) * transform
        return clone
    }

    static func makeBody(part: VehicleDetachedSubtree, shapeGeometry: SCNGeometry,
                         velocity: SIMD3<Float>, angularVelocity: SIMD3<Float>) -> SCNPhysicsBody {
        let shape = SCNPhysicsShape(geometry: shapeGeometry,
            options: [.type: SCNPhysicsShape.ShapeType.boundingBox])
        let body = SCNPhysicsBody(type: .dynamic, shape: shape)
        body.mass = CGFloat(max(0.005, part.massProperties.totalMassKg))
        body.centerOfMassOffset = SCNVector3(part.massProperties.centerOfMassOffset - part.localBoundsCenter)
        body.usesDefaultMomentOfInertia = false
        body.momentOfInertia = SCNVector3(simd_max(part.massProperties.inertiaDiagonal, SIMD3<Float>(repeating: 0.00001)))
        body.isAffectedByGravity = true
        body.allowsResting = true
        body.friction = 0.72; body.rollingFriction = 0.18; body.restitution = 0.14
        body.damping = 0.035; body.angularDamping = 0.055
        let half = part.localBoundsHalfExtents
        body.continuousCollisionDetectionThreshold = CGFloat(max(0.008, min(half.x, half.y, half.z) * 0.35))
        body.categoryBitMask = category
        // The retained aircraft's coarse sphere is not its physical skin.
        body.collisionBitMask = environmentCategory | category
        body.contactTestBitMask = environmentCategory | category
        body.velocity = SCNVector3(velocity)
        let speed = simd_length(angularVelocity)
        if speed > 0.0001 {
            let axis = angularVelocity / speed
            body.angularVelocity = SCNVector4(axis.x, axis.y, axis.z, speed)
        }
        return body
    }
}

/// Stable, physical ownership of rendered geometry. Legacy diagnostic buckets
/// deliberately combine unrelated things (the body and flight computer, or a
/// whole wing); they are not attachment relationships.
final class VehicleComponentVisualBinding {
    struct Entry {
        let componentID: String
        let node: SCNNode
        let parentInBody: simd_float4x4
    }
    private(set) var entries: [Entry] = []

    /// One cut across a member: the plane at a station's inboard joint, normal along the
    /// member. Pieces are owned by how many of a member's cuts they lie beyond.
    private struct MemberCut {
        let normal: SIMD3<Float>
        let offset: Float
        /// Half-width of the ragged band the break wanders over, metres.
        let jag: Float
    }

    private struct MemberCuts {
        let stations: [String]
        let rootOwner: String
        let cuts: [MemberCut]
    }

    init(root: SCNNode, bodyFrame: SCNNode, legacyNodes: [DamageComponent: [SCNNode]],
         propellers: [SCNNode], graph: VehicleComponentGraph) {
        guard let body = graph.components.first(where: { $0.parentID == nil }) else { return }
        var legacyByNode: [ObjectIdentifier: DamageComponent] = [:]
        for (legacy, nodes) in legacyNodes.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for node in nodes { legacyByNode[ObjectIdentifier(node)] = legacy }
        }
        let propIDs = Set(propellers.map(ObjectIdentifier.init))
        // Every discretised member, with a cut at each station joint.
        var memberOf: [String: String] = [:]
        var members: [String: MemberCuts] = [:]
        for (memberID, stations) in graph.memberChains {
            var cuts: [MemberCut] = []
            for (index, id) in stations.enumerated() {
                guard let section = graph.connection(childComponentID: id)?.section,
                      let component = graph.component(id: id) else { continue }
                let length = max(0.004, 2 * abs(simd_dot(component.localPosition - section.anchor, section.spanAxis)))
                // The root joint is a fitting and breaks close to its line; a break across
                // the member tears over about a quarter of a station either way.
                let jag = length * (index == 0 ? 0.08 : 0.25)
                cuts.append(MemberCut(normal: section.spanAxis, offset: simd_dot(section.anchor, section.spanAxis), jag: jag))
                memberOf[id] = memberID
            }
            let rootOwner = stations.first.flatMap { graph.connection(childComponentID: $0)?.parentComponentID } ?? body.id
            members[memberID] = MemberCuts(stations: stations, rootOwner: rootOwner, cuts: cuts)
        }
        func closest(_ point: SIMD3<Float>, _ candidates: [VehicleComponent]) -> String {
            candidates.min { a, b in
                func distance(_ c: VehicleComponent) -> Float {
                    let outside = simd_max(simd_abs(point - c.localPosition) - c.boundingHalfExtents, .zero)
                    return simd_length(outside) + simd_distance(point, c.localPosition) * 0.001
                }
                return distance(a) < distance(b)
            }?.id ?? body.id
        }
        /// Owner of a piece: the nearest candidate, and — when that is a station — the
        /// station whose interval along its member (between the ragged cuts, as jittered for
        /// this triangle) actually contains the piece.
        func owner(_ point: SIMD3<Float>, candidates: [VehicleComponent], jitter: (Int, Int) -> Float) -> String {
            let nearest = closest(point, candidates)
            guard let memberID = memberOf[nearest], let member = members[memberID] else { return nearest }
            var beyond = 0
            for (index, cut) in member.cuts.enumerated()
            where simd_dot(point, cut.normal) >= cut.offset + cut.jag * jitter(Self.stableHash(memberID), index) {
                beyond = index + 1
            }
            return beyond == 0 ? member.rootOwner : member.stations[min(member.stations.count - 1, beyond - 1)]
        }
        func install(_ node: SCNNode, owner: String) {
            guard let parent = node.parent else { return }
            let wrapper = SCNNode()
            wrapper.name = "componentVisual.\(owner)"
            let parentTransform = bodyFrame.simdConvertTransform(matrix_identity_float4x4, from: parent)
            node.removeFromParentNode()
            parent.addChildNode(wrapper)
            wrapper.addChildNode(node)
            entries.append(Entry(componentID: owner, node: wrapper, parentInBody: parentTransform))
        }
        let wingStations = graph.components.filter { if case .wingSection = $0.kind { return true }; return false }
        let tailParts = graph.components.filter { component in
            switch component.kind {
            case .tailSection, .horizontalTail, .verticalTail, .elevator, .rudder: return true
            default: return false
            }
        }
        func walk(_ node: SCNNode, inherited: DamageComponent?) {
            let legacy = legacyByNode[ObjectIdentifier(node)] ?? inherited
            if propIDs.contains(ObjectIdentifier(node)) {
                let point = bodyFrame.simdConvertPosition(.zero, from: node)
                install(node, owner: closest(point, graph.components.filter {
                    if case .propeller = $0.kind { return true }; return false
                }))
                return
            }
            // Gather before adding wrappers: traversal must never visit its own output.
            let children = node.childNodes
            if let geometry = node.geometry {
                let bounds = node.boundingBox
                let localCenter = SIMD3<Float>(Float(bounds.min.x + bounds.max.x),
                    Float(bounds.min.y + bounds.max.y), Float(bounds.min.z + bounds.max.z)) * 0.5
                let point = bodyFrame.simdConvertPosition(localCenter, from: node)
                let name = (node.name ?? "").lowercased()
                var candidates: [VehicleComponent]
                if (legacy == .armFL || legacy == .armFR), !wingStations.isEmpty {
                    // A wing mesh may run through the fuselage: what lies inboard of the root
                    // joint belongs to the body.
                    candidates = wingStations + [body]
                } else if (legacy == .armRL || legacy == .armRR), !tailParts.isEmpty {
                    // The tail bucket also holds booms and pylons that hang from the wing.
                    candidates = tailParts + wingStations + [body]
                } else if legacy == .flightControllerCore || legacy == nil {
                    let isGear = ["gear", "wheel", "tyre", "tire", "skid", "strut", "leg", "foot"].contains { name.contains($0) }
                    candidates = isGear ? graph.components.filter {
                        if case .landingGear = $0.kind { return true }; return false
                    } : [body]
                } else if [.motorFL, .motorFR, .motorRL, .motorRR].contains(legacy!) {
                    candidates = graph.components.filter { if case .motor = $0.kind { return true }; return false }
                } else {
                    candidates = graph.components.filter { $0.legacyComponent == legacy }
                    if candidates.isEmpty { candidates = [body] }
                }
                let involved = Set(candidates.compactMap { memberOf[$0.id] })
                let cuts = involved.sorted().flatMap { memberID in
                    (members[memberID]?.cuts ?? []).enumerated().map { (Self.stableHash(memberID), $0.offset, $0.element) }
                }
                let groups = candidates.count > 1 ? Self.partition(geometry, cuts: cuts,
                    bodyPosition: { bodyFrame.simdConvertPosition($0, from: node) },
                    owner: { point, jitter in owner(point, candidates: candidates, jitter: jitter) }) : [:]
                if groups.count > 1 {
                    node.geometry = nil
                    for pieceOwner in groups.keys.sorted() {
                        let section = SCNNode(geometry: groups[pieceOwner])
                        section.name = "\(node.name ?? "mesh").\(pieceOwner)"
                        section.castsShadow = node.castsShadow
                        node.addChildNode(section)
                        install(section, owner: pieceOwner)
                    }
                } else {
                    let singleOwner = groups.keys.first ?? owner(point, candidates: candidates, jitter: { _, _ in 0 })
                    if children.isEmpty {
                        install(node, owner: singleOwner)
                        return
                    }
                    // Bind only this mesh. Descendant motors and propellers
                    // keep their own ownership and must not bend twice.
                    let mesh = SCNNode(geometry: geometry)
                    mesh.name = "\(node.name ?? "mesh").geometry"
                    mesh.castsShadow = node.castsShadow
                    node.geometry = nil
                    node.addChildNode(mesh)
                    install(mesh, owner: singleOwner)
                }
            }
            for child in children { walk(child, inherited: legacy) }
        }
        walk(root, inherited: nil)
    }

    func nodes(for components: Set<String>) -> [SCNNode] {
        entries.filter { components.contains($0.componentID) }.map(\.node)
    }

    func apply(_ graph: VehicleComponentGraph) {
        let transforms = graph.deformationTransforms()
        for entry in entries {
            let deformation = transforms[entry.componentID] ?? matrix_identity_float4x4
            entry.node.simdTransform = simd_inverse(entry.parentInBody) * deformation * entry.parentInBody
            entry.node.isHidden = graph.component(id: entry.componentID)?.isAttached != true
        }
    }

    /// Opens the pieces on both sides of a break: their materials become double-sided so the
    /// torn shell shows its inside instead of vanishing where the surface was cut.
    func exposeFracture(components: Set<String>) {
        for entry in entries where components.contains(entry.componentID) {
            entry.node.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry, geometry.materials.contains(where: { !$0.isDoubleSided }) else { return }
                geometry.materials = geometry.materials.map { material in
                    let copy = (material.copy() as? SCNMaterial) ?? material
                    copy.isDoubleSided = true
                    return copy
                }
            }
        }
    }

    /// FNV-1a of a string: stable across launches, unlike `hashValue`.
    private static func stableHash(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x0000_0100_0000_01b3 }
        return Int(truncatingIfNeeded: hash)
    }

    /// A stable −1...1 per (member, cut, triangle) so both sides of a break agree on where it
    /// runs, and a given aircraft always tears the same way.
    private static func jitter(member: Int, cut: Int, triangle: Int) -> Float {
        var hash = UInt64(bitPattern: Int64(member)) &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(cut &+ 1) &* 0xBF58_476D_1CE4_E5B9
        hash ^= UInt64(triangle &+ 7) &* 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        hash = hash &* 0xD6E8_FEB8_6659_FD93
        hash ^= hash >> 32
        return Float(Double(hash % 20_001) / 10_000.0 - 1.0)
    }

    /// Partition authored triangles while retaining all original vertex streams
    /// (normals, UVs, colours) and material slots. Each triangle is clipped against the
    /// members' station cuts — each cut displaced for that triangle by its own jitter, so the
    /// break runs ragged across the member instead of along a ruled line — and every piece is
    /// then owned by the station interval it lies in. A detached outer wing must not hide the
    /// whole source mesh or produce a duplicate full-span wing.
    private static func partition(_ geometry: SCNGeometry, cuts: [(member: Int, index: Int, cut: MemberCut)],
                                  bodyPosition: (SIMD3<Float>) -> SIMD3<Float>,
                                  owner: (SIMD3<Float>, (Int, Int) -> Float) -> String) -> [String: SCNGeometry] {
        let sources = geometry.sources
        let channels = geometry.geometrySourceChannels?.map(\.intValue) ?? Array(repeating: 0, count: sources.count)
        guard channels.count == sources.count, let positionSlot = sources.firstIndex(where: { $0.semantic == .vertex }),
              let positions = sources.first(where: { $0.semantic == .vertex }),
              sources.allSatisfy({ $0.usesFloatComponents && $0.bytesPerComponent == 4 &&
                  $0.vectorCount > 0 &&
                  $0.dataStride >= $0.componentsPerVector * 4 &&
                  $0.dataOffset + ($0.vectorCount - 1) * $0.dataStride + $0.componentsPerVector * 4 <= $0.data.count }),
              geometry.elements.allSatisfy({ element in element.primitiveType == .triangles &&
                  [1, 2, 4].contains(element.bytesPerIndex) &&
                  element.data.count >= element.primitiveCount * 3 * element.bytesPerIndex * max(1, element.indicesChannelCount) &&
                  channels.allSatisfy { channel in channel >= 0 && channel < max(1, element.indicesChannelCount) } }) else { return [:] }
        func value(_ source: SCNGeometrySource, _ index: UInt32, _ channel: Int) -> Float {
            source.data.withUnsafeBytes { bytes in
                bytes.loadUnaligned(fromByteOffset: source.dataOffset + Int(index) * source.dataStride + channel * 4, as: Float.self)
            }
        }
        func position(_ i: UInt32) -> SIMD3<Float> {
            SIMD3<Float>(value(positions, i, 0), value(positions, i, 1), value(positions, i, 2))
        }
        struct Vertex {
            let a: [UInt32]; let b: [UInt32]; let c: [UInt32]
            let weights: SIMD3<Float>
        }
        var groups: [String: [[Vertex]]] = [:]
        var valid = true
        var triangleSerial = 0
        for (slot, element) in geometry.elements.enumerated() {
            element.data.withUnsafeBytes { bytes in
                func index(_ i: Int, source: Int) -> UInt32 {
                    let channel = channels[source]
                    let address = element.hasInterleavedIndicesChannels
                        ? i * max(1, element.indicesChannelCount) + channel
                        : i + channel * element.primitiveCount * 3
                    let offset = address * element.bytesPerIndex
                    switch element.bytesPerIndex {
                    case 1: return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                    case 2: return UInt32(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    default: return bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                    }
                }
                for face in 0..<element.primitiveCount {
                    triangleSerial += 1
                    let serial = triangleSerial
                    let a = sources.indices.map { index(face * 3, source: $0) }
                    let b = sources.indices.map { index(face * 3 + 1, source: $0) }
                    let c = sources.indices.map { index(face * 3 + 2, source: $0) }
                    guard sources.indices.allSatisfy({ max(a[$0], b[$0], c[$0]) < sources[$0].vectorCount }) else { valid = false; return }
                    let pa = bodyPosition(position(a[positionSlot])), pb = bodyPosition(position(b[positionSlot])), pc = bodyPosition(position(c[positionSlot]))
                    func point(_ w: SIMD3<Float>) -> SIMD3<Float> { pa * w.x + pb * w.y + pc * w.z }
                    let triangleJitter: (Int, Int) -> Float = { member, cut in jitter(member: member, cut: cut, triangle: serial) }
                    var polygons = [[SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]]
                    for (member, cutIndex, cut) in cuts {
                        let offset = cut.offset + cut.jag * triangleJitter(member, cutIndex)
                        let da = simd_dot(pa, cut.normal) - offset, db = simd_dot(pb, cut.normal) - offset
                        let dc = simd_dot(pc, cut.normal) - offset
                        guard min(da, db, dc) < -1e-6, max(da, db, dc) > 1e-6 else { continue }
                        var divided: [[SIMD3<Float>]] = []
                        for polygon in polygons {
                            for sign: Float in [-1, 1] {
                                var clipped: [SIMD3<Float>] = []
                                for i in polygon.indices {
                                    let start = polygon[i], end = polygon[(i + 1) % polygon.count]
                                    let d0 = (simd_dot(point(start), cut.normal) - offset) * sign
                                    let d1 = (simd_dot(point(end), cut.normal) - offset) * sign
                                    if d0 <= 0 { clipped.append(start) }
                                    if (d0 < 0 && d1 > 0) || (d0 > 0 && d1 < 0) {
                                        clipped.append(start + (end - start) * (d0 / (d0 - d1)))
                                    }
                                }
                                if clipped.count >= 3 { divided.append(clipped) }
                            }
                        }
                        polygons = divided
                    }
                    for polygon in polygons {
                        for i in 1..<(polygon.count - 1) {
                            let weights = [polygon[0], polygon[i], polygon[i + 1]]
                            let id = owner(point((weights[0] + weights[1] + weights[2]) / 3), triangleJitter)
                            if groups[id] == nil { groups[id] = Array(repeating: [], count: geometry.elements.count) }
                            groups[id]![slot].append(contentsOf: weights.map { Vertex(a: a, b: b, c: c, weights: $0) })
                        }
                    }
                }
            }
        }
        guard valid, !groups.isEmpty else { return [:] }
        guard groups.count > 1 else { return [groups.keys.first!: geometry] }
        return groups.mapValues { slots in
            let vertices = slots.flatMap { $0 }
            let outputSources = sources.enumerated().map { sourceIndex, source -> SCNGeometrySource in
                var values: [Float] = []
                values.reserveCapacity(vertices.count * source.componentsPerVector)
                for v in vertices {
                    for channel in 0..<source.componentsPerVector {
                        values.append(value(source, v.a[sourceIndex], channel) * v.weights.x +
                            value(source, v.b[sourceIndex], channel) * v.weights.y + value(source, v.c[sourceIndex], channel) * v.weights.z)
                    }
                }
                let data = values.withUnsafeBytes { Data($0) }
                return SCNGeometrySource(data: data, semantic: source.semantic, vectorCount: vertices.count,
                    usesFloatComponents: true, componentsPerVector: source.componentsPerVector,
                    bytesPerComponent: 4, dataOffset: 0, dataStride: source.componentsPerVector * 4)
            }
            var offset: UInt32 = 0
            let elements = slots.map { vertices -> SCNGeometryElement in
                let indices = Array(offset..<(offset + UInt32(vertices.count)))
                offset += UInt32(vertices.count)
                return SCNGeometryElement(indices: indices, primitiveType: .triangles)
            }
            let result = SCNGeometry(sources: outputSources, elements: elements)
            result.materials = geometry.materials
            return result
        }
    }
}

/// Per-component AABB in the aircraft's physics body frame (the flight-root
/// node's space: +Y up, -Z forward, origin at the ground/gear reference —
/// including the legacy chase-camera yaw flip and the ground lift applied by
/// `DroneModelBuilder.wrapVisualModel`). Captured once per visual build; the
/// component graph builder consumes it so physics contact geometry always
/// matches the model actually being rendered (catalog, legacy and workbench
/// builds alike, at the displayed scale).
struct DroneVisualGeometryComponentBox: Hashable {
    let component: DamageComponent
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
}

struct DroneVisualGeometryPropeller: Hashable {
    let center: SIMD3<Float>
    let radius: Float
    /// +1 / -1 blade spin direction (from the visual rig's
    /// `propellerSpinDirections`, index-aligned with the propeller nodes).
    let spinDirection: Float
}

/// One spanwise strip of the rendered wing, body frame: where its leading and trailing
/// edges are and how thick it is. Sampled from the wing meshes' own vertices, so a swept,
/// tapered, cranked or dihedral wing is described as drawn — not as the rectangle around it.
struct DroneVisualGeometryPlanformSlice: Hashable {
    let x0: Float
    let x1: Float
    /// Leading edge (most forward, −Z is the nose) and trailing edge.
    let leadingZ: Float
    let trailingZ: Float
    let lowerY: Float
    let upperY: Float

    var centerX: Float { (x0 + x1) * 0.5 }
    var chord: Float { max(0.001, trailingZ - leadingZ) }
    var depth: Float { max(0.001, upperY - lowerY) }
    var midY: Float { (lowerY + upperY) * 0.5 }
}

struct DroneVisualGeometrySample: Hashable {
    let componentBoxes: [DroneVisualGeometryComponentBox]
    let propellers: [DroneVisualGeometryPropeller]
    let boundsCenter: SIMD3<Float>
    let boundsSize: SIMD3<Float>
    let fpvAnchorPosition: SIMD3<Float>
    let payloadMountPosition: SIMD3<Float>
    /// Spanwise strips of the main wing, sorted by x. Empty when the model has no wing
    /// meshes to sample (procedural fallbacks); the graph then uses the bucket boxes.
    var wingPlanform: [DroneVisualGeometryPlanformSlice] = []
    /// Half-width of the fuselage where the wing meets it — where the exposed wing, and
    /// its root joint, begins. Zero for a flying wing with no separate body.
    var fuselageHalfWidth: Float = 0

    static let empty = DroneVisualGeometrySample(
        componentBoxes: [],
        propellers: [],
        boundsCenter: .zero,
        boundsSize: SIMD3<Float>(repeating: 0.3),
        fpvAnchorPosition: .zero,
        payloadMountPosition: .zero
    )

    func boxes(for component: DamageComponent) -> [DroneVisualGeometryComponentBox] {
        componentBoxes.filter { $0.component == component }
    }

    /// Union AABB of every box mapped to `component`, if any geometry exists.
    func unionBox(for component: DamageComponent) -> DroneVisualGeometryComponentBox? {
        let boxes = boxes(for: component)
        guard !boxes.isEmpty else { return nil }
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        for box in boxes {
            minimum = simd_min(minimum, box.center - box.halfExtents)
            maximum = simd_max(maximum, box.center + box.halfExtents)
        }
        return DroneVisualGeometryComponentBox(
            component: component,
            center: (minimum + maximum) * 0.5,
            halfExtents: simd_max((maximum - minimum) * 0.5, SIMD3<Float>(repeating: 0.005))
        )
    }

    static func capture(from model: DroneVisualModel) -> DroneVisualGeometrySample {
        let bodyFrameNode = model.rootNode

        var boxes: [DroneVisualGeometryComponentBox] = []
        for (component, nodes) in model.componentNodes {
            for node in nodes {
                guard let aabb = accumulateBounds(of: node, in: bodyFrameNode) else { continue }
                boxes.append(
                    DroneVisualGeometryComponentBox(
                        component: component,
                        center: (aabb.min + aabb.max) * 0.5,
                        halfExtents: simd_max((aabb.max - aabb.min) * 0.5, SIMD3<Float>(repeating: 0.005))
                    )
                )
            }
        }

        var propellers: [DroneVisualGeometryPropeller] = []
        for (index, propNode) in model.propellerNodes.enumerated() {
            guard let aabb = accumulateBounds(of: propNode, in: bodyFrameNode) else { continue }
            // ⚠️ The hub is the spin node's own origin, not the centre of the blades'
            // bounding box. A propeller is modelled with its blades frozen at one
            // azimuth, so that box is lopsided: the Hermes 900's pusher reported a
            // centre 81 mm off its own shaft, which is a fact about the pose the artist
            // left it in and not about the aeroplane. The graph places the motor and
            // propeller components there, measures the rotor arm that sets yaw and roll
            // authority from it, and splits motors into quadrants by it — and 81 mm was
            // enough to put a centreline pusher on the left-hand side of an aircraft
            // that has no left-hand engine.
            let hub = bodyFrameNode.simdConvertPosition(.zero, from: propNode)
            let reach = simd_max(aabb.max - hub, hub - aabb.min)
            let spin = index < model.propellerSpinDirections.count
                ? model.propellerSpinDirections[index]
                : (index.isMultiple(of: 2) ? 1.0 : -1.0)
            propellers.append(
                DroneVisualGeometryPropeller(
                    center: hub,
                    radius: max(reach.x, reach.y, reach.z, 0.02),
                    spinDirection: spin >= 0.0 ? 1.0 : -1.0
                )
            )
        }

        var sample = DroneVisualGeometrySample(
            componentBoxes: boxes,
            propellers: propellers,
            boundsCenter: model.visualBoundsCenter,
            boundsSize: model.visualBoundsSize,
            fpvAnchorPosition: bodyFrameNode.simdConvertPosition(.zero, from: model.fpvAnchorNode),
            payloadMountPosition: bodyFrameNode.simdConvertPosition(.zero, from: model.payloadMountNode)
        )
        let wingNodes = (model.componentNodes[.armFL] ?? []) + (model.componentNodes[.armFR] ?? [])
        sample.wingPlanform = planform(of: wingNodes, in: bodyFrameNode)
        sample.fuselageHalfWidth = fuselageHalfWidth(
            core: model.componentNodes[.flightControllerCore] ?? [],
            in: bodyFrameNode,
            planform: sample.wingPlanform
        )
        return sample
    }

    /// Body-frame vertex positions of every mesh under `node`.
    static func vertexPositions(of node: SCNNode, in referenceNode: SCNNode) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        func walk(_ current: SCNNode) {
            if let geometry = current.geometry,
               let source = geometry.sources(for: .vertex).first,
               source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 {
                let transform = referenceNode.simdConvertTransform(matrix_identity_float4x4, from: current)
                source.data.withUnsafeBytes { bytes in
                    for index in 0..<source.vectorCount {
                        let offset = source.dataOffset + index * source.dataStride
                        guard offset + 12 <= bytes.count else { break }
                        let p = SIMD4<Float>(
                            bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                            bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                            bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self),
                            1
                        )
                        let q = transform * p
                        result.append(SIMD3<Float>(q.x, q.y, q.z))
                    }
                }
            }
            for child in current.childNodes { walk(child) }
        }
        walk(node)
        return result
    }

    /// Spanwise strips of the wing meshes. Authored wings are lofted between a few stations,
    /// so their vertices sit on rings and most narrow bins are empty; those are filled by
    /// interpolating the edges between the nearest sampled strips. Depth is capped at a
    /// third of the chord so a winglet or tip fin standing on the tip does not read as a
    /// wing a metre thick.
    private static func planform(of nodes: [SCNNode], in referenceNode: SCNNode) -> [DroneVisualGeometryPlanformSlice] {
        var points: [SIMD3<Float>] = []
        var seen: Set<ObjectIdentifier> = []
        for node in nodes where seen.insert(ObjectIdentifier(node)).inserted {
            // Mapped nodes are leaves or parents of leaves; take only this node's own mesh
            // so a parent and its mapped child are not counted twice.
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first,
                  source.usesFloatComponents, source.bytesPerComponent == 4, source.componentsPerVector >= 3 else {
                continue
            }
            let transform = referenceNode.simdConvertTransform(matrix_identity_float4x4, from: node)
            source.data.withUnsafeBytes { bytes in
                for index in 0..<source.vectorCount {
                    let offset = source.dataOffset + index * source.dataStride
                    guard offset + 12 <= bytes.count else { break }
                    let q = transform * SIMD4<Float>(
                        bytes.loadUnaligned(fromByteOffset: offset, as: Float.self),
                        bytes.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                        bytes.loadUnaligned(fromByteOffset: offset + 8, as: Float.self), 1)
                    points.append(SIMD3<Float>(q.x, q.y, q.z))
                }
            }
        }
        guard points.count >= 8 else { return [] }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        guard maxX - minX > 0.01 else { return [] }
        let binCount = 96
        let width = (maxX - minX) / Float(binCount)
        var lead = [Float](repeating: .greatestFiniteMagnitude, count: binCount)
        var trail = [Float](repeating: -.greatestFiniteMagnitude, count: binCount)
        var low = [Float](repeating: .greatestFiniteMagnitude, count: binCount)
        var high = [Float](repeating: -.greatestFiniteMagnitude, count: binCount)
        for p in points {
            let bin = min(binCount - 1, max(0, Int((p.x - minX) / width)))
            lead[bin] = min(lead[bin], p.z); trail[bin] = max(trail[bin], p.z)
            low[bin] = min(low[bin], p.y); high[bin] = max(high[bin], p.y)
        }
        let filled = (0..<binCount).filter { lead[$0] < trail[$0] }
        guard filled.count >= 2 else { return [] }
        func interpolate(_ values: inout [Float]) {
            for bin in 0..<binCount where !filled.contains(bin) {
                let before = filled.last { $0 < bin }, after = filled.first { $0 > bin }
                switch (before, after) {
                case let (b?, a?):
                    let t = Float(bin - b) / Float(a - b)
                    values[bin] = values[b] + (values[a] - values[b]) * t
                case let (b?, nil): values[bin] = values[b]
                case let (nil, a?): values[bin] = values[a]
                default: break
                }
            }
        }
        interpolate(&lead); interpolate(&trail); interpolate(&low); interpolate(&high)
        // A winglet or tip fin stands on the tip and inflates its bins' height. Real wings
        // keep a roughly constant thickness ratio, so each strip is capped at 1.5× the
        // wing's median t/c.
        let ratios = (0..<binCount).map { (high[$0] - low[$0]) / max(0.001, trail[$0] - lead[$0]) }.sorted()
        let medianRatio = min(0.33, max(0.02, ratios[ratios.count / 2]))
        return (0..<binCount).map { bin in
            let chord = max(0.001, trail[bin] - lead[bin])
            let mid = (low[bin] + high[bin]) * 0.5
            let depth = min(max(0.001, high[bin] - low[bin]), chord * medianRatio * 1.5)
            return DroneVisualGeometryPlanformSlice(
                x0: minX + Float(bin) * width, x1: minX + Float(bin + 1) * width,
                leadingZ: lead[bin], trailingZ: trail[bin],
                lowerY: mid - depth * 0.5, upperY: mid + depth * 0.5)
        }
    }

    /// Width of the body at the wing: the widest core mesh named like a fuselage/body that
    /// overlaps the wing chord. A flying wing has none and returns zero.
    private static func fuselageHalfWidth(
        core: [SCNNode],
        in referenceNode: SCNNode,
        planform: [DroneVisualGeometryPlanformSlice]
    ) -> Float {
        guard !planform.isEmpty else { return 0 }
        let chordLow = planform.map(\.leadingZ).min()!, chordHigh = planform.map(\.trailingZ).max()!
        let halfSpan = (planform.last!.x1 - planform.first!.x0) * 0.5
        let centerX = (planform.last!.x1 + planform.first!.x0) * 0.5
        var best: Float = 0
        for node in core {
            let name = (node.name ?? "").lowercased()
            guard ["fuselage", "body", "hull", "pod", "centre", "center", "nacelle"].contains(where: { name.contains($0) }),
                  let bounds = accumulateBounds(of: node, in: referenceNode),
                  bounds.max.z > chordLow, bounds.min.z < chordHigh else { continue }
            best = max(best, max(abs(bounds.max.x - centerX), abs(bounds.min.x - centerX)))
        }
        return min(best, halfSpan * 0.35)
    }

    private static func accumulateBounds(
        of node: SCNNode,
        in referenceNode: SCNNode
    ) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var minimum = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var found = false
        accumulate(node: node, referenceNode: referenceNode, minimum: &minimum, maximum: &maximum, found: &found)
        return found ? (minimum, maximum) : nil
    }

    private static func accumulate(
        node: SCNNode,
        referenceNode: SCNNode,
        minimum: inout SIMD3<Float>,
        maximum: inout SIMD3<Float>,
        found: inout Bool
    ) {
        if node.geometry != nil {
            let box = node.boundingBox
            let localMin = SIMD3<Float>(Float(box.min.x), Float(box.min.y), Float(box.min.z))
            let localMax = SIMD3<Float>(Float(box.max.x), Float(box.max.y), Float(box.max.z))
            for corner in corners(min: localMin, max: localMax) {
                let converted = referenceNode.simdConvertPosition(corner, from: node)
                minimum = simd_min(minimum, converted)
                maximum = simd_max(maximum, converted)
            }
            found = true
        }
        for child in node.childNodes {
            accumulate(node: child, referenceNode: referenceNode, minimum: &minimum, maximum: &maximum, found: &found)
        }
    }

    private static func corners(min: SIMD3<Float>, max: SIMD3<Float>) -> [SIMD3<Float>] {
        [
            SIMD3<Float>(min.x, min.y, min.z),
            SIMD3<Float>(min.x, min.y, max.z),
            SIMD3<Float>(min.x, max.y, min.z),
            SIMD3<Float>(min.x, max.y, max.z),
            SIMD3<Float>(max.x, min.y, min.z),
            SIMD3<Float>(max.x, min.y, max.z),
            SIMD3<Float>(max.x, max.y, min.z),
            SIMD3<Float>(max.x, max.y, max.z)
        ]
    }
}
