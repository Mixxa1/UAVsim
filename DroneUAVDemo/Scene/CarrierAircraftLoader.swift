import Foundation
import SceneKit
import simd

/// Loads a carrier aircraft's model and prepares it for the scene.
///
/// Three downloaded assets, three different sets of assumptions about units, orientation
/// and node naming — so nothing about the file is trusted. The model is measured, scaled
/// to the aircraft's real length, re-centred on its own bounding box and turned to face
/// the scene's convention. That is more work than reading a scale factor out of the file,
/// and it is the only approach that survives someone replacing one of these assets.
///
/// Model credits (all Creative Commons Attribution 4.0):
///  - "C130" by manilov.ap — https://skfb.ly/YQ97
///  - "Boeing B-52 Stratofortress" by bohmerang — https://skfb.ly/oLo8p
enum CarrierAircraftLoader {
    /// A prepared carrier, with the parts the runtime needs to animate held separately so
    /// it does not have to search the graph every frame.
    struct Prepared {
        let rootNode: SCNNode
        /// Propeller or fan nodes, spun about their own axis each frame. Empty for a jet
        /// whose fans are buried inside nacelles and invisible anyway.
        let propellerNodes: [SCNNode]
        /// The pylon or bay door that swings open at release.
        let bayNode: SCNNode?
    }

    private static var cache: [CarrierAircraftKind: SCNNode] = [:]

    static func prepare(kind: CarrierAircraftKind) -> Prepared? {
        guard let template = loadTemplate(kind: kind) else { return nil }
        let root = template.clone()
        root.name = "carrier.\(kind.rawValue)"

        // No synthesised propellers. The C-130 had four, because its asset's blades are part
        // of one merged mesh with no hub to turn, and four flat discs bolted on where the
        // real ones are looked like four black crosses stuck to an aeroplane. The model's own
        // still propellers are the better picture.
        let propellers: [SCNNode] = []

        let bay = makePylon(kind: kind)
        root.addChildNode(bay)

        return Prepared(rootNode: root, propellerNodes: propellers, bayNode: bay)
    }

    private static func loadTemplate(kind: CarrierAircraftKind) -> SCNNode? {
        if let cached = cache[kind] { return cached }
        guard let url = Bundle.main.url(forResource: kind.resourceName, withExtension: "usdz"),
              let scene = try? SCNScene(url: url, options: [
                  .checkConsistency: false,
                  .preserveOriginalTopology: false
              ]) else {
            // A missing asset is not worth stopping a flight over: the release still
            // happens, the operator simply does not see what dropped them.
            print("[Carrier] \(kind.resourceName).usdz unavailable; releasing without a visible carrier")
            return nil
        }

        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            container.addChildNode(child)
        }

        // Measure the aeroplane, then work out which way it is facing.
        //
        // Both from the vertices, not from bounding boxes. `SCNNode.boundingBox` describes a
        // node's own geometry, and this node has none — every triangle is in a child; and a
        // box tells you nothing about *orientation*, which turned out to be the thing that
        // actually needed knowing.
        let points = sampledVertices(of: container)
        guard points.count >= 64 else {
            print("[Carrier] \(kind.resourceName).usdz has no readable geometry; placing unscaled")
            cache[kind] = container
            return container
        }
        var minimum = points[0]
        var maximum = points[0]
        for point in points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let centre = (minimum + maximum) * 0.5

        // Which way is the nose? Find the fin.
        //
        // An aeroplane's tallest structure is its vertical stabiliser, and the stabiliser is
        // at the tail. That is the one landmark that survives a mesh with no node names, no
        // export convention and no agreement about which axis is forward — and it gives the
        // heading directly, as the horizontal direction from the aircraft's centre to the
        // fin, reversed.
        //
        // This replaces a pair of hand-measured per-asset constants, and it replaces them
        // because those constants could not express the answer. The C-130 asset is not
        // axis-aligned at all: its fuselage lies 48 degrees off, so no quarter-turn could
        // ever have straightened it, which is exactly why two attempts at "rotate it by 90
        // degrees the other way" both produced an aeroplane flying sideways. Measuring an
        // angle instead of choosing between four of them is what makes that case expressible.
        let topCount = max(24, points.count / 100)
        let tallest = points.sorted { $0.y > $1.y }.prefix(topCount)
        var finSum = SIMD3<Float>()
        for point in tallest { finSum += point }
        let fin = finSum / Float(tallest.count)
        let towardsTail = SIMD2<Float>(fin.x - centre.x, fin.z - centre.z)
        let tailDistance = simd_length(towardsTail)
        // A fin sitting on the centre means this is not an aeroplane shape, or the tallest
        // thing on it is not the fin. Leave such a model alone rather than spinning it by an
        // angle derived from rounding error.
        let modelYaw: Float
        if tailDistance > 1.0e-3 {
            let nose = -towardsTail / tailDistance
            // Yaw t maps a direction onto +Z when z' = -x sin t + z cos t = 1.
            modelYaw = atan2(-nose.x, nose.y)
        } else {
            modelYaw = 0.0
        }

