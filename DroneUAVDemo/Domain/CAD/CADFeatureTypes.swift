import Foundation

// MARK: - Feature Operation

enum CADFeatureOperation: String, Codable, CaseIterable, Identifiable {
    case extrudeNewBody
    case extrudeAddMaterial
    case cutRemoveMaterialV2
    @available(*, deprecated, message: "Legacy Cut is disabled. Use cutRemoveMaterialV2.")
    case cutRemoveMaterial

    static var allCases: [CADFeatureOperation] {
        [.extrudeNewBody, .extrudeAddMaterial, .cutRemoveMaterialV2]
    }

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .extrudeNewBody:       return "cad.feature.op.extrude"
        case .extrudeAddMaterial:   return "cad.feature.op.extrude_add"
        case .cutRemoveMaterialV2:  return "cad.feature.op.cut"
        case .cutRemoveMaterial:    return "cad.feature.op.cut_legacy_disabled"
        }
    }

    var isCutV2: Bool { self == .cutRemoveMaterialV2 }

    static var activeWorkshopOperations: [CADFeatureOperation] {
        [.extrudeNewBody, .cutRemoveMaterialV2]
    }
}

// MARK: - Cut v2 Profile Metadata

enum CADCutV2ProfileType: String, Codable, Equatable {
    case circle
    case rectangle
    case polygon
    case unsupported

    var displayNameKey: String {
        switch self {
        case .circle:      return "cad.cut_v2.profile.circle"
        case .rectangle:   return "cad.cut_v2.profile.rectangle"
        case .polygon:     return "cad.cut_v2.profile.polygon"
        case .unsupported: return "cad.cut_v2.profile.unsupported"
        }
    }

    var isSupportedForCutPreview: Bool {
        self != .unsupported
    }
}

// MARK: - Depth Mode

enum DepthMode: String, Codable, CaseIterable, Identifiable {
    case distance
    case throughAll
    case upToObject
    case upToNearestFace

    var id: String { rawValue }

    var displayNameKey: String {
        switch self {
        case .distance:        return "cad.feature.depth.distance"
        case .throughAll:      return "cad.feature.depth.through_all"
        case .upToObject:      return "cad.feature.depth.up_to_object"
        case .upToNearestFace: return "cad.feature.depth.up_to_nearest_face"
        }
    }

    var isImplemented: Bool {
        self == .distance || self == .throughAll
    }
}

// MARK: - Feature Validation

enum CADFeatureValidation: Equatable {
    case valid
    case noProfile
    case insufficientDepth
    case noCutTarget
    case sketchNotOnFace
    case unsupportedDepthMode(DepthMode)
    case cutNormalMisaligned
    case cutVolumeOutsideTarget
    case cutBooleanInvalidResult
    case unsupportedOperation
    case noActiveSketch
    case noSelectedProfileArea
    case invalidProfileLoop
    case targetBodyNotSolid
    case invalidSketchPlaneFrame
    case invalidDepth
    case cutToolDoesNotIntersectBody
    case unsupportedProfileForCutV2
    case cutIntersectsExistingVoidUnsupported
    case cutResultNotSolid
    case cutResultBoundsInvalid
    case cutMissingCylindricalWall
    case cutMissingInternalWall
    case cutMissingBlindBottom
    case cutMissingExitOpening
    case unaffectedGeometryWasRemoved
    case cutVisibleTriangulationArtifact
    case invalidEntryFaceTriangulation
    case cutBooleanFailed
    case kernelCandidateValidationFailed
    case kernelCommitUnsupportedForCase
    case intersectingCutSupportedPendingValidation
    case intersectingCutValidationFailed
    case unsupportedIntersectingCutCase
    case trimLoopResolutionFailed
    case boundaryFragmentValidationFailed
    case internalOrphanFaceDetected
    case volumeRuleFailedAfterCut
    case kernelCandidateInvalid

    var isValid: Bool { self == .valid }

