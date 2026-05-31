import SceneKit
import simd

enum DesignAssetNodeFactory {

    static func makeNode(
        for asset: DesignAsset,
        includeAttachmentPoints: Bool = true,
        selectedAttachmentPointID: UUID? = nil,
        selectedSketchLineID: UUID? = nil,
        selectedSketchEntityID: UUID? = nil,
        selectedSketchEntityIDs: Set<UUID> = [],
        showSketchPoints: Bool = true,
        showConstraintGlyphs: Bool = true,
        hoveredFaceID: UUID? = nil,
        selectedFaceID: UUID? = nil
    ) -> SCNNode {
        let node = SCNNode()
        node.name = "asset_\(asset.id.uuidString)"

        if case let .sketch2D(parameters) = asset.kind {
            let effectiveIDs = selectedSketchEntityIDs.isEmpty
                ? Set([selectedSketchEntityID, selectedSketchLineID].compactMap { $0 })
                : selectedSketchEntityIDs
            node.addChildNode(makeSketchNode(
                parameters,
                selectedLineID: selectedSketchLineID,
                selectedEntityIDs: effectiveIDs,
                showPoints: showSketchPoints,
                showConstraintGlyphs: showConstraintGlyphs
            ))
        } else {
            let geometry = makeGeometry(for: asset.kind)
            let material = makeMaterial(for: asset.kind, designMaterial: asset.material)
            geometry.firstMaterial = material

            let bodyNode = SCNNode(geometry: geometry)
            bodyNode.name = "cad.body.mesh.\(asset.id.uuidString)"
            node.addChildNode(bodyNode)
            if case let .extrudedSolid(parameters) = asset.kind {
                for face in parameters.faces {
                    node.addChildNode(
                        makeFaceInteractionNode(
                            face,
                            hovered: face.id == hoveredFaceID,
                            selected: face.id == selectedFaceID
                        )
                    )
                }
            }
        }

        if includeAttachmentPoints {
            for ap in asset.attachmentPoints {
                let marker = makeAttachmentMarker(
                    point: ap,
                    selected: ap.id == selectedAttachmentPointID
                )
                marker.name = "ap_\(ap.id.uuidString)"
                marker.position = SCNVector3(Float(ap.localX), Float(ap.localY), Float(ap.localZ))
                marker.eulerAngles = SCNVector3(
                    Float(ap.localRotation.x),
                    Float(ap.localRotation.y),
                    Float(ap.localRotation.z)
                )
                node.addChildNode(marker)
            }
        }

        return node
    }

    static func makeGeometry(for kind: DesignAssetKind) -> SCNGeometry {
        switch kind {
        case let .basicWing(p):
            return makeWingGeometry(p)
        case let .framePlate(p):
            return SCNBox(
                width: CGFloat(p.widthMeters),
                height: CGFloat(p.thicknessMeters),
                length: CGFloat(p.depthMeters),
                chamferRadius: 0.001
            )
        case let .beam(p):
            // Beam lies along X (length), Y (height), Z (width)
            return SCNBox(
                width: CGFloat(p.lengthMeters),
                height: CGFloat(p.heightMeters),
                length: CGFloat(p.widthMeters),
                chamferRadius: 0.001
            )
        case let .tube(p):
            // Tube lies along X axis; SCNCylinder is along Y by default — rotate in makeNode
            let cyl = SCNCylinder(radius: CGFloat(p.outerRadiusMeters), height: CGFloat(p.lengthMeters))
            cyl.radialSegmentCount = 24
            return cyl
        case let .mountBracket(p):
            return SCNBox(
                width: CGFloat(p.plateWidthMeters),
                height: CGFloat(p.plateThicknessMeters + p.armLengthMeters),
                length: CGFloat(p.plateDepthMeters),
                chamferRadius: 0.001
            )
        case let .payloadBox(p):
            return SCNBox(
                width: CGFloat(p.widthMeters),
                height: CGFloat(p.heightMeters),
                length: CGFloat(p.depthMeters),
                chamferRadius: 0.003
            )
        case .sketch2D:
            return SCNBox(width: 0.001, height: 0.001, length: 0.001, chamferRadius: 0)
        case let .extrudedSolid(p):
            return makeExtrudedSolidGeometry(p)
        }
    }

    // MARK: Wing geometry
    // CAD convention: X=span, Y=thickness, Z=chord
    // Full symmetric wing: root at X=0, right tip at X=+halfSpan, left tip at X=-halfSpan
    // Sweep moves tip leading edge in +Z; dihedral lifts tip in +Y
    private static func makeWingGeometry(_ p: BasicWingParameters) -> SCNGeometry {
        let hs = Float(p.spanMeters / 2)
        let rc = Float(p.rootChordMeters)
        let tc = Float(p.tipChordMeters)
        let ht = Float(p.thicknessMeters / 2)
        let sw = Float(p.sweepDegrees * .pi / 180.0)
        let di = Float(p.dihedralDegrees * .pi / 180.0)

        let dz = hs * tan(sw)   // tip LE Z-offset from root LE
        let dy = hs * tan(di)   // tip Y-lift from dihedral

        // 12 vertices: indices 0-3 = root, 4-7 = right tip, 8-11 = left tip
        // At root (X=0):   lower-LE(0), lower-TE(1), upper-LE(2), upper-TE(3)
        // At right (X=+hs): lower-LE(4), lower-TE(5), upper-LE(6), upper-TE(7)
        // At left  (X=-hs): lower-LE(8), lower-TE(9), upper-LE(10), upper-TE(11)
        let v: [SCNVector3] = [
            SCNVector3(0,    -ht,        0),          // 0 root lower LE
            SCNVector3(0,    -ht,        rc),          // 1 root lower TE
            SCNVector3(0,     ht,        0),           // 2 root upper LE
            SCNVector3(0,     ht,        rc),          // 3 root upper TE
            SCNVector3( hs,  dy - ht,   dz),          // 4 right lower LE
            SCNVector3( hs,  dy - ht,   dz + tc),     // 5 right lower TE
            SCNVector3( hs,  dy + ht,   dz),          // 6 right upper LE
            SCNVector3( hs,  dy + ht,   dz + tc),     // 7 right upper TE
            SCNVector3(-hs,  dy - ht,   dz),          // 8 left  lower LE
            SCNVector3(-hs,  dy - ht,   dz + tc),     // 9 left  lower TE
            SCNVector3(-hs,  dy + ht,   dz),          // 10 left upper LE
            SCNVector3(-hs,  dy + ht,   dz + tc),     // 11 left upper TE
        ]

        // Triangles — material is double-sided so winding is for reference only
        let idx: [Int32] = [
            // Right half — upper surface
            2, 6, 7,   2, 7, 3,
            // Right half — lower surface
            0, 5, 4,   0, 1, 5,
            // Right half — leading edge
            0, 6, 4,   0, 2, 6,
            // Right half — trailing edge
            1, 7, 5,   1, 3, 7,
            // Right tip cap
            4, 7, 6,   4, 5, 7,

            // Left half — upper surface
            2, 3, 11,  2, 11, 10,
            // Left half — lower surface
            0, 8, 9,   0, 9, 1,
            // Left half — leading edge
            0, 10, 8,  0, 2, 10,
            // Left half — trailing edge
            1, 9, 11,  1, 11, 3,
            // Left tip cap
            8, 10, 11, 8, 11, 9,

            // Root cross-section cap
            0, 2, 3,   0, 3, 1,
        ]

        let src = SCNGeometrySource(vertices: v)
        let el  = SCNGeometryElement(indices: idx, primitiveType: .triangles)
        return SCNGeometry(sources: [src], elements: [el])
    }

    // MARK: Extruded Solid geometry