        // Now measure the aircraft in its *corrected* frame, so the length really is the
        // fuselage and the span really is the wings. Scaling against the raw box is what made
        // a C-130 a quarter too small: on a transport the longest raw dimension is the span.
        let cosYaw = cos(modelYaw)
        let sinYaw = sin(modelYaw)
        var alignedMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var alignedMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in points {
            let rotated = SIMD3<Float>(
                point.x * cosYaw + point.z * sinYaw,
                point.y,
                -point.x * sinYaw + point.z * cosYaw
            )
            alignedMin = simd_min(alignedMin, rotated)
            alignedMax = simd_max(alignedMax, rotated)
        }
        let aligned = alignedMax - alignedMin
        // Centred on the bounding box, including sideways.
        //
        // Sideways deserves a word, because the obvious alternative is wrong. The fuselage
        // axis is a better *datum* than the box — the fin sits on it by construction — and
        // centring on it was tried. On a symmetric model the two agree exactly: the B-52's
        // box centre, its fin and its fuselage ridge all land on the same value to within
        // rounding, and its half-spans come out 27.8 m either side.
        //
        // The C-130 asset is not symmetric. Measured about its own fuselage line its wings
        // differ by a metre and a half, so no datum can put both the body and the silhouette
        // in the middle of the frame. Centring on the fuselage leaves the outline visibly
        // heavier on one side, which is what the eye actually reads and what an operator
        // sees as "not centred". Centring on the box splits the asset's asymmetry evenly and
        // leaves the body under a metre off centre in a forty-metre span, which nobody can
        // see. The box wins on the thing being judged.
        let alignedCentre = (alignedMin + alignedMax) * 0.5
        let scale = kind.lengthMeters / max(0.001, aligned.z)

        // Logged once per carrier, and worth the line: the span and the height are *not*
        // constrained by anything above — only the length is forced. If they come out near
        // the real aircraft's, the orientation was found correctly, and if they do not, it
        // was not. That is a check the code performs on itself every time it loads a model.
        print(String(
            format: "[Carrier] %@: yaw %+.1f deg, length %.1f m, span %.1f m, height %.1f m",
            kind.resourceName,
            modelYaw * 180.0 / .pi,
            aligned.z * scale,
            aligned.x * scale,
            aligned.y * scale
        ))

        // Three nested nodes, and the nesting is the point.
        //
        // The re-centring translation is expressed in the model's own axes, and the heading
        // correction changes what those axes mean. Putting both on one node applies them in
        // SceneKit's order — scale, then rotate, then translate — so the offset lands along
        // the wrong axis. Rotating a parent instead puts the translation inside the rotated
        // frame, where it was computed.
        let scaled = SCNNode()
        let yaw = SCNNode()
        scaled.addChildNode(yaw)
        yaw.addChildNode(container)

        container.scale = SCNVector3(scale, scale, scale)
        // Centred *after* the turn, not before it.
        //
        // Rotating a model about the origin moves the middle of its bounding box unless the
        // box happens to be symmetric about that origin — and for a model lying 48 degrees
        // off axis it is not. Subtracting the raw centre first and rotating afterwards left
        // the aeroplane a little off the middle of the frame, which is exactly the residual
        // the operator could see. The translation therefore goes on the node that carries the
        // rotation, so it is applied in the corrected frame and cancels the corrected centre.
        yaw.eulerAngles = SCNVector3(0.0, modelYaw, 0.0)
        yaw.position = SCNVector3(
            -alignedCentre.x * scale,
            -alignedCentre.y * scale,
            -alignedCentre.z * scale
        )

        cache[kind] = scaled
        return scaled
    }

    /// Every vertex under a node, in that node's own space.
    ///
    /// Read from the geometry sources rather than inferred from bounding boxes. A box gives
    /// extents and nothing else; orientation, and the position of a fin inside a mesh, are
    /// questions only the vertices can answer. Twenty thousand points per carrier, read once
    /// and cached with the prepared model.
    private static func sampledVertices(of node: SCNNode) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        func visit(_ current: SCNNode, transform: simd_float4x4) {
            let local = simd_mul(transform, current.simdTransform)
            if let geometry = current.geometry {
                for source in geometry.sources(for: .vertex) {
                    let stride = source.dataStride
                    let offset = source.dataOffset
                    let count = source.vectorCount
                    guard source.componentsPerVector >= 3,
                          source.bytesPerComponent == MemoryLayout<Float>.size else {
                        continue
                    }
                    source.data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        for index in 0..<count {
                            let component = base.advanced(by: offset + index * stride)
                                .assumingMemoryBound(to: Float.self)
                            let world = simd_mul(
                                local,
                                SIMD4<Float>(component[0], component[1], component[2], 1.0)
                            )
                            points.append(SIMD3<Float>(world.x, world.y, world.z))
                        }
                    }
                }
            }
            for child in current.childNodes {
                visit(child, transform: local)
            }
        }
        for child in node.childNodes {
            visit(child, transform: matrix_identity_float4x4)
        }
        return points
    }

    /// The pylon the UAV hangs from, and the arm that swings it clear at release.
    private static func makePylon(kind: CarrierAircraftKind) -> SCNNode {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.22, alpha: 1.0)
        material.lightingModel = .physicallyBased
        material.roughness.contents = NSNumber(value: 0.5)

        let pylon = SCNNode()
        pylon.name = "carrier_pylon"
        let offset = kind.pylonOffset
        pylon.position = SCNVector3(offset.x, offset.y * 0.45, offset.z)

        let strut = SCNBox(
            width: 0.35,
            height: CGFloat(abs(offset.y) * 0.9),
            length: 1.6,
            chamferRadius: 0.06
        )
        strut.materials = [material]
        pylon.geometry = strut

        // The shackle: a short arm that rotates down and away as the round is released, so
        // the release reads as a mechanism letting go rather than the aircraft simply
        // teleporting off the wing.
        let shackle = SCNNode(geometry: SCNBox(width: 0.28, height: 0.5, length: 0.9, chamferRadius: 0.04))
        shackle.geometry?.materials = [material]
        shackle.name = "carrier_shackle"
        shackle.position = SCNVector3(0.0, CGFloat(-abs(offset.y) * 0.45), 0.0)
        pylon.addChildNode(shackle)
        return pylon
    }
}