    var messageKey: String? {
        switch self {
        case .valid:                        return nil
        case .noProfile:                    return "cad.feature.validation.no_profile"
        case .insufficientDepth:            return "cad.feature.validation.insufficient_depth"
        case .noCutTarget:                  return "cad.feature.validation.no_cut_target"
        case .sketchNotOnFace:              return "cad.feature.validation.sketch_not_on_face"
        case .unsupportedDepthMode:         return "cad.feature.validation.unsupported_depth_mode"
        case .cutNormalMisaligned:          return "cad.feature.validation.cut_normal_misaligned"
        case .cutVolumeOutsideTarget:       return "cad.feature.validation.cut_volume_outside_target"
        case .cutBooleanInvalidResult:      return "cad.feature.validation.cut_boolean_invalid_result"
        case .unsupportedOperation:          return "cad.feature.validation.unsupported_operation"
        case .noActiveSketch:                return "cad.cut_v2.reason.no_active_sketch"
        case .noSelectedProfileArea:         return "cad.cut_v2.reason.no_selected_profile_area"
        case .invalidProfileLoop:            return "cad.cut_v2.reason.invalid_profile_loop"
        case .targetBodyNotSolid:            return "cad.cut_v2.reason.target_body_not_solid"
        case .invalidSketchPlaneFrame:       return "cad.cut_v2.reason.invalid_sketch_plane_frame"
        case .invalidDepth:                  return "cad.cut_v2.reason.invalid_depth"
        case .cutToolDoesNotIntersectBody:   return "cad.cut_v2.reason.cut_tool_does_not_intersect_body"
        case .unsupportedProfileForCutV2:    return "cad.cut_v2.reason.unsupported_profile_for_cut_v2"
        case .cutIntersectsExistingVoidUnsupported: return "cad.cut_v2.reason.intersecting_cut_unsupported"
        case .cutResultNotSolid:             return "cad.cut_v2.reason.cut_result_not_solid"
        case .cutResultBoundsInvalid:        return "cad.cut_v2.reason.cut_result_bounds_invalid"
        case .cutMissingCylindricalWall:     return "cad.cut_v2.reason.cut_missing_cylindrical_wall"
        case .cutMissingInternalWall:        return "cad.cut_v2.reason.cut_missing_internal_wall"
        case .cutMissingBlindBottom:         return "cad.cut_v2.reason.cut_missing_blind_bottom"
        case .cutMissingExitOpening:         return "cad.cut_v2.reason.cut_missing_exit_opening"
        case .unaffectedGeometryWasRemoved:  return "cad.cut_v2.reason.unaffected_geometry_was_removed"
        case .cutVisibleTriangulationArtifact: return "cad.cut_v2.reason.cut_visible_triangulation_artifact"
        case .invalidEntryFaceTriangulation: return "cad.cut_v2.reason.invalid_entry_face_triangulation"
        case .cutBooleanFailed:              return "cad.cut_v2.reason.cut_boolean_failed"
        case .kernelCandidateValidationFailed: return "cad.cut_v2.reason.kernel_candidate_validation_failed"
        case .kernelCommitUnsupportedForCase: return "cad.cut_v2.reason.kernel_commit_unsupported_for_case"
        case .intersectingCutSupportedPendingValidation: return "cad.cut_v2.reason.intersecting_cut_supported_pending_validation"
        case .intersectingCutValidationFailed: return "cad.cut_v2.reason.intersecting_cut_validation_failed"
        case .unsupportedIntersectingCutCase: return "cad.cut_v2.reason.unsupported_intersecting_cut_case"
        case .trimLoopResolutionFailed: return "cad.cut_v2.reason.trim_loop_resolution_failed"
        case .boundaryFragmentValidationFailed: return "cad.cut_v2.reason.boundary_fragment_validation_failed"
        case .internalOrphanFaceDetected: return "cad.cut_v2.reason.internal_orphan_face_detected"
        case .volumeRuleFailedAfterCut: return "cad.cut_v2.reason.volume_rule_failed_after_cut"
        case .kernelCandidateInvalid: return "cad.cut_v2.reason.kernel_candidate_invalid"
        }
    }
}

// MARK: - Solid Mesh Diagnostics

struct CADSolidTriangle: Codable, Equatable {
    var a: Int
    var b: Int
    var c: Int
}

struct CADSolidMeshSnapshot: Codable, Equatable {
    var vertices: [DesignVector3]
    var triangles: [CADSolidTriangle]
}

