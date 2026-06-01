import SwiftUI
import SceneKit
import simd

struct DesignPreviewSceneViewRepresentable: NSViewRepresentable {
    typealias NSViewType = CADCanvasView
    private static let cadTransientRootNodeName = "cad.cut.transientRoot"
    private static let cutPreviewNodeName = "cad.cut.preview"
    private static let cutterVolumeNodeName = "cad.cut.cutterVolume"
    private static let cutSelectionHighlightNodeName = "cad.cut.selectionHighlight"
    private static let cutDebugNodePrefix = "cad.cut.debug"
    private static let cutHighlightNodePrefix = "cad.cut.highlight"
    private static let legacyCadTransientRootNodeName = "cadTransientRootNode"
    private static let legacyCutPreviewNodeName = "CutToolPreviewNode"
    private static let legacyExtrudePreviewNodeName = "feature_preview"

    let document: DesignDocument
    let viewportState: DesignViewportState
    let cameraCommand: CADPreviewCameraCommand?
    let lineToolState: LineToolState
    let rectangleToolState: RectangleToolState
    let circleToolState: CircleToolState
    let arcToolState: ArcToolState
    let autolineToolState: AutolineToolState
    let constructionToolState: ConstructionToolState
    let sketchMoveToolState: SketchMoveToolState
    let sketchParallelToolState: SketchParallelToolState
    let sketchSplitToolState: SketchSplitToolState
    let onMouseMoved: ((CADSnapResult) -> Void)?
    let onMouseDown: ((CADSnapResult) -> Void)?
    let onSketchLineSelected: ((UUID?) -> Void)?
    let onSolidFaceSelected: ((UUID?) -> Void)?
    let onWorkPlaneHovered: ((CADWorkPlane?) -> Void)?
    let onWorkPlaneSelected: ((CADWorkPlane?, CGPoint, Bool) -> Void)?
    let onKeyCode: ((UInt16, String?) -> Void)?
    let onEntityDragBegan: ((UUID) -> Void)?
    let onEntityDragMoved: ((SketchPoint2D) -> Void)?
    let onEntityDragEnded: ((SketchPoint2D) -> Void)?
    let onEntityDragCanceled: (() -> Void)?
    let onSketchEntityShiftSelected: ((UUID?) -> Void)?

    private struct CADCutArtifactDiagnostics {
        var transientCutNodeCount: Int
        var cutterPreviewNodeCount: Int
        var ghostTransparentNodeCount: Int
        var bodyOpaqueStateRestored: Bool
        var bodyTransparentMaterialCount: Int
        var bodyRenderingOrderAnomalyCount: Int
        var previewNodesRemovedAfterApply: Bool
    }

    init(
        document: DesignDocument,
        viewportState: DesignViewportState,
        cameraCommand: CADPreviewCameraCommand? = nil,
        lineToolState: LineToolState = LineToolState(),
        rectangleToolState: RectangleToolState = RectangleToolState(),
        circleToolState: CircleToolState = CircleToolState(),
        arcToolState: ArcToolState = ArcToolState(),
        autolineToolState: AutolineToolState = AutolineToolState(),
        constructionToolState: ConstructionToolState = ConstructionToolState(),
        sketchMoveToolState: SketchMoveToolState = SketchMoveToolState(),
        sketchParallelToolState: SketchParallelToolState = SketchParallelToolState(),
        sketchSplitToolState: SketchSplitToolState = SketchSplitToolState(),
        onMouseMoved: ((CADSnapResult) -> Void)? = nil,
        onMouseDown: ((CADSnapResult) -> Void)? = nil,
        onSketchLineSelected: ((UUID?) -> Void)? = nil,
        onSolidFaceSelected: ((UUID?) -> Void)? = nil,
        onWorkPlaneHovered: ((CADWorkPlane?) -> Void)? = nil,
        onWorkPlaneSelected: ((CADWorkPlane?, CGPoint, Bool) -> Void)? = nil,
        onKeyCode: ((UInt16, String?) -> Void)? = nil,
        onEntityDragBegan: ((UUID) -> Void)? = nil,
        onEntityDragMoved: ((SketchPoint2D) -> Void)? = nil,
        onEntityDragEnded: ((SketchPoint2D) -> Void)? = nil,
        onEntityDragCanceled: (() -> Void)? = nil,
        onSketchEntityShiftSelected: ((UUID?) -> Void)? = nil
    ) {
        self.document = document
        self.viewportState = viewportState
        self.cameraCommand = cameraCommand
        self.lineToolState = lineToolState
        self.rectangleToolState = rectangleToolState
        self.circleToolState = circleToolState
        self.arcToolState = arcToolState
        self.autolineToolState = autolineToolState
        self.constructionToolState = constructionToolState
        self.sketchMoveToolState = sketchMoveToolState
        self.sketchParallelToolState = sketchParallelToolState
        self.sketchSplitToolState = sketchSplitToolState
        self.onMouseMoved = onMouseMoved
        self.onMouseDown = onMouseDown
        self.onSketchLineSelected = onSketchLineSelected
        self.onSolidFaceSelected = onSolidFaceSelected
        self.onWorkPlaneHovered = onWorkPlaneHovered
        self.onWorkPlaneSelected = onWorkPlaneSelected
        self.onKeyCode = onKeyCode
        self.onEntityDragBegan = onEntityDragBegan
        self.onEntityDragMoved = onEntityDragMoved
        self.onEntityDragEnded = onEntityDragEnded
        self.onEntityDragCanceled = onEntityDragCanceled
        self.onSketchEntityShiftSelected = onSketchEntityShiftSelected
    }

    // MARK: Coordinator

    final class Coordinator: NSObject {
        var lastCameraCommandID: UUID?
        var lastDocument: DesignDocument?
        var lastViewportState: DesignViewportState?
        var document: DesignDocument = DesignDocument()

        // Line tool state
        var activeSketchPlane: SketchPlane = .xz
        var activeSketchPlaneOffset: Double = 0
        var activeSketchReference: SketchReference = .canonicalPlane(.xz, offsetMeters: 0)
        var snapOptions: CADSnapOptions = CADSnapOptions()
        var isSketchPlacementToolActive: Bool = false
        var isSketch2DMode: Bool = false
        var mouseDownPoint: CGPoint?
        var lastSketchPanPoint: CGPoint?

        // Direct-manipulation drag state
        var dragCandidateEntityID: UUID?
        var dragStartSketchPoint: SketchPoint2D?
        var dragAnchorSketchPoint: SketchPoint2D?
        var dragCursorToAnchorOffset: SketchPoint2D?
        var isDraggingEntity: Bool = false
        // True when left drag should pan the viewport (Copy tool).
        var isSketchPanMode: Bool = false
        // True when the active tool is sketchMove — drag on entity moves it, drag on empty pans.
        var isSketchMoveMode: Bool = false
        // Base positions of preview entity nodes, captured at drag start.
        var previewNodeBasePositions: [String: simd_float3] = [:]
        var featurePreviewNodeRebuildCount: Int = 0
        var assetGeometryRebuildCount: Int = 0

        // Callbacks
        var onMouseMoved: ((CADSnapResult) -> Void)?
        var onMouseDown: ((CADSnapResult) -> Void)?
        var onSketchLineSelected: ((UUID?) -> Void)?
        var onSolidFaceSelected: ((UUID?) -> Void)?
        var onWorkPlaneHovered: ((CADWorkPlane?) -> Void)?
        var onWorkPlaneSelected: ((CADWorkPlane?, CGPoint, Bool) -> Void)?
        var onKeyCode: ((UInt16, String?) -> Void)?
        var onEntityDragBegan: ((UUID) -> Void)?
        var onEntityDragMoved: ((SketchPoint2D) -> Void)?
        var onEntityDragEnded: ((SketchPoint2D) -> Void)?
        var onEntityDragCanceled: (() -> Void)?
        var onSketchEntityShiftSelected: ((UUID?) -> Void)?

        func projectToSketchPlane(screenPoint: CGPoint, in view: CADCanvasView) -> SketchPoint2D? {
            let sp = SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 0)
            let ep = SCNVector3(Float(screenPoint.x), Float(screenPoint.y), 1)
            let near = view.unprojectPoint(sp)
            let far  = view.unprojectPoint(ep)
            let dir  = SCNVector3(far.x - near.x, far.y - near.y, far.z - near.z)

            let n = normalVector(for: activeSketchReference)
            let o = originForSketchReference(activeSketchReference)
            let normal = SCNVector3(Float(n.x), Float(n.y), Float(n.z))
            let planePoint = SCNVector3(Float(o.x), Float(o.y), Float(o.z))

            let denom = normal.x * dir.x + normal.y * dir.y + normal.z * dir.z
            guard abs(denom) > 0.0001 else { return nil }
            let dp = SCNVector3(planePoint.x - near.x, planePoint.y - near.y, planePoint.z - near.z)
            let t = (normal.x * dp.x + normal.y * dp.y + normal.z * dp.z) / denom
            // Guard against near-grazing camera angle: t >> camera distance means coordinates will explode.
            // In normal CAD usage (orthographic sketch mode) t is the camera-to-plane distance, typically < 50m.
            guard t.isFinite, abs(t) < 500.0 else { return nil }
            let hit = SCNVector3(near.x + t * dir.x, near.y + t * dir.y, near.z + t * dir.z)
            let world = DesignVector3(x: Double(hit.x), y: Double(hit.y), z: Double(hit.z))
            let result = worldPointToSketch(world, reference: activeSketchReference)
            // Final sanity check: reject non-finite or absurd U/V values (> 100m workspace limit).
            guard result.u.isFinite, result.v.isFinite,
                  abs(result.u) < 100.0, abs(result.v) < 100.0 else { return nil }
            return result
        }

        private func snapResult(for rawPoint: SketchPoint2D, screenPoint: CGPoint, in view: CADCanvasView) -> CADSnapResult {
            let swiftPt = swiftUIPoint(from: screenPoint, in: view)
            let rawWorld = sketchPointToWorld(rawPoint, reference: activeSketchReference)
            guard snapOptions.isEnabled else {
                return CADSnapResult(rawPoint: rawPoint, point: rawPoint, screenPoint: swiftPt, kind: nil, displayName: nil, worldPoint: rawWorld)
            }

            let tolerance = min(max(snapOptions.snapTolerancePixels, 4), 48)
            let candidates = snapCandidates(near: rawPoint)
            let ranked = candidates.compactMap { candidate -> (candidate: CADSnapCandidate, distance: Double)? in
                let distance = screenDistance(from: candidate.worldPoint, to: screenPoint, in: view)
                guard distance.isFinite, distance <= tolerance else { return nil }
                return (candidate, distance)
            }
            .sorted {
                if $0.candidate.priority == $1.candidate.priority { return $0.distance < $1.distance }
                return $0.candidate.priority < $1.candidate.priority
            }

            if let best = ranked.first?.candidate {
                return CADSnapResult(rawPoint: rawPoint, point: best.sketchPoint, screenPoint: swiftPt, kind: best.kind, displayName: best.displayName, worldPoint: best.worldPoint, edgeStartWorld: best.edgeStartWorld, edgeEndWorld: best.edgeEndWorld)
            }

            if snapOptions.effectiveSnapToGrid {
                let gridPoint = snapToGrid(rawPoint)
                return CADSnapResult(rawPoint: rawPoint, point: gridPoint, screenPoint: swiftPt, kind: .grid, displayName: CADSnapKind.grid.displayName, worldPoint: sketchPointToWorld(gridPoint, reference: activeSketchReference))
            }

            return CADSnapResult(rawPoint: rawPoint, point: rawPoint, screenPoint: swiftPt, kind: nil, displayName: nil, worldPoint: rawWorld)
        }