    private static func makeExtrudedSolidGeometry(_ p: ExtrudedSolidParameters) -> SCNGeometry {
        if let kernelVisualMesh = p.kernelVisualMesh,
           let geometry = makeKernelSolidGeometry(kernelVisualMesh) {
            return geometry
        }

        let pts = p.profilePoints
        let n = pts.count
        guard n >= 3 else {
            return SCNBox(width: 0.05, height: 0.05, length: 0.05, chamferRadius: 0)
        }

        if !p.boxBlindCutFeatures.isEmpty,
           let geometry = makeBoxBlindCutGeometry(p) {
            return geometry
        }

        let (frontOff, backOff) = p.direction.offsets(depth: p.depthMeters)
        let normal = normalVector(for: p.sourceReference)
        let axes = axesForSketchReference(p.sourceReference)

        // flipFront: used ONLY inside outerWallNorm/innerWallNorm to choose which side of an
        // edge is "outward". Based purely on UV-space signed area (CW → flip side).
        let flipFront = p.signedAreaMeters2 < 0

        // XZ and YZ canonical planes have a left-handed UV basis: axes.u × axes.v = −normal.
        // A "CCW" polygon in UV actually produces CW triangles in 3D, so SceneKit treats every
        // outward-facing surface as a back-face and negates the provided vertex normals for
        // lighting → faces appear dark → body looks hollow.
        // flipWinding corrects the index order for all triangle primitives (caps, walls, holes)
        // so that outward-facing polygons always appear CCW in screen-space to SceneKit.
        let basisIsLeftHanded = axes.u.cross(axes.v).dot(normal) < -0.5
        let flipWinding = basisIsLeftHanded != flipFront

        func worldVert(_ pt: SketchPoint2D, offset: Double) -> SCNVector3 {
            let v = sketchPointToWorld(pt, reference: p.sourceReference) + normal * offset
            return SCNVector3(Float(v.x), Float(v.y), Float(v.z))
        }

        let fnFront = SCNVector3(Float(normal.x), Float(normal.y), Float(normal.z))
        let fnBack  = SCNVector3(-Float(normal.x), -Float(normal.y), -Float(normal.z))

        // Outward normal for outer side wall edge i→j (direction-only; winding uses flipWinding).
        func outerWallNorm(_ i: Int, _ j: Int, _ poly: [SketchPoint2D]) -> SCNVector3 {
            let du = poly[j].u - poly[i].u
            let dv = poly[j].v - poly[i].v
            let (nu, nv): (Double, Double) = flipFront ? (-dv, du) : (dv, -du)
            let n3 = (axes.u * nu + axes.v * nv).normalized(fallback: normal)
            return SCNVector3(Float(n3.x), Float(n3.y), Float(n3.z))
        }

        // Inward normal for inner cylinder wall edge i→j (direction-only; winding uses flipHoleWinding).
        func innerWallNorm(_ i: Int, _ j: Int, _ hole: [SketchPoint2D], _ hf: Bool) -> SCNVector3 {
            let du = hole[j].u - hole[i].u
            let dv = hole[j].v - hole[i].v
            let (nu, nv): (Double, Double) = hf ? (-dv, du) : (dv, -du)
            let n3 = (axes.u * nu + axes.v * nv).normalized(fallback: normal)
            return SCNVector3(Float(n3.x), Float(n3.y), Float(n3.z))
        }

        var allVerts: [SCNVector3] = []
        var allNorms: [SCNVector3] = []
        var indices: [Int32] = []

        if p.holes.isEmpty && p.cutFeatures.isEmpty {
            // Front cap
            let fcBase = Int32(allVerts.count)
            allVerts += pts.map { worldVert($0, offset: frontOff) }
            allNorms += Array(repeating: fnFront, count: n)
            indices += triangulateFan(vertexCount: n, vertexOffset: fcBase, reversed: flipWinding)

            // Back cap
            let bcBase = Int32(allVerts.count)
            allVerts += pts.map { worldVert($0, offset: backOff) }
            allNorms += Array(repeating: fnBack, count: n)
            indices += triangulateFan(vertexCount: n, vertexOffset: bcBase, reversed: !flipWinding)

            // Side walls — 4 dedicated vertices per edge, hard-edge outward normal per face
            for i in 0..<n {
                let j = (i + 1) % n
                let wallN = outerWallNorm(i, j, pts)
                let swBase = Int32(allVerts.count)
                allVerts += [
                    worldVert(pts[i], offset: frontOff),
                    worldVert(pts[j], offset: frontOff),
                    worldVert(pts[i], offset: backOff),
                    worldVert(pts[j], offset: backOff),
                ]
                allNorms += [wallN, wallN, wallN, wallN]
                let f0 = swBase, f1 = swBase + 1, b0 = swBase + 2, b1 = swBase + 3
                indices += flipWinding ? [f0, f1, b1, f0, b1, b0] : [f0, b1, f1, f0, b0, b1]
            }
        } else if p.cutFeatures.isEmpty {
            // Per-hole depths: fall back to full body depth (through cut) for missing entries.
            let bodyDepth = p.depthMeters
            let resolvedHoleDepths: [Double] = {
                var d = p.holeDepths
                while d.count < p.holes.count { d.append(bodyDepth) }
                return d
            }()

            let depthSign = frontOff > backOff ? 1.0 : -1.0
            let holeBackOffsets: [Double] = resolvedHoleDepths.enumerated().map { _, depth in
                let clampedDepth = min(max(depth, 0), bodyDepth)
                return frontOff - depthSign * clampedDepth
            }
            let isThrough: [Bool] = holeBackOffsets.map { abs($0 - backOff) < 1e-9 }

            // Front cap with holes (ear-clip merged polygon)
            let mergedFront = mergePolygonWithHoles(outer: pts, holes: p.holes)
            let ffBase = Int32(allVerts.count)
            allVerts += mergedFront.map { worldVert($0, offset: frontOff) }
            allNorms += Array(repeating: fnFront, count: mergedFront.count)
            for (ia, ib, ic) in earClipTriangulate(mergedFront) {
                let a = ffBase + Int32(ia), b = ffBase + Int32(ib), c = ffBase + Int32(ic)
                indices += flipWinding ? [a, c, b] : [a, b, c]
            }

            // Back cap — solid or merged with through-holes
            let throughProfiles = p.holes.indices.compactMap { isThrough[$0] ? p.holes[$0] : nil }
            if throughProfiles.isEmpty {
                let bfBase = Int32(allVerts.count)
                allVerts += pts.map { worldVert($0, offset: backOff) }
                allNorms += Array(repeating: fnBack, count: n)
                indices += triangulateFan(vertexCount: n, vertexOffset: bfBase, reversed: !flipWinding)
            } else {
                let mergedBack = mergePolygonWithHoles(outer: pts, holes: throughProfiles)
                let bfBase = Int32(allVerts.count)
                allVerts += mergedBack.map { worldVert($0, offset: backOff) }
                allNorms += Array(repeating: fnBack, count: mergedBack.count)
                for (ia, ib, ic) in earClipTriangulate(mergedBack) {
                    let a = bfBase + Int32(ia), b = bfBase + Int32(ib), c = bfBase + Int32(ic)
                    indices += flipWinding ? [a, b, c] : [a, c, b]
                }
            }

            // Outer side walls
            for i in 0..<n {
                let j = (i + 1) % n
                let wallN = outerWallNorm(i, j, pts)
                let swBase = Int32(allVerts.count)
                allVerts += [
                    worldVert(pts[i], offset: frontOff),
                    worldVert(pts[j], offset: frontOff),
                    worldVert(pts[i], offset: backOff),
                    worldVert(pts[j], offset: backOff),
                ]
                allNorms += [wallN, wallN, wallN, wallN]
                let f0 = swBase, f1 = swBase + 1, b0 = swBase + 2, b1 = swBase + 3
                indices += flipWinding ? [f0, f1, b1, f0, b1, b0] : [f0, b1, f1, f0, b0, b1]
            }

            // Per-hole: inner cylinder walls (smooth Gouraud) + optional bottom cap
            for (hIdx, hole) in p.holes.enumerated() {
                let hn = hole.count
                guard hn >= 3 else { continue }
                let hBack = holeBackOffsets[hIdx]
                let holeFlip = DesignSketch.polygonSignedAreaMeters2(hole) > 0
                // Same left-handed correction for hole winding.
                let flipHoleWinding = basisIsLeftHanded != holeFlip

                let holeNorms: [SCNVector3] = (0..<hn).map { idx in
                    let prev = (idx + hn - 1) % hn
                    let next = (idx + 1) % hn
                    let n0 = innerWallNorm(prev, idx, hole, holeFlip)
                    let n1 = innerWallNorm(idx, next, hole, holeFlip)
                    let ax = (Double(n0.x) + Double(n1.x)) * 0.5
                    let ay = (Double(n0.y) + Double(n1.y)) * 0.5
                    let az = (Double(n0.z) + Double(n1.z)) * 0.5
                    let len = sqrt(ax*ax + ay*ay + az*az)
                    return len < 1e-9 ? n0 : SCNVector3(Float(ax/len), Float(ay/len), Float(az/len))
                }

                let hfBase = Int32(allVerts.count)
                allVerts += hole.map { worldVert($0, offset: frontOff) }
                allNorms += holeNorms

                let hbBase = Int32(allVerts.count)
                allVerts += hole.map { worldVert($0, offset: hBack) }
                allNorms += holeNorms

                for i in 0..<hn {
                    let j = (i + 1) % hn
                    let f0 = hfBase + Int32(i), f1 = hfBase + Int32(j)
                    let b0 = hbBase + Int32(i), b1 = hbBase + Int32(j)
                    indices += flipHoleWinding ? [f0, f1, b1, f0, b1, b0] : [f1, f0, b0, f1, b0, b1]
                }

                if !isThrough[hIdx] {
                    let cbBase = Int32(allVerts.count)
                    allVerts += hole.map { worldVert($0, offset: hBack) }
                    allNorms += Array(repeating: fnFront, count: hn)
                    // Hole bottom cap faces toward frontOff (pocket opening). Corrected for basis handedness.
                    let capReversed = basisIsLeftHanded != (holeFlip != (depthSign > 0))
                    indices += triangulateFan(vertexCount: hn, vertexOffset: cbBase,
                                             reversed: capReversed)
                }
            }
        } else {
            let bodyMinOffset = min(frontOff, backOff)
            let bodyMaxOffset = max(frontOff, backOff)

            func clampedOffset(_ value: Double) -> Double {
                min(max(value, bodyMinOffset), bodyMaxOffset)
            }

            let depthSign = frontOff > backOff ? 1.0 : -1.0
            let legacyFeatures: [ExtrudedSolidCutFeature] = zip(p.holes, p.resolvedLegacyHoleDepths()).map { hole, depth in
                ExtrudedSolidCutFeature(
                    id: UUID(),
                    profilePoints: hole,
                    startOffsetMeters: frontOff,
                    endOffsetMeters: frontOff - depthSign * min(max(depth, 0), p.depthMeters),
                    sourceSketchID: p.sourceSketchID,
                    sourceSketchName: p.sourceSketchName,
                    selectedProfileID: UUID(),
                    depthMode: abs(depth - p.depthMeters) < 1e-7 ? .throughAll : .distance,
                    direction: p.direction
                )
            }
            let cutFeatures = (legacyFeatures + p.cutFeatures).compactMap { feature -> ExtrudedSolidCutFeature? in
                let start = clampedOffset(feature.startOffsetMeters)
                let end = clampedOffset(feature.endOffsetMeters)
                guard feature.profilePoints.count >= 3,
                      abs(end - start) > 1e-7 else { return nil }
                var copy = feature
                copy.startOffsetMeters = start
                copy.endOffsetMeters = end
                return copy
            }

            func profilesOpening(at capOffset: Double) -> [[SketchPoint2D]] {
                cutFeatures.compactMap { feature in
                    let start = feature.startOffsetMeters
                    let end = feature.endOffsetMeters
                    let includesCap = abs(start - capOffset) < 1e-7 || abs(end - capOffset) < 1e-7
                    return includesCap ? feature.profilePoints : nil
                }
            }

            func appendCap(offset: Double, normal: SCNVector3, holes: [[SketchPoint2D]], reversed: Bool) {
                if holes.isEmpty {
                    let base = Int32(allVerts.count)
                    allVerts += pts.map { worldVert($0, offset: offset) }
                    allNorms += Array(repeating: normal, count: n)
                    indices += triangulateFan(vertexCount: n, vertexOffset: base, reversed: reversed)
                } else {
                    let merged = mergePolygonWithHoles(outer: pts, holes: holes)
                    let base = Int32(allVerts.count)
                    allVerts += merged.map { worldVert($0, offset: offset) }
                    allNorms += Array(repeating: normal, count: merged.count)
                    for (ia, ib, ic) in earClipTriangulate(merged) {
                        let a = base + Int32(ia), b = base + Int32(ib), c = base + Int32(ic)
                        indices += reversed ? [a, c, b] : [a, b, c]
                    }
                }
            }

            appendCap(
                offset: frontOff,
                normal: fnFront,
                holes: profilesOpening(at: frontOff),
                reversed: flipWinding
            )
            appendCap(
                offset: backOff,
                normal: fnBack,
                holes: profilesOpening(at: backOff),
                reversed: !flipWinding
            )

            // Outer side walls remain untouched by Cut v2. Only cap holes, inner walls, and
            // blind bottoms are added for the explicit cut tool volume interval.
            for i in 0..<n {
                let j = (i + 1) % n
                let wallN = outerWallNorm(i, j, pts)
                let swBase = Int32(allVerts.count)
                allVerts += [
                    worldVert(pts[i], offset: frontOff),
                    worldVert(pts[j], offset: frontOff),
                    worldVert(pts[i], offset: backOff),
                    worldVert(pts[j], offset: backOff),
                ]
                allNorms += [wallN, wallN, wallN, wallN]
                let f0 = swBase, f1 = swBase + 1, b0 = swBase + 2, b1 = swBase + 3
                indices += flipWinding ? [f0, f1, b1, f0, b1, b0] : [f0, b1, f1, f0, b0, b1]
            }

            for feature in cutFeatures {
                let hole = feature.profilePoints
                let hn = hole.count
                guard hn >= 3 else { continue }
                let holeFlip = DesignSketch.polygonSignedAreaMeters2(hole) > 0
                let flipHoleWinding = basisIsLeftHanded != holeFlip
                let holeNorms: [SCNVector3] = (0..<hn).map { idx in
                    let prev = (idx + hn - 1) % hn
                    let next = (idx + 1) % hn
                    let n0 = innerWallNorm(prev, idx, hole, holeFlip)
                    let n1 = innerWallNorm(idx, next, hole, holeFlip)
                    let ax = (Double(n0.x) + Double(n1.x)) * 0.5
                    let ay = (Double(n0.y) + Double(n1.y)) * 0.5
                    let az = (Double(n0.z) + Double(n1.z)) * 0.5
                    let len = sqrt(ax*ax + ay*ay + az*az)
                    return len < 1e-9 ? n0 : SCNVector3(Float(ax/len), Float(ay/len), Float(az/len))
                }

                let startBase = Int32(allVerts.count)
                allVerts += hole.map { worldVert($0, offset: feature.startOffsetMeters) }
                allNorms += holeNorms

                let endBase = Int32(allVerts.count)
                allVerts += hole.map { worldVert($0, offset: feature.endOffsetMeters) }
                allNorms += holeNorms

                for i in 0..<hn {
                    let j = (i + 1) % hn
                    let s0 = startBase + Int32(i), s1 = startBase + Int32(j)
                    let e0 = endBase + Int32(i), e1 = endBase + Int32(j)
                    indices += flipHoleWinding ? [s0, s1, e1, s0, e1, e0] : [s1, s0, e0, s1, e0, e1]
                }

                let startsAtCap = abs(feature.startOffsetMeters - frontOff) < 1e-7
                    || abs(feature.startOffsetMeters - backOff) < 1e-7
                let endsAtCap = abs(feature.endOffsetMeters - frontOff) < 1e-7
                    || abs(feature.endOffsetMeters - backOff) < 1e-7
                if startsAtCap != endsAtCap {
                    let bottomOffset = startsAtCap ? feature.endOffsetMeters : feature.startOffsetMeters
                    let capBase = Int32(allVerts.count)
                    allVerts += hole.map { worldVert($0, offset: bottomOffset) }
                    let bottomNormalSign = startsAtCap
                        ? (feature.endOffsetMeters > feature.startOffsetMeters ? -1.0 : 1.0)
                        : (feature.startOffsetMeters > feature.endOffsetMeters ? -1.0 : 1.0)
                    let bottomNormal = normal * bottomNormalSign
                    allNorms += Array(
                        repeating: SCNVector3(Float(bottomNormal.x), Float(bottomNormal.y), Float(bottomNormal.z)),
                        count: hn
                    )
                    let capReversed = basisIsLeftHanded != (holeFlip != (bottomNormalSign < 0))
                    indices += triangulateFan(vertexCount: hn, vertexOffset: capBase, reversed: capReversed)
                }
            }
        }

        let posSrc  = SCNGeometrySource(vertices: allVerts)
        let normSrc = SCNGeometrySource(normals: allNorms)
        let el      = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [posSrc, normSrc], elements: [el])
    }

    private static func makeKernelSolidGeometry(_ mesh: CADSolidMeshSnapshot) -> SCNGeometry? {
        guard !mesh.vertices.isEmpty,
              !mesh.triangles.isEmpty,
              mesh.vertices.allSatisfy(\.isFinite) else {
            return nil
        }
        var vertexNormals = Array(repeating: DesignVector3.zero, count: mesh.vertices.count)
        var indices: [Int32] = []
        indices.reserveCapacity(mesh.triangles.count * 3)
        for triangle in mesh.triangles {
            guard mesh.vertices.indices.contains(triangle.a),
                  mesh.vertices.indices.contains(triangle.b),
                  mesh.vertices.indices.contains(triangle.c) else {
                return nil
            }
            let a = mesh.vertices[triangle.a]
            let b = mesh.vertices[triangle.b]
            let c = mesh.vertices[triangle.c]
            let normal = (b - a).cross(c - a).normalized(fallback: .zAxis)
            vertexNormals[triangle.a] = vertexNormals[triangle.a] + normal
            vertexNormals[triangle.b] = vertexNormals[triangle.b] + normal
            vertexNormals[triangle.c] = vertexNormals[triangle.c] + normal
            indices.append(Int32(triangle.a))
            indices.append(Int32(triangle.b))
            indices.append(Int32(triangle.c))
        }
        let vertices = mesh.vertices.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let normals = vertexNormals.map {
            let normal = $0.normalized(fallback: .zAxis)
            return SCNVector3(Float(normal.x), Float(normal.y), Float(normal.z))
        }
        let posSrc = SCNGeometrySource(vertices: vertices)
        let normSrc = SCNGeometrySource(normals: normals)
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [posSrc, normSrc], elements: [el])
    }

    private struct BoxBlindCutMeshCandidate {
        var geometry: SCNGeometry
        var vertexCount: Int
        var triangleCount: Int
        var faceSurfacesRendered: Int
        var entryFaceSurfacesRendered: Int
        var expectedEntryFaceSurfacesRendered: Int
        var invalidEntryFaceTriangulation: Bool
        var meshSnapshot: CADSolidMeshSnapshot
        var meshDiagnostics: CADSolidMeshDiagnostics
        var cutStats: [UUID: BoxBlindCutMeshStats]
    }

    private struct BoxBlindCutMeshStats {
        var segmentCount: Int
        var wallQuadCount: Int
        var wallTriangleCount: Int
        var skippedWallSegmentCount: Int
        var wallFlippedTriangleCount: Int
        var bottomTriangleCount: Int
        var cutIntersectionCullCount: Int
        var minDepthMeters: Double
        var maxDepthMeters: Double
    }

    static func debugMeshStats(for params: ExtrudedSolidParameters) -> (vertexCount: Int, triangleCount: Int)? {
        if !params.boxBlindCutFeatures.isEmpty,
           let candidate = makeBoxBlindCutCandidate(params) {
            return (candidate.vertexCount, candidate.triangleCount)
        }

        let geometry = makeExtrudedSolidGeometry(params)
        let vertexCount = geometry.sources(for: .vertex).first?.vectorCount ?? 0
        var triangleCount = 0
        for index in 0..<geometry.elementCount {
            let element = geometry.element(at: index)
            if element.primitiveType == .triangles {
                triangleCount += element.primitiveCount
            }
        }
        return (vertexCount, triangleCount)
    }

    static func debugSolidMeshSnapshot(for params: ExtrudedSolidParameters) -> CADSolidMeshSnapshot? {
        if !params.boxBlindCutFeatures.isEmpty,
           let candidate = makeBoxBlindCutCandidate(params) {
            return candidate.meshSnapshot
        }

        let geometry = makeExtrudedSolidGeometry(params)
        return solidMeshSnapshot(from: geometry)
    }

    static func validateBoxDistanceCutCandidate(params p: ExtrudedSolidParameters) -> CADFeatureValidation {
        guard let candidate = makeBoxBlindCutCandidate(p) else {
            return .cutResultNotSolid
        }
        guard !candidate.invalidEntryFaceTriangulation else {
            return .invalidEntryFaceTriangulation
        }
        guard candidate.vertexCount >= 24,
              candidate.triangleCount >= 12,
              candidate.faceSurfacesRendered == p.faces.count,
              candidate.entryFaceSurfacesRendered == candidate.expectedEntryFaceSurfacesRendered else {
            return .unaffectedGeometryWasRemoved
        }
        print(
            "CAD Cut v2 Result Mesh: vertices=\(candidate.vertexCount) " +
            "triangles=\(candidate.triangleCount) " +
            "volumeEstimate=\(candidate.meshDiagnostics.volumeEstimate) " +
            "invalidVertices=\(candidate.meshDiagnostics.invalidVertexCount) " +
            "zeroAreaTriangles=\(candidate.meshDiagnostics.zeroAreaTriangleCount) " +
            "sliverTriangles=\(candidate.meshDiagnostics.sliverTriangleCount) " +
            "duplicateFaces=\(candidate.meshDiagnostics.duplicateFaceCount) " +
            "boundaryEdges=\(candidate.meshDiagnostics.boundaryEdgeCount) " +
            "boundaryLoops=\(candidate.meshDiagnostics.boundaryLoopCount) " +
            "nonManifoldEdges=\(candidate.meshDiagnostics.nonManifoldEdgeCount)"
        )
        if candidate.meshDiagnostics.hasInvalidTopology {
            return .cutResultNotSolid
        }
        if candidate.meshDiagnostics.hasOpenBoundary {
            print(
                "CAD Cut v2 Mesh Warning: result mesh has open or non-manifold edges " +
                "(boundary=\(candidate.meshDiagnostics.boundaryEdgeCount), " +
                "loops=\(candidate.meshDiagnostics.boundaryLoopCount), " +
                "nonManifold=\(candidate.meshDiagnostics.nonManifoldEdgeCount))."
            )
        }

        for cut in p.boxBlindCutFeatures {
            guard let stats = candidate.cutStats[cut.id] else {
                return .cutResultNotSolid
            }
            let expectedWallTriangleCount = stats.segmentCount * 2
            let expectedWallQuadCount = stats.segmentCount
            print(
                "CAD Cut v2 Mesh: cutID=\(cut.id.uuidString) " +
                "profile=\(cut.profileType.rawValue) " +
                "segments=\(stats.segmentCount) " +
                "wallQuads=\(stats.wallQuadCount)/\(expectedWallQuadCount) " +
                "wallTriangles=\(stats.wallTriangleCount) min=\(expectedWallTriangleCount) " +
                "skippedWallSegments=\(stats.skippedWallSegmentCount) " +
                "culledByExistingCuts=\(stats.cutIntersectionCullCount) " +
                "flippedWallTriangles=\(stats.wallFlippedTriangleCount) " +
                "bottomTriangles=\(stats.bottomTriangleCount) " +
                "depthRange=\(stats.minDepthMeters)...\(stats.maxDepthMeters)"
            )
            if stats.cutIntersectionCullCount == 0 {
                guard stats.wallQuadCount == expectedWallQuadCount,
                      stats.wallTriangleCount >= expectedWallTriangleCount,
                      stats.skippedWallSegmentCount == 0 else {
                    return cut.profileType == .circle ? .cutMissingCylindricalWall : .cutMissingInternalWall
                }
            }
            switch cut.profileType {
            case .circle:
                guard stats.segmentCount >= 64 else { return .unsupportedProfileForCutV2 }
                if cut.depthMode == .throughAll {
                    guard stats.bottomTriangleCount == 0 else { return .cutMissingExitOpening }
                } else if stats.cutIntersectionCullCount == 0 {
                    guard stats.bottomTriangleCount >= stats.segmentCount - 2 else { return .cutMissingBlindBottom }
                }
            case .rectangle:
                guard stats.segmentCount == 4 else { return .unsupportedProfileForCutV2 }
                if cut.depthMode == .throughAll {
                    guard stats.bottomTriangleCount == 0 else { return .cutMissingExitOpening }
                } else if stats.cutIntersectionCullCount == 0 {
                    guard stats.bottomTriangleCount >= 2 else { return .cutMissingBlindBottom }
                }
            case .polygon, .unsupported:
                return .unsupportedProfileForCutV2
            }
        }
        return .valid
    }

    private static func makeBoxBlindCutGeometry(_ p: ExtrudedSolidParameters) -> SCNGeometry? {
        guard let candidate = makeBoxBlindCutCandidate(p),
              !candidate.invalidEntryFaceTriangulation,
              candidate.vertexCount >= 24,
              candidate.triangleCount >= 12,
              candidate.faceSurfacesRendered == p.faces.count,
              candidate.entryFaceSurfacesRendered == candidate.expectedEntryFaceSurfacesRendered else {
            return nil
        }
        return candidate.geometry
    }

    private static func makeBoxBlindCutCandidate(_ p: ExtrudedSolidParameters) -> BoxBlindCutMeshCandidate? {
        guard p.profilePoints.count == 4,
              p.holes.isEmpty,
              p.cutFeatures.isEmpty,
              !p.boxBlindCutFeatures.isEmpty,
              p.faces.count >= 6 else {
            return nil
        }

        let faceByID = Dictionary(uniqueKeysWithValues: p.faces.map { ($0.id, $0) })
        guard p.boxBlindCutFeatures.allSatisfy({
            ($0.profileType == .circle || $0.profileType == .rectangle)
                && ($0.depthMode == .distance || $0.depthMode == .throughAll)
                && $0.depthMeters.isFinite
                && ($0.depthMode == .throughAll || $0.depthMeters > 1e-6)
                && $0.cutDirection.isFinite
                && faceByID[$0.entryFaceID] != nil
        }) else {
            return nil
        }

        var allVerts: [SCNVector3] = []
        var allNorms: [SCNVector3] = []
        var indices: [Int32] = []
        var faceSurfacesRendered = 0
        var entryFaceSurfacesRendered = 0
        var invalidEntryFaceTriangulation = false
        var cutStats: [UUID: BoxBlindCutMeshStats] = [:]

        func scn(_ vector: DesignVector3) -> SCNVector3 {
            SCNVector3(Float(vector.x), Float(vector.y), Float(vector.z))
        }

        func appendVertex(_ point: DesignVector3, normal: DesignVector3) -> Int32 {
            let index = Int32(allVerts.count)
            allVerts.append(scn(point))
            allNorms.append(scn(normal.normalized(fallback: .zAxis)))
            return index
        }

        var ignoredCutVolumeIDs: Set<UUID> = []
        var cutVolumeCulledTriangleCount = 0
        let materialPatchMaxEdgeMeters = 0.01
        let materialPatchMaxSubdivisions = 28

        func withIgnoredCutVolumes<T>(_ ids: Set<UUID>, _ body: () -> T) -> T {
            let previous = ignoredCutVolumeIDs
            ignoredCutVolumeIDs.formUnion(ids)
            defer { ignoredCutVolumeIDs = previous }
            return body()
        }

        func pointInsideProfile(
            _ point: SketchPoint2D,
            cut: ExtrudedSolidBoxBlindCutFeature,
            tolerance: Double
        ) -> Bool {
            switch cut.profileType {
            case .circle:
                guard cut.profilePoints.count >= 32 else { return false }
                let sum = cut.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
                    SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
                }
                let count = Double(cut.profilePoints.count)
                let center = SketchPoint2D(u: sum.u / count, v: sum.v / count)
                let radius = cut.profilePoints.map { $0.distance(to: center) }.reduce(0, +) / count
                return radius.isFinite && radius > tolerance && point.distance(to: center) < radius - tolerance
            case .rectangle:
                let us = cut.profilePoints.map(\.u)
                let vs = cut.profilePoints.map(\.v)
                guard let minU = us.min(),
                      let maxU = us.max(),
                      let minV = vs.min(),
                      let maxV = vs.max() else {
                    return false
                }
                return point.u > minU + tolerance
                    && point.u < maxU - tolerance
                    && point.v > minV + tolerance
                    && point.v < maxV - tolerance
            case .polygon:
                return SketchProfileEngine.pointInPolygon(point, polygon: cut.profilePoints)
            case .unsupported:
                return false
            }
        }

        func throughAllDepth(
            for cut: ExtrudedSolidBoxBlindCutFeature,
            entryFace: DesignPlanarFace,
            direction: DesignVector3
        ) -> Double? {
            let entryU = entryFace.uAxis.normalized(fallback: .xAxis)
            let entryV = entryFace.vAxis.normalized(fallback: .yAxis)
            let center = cut.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
                SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
            }
            let count = max(Double(cut.profilePoints.count), 1.0)
            let entryCenter = entryFace.origin
                + entryU * (center.u / count)
                + entryV * (center.v / count)

            for exitFace in p.faces where exitFace.id != entryFace.id {
                let exitNormal = exitFace.normal.normalized(fallback: direction)
                guard exitNormal.dot(direction) > 0.99 else { continue }
                let denominator = direction.dot(exitNormal)
                guard denominator > 1e-6 else { continue }
                let distance = (exitFace.origin - entryCenter).dot(exitNormal) / denominator
                guard distance.isFinite, distance > 1e-6 else { continue }

                let exitU = exitFace.uAxis.normalized(fallback: .xAxis)
                let exitV = exitFace.vAxis.normalized(fallback: .yAxis)
                let tolerance = 1e-5
                let profileProjectsInsideExit = cut.profilePoints.allSatisfy { profilePoint in
                    let world = entryFace.origin + entryU * profilePoint.u + entryV * profilePoint.v
                    let projected = world + direction * distance
                    let localDelta = projected - exitFace.origin
                    let u = localDelta.dot(exitU)
                    let v = localDelta.dot(exitV)
                    return u >= exitFace.bounds.minU - tolerance
                        && u <= exitFace.bounds.maxU + tolerance
                        && v >= exitFace.bounds.minV - tolerance
                        && v <= exitFace.bounds.maxV + tolerance
                }
                if profileProjectsInsideExit { return distance }
            }
            return nil
        }

        func pointInsideCutVolume(_ point: DesignVector3, cut: ExtrudedSolidBoxBlindCutFeature) -> Bool {
            guard !ignoredCutVolumeIDs.contains(cut.id),
                  let entryFace = faceByID[cut.entryFaceID] else {
                return false
            }

            let direction = cut.cutDirection.normalized(fallback: entryFace.normal * -1)
            let tolerance = 1e-6
            let depth: Double
            switch cut.depthMode {
            case .distance:
                depth = cut.depthMeters
            case .throughAll:
                guard let throughDepth = throughAllDepth(for: cut, entryFace: entryFace, direction: direction) else {
                    return false
                }
                depth = throughDepth
            case .upToObject, .upToNearestFace:
                return false
            }
            guard depth.isFinite, depth > tolerance else { return false }

            let delta = point - entryFace.origin
            let distanceAlongCut = delta.dot(direction)
            guard distanceAlongCut > tolerance,
                  distanceAlongCut < depth - tolerance else {
                return false
            }

            let faceU = entryFace.uAxis.normalized(fallback: .xAxis)
            let faceV = entryFace.vAxis.normalized(fallback: .yAxis)
            let local = SketchPoint2D(u: delta.dot(faceU), v: delta.dot(faceV))
            return pointInsideProfile(local, cut: cut, tolerance: tolerance)
        }

        func triangleCentroidIsInsideExistingCut(_ a: DesignVector3, _ b: DesignVector3, _ c: DesignVector3) -> Bool {
            let centroid = (a + b + c) * (1.0 / 3.0)
            return p.boxBlindCutFeatures.contains { pointInsideCutVolume(centroid, cut: $0) }
        }

        func triangleVerticesAreInsideSameExistingCut(_ a: DesignVector3, _ b: DesignVector3, _ c: DesignVector3) -> Bool {
            p.boxBlindCutFeatures.contains { cut in
                pointInsideCutVolume(a, cut: cut)
                    && pointInsideCutVolume(b, cut: cut)
                    && pointInsideCutVolume(c, cut: cut)
            }
        }

        @discardableResult
        func appendTriangle(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            desiredNormal: DesignVector3
        ) -> Bool {
            let n = desiredNormal.normalized(fallback: .zAxis)
            let windingNormal = (b - a).cross(c - a)
            guard a.isFinite, b.isFinite, c.isFinite, n.isFinite,
                  windingNormal.length > 1e-12 else {
                return false
            }
            if triangleCentroidIsInsideExistingCut(a, b, c) {
                cutVolumeCulledTriangleCount += 1
                return false
            }
            let ia = appendVertex(a, normal: n)
            let ib = appendVertex(b, normal: n)
            let ic = appendVertex(c, normal: n)
            if windingNormal.dot(n) < 0 {
                indices += [ia, ic, ib]
            } else {
                indices += [ia, ib, ic]
            }
            return true
        }

        @discardableResult
        func appendCutWallTriangle(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            normalA: DesignVector3,
            normalB: DesignVector3,
            normalC: DesignVector3,
            desiredNormal: DesignVector3,
            flippedTriangleCount: inout Int
        ) -> Bool {
            let n = desiredNormal.normalized(fallback: .zAxis)
            let na = normalA.normalized(fallback: n)
            let nb = normalB.normalized(fallback: n)
            let nc = normalC.normalized(fallback: n)
            let windingNormal = (b - a).cross(c - a)
            guard a.isFinite, b.isFinite, c.isFinite,
                  n.isFinite, na.isFinite, nb.isFinite, nc.isFinite,
                  windingNormal.length > 1e-12 else {
                return false
            }
            if triangleVerticesAreInsideSameExistingCut(a, b, c) {
                cutVolumeCulledTriangleCount += 1
                return false
            }

            let ia = appendVertex(a, normal: na)
            let ib = appendVertex(b, normal: nb)
            let ic = appendVertex(c, normal: nc)
            if windingNormal.dot(n) < 0 {
                indices += [ia, ic, ib]
                flippedTriangleCount += 1
            } else {
                indices += [ia, ib, ic]
            }
            return true
        }

        func subdivisionCount(for length: Double) -> Int {
            guard length.isFinite, length > materialPatchMaxEdgeMeters else { return 1 }
            return min(materialPatchMaxSubdivisions, max(1, Int(ceil(length / materialPatchMaxEdgeMeters))))
        }

        func bilerp(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            u: Double,
            v: Double
        ) -> DesignVector3 {
            let top = a * (1.0 - u) + b * u
            let bottom = d * (1.0 - u) + c * u
            return top * (1.0 - v) + bottom * v
        }

        @discardableResult
        func appendTriangle(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            normalA: DesignVector3,
            normalB: DesignVector3,
            normalC: DesignVector3,
            desiredNormal: DesignVector3,
            flippedTriangleCount: inout Int
        ) -> Bool {
            let n = desiredNormal.normalized(fallback: .zAxis)
            let na = normalA.normalized(fallback: n)
            let nb = normalB.normalized(fallback: n)
            let nc = normalC.normalized(fallback: n)
            let windingNormal = (b - a).cross(c - a)
            guard a.isFinite, b.isFinite, c.isFinite,
                  n.isFinite, na.isFinite, nb.isFinite, nc.isFinite,
                  windingNormal.length > 1e-12 else {
                return false
            }
            if triangleCentroidIsInsideExistingCut(a, b, c) {
                cutVolumeCulledTriangleCount += 1
                return false
            }
            let ia = appendVertex(a, normal: na)
            let ib = appendVertex(b, normal: nb)
            let ic = appendVertex(c, normal: nc)
            if windingNormal.dot(n) < 0 {
                indices += [ia, ic, ib]
                flippedTriangleCount += 1
            } else {
                indices += [ia, ib, ic]
            }
            return true
        }

        @discardableResult
        func appendSubdividedQuad(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            normalA: DesignVector3,
            normalB: DesignVector3,
            normalC: DesignVector3,
            normalD: DesignVector3,
            desiredNormal: DesignVector3,
            flippedTriangleCount: inout Int
        ) -> Int {
            let uLength = max((b - a).length, (c - d).length)
            let vLength = max((d - a).length, (c - b).length)
            let uSteps = subdivisionCount(for: uLength)
            let vSteps = subdivisionCount(for: vLength)
            var count = 0

            for uIndex in 0..<uSteps {
                let u0 = Double(uIndex) / Double(uSteps)
                let u1 = Double(uIndex + 1) / Double(uSteps)
                for vIndex in 0..<vSteps {
                    let v0 = Double(vIndex) / Double(vSteps)
                    let v1 = Double(vIndex + 1) / Double(vSteps)

                    let p00 = bilerp(a, b, c, d, u: u0, v: v0)
                    let p10 = bilerp(a, b, c, d, u: u1, v: v0)
                    let p11 = bilerp(a, b, c, d, u: u1, v: v1)
                    let p01 = bilerp(a, b, c, d, u: u0, v: v1)
                    let n00 = bilerp(normalA, normalB, normalC, normalD, u: u0, v: v0)
                    let n10 = bilerp(normalA, normalB, normalC, normalD, u: u1, v: v0)
                    let n11 = bilerp(normalA, normalB, normalC, normalD, u: u1, v: v1)
                    let n01 = bilerp(normalA, normalB, normalC, normalD, u: u0, v: v1)

                    if appendTriangle(
                        p00,
                        p10,
                        p11,
                        normalA: n00,
                        normalB: n10,
                        normalC: n11,
                        desiredNormal: desiredNormal,
                        flippedTriangleCount: &flippedTriangleCount
                    ) {
                        count += 1
                    }
                    if appendTriangle(
                        p00,
                        p11,
                        p01,
                        normalA: n00,
                        normalB: n11,
                        normalC: n01,
                        desiredNormal: desiredNormal,
                        flippedTriangleCount: &flippedTriangleCount
                    ) {
                        count += 1
                    }
                }
            }

            return count
        }

        @discardableResult
        func appendQuad(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            desiredNormal: DesignVector3
        ) -> Int {
            var flippedTriangleCount = 0
            return appendSubdividedQuad(
                a,
                b,
                c,
                d,
                normalA: desiredNormal,
                normalB: desiredNormal,
                normalC: desiredNormal,
                normalD: desiredNormal,
                desiredNormal: desiredNormal,
                flippedTriangleCount: &flippedTriangleCount
            )
        }

        @discardableResult
        func appendCutWallQuad(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            normalA: DesignVector3,
            normalB: DesignVector3,
            normalC: DesignVector3,
            normalD: DesignVector3,
            desiredNormal: DesignVector3,
            flippedTriangleCount: inout Int
        ) -> Int {
            var count = 0
            if appendCutWallTriangle(
                a,
                b,
                c,
                normalA: normalA,
                normalB: normalB,
                normalC: normalC,
                desiredNormal: desiredNormal,
                flippedTriangleCount: &flippedTriangleCount
            ) {
                count += 1
            }
            if appendCutWallTriangle(
                a,
                c,
                d,
                normalA: normalA,
                normalB: normalC,
                normalC: normalD,
                desiredNormal: desiredNormal,
                flippedTriangleCount: &flippedTriangleCount
            ) {
                count += 1
            }
            return count
        }

        func faceWorldPoint(_ face: DesignPlanarFace, _ point: SketchPoint2D) -> DesignVector3 {
            face.origin + face.uAxis * point.u + face.vAxis * point.v
        }

        func projectCutProfile(
            _ cut: ExtrudedSolidBoxBlindCutFeature,
            from entryFace: DesignPlanarFace,
            to exitFace: DesignPlanarFace
        ) -> [SketchPoint2D]? {
            let direction = cut.cutDirection.normalized(fallback: entryFace.normal * -1)
            let exitNormal = exitFace.normal.normalized(fallback: direction)
            let denominator = direction.dot(exitNormal)
            guard denominator > 1e-6 else { return nil }

            let exitU = exitFace.uAxis.normalized(fallback: .xAxis)
            let exitV = exitFace.vAxis.normalized(fallback: .yAxis)
            let tolerance = 1e-5
            var projected: [SketchPoint2D] = []
            for point in cut.profilePoints {
                let world = faceWorldPoint(entryFace, point)
                let distance = (exitFace.origin - world).dot(exitNormal) / denominator
                guard distance.isFinite, distance > 1e-6 else { return nil }
                let exitWorld = world + direction * distance
                let delta = exitWorld - exitFace.origin
                let local = SketchPoint2D(u: delta.dot(exitU), v: delta.dot(exitV))
                guard local.u >= exitFace.bounds.minU - tolerance,
                      local.u <= exitFace.bounds.maxU + tolerance,
                      local.v >= exitFace.bounds.minV - tolerance,
                      local.v <= exitFace.bounds.maxV + tolerance else {
                    return nil
                }
                projected.append(local)
            }
            return projected
        }

        func throughAllExitFace(
            for cut: ExtrudedSolidBoxBlindCutFeature,
            entryFace: DesignPlanarFace
        ) -> DesignPlanarFace? {
            guard cut.depthMode == .throughAll else { return nil }
            let direction = cut.cutDirection.normalized(fallback: entryFace.normal * -1)
            return p.faces.first { face in
                face.id != entryFace.id
                    && face.normal.normalized(fallback: .zAxis).dot(direction) > 0.99
                    && projectCutProfile(cut, from: entryFace, to: face) != nil
            }
        }

        func cutProjectedOnFace(
            _ cut: ExtrudedSolidBoxBlindCutFeature,
            face: DesignPlanarFace
        ) -> ExtrudedSolidBoxBlindCutFeature? {
            if cut.entryFaceID == face.id {
                return cut
            }
            guard cut.depthMode == .throughAll,
                  let entryFace = faceByID[cut.entryFaceID],
                  let exitFace = throughAllExitFace(for: cut, entryFace: entryFace),
                  exitFace.id == face.id,
                  let projectedProfile = projectCutProfile(cut, from: entryFace, to: face) else {
                return nil
            }
            var projectedCut = cut
            projectedCut.entryFaceID = face.id
            projectedCut.profilePoints = projectedProfile
            return projectedCut
        }

        func faceOuterLoop(_ face: DesignPlanarFace) -> [SketchPoint2D] {
            [
                SketchPoint2D(u: face.bounds.minU, v: face.bounds.minV),
                SketchPoint2D(u: face.bounds.maxU, v: face.bounds.minV),
                SketchPoint2D(u: face.bounds.maxU, v: face.bounds.maxV),
                SketchPoint2D(u: face.bounds.minU, v: face.bounds.maxV),
            ]
        }

        @discardableResult
        func circleDescriptor(for cut: ExtrudedSolidBoxBlindCutFeature) -> (center: SketchPoint2D, radius: Double)? {
            guard cut.profileType == .circle, cut.profilePoints.count >= 32 else { return nil }
            let center = cut.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
                SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
            }
            let count = Double(cut.profilePoints.count)
            let resolvedCenter = SketchPoint2D(u: center.u / count, v: center.v / count)
            let radius = cut.profilePoints
                .map { $0.distance(to: resolvedCenter) }
                .reduce(0, +) / count
            guard radius.isFinite, radius > 1e-6 else { return nil }
            return (resolvedCenter, radius)
        }

        func rectangleDescriptor(
            for cut: ExtrudedSolidBoxBlindCutFeature
        ) -> (minU: Double, maxU: Double, minV: Double, maxV: Double)? {
            guard cut.profileType == .rectangle, cut.profilePoints.count == 4 else { return nil }
            let us = cut.profilePoints.map(\.u)
            let vs = cut.profilePoints.map(\.v)
            guard us.allSatisfy(\.isFinite), vs.allSatisfy(\.isFinite),
                  let minU = us.min(),
                  let maxU = us.max(),
                  let minV = vs.min(),
                  let maxV = vs.max(),
                  maxU - minU > 1e-6,
                  maxV - minV > 1e-6 else {
                return nil
            }

            let tolerance = max(1e-6, max(maxU - minU, maxV - minV) * 0.002)
            let pointsMatchRectangle = cut.profilePoints.allSatisfy { point in
                let onVerticalEdge = abs(point.u - minU) <= tolerance || abs(point.u - maxU) <= tolerance
                let onHorizontalEdge = abs(point.v - minV) <= tolerance || abs(point.v - maxV) <= tolerance
                return onVerticalEdge && onHorizontalEdge
            }
            guard pointsMatchRectangle else { return nil }
            return (minU, maxU, minV, maxV)
        }

        func entryTriangleAllowed(
            _ a: SketchPoint2D,
            _ b: SketchPoint2D,
            _ c: SketchPoint2D,
            circleHoles: [(center: SketchPoint2D, radius: Double)]
        ) -> Bool {
            let area2 = abs((b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u))
            guard area2 > 1e-12 else { return true }
            for circle in circleHoles {
                let tolerance = max(1e-6, circle.radius * 0.005)
                let centroid = SketchPoint2D(
                    u: (a.u + b.u + c.u) / 3.0,
                    v: (a.v + b.v + c.v) / 3.0
                )
                if centroid.distance(to: circle.center) < circle.radius - tolerance {
                    return false
                }

                let tri = [a, b, c]
                for index in tri.indices {
                    let p0 = tri[index]
                    let p1 = tri[(index + 1) % tri.count]
                    let d0 = abs(p0.distance(to: circle.center) - circle.radius)
                    let d1 = abs(p1.distance(to: circle.center) - circle.radius)
                    if d0 <= tolerance && d1 <= tolerance && p0.distance(to: p1) <= circle.radius * 0.25 {
                        continue
                    }
                    let closest = closestPointOnSegment(from: circle.center, segA: p0, segB: p1)
                    if closest.distance(to: circle.center) < circle.radius - tolerance {
                        return false
                    }
                }
            }
            return true
        }

        func entryTriangleAllowed(
            _ a: SketchPoint2D,
            _ b: SketchPoint2D,
            _ c: SketchPoint2D,
            rectangleHoles: [(minU: Double, maxU: Double, minV: Double, maxV: Double)]
        ) -> Bool {
            let area2 = abs((b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u))
            guard area2 > 1e-12 else { return true }

            func pointInside(_ point: SketchPoint2D, _ rect: (minU: Double, maxU: Double, minV: Double, maxV: Double), tolerance: Double) -> Bool {
                point.u > rect.minU + tolerance
                    && point.u < rect.maxU - tolerance
                    && point.v > rect.minV + tolerance
                    && point.v < rect.maxV - tolerance
            }

            func segmentIntersectsInterior(
                _ p0: SketchPoint2D,
                _ p1: SketchPoint2D,
                _ rect: (minU: Double, maxU: Double, minV: Double, maxV: Double),
                tolerance: Double
            ) -> Bool {
                let minU = rect.minU + tolerance
                let maxU = rect.maxU - tolerance
                let minV = rect.minV + tolerance
                let maxV = rect.maxV - tolerance
                guard minU < maxU, minV < maxV else { return false }
                if pointInside(p0, rect, tolerance: tolerance) || pointInside(p1, rect, tolerance: tolerance) {
                    return true
                }

                let dx = p1.u - p0.u
                let dy = p1.v - p0.v
                var t0 = 0.0
                var t1 = 1.0

                func clip(_ p: Double, _ q: Double) -> Bool {
                    if abs(p) < 1e-12 {
                        return q >= 0
                    }
                    let r = q / p
                    if p < 0 {
                        if r > t1 { return false }
                        if r > t0 { t0 = r }
                    } else {
                        if r < t0 { return false }
                        if r < t1 { t1 = r }
                    }
                    return true
                }

                guard clip(-dx, p0.u - minU),
                      clip(dx, maxU - p0.u),
                      clip(-dy, p0.v - minV),
                      clip(dy, maxV - p0.v) else {
                    return false
                }
                return t0 < t1 && t1 > 1e-9 && t0 < 1.0 - 1e-9
            }

            for rect in rectangleHoles {
                let tolerance = max(1e-6, max(rect.maxU - rect.minU, rect.maxV - rect.minV) * 0.002)
                let centroid = SketchPoint2D(
                    u: (a.u + b.u + c.u) / 3.0,
                    v: (a.v + b.v + c.v) / 3.0
                )
                if pointInside(centroid, rect, tolerance: tolerance) {
                    return false
                }

                let tri = [a, b, c]
                for index in tri.indices {
                    if segmentIntersectsInterior(
                        tri[index],
                        tri[(index + 1) % tri.count],
                        rect,
                        tolerance: tolerance
                    ) {
                        return false
                    }
                }
            }
            return true
        }

        @discardableResult
        func appendCircleEntryFaceSurface(
            _ face: DesignPlanarFace,
            cut: ExtrudedSolidBoxBlindCutFeature,
            circle: (center: SketchPoint2D, radius: Double)
        ) -> Int {
            let normal = face.normal.normalized(fallback: .zAxis)
            let minU = face.bounds.minU
            let maxU = face.bounds.maxU
            let minV = face.bounds.minV
            let maxV = face.bounds.maxV
            let cx = circle.center.u
            let cy = circle.center.v
            let r = circle.radius
            let tolerance = 1e-6
            guard cx - r > minU + tolerance,
                  cx + r < maxU - tolerance,
                  cy - r > minV + tolerance,
                  cy + r < maxV - tolerance else {
                invalidEntryFaceTriangulation = true
                return 0
            }

            func appendLocalTriangle(
                _ a: SketchPoint2D,
                _ b: SketchPoint2D,
                _ c: SketchPoint2D
            ) -> Int {
                guard entryTriangleAllowed(a, b, c, circleHoles: [circle]) else {
                    invalidEntryFaceTriangulation = true
                    return 0
                }
                return appendTriangle(
                    faceWorldPoint(face, a),
                    faceWorldPoint(face, b),
                    faceWorldPoint(face, c),
                    desiredNormal: normal
                ) ? 1 : 0
            }

            func appendLocalQuad(
                _ a: SketchPoint2D,
                _ b: SketchPoint2D,
                _ c: SketchPoint2D,
                _ d: SketchPoint2D
            ) -> Int {
                appendLocalTriangle(a, b, c) + appendLocalTriangle(a, c, d)
            }

            func appendLocalMaterialQuad(
                _ a: SketchPoint2D,
                _ b: SketchPoint2D,
                _ c: SketchPoint2D,
                _ d: SketchPoint2D
            ) -> Int {
                var flippedTriangleCount = 0
                return appendSubdividedQuad(
                    faceWorldPoint(face, a),
                    faceWorldPoint(face, b),
                    faceWorldPoint(face, c),
                    faceWorldPoint(face, d),
                    normalA: normal,
                    normalB: normal,
                    normalC: normal,
                    normalD: normal,
                    desiredNormal: normal,
                    flippedTriangleCount: &flippedTriangleCount
                )
            }

            func appendRect(minU: Double, maxU: Double, minV: Double, maxV: Double) -> Int {
                guard maxU - minU > tolerance, maxV - minV > tolerance else { return 0 }
                return appendLocalMaterialQuad(
                    SketchPoint2D(u: minU, v: minV),
                    SketchPoint2D(u: maxU, v: minV),
                    SketchPoint2D(u: maxU, v: maxV),
                    SketchPoint2D(u: minU, v: maxV)
                )
            }

            func squareHit(for point: SketchPoint2D) -> SketchPoint2D {
                let du = point.u - cx
                let dv = point.v - cy
                let scale = r / max(abs(du), abs(dv), 1e-12)
                return SketchPoint2D(u: cx + du * scale, v: cy + dv * scale)
            }

            var count = 0
            count += appendRect(minU: minU, maxU: maxU, minV: minV, maxV: cy - r)
            count += appendRect(minU: minU, maxU: maxU, minV: cy + r, maxV: maxV)
            count += appendRect(minU: minU, maxU: cx - r, minV: cy - r, maxV: cy + r)
            count += appendRect(minU: cx + r, maxU: maxU, minV: cy - r, maxV: cy + r)

            let loop = DesignSketch.polygonSignedAreaMeters2(cut.profilePoints) >= 0
                ? cut.profilePoints
                : cut.profilePoints.reversed()
            let circleLoop = Array(loop)
            for index in circleLoop.indices {
                let next = (index + 1) % circleLoop.count
                let p0 = circleLoop[index]
                let p1 = circleLoop[next]
                count += appendLocalQuad(
                    p0,
                    p1,
                    squareHit(for: p1),
                    squareHit(for: p0)
                )
            }

            return invalidEntryFaceTriangulation ? 0 : count
        }

        @discardableResult
        func appendRectangleEntryFaceSurface(
            _ face: DesignPlanarFace,
            cut: ExtrudedSolidBoxBlindCutFeature,
            rectangle: (minU: Double, maxU: Double, minV: Double, maxV: Double)
        ) -> Int {
            let normal = face.normal.normalized(fallback: .zAxis)
            let faceMinU = face.bounds.minU
            let faceMaxU = face.bounds.maxU
            let faceMinV = face.bounds.minV
            let faceMaxV = face.bounds.maxV
            let tolerance = 1e-6
            guard rectangle.minU > faceMinU + tolerance,
                  rectangle.maxU < faceMaxU - tolerance,
                  rectangle.minV > faceMinV + tolerance,
                  rectangle.maxV < faceMaxV - tolerance else {
                invalidEntryFaceTriangulation = true
                return 0
            }

            func appendLocalTriangle(
                _ a: SketchPoint2D,
                _ b: SketchPoint2D,
                _ c: SketchPoint2D
            ) -> Int {
                guard entryTriangleAllowed(a, b, c, rectangleHoles: [rectangle]) else {
                    invalidEntryFaceTriangulation = true
                    return 0
                }
                return appendTriangle(
                    faceWorldPoint(face, a),
                    faceWorldPoint(face, b),
                    faceWorldPoint(face, c),
                    desiredNormal: normal
                ) ? 1 : 0
            }

            func appendLocalQuad(
                _ a: SketchPoint2D,
                _ b: SketchPoint2D,
                _ c: SketchPoint2D,
                _ d: SketchPoint2D
            ) -> Int {
                var flippedTriangleCount = 0
                return appendSubdividedQuad(
                    faceWorldPoint(face, a),
                    faceWorldPoint(face, b),
                    faceWorldPoint(face, c),
                    faceWorldPoint(face, d),
                    normalA: normal,
                    normalB: normal,
                    normalC: normal,
                    normalD: normal,
                    desiredNormal: normal,
                    flippedTriangleCount: &flippedTriangleCount
                )
            }

            func appendRect(minU: Double, maxU: Double, minV: Double, maxV: Double) -> Int {
                guard maxU - minU > tolerance, maxV - minV > tolerance else { return 0 }
                return appendLocalQuad(
                    SketchPoint2D(u: minU, v: minV),
                    SketchPoint2D(u: maxU, v: minV),
                    SketchPoint2D(u: maxU, v: maxV),
                    SketchPoint2D(u: minU, v: maxV)
                )
            }

            var count = 0
            count += appendRect(minU: faceMinU, maxU: faceMaxU, minV: faceMinV, maxV: rectangle.minV)
            count += appendRect(minU: faceMinU, maxU: faceMaxU, minV: rectangle.maxV, maxV: faceMaxV)
            count += appendRect(minU: faceMinU, maxU: rectangle.minU, minV: rectangle.minV, maxV: rectangle.maxV)
            count += appendRect(minU: rectangle.maxU, maxU: faceMaxU, minV: rectangle.minV, maxV: rectangle.maxV)

            if count < 8 {
                invalidEntryFaceTriangulation = true
                return 0
            }
            return invalidEntryFaceTriangulation ? 0 : count
        }

        @discardableResult
        func appendFaceSurface(_ face: DesignPlanarFace, cuts: [ExtrudedSolidBoxBlindCutFeature]) -> Int {
            return withIgnoredCutVolumes(Set(cuts.map(\.id))) {
                let normal = face.normal.normalized(fallback: .zAxis)
                let holes = cuts.map(\.profilePoints)
                if holes.isEmpty {
                    let outer = faceOuterLoop(face)
                    let world = outer.map { faceWorldPoint(face, $0) }
                    return appendQuad(world[0], world[1], world[2], world[3], desiredNormal: normal)
                }
                if cuts.count == 1,
                   cuts[0].profileType == .circle,
                   let circle = circleDescriptor(for: cuts[0]) {
                    return appendCircleEntryFaceSurface(face, cut: cuts[0], circle: circle)
                }
                if cuts.count == 1,
                   cuts[0].profileType == .rectangle,
                   let rectangle = rectangleDescriptor(for: cuts[0]) {
                    return appendRectangleEntryFaceSurface(face, cut: cuts[0], rectangle: rectangle)
                }

                invalidEntryFaceTriangulation = true
                return 0
            }
        }

        @discardableResult
        func appendConvexCap(points: [DesignVector3], desiredNormal: DesignVector3) -> Int {
            guard points.count >= 3 else { return 0 }
            if points.count == 4 {
                return appendQuad(
                    points[0],
                    points[1],
                    points[2],
                    points[3],
                    desiredNormal: desiredNormal
                )
            }
            var count = 0
            for index in 1..<(points.count - 1) {
                if appendTriangle(
                    points[0],
                    points[index],
                    points[index + 1],
                    desiredNormal: desiredNormal
                ) {
                    count += 1
                }
            }
            return count
        }

        guard p.boxBlindCutFeatures.allSatisfy({ cut in
            guard cut.depthMode == .throughAll else { return true }
            guard let entryFace = faceByID[cut.entryFaceID] else { return false }
            return throughAllExitFace(for: cut, entryFace: entryFace) != nil
        }) else {
            return nil
        }

        let expectedCutFaceIDs = Set(p.faces.compactMap { face -> UUID? in
            p.boxBlindCutFeatures.contains { cutProjectedOnFace($0, face: face) != nil } ? face.id : nil
        })

        for face in p.faces {
            let faceCuts = p.boxBlindCutFeatures.compactMap { cutProjectedOnFace($0, face: face) }
            let triangles = appendFaceSurface(face, cuts: faceCuts)
            if triangles > 0 {
                faceSurfacesRendered += 1
                if !faceCuts.isEmpty {
                    entryFaceSurfacesRendered += 1
                }
            }
        }

        for cut in p.boxBlindCutFeatures {
            guard let face = faceByID[cut.entryFaceID] else { continue }
            let entryPoints = cut.profilePoints.map { faceWorldPoint(face, $0) }
            guard entryPoints.count >= 3 else { continue }
            let cutDirection = cut.cutDirection.normalized(fallback: face.normal * -1)
            let endPoints: [DesignVector3]
            if cut.depthMode == .throughAll {
                guard let exitFace = throughAllExitFace(for: cut, entryFace: face),
                      let projectedProfile = projectCutProfile(cut, from: face, to: exitFace) else {
                    invalidEntryFaceTriangulation = true
                    continue
                }
                endPoints = projectedProfile.map { faceWorldPoint(exitFace, $0) }
            } else {
                endPoints = entryPoints.map { $0 + cutDirection * cut.depthMeters }
            }
            guard endPoints.count == entryPoints.count else {
                invalidEntryFaceTriangulation = true
                continue
            }
            let entryCenter = entryPoints.reduce(DesignVector3.zero, +) * (1.0 / Double(entryPoints.count))
            let endCenter = endPoints.reduce(DesignVector3.zero, +) * (1.0 / Double(endPoints.count))
            let axisDirection = (endCenter - entryCenter).normalized(fallback: cutDirection)
            let depthSamples = zip(entryPoints, endPoints).map { pair in
                (pair.1 - pair.0).dot(axisDirection)
            }
            let minDepthMeters = depthSamples.min() ?? 0
            let maxDepthMeters = depthSamples.max() ?? 0
            var wallTriangleCount = 0
            var wallQuadCount = 0
            var skippedWallSegmentCount = 0
            var wallFlippedTriangleCount = 0
            let cullCountBeforeCutSurfaces = cutVolumeCulledTriangleCount

            // Internal cut walls face the removed volume, so their normals must point
            // radially toward the cut axis instead of borrowing any axial depth component.
            func wallNormal(
                at point: DesignVector3,
                fallback: DesignVector3
            ) -> DesignVector3 {
                let axialDistance = (point - entryCenter).dot(axisDirection)
                let axisPoint = entryCenter + axisDirection * axialDistance
                return (axisPoint - point).normalized(fallback: fallback)
            }

            let bottomTriangleCount = withIgnoredCutVolumes(Set([cut.id])) {
                for index in entryPoints.indices {
                    let next = (index + 1) % entryPoints.count
                    let wallMid = (entryPoints[index] + entryPoints[next] + endPoints[index] + endPoints[next]) * 0.25
                    let segmentFallback = wallNormal(at: wallMid, fallback: cutDirection * -1)
                    let normalA: DesignVector3
                    let normalB: DesignVector3
                    let normalC: DesignVector3
                    let normalD: DesignVector3
                    switch cut.profileType {
                    case .circle:
                        normalA = wallNormal(at: entryPoints[index], fallback: segmentFallback)
                        normalB = wallNormal(at: entryPoints[next], fallback: segmentFallback)
                        normalC = wallNormal(at: endPoints[next], fallback: segmentFallback)
                        normalD = wallNormal(at: endPoints[index], fallback: segmentFallback)
                    case .rectangle, .polygon, .unsupported:
                        normalA = segmentFallback
                        normalB = segmentFallback
                        normalC = segmentFallback
                        normalD = segmentFallback
                    }
                    let appendedTriangles = appendCutWallQuad(
                        entryPoints[index],
                        entryPoints[next],
                        endPoints[next],
                        endPoints[index],
                        normalA: normalA,
                        normalB: normalB,
                        normalC: normalC,
                        normalD: normalD,
                        desiredNormal: segmentFallback,
                        flippedTriangleCount: &wallFlippedTriangleCount
                    )
                    wallTriangleCount += appendedTriangles
                    if appendedTriangles > 0 {
                        wallQuadCount += 1
                    } else {
                        skippedWallSegmentCount += 1
                    }
                }

                return cut.depthMode == .throughAll
                    ? 0
                    : appendConvexCap(points: endPoints, desiredNormal: cutDirection * -1)
            }
            let cutIntersectionCullCount = cutVolumeCulledTriangleCount - cullCountBeforeCutSurfaces
            cutStats[cut.id] = BoxBlindCutMeshStats(
                segmentCount: entryPoints.count,
                wallQuadCount: wallQuadCount,
                wallTriangleCount: wallTriangleCount,
                skippedWallSegmentCount: skippedWallSegmentCount,
                wallFlippedTriangleCount: wallFlippedTriangleCount,
                bottomTriangleCount: bottomTriangleCount,
                cutIntersectionCullCount: cutIntersectionCullCount,
                minDepthMeters: minDepthMeters,
                maxDepthMeters: maxDepthMeters
            )
        }

        func solidMeshSnapshot() -> CADSolidMeshSnapshot {
            let vertices = allVerts.map { vertex in
                DesignVector3(
                    x: Double(vertex.x),
                    y: Double(vertex.y),
                    z: Double(vertex.z)
                )
            }
            var triangles: [CADSolidTriangle] = []
            var offset = 0
            while offset + 2 < indices.count {
                triangles.append(
                    CADSolidTriangle(
                        a: Int(indices[offset]),
                        b: Int(indices[offset + 1]),
                        c: Int(indices[offset + 2])
                    )
                )
                offset += 3
            }
            return CADSolidMeshSnapshot(vertices: vertices, triangles: triangles)
        }

        guard !indices.isEmpty else { return nil }
        let meshSnapshot = solidMeshSnapshot()
        let meshDiagnostics = CADSolidMeshValidator.diagnose(meshSnapshot)
        let posSrc = SCNGeometrySource(vertices: allVerts)
        let normSrc = SCNGeometrySource(normals: allNorms)
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [posSrc, normSrc], elements: [el])
        return BoxBlindCutMeshCandidate(
            geometry: geometry,
            vertexCount: allVerts.count,
            triangleCount: indices.count / 3,
            faceSurfacesRendered: faceSurfacesRendered,
            entryFaceSurfacesRendered: entryFaceSurfacesRendered,
            expectedEntryFaceSurfacesRendered: expectedCutFaceIDs.count,
            invalidEntryFaceTriangulation: invalidEntryFaceTriangulation,
            meshSnapshot: meshSnapshot,
            meshDiagnostics: meshDiagnostics,
            cutStats: cutStats
        )
    }

    private static func solidMeshSnapshot(from geometry: SCNGeometry) -> CADSolidMeshSnapshot? {
        guard let vertexSource = geometry.sources(for: .vertex).first,
              let vertexData = vertexSource.data as Data? else {
            return nil
        }

        var vertices: [DesignVector3] = []
        vertices.reserveCapacity(vertexSource.vectorCount)
        vertexData.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            for index in 0..<vertexSource.vectorCount {
                let offset = vertexSource.dataOffset + index * vertexSource.dataStride
                let pointer = base.advanced(by: offset).assumingMemoryBound(to: Float.self)
                vertices.append(
                    DesignVector3(
                        x: Double(pointer[0]),
                        y: Double(pointer[1]),
                        z: Double(pointer[2])
                    )
                )
            }
        }

        var triangles: [CADSolidTriangle] = []
        for elementIndex in 0..<geometry.elementCount {
            let element = geometry.element(at: elementIndex)
            guard element.primitiveType == .triangles,
                  let indexData = element.data as Data? else {
                continue
            }
            let bytesPerIndex = element.bytesPerIndex
            indexData.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                for primitiveIndex in 0..<element.primitiveCount {
                    let baseIndex = primitiveIndex * 3
                    let a = readGeometryIndex(base: base, index: baseIndex, bytesPerIndex: bytesPerIndex)
                    let b = readGeometryIndex(base: base, index: baseIndex + 1, bytesPerIndex: bytesPerIndex)
                    let c = readGeometryIndex(base: base, index: baseIndex + 2, bytesPerIndex: bytesPerIndex)
                    triangles.append(CADSolidTriangle(a: a, b: b, c: c))
                }
            }
        }

        return CADSolidMeshSnapshot(vertices: vertices, triangles: triangles)
    }

    private static func readGeometryIndex(base: UnsafeRawPointer, index: Int, bytesPerIndex: Int) -> Int {
        let offset = index * bytesPerIndex
        switch bytesPerIndex {
        case 1:
            return Int(base.advanced(by: offset).assumingMemoryBound(to: UInt8.self).pointee)
        case 2:
            return Int(base.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
        default:
            return Int(base.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
        }
    }

    // MARK: Feature preview node

    static func makeFeaturePreviewNode(
        params: ExtrudedSolidParameters,
        isCut: Bool
    ) -> SCNNode {
        if isCut {
            return makeCutToolPreviewNode(params: params)
        }
        let geometry = makeExtrudedSolidGeometry(params)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(red: 0.15, green: 0.80, blue: 1.0, alpha: 1)
        // 35% opacity — light enough that the solid body is clearly visible through the preview;
        // heavy enough that the cut/extrude volume is clearly distinguishable.
        mat.transparency = 0.35
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        // Must NOT write to the depth buffer — otherwise the ghost occludes the solid body behind it.
        mat.writesToDepthBuffer = false
        // Ignore the depth buffer so the preview is visible even when it overlaps the solid body.
        // This lets the user see the full cut volume shape (XRay mode).
        mat.readsFromDepthBuffer = false
        geometry.firstMaterial = mat
        let node = SCNNode(geometry: geometry)
        node.name = "cad.cut.preview"
        // Render after all opaque geometry so depth buffer state from the body is intact.
        node.renderingOrder = 10
        return node
    }

    static func makeCutToolPreviewNode(params: ExtrudedSolidParameters) -> SCNNode {
        let node = SCNNode()
        node.name = "cad.cut.cutterVolume"
        node.renderingOrder = 10
        guard let geometry = makeCutToolPreviewGeometry(params) else {
            return node
        }
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(red: 1.0, green: 0.25, blue: 0.15, alpha: 1)
        mat.transparency = 0.35
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        geometry.firstMaterial = mat
        node.geometry = geometry
        return node
    }

    private static func makeCutToolPreviewGeometry(_ p: ExtrudedSolidParameters) -> SCNGeometry? {
        let pts = p.profilePoints
        guard pts.count >= 3,
              p.depthMeters.isFinite,
              p.depthMeters > 0,
              p.direction == .positiveNormal || p.direction == .negativeNormal else {
            return nil
        }

        let normal = normalVector(for: p.sourceReference).normalized(fallback: .zAxis)
        let (frontOff, backOff) = p.direction.offsets(depth: p.depthMeters)
        let entryOffset = abs(frontOff) <= abs(backOff) ? frontOff : backOff
        let farOffset = abs(frontOff) > abs(backOff) ? frontOff : backOff
        guard abs(farOffset - entryOffset) > 1e-6 else { return nil }

        func world(_ point: SketchPoint2D, offset: Double) -> DesignVector3 {
            sketchPointToWorld(point, reference: p.sourceReference) + normal * offset
        }

        func scn(_ vector: DesignVector3) -> SCNVector3 {
            SCNVector3(Float(vector.x), Float(vector.y), Float(vector.z))
        }

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []

        func appendVertex(_ point: DesignVector3, normal desiredNormal: DesignVector3) -> Int32 {
            let index = Int32(vertices.count)
            vertices.append(scn(point))
            normals.append(scn(desiredNormal.normalized(fallback: .zAxis)))
            return index
        }

        @discardableResult
        func appendTriangle(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            desiredNormal: DesignVector3
        ) -> Bool {
            let n = desiredNormal.normalized(fallback: .zAxis)
            let windingNormal = (b - a).cross(c - a)
            guard a.isFinite, b.isFinite, c.isFinite, n.isFinite,
                  windingNormal.length > 1e-12 else {
                return false
            }
            let ia = appendVertex(a, normal: n)
            let ib = appendVertex(b, normal: n)
            let ic = appendVertex(c, normal: n)
            indices += windingNormal.dot(n) < 0 ? [ia, ic, ib] : [ia, ib, ic]
            return true
        }

        @discardableResult
        func appendQuad(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            desiredNormal: DesignVector3
        ) -> Int {
            var count = 0
            if appendTriangle(a, b, c, desiredNormal: desiredNormal) { count += 1 }
            if appendTriangle(a, c, d, desiredNormal: desiredNormal) { count += 1 }
            return count
        }

        let entryPoints = pts.map { world($0, offset: entryOffset) }
        let farPoints = pts.map { world($0, offset: farOffset) }
        let center = entryPoints.reduce(DesignVector3.zero, +) * (1.0 / Double(entryPoints.count))
        let cutDirection = (normal * (farOffset - entryOffset)).normalized(fallback: normal)

        for index in pts.indices {
            let next = (index + 1) % pts.count
            let mid = (entryPoints[index] + entryPoints[next] + farPoints[index] + farPoints[next]) * 0.25
            let wallNormal = (mid - center).normalized(fallback: cutDirection)
            appendQuad(
                entryPoints[index],
                entryPoints[next],
                farPoints[next],
                farPoints[index],
                desiredNormal: wallNormal
            )
        }

        for index in 1..<(farPoints.count - 1) {
            appendTriangle(
                farPoints[0],
                farPoints[index],
                farPoints[index + 1],
                desiredNormal: cutDirection
            )
        }

        guard !indices.isEmpty else { return nil }
        let posSrc = SCNGeometrySource(vertices: vertices)
        let normSrc = SCNGeometrySource(normals: normals)
        let el = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [posSrc, normSrc], elements: [el])
    }

    private static func triangulateFan(
        vertexCount: Int,
        vertexOffset: Int32,
        reversed: Bool
    ) -> [Int32] {
        guard vertexCount >= 3 else { return [] }
        var indices: [Int32] = []
        for i in 1..<(vertexCount - 1) {
            let a = vertexOffset
            let b = vertexOffset + Int32(i)
            let c = vertexOffset + Int32(i + 1)
            indices += reversed ? [a, c, b] : [a, b, c]
        }
        return indices
    }

    // MARK: Hole triangulation helpers

    // Merge outer polygon (CCW) with holes using the rightmost-vertex bridge technique.
    // Returns a simple polygon covering the region between outer and holes.
    private static func mergePolygonWithHoles(
        outer: [SketchPoint2D],
        holes: [[SketchPoint2D]]
    ) -> [SketchPoint2D] {
        var result = outer
        if DesignSketch.polygonSignedAreaMeters2(result) < 0 { result.reverse() }
        // Sort holes descending by rightmost U vertex so we always bridge from the
        // right side first. This prevents the second hole's +U bridge-ray from
        // hitting a bridge edge inserted by the first hole merge.
        let sortedHoles = holes.sorted { lhs, rhs in
            let lu = lhs.max(by: { $0.u < $1.u })?.u ?? -.infinity
            let ru = rhs.max(by: { $0.u < $1.u })?.u ?? -.infinity
            return lu > ru
        }
        for hole in sortedHoles {
            var h = hole
            if DesignSketch.polygonSignedAreaMeters2(h) > 0 { h.reverse() }
            result = bridgeMergeHole(outer: result, hole: h)
        }
        return result
    }

    /// Pre-validates that adding newHole to outerProfile+existingHoles produces a triangulable cap.
    /// Returns false if the merged polygon is degenerate or ear-clip fails — caller should reject the cut.
    static func validateHoleMerge(
        outerProfile: [SketchPoint2D],
        existingHoles: [[SketchPoint2D]],
        newHole: [SketchPoint2D]
    ) -> Bool {
        guard outerProfile.count >= 3, newHole.count >= 3 else { return false }
        let allHoles = existingHoles + [newHole]
        let merged = mergePolygonWithHoles(outer: outerProfile, holes: allHoles)
        guard merged.count >= 3 else { return false }
        guard abs(DesignSketch.polygonSignedAreaMeters2(merged)) > 1e-10 else { return false }
        return !earClipTriangulate(merged).isEmpty
    }

    static func validateCapTriangulation(
        outerProfile: [SketchPoint2D],
        holes: [[SketchPoint2D]]
    ) -> Bool {
        guard outerProfile.count >= 3 else { return false }
        guard !holes.contains(where: { $0.count < 3 }) else { return false }
        let merged = mergePolygonWithHoles(outer: outerProfile, holes: holes)
        guard merged.count >= 3 else { return false }
        guard abs(DesignSketch.polygonSignedAreaMeters2(merged)) > 1e-10 else { return false }
        return !earClipTriangulate(merged).isEmpty
    }

    private static func bridgeMergeHole(
        outer: [SketchPoint2D],
        hole: [SketchPoint2D]
    ) -> [SketchPoint2D] {
        guard hole.count >= 3, outer.count >= 3 else { return outer }

        // Find rightmost hole vertex M
        let mIdx = hole.indices.max(by: { hole[$0].u < hole[$1].u }) ?? 0
        let M = hole[mIdx]
        let n = outer.count

        // Cast +U ray from M to find first outer edge crossing.
        // Offset the ray V by a tiny amount to avoid degenerate cases where M.v coincides
        // exactly with an outer vertex's V — the strict-less-than straddle test (a.v < M.v) !=
        // (b.v < M.v) silently skips edges whose endpoint lies exactly on the ray.
        let rayV = M.v + 1e-9
        var bestU = Double.infinity
        var bestEdgeIdx = -1
        for i in 0..<n {
            let a = outer[i], b = outer[(i + 1) % n]
            guard (a.v < rayV) != (b.v < rayV) else { continue }
            let t = (rayV - a.v) / (b.v - a.v)
            let ix = a.u + t * (b.u - a.u)
            guard ix >= M.u - 1e-9, ix < bestU else { continue }
            bestU = ix
            bestEdgeIdx = i
        }
        if bestEdgeIdx < 0 { bestEdgeIdx = 0 }

        // Pick outer vertex on intersected edge closest to intersection
        let iA = bestEdgeIdx, iB = (bestEdgeIdx + 1) % n
        let intersect = SketchPoint2D(u: bestU, v: M.v)
        let P = outer[iA].distance(to: intersect) <= outer[iB].distance(to: intersect) ? iA : iB

        // Rotate hole so M is at index 0
        let holeFromM = Array(hole[mIdx...]) + Array(hole[..<mIdx])

        // Build merged polygon: outer[0..P] + holeFromM + outer[P+1..N-1]
        // Bridge-in: outer[P] → holeFromM[0] (= M, rightmost hole vertex)
        // Bridge-out: holeFromM[last] → outer[P+1]
        // No duplicate vertex at M — avoids the degenerate zero-length edge that
        // was producing a degenerate triangle in ear-clip at the bridge seam.
        var merged = Array(outer[0...P])
        merged += holeFromM
        if P + 1 < n { merged += Array(outer[(P + 1)...]) }
        return merged
    }

    // Ear-clip triangulation. Polygon must be simple (no self-intersections).
    // Returns index triples into the original pts array.
    private static func earClipTriangulate(_ pts: [SketchPoint2D]) -> [(Int, Int, Int)] {
        var ring = Array(0..<pts.count)
        var tris: [(Int, Int, Int)] = []
        let ccw = DesignSketch.polygonSignedAreaMeters2(pts) > 0

        while ring.count > 3 {
            let cnt = ring.count
            var earFound = false
            for i in 0..<cnt {
                let ip = (i + cnt - 1) % cnt
                let in_ = (i + 1) % cnt
                let prev = pts[ring[ip]], curr = pts[ring[i]], next = pts[ring[in_]]
                let cross = (curr.u - prev.u) * (next.v - prev.v)
                              - (curr.v - prev.v) * (next.u - prev.u)
                let convex = ccw ? (cross > 0) : (cross < 0)
                guard convex else { continue }
                let noInterior = !ring.enumerated().contains { j, vIdx in
                    guard j != ip && j != i && j != in_ else { return false }
                    return ptInTriangle(pts[vIdx], a: prev, b: curr, c: next)
                }
                if noInterior {
                    tris.append((ring[ip], ring[i], ring[in_]))
                    ring.remove(at: i)
                    earFound = true
                    break
                }
            }
            if !earFound { break }
        }
        if ring.count == 3 { tris.append((ring[0], ring[1], ring[2])) }
        return tris
    }

    private static func ptInTriangle(
        _ p: SketchPoint2D,
        a: SketchPoint2D, b: SketchPoint2D, c: SketchPoint2D
    ) -> Bool {
        func sign(_ x: Double) -> Double { x < 0 ? -1 : (x > 0 ? 1 : 0) }
        let d1 = sign((p.u - b.u) * (a.v - b.v) - (a.u - b.u) * (p.v - b.v))
        let d2 = sign((p.u - c.u) * (b.v - c.v) - (b.u - c.u) * (p.v - c.v))
        let d3 = sign((p.u - a.u) * (c.v - a.v) - (c.u - a.u) * (p.v - a.v))
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }

    // MARK: Sketch

    private static func makeSketchNode(
        _ parameters: SketchAssetParameters,
        selectedLineID: UUID?,
        selectedEntityIDs: Set<UUID>,
        showPoints: Bool,
        showConstraintGlyphs: Bool = true
    ) -> SCNNode {
        let container = SCNNode()
        container.name = "sketch_entities"
        let reference = parameters.sketch.reference

        for entity in parameters.sketch.entities {
            let isSelected = selectedEntityIDs.contains(entity.id) || entity.id == selectedLineID
            switch entity {
            case let .line(line):
                let start = offsetWorldPoint(line.start, reference: reference, normalOffsetMeters: CADSketchVisualLayer.sketch)
                let end = offsetWorldPoint(line.end, reference: reference, normalOffsetMeters: CADSketchVisualLayer.sketch)
                container.addChildNode(makeSketchSegmentNode(
                    id: line.id,
                    prefix: "sketch_line_",
                    from: start,
                    to: end,
                    selected: isSelected,
                    construction: line.constructionStyle == .construction
                ))
            case let .rectangle(rectangle):
                let isConstruction = rectangle.constructionStyle == .construction
                container.addChildNode(makeSketchPathNode(
                    id: rectangle.id,
                    prefix: "sketch_rectangle_",
                    points: rectangle.corners,
                    closed: true,
                    reference: reference,
                    selected: isSelected,
                    construction: isConstruction
                ))
            case let .circle(circle):
                let isConstruction = circle.constructionStyle == .construction
                container.addChildNode(makeSketchPathNode(
                    id: circle.id,
                    prefix: "sketch_circle_",
                    points: circle.profilePoints(segments: 64),
                    closed: true,
                    reference: reference,
                    selected: isSelected,
                    construction: isConstruction
                ))
                let center = offsetWorldPoint(circle.center, reference: reference, normalOffsetMeters: CADSketchVisualLayer.points)
                container.addChildNode(makeSketchEndpointNode(id: circle.id, at: center, selected: isSelected))
            case let .polyline(polyline):
                container.addChildNode(makeSketchPathNode(
                    id: polyline.id,
                    prefix: "sketch_polyline_",
                    points: polyline.points,
                    closed: polyline.isClosed,
                    reference: reference,
                    selected: isSelected,
                    construction: polyline.constructionStyle == .construction
                ))
            case let .arc(arc):
                let pts = arc.approximationPoints(segments: 32)
                container.addChildNode(makeSketchPathNode(
                    id: arc.id,
                    prefix: "sketch_arc_",
                    points: pts,
                    closed: false,
                    reference: reference,
                    selected: isSelected,
                    construction: arc.constructionStyle == .construction
                ))
                let startWorld = offsetWorldPoint(arc.start, reference: reference, normalOffsetMeters: CADSketchVisualLayer.points)
                let endWorld   = offsetWorldPoint(arc.end,   reference: reference, normalOffsetMeters: CADSketchVisualLayer.points)
                container.addChildNode(makeSketchEndpointNode(id: arc.id, at: startWorld, selected: isSelected))
                container.addChildNode(makeSketchEndpointNode(id: UUID(), at: endWorld, selected: isSelected))
            }
        }

        if showPoints {
            let selectedEntity = selectedEntityIDs.first.flatMap { parameters.sketch.entity(with: $0) }
            let vertices = parameters.sketch.snapVertices(toleranceMeters: 0.001)
            for vertex in vertices {
                let worldPoint = offsetWorldPoint(vertex, reference: reference, normalOffsetMeters: CADSketchVisualLayer.points)
                let isSelectedVertex = selectedEntity.map { entityContainsPoint($0, vertex, tolerance: 0.001) } ?? false
                container.addChildNode(makeSketchEndpointNode(id: UUID(), at: worldPoint, selected: isSelectedVertex))
            }
            // Midpoint overlay — small diamond markers at the midpoint of every main-sketch edge.
            for entity in parameters.sketch.entities {
                guard entity.constructionStyle != .construction else { continue }
                for (start, end) in sketchEdgePairs(entity) {
                    let mid = SketchPoint2D(u: (start.u + end.u) / 2, v: (start.v + end.v) / 2)
                    let worldMid = offsetWorldPoint(mid, reference: reference, normalOffsetMeters: CADSketchVisualLayer.points)
                    container.addChildNode(makeSketchMidpointMarker(at: worldMid))
                }
            }
        }

        // Constraint glyph overlay — "H", "V", "⊥", "∥" near constrained line midpoints
        if showConstraintGlyphs {
            for constraint in parameters.sketch.constraints {
                guard let entity = parameters.sketch.entity(with: constraint.lineID),
                      entity.constructionStyle != .construction else { continue }
                let glyph = constraintGlyph(for: constraint.kind)
                guard !glyph.isEmpty else { continue }
                let midSketch = entityMidpoint(entity)
                let worldMid = offsetWorldPoint(midSketch, reference: reference,
                                                normalOffsetMeters: CADSketchVisualLayer.points + 0.004)
                container.addChildNode(makeConstraintGlyphNode(glyph, at: worldMid))
            }
        }

        return container
    }

    private static func constraintGlyph(for kind: SketchConstraintKind) -> String {
        switch kind {
        case .horizontal:    return "H"
        case .vertical:      return "V"
        case .perpendicular: return "⊥"
        case .parallel:      return "∥"
        case .fixedStart, .fixedEnd: return "■"
        case .coincident:    return "⊙"
        case .equalLength:   return "="
        }
    }

    private static func entityMidpoint(_ entity: SketchEntity) -> SketchPoint2D {
        switch entity {
        case let .line(line):
            return SketchPoint2D(u: (line.start.u + line.end.u) / 2,
                                 v: (line.start.v + line.end.v) / 2)
        case let .rectangle(rect):
            let u = rect.corners.map(\.u).reduce(0, +) / Double(rect.corners.count)
            let v = rect.corners.map(\.v).reduce(0, +) / Double(rect.corners.count)
            return SketchPoint2D(u: u, v: v)
        case let .circle(circle):
            return circle.center
        case let .polyline(poly):
            guard let mid = poly.points.first else { return .zero }
            return mid
        case let .arc(arc):
            return arc.midPoint
        }
    }

    private static func makeConstraintGlyphNode(_ glyph: String, at point: DesignVector3) -> SCNNode {
        let text = SCNText(string: glyph, extrusionDepth: 0)
        text.font = .systemFont(ofSize: 12)
        text.flatness = 0.4
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents  = CGColor(red: 0.72, green: 0.82, blue: 0.92, alpha: 0.90)
        mat.emission.contents = CGColor(red: 0.18, green: 0.26, blue: 0.40, alpha: 0.55)
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.isDoubleSided = true
        text.firstMaterial = mat

        let textNode = SCNNode(geometry: text)
        // Scale down: SCNText at fontSize 12 produces geometry ~12 units tall; 0.002 → ~24 mm
        let s: Float = 0.002
        textNode.scale = SCNVector3(s, s, s)
        // Center the bounding box
        let (minB, maxB) = textNode.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (minB.x + maxB.x) / 2,
            (minB.y + maxB.y) / 2,
            0
        )

        let container = SCNNode()
        container.name = "constraint_glyph"
        container.renderingOrder = 25
        container.position = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        // Billboard — always face camera
        container.constraints = [SCNBillboardConstraint()]
        container.addChildNode(textNode)
        return container
    }

    private static func makeSketchPathNode(
        id: UUID,
        prefix: String,
        points: [SketchPoint2D],
        closed: Bool,
        reference: SketchReference,
        selected: Bool,
        construction: Bool = false,
        lineStyle: CADLineStyle = .main
    ) -> SCNNode {
        let container = SCNNode()
        container.name = "\(prefix)\(id.uuidString)"
        guard points.count >= 2 else { return container }
        let segmentCount = closed ? points.count : points.count - 1
        for index in 0..<segmentCount {
            let next = (index + 1) % points.count
            let start = offsetWorldPoint(points[index], reference: reference, normalOffsetMeters: CADSketchVisualLayer.sketch)
            let end = offsetWorldPoint(points[next], reference: reference, normalOffsetMeters: CADSketchVisualLayer.sketch)
            container.addChildNode(makeSketchSegmentNode(
                id: id,
                prefix: prefix,
                from: start,
                to: end,
                selected: selected,
                construction: construction,
                lineStyle: lineStyle
            ))
        }
        return container
    }

    private static func makeSketchSegmentNode(
        id: UUID,
        prefix: String,
        from start: DesignVector3,
        to end: DesignVector3,
        selected: Bool,
        construction: Bool = false,
        lineStyle: CADLineStyle = .main
    ) -> SCNNode {
        let sx = Float(start.x), sy = Float(start.y), sz = Float(start.z)
        let ex = Float(end.x),   ey = Float(end.y),   ez = Float(end.z)
        let delta = SIMD3<Float>(ex - sx, ey - sy, ez - sz)
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }

        let renderOrder = construction ? 14 : (selected ? 22 : 21)
        let material = sketchMaterial(selected: selected, construction: construction)

        // Construction lines always thin solid regardless of lineStyle
        if construction {
            return makeSolidCylinderNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, radius: 0.0014, material: material, renderOrder: renderOrder)
        }

        switch lineStyle {
        case .thin:
            return makeSolidCylinderNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, radius: selected ? 0.0024 : 0.0014, material: material, renderOrder: renderOrder)
        case .thick:
            return makeSolidCylinderNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, radius: selected ? 0.0048 : 0.0036, material: material, renderOrder: renderOrder)
        case .center:
            return makeDashedSegmentNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, material: material, renderOrder: renderOrder,
                dashLong: 0.020, dashShort: 0.004, gap: 0.004, radius: selected ? 0.0024 : 0.0014)
        case .hidden:
            return makeDashedSegmentNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, material: material, renderOrder: renderOrder,
                dashLong: 0.010, dashShort: nil, gap: 0.004, radius: selected ? 0.0024 : 0.0014)
        case .breakLine:
            return makeBreakLineSegmentNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, material: material, renderOrder: renderOrder)
        case .main:
            return makeSolidCylinderNode(
                prefix: prefix, id: id, sx: sx, sy: sy, sz: sz, ex: ex, ey: ey, ez: ez,
                delta: delta, length: length, radius: selected ? 0.0032 : 0.0022, material: material, renderOrder: renderOrder)
        }
    }

    private static func makeSolidCylinderNode(
        prefix: String, id: UUID,
        sx: Float, sy: Float, sz: Float, ex: Float, ey: Float, ez: Float,
        delta: SIMD3<Float>, length: Float, radius: CGFloat,
        material: SCNMaterial, renderOrder: Int
    ) -> SCNNode {
        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial = material
        let node = SCNNode(geometry: cylinder)
        node.name = "\(prefix)\(id.uuidString)"
        node.renderingOrder = renderOrder
        node.position = SCNVector3((sx + ex) / 2, (sy + ey) / 2, (sz + ez) / 2)
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
        return node
    }

    // Renders dashed or center-line pattern as multiple cylinders in a container node.
    // dashShort: if nil, renders simple dashes only. If non-nil, renders center-line pattern:
    //   dashLong — gap — dashShort — gap — dashLong — …
    private static func makeDashedSegmentNode(
        prefix: String, id: UUID,
        sx: Float, sy: Float, sz: Float, ex: Float, ey: Float, ez: Float,
        delta: SIMD3<Float>, length: Float, material: SCNMaterial, renderOrder: Int,
        dashLong: Double, dashShort: Double?, gap: Double, radius: CGFloat
    ) -> SCNNode {
        let container = SCNNode()
        container.name = "\(prefix)\(id.uuidString)"
        let dir = simd_normalize(delta)
        let totalLen = Double(length)

        var offset = 0.0
        var useLong = true
        while offset < totalLen {
            let dashLen = useLong ? dashLong : (dashShort ?? dashLong)
            let segLen = min(dashLen, totalLen - offset)
            if segLen > 0.0005 {
                let t0 = Float(offset / totalLen)
                let t1 = Float((offset + segLen) / totalLen)
                let ps = SIMD3<Float>(sx + delta.x * t0, sy + delta.y * t0, sz + delta.z * t0)
                let pe = SIMD3<Float>(sx + delta.x * t1, sy + delta.y * t1, sz + delta.z * t1)
                let mid = (ps + pe) / 2
                let seg = SCNCylinder(radius: radius, height: CGFloat(segLen))
                seg.radialSegmentCount = 6
                seg.firstMaterial = material
                let n = SCNNode(geometry: seg)
                n.renderingOrder = renderOrder
                n.position = SCNVector3(mid.x, mid.y, mid.z)
                n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
                container.addChildNode(n)
            }
            offset += dashLen + gap
            if let short = dashShort {
                if !useLong {
                    useLong = true
                } else {
                    useLong = false
                    _ = short
                }
            }
        }
        return container
    }

    // Renders a zig-zag break-line pattern (freehand break symbol approximation)
    private static func makeBreakLineSegmentNode(
        prefix: String, id: UUID,
        sx: Float, sy: Float, sz: Float, ex: Float, ey: Float, ez: Float,
        delta: SIMD3<Float>, length: Float, material: SCNMaterial, renderOrder: Int
    ) -> SCNNode {
        let container = SCNNode()
        container.name = "\(prefix)\(id.uuidString)"
        guard length > 0.001 else { return container }

        let dir = simd_normalize(delta)
        let perp = SIMD3<Float>(-dir.y, dir.x, 0)   // 2-D perpendicular in sketch plane
        let totalLen = Double(length)
        let zigLen = 0.010    // 10 mm zig-zag period
        let amplitude: Float = 0.005  // 5 mm offset
        let steps = max(Int(totalLen / zigLen), 2)
        let radius: CGFloat = 0.0014

        var pts: [SIMD3<Float>] = []
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let base = SIMD3<Float>(sx + delta.x * t, sy + delta.y * t, sz + delta.z * t)
            let sign: Float = (i % 2 == 0) ? 0 : (i % 4 == 1 ? 1 : -1)
            pts.append(base + perp * (amplitude * sign))
        }
        for i in 0..<pts.count - 1 {
            let ps = pts[i], pe = pts[i + 1]
            let segDelta = pe - ps
            let segLen = simd_length(segDelta)
            guard segLen > 0.0001 else { continue }
            let mid = (ps + pe) / 2
            let seg = SCNCylinder(radius: radius, height: CGFloat(segLen))
            seg.radialSegmentCount = 6
            seg.firstMaterial = material
            let n = SCNNode(geometry: seg)
            n.renderingOrder = renderOrder
            n.position = SCNVector3(mid.x, mid.y, mid.z)
            n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(segDelta))
            container.addChildNode(n)
        }
        return container
    }

    private static func entityContainsPoint(_ entity: SketchEntity, _ point: SketchPoint2D, tolerance: Double) -> Bool {
        switch entity {
        case let .line(line):
            return line.start.distance(to: point) < tolerance || line.end.distance(to: point) < tolerance
        case let .rectangle(rectangle):
            return rectangle.corners.contains { $0.distance(to: point) < tolerance }
        case let .circle(circle):
            return circle.center.distance(to: point) < tolerance
        case let .polyline(polyline):
            return polyline.points.contains { $0.distance(to: point) < tolerance }
        case let .arc(arc):
            return arc.start.distance(to: point) < tolerance
                || arc.end.distance(to: point) < tolerance
                || arc.midPoint.distance(to: point) < tolerance
        }
    }

    // MARK: Snap / Overlay helpers

    /// Returns the (start, end) 2D pairs for every segment of a sketch entity.
    /// Circles and arcs return empty — they have no straight edges for midpoint purposes.
    private static func sketchEdgePairs(_ entity: SketchEntity) -> [(SketchPoint2D, SketchPoint2D)] {
        switch entity {
        case let .line(line):
            return [(line.start, line.end)]
        case let .rectangle(rect):
            let c = rect.corners
            return c.indices.map { i in (c[i], c[(i + 1) % c.count]) }
        case let .polyline(poly):
            guard poly.points.count >= 2 else { return [] }
            return (0..<(poly.points.count - 1)).map { i in (poly.points[i], poly.points[i + 1]) }
        case .circle, .arc:
            return []
        }
    }

    /// Small green diamond marker shown at edge midpoints in the active-sketch overlay.
    private static func makeSketchMidpointMarker(at point: DesignVector3) -> SCNNode {
        let sphere = SCNSphere(radius: 0.0032)
        sphere.segmentCount = 8
        sphere.firstMaterial = sketchMidpointMaterial()
        let node = SCNNode(geometry: sphere)
        node.name = "sketch_midpoint_marker"
        node.renderingOrder = 23
        node.position = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        return node
    }

    private static func sketchMidpointMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents  = CGColor(red: 0.28, green: 1.0, blue: 0.52, alpha: 0.90)
        mat.emission.contents = CGColor(red: 0.06, green: 0.50, blue: 0.16, alpha: 0.70)
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        return mat
    }

    private static func makeFaceInteractionNode(_ face: DesignPlanarFace, hovered: Bool, selected: Bool) -> SCNNode {
        let normal = face.normal.normalized(fallback: .zAxis)
        let offset = selected || hovered ? CADSketchVisualLayer.phantom : CADSketchVisualLayer.cursor
        let corners = [
            face.origin + face.uAxis * face.bounds.minU + face.vAxis * face.bounds.minV + normal * offset,
            face.origin + face.uAxis * face.bounds.maxU + face.vAxis * face.bounds.minV + normal * offset,
            face.origin + face.uAxis * face.bounds.maxU + face.vAxis * face.bounds.maxV + normal * offset,
            face.origin + face.uAxis * face.bounds.minU + face.vAxis * face.bounds.maxV + normal * offset,
        ]
        let vertices = corners.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        let alpha: CGFloat = selected ? 0.30 : (hovered ? 0.17 : 0.0)
        material.transparency = selected || hovered ? 1.0 : 0.0
        material.diffuse.contents = CGColor(red: 0.38, green: 0.72, blue: 1.0, alpha: alpha)
        material.emission.contents = CGColor(red: 0.10, green: 0.28, blue: 0.55, alpha: selected || hovered ? alpha : 0.0)
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.name = "solidFace:\(face.assetID.uuidString):\(face.id.uuidString)"
        node.renderingOrder = selected ? 13 : (hovered ? 12 : 11)
        return node
    }

    private static func makeSketchEndpointNode(id: UUID, at point: DesignVector3, selected: Bool) -> SCNNode {
        let sphere = SCNSphere(radius: selected ? 0.006 : 0.0045)
        sphere.segmentCount = 10
        sphere.firstMaterial = sketchEndpointMaterial(selected: selected)
        let node = SCNNode(geometry: sphere)
        node.name = "sketch_endpoint_\(id.uuidString)"
        node.renderingOrder = selected ? 24 : 23
        node.position = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        return node
    }

    private static func sketchMaterial(selected: Bool, construction: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        if construction {
            // Clearly purple construction geometry — distinct from main sketch geometry
            material.diffuse.contents  = selected
                ? CGColor(red: 0.88, green: 0.50, blue: 1.0, alpha: 0.95)
                : CGColor(red: 0.68, green: 0.30, blue: 0.92, alpha: 0.78)
            material.emission.contents = CGColor(red: 0.32, green: 0.08, blue: 0.52, alpha: 0.55)
        } else {
            material.diffuse.contents = selected
                ? CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                : CGColor(red: 0.24, green: 0.84, blue: 1.0, alpha: 1.0)
            material.emission.contents = selected
                ? CGColor(red: 0.30, green: 0.44, blue: 0.62, alpha: 0.85)
                : CGColor(red: 0.05, green: 0.38, blue: 0.55, alpha: 0.75)
        }
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        return material
    }

    private static func sketchEndpointMaterial(selected: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = selected
            ? CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            : CGColor(red: 0.75, green: 0.95, blue: 1.0, alpha: 1.0)
        material.emission.contents = selected
            ? CGColor(red: 0.28, green: 0.40, blue: 0.58, alpha: 0.80)
            : CGColor(red: 0.12, green: 0.42, blue: 0.55, alpha: 0.65)
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        return material
    }

    // MARK: Attachment markers

    private static func makeAttachmentMarker(point: AttachmentPoint, selected: Bool) -> SCNNode {
        let markerNode = SCNNode()
        let alpha: CGFloat = point.isEnabled ? 1.0 : 0.25
        let sphere = SCNSphere(radius: selected ? 0.008 : 0.006)
        sphere.segmentCount = 10
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        let color = point.role.markerRGB
        let r = CGFloat(color.r)
        let g = CGFloat(color.g)
        let b = CGFloat(color.b)
        mat.diffuse.contents  = CGColor(red: r, green: g, blue: b, alpha: alpha)
        mat.emission.contents = CGColor(red: r * 0.6, green: g * 0.6, blue: b * 0.6, alpha: selected ? 0.95 : 0.55)
        mat.transparency = alpha
        sphere.firstMaterial = mat
        markerNode.addChildNode(SCNNode(geometry: sphere))

        if selected {
            let halo = SCNTorus(ringRadius: 0.013, pipeRadius: 0.0012)
            halo.ringSegmentCount = 24
            halo.pipeSegmentCount = 6
            let haloMaterial = SCNMaterial()
            haloMaterial.lightingModel = .constant
            haloMaterial.diffuse.contents = CGColor(red: r, green: g, blue: b, alpha: 0.85)
            haloMaterial.emission.contents = CGColor(red: r, green: g, blue: b, alpha: 0.35)
            halo.firstMaterial = haloMaterial
            let haloNode = SCNNode(geometry: halo)
            markerNode.addChildNode(haloNode)
        }

        return markerNode
    }

    // MARK: Material

    private static func makeMaterial(for kind: DesignAssetKind, designMaterial: DesignMaterial) -> SCNMaterial {
        let mat = SCNMaterial()
        let rgb = designMaterial.previewColorRGB
        mat.diffuse.contents   = CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1.0)
        mat.specular.contents  = CGColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1.0)
        mat.shininess = designMaterial == .carbonFiber ? 0.12 : 0.55
        mat.lightingModel = .phong
        mat.transparency = 1.0          // fully opaque
        mat.writesToDepthBuffer = true
        // Explicit normals and corrected triangle winding are required before single-sided
        // body materials are safe. Otherwise incorrectly-oriented faces disappear under
        // front-face culling or leak through XRay cut previews.
        if case .extrudedSolid = kind {
            mat.isDoubleSided = false
        } else {
            mat.isDoubleSided = true
        }
        return mat
    }

    // MARK: Highlight

    static func applyHighlight(_ node: SCNNode, selected: Bool) {
        node.childNodes.first?.geometry?.firstMaterial?.emission.contents =
            selected
                ? CGColor(red: 0.18, green: 0.55, blue: 0.92, alpha: 0.35)
                : CGColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
}