struct CADSolidMeshDiagnostics: Codable, Equatable {
    var vertexCount: Int
    var triangleCount: Int
    var invalidVertexCount: Int
    var zeroAreaTriangleCount: Int
    var sliverTriangleCount: Int
    var duplicateFaceCount: Int
    var boundaryEdgeCount: Int
    var boundaryLoopCount: Int
    var nonManifoldEdgeCount: Int
    var volumeEstimate: Double
    var boundsMin: DesignVector3?
    var boundsMax: DesignVector3?

    var hasInvalidTopology: Bool {
        invalidVertexCount > 0
            || zeroAreaTriangleCount > 0
            || sliverTriangleCount > 0
            || duplicateFaceCount > 0
            || boundaryEdgeCount > 0
            || nonManifoldEdgeCount > 0
    }

    var hasOpenBoundary: Bool {
        boundaryEdgeCount > 0
    }

    var isClosedManifold: Bool {
        vertexCount > 0
            && triangleCount > 0
            && invalidVertexCount == 0
            && zeroAreaTriangleCount == 0
            && sliverTriangleCount == 0
            && duplicateFaceCount == 0
            && boundaryEdgeCount == 0
            && nonManifoldEdgeCount == 0
    }
}

enum CADSolidMeshValidator {
    private struct QuantizedVertexKey: Hashable {
        var x: Int64
        var y: Int64
        var z: Int64
    }

    private struct QuantizedEdgeKey: Hashable {
        var a: QuantizedVertexKey
        var b: QuantizedVertexKey
    }

    static func diagnose(
        _ mesh: CADSolidMeshSnapshot,
        epsilon: Double = 1e-6
    ) -> CADSolidMeshDiagnostics {
        let safeEpsilon = max(epsilon, 1e-9)
        var invalidVertexCount = 0
        var boundsMin: DesignVector3?
        var boundsMax: DesignVector3?

        for vertex in mesh.vertices {
            guard vertex.isFinite else {
                invalidVertexCount += 1
                continue
            }
            if let currentMin = boundsMin, let currentMax = boundsMax {
                boundsMin = DesignVector3(
                    x: min(currentMin.x, vertex.x),
                    y: min(currentMin.y, vertex.y),
                    z: min(currentMin.z, vertex.z)
                )
                boundsMax = DesignVector3(
                    x: max(currentMax.x, vertex.x),
                    y: max(currentMax.y, vertex.y),
                    z: max(currentMax.z, vertex.z)
                )
            } else {
                boundsMin = vertex
                boundsMax = vertex
            }
        }

        var edgeUseCounts: [QuantizedEdgeKey: Int] = [:]
        var faceUseCounts: [String: Int] = [:]
        var zeroAreaTriangleCount = 0
        var sliverTriangleCount = 0
        var volumeAccumulator = 0.0

        for triangle in mesh.triangles {
            guard mesh.vertices.indices.contains(triangle.a),
                  mesh.vertices.indices.contains(triangle.b),
                  mesh.vertices.indices.contains(triangle.c) else {
                zeroAreaTriangleCount += 1
                continue
            }

            let a = mesh.vertices[triangle.a]
            let b = mesh.vertices[triangle.b]
            let c = mesh.vertices[triangle.c]
            guard a.isFinite, b.isFinite, c.isFinite else {
                invalidVertexCount += 1
                continue
            }

            let ab = b - a
            let ac = c - a
            let doubledArea = ab.cross(ac).length
            let maxEdgeLength = max((b - a).length, max((c - b).length, (a - c).length))
            if doubledArea <= safeEpsilon * safeEpsilon {
                zeroAreaTriangleCount += 1
            } else if maxEdgeLength > safeEpsilon,
                      doubledArea <= safeEpsilon * maxEdgeLength * maxEdgeLength {
                sliverTriangleCount += 1
            }

            let qa = quantizedVertexKey(a, epsilon: safeEpsilon)
            let qb = quantizedVertexKey(b, epsilon: safeEpsilon)
            let qc = quantizedVertexKey(c, epsilon: safeEpsilon)
            edgeUseCounts[quantizedEdgeKey(qa, qb), default: 0] += 1
            edgeUseCounts[quantizedEdgeKey(qb, qc), default: 0] += 1
            edgeUseCounts[quantizedEdgeKey(qc, qa), default: 0] += 1

            let faceKey = [qa, qb, qc]
                .sorted(by: isLess)
                .map { "\($0.x),\($0.y),\($0.z)" }
                .joined(separator: "|")
            faceUseCounts[faceKey, default: 0] += 1
            volumeAccumulator += a.dot(b.cross(c)) / 6.0
        }

        let boundaryEdges = edgeUseCounts.filter { $0.value == 1 }.map(\.key)
        let nonManifoldEdgeCount = edgeUseCounts.values.filter { $0 > 2 }.count
        let duplicateFaceCount = faceUseCounts.values.reduce(0) { total, count in
            count > 1 ? total + count - 1 : total
        }

        return CADSolidMeshDiagnostics(
            vertexCount: mesh.vertices.count,
            triangleCount: mesh.triangles.count,
            invalidVertexCount: invalidVertexCount,
            zeroAreaTriangleCount: zeroAreaTriangleCount,
            sliverTriangleCount: sliverTriangleCount,
            duplicateFaceCount: duplicateFaceCount,
            boundaryEdgeCount: boundaryEdges.count,
            boundaryLoopCount: boundaryLoopCount(from: boundaryEdges),
            nonManifoldEdgeCount: nonManifoldEdgeCount,
            volumeEstimate: abs(volumeAccumulator),
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )
    }