        private func snapCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            var candidates: [CADSnapCandidate] = []
            // 1. Active sketch geometry (highest priority)
            if snapOptions.snapToSketchVertices {
                candidates.append(contentsOf: sketchVertexCandidates())
                candidates.append(contentsOf: circleCenterCandidates())
            }
            candidates.append(contentsOf: sketchEdgeCandidates(near: rawPoint))
            // 2. Reference sketches (same plane) and projected sketches (cross plane)
            if snapOptions.snapToReferenceSketches {
                candidates.append(contentsOf: referenceSketchCandidates())
                candidates.append(contentsOf: projectedSketchCandidates())
            }
            // 3. Body snap — face-specific for planar-face sketches, projected for canonical planes
            if case .planarFace = activeSketchReference {
                candidates.append(contentsOf: bodyFaceCandidates(near: rawPoint))
            } else {
                candidates.append(contentsOf: extrudedBodyCandidates(near: rawPoint))
            }
            // 4. Construction geometry
            candidates.append(contentsOf: constructionVertexCandidates())
            candidates.append(contentsOf: constructionLineCandidates(near: rawPoint))
            candidates.append(contentsOf: constructionIntersectionCandidates(near: rawPoint))
            // Note: grid is NOT a candidate — it's a separate fallback in snapResult().
            // This guarantees grid can never outrank any geometry candidate.
            return candidates
        }

        private func circleCenterCandidates() -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference else { return [] }
            return sketch.circles.compactMap { circle in
                guard circle.constructionStyle != .construction else { return nil }
                let world = sketchPointToWorld(circle.center, reference: activeSketchReference)
                return CADSnapCandidate(
                    kind: .activeCircleCenter,
                    worldPoint: world,
                    sketchPoint: circle.center,
                    displayName: CADSnapKind.activeCircleCenter.displayName,
                    priority: CADSnapKind.activeCircleCenter.priority
                )
            }
        }

        private func otherSketchAssets() -> [(asset: DesignAsset, params: SketchAssetParameters)] {
            let activeID = document.selectedAssetID
            return document.assets.compactMap { asset in
                guard asset.id != activeID,
                      case let .sketch2D(params) = asset.kind else { return nil }
                return (asset, params)
            }
        }

        private func referenceSketchCandidates() -> [CADSnapCandidate] {
            var candidates: [CADSnapCandidate] = []
            for entry in otherSketchAssets() {
                guard entry.params.sketch.reference == activeSketchReference else { continue }
                let label = entry.asset.name
                let sketch = entry.params.sketch
                // Vertices from all entity types
                for point in sketch.snapVertices() {
                    let world = sketchPointToWorld(point, reference: activeSketchReference)
                    candidates.append(CADSnapCandidate(
                        kind: .referenceSketchVertex,
                        worldPoint: world,
                        sketchPoint: point,
                        sourceAssetID: entry.asset.id,
                        displayName: NSLocalizedString("cad.snap.reference_sketch_vertex", comment: "") + " · " + label,
                        priority: CADSnapKind.referenceSketchVertex.priority
                    ))
                }
                // Edge midpoints
                for entity in sketch.entities {
                    guard entity.constructionStyle != .construction else { continue }
                    for (start, end) in sketchEntityEdges(entity) {
                        let mid = SketchPoint2D(u: (start.u + end.u) / 2, v: (start.v + end.v) / 2)
                        let world = sketchPointToWorld(mid, reference: activeSketchReference)
                        candidates.append(CADSnapCandidate(
                            kind: .referenceSketchEdgeMidpoint,
                            worldPoint: world,
                            sketchPoint: mid,
                            sourceAssetID: entry.asset.id,
                            displayName: NSLocalizedString("cad.snap.reference_sketch_edge_midpoint", comment: "") + " · " + label,
                            priority: CADSnapKind.referenceSketchEdgeMidpoint.priority
                        ))
                    }
                }
                // Circle centers from reference sketch
                for circle in sketch.circles {
                    guard circle.constructionStyle != .construction else { continue }
                    let world = sketchPointToWorld(circle.center, reference: activeSketchReference)
                    candidates.append(CADSnapCandidate(
                        kind: .referenceSketchVertex,
                        worldPoint: world,
                        sketchPoint: circle.center,
                        sourceAssetID: entry.asset.id,
                        displayName: NSLocalizedString("cad.snap.circle_center", comment: "") + " · " + label,
                        priority: CADSnapKind.referenceSketchVertex.priority
                    ))
                }
            }
            return candidates
        }

        private func projectedSketchCandidates() -> [CADSnapCandidate] {
            var candidates: [CADSnapCandidate] = []
            for entry in otherSketchAssets() {
                let otherRef = entry.params.sketch.reference
                guard otherRef != activeSketchReference else { continue }
                let label = entry.asset.name
                let sketch = entry.params.sketch
                // Project vertices
                for point in sketch.snapVertices() {
                    let worldPt = sketchPointToWorld(point, reference: otherRef)
                    let proj = worldPointToSketch(worldPt, reference: activeSketchReference)
                    guard proj.u.isFinite, proj.v.isFinite else { continue }
                    candidates.append(CADSnapCandidate(
                        kind: .projectedSketchVertex,
                        worldPoint: sketchPointToWorld(proj, reference: activeSketchReference),
                        sketchPoint: proj,
                        sourceAssetID: entry.asset.id,
                        displayName: NSLocalizedString("cad.snap.projected_sketch_vertex", comment: "") + " · " + label,
                        priority: CADSnapKind.projectedSketchVertex.priority
                    ))
                }
                // Project edge midpoints
                for entity in sketch.entities {
                    guard entity.constructionStyle != .construction else { continue }
                    for (start, end) in sketchEntityEdges(entity) {
                        let midLocal = SketchPoint2D(u: (start.u + end.u) / 2, v: (start.v + end.v) / 2)
                        let midWorld = sketchPointToWorld(midLocal, reference: otherRef)
                        let proj = worldPointToSketch(midWorld, reference: activeSketchReference)
                        guard proj.u.isFinite, proj.v.isFinite else { continue }
                        candidates.append(CADSnapCandidate(
                            kind: .projectedSketchEdgeMidpoint,
                            worldPoint: sketchPointToWorld(proj, reference: activeSketchReference),
                            sketchPoint: proj,
                            sourceAssetID: entry.asset.id,
                            displayName: NSLocalizedString("cad.snap.projected_sketch_edge_midpoint", comment: "") + " · " + label,
                            priority: CADSnapKind.projectedSketchEdgeMidpoint.priority
                        ))
                    }
                }
                // Project circle centers
                for circle in sketch.circles {
                    guard circle.constructionStyle != .construction else { continue }
                    let worldPt = sketchPointToWorld(circle.center, reference: otherRef)
                    let proj = worldPointToSketch(worldPt, reference: activeSketchReference)
                    guard proj.u.isFinite, proj.v.isFinite else { continue }
                    candidates.append(CADSnapCandidate(
                        kind: .projectedSketchVertex,
                        worldPoint: sketchPointToWorld(proj, reference: activeSketchReference),
                        sketchPoint: proj,
                        sourceAssetID: entry.asset.id,
                        displayName: NSLocalizedString("cad.snap.projected_circle_center", comment: "") + " · " + label,
                        priority: CADSnapKind.projectedSketchVertex.priority
                    ))
                }
            }
            return candidates
        }

        private func sketchEntityEdges(_ entity: SketchEntity) -> [(SketchPoint2D, SketchPoint2D)] {
            switch entity {
            case let .line(line):
                return [(line.start, line.end)]
            case let .rectangle(rect):
                let corners = rect.corners
                return corners.indices.map { i in (corners[i], corners[(i + 1) % corners.count]) }
            case let .polyline(poly):
                guard poly.points.count >= 2 else { return [] }
                return (0..<(poly.points.count - 1)).map { i in (poly.points[i], poly.points[i + 1]) }
            case .circle, .arc:
                return []
            }
        }

        private func sketchEdgeCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference,
                  snapOptions.snapToEdgeMidpoints || snapOptions.snapToBodyEdges else { return [] }
            var candidates: [CADSnapCandidate] = []
            for entity in sketch.entities {
                // Skip ALL construction-style entities — they get their own snap pass.
                // Previously only construction Lines were filtered; rectangles/polylines were not.
                guard entity.constructionStyle != .construction else { continue }
                for (start, end) in sketchEntityEdges(entity) {
                    let startWorld = sketchPointToWorld(start, reference: activeSketchReference)
                    let endWorld   = sketchPointToWorld(end,   reference: activeSketchReference)
                    if snapOptions.snapToEdgeMidpoints {
                        let mid = SketchPoint2D(u: (start.u + end.u) / 2, v: (start.v + end.v) / 2)
                        candidates.append(CADSnapCandidate(
                            kind: .edgeMidpoint,
                            worldPoint: sketchPointToWorld(mid, reference: activeSketchReference),
                            sketchPoint: mid,
                            sourceAssetID: nil,
                            sourceFaceID: nil,
                            sourceEntityID: entity.id,
                            displayName: CADSnapKind.edgeMidpoint.displayName,
                            priority: CADSnapKind.edgeMidpoint.priority,
                            edgeStartWorld: startWorld, edgeEndWorld: endWorld
                        ))
                    }
                    if snapOptions.snapToBodyEdges {
                        let edgePt = closestPoint(rawPoint, onSegmentFrom: start, to: end)
                        candidates.append(CADSnapCandidate(
                            kind: .bodyEdge,
                            worldPoint: sketchPointToWorld(edgePt, reference: activeSketchReference),
                            sketchPoint: edgePt,
                            sourceAssetID: nil,
                            sourceFaceID: nil,
                            sourceEntityID: entity.id,
                            displayName: CADSnapKind.bodyEdge.displayName,
                            priority: CADSnapKind.bodyEdge.priority,
                            edgeStartWorld: startWorld, edgeEndWorld: endWorld
                        ))
                    }
                }
            }
            return candidates
        }

        private func sketchVertexCandidates() -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference else { return [] }

            return sketch.snapVertices().map { point in
                CADSnapCandidate(
                    kind: .sketchVertex,
                    worldPoint: sketchPointToWorld(point, reference: activeSketchReference),
                    sketchPoint: point,
                    sourceAssetID: nil,
                    sourceFaceID: nil,
                    displayName: CADSnapKind.sketchVertex.displayName,
                    priority: 0
                )
            }
        }

        private func constructionVertexCandidates() -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference,
                  snapOptions.snapToConstructionPoints else { return [] }
            var candidates: [CADSnapCandidate] = []
            for entity in sketch.entities {
                guard case let .line(line) = entity, line.constructionStyle == .construction else { continue }
                for point in [line.start, line.end] {
                    candidates.append(CADSnapCandidate(
                        kind: .constructionVertex,
                        worldPoint: sketchPointToWorld(point, reference: activeSketchReference),
                        sketchPoint: point,
                        sourceAssetID: nil, sourceFaceID: nil,
                        displayName: CADSnapKind.constructionVertex.displayName,
                        priority: CADSnapKind.constructionVertex.priority
                    ))
                }
            }
            return candidates
        }

        private func constructionLineCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference,
                  snapOptions.snapToConstructionLines else { return [] }
            var candidates: [CADSnapCandidate] = []
            for entity in sketch.entities {
                guard case let .line(line) = entity, line.constructionStyle == .construction else { continue }
                let closestPt = closestPoint(rawPoint, onSegmentFrom: line.start, to: line.end)
                let startWorld = sketchPointToWorld(line.start, reference: activeSketchReference)
                let endWorld   = sketchPointToWorld(line.end,   reference: activeSketchReference)
                candidates.append(CADSnapCandidate(
                    kind: .constructionLine,
                    worldPoint: sketchPointToWorld(closestPt, reference: activeSketchReference),
                    sketchPoint: closestPt,
                    sourceAssetID: nil, sourceFaceID: nil,
                    displayName: CADSnapKind.constructionLine.displayName,
                    priority: CADSnapKind.constructionLine.priority,
                    edgeStartWorld: startWorld,
                    edgeEndWorld: endWorld
                ))
            }
            return candidates
        }

        private func constructionIntersectionCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            guard let sketch = activeSketchForLineTool(),
                  sketch.reference == activeSketchReference,
                  snapOptions.snapToConstructionIntersections else { return [] }
            let constructionLines: [SketchLine] = sketch.entities.compactMap { entity in
                guard case let .line(line) = entity, line.constructionStyle == .construction else { return nil }
                return line
            }
            let mainLines: [SketchLine] = sketch.entities.compactMap { entity in
                guard case let .line(line) = entity, line.constructionStyle == .main else { return nil }
                return line
            }
            var candidates: [CADSnapCandidate] = []
            for i in constructionLines.indices {
                for j in (i + 1)..<constructionLines.count {
                    if let pt = lineIntersect2D(constructionLines[i].start, constructionLines[i].end,
                                                constructionLines[j].start, constructionLines[j].end) {
                        candidates.append(CADSnapCandidate(
                            kind: .constructionIntersection,
                            worldPoint: sketchPointToWorld(pt, reference: activeSketchReference),
                            sketchPoint: pt,
                            sourceAssetID: nil, sourceFaceID: nil,
                            displayName: CADSnapKind.constructionIntersection.displayName,
                            priority: CADSnapKind.constructionIntersection.priority
                        ))
                    }
                }
            }
            for cLine in constructionLines {
                for mLine in mainLines {
                    if let pt = lineIntersect2D(cLine.start, cLine.end, mLine.start, mLine.end) {
                        candidates.append(CADSnapCandidate(
                            kind: .constructionIntersection,
                            worldPoint: sketchPointToWorld(pt, reference: activeSketchReference),
                            sketchPoint: pt,
                            sourceAssetID: nil, sourceFaceID: nil,
                            displayName: CADSnapKind.constructionIntersection.displayName,
                            priority: CADSnapKind.constructionIntersection.priority
                        ))
                    }
                }
            }
            return candidates
        }

        private func lineIntersect2D(
            _ p1: SketchPoint2D, _ p2: SketchPoint2D,
            _ p3: SketchPoint2D, _ p4: SketchPoint2D
        ) -> SketchPoint2D? {
            let d1u = p2.u - p1.u, d1v = p2.v - p1.v
            let d2u = p4.u - p3.u, d2v = p4.v - p3.v
            let denom = d1u * d2v - d1v * d2u
            guard abs(denom) > 1e-12 else { return nil }
            let t = ((p3.u - p1.u) * d2v - (p3.v - p1.v) * d2u) / denom
            let u = p1.u + t * d1u
            let v = p1.v + t * d1v
            guard u.isFinite, v.isFinite, abs(u) < 100.0, abs(v) < 100.0 else { return nil }
            return SketchPoint2D(u: u, v: v)
        }

        private func activeSketchForLineTool() -> DesignSketch? {
            guard let selected = document.selectedAsset,
                  case let .sketch2D(parameters) = selected.kind else { return nil }
            return parameters.sketch
        }

        private func bodyFaceCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            guard case let .planarFace(faceReference) = activeSketchReference,
                  let asset = document.assets.first(where: { $0.id == faceReference.sourceAssetID }),
                  case let .extrudedSolid(parameters) = asset.kind,
                  let faceIndex = parameters.faces.firstIndex(where: { $0.id == faceReference.faceID }) else { return [] }

            let face = parameters.faces[faceIndex]
            let vertices = faceVertices(parameters: parameters, faceIndex: faceIndex)
            guard vertices.count >= 2 else { return [] }

            let vertexSketchPoints = vertices.map { worldPointToSketch($0, reference: activeSketchReference) }
            var candidates: [CADSnapCandidate] = []

            if snapOptions.snapToBodyVertices {
                for index in vertices.indices {
                    candidates.append(
                        CADSnapCandidate(
                            kind: .bodyVertex,
                            worldPoint: vertices[index],
                            sketchPoint: vertexSketchPoints[index],
                            sourceAssetID: face.assetID,
                            sourceFaceID: face.id,
                            displayName: CADSnapKind.bodyVertex.displayName,
                            priority: CADSnapKind.bodyVertex.priority
                        )
                    )
                }
            }

            for index in vertices.indices {
                let next = (index + 1) % vertices.count
                let startWorld = vertices[index]
                let endWorld = vertices[next]
                let startSketch = vertexSketchPoints[index]
                let endSketch = vertexSketchPoints[next]

                if snapOptions.snapToEdgeMidpoints {
                    let midpointSketch = SketchPoint2D(
                        u: (startSketch.u + endSketch.u) / 2,
                        v: (startSketch.v + endSketch.v) / 2
                    )
                    let midpointWorld = sketchPointToWorld(midpointSketch, reference: activeSketchReference)
                    candidates.append(
                        CADSnapCandidate(
                            kind: .edgeMidpoint,
                            worldPoint: midpointWorld,
                            sketchPoint: midpointSketch,
                            sourceAssetID: face.assetID,
                            sourceFaceID: face.id,
                            displayName: CADSnapKind.edgeMidpoint.displayName,
                            priority: CADSnapKind.edgeMidpoint.priority,
                            edgeStartWorld: startWorld,
                            edgeEndWorld: endWorld
                        )
                    )
                }

                if snapOptions.snapToBodyEdges {
                    let edgePoint = closestPoint(rawPoint, onSegmentFrom: startSketch, to: endSketch)
                    candidates.append(
                        CADSnapCandidate(
                            kind: .bodyEdge,
                            worldPoint: sketchPointToWorld(edgePoint, reference: activeSketchReference),
                            sketchPoint: edgePoint,
                            sourceAssetID: face.assetID,
                            sourceFaceID: face.id,
                            displayName: CADSnapKind.bodyEdge.displayName,
                            priority: CADSnapKind.bodyEdge.priority,
                            edgeStartWorld: startWorld,
                            edgeEndWorld: endWorld
                        )
                    )
                }
            }
            return candidates
        }

        private func faceVertices(parameters: ExtrudedSolidParameters, faceIndex: Int) -> [DesignVector3] {
            guard parameters.profilePoints.count >= 3 else { return [] }

            let axes = axesForSketchReference(parameters.sourceReference)
            let normal = axes.normal.normalized(fallback: .zAxis)
            let (frontOffset, backOffset) = parameters.direction.offsets(depth: parameters.depthMeters)
            let basePoints = parameters.profilePoints.map { sketchPointToWorld($0, reference: parameters.sourceReference) }
            let frontPoints = basePoints.map { $0 + normal * frontOffset }
            let backPoints = basePoints.map { $0 + normal * backOffset }

            if faceIndex == 0 {
                return frontPoints
            }
            if faceIndex == 1 {
                return backPoints
            }

            let segmentIndex = faceIndex - 2
            guard segmentIndex >= 0, segmentIndex < parameters.profilePoints.count else { return [] }
            let next = (segmentIndex + 1) % parameters.profilePoints.count
            return [
                frontPoints[segmentIndex],
                frontPoints[next],
                backPoints[next],
                backPoints[segmentIndex],
            ]
        }

        /// Collects body vertex/edge snap candidates from ALL extruded solids in the document,
        /// projecting their 3D vertices onto the active canonical sketch plane.
        /// Used when activeSketchReference is a canonical plane (XY/XZ/YZ), where
        /// bodyFaceCandidates() does not fire (that function is only for planar-face sketches).
        private func extrudedBodyCandidates(near rawPoint: SketchPoint2D) -> [CADSnapCandidate] {
            guard snapOptions.snapToBodyVertices || snapOptions.snapToEdgeMidpoints || snapOptions.snapToBodyEdges else { return [] }
            var candidates: [CADSnapCandidate] = []
            let bodyVertexLabel = NSLocalizedString("cad.snap.body_vertex_solid", comment: "")
            let bodyMidLabel    = NSLocalizedString("cad.snap.body_edge_midpoint", comment: "")
            let bodyEdgeLabel   = NSLocalizedString("cad.snap.body_edge", comment: "")

            for asset in document.assets {
                guard case let .extrudedSolid(params) = asset.kind,
                      params.profilePoints.count >= 2 else { continue }
                let n = params.profilePoints.count
                let normal = normalVector(for: params.sourceReference)
                let (frontOff, backOff) = params.direction.offsets(depth: params.depthMeters)
                let baseWorld = params.profilePoints.map { sketchPointToWorld($0, reference: params.sourceReference) }
                let frontWorld = baseWorld.map { $0 + normal * frontOff }
                let backWorld  = baseWorld.map { $0 + normal * backOff }

                // Project each 3D vertex onto the active sketch plane
                let allVertices = frontWorld + backWorld
                if snapOptions.snapToBodyVertices {
                    for worldPt in allVertices {
                        let projected = worldPointToSketch(worldPt, reference: activeSketchReference)
                        guard projected.u.isFinite, projected.v.isFinite,
                              abs(projected.u) < 100, abs(projected.v) < 100 else { continue }
                        let projWorld = sketchPointToWorld(projected, reference: activeSketchReference)
                        candidates.append(CADSnapCandidate(
                            kind: .bodyVertex,
                            worldPoint: projWorld,
                            sketchPoint: projected,
                            sourceAssetID: asset.id,
                            displayName: bodyVertexLabel,
                            priority: CADSnapKind.bodyVertex.priority
                        ))
                    }
                }

                // Build all prism edges: front face, back face, side edges
                var edges: [(DesignVector3, DesignVector3)] = []
                for i in 0..<n {
                    let j = (i + 1) % n
                    edges.append((frontWorld[i], frontWorld[j]))
                    edges.append((backWorld[i],  backWorld[j]))
                    edges.append((frontWorld[i], backWorld[i]))
                }
                for (startW, endW) in edges {
                    let startS = worldPointToSketch(startW, reference: activeSketchReference)
                    let endS   = worldPointToSketch(endW,   reference: activeSketchReference)
                    guard startS.u.isFinite, startS.v.isFinite,
                          endS.u.isFinite, endS.v.isFinite,
                          abs(startS.u) < 100, abs(startS.v) < 100,
                          abs(endS.u) < 100, abs(endS.v) < 100 else { continue }
                    let startPW = sketchPointToWorld(startS, reference: activeSketchReference)
                    let endPW   = sketchPointToWorld(endS,   reference: activeSketchReference)

                    if snapOptions.snapToEdgeMidpoints {
                        let mid = SketchPoint2D(u: (startS.u + endS.u) / 2,
                                                v: (startS.v + endS.v) / 2)
                        candidates.append(CADSnapCandidate(
                            kind: .edgeMidpoint,
                            worldPoint: sketchPointToWorld(mid, reference: activeSketchReference),
                            sketchPoint: mid,
                            sourceAssetID: asset.id,
                            displayName: bodyMidLabel,
                            priority: CADSnapKind.edgeMidpoint.priority,
                            edgeStartWorld: startPW,
                            edgeEndWorld: endPW
                        ))
                    }
                    if snapOptions.snapToBodyEdges {
                        let closest = closestPoint(rawPoint, onSegmentFrom: startS, to: endS)
                        candidates.append(CADSnapCandidate(
                            kind: .bodyEdge,
                            worldPoint: sketchPointToWorld(closest, reference: activeSketchReference),
                            sketchPoint: closest,
                            sourceAssetID: asset.id,
                            displayName: bodyEdgeLabel,
                            priority: CADSnapKind.bodyEdge.priority,
                            edgeStartWorld: startPW,
                            edgeEndWorld: endPW
                        ))
                    }
                }
            }
            return candidates
        }

        private func closestPoint(
            _ point: SketchPoint2D,
            onSegmentFrom start: SketchPoint2D,
            to end: SketchPoint2D
        ) -> SketchPoint2D {
            let du = end.u - start.u
            let dv = end.v - start.v
            let lengthSquared = du * du + dv * dv
            guard lengthSquared > 1e-12 else { return start }
            let rawT = ((point.u - start.u) * du + (point.v - start.v) * dv) / lengthSquared
            let t = min(max(rawT, 0), 1)
            return SketchPoint2D(u: start.u + du * t, v: start.v + dv * t)
        }

        private func snapToGrid(_ point: SketchPoint2D) -> SketchPoint2D {
            let step = min(max(snapOptions.gridStepMeters, 0.001), 1.0)
            return SketchPoint2D(
                u: (point.u / step).rounded() * step,
                v: (point.v / step).rounded() * step
            )
        }

        private func screenDistance(from worldPoint: DesignVector3, to screenPoint: CGPoint, in view: CADCanvasView) -> Double {
            let projected = view.projectPoint(SCNVector3(Float(worldPoint.x), Float(worldPoint.y), Float(worldPoint.z)))
            guard projected.x.isFinite, projected.y.isFinite else { return .infinity }
            let dx = Double(CGFloat(projected.x) - screenPoint.x)
            let dy = Double(CGFloat(projected.y) - screenPoint.y)
            return sqrt(dx * dx + dy * dy)
        }

        func handleMouseMoved(_ event: NSEvent, in view: CADCanvasView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            guard isSketchPlacementToolActive else {
                if isSketch2DMode {
                    onWorkPlaneHovered?(nil)
                } else {
                    onWorkPlaneHovered?(hitWorkPlane(at: loc, in: view))
                }
                return
            }
            if let pt = projectToSketchPlane(screenPoint: loc, in: view) {
                onMouseMoved?(snapResult(for: pt, screenPoint: loc, in: view))
            }
        }

        func handleMouseDown(_ event: NSEvent, in view: CADCanvasView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            mouseDownPoint = loc
            lastSketchPanPoint = loc
            // Detect what the mouseDown hit so mouseDragged knows whether to pan or move.
            // Select mode: hit entity → selection candidate (no geometry move), hit empty → pan.
            // Move mode: hit entity → entity drag candidate, hit empty → pan.
            if isSketch2DMode, (!isSketchPlacementToolActive || isSketchMoveMode) {
                dragCandidateEntityID = hitSketchEntityIDByProximity(at: loc, in: view)
                dragStartSketchPoint = nil
                dragAnchorSketchPoint = nil
                dragCursorToAnchorOffset = nil
                isDraggingEntity = false
            }
        }

        // Called from mouseDragged; returns true if the event was consumed by entity drag.
        // ignorePlacement: if true, bypasses the isSketchPlacementToolActive guard (for Move mode).
        func handleEntityDragIfNeeded(_ event: NSEvent, in view: CADCanvasView, ignorePlacement: Bool = false) -> Bool {
            guard isSketch2DMode, (!isSketchPlacementToolActive || ignorePlacement) else { return false }
            let loc = view.convert(event.locationInWindow, from: nil)

            if isDraggingEntity {
                // Already dragging — snap the anchor point, compute total delta from anchor's initial position.
                guard let anchorPt = dragAnchorSketchPoint,
                      let rawPt = projectToSketchPlane(screenPoint: loc, in: view) else { return true }
                let offset = dragCursorToAnchorOffset ?? .zero
                let anchorCurrent = SketchPoint2D(u: rawPt.u - offset.u, v: rawPt.v - offset.v)
                let snapped = snapResult(for: anchorCurrent, screenPoint: loc, in: view).point
                onEntityDragMoved?(SketchPoint2D(u: snapped.u - anchorPt.u, v: snapped.v - anchorPt.v))
                return true
            }

            guard let candidateID = dragCandidateEntityID,
                  let downPt = mouseDownPoint else { return false }

            let dx = abs(loc.x - downPt.x)
            let dy = abs(loc.y - downPt.y)
            guard dx > 4 || dy > 4 else { return false }  // below drag threshold

            // Threshold crossed — begin entity drag
            isDraggingEntity = true
            dragStartSketchPoint = projectToSketchPlane(screenPoint: downPt, in: view)
            lastSketchPanPoint = nil   // prevent pan from also firing
            onEntityDragBegan?(candidateID)

            // Compute anchor as entity's nearest characteristic point to the click position.
            if let clickPt = dragStartSketchPoint {
                let anchor = nearestEntityAnchor(forEntityID: candidateID, near: clickPt)
                dragAnchorSketchPoint = anchor
                dragCursorToAnchorOffset = SketchPoint2D(u: clickPt.u - anchor.u, v: clickPt.v - anchor.v)
            } else {
                dragAnchorSketchPoint = dragStartSketchPoint
                dragCursorToAnchorOffset = .zero
            }

            // Apply initial drag delta.
            if let anchorPt = dragAnchorSketchPoint,
               let currentPt = projectToSketchPlane(screenPoint: loc, in: view) {
                let offset = dragCursorToAnchorOffset ?? .zero
                let anchorCurrent = SketchPoint2D(u: currentPt.u - offset.u, v: currentPt.v - offset.v)
                let snapped = snapResult(for: anchorCurrent, screenPoint: loc, in: view).point
                onEntityDragMoved?(SketchPoint2D(u: snapped.u - anchorPt.u, v: snapped.v - anchorPt.v))
            }
            return true
        }

        private func nearestEntityAnchor(forEntityID id: UUID, near point: SketchPoint2D) -> SketchPoint2D {
            guard let asset = document.selectedAsset,
                  case let .sketch2D(params) = asset.kind,
                  let entity = params.sketch.entity(with: id) else { return point }
            var candidates: [SketchPoint2D] = []
            switch entity {
            case let .line(line):
                candidates = [line.start, line.end,
                              SketchPoint2D(u: (line.start.u + line.end.u) / 2,
                                            v: (line.start.v + line.end.v) / 2)]
            case let .rectangle(rect):
                candidates = rect.corners
                if !rect.corners.isEmpty {
                    let cu = rect.corners.map(\.u).reduce(0, +) / Double(rect.corners.count)
                    let cv = rect.corners.map(\.v).reduce(0, +) / Double(rect.corners.count)
                    candidates.append(SketchPoint2D(u: cu, v: cv))
                }
            case let .circle(circle):
                candidates = [circle.center]
            case let .polyline(pl):
                candidates = pl.points
                for i in 0..<max(0, pl.points.count - 1) {
                    candidates.append(SketchPoint2D(
                        u: (pl.points[i].u + pl.points[i + 1].u) / 2,
                        v: (pl.points[i].v + pl.points[i + 1].v) / 2))
                }
            case let .arc(arc):
                candidates = [arc.start, arc.end,
                              SketchPoint2D(u: (arc.start.u + arc.end.u) / 2,
                                            v: (arc.start.v + arc.end.v) / 2)]
            }
            return candidates.min(by: {
                ($0.u - point.u) * ($0.u - point.u) + ($0.v - point.v) * ($0.v - point.v)
                    < ($1.u - point.u) * ($1.u - point.u) + ($1.v - point.v) * ($1.v - point.v)
            }) ?? point
        }

        func handleMouseUp(_ event: NSEvent, in view: CADCanvasView) {
            let loc = view.convert(event.locationInWindow, from: nil)
            defer {
                mouseDownPoint = nil
                lastSketchPanPoint = nil
                dragCandidateEntityID = nil
                dragStartSketchPoint = nil
                dragAnchorSketchPoint = nil
                dragCursorToAnchorOffset = nil
                isDraggingEntity = false
            }

            // Move tool: commit entity drag preview on mouseUp.
            if isSketchMoveMode, isDraggingEntity {
                onEntityDragEnded?(.zero)
                return
            }

            guard isSketchPlacementToolActive else {
                if isDraggingEntity {
                    onEntityDragEnded?(.zero)
                    return
                }

                if isSketch2DMode,
                   let down = mouseDownPoint,
                   abs(loc.x - down.x) < 6,
                   abs(loc.y - down.y) < 6 {
                    // Click → select or deselect entity (Shift = toggle multi-selection)
                    let hitID = hitSketchEntityID(at: loc, in: view)
                    if event.modifierFlags.contains(.shift) {
                        onSketchEntityShiftSelected?(hitID)
                    } else {
                        onSketchLineSelected?(hitID)
                    }
                } else if let down = mouseDownPoint,
                          abs(loc.x - down.x) < 6,
                          abs(loc.y - down.y) < 6 {
                    let workPlane = hitWorkPlane(at: loc, in: view)
                    if case let .face(face)? = workPlane {
                        onSolidFaceSelected?(face.id)
                    } else {
                        onSolidFaceSelected?(nil)
                    }
                    onWorkPlaneSelected?(workPlane, swiftUIPoint(from: loc, in: view), false)
                }
                return
            }

            // Placement tool active path (drawing tools)
            if let down = mouseDownPoint {
                let dx = abs(loc.x - down.x)
                let dy = abs(loc.y - down.y)
                if dx < 6 && dy < 6 {
                    if isSketchMoveMode {
                        // Move tool click: select entity (Shift = toggle multi-selection).
                        let hitID = hitSketchEntityID(at: loc, in: view)
                        if event.modifierFlags.contains(.shift) {
                            onSketchEntityShiftSelected?(hitID)
                        } else {
                            onSketchLineSelected?(hitID)
                        }
                    } else if let pt = projectToSketchPlane(screenPoint: loc, in: view) {
                        onMouseDown?(snapResult(for: pt, screenPoint: loc, in: view))
                    }
                }
            }
        }

        func handleContextClick(_ event: NSEvent, in view: CADCanvasView) {
            guard !isSketchPlacementToolActive else { return }
            let loc = view.convert(event.locationInWindow, from: nil)
            let workPlane = hitWorkPlane(at: loc, in: view)
            if case let .face(face)? = workPlane {
                onSolidFaceSelected?(face.id)
            }
            onWorkPlaneSelected?(workPlane, swiftUIPoint(from: loc, in: view), true)
        }

        private func hitSketchEntityID(at point: CGPoint, in view: CADCanvasView) -> UUID? {
            // First: exact SceneKit 3D hit test
            let options: [SCNHitTestOption: Any] = [
                .boundingBoxOnly: false,
                .searchMode: SCNHitTestSearchMode.all.rawValue
            ]
            for hit in view.hitTest(point, options: options) {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let id = sketchEntityID(from: current.name) {
                        return id
                    }
                    node = current.parent
                }
            }
            // Fallback: sketch-plane proximity search (handles thin lines SceneKit misses)
            return hitSketchEntityIDByProximity(at: point, in: view)
        }

        // Proximity-based entity selection: measures screen-space distance from click to each entity.
        // This makes thin lines and small circles reliably selectable.
        func hitSketchEntityIDByProximity(at screenPoint: CGPoint, in view: CADCanvasView) -> UUID? {
            guard let sketch = activeSketchForLineTool() else { return nil }
            let tolerancePx: Double = 10.0
            var bestID: UUID? = nil
            var bestDist: Double = tolerancePx

            for entity in sketch.entities {
                guard entity.constructionStyle != .construction else { continue }
                let dist = screenDistanceToEntity(entity, from: screenPoint, in: view)
                if dist < bestDist {
                    bestDist = dist
                    bestID = entity.id
                }
            }
            return bestID
        }

        private func screenDistanceToEntity(_ entity: SketchEntity, from screenPoint: CGPoint, in view: CADCanvasView) -> Double {
            switch entity {
            case let .line(l):
                return screenDistanceToSegment(from: screenPoint, a: l.start, b: l.end, in: view)
            case let .rectangle(r):
                let corners = r.corners
                return corners.indices.map { i -> Double in
                    screenDistanceToSegment(from: screenPoint, a: corners[i], b: corners[(i + 1) % corners.count], in: view)
                }.min() ?? .infinity
            case let .circle(c):
                return screenDistanceToCircle(from: screenPoint, center: c.center, radiusMeters: c.radiusMeters, in: view)
            case let .polyline(p):
                guard p.points.count >= 2 else { return .infinity }
                return (0..<(p.points.count - 1)).map { i -> Double in
                    screenDistanceToSegment(from: screenPoint, a: p.points[i], b: p.points[i + 1], in: view)
                }.min() ?? .infinity
            case let .arc(a):
                // Sample arc as a rough polyline
                return screenDistanceToSegment(from: screenPoint, a: a.start, b: a.end, in: view)
            }
        }

        private func screenDistanceToSegment(from screenPoint: CGPoint, a: SketchPoint2D, b: SketchPoint2D, in view: CADCanvasView) -> Double {
            let aWorld = sketchPointToWorld(a, reference: activeSketchReference)
            let bWorld = sketchPointToWorld(b, reference: activeSketchReference)
            let ap = view.projectPoint(SCNVector3(Float(aWorld.x), Float(aWorld.y), Float(aWorld.z)))
            let bp = view.projectPoint(SCNVector3(Float(bWorld.x), Float(bWorld.y), Float(bWorld.z)))
            guard ap.x.isFinite, ap.y.isFinite, bp.x.isFinite, bp.y.isFinite else { return .infinity }
            let ax = Double(ap.x), ay = Double(ap.y)
            let bx = Double(bp.x), by = Double(bp.y)
            let px = Double(screenPoint.x), py = Double(screenPoint.y)
            let dx = bx - ax, dy = by - ay
            let lenSq = dx * dx + dy * dy
            guard lenSq > 1e-6 else { return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay)) }
            let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
            let cx = ax + t * dx, cy = ay + t * dy
            return sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
        }

        private func screenDistanceToCircle(from screenPoint: CGPoint, center: SketchPoint2D, radiusMeters: Double, in view: CADCanvasView) -> Double {
            let centerWorld = sketchPointToWorld(center, reference: activeSketchReference)
            let cp = view.projectPoint(SCNVector3(Float(centerWorld.x), Float(centerWorld.y), Float(centerWorld.z)))
            guard cp.x.isFinite, cp.y.isFinite else { return .infinity }
            let cx = Double(cp.x), cy = Double(cp.y)
            let px = Double(screenPoint.x), py = Double(screenPoint.y)
            // Sample a point on the circumference at 0° and 90° for radius in screen pixels
            let edgeWorld = sketchPointToWorld(SketchPoint2D(u: center.u + radiusMeters, v: center.v), reference: activeSketchReference)
            let ep = view.projectPoint(SCNVector3(Float(edgeWorld.x), Float(edgeWorld.y), Float(edgeWorld.z)))
            guard ep.x.isFinite, ep.y.isFinite else { return .infinity }
            let screenRadius = sqrt((Double(ep.x) - cx) * (Double(ep.x) - cx) + (Double(ep.y) - cy) * (Double(ep.y) - cy))
            // Distance from click to circle arc = |dist_to_center - screenRadius|
            let distToCenter = sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy))
            return abs(distToCenter - screenRadius)
        }

        private func sketchEntityID(from nodeName: String?) -> UUID? {
            guard let nodeName else { return nil }
            for prefix in ["sketch_line_", "sketch_rectangle_", "sketch_circle_", "sketch_polyline_"] {
                if nodeName.hasPrefix(prefix) {
                    return UUID(uuidString: String(nodeName.dropFirst(prefix.count)))
                }
            }
            return nil
        }

        private func hitWorkPlane(at point: CGPoint, in view: CADCanvasView) -> CADWorkPlane? {
            let options: [SCNHitTestOption: Any] = [
                .boundingBoxOnly: false,
                .searchMode: SCNHitTestSearchMode.all.rawValue
            ]
            let hits = view.hitTest(point, options: options)
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name,
                       let face = workPlaneFace(from: name) {
                        return .face(face)
                    }
                    node = current.parent
                }
            }
            for hit in hits {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name,
                       let plane = workPlaneCanonical(from: name) {
                        return .canonical(plane)
                    }
                    node = current.parent
                }
            }
            return nil
        }

        private func workPlaneCanonical(from nodeName: String) -> SketchPlane? {
            guard nodeName.hasPrefix("workPlane:") else { return nil }
            let raw = String(nodeName.dropFirst("workPlane:".count))
            return SketchPlane(rawValue: raw)
        }

        private func workPlaneFace(from nodeName: String) -> DesignPlanarFace? {
            guard nodeName.hasPrefix("solidFace:") else { return nil }
            let parts = nodeName.split(separator: ":")
            guard parts.count == 3,
                  let assetID = UUID(uuidString: String(parts[1])),
                  let faceID = UUID(uuidString: String(parts[2])),
                  let asset = document.assets.first(where: { $0.id == assetID }),
                  case let .extrudedSolid(parameters) = asset.kind else { return nil }
            return parameters.faces.first { $0.id == faceID }
        }

        private func hitSolidFaceID(at point: CGPoint, in view: CADCanvasView) -> UUID? {
            if case let .face(face)? = hitWorkPlane(at: point, in: view) {
                return face.id
            }
            let options: [SCNHitTestOption: Any] = [
                .boundingBoxOnly: false,
                .searchMode: SCNHitTestSearchMode.closest.rawValue
            ]
            for hit in view.hitTest(point, options: options) {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, name.hasPrefix("solidFaceMarker_") {
                        return UUID(uuidString: String(name.dropFirst("solidFaceMarker_".count)))
                    }
                    node = current.parent
                }
            }
            return nil
        }

        private func swiftUIPoint(from scenePoint: CGPoint, in view: CADCanvasView) -> CGPoint {
            CGPoint(x: scenePoint.x, y: max(0, view.bounds.height - scenePoint.y))
        }

        func handleSketchPan(_ event: NSEvent, in view: CADCanvasView) {
            guard isSketch2DMode, !isSketchPlacementToolActive else { return }
            let loc = view.convert(event.locationInWindow, from: nil)
            guard let previous = lastSketchPanPoint else {
                lastSketchPanPoint = loc
                return
            }
            defer { lastSketchPanPoint = loc }

            guard let previousPoint = projectToSketchPlane(screenPoint: previous, in: view),
                  let currentPoint = projectToSketchPlane(screenPoint: loc, in: view),
                  let cameraNode = view.pointOfView else { return }

            let delta = worldDelta(
                du: previousPoint.u - currentPoint.u,
                dv: previousPoint.v - currentPoint.v
            )
            cameraNode.position = SCNVector3(
                cameraNode.position.x + delta.x,
                cameraNode.position.y + delta.y,
                cameraNode.position.z + delta.z
            )
            let target = view.defaultCameraController.target
            view.defaultCameraController.target = SCNVector3(
                target.x + delta.x,
                target.y + delta.y,
                target.z + delta.z
            )
        }

        func handleOtherMouseDown(_ event: NSEvent, in view: CADCanvasView) {
            guard isSketch2DMode else { return }
            lastSketchPanPoint = view.convert(event.locationInWindow, from: nil)
        }

        func handleSketchZoom(_ event: NSEvent, in view: CADCanvasView) {
            guard isSketch2DMode,
                  let camera = view.pointOfView?.camera,
                  camera.usesOrthographicProjection else { return }
            let delta = Double(event.scrollingDeltaY)
            let factor = min(max(pow(1.0018, delta), 0.70), 1.35)
            camera.orthographicScale = min(max(camera.orthographicScale * factor, 0.05), 20.0)
        }

        func handleSketchScrollPan(_ event: NSEvent, in view: CADCanvasView) {
            guard isSketch2DMode, let cameraNode = view.pointOfView else { return }
            let loc = view.convert(event.locationInWindow, from: nil)
            // Treat scroll deltas as screen-space pixel displacement.
            // scrollingDeltaY positive = scroll down (natural: content moves down = camera moves up).
            let offset = CGPoint(x: loc.x + event.scrollingDeltaX, y: loc.y - event.scrollingDeltaY)
            guard let p1 = projectToSketchPlane(screenPoint: loc, in: view),
                  let p2 = projectToSketchPlane(screenPoint: offset, in: view) else { return }
            let delta = worldDelta(du: p1.u - p2.u, dv: p1.v - p2.v)
            cameraNode.position = SCNVector3(
                cameraNode.position.x + delta.x,
                cameraNode.position.y + delta.y,
                cameraNode.position.z + delta.z
            )
            let target = view.defaultCameraController.target
            view.defaultCameraController.target = SCNVector3(
                target.x + delta.x,
                target.y + delta.y,
                target.z + delta.z
            )
        }

        func handleKeyDown(_ event: NSEvent) -> Bool {
            let kc = event.keyCode
            let cmd = event.modifierFlags.contains(.command)
            switch kc {
            case 53: // Esc
                if isSketchMoveMode && isDraggingEntity {
                    isDraggingEntity = false
                    dragCandidateEntityID = nil
                    dragStartSketchPoint = nil
                    dragAnchorSketchPoint = nil
                    dragCursorToAnchorOffset = nil
                    onEntityDragCanceled?()
                    return true
                }
                onKeyCode?(kc, event.characters)
                return true
            case 36: // Enter
                if isSketchMoveMode && isDraggingEntity {
                    isDraggingEntity = false
                    onEntityDragEnded?(.zero)
                    return true
                }
                onKeyCode?(kc, event.characters)
                return true
            case 48, 51, 117: // Tab, Backspace, Delete
                onKeyCode?(kc, event.characters)
                return true
            default:
                let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
                if cmd && ch == "c" { onKeyCode?(0xC001, nil); return true }
                if cmd && ch == "v" { onKeyCode?(0xC002, nil); return true }
                if !cmd, ch == "l" { onKeyCode?(kc, event.characters); return true }
                return false
            }
        }

        private func worldDelta(du: Double, dv: Double) -> SCNVector3 {
            let axes = axesForSketchReference(activeSketchReference)
            let delta = axes.u * du + axes.v * dv
            return SCNVector3(Float(delta.x), Float(delta.y), Float(delta.z))
        }
    }

    private var activeSketchToolState: (isActive: Bool, cursorPoint: SketchPoint2D, snapResult: CADSnapResult?) {
        switch viewportState.activeTool {
        case .sketchRectangle:
            return (rectangleToolState.isActive, rectangleToolState.cursorPoint, rectangleToolState.snapResult)
        case .sketchCircle:
            return (circleToolState.isActive, circleToolState.cursorPoint, circleToolState.snapResult)
        case .sketchLine:
            return (lineToolState.isActive, lineToolState.cursorPoint, lineToolState.snapResult)
        case .sketchArc:
            return (arcToolState.isActive, arcToolState.cursorPoint, arcToolState.snapResult)
        case .sketchAutoline:
            return (autolineToolState.isActive, autolineToolState.cursorPoint, autolineToolState.snapResult)
        case .sketchConstruction:
            return (constructionToolState.isActive, constructionToolState.cursorPoint, constructionToolState.snapResult)
        case .sketchMove, .sketchCopy:
            return (sketchMoveToolState.isActive, sketchMoveToolState.cursorPoint, sketchMoveToolState.snapResult)
        case .sketchParallel, .sketchPerpendicular:
            return (sketchParallelToolState.isActive, sketchParallelToolState.cursorPoint, sketchParallelToolState.snapResult)
        case .sketchSplit, .sketchTrim, .sketchExtend:
            return (sketchSplitToolState.isActive, sketchSplitToolState.cursorPoint, sketchSplitToolState.snapResult)
        case .select, .sketchEdit:
            return (false, .zero, nil)
        }
    }

    private func phantomSketchPath() -> (points: [SketchPoint2D], closed: Bool)? {
        if let start = lineToolState.phantomStart, let end = lineToolState.phantomEnd {
            return ([start, end], false)
        }
        if let firstCorner = rectangleToolState.firstCorner,
           let opposite = rectangleToolState.oppositeCorner {
            let rectangle = SketchRectangle(firstCorner: firstCorner, oppositeCorner: opposite)
            return (rectangle.corners, true)
        }
        if let center = circleToolState.center,
           let radius = circleToolState.radiusMeters,
           radius > 0.0005 {
            let circle = SketchCircle(center: center, radiusMeters: radius)
            return (circle.profilePoints(segments: 48), true)
        }
        if let pts = arcToolState.phantomPoints, pts.count >= 2 {
            return (pts, false)
        }
        if autolineToolState.isActive {
            var pts = autolineToolState.points
            pts.append(autolineToolState.cursorPoint)
            if pts.count >= 2 { return (pts, false) }
        }
        if viewportState.activeTool == .sketchConstruction,
           let (start, end) = constructionToolState.phantomEndpoints {
            return ([start, end], false)
        }
        if viewportState.activeTool == .sketchTrim || viewportState.activeTool == .sketchExtend,
           let pts = sketchSplitToolState.phantomPoints, pts.count >= 2 {
            return (pts, false)
        }
        return nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: NSViewRepresentable

    func makeNSView(context: Context) -> CADCanvasView {
        let view = CADCanvasView()
        view.backgroundColor = NSColor(red: 0.07, green: 0.09, blue: 0.12, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.showsStatistics = false
        view.rendersContinuously = false

        view.coordinator = context.coordinator

        let scene = DesignPreviewSceneBuilder.buildScene()
        view.scene = scene
        DesignPreviewSceneBuilder.addCamera(to: view)
        populateScene(view: view, scene: scene, coordinator: context.coordinator)
        DesignPreviewSceneBuilder.applyViewportState(
            viewportState,
            to: view,
            document: document,
            previousState: nil,
            animated: false
        )
        if let cameraCommand {
            DesignPreviewSceneBuilder.applyCommand(
                cameraCommand,
                to: view,
                document: document,
                viewportState: viewportState,
                canvasOptions: viewportState.canvasOptions
            )
        }

        syncCoordinator(context.coordinator)
        cacheState(in: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: CADCanvasView, context: Context) {
        guard let scene = nsView.scene else { return }
        syncCoordinator(context.coordinator)

        if scene.rootNode.childNode(withName: "assets_container", recursively: false) == nil {
            populateScene(view: nsView, scene: scene, coordinator: context.coordinator)
            context.coordinator.lastDocument = document
        }

        let didCommittedAssetStateChange = context.coordinator.lastDocument != document
            || context.coordinator.lastViewportState?.selectedAssetID != viewportState.selectedAssetID
            || context.coordinator.lastViewportState?.selectedAttachmentPointID != viewportState.selectedAttachmentPointID
            || context.coordinator.lastViewportState?.selectedSketchLineID != viewportState.selectedSketchLineID
            || context.coordinator.lastViewportState?.selectedSketchEntityID != viewportState.selectedSketchEntityID
            || context.coordinator.lastViewportState?.selectedSketchEntityIDs != viewportState.selectedSketchEntityIDs
            || context.coordinator.lastViewportState?.selectedFaceID != viewportState.selectedFaceID
            || context.coordinator.lastViewportState?.hoveredWorkPlaneID != viewportState.hoveredWorkPlaneID

        let didFeaturePreviewChange = context.coordinator.lastViewportState?.featurePreviewParams != viewportState.featurePreviewParams
            || context.coordinator.lastViewportState?.featurePreviewIsCut != viewportState.featurePreviewIsCut
        let didCutSelectionChange = context.coordinator.lastViewportState?.selectedCutFeatureID != viewportState.selectedCutFeatureID
            || context.coordinator.lastViewportState?.selectedCutTargetBodyID != viewportState.selectedCutTargetBodyID
            || context.coordinator.lastViewportState?.activeTool != viewportState.activeTool

        if didCommittedAssetStateChange {
            repopulateScene(view: nsView, scene: scene, coordinator: context.coordinator)
            context.coordinator.lastDocument = document
            // Full rebuild: base positions are stale, clear them.
            context.coordinator.previewNodeBasePositions = [:]
        } else if didFeaturePreviewChange,
                  let container = scene.rootNode.childNode(withName: "assets_container", recursively: false) {
            updateFeaturePreviewNode(in: container, coordinator: context.coordinator)
        } else if didCutSelectionChange,
                  let container = scene.rootNode.childNode(withName: "assets_container", recursively: false) {
            updateCutSelectionHighlight(in: container)
        }

        // Move preview: directly translate entity nodes without full rebuild.
        let prevPreviewDelta = context.coordinator.lastViewportState?.movePreviewDelta
        let currPreviewDelta = viewportState.movePreviewDelta
        let prevPreviewIDs = context.coordinator.lastViewportState?.movePreviewEntityIDs ?? []
        let currPreviewIDs = viewportState.movePreviewEntityIDs
        if !didCommittedAssetStateChange, (prevPreviewDelta != currPreviewDelta || prevPreviewIDs != currPreviewIDs) {
            applyMovePreview(
                entityIDs: currPreviewIDs,
                delta: currPreviewDelta,
                reference: viewportState.activeReference,
                in: nsView,
                scene: scene,
                coordinator: context.coordinator
            )
        }

        if context.coordinator.lastViewportState != viewportState {
            let previousState = context.coordinator.lastViewportState
            DesignPreviewSceneBuilder.applyViewportState(
                viewportState,
                to: nsView,
                document: document,
                previousState: previousState,
                animated: false
            )
            context.coordinator.lastViewportState = viewportState
        } else if didCommittedAssetStateChange {
            DesignPreviewSceneBuilder.applyCanvasOptions(viewportState.canvasOptions, to: nsView)
        }

        if context.coordinator.lastCameraCommandID != cameraCommand?.id,
           let cameraCommand {
            if nsView.bounds.isEmpty {
                let coordinator = context.coordinator
                DispatchQueue.main.async {
                    guard coordinator.lastCameraCommandID != cameraCommand.id else { return }
                    DesignPreviewSceneBuilder.applyCommand(
                        cameraCommand,
                        to: nsView,
                        document: document,
                        viewportState: viewportState,
                        canvasOptions: viewportState.canvasOptions
                    )
                    coordinator.lastCameraCommandID = cameraCommand.id
                }
            } else {
                DesignPreviewSceneBuilder.applyCommand(
                    cameraCommand,
                    to: nsView,
                    document: document,
                    viewportState: viewportState,
                    canvasOptions: viewportState.canvasOptions
                )
                context.coordinator.lastCameraCommandID = cameraCommand.id
                // If the command left the camera in an invalid state, recover immediately.
                DesignPreviewSceneBuilder.recoverIfCameraInvalid(in: nsView, document: document)
            }
        }

        // Phantom sketch (line / rectangle / circle)
        if let (sketchPoints, closed) = phantomSketchPath() {
            let world3D = sketchPoints.map {
                offsetWorldPoint($0, reference: viewportState.activeReference, normalOffsetMeters: CADSketchVisualLayer.phantom)
            }
            DesignPreviewSceneBuilder.updatePhantomPath(points: world3D, closed: closed, in: nsView)
        } else {
            DesignPreviewSceneBuilder.removePhantomLine(from: nsView)
        }

        // Cursor marker
        if activeSketchToolState.isActive {
            let cur3d = offsetWorldPoint(
                activeSketchToolState.cursorPoint,
                reference: viewportState.activeReference,
                normalOffsetMeters: CADSketchVisualLayer.cursor
            )
            DesignPreviewSceneBuilder.updateCursorMarker(at: cur3d, in: nsView)
        } else {
            DesignPreviewSceneBuilder.removeCursorMarker(from: nsView)
        }

        // Snap feedback
        if activeSketchToolState.isActive,
           let snapResult = activeSketchToolState.snapResult,
           let snapKind = snapResult.kind {
            let snapPoint = offsetWorldPoint(
                snapResult.point,
                reference: viewportState.activeReference,
                normalOffsetMeters: CADSketchVisualLayer.cursor + 0.00003
            )
            let normal = normalVector(for: viewportState.activeReference)
            let edgeStart = snapResult.edgeStartWorld.map { $0 + normal * (CADSketchVisualLayer.cursor + 0.00003) }
            let edgeEnd = snapResult.edgeEndWorld.map { $0 + normal * (CADSketchVisualLayer.cursor + 0.00003) }
            DesignPreviewSceneBuilder.updateSnapMarker(
                at: snapPoint,
                kind: snapKind,
                label: snapResult.displayName,
                edgeStart: edgeStart,
                edgeEnd: edgeEnd,
                in: nsView
            )
        } else {
            DesignPreviewSceneBuilder.removeSnapMarker(from: nsView)
        }

        syncCoordinator(context.coordinator)
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    // MARK: Helpers

    private func syncCoordinator(_ c: Coordinator) {
        c.document = document
        c.activeSketchPlane = viewportState.activePlane
        c.activeSketchPlaneOffset = viewportState.activePlaneOffsetMeters
        c.activeSketchReference = viewportState.activeReference
        c.snapOptions = viewportState.snapOptions
        c.isSketchPlacementToolActive = activeSketchToolState.isActive
        c.isSketch2DMode = viewportState.isSketch2DMode
        c.isSketchPanMode = viewportState.activeTool == .sketchCopy
        c.isSketchMoveMode = viewportState.activeTool == .sketchMove
        c.onMouseMoved = onMouseMoved
        c.onMouseDown = onMouseDown
        c.onSketchLineSelected = onSketchLineSelected
        c.onSolidFaceSelected = onSolidFaceSelected
        c.onWorkPlaneHovered = onWorkPlaneHovered
        c.onWorkPlaneSelected = onWorkPlaneSelected
        c.onKeyCode = onKeyCode
        c.onEntityDragBegan = onEntityDragBegan
        c.onEntityDragMoved = onEntityDragMoved
        c.onEntityDragEnded = onEntityDragEnded
        c.onEntityDragCanceled = onEntityDragCanceled
        c.onSketchEntityShiftSelected = onSketchEntityShiftSelected
    }

    private func cacheState(in c: Coordinator) {
        c.lastDocument = document
        c.lastViewportState = viewportState
        c.lastCameraCommandID = cameraCommand?.id
    }

    private func populateScene(view: CADCanvasView, scene: SCNScene, coordinator: Coordinator?) {
        let container = SCNNode()
        container.name = "assets_container"
        scene.rootNode.addChildNode(container)
        rebuildAssets(in: container, coordinator: coordinator)
    }

    private func repopulateScene(view: CADCanvasView, scene: SCNScene, coordinator: Coordinator?) {
        scene.rootNode.childNode(withName: "assets_container", recursively: false)?.removeFromParentNode()
        let container = SCNNode()
        container.name = "assets_container"
        scene.rootNode.addChildNode(container)
        rebuildAssets(in: container, coordinator: coordinator)
    }

    private func rebuildAssets(in container: SCNNode, coordinator: Coordinator?) {
        if let coordinator {
            coordinator.assetGeometryRebuildCount += 1
            print(
                "CAD Cut v2 Scene Counters: " +
                "previewNodeRebuildCount=\(coordinator.featurePreviewNodeRebuildCount) " +
                "assetGeometryRebuildCount=\(coordinator.assetGeometryRebuildCount) " +
                "removedPreviewNodeCount=0 " +
                "previewVisible=\(viewportState.featurePreviewParams != nil)"
            )
        }
        _ = clearAllTransientCADNodes(in: container)
        for asset in document.assets {
            let node = DesignAssetNodeFactory.makeNode(
                for: asset,
                includeAttachmentPoints: asset.id == viewportState.selectedAssetID,
                selectedAttachmentPointID: viewportState.selectedAttachmentPointID,
                selectedSketchLineID: viewportState.selectedSketchLineID,
                selectedSketchEntityID: viewportState.selectedSketchEntityID,
                selectedSketchEntityIDs: viewportState.selectedSketchEntityIDs,
                showSketchPoints: asset.id == viewportState.selectedAssetID,
                showConstraintGlyphs: viewportState.showConstraintGlyphs,
                hoveredFaceID: hoveredFaceID(from: viewportState.hoveredWorkPlaneID),
                selectedFaceID: viewportState.selectedFaceID
            )
            node.position = SCNVector3(
                Float(asset.transform.positionX),
                Float(asset.transform.positionY),
                Float(asset.transform.positionZ)
            )
            let rotationZOffset: Float
            if case .tube = asset.kind { rotationZOffset = Float.pi / 2 } else { rotationZOffset = 0 }
            node.eulerAngles = SCNVector3(
                Float(asset.transform.rotationX),
                Float(asset.transform.rotationY),
                Float(asset.transform.rotationZ) + rotationZOffset
            )
            let scale = Float(max(0.01, min(asset.transform.scale, 100.0)))
            node.scale = SCNVector3(scale, scale, scale)
            container.addChildNode(node)
            if case .extrudedSolid = asset.kind {
                restoreOpaqueBodyRenderState(bodyNode: node)
            }
            DesignAssetNodeFactory.applyHighlight(node, selected: asset.id == viewportState.selectedAssetID)
        }

        updateFeaturePreviewNode(in: container, coordinator: nil)
        updateCutSelectionHighlight(in: container)
        logCutArtifactDiagnostics(
            artifactDiagnostics(in: container, removedPreviewNodeCount: 0),
            committedMeshStats: committedMeshStats()
        )
    }

    private func updateFeaturePreviewNode(in container: SCNNode, coordinator: Coordinator?) {
        let removedPreviewNodeCount = clearAllTransientCADNodes(in: container)

        if let previewParams = viewportState.featurePreviewParams {
            let root = cadTransientRootNode(in: container, createIfNeeded: true)
            let previewNode = DesignAssetNodeFactory.makeFeaturePreviewNode(
                params: previewParams,
                isCut: viewportState.featurePreviewIsCut
            )
            root.addChildNode(previewNode)
        }

        if let coordinator {
            coordinator.featurePreviewNodeRebuildCount += 1
            let diagnostics = artifactDiagnostics(in: container, removedPreviewNodeCount: removedPreviewNodeCount)
            print(
                "CAD Cut v2 Scene Counters: " +
                "previewNodeRebuildCount=\(coordinator.featurePreviewNodeRebuildCount) " +
                "assetGeometryRebuildCount=\(coordinator.assetGeometryRebuildCount) " +
                "removedPreviewNodeCount=\(removedPreviewNodeCount) " +
                "previewVisible=\(viewportState.featurePreviewParams != nil) " +
                "transientCutNodeCount=\(diagnostics.transientCutNodeCount) " +
                "cutterPreviewNodeCount=\(diagnostics.cutterPreviewNodeCount) " +
                "ghostTransparentNodeCount=\(diagnostics.ghostTransparentNodeCount) " +
                "bodyOpaqueStateRestored=\(diagnostics.bodyOpaqueStateRestored) " +
                "bodyTransparentMaterialCount=\(diagnostics.bodyTransparentMaterialCount) " +
                "bodyRenderingOrderAnomalyCount=\(diagnostics.bodyRenderingOrderAnomalyCount) " +
                "previewNodesRemovedAfterApply=\(diagnostics.previewNodesRemovedAfterApply)"
            )
        }
    }

    private func updateCutSelectionHighlight(in container: SCNNode) {
        _ = clearCutSelectionHighlight(in: container)

        guard viewportState.activeTool == .select,
              let bodyID = viewportState.selectedCutTargetBodyID,
              let cutID = viewportState.selectedCutFeatureID,
              let asset = document.assets.first(where: { $0.id == bodyID }),
              case let .extrudedSolid(params) = asset.kind,
              let highlightNode = DesignAssetNodeFactory.makeCutSelectionHighlightNode(
                bodyParams: params,
                cutID: cutID
              ) else {
            return
        }

        let root = cadTransientRootNode(in: container, createIfNeeded: true)
        root.addChildNode(highlightNode)
    }

    @discardableResult
    private func clearCutSelectionHighlight(in container: SCNNode) -> Int {
        var removed = 0
        for node in [container] + container.childNodesRecursive {
            for child in node.childNodes where child.name == Self.cutSelectionHighlightNodeName {
                removed += max(1, child.flattenedChildCount)
                child.removeFromParentNode()
            }
        }
        return removed
    }

    @discardableResult
    private func clearAllTransientCADNodes(in container: SCNNode) -> Int {
        var removedCount = 0
        let removablePrefixes = [
            "cad.cut.",
            Self.cutDebugNodePrefix,
            Self.cutHighlightNodePrefix,
        ]
        let legacyNames = [
            Self.legacyCadTransientRootNodeName,
            Self.legacyCutPreviewNodeName,
            Self.legacyExtrudePreviewNodeName,
        ]

        func shouldRemove(_ node: SCNNode) -> Bool {
            guard let name = node.name else { return false }
            return removablePrefixes.contains { name.hasPrefix($0) }
                || legacyNames.contains(name)
        }

        func scan(_ node: SCNNode) {
            for child in node.childNodes {
                if shouldRemove(child) {
                    removedCount += max(1, child.flattenedChildCount)
                    child.removeFromParentNode()
                } else {
                    scan(child)
                }
            }
        }
        scan(container)
        return removedCount
    }

    private func cadTransientRootNode(in container: SCNNode, createIfNeeded: Bool) -> SCNNode {
        if let existing = container.childNode(
            withName: Self.cadTransientRootNodeName,
            recursively: false
        ) {
            return existing
        }
        let root = SCNNode()
        root.name = Self.cadTransientRootNodeName
        if createIfNeeded {
            container.addChildNode(root)
        }
        return root
    }

    private func restoreOpaqueBodyRenderState(bodyNode: SCNNode) {
        for node in [bodyNode] + bodyNode.childNodesRecursive {
            guard node.name?.hasPrefix("cad.body.mesh.") == true else { continue }
            node.opacity = 1.0
            node.renderingOrder = 0
            guard let geometry = node.geometry else { continue }
            for material in geometry.materials {
                material.transparency = 1.0
                material.writesToDepthBuffer = true
                material.readsFromDepthBuffer = true
                material.blendMode = .alpha
            }
        }
    }

    private func artifactDiagnostics(
        in container: SCNNode,
        removedPreviewNodeCount: Int
    ) -> CADCutArtifactDiagnostics {
        var transientCutNodeCount = 0
        var cutterPreviewNodeCount = 0
        var ghostTransparentNodeCount = 0
        var bodyTransparentMaterialCount = 0
        var bodyRenderingOrderAnomalyCount = 0

        for node in [container] + container.childNodesRecursive {
            let name = node.name ?? ""
            if name.hasPrefix("cad.cut.") || name == Self.legacyCutPreviewNodeName || name == Self.legacyExtrudePreviewNodeName {
                transientCutNodeCount += 1
                if name == Self.cutterVolumeNodeName || name == Self.legacyCutPreviewNodeName {
                    cutterPreviewNodeCount += 1
                }
                if nodeHasTransparentMaterial(node) {
                    ghostTransparentNodeCount += 1
                }
            }

            guard name.hasPrefix("cad.body.mesh.") else { continue }
            if node.renderingOrder != 0 {
                bodyRenderingOrderAnomalyCount += 1
            }
            if let geometry = node.geometry {
                for material in geometry.materials where material.transparency < 0.999 || !material.writesToDepthBuffer || !material.readsFromDepthBuffer {
                    bodyTransparentMaterialCount += 1
                }
            }
        }

        return CADCutArtifactDiagnostics(
            transientCutNodeCount: transientCutNodeCount,
            cutterPreviewNodeCount: cutterPreviewNodeCount,
            ghostTransparentNodeCount: ghostTransparentNodeCount,
            bodyOpaqueStateRestored: bodyTransparentMaterialCount == 0 && bodyRenderingOrderAnomalyCount == 0,
            bodyTransparentMaterialCount: bodyTransparentMaterialCount,
            bodyRenderingOrderAnomalyCount: bodyRenderingOrderAnomalyCount,
            previewNodesRemovedAfterApply: removedPreviewNodeCount > 0 || viewportState.featurePreviewParams == nil
        )
    }

    private func nodeHasTransparentMaterial(_ node: SCNNode) -> Bool {
        guard let geometry = node.geometry else { return false }
        return geometry.materials.contains { material in
            material.transparency < 0.999 || !material.writesToDepthBuffer
        }
    }

    private func logCutArtifactDiagnostics(
        _ diagnostics: CADCutArtifactDiagnostics,
        committedMeshStats: (vertices: Int, triangles: Int)
    ) {
        print(
            "CAD Cut Artifact Diagnostics: " +
            "transientCutNodeCount=\(diagnostics.transientCutNodeCount) " +
            "cutterPreviewNodeCount=\(diagnostics.cutterPreviewNodeCount) " +
            "ghostTransparentNodeCount=\(diagnostics.ghostTransparentNodeCount) " +
            "bodyOpaqueStateRestored=\(diagnostics.bodyOpaqueStateRestored) " +
            "bodyTransparentMaterialCount=\(diagnostics.bodyTransparentMaterialCount) " +
            "bodyRenderingOrderAnomalyCount=\(diagnostics.bodyRenderingOrderAnomalyCount) " +
            "committedMeshVertexCount=\(committedMeshStats.vertices) " +
            "committedMeshTriangleCount=\(committedMeshStats.triangles) " +
            "previewNodesRemovedAfterApply=\(diagnostics.previewNodesRemovedAfterApply)"
        )
    }

    private func committedMeshStats() -> (vertices: Int, triangles: Int) {
        document.assets.reduce((vertices: 0, triangles: 0)) { result, asset in
            guard case let .extrudedSolid(params) = asset.kind,
                  let mesh = params.kernelVisualMesh else {
                return result
            }
            return (
                vertices: result.vertices + mesh.vertices.count,
                triangles: result.triangles + mesh.triangles.count
            )
        }
    }

    private func hoveredFaceID(from workPlaneID: String?) -> UUID? {
        guard let workPlaneID, workPlaneID.hasPrefix("face:") else { return nil }
        let parts = workPlaneID.split(separator: ":")
        guard parts.count == 3 else { return nil }
        return UUID(uuidString: String(parts[2]))
    }

    // Translates entity nodes in the scene directly (no full rebuild) for drag preview.
    private func applyMovePreview(
        entityIDs: Set<UUID>,
        delta: SketchPoint2D?,
        reference: SketchReference,
        in view: CADCanvasView,
        scene: SCNScene,
        coordinator: Coordinator
    ) {
        // Find the "sketch_entities" container for the selected asset.
        guard let assetsRoot = scene.rootNode
            .childNode(withName: "assets_container", recursively: false),
              let assetNode = assetsRoot.childNodes.first(where: {
                  $0.name?.hasPrefix("asset_") == true
              }),
              let sketchContainer = assetNode.childNode(withName: "sketch_entities", recursively: false)
        else { return }

        // Capture base positions when preview first begins.
        if coordinator.previewNodeBasePositions.isEmpty, !entityIDs.isEmpty {
            for child in sketchContainer.childNodes {
                guard let name = child.name,
                      entityIDs.contains(where: { name.hasSuffix($0.uuidString) }) else { continue }
                coordinator.previewNodeBasePositions[name] = child.simdPosition
            }
        }

        let axes = axesForSketchReference(reference)

        if let delta, !coordinator.previewNodeBasePositions.isEmpty {
            let worldVec = axes.u * delta.u + axes.v * delta.v
            let worldOffset = simd_float3(Float(worldVec.x), Float(worldVec.y), Float(worldVec.z))
            for (name, basePos) in coordinator.previewNodeBasePositions {
                if let node = sketchContainer.childNodes.first(where: { $0.name == name }) {
                    node.simdPosition = basePos + worldOffset
                }
            }
        } else {
            // Preview ended or canceled — restore base positions.
            for (name, basePos) in coordinator.previewNodeBasePositions {
                if let node = sketchContainer.childNodes.first(where: { $0.name == name }) {
                    node.simdPosition = basePos
                }
            }
            coordinator.previewNodeBasePositions = [:]
        }
    }
}

// MARK: - CADCanvasView

final class CADCanvasView: SCNView {
    weak var coordinator: DesignPreviewSceneViewRepresentable.Coordinator?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        discardCursorRects()
        if coordinator?.isSketchPlacementToolActive == true {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.handleMouseMoved(event, in: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.handleMouseDown(event, in: self)
        if coordinator?.isSketchPlacementToolActive != true {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if coordinator?.isSketch2DMode == true {
            if coordinator?.isSketchMoveMode == true {
                // Move tool: drag on entity = move entity; drag on empty space = pan.
                if coordinator?.handleEntityDragIfNeeded(event, in: self, ignorePlacement: true) == false {
                    coordinator?.handleSketchPan(event, in: self)
                }
                return
            }
            if coordinator?.isSketchPanMode == true {
                // Copy tool: left drag always pans.
                coordinator?.handleSketchPan(event, in: self)
                return
            }
            // Select mode: pan if drag started on empty area; ignore if started on entity.
            // Drawing tools: no left-drag pan (drawing tools handle their own pointer events via onMouseMoved).
            if coordinator?.isSketchPlacementToolActive == false,
               coordinator?.dragCandidateEntityID == nil {
                coordinator?.handleSketchPan(event, in: self)
            }
            return
        }
        super.mouseDragged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        coordinator?.handleOtherMouseDown(event, in: self)
        super.otherMouseDown(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        if coordinator?.isSketch2DMode == true {
            coordinator?.handleSketchPan(event, in: self)
            return
        }
        super.otherMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.handleMouseUp(event, in: self)
        if coordinator?.isSketchPlacementToolActive != true {
            super.mouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.handleContextClick(event, in: self)
    }

    override func keyDown(with event: NSEvent) {
        if coordinator?.handleKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if coordinator?.isSketch2DMode == true {
            // Trackpad two-finger swipe has a gesture phase; mouse wheel does not.
            if !event.phase.isEmpty || !event.momentumPhase.isEmpty {
                coordinator?.handleSketchScrollPan(event, in: self)
            } else {
                coordinator?.handleSketchZoom(event, in: self)
            }
            return
        }
        super.scrollWheel(with: event)
    }
}

private extension SCNNode {
    var childNodesRecursive: [SCNNode] {
        childNodes + childNodes.flatMap(\.childNodesRecursive)
    }

    var flattenedChildCount: Int {
        1 + childNodes.reduce(0) { partialResult, child in
            partialResult + child.flattenedChildCount
        }
    }
}