    private static func quantizedVertexKey(_ vertex: DesignVector3, epsilon: Double) -> QuantizedVertexKey {
        QuantizedVertexKey(
            x: Int64((vertex.x / epsilon).rounded()),
            y: Int64((vertex.y / epsilon).rounded()),
            z: Int64((vertex.z / epsilon).rounded())
        )
    }

    private static func quantizedEdgeKey(_ first: QuantizedVertexKey, _ second: QuantizedVertexKey) -> QuantizedEdgeKey {
        isLess(first, second)
            ? QuantizedEdgeKey(a: first, b: second)
            : QuantizedEdgeKey(a: second, b: first)
    }

    private static func isLess(_ lhs: QuantizedVertexKey, _ rhs: QuantizedVertexKey) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }

    private static func boundaryLoopCount(from edges: [QuantizedEdgeKey]) -> Int {
        guard !edges.isEmpty else { return 0 }
        var adjacency: [QuantizedVertexKey: Set<QuantizedVertexKey>] = [:]
        for edge in edges {
            adjacency[edge.a, default: []].insert(edge.b)
            adjacency[edge.b, default: []].insert(edge.a)
        }

        var visited: Set<QuantizedVertexKey> = []
        var componentCount = 0
        for start in adjacency.keys where !visited.contains(start) {
            componentCount += 1
            var stack = [start]
            visited.insert(start)
            while let current = stack.popLast() {
                for next in adjacency[current, default: []] where !visited.contains(next) {
                    visited.insert(next)
                    stack.append(next)
                }
            }
        }
        return componentCount
    }
}

// MARK: - Cut Commit Diagnostics

struct CutCommitValidationResult: Equatable {
    var isValid: Bool
    var canCommit: Bool
    var targetBodyID: UUID?
    var uiSelectedBodyID: UUID?
    var kernelTargetBodyID: UUID?
    var applyTargetBodyID: UUID?
    var previewTargetBodyID: UUID?
    var cutProfileType: CADCutV2ProfileType
    var cutDepthMode: DepthMode
    var cutDirection: ExtrudeDirection
    var intersectsExistingVoid: Bool
    var createsOpenShell: Bool
    var createsNonManifoldEdges: Bool
    var createsFloatingIsland: Bool
    var reason: String?

    static func blocked(
        targetBodyID: UUID?,
        uiSelectedBodyID: UUID? = nil,
        kernelTargetBodyID: UUID? = nil,
        applyTargetBodyID: UUID? = nil,
        previewTargetBodyID: UUID? = nil,
        cutProfileType: CADCutV2ProfileType,
        cutDepthMode: DepthMode,
        cutDirection: ExtrudeDirection,
        intersectsExistingVoid: Bool = false,
        createsOpenShell: Bool = false,
        createsNonManifoldEdges: Bool = false,
        createsFloatingIsland: Bool = false,
        reason: String?
    ) -> CutCommitValidationResult {
        CutCommitValidationResult(
            isValid: false,
            canCommit: false,
            targetBodyID: targetBodyID,
            uiSelectedBodyID: uiSelectedBodyID ?? targetBodyID,
            kernelTargetBodyID: kernelTargetBodyID ?? targetBodyID,
            applyTargetBodyID: applyTargetBodyID ?? targetBodyID,
            previewTargetBodyID: previewTargetBodyID,
            cutProfileType: cutProfileType,
            cutDepthMode: cutDepthMode,
            cutDirection: cutDirection,
            intersectsExistingVoid: intersectsExistingVoid,
            createsOpenShell: createsOpenShell,
            createsNonManifoldEdges: createsNonManifoldEdges,
            createsFloatingIsland: createsFloatingIsland,
            reason: reason
        )
    }
}

// MARK: - Feature Record (Codable — stored in asset, shown in project tree)

struct CADFeatureRecord: Codable, Equatable {
    var featureID: UUID
    var operation: CADFeatureOperation
    var sourceSketchID: UUID
    var sourceSketchName: String
    var depthMeters: Double
    var direction: ExtrudeDirection
    var depthMode: DepthMode
    var timestamp: Date
}

// MARK: - Cut v2 Body Feature

struct ExtrudedSolidCutFeature: Codable, Identifiable, Equatable {
    var id: UUID
    var profilePoints: [SketchPoint2D]       // body sketch-local contour, no repeated last vertex
    var startOffsetMeters: Double            // offset along target body source normal
    var endOffsetMeters: Double              // offset along target body source normal
    var sourceSketchID: UUID
    var sourceSketchName: String
    var selectedProfileID: UUID
    var depthMode: DepthMode
    var direction: ExtrudeDirection

    var depthMeters: Double {
        abs(endOffsetMeters - startOffsetMeters)
    }
}

struct ExtrudedSolidBoxBlindCutFeature: Codable, Identifiable, Equatable {
    var id: UUID
    var profileType: CADCutV2ProfileType
    var entryFaceID: UUID
    var profilePoints: [SketchPoint2D]       // entry face-local contour, no repeated last vertex
    var depthMeters: Double
    var cutDirection: DesignVector3          // world-space direction into the target solid
    var sourceSketchID: UUID
    var sourceSketchName: String
    var selectedProfileID: UUID
    var depthMode: DepthMode
    var direction: ExtrudeDirection
}

// MARK: - Cut v2 Transaction

struct CADBodyEditTransaction: Equatable {
    var transactionID: UUID
    var operationType: CADFeatureOperation
    var targetBodyID: UUID
    var bodyGeometryBefore: ExtrudedSolidParameters
    var bodyMaterialBefore: DesignMaterial
    var bodyTransformBefore: DesignTransform
    var bodyRenderStateBefore: CADBodyRenderState
    var bodyVisibilityBefore: Bool
    var selectedProfileID: UUID
    var sketchPlaneFrame: CADSketchPlaneFrame
    var previewNodeID: String?
}

struct CADBodyRenderState: Equatable {
    var isOpaque: Bool = true
    var writesDepth: Bool = true
    var readsDepth: Bool = true
    var renderingOrder: Int = 0
}

struct CADSketchPlaneFrame: Equatable {
    var origin: DesignVector3
    var basisU: DesignVector3
    var basisV: DesignVector3
    var normal: DesignVector3

    var isFinite: Bool {
        origin.isFinite && basisU.isFinite && basisV.isFinite && normal.isFinite
    }
}

// MARK: - Feature Preview State (transient — not Codable)

struct CADFeaturePreviewState: Equatable {
    var operation: CADFeatureOperation
    var profilePoints: [SketchPoint2D]
    var sourceReference: SketchReference
    var targetBodyID: UUID?
    var selectedProfileID: UUID?
    var depthMeters: Double
    var direction: ExtrudeDirection
    var depthMode: DepthMode
    var material: DesignMaterial
    var sourceSketchID: UUID
    var sourceSketchName: String

    func asExtrudedSolidParameters(assetID: UUID) -> ExtrudedSolidParameters {
        ExtrudedSolidParameters(
            assetID: assetID,
            sourceSketchID: sourceSketchID,
            sourceSketchName: sourceSketchName,
            profilePoints: profilePoints,
            sourceReference: sourceReference,
            depthMeters: depthMeters,
            direction: direction,
            material: material
        )
    }
}
