import Foundation

// MARK: - Solid Backend Foundation

struct CADSolidBounds: Codable, Equatable {
    var min: DesignVector3
    var max: DesignVector3

    init?(points: [DesignVector3]) {
        guard let first = points.first, first.isFinite else { return nil }
        var minPoint = first
        var maxPoint = first
        for point in points.dropFirst() {
            guard point.isFinite else { return nil }
            minPoint = DesignVector3(
                x: Swift.min(minPoint.x, point.x),
                y: Swift.min(minPoint.y, point.y),
                z: Swift.min(minPoint.z, point.z)
            )
            maxPoint = DesignVector3(
                x: Swift.max(maxPoint.x, point.x),
                y: Swift.max(maxPoint.y, point.y),
                z: Swift.max(maxPoint.z, point.z)
            )
        }
        min = minPoint
        max = maxPoint
    }

    func intersects(_ other: CADSolidBounds, tolerance: Double = 1e-6) -> Bool {
        min.x <= other.max.x + tolerance && max.x + tolerance >= other.min.x
            && min.y <= other.max.y + tolerance && max.y + tolerance >= other.min.y
            && min.z <= other.max.z + tolerance && max.z + tolerance >= other.min.z
    }

    func contains(_ point: DesignVector3, tolerance: Double = 1e-6) -> Bool {
        point.x >= min.x - tolerance && point.x <= max.x + tolerance
            && point.y >= min.y - tolerance && point.y <= max.y + tolerance
            && point.z >= min.z - tolerance && point.z <= max.z + tolerance
    }

    func union(_ other: CADSolidBounds) -> CADSolidBounds {
        CADSolidBounds(
            min: DesignVector3(
                x: Swift.min(min.x, other.min.x),
                y: Swift.min(min.y, other.min.y),
                z: Swift.min(min.z, other.min.z)
            ),
            max: DesignVector3(
                x: Swift.max(max.x, other.max.x),
                y: Swift.max(max.y, other.max.y),
                z: Swift.max(max.z, other.max.z)
            )
        )
    }

    var volumeEstimate: Double {
        Swift.max(max.x - min.x, 0)
            * Swift.max(max.y - min.y, 0)
            * Swift.max(max.z - min.z, 0)
    }

    private init(min: DesignVector3, max: DesignVector3) {
        self.min = min
        self.max = max
    }
}

struct CADSketchProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var outerLoop: [SketchPoint2D]
    var holes: [[SketchPoint2D]]?
    var sourceReference: SketchReference

    var areaMeters2: Double {
        max(
            abs(DesignSketch.polygonSignedAreaMeters2(outerLoop))
                - (holes ?? []).reduce(0.0) { $0 + DesignSketch.polygonAreaMeters2($1) },
            0
        )
    }
}

enum CADBooleanOperation: String, Codable, Equatable {
    case union
    case subtract
    case intersect
}

enum CADVolumeKind: String, Codable, Equatable {
    case boxExtrusion
    case rectangularPrism
    case cylinder
    case unsupported
}

enum CADVolumeOperationRole: String, Codable, Equatable {
    case additive
    case subtractive
}

enum CADMaterialClassification: String, Codable, Equatable {
    case material
    case empty
    case boundary
    case unknown
}

enum CADFeatureType: String, Codable, Equatable {
    case extrudeAdd
    case extrudeCut
}

enum CADOperationValidationSeverity: String, Codable, Equatable {
    case info
    case warning
    case error
}

enum CADOperationValidationReasonCode: String, Codable, Equatable {
    case none
    case noTargetBody = "no_target_body"
    case noSelectedProfile = "no_selected_profile"
    case profileNotClosed = "profile_not_closed"
    case invalidProfileArea = "invalid_profile_area"
    case invalidDepth = "invalid_depth"
    case invalidDirection = "invalid_direction"
    case cutterDoesNotIntersectBody = "cutter_does_not_intersect_body"
    case unsupportedProfileKind = "unsupported_profile_kind"
    case unsupportedIntersectingCutUntilSolidKernelV02 = "unsupported_intersecting_cut_until_solid_kernel_v02"
    case cadSolidRecordingFailed = "cad_solid_recording_failed"
    case topologyValidationFailed = "topology_validation_failed"
    case unsupportedSurfaceIntersectionV04 = "unsupported_surface_intersection_v04"
    case trimLoopValidationFailedV04 = "trim_loop_validation_failed_v04"
    case unsupportedIntersectionCaseV04 = "unsupported_intersection_case_v04"
    case boundaryBuilderValidationFailedForIntersectingCut = "boundary_builder_validation_failed_for_intersecting_cut"
}

struct CADOperationValidationResult: Codable, Equatable {
    var isValid: Bool
    var severity: CADOperationValidationSeverity
    var reasonCode: CADOperationValidationReasonCode
    var message: String
    var debugDetails: [String]

    static func valid(debugDetails: [String] = []) -> CADOperationValidationResult {
        CADOperationValidationResult(
            isValid: true,
            severity: .info,
            reasonCode: .none,
            message: "Operation valid",
            debugDetails: debugDetails
        )
    }

    static func invalid(
        _ reasonCode: CADOperationValidationReasonCode,
        message: String,
        debugDetails: [String] = []
    ) -> CADOperationValidationResult {
        CADOperationValidationResult(
            isValid: false,
            severity: .error,
            reasonCode: reasonCode,
            message: message,
            debugDetails: debugDetails
        )
    }
}

struct CADSketchProfileRef: Codable, Equatable {
    var sketchID: UUID
    var profileID: UUID?
    var profileKind: CADCutV2ProfileType
}

struct CADVisualMeshCache: Codable, Equatable {
    var mesh: CADSolidMeshSnapshot?
    var diagnostics: CADSolidMeshDiagnostics?
    var generationVersion: Int
}

struct CADSolidEvaluationReport: Codable, Equatable {
    var bodyID: UUID
    var additiveVolumeCount: Int
    var cutterVolumeCount: Int
    var estimatedBounds: CADSolidBounds?
    var estimatedVolumeBefore: Double
    var estimatedVolumeAfter: Double
    var unsupportedIntersections: Bool
    var validationErrors: [CADOperationValidationResult]
}

struct CADVolume: Codable, Identifiable, Equatable {
    var id: UUID
    var kind: CADVolumeKind
    var operationRole: CADVolumeOperationRole
    var profileType: CADCutV2ProfileType
    var sourceSketchID: UUID?
    var sourceProfileID: UUID?
    var entryFaceID: UUID?
    var profilePoints: [SketchPoint2D]
    var holes: [[SketchPoint2D]]
    var origin: DesignVector3
    var uAxis: DesignVector3
    var vAxis: DesignVector3
    var direction: DesignVector3
    var depthMeters: Double
    var depthMode: DepthMode
    var bounds: CADSolidBounds

    var estimatedVolumeMeters3: Double {
        max(
            DesignSketch.polygonAreaMeters2(profilePoints)
                - holes.reduce(0.0) { $0 + DesignSketch.polygonAreaMeters2($1) },
            0
        ) * max(depthMeters, 0)
    }

    func contains(_ point: DesignVector3, epsilon: Double = 1e-6) -> Bool? {
        guard kind != .unsupported,
              depthMeters.isFinite,
              depthMeters > epsilon,
              direction.isFinite,
              uAxis.isFinite,
              vAxis.isFinite else {
            return nil
        }
        guard bounds.contains(point, tolerance: epsilon) else { return false }

        let local = localCoordinates(for: point)
        guard local.depth >= -epsilon,
              local.depth <= depthMeters + epsilon else {
            return false
        }

        switch kind {
        case .cylinder:
            guard let circle = circleMetrics() else { return nil }
            let du = local.u - circle.center.u
            let dv = local.v - circle.center.v
            return sqrt(du * du + dv * dv) <= circle.radius + epsilon
        case .boxExtrusion, .rectangularPrism:
            if holes.contains(where: {
                Self.pointInPolygon(
                    SketchPoint2D(u: local.u, v: local.v),
                    polygon: $0,
                    tolerance: epsilon
                )
            }) {
                return false
            }
            return Self.pointInPolygon(
                SketchPoint2D(u: local.u, v: local.v),
                polygon: profilePoints,
                tolerance: epsilon
            )
        case .unsupported:
            return nil
        }
    }

    func isOnBoundary(_ point: DesignVector3, epsilon: Double = 1e-6) -> Bool? {
        guard let containsPoint = contains(point, epsilon: epsilon),
              containsPoint else {
            return contains(point, epsilon: epsilon)
        }
        guard let distance = approximateSignedDistance(point) else { return nil }
        return abs(distance) <= epsilon
    }

    func approximateSignedDistance(_ point: DesignVector3) -> Double? {
        guard kind != .unsupported,
              depthMeters.isFinite,
              depthMeters > 1e-9,
              direction.isFinite,
              uAxis.isFinite,
              vAxis.isFinite else {
            return nil
        }
        let local = localCoordinates(for: point)
        let axialOutside = max(-local.depth, local.depth - depthMeters, 0)
        let axialInside = min(local.depth, depthMeters - local.depth)

        switch kind {
        case .cylinder:
            guard let circle = circleMetrics() else { return nil }
            let du = local.u - circle.center.u
            let dv = local.v - circle.center.v
            let radialDistance = sqrt(du * du + dv * dv)
            let radialOutside = max(radialDistance - circle.radius, 0)
            if axialOutside > 0 || radialOutside > 0 {
                return sqrt(axialOutside * axialOutside + radialOutside * radialOutside)
            }
            return -min(circle.radius - radialDistance, axialInside)
        case .boxExtrusion, .rectangularPrism:
            let localPoint = SketchPoint2D(u: local.u, v: local.v)
            let insideProfile = Self.pointInPolygon(localPoint, polygon: profilePoints, tolerance: 1e-9)
            let edgeDistance = Self.distanceToPolygonEdges(localPoint, polygon: profilePoints)
            if !insideProfile || axialOutside > 0 {
                return max(insideProfile ? 0 : edgeDistance, axialOutside)
            }
            return -min(edgeDistance, axialInside)
        case .unsupported:
            return nil
        }
    }

    private func localCoordinates(for point: DesignVector3) -> (u: Double, v: Double, depth: Double) {
        let delta = point - origin
        return (
            u: delta.dot(uAxis.normalized(fallback: .xAxis)),
            v: delta.dot(vAxis.normalized(fallback: .yAxis)),
            depth: delta.dot(direction.normalized(fallback: .zAxis))
        )
    }

    private func circleMetrics() -> (center: SketchPoint2D, radius: Double)? {
        guard profilePoints.count >= 8 else { return nil }
        let center = profilePoints.reduce(SketchPoint2D.zero) { partial, point in
            SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
        }
        let count = Double(profilePoints.count)
        let averagedCenter = SketchPoint2D(u: center.u / count, v: center.v / count)
        let radius = profilePoints.reduce(0.0) { total, point in
            total + point.distance(to: averagedCenter)
        } / count
        guard radius.isFinite, radius > 1e-9 else { return nil }
        return (averagedCenter, radius)
    }

    private static func pointInPolygon(
        _ point: SketchPoint2D,
        polygon: [SketchPoint2D],
        tolerance: Double
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if distanceFromPoint(point, toSegmentA: pi, b: pj) <= tolerance {
                return true
            }
            let crosses = (pi.v > point.v) != (pj.v > point.v)
            if crosses {
                let denominator = pj.v - pi.v
                if abs(denominator) > tolerance {
                    let intersectU = (pj.u - pi.u) * (point.v - pi.v) / denominator + pi.u
                    if point.u < intersectU {
                        inside.toggle()
                    }
                }
            }
            j = i
        }
        return inside
    }

    private static func distanceToPolygonEdges(
        _ point: SketchPoint2D,
        polygon: [SketchPoint2D]
    ) -> Double {
        guard polygon.count >= 2 else { return Double.infinity }
        var result = Double.infinity
        for index in polygon.indices {
            let next = (index + 1) % polygon.count
            result = min(result, distanceFromPoint(point, toSegmentA: polygon[index], b: polygon[next]))
        }
        return result
    }

    private static func distanceFromPoint(
        _ point: SketchPoint2D,
        toSegmentA a: SketchPoint2D,
        b: SketchPoint2D
    ) -> Double {
        let abU = b.u - a.u
        let abV = b.v - a.v
        let lengthSquared = abU * abU + abV * abV
        guard lengthSquared > 1e-18 else { return point.distance(to: a) }
        let apU = point.u - a.u
        let apV = point.v - a.v
        let t = max(0, min(1, (apU * abU + apV * abV) / lengthSquared))
        let projected = SketchPoint2D(u: a.u + abU * t, v: a.v + abV * t)
        return point.distance(to: projected)
    }
}

struct CADPrismaticSolidRepresentation: Codable, Equatable {
    var baseProfile: [SketchPoint2D]
    var sourceReference: SketchReference
    var depthMeters: Double
    var direction: ExtrudeDirection
    var faces: [DesignPlanarFace]
    var removedVolumes: [CADVolume]
}

struct CADSolidEvaluatedState: Codable, Equatable {
    var materialRuleVersion: Int
    var additiveVolumeCount: Int
    var cutterVolumeCount: Int
    var boundingBox: CADSolidBounds?
    var estimatedVolumeMeters3: Double
    var validationState: CADOperationValidationResult
}

struct CADSolid: Codable, Identifiable, Equatable {
    var id: UUID
    var additiveVolumes: [CADVolume]
    var cutterVolumes: [CADVolume]
    var evaluatedState: CADSolidEvaluatedState
    var evaluatedBounds: CADSolidBounds?
    var validationState: CADOperationValidationResult
    var generationVersion: Int
    var legacyPrismaticRepresentation: CADPrismaticSolidRepresentation?
    var visualMeshCache: CADVisualMeshCache?
}

struct CADBody: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var solid: CADSolid
    var materialID: DesignMaterial
    var visualMeshCache: CADVisualMeshCache?
    var featureHistory: [UUID]
}

struct CADFeatureParameters: Codable, Equatable {
    var depthMeters: Double
    var depthMode: DepthMode
    var direction: ExtrudeDirection
    var profileKind: CADCutV2ProfileType
}

struct CADFeature: Codable, Identifiable, Equatable {
    var id: UUID
    var type: CADFeatureType
    var targetBodyID: UUID?
    var sourceSketchID: UUID
    var sourceProfileID: UUID?
    var createdVolumeID: UUID?
    var parameters: CADFeatureParameters
    var timestamp: Date
    var order: Int
    var validationResult: CADOperationValidationResult
}

struct CADDocument: Codable, Equatable {
    var id: UUID
    var bodies: [CADBody]
    var sketches: [DesignSketch]
    var features: [CADFeature]
    var activeBodyID: UUID?
    var activeSketchID: UUID?

    init(
        id: UUID = UUID(),
        bodies: [CADBody] = [],
        sketches: [DesignSketch] = [],
        features: [CADFeature] = [],
        activeBodyID: UUID? = nil,
        activeSketchID: UUID? = nil
    ) {
        self.id = id
        self.bodies = bodies
        self.sketches = sketches
        self.features = features
        self.activeBodyID = activeBodyID
        self.activeSketchID = activeSketchID
    }
}

enum CADKernelRenderMode: String, Codable, CaseIterable, Identifiable {
    case conservativeLegacy
    case kernelShadow
    case kernelPreview
    case kernelCommitValidated

    var id: String { rawValue }
}

enum CADKernelMeshCandidateSourceMode: String, Codable, Equatable {
    case graphTrimKernel
}

struct CADKernelMeshCandidate: Equatable {
    var bodyID: UUID
    var sourceSolidVersion: Int
    var featureID: UUID?
    var mesh: CADSolidMeshSnapshot
    var normals: [DesignVector3]
    var indices: [Int]
    var materialIDs: [String]
    var bounds: CADSolidBounds?
    var diagnostics: CADSolidMeshDiagnostics
    var boundaryDiagnostics: CADBoundaryBuildDiagnostics?
    var validationResults: [CADSurfaceBoundaryValidationResult]
    var validationResult: CADOperationValidationResult
    var buildTimeMs: Double
    var sourceMode: CADKernelMeshCandidateSourceMode
}

struct CADBooleanKernelRequest: Equatable {
    var operation: CADBooleanOperation
    var targetBodyID: UUID
    var sourceSolid: CADSolid
    var toolVolume: CADVolume
    var featureID: UUID?
}

struct CADBooleanKernelResult: Equatable {
    var operation: CADBooleanOperation
    var targetBodyID: UUID
    var sourceSolid: CADSolid
    var resultSolid: CADSolid?
    var candidate: CADKernelMeshCandidate?
    var validationResult: CADOperationValidationResult
    var canCommit: Bool
}

struct CADMeshBuildResult: Equatable {
    var mesh: CADSolidMeshSnapshot
    var normals: [DesignVector3]
    var indices: [Int]
    var materials: [String]
    var diagnostics: CADSolidMeshDiagnostics
    var boundaryDiagnostics: CADBoundaryBuildDiagnostics?
    var validationResults: [CADSurfaceBoundaryValidationResult]
    var validationResult: CADOperationValidationResult
}

struct CADTopologyValidationResult: Equatable {
    var isValid: Bool
    var diagnostics: CADSolidMeshDiagnostics
    var failure: CADFeatureValidation?
}

struct CADBooleanKernel {
    var classifier: CADSolidMaterialClassifier = CADSolidMaterialClassifier(epsilon: 1e-5)
    var boundaryOptions: CADBoundaryBuildOptions = CADBoundaryBuildOptions()

    func evaluate(_ request: CADBooleanKernelRequest) -> CADBooleanKernelResult {
        guard request.sourceSolid.id == request.targetBodyID else {
            return rejected(
                request,
                reason: .noTargetBody,
                message: "Commit blocked: target body id is missing in apply context.",
                debugDetails: [
                    "sourceSolidID=\(request.sourceSolid.id.uuidString)",
                    "targetBodyID=\(request.targetBodyID.uuidString)"
                ]
            )
        }

        guard var resultSolid = makeResultSolid(for: request) else {
            return rejected(
                request,
                reason: .unsupportedIntersectionCaseV04,
                message: "Commit blocked: Boolean operation is not supported by the current kernel.",
                debugDetails: ["operation=\(request.operation.rawValue)"]
            )
        }

        let candidate = CADKernelMeshCandidateBuilder().buildCandidate(
            bodyID: request.targetBodyID,
            solid: resultSolid,
            featureID: request.featureID,
            classifier: classifier,
            options: boundaryOptions
        )
        let validation = validateOperationRule(
            request: request,
            resultSolid: resultSolid,
            candidate: candidate
        )
        resultSolid.validationState = validation
        if validation.isValid {
            resultSolid.evaluatedState.estimatedVolumeMeters3 = candidate.diagnostics.volumeEstimate
            resultSolid.evaluatedState.validationState = validation
            resultSolid.visualMeshCache = CADVisualMeshCache(
                mesh: candidate.mesh,
                diagnostics: candidate.diagnostics,
                generationVersion: resultSolid.generationVersion
            )
        }
        return CADBooleanKernelResult(
            operation: request.operation,
            targetBodyID: request.targetBodyID,
            sourceSolid: request.sourceSolid,
            resultSolid: resultSolid,
            candidate: candidate,
            validationResult: validation,
            canCommit: validation.isValid
        )
    }

    private func rejected(
        _ request: CADBooleanKernelRequest,
        reason: CADOperationValidationReasonCode,
        message: String,
        debugDetails: [String] = []
    ) -> CADBooleanKernelResult {
        CADBooleanKernelResult(
            operation: request.operation,
            targetBodyID: request.targetBodyID,
            sourceSolid: request.sourceSolid,
            resultSolid: nil,
            candidate: nil,
            validationResult: .invalid(reason, message: message, debugDetails: debugDetails),
            canCommit: false
        )
    }

    private func makeResultSolid(for request: CADBooleanKernelRequest) -> CADSolid? {
        var result = request.sourceSolid
        switch request.operation {
        case .union:
            guard request.toolVolume.operationRole == .additive else { return nil }
            result.additiveVolumes.append(request.toolVolume)
        case .subtract:
            guard request.toolVolume.operationRole == .subtractive else { return nil }
            result.cutterVolumes.append(request.toolVolume)
        case .intersect:
            return nil
        }

        result.evaluatedBounds = bounds(for: result.additiveVolumes)
        result.evaluatedState = evaluatedState(
            additiveVolumes: result.additiveVolumes,
            cutterVolumes: result.cutterVolumes,
            boundingBox: result.evaluatedBounds
        )
        result.validationState = .invalid(.topologyValidationFailed, message: "Pending boundary reconstruction", debugDetails: [
            "operation=\(request.operation.rawValue)",
            "toolVolumeID=\(request.toolVolume.id.uuidString)"
        ])
        result.generationVersion += 1
        result.visualMeshCache = nil
        return result
    }

    private func validateOperationRule(
        request: CADBooleanKernelRequest,
        resultSolid: CADSolid,
        candidate: CADKernelMeshCandidate
    ) -> CADOperationValidationResult {
        guard candidate.validationResult.isValid else {
            return candidate.validationResult
        }
        guard candidate.diagnostics.boundaryEdgeCount == 0,
              candidate.diagnostics.nonManifoldEdgeCount == 0,
              candidate.diagnostics.isClosedManifold else {
            return .invalid(
                .topologyValidationFailed,
                message: "Commit blocked: result mesh is not a closed manifold.",
                debugDetails: [
                    "boundaryEdges=\(candidate.diagnostics.boundaryEdgeCount)",
                    "nonManifoldEdges=\(candidate.diagnostics.nonManifoldEdgeCount)"
                ]
            )
        }

        let beforeVolume = request.sourceSolid.evaluatedState.estimatedVolumeMeters3
        let afterVolume = resultSolid.evaluatedState.estimatedVolumeMeters3
        let epsilon = 1e-9
        switch request.operation {
        case .subtract:
            guard afterVolume <= beforeVolume + epsilon else {
                return .invalid(
                    .topologyValidationFailed,
                    message: "Commit blocked: cut operation increased estimated body volume.",
                    debugDetails: ["before=\(beforeVolume)", "after=\(afterVolume)"]
                )
            }
        case .union:
            guard afterVolume >= beforeVolume - epsilon else {
                return .invalid(
                    .topologyValidationFailed,
                    message: "Commit blocked: add operation decreased estimated body volume.",
                    debugDetails: ["before=\(beforeVolume)", "after=\(afterVolume)"]
                )
            }
        case .intersect:
            return .invalid(
                .unsupportedIntersectionCaseV04,
                message: "Commit blocked: Intersect is not implemented by the current kernel."
            )
        }
        return .valid(debugDetails: ["source=CADBooleanKernel"])
    }

    private func bounds(for volumes: [CADVolume]) -> CADSolidBounds? {
        var result: CADSolidBounds?
        for volume in volumes {
            result = result.map { $0.union(volume.bounds) } ?? volume.bounds
        }
        return result
    }

    private func evaluatedState(
        additiveVolumes: [CADVolume],
        cutterVolumes: [CADVolume],
        boundingBox: CADSolidBounds?
    ) -> CADSolidEvaluatedState {
        let additiveVolume = additiveVolumes.reduce(0.0) { $0 + $1.estimatedVolumeMeters3 }
        let cutterVolume = cutterVolumes.reduce(0.0) { $0 + $1.estimatedVolumeMeters3 }
        return CADSolidEvaluatedState(
            materialRuleVersion: 1,
            additiveVolumeCount: additiveVolumes.count,
            cutterVolumeCount: cutterVolumes.count,
            boundingBox: boundingBox,
            estimatedVolumeMeters3: max(additiveVolume - cutterVolume, 0),
            validationState: .valid(debugDetails: [
                "additiveVolumeEstimate=\(additiveVolume)",
                "cutterVolumeEstimate=\(cutterVolume)"
            ])
        )
    }
}

struct CADKernelMeshCandidateBuilder {
    func buildCandidate(
        bodyID: UUID,
        solid: CADSolid,
        featureID: UUID?,
        classifier: CADSolidMaterialClassifier = CADSolidMaterialClassifier(epsilon: 1e-5),
        options: CADBoundaryBuildOptions = CADBoundaryBuildOptions()
    ) -> CADKernelMeshCandidate {
        let started = Date()
        let buildResult = CADBoundarySurfaceBuilder().buildBoundaryMesh(
            solid: solid,
            classifier: classifier,
            options: options
        )
        let validation = validate(buildResult: buildResult)
        return CADKernelMeshCandidate(
            bodyID: bodyID,
            sourceSolidVersion: solid.generationVersion,
            featureID: featureID,
            mesh: buildResult.mesh,
            normals: buildResult.normals,
            indices: buildResult.indices,
            materialIDs: buildResult.materials,
            bounds: CADSolidBounds(points: buildResult.mesh.vertices),
            diagnostics: buildResult.diagnostics,
            boundaryDiagnostics: buildResult.boundaryDiagnostics,
            validationResults: buildResult.validationResults,
            validationResult: validation,
            buildTimeMs: Date().timeIntervalSince(started) * 1000.0,
            sourceMode: .graphTrimKernel
        )
    }

    private func validate(buildResult: CADMeshBuildResult) -> CADOperationValidationResult {
        guard !buildResult.mesh.vertices.isEmpty else {
            return .invalid(.topologyValidationFailed, message: "Kernel candidate has no vertices")
        }
        guard !buildResult.mesh.triangles.isEmpty else {
            return .invalid(.topologyValidationFailed, message: "Kernel candidate has no triangles")
        }
        guard buildResult.mesh.vertices.allSatisfy(\.isFinite) else {
            return .invalid(.topologyValidationFailed, message: "Kernel candidate contains non-finite vertices")
        }
        guard buildResult.mesh.triangles.allSatisfy({ triangle in
            buildResult.mesh.vertices.indices.contains(triangle.a)
                && buildResult.mesh.vertices.indices.contains(triangle.b)
                && buildResult.mesh.vertices.indices.contains(triangle.c)
        }) else {
            return .invalid(.topologyValidationFailed, message: "Kernel candidate contains invalid indices")
        }
        guard !buildResult.materials.contains(where: { material in
            material.localizedCaseInsensitiveContains("preview")
                || material.localizedCaseInsensitiveContains("cutter")
                || material.localizedCaseInsensitiveContains("red")
        }) else {
            return .invalid(.topologyValidationFailed, message: "Kernel candidate contains preview/cutter material")
        }
        guard buildResult.diagnostics.isClosedManifold else {
            return .invalid(
                .topologyValidationFailed,
                message: "Kernel candidate topology validation failed",
                debugDetails: [
                    "zeroAreaTriangles=\(buildResult.diagnostics.zeroAreaTriangleCount)",
                    "duplicateFaces=\(buildResult.diagnostics.duplicateFaceCount)",
                    "nonManifoldEdges=\(buildResult.diagnostics.nonManifoldEdgeCount)",
                    "boundaryEdges=\(buildResult.diagnostics.boundaryEdgeCount)"
                ]
            )
        }
        guard buildResult.validationResult.isValid else {
            return buildResult.validationResult
        }
        return .valid(debugDetails: ["source=CADKernelMeshCandidateBuilder"])
    }
}

struct CADSolidClassificationDebugReport: Codable, Equatable {
    var additiveVolumeCount: Int
    var cutterVolumeCount: Int
    var supportedVolumeTypeCount: Int
    var unsupportedVolumeCount: Int
    var intersectingCutterVolumeCount: Int
    var lastSampleClassification: CADMaterialClassification?
}

struct CADSolidMaterialClassifier {
    var epsilon: Double = 1e-6

    func classify(_ point: SIMD3<Double>, in solid: CADSolid) -> CADMaterialClassification {
        classify(DesignVector3(x: point.x, y: point.y, z: point.z), in: solid)
    }

    func classify(_ point: DesignVector3, in solid: CADSolid) -> CADMaterialClassification {
        if isBoundary(point, solid: solid) {
            return .boundary
        }
        guard let insideAdd = isInsideAnyAdditive(point, solid: solid),
              let insideCut = isInsideAnyCutter(point, solid: solid) else {
            return .unknown
        }
        return insideAdd && !insideCut ? .material : .empty
    }

    func isInsideFinalSolid(_ point: SIMD3<Double>, solid: CADSolid) -> Bool {
        isInsideFinalSolid(DesignVector3(x: point.x, y: point.y, z: point.z), solid: solid)
    }

    func isInsideFinalSolid(_ point: DesignVector3, solid: CADSolid) -> Bool {
        classify(point, in: solid) == .material
    }

    func isInsideAnyAdditive(_ point: SIMD3<Double>, solid: CADSolid) -> Bool? {
        isInsideAnyAdditive(DesignVector3(x: point.x, y: point.y, z: point.z), solid: solid)
    }

    func isInsideAnyAdditive(_ point: DesignVector3, solid: CADSolid) -> Bool? {
        contains(point, in: solid.additiveVolumes)
    }

    func isInsideAnyCutter(_ point: SIMD3<Double>, solid: CADSolid) -> Bool? {
        isInsideAnyCutter(DesignVector3(x: point.x, y: point.y, z: point.z), solid: solid)
    }

    func isInsideAnyCutter(_ point: DesignVector3, solid: CADSolid) -> Bool? {
        contains(point, in: solid.cutterVolumes)
    }

    func signedDistanceApprox(_ point: SIMD3<Double>, to volume: CADVolume) -> Double? {
        signedDistanceApprox(DesignVector3(x: point.x, y: point.y, z: point.z), to: volume)
    }

    func signedDistanceApprox(_ point: DesignVector3, to volume: CADVolume) -> Double? {
        volume.approximateSignedDistance(point)
    }

    func debugReport(
        for solid: CADSolid,
        lastSamplePoint: DesignVector3? = nil
    ) -> CADSolidClassificationDebugReport {
        let volumes = solid.additiveVolumes + solid.cutterVolumes
        let unsupportedCount = volumes.filter { $0.kind == .unsupported }.count
        return CADSolidClassificationDebugReport(
            additiveVolumeCount: solid.additiveVolumes.count,
            cutterVolumeCount: solid.cutterVolumes.count,
            supportedVolumeTypeCount: volumes.count - unsupportedCount,
            unsupportedVolumeCount: unsupportedCount,
            intersectingCutterVolumeCount: intersectingCutterVolumeCount(in: solid),
            lastSampleClassification: lastSamplePoint.map { classify($0, in: solid) }
        )
    }

    func intersectingCutterVolumeCount(in solid: CADSolid) -> Int {
        guard solid.cutterVolumes.count > 1 else { return 0 }
        var count = 0
        for leftIndex in solid.cutterVolumes.indices {
            for rightIndex in solid.cutterVolumes.indices where rightIndex > leftIndex {
                if solid.cutterVolumes[leftIndex].bounds.intersects(solid.cutterVolumes[rightIndex].bounds) {
                    count += 1
                }
            }
        }
        return count
    }

    private func contains(_ point: DesignVector3, in volumes: [CADVolume]) -> Bool? {
        var sawUnsupported = false
        for volume in volumes {
            guard let containsPoint = volume.contains(point, epsilon: epsilon) else {
                sawUnsupported = true
                continue
            }
            if containsPoint { return true }
        }
        return sawUnsupported ? nil : false
    }

    private func isBoundary(_ point: DesignVector3, solid: CADSolid) -> Bool {
        for additive in solid.additiveVolumes {
            guard let onBoundary = additive.isOnBoundary(point, epsilon: epsilon) else { return false }
            if onBoundary {
                let insideCut = isInsideAnyCutter(point, solid: solid)
                if insideCut == false { return true }
            }
        }

        for cutter in solid.cutterVolumes {
            guard let onBoundary = cutter.isOnBoundary(point, epsilon: epsilon),
                  onBoundary,
                  isInsideAnyAdditive(point, solid: solid) == true else {
                continue
            }
            let normal = approximateNormal(at: point, volume: cutter)
            let offset = max(epsilon * 4, 1e-5)
            let plus = classifyWithoutBoundary(point + normal * offset, in: solid)
            let minus = classifyWithoutBoundary(point - normal * offset, in: solid)
            if (plus == .material && minus == .empty) || (plus == .empty && minus == .material) {
                return true
            }
        }
        return false
    }

    private func classifyWithoutBoundary(_ point: DesignVector3, in solid: CADSolid) -> CADMaterialClassification {
        guard let insideAdd = isInsideAnyAdditive(point, solid: solid),
              let insideCut = isInsideAnyCutter(point, solid: solid) else {
            return .unknown
        }
        return insideAdd && !insideCut ? .material : .empty
    }

    private func approximateNormal(at point: DesignVector3, volume: CADVolume) -> DesignVector3 {
        let delta = 1e-5
        let dx = signedDistanceApprox(point + .xAxis * delta, to: volume)
            .flatMap { px in signedDistanceApprox(point - .xAxis * delta, to: volume).map { px - $0 } } ?? 0
        let dy = signedDistanceApprox(point + .yAxis * delta, to: volume)
            .flatMap { py in signedDistanceApprox(point - .yAxis * delta, to: volume).map { py - $0 } } ?? 0
        let dz = signedDistanceApprox(point + .zAxis * delta, to: volume)
            .flatMap { pz in signedDistanceApprox(point - .zAxis * delta, to: volume).map { pz - $0 } } ?? 0
        return DesignVector3(x: dx, y: dy, z: dz).normalized(fallback: volume.direction)
    }
}

enum CADSurfaceBoundaryValidationStatus: String, Codable, Equatable {
    case valid
    case invalid
    case unsupported
}

enum CADSurfaceBoundaryReasonCode: String, Codable, Equatable {
    case validBoundary
    case internalFaceInsideMaterial
    case orphanFaceInsideVoid
    case unsupportedClassification
}

struct CADSurfaceBoundaryValidationResult: Codable, Equatable {
    var faceID: String
    var sampleCount: Int
    var validBoundarySamples: Int
    var invalidInternalSamples: Int
    var invalidVoidSamples: Int
    var result: CADSurfaceBoundaryValidationStatus
    var reasonCode: CADSurfaceBoundaryReasonCode
}

enum CADSurfaceBoundaryValidator {
    static func validate(
        mesh: CADSolidMeshSnapshot,
        solid: CADSolid,
        epsilon: Double = 1e-5
    ) -> [CADSurfaceBoundaryValidationResult] {
        let classifier = CADSolidMaterialClassifier(epsilon: epsilon)
        return mesh.triangles.enumerated().compactMap { index, triangle in
            guard mesh.vertices.indices.contains(triangle.a),
                  mesh.vertices.indices.contains(triangle.b),
                  mesh.vertices.indices.contains(triangle.c) else {
                return nil
            }
            let a = mesh.vertices[triangle.a]
            let b = mesh.vertices[triangle.b]
            let c = mesh.vertices[triangle.c]
            let normal = (b - a).cross(c - a).normalized(fallback: .zAxis)
            let samples = [
                (a + b + c) * (1.0 / 3.0),
                (a + b) * 0.5,
                (b + c) * 0.5,
                (c + a) * 0.5,
            ]
            var validBoundarySamples = 0
            var invalidInternalSamples = 0
            var invalidVoidSamples = 0
            var unsupportedSamples = 0

            for sample in samples {
                let plus = classifier.classify(sample + normal * epsilon, in: solid)
                let minus = classifier.classify(sample - normal * epsilon, in: solid)
                switch (plus, minus) {
                case (.unknown, _), (_, .unknown):
                    unsupportedSamples += 1
                case (.material, .empty), (.empty, .material), (.boundary, _), (_, .boundary):
                    validBoundarySamples += 1
                case (.material, .material):
                    invalidInternalSamples += 1
                case (.empty, .empty):
                    invalidVoidSamples += 1
                }
            }

            let status: CADSurfaceBoundaryValidationStatus
            let reason: CADSurfaceBoundaryReasonCode
            if unsupportedSamples == samples.count {
                status = .unsupported
                reason = .unsupportedClassification
            } else if invalidInternalSamples > validBoundarySamples {
                status = .invalid
                reason = .internalFaceInsideMaterial
            } else if invalidVoidSamples > validBoundarySamples {
                status = .invalid
                reason = .orphanFaceInsideVoid
            } else {
                status = .valid
                reason = .validBoundary
            }

            return CADSurfaceBoundaryValidationResult(
                faceID: "triangle:\(index)",
                sampleCount: samples.count,
                validBoundarySamples: validBoundarySamples,
                invalidInternalSamples: invalidInternalSamples,
                invalidVoidSamples: invalidVoidSamples,
                result: status,
                reasonCode: reason
            )
        }
    }
}

struct CADKernelTolerance: Codable, Equatable {
    var positionEpsilon: Double = 1e-6
    var distanceEpsilon: Double = 1e-5
    var areaEpsilon: Double = 1e-10
    var angleEpsilon: Double = 1e-6
    var mergeEpsilon: Double = 1e-6
    var classificationEpsilon: Double = 1e-5
}

struct CADBoundaryBuildOptions: Codable, Equatable {
    var tolerance: CADKernelTolerance = CADKernelTolerance()
    var planeGridResolution: Int = 24
    var cylinderSegments: Int = 64
    var depthSegments: Int = 8
}

struct CADSurfaceID: Codable, Hashable, Equatable, Identifiable {
    var rawValue: String
    var id: String { rawValue }
}

enum CADAnalyticSurfaceKind: String, Codable, Equatable {
    case plane
    case cylinder
    case unsupported
}

enum CADSurfaceOwner: Codable, Equatable {
    case additiveVolume(UUID)
    case cutterVolume(UUID)

    var volumeID: UUID {
        switch self {
        case let .additiveVolume(id), let .cutterVolume(id):
            return id
        }
    }
}

enum CADSurfaceRole: String, Codable, Equatable {
    case outerAdditiveFace
    case cutterWall
    case cutterCap
    case additiveCylinderWall
    case additiveCap
}

enum CADSurfaceSeamPolicy: String, Codable, Equatable {
    case none
    case splitAtZeroTheta
}

struct CADTrimCurve2D: Codable, Identifiable, Equatable {
    var id: UUID
    var points: [SketchPoint2D]
}

enum CADCandidateSurfaceKind: String, Codable, Equatable {
    case planar
    case cylindrical
}

struct CADSurfaceDomain2D: Codable, Equatable {
    var surfaceID: CADSurfaceID? = nil
    var minU: Double
    var maxU: Double
    var minV: Double
    var maxV: Double
    var outerDomainLoop: [SketchPoint2D] = []
    var trimCurves: [CADTrimCurve2D] = []
    var holes: [CADTrimLoop] = []
    var seamPolicy: CADSurfaceSeamPolicy = .none
    var tolerance: Double = 1e-6
}

struct CADAnalyticSurface: Codable, Identifiable, Equatable {
    var id: CADSurfaceID
    var owner: CADSurfaceOwner
    var role: CADSurfaceRole
    var kind: CADAnalyticSurfaceKind
    var origin: DesignVector3
    var uAxis: DesignVector3
    var vAxis: DesignVector3
    var normal: DesignVector3
    var axis: DesignVector3
    var radius: Double?
    var domain: CADSurfaceDomain2D
    var bounds: CADSolidBounds?
    var materialSideHint: CADMaterialClassification
    var sourceFeatureID: UUID?
}

enum CADIntersectionCurveKind: String, Codable, Equatable {
    case lineSegment
    case circleArc
    case ellipseLikeCurve
    case polyline
    case unsupported
}

struct CADIntersectionCurve: Codable, Identifiable, Equatable {
    var id: UUID
    var surfaceA: CADSurfaceID
    var surfaceB: CADSurfaceID
    var kind: CADIntersectionCurveKind
    var points3D: [DesignVector3]
    var pointsOnSurfaceA2D: [SketchPoint2D]
    var pointsOnSurfaceB2D: [SketchPoint2D]
    var tolerance: Double
    var sourceVolumeIDs: [UUID]
}

struct CADIntersectionOptions: Codable, Equatable {
    var tolerance: CADKernelTolerance = CADKernelTolerance()
    var cylinderSegments: Int = 64
    var maxSurfacePairs: Int = 4096
}

struct CADSurfaceIntersectionDiagnostics: Codable, Equatable {
    var graphBuildCount: Int
    var surfacePairTestCount: Int
    var bboxRejectedPairCount: Int
    var intersectionCurveCount: Int
    var unsupportedIntersectionCount: Int
    var seamCrossingCurveCount: Int
    var seamSplitCount: Int
    var seamWeldedVertexCount: Int
}

struct CADSurfaceIntersectionGraph: Codable, Equatable {
    var surfaces: [CADAnalyticSurface]
    var intersectionCurves: [CADIntersectionCurve]
    var adjacency: [String: [UUID]]
    var diagnostics: CADSurfaceIntersectionDiagnostics
}

struct CADCandidateSurface: Codable, Identifiable, Equatable {
    var id: String
    var volumeID: UUID
    var sourceRole: CADVolumeOperationRole
    var kind: CADCandidateSurfaceKind
    var domain: CADSurfaceDomain2D
}

struct CADSurfaceFragment: Codable, Equatable {
    var surfaceID: String
    var samplePoint: DesignVector3
    var normal: DesignVector3
    var kept: Bool
}

struct CADBoundaryFragment: Codable, Equatable {
    var surfaceID: String
    var triangle: CADSolidTriangle
}

struct CADTrimLoop: Codable, Equatable {
    var points: [SketchPoint2D]
}

enum CADTrimLoopResolutionStatus: String, Codable, Equatable {
    case valid
    case invalid
    case unsupported
}

struct CADTrimLoopDiagnostics: Codable, Equatable {
    var trimLoopCount: Int
    var rejectedCurveCount: Int
    var openChainCount: Int
    var tinyLoopDiscardCount: Int
    var selfIntersectingLoopCount: Int
}

struct CADTrimLoopResult: Codable, Equatable {
    var surfaceID: CADSurfaceID?
    var outerLoops: [CADTrimLoop]
    var innerLoops: [CADTrimLoop]
    var rejectedCurves: [CADTrimCurve2D]
    var openChains: [CADTrimCurve2D]
    var diagnostics: CADTrimLoopDiagnostics
    var status: CADTrimLoopResolutionStatus
}

struct CADTrimLoopAggregateResult: Codable, Equatable {
    var surfaceResults: [CADTrimLoopResult]
    var diagnostics: CADTrimLoopDiagnostics
}

struct CADBoundaryBuildDiagnostics: Codable, Equatable {
    var candidateSurfaceCount: Int
    var keptFragmentCount: Int
    var rejectedFragmentCount: Int
    var graphBuildCount: Int
    var surfacePairTestCount: Int
    var intersectionCurveCount: Int
    var trimLoopCount: Int
    var seamCrossingCurveCount: Int
    var seamSplitCount: Int
    var seamWeldedVertexCount: Int
    var removedDuplicateVertices: Int
    var removedDuplicateTriangles: Int
    var removedZeroAreaTriangles: Int
    var removedSliverTriangles: Int
    var removedInvalidBoundaryTriangles: Int
    var finalVertexCount: Int
    var finalTriangleCount: Int
}

struct CADSurfaceIntersectionGraphBuilder {
    func analyticSurfaces(
        solid: CADSolid,
        options: CADIntersectionOptions = CADIntersectionOptions()
    ) -> [CADAnalyticSurface] {
        var surfaces: [CADAnalyticSurface] = []
        for volume in solid.additiveVolumes {
            surfaces.append(contentsOf: analyticSurfaces(for: volume, owner: .additiveVolume(volume.id), options: options))
        }
        for volume in solid.cutterVolumes {
            surfaces.append(contentsOf: analyticSurfaces(for: volume, owner: .cutterVolume(volume.id), options: options))
        }
        return surfaces
    }

    func buildGraph(
        solid: CADSolid,
        surfaces: [CADAnalyticSurface],
        classifier: CADSolidMaterialClassifier,
        options: CADIntersectionOptions
    ) -> CADSurfaceIntersectionGraph {
        _ = solid
        _ = classifier
        var curves: [CADIntersectionCurve] = []
        var adjacency: [String: [UUID]] = [:]
        var pairTests = 0
        var bboxRejected = 0
        var unsupported = 0
        let pairLimit = max(options.maxSurfacePairs, 0)

        for leftIndex in surfaces.indices {
            for rightIndex in surfaces.indices where rightIndex > leftIndex {
                guard pairTests < pairLimit else { break }
                pairTests += 1
                let a = surfaces[leftIndex]
                let b = surfaces[rightIndex]
                if let aBounds = a.bounds,
                   let bBounds = b.bounds,
                   !aBounds.intersects(bBounds, tolerance: options.tolerance.distanceEpsilon) {
                    bboxRejected += 1
                    continue
                }
                let intersections = intersectionCurves(surfaceA: a, surfaceB: b, options: options)
                if intersections.isEmpty, a.kind == .cylinder, b.kind == .cylinder {
                    unsupported += 1
                }
                for curve in intersections where curve.points3D.count >= 2 {
                    curves.append(curve)
                    adjacency[curve.surfaceA.rawValue, default: []].append(curve.id)
                    adjacency[curve.surfaceB.rawValue, default: []].append(curve.id)
                }
            }
        }

        let seamCrossings = curves.filter { curve in
            zip(curve.pointsOnSurfaceA2D, curve.pointsOnSurfaceA2D.dropFirst()).contains { abs($0.u - $1.u) > Double.pi }
                || zip(curve.pointsOnSurfaceB2D, curve.pointsOnSurfaceB2D.dropFirst()).contains { abs($0.u - $1.u) > Double.pi }
        }.count

        return CADSurfaceIntersectionGraph(
            surfaces: surfaces,
            intersectionCurves: curves,
            adjacency: adjacency,
            diagnostics: CADSurfaceIntersectionDiagnostics(
                graphBuildCount: 1,
                surfacePairTestCount: pairTests,
                bboxRejectedPairCount: bboxRejected,
                intersectionCurveCount: curves.count,
                unsupportedIntersectionCount: unsupported,
                seamCrossingCurveCount: seamCrossings,
                seamSplitCount: seamCrossings,
                seamWeldedVertexCount: 0
            )
        )
    }

    private func analyticSurfaces(
        for volume: CADVolume,
        owner: CADSurfaceOwner,
        options: CADIntersectionOptions
    ) -> [CADAnalyticSurface] {
        switch volume.kind {
        case .boxExtrusion, .rectangularPrism:
            return prismaticSurfaces(for: volume, owner: owner)
        case .cylinder:
            return cylindricalSurfaces(for: volume, owner: owner, options: options)
        case .unsupported:
            return []
        }
    }

    private func prismaticSurfaces(for volume: CADVolume, owner: CADSurfaceOwner) -> [CADAnalyticSurface] {
        guard volume.profilePoints.count >= 3 else { return [] }
        let axis = volume.direction.normalized(fallback: .zAxis)
        let front = volume.profilePoints.map { volume.origin + volume.uAxis * $0.u + volume.vAxis * $0.v }
        let back = front.map { $0 + axis * volume.depthMeters }
        let role: CADSurfaceRole = volume.operationRole == .additive ? .outerAdditiveFace : .cutterCap
        var surfaces: [CADAnalyticSurface] = []
        surfaces.append(
            planeSurface(
                id: "\(volume.id.uuidString):front",
                owner: owner,
                role: role,
                points: front,
                origin: volume.origin,
                uAxis: volume.uAxis.normalized(fallback: .xAxis),
                vAxis: volume.vAxis.normalized(fallback: .yAxis),
                normal: axis * -1
            )
        )
        surfaces.append(
            planeSurface(
                id: "\(volume.id.uuidString):back",
                owner: owner,
                role: role,
                points: back,
                origin: volume.origin + axis * volume.depthMeters,
                uAxis: volume.uAxis.normalized(fallback: .xAxis),
                vAxis: volume.vAxis.normalized(fallback: .yAxis),
                normal: axis
            )
        )
        for index in volume.profilePoints.indices {
            let next = (index + 1) % volume.profilePoints.count
            let a = front[index]
            let b = front[next]
            let c = back[next]
            let d = back[index]
            let edge = (b - a).normalized(fallback: volume.uAxis)
            let normal = edge.cross(axis).normalized(fallback: .zAxis)
            surfaces.append(
                planeSurface(
                    id: "\(volume.id.uuidString):side:\(index)",
                    owner: owner,
                    role: volume.operationRole == .additive ? .outerAdditiveFace : .cutterWall,
                    points: [a, b, c, d],
                    origin: a,
                    uAxis: edge,
                    vAxis: axis,
                    normal: normal
                )
            )
        }
        return surfaces
    }

    private func cylindricalSurfaces(
        for volume: CADVolume,
        owner: CADSurfaceOwner,
        options: CADIntersectionOptions
    ) -> [CADAnalyticSurface] {
        guard let metrics = circleMetrics(for: volume) else { return [] }
        let axis = volume.direction.normalized(fallback: .zAxis)
        let center = volume.origin + volume.uAxis * metrics.center.u + volume.vAxis * metrics.center.v
        let uAxis = volume.uAxis.normalized(fallback: .xAxis)
        let vAxis = volume.vAxis.normalized(fallback: .yAxis)
        let front = circlePoints(center: center, uAxis: uAxis, vAxis: vAxis, radius: metrics.radius, segments: options.cylinderSegments)
        let backCenter = center + axis * volume.depthMeters
        let back = front.map { $0 + axis * volume.depthMeters }
        let wallBounds = CADSolidBounds(points: front + back)
        let wallID = CADSurfaceID(rawValue: "\(volume.id.uuidString):cylinder:wall")
        var surfaces: [CADAnalyticSurface] = [
            CADAnalyticSurface(
                id: wallID,
                owner: owner,
                role: volume.operationRole == .additive ? .additiveCylinderWall : .cutterWall,
                kind: .cylinder,
                origin: center,
                uAxis: uAxis,
                vAxis: vAxis,
                normal: uAxis,
                axis: axis,
                radius: metrics.radius,
                domain: CADSurfaceDomain2D(
                    surfaceID: wallID,
                    minU: 0,
                    maxU: 2.0 * Double.pi,
                    minV: 0,
                    maxV: volume.depthMeters,
                    outerDomainLoop: [
                        SketchPoint2D(u: 0, v: 0),
                        SketchPoint2D(u: 2.0 * Double.pi, v: 0),
                        SketchPoint2D(u: 2.0 * Double.pi, v: volume.depthMeters),
                        SketchPoint2D(u: 0, v: volume.depthMeters)
                    ],
                    seamPolicy: .splitAtZeroTheta,
                    tolerance: options.tolerance.mergeEpsilon
                ),
                bounds: wallBounds,
                materialSideHint: volume.operationRole == .additive ? .material : .empty,
                sourceFeatureID: nil
            )
        ]
        surfaces.append(
            planeSurface(
                id: "\(volume.id.uuidString):cylinder:front",
                owner: owner,
                role: volume.operationRole == .additive ? .additiveCap : .cutterCap,
                points: front,
                origin: center,
                uAxis: uAxis,
                vAxis: vAxis,
                normal: axis * -1
            )
        )
        surfaces.append(
            planeSurface(
                id: "\(volume.id.uuidString):cylinder:back",
                owner: owner,
                role: volume.operationRole == .additive ? .additiveCap : .cutterCap,
                points: back,
                origin: backCenter,
                uAxis: uAxis,
                vAxis: vAxis,
                normal: axis
            )
        )
        return surfaces
    }

    private func planeSurface(
        id: String,
        owner: CADSurfaceOwner,
        role: CADSurfaceRole,
        points: [DesignVector3],
        origin: DesignVector3,
        uAxis: DesignVector3,
        vAxis: DesignVector3,
        normal: DesignVector3
    ) -> CADAnalyticSurface {
        let surfaceID = CADSurfaceID(rawValue: id)
        let u = uAxis.normalized(fallback: .xAxis)
        let v = vAxis.normalized(fallback: .yAxis)
        let projected = points.map { point -> SketchPoint2D in
            let offset = point - origin
            return SketchPoint2D(u: offset.dot(u), v: offset.dot(v))
        }
        let minU = projected.map(\.u).min() ?? 0
        let maxU = projected.map(\.u).max() ?? 0
        let minV = projected.map(\.v).min() ?? 0
        let maxV = projected.map(\.v).max() ?? 0
        return CADAnalyticSurface(
            id: surfaceID,
            owner: owner,
            role: role,
            kind: .plane,
            origin: origin,
            uAxis: u,
            vAxis: v,
            normal: normal.normalized(fallback: u.cross(v).normalized(fallback: .zAxis)),
            axis: normal.normalized(fallback: .zAxis),
            radius: nil,
            domain: CADSurfaceDomain2D(
                surfaceID: surfaceID,
                minU: minU,
                maxU: maxU,
                minV: minV,
                maxV: maxV,
                outerDomainLoop: projected
            ),
            bounds: CADSolidBounds(points: points),
            materialSideHint: {
                switch owner {
                case .additiveVolume:
                    return .material
                case .cutterVolume:
                    return .empty
                }
            }(),
            sourceFeatureID: nil
        )
    }

    private func intersectionCurves(
        surfaceA: CADAnalyticSurface,
        surfaceB: CADAnalyticSurface,
        options: CADIntersectionOptions
    ) -> [CADIntersectionCurve] {
        switch (surfaceA.kind, surfaceB.kind) {
        case (.plane, .plane):
            return planePlaneIntersection(surfaceA, surfaceB, options: options).map { [$0] } ?? []
        case (.plane, .cylinder):
            return planeCylinderIntersections(plane: surfaceA, cylinder: surfaceB, options: options)
        case (.cylinder, .plane):
            return planeCylinderIntersections(plane: surfaceB, cylinder: surfaceA, options: options).map {
                CADIntersectionCurve(
                    id: $0.id,
                    surfaceA: surfaceA.id,
                    surfaceB: surfaceB.id,
                    kind: $0.kind,
                    points3D: $0.points3D,
                    pointsOnSurfaceA2D: $0.pointsOnSurfaceB2D,
                    pointsOnSurfaceB2D: $0.pointsOnSurfaceA2D,
                    tolerance: $0.tolerance,
                    sourceVolumeIDs: $0.sourceVolumeIDs
                )
            }
        case (.cylinder, .cylinder):
            return []
        default:
            return []
        }
    }

    private func planePlaneIntersection(
        _ a: CADAnalyticSurface,
        _ b: CADAnalyticSurface,
        options: CADIntersectionOptions
    ) -> CADIntersectionCurve? {
        let direction = a.normal.cross(b.normal)
        let denom = direction.dot(direction)
        guard denom > options.tolerance.angleEpsilon else { return nil }
        let da = a.normal.dot(a.origin)
        let db = b.normal.dot(b.origin)
        let point = ((b.normal.cross(direction) * da) + (direction.cross(a.normal) * db)) * (1.0 / denom)
        let lineDirection = direction.normalized(fallback: .xAxis)
        guard let segment = clippedLineSegment(point: point, direction: lineDirection, surfaces: [a, b]) else {
            return nil
        }
        let p0 = segment.0
        let p1 = segment.1
        return makeCurve(
            surfaceA: a,
            surfaceB: b,
            kind: .lineSegment,
            points: [p0, p1],
            tolerance: options.tolerance.mergeEpsilon
        )
    }

    private func planeCylinderIntersections(
        plane: CADAnalyticSurface,
        cylinder: CADAnalyticSurface,
        options: CADIntersectionOptions
    ) -> [CADIntersectionCurve] {
        guard let radius = cylinder.radius else { return [] }
        let axis = cylinder.axis.normalized(fallback: .zAxis)
        let denom = plane.normal.dot(axis)
        let depth = cylinder.domain.maxV - cylinder.domain.minV
        let segments = max(options.cylinderSegments, 16)

            if abs(denom) > 0.98 {
            let axial = (plane.origin - cylinder.origin).dot(axis)
            guard axial >= cylinder.domain.minV - options.tolerance.distanceEpsilon,
                  axial <= cylinder.domain.maxV + options.tolerance.distanceEpsilon else {
                return []
            }
            let center = cylinder.origin + axis * axial
            let points = circlePoints(
                center: center,
                uAxis: cylinder.uAxis,
                vAxis: cylinder.vAxis,
                radius: radius,
                segments: segments
            ).filter {
                domainContains(project($0, onto: plane), domain: plane.domain, tolerance: options.tolerance.distanceEpsilon)
                    && domainContains(project($0, onto: cylinder), domain: cylinder.domain, tolerance: options.tolerance.distanceEpsilon)
            }
            guard points.count >= 2 else { return [] }
            return [makeCurve(surfaceA: plane, surfaceB: cylinder, kind: .circleArc, points: points, tolerance: options.tolerance.mergeEpsilon)]
        }

        if abs(denom) < 0.05 {
            let a = plane.normal.dot(cylinder.uAxis)
            let b = plane.normal.dot(cylinder.vAxis)
            let c = plane.normal.dot(cylinder.origin - plane.origin)
            let length = sqrt(a * a + b * b)
            guard length > options.tolerance.angleEpsilon,
                  abs(c) <= radius * length + options.tolerance.distanceEpsilon else {
                return []
            }
            let baseAngle = atan2(b, a)
            let delta = acos(max(-1, min(1, -c / (radius * length))))
            return [baseAngle + delta, baseAngle - delta].compactMap { theta in
                let radial = cylinder.uAxis * cos(theta) * radius + cylinder.vAxis * sin(theta) * radius
                let rawPoints = [
                    cylinder.origin + radial,
                    cylinder.origin + radial + axis * depth
                ]
                let clipped = rawPoints.filter {
                    domainContains(project($0, onto: plane), domain: plane.domain, tolerance: options.tolerance.distanceEpsilon)
                        && domainContains(project($0, onto: cylinder), domain: cylinder.domain, tolerance: options.tolerance.distanceEpsilon)
                }
                guard clipped.count >= 2 else { return nil }
                return makeCurve(
                    surfaceA: plane,
                    surfaceB: cylinder,
                    kind: .lineSegment,
                    points: clipped,
                    tolerance: options.tolerance.mergeEpsilon
                )
            }
        }

        var points: [DesignVector3] = []
        for segment in 0..<segments {
            let theta = Double(segment) / Double(segments) * 2.0 * Double.pi
            let radial = cylinder.uAxis * cos(theta) * radius + cylinder.vAxis * sin(theta) * radius
            let base = cylinder.origin + radial
            let axial = -plane.normal.dot(base - plane.origin) / denom
            if axial >= cylinder.domain.minV - options.tolerance.distanceEpsilon,
               axial <= cylinder.domain.maxV + options.tolerance.distanceEpsilon {
                points.append(base + axis * axial)
            }
        }
        guard points.count >= 2 else { return [] }
        return [makeCurve(surfaceA: plane, surfaceB: cylinder, kind: .polyline, points: points, tolerance: options.tolerance.mergeEpsilon)]
    }

    private func clippedLineSegment(
        point: DesignVector3,
        direction: DesignVector3,
        surfaces: [CADAnalyticSurface]
    ) -> (DesignVector3, DesignVector3)? {
        var lower = -Double.infinity
        var upper = Double.infinity
        for surface in surfaces {
            let corners = [
                SketchPoint2D(u: surface.domain.minU, v: surface.domain.minV),
                SketchPoint2D(u: surface.domain.maxU, v: surface.domain.minV),
                SketchPoint2D(u: surface.domain.maxU, v: surface.domain.maxV),
                SketchPoint2D(u: surface.domain.minU, v: surface.domain.maxV)
            ].map { domainPoint in
                surface.origin + surface.uAxis * domainPoint.u + surface.vAxis * domainPoint.v
            }
            let projections = corners.map { ($0 - point).dot(direction) }
            lower = max(lower, projections.min() ?? lower)
            upper = min(upper, projections.max() ?? upper)
        }
        guard lower.isFinite, upper.isFinite, upper - lower > 1e-8 else { return nil }
        return (point + direction * lower, point + direction * upper)
    }

    private func domainContains(
        _ point: SketchPoint2D,
        domain: CADSurfaceDomain2D,
        tolerance: Double
    ) -> Bool {
        point.u >= domain.minU - tolerance
            && point.u <= domain.maxU + tolerance
            && point.v >= domain.minV - tolerance
            && point.v <= domain.maxV + tolerance
    }

    private func makeCurve(
        surfaceA: CADAnalyticSurface,
        surfaceB: CADAnalyticSurface,
        kind: CADIntersectionCurveKind,
        points: [DesignVector3],
        tolerance: Double
    ) -> CADIntersectionCurve {
        CADIntersectionCurve(
            id: UUID(),
            surfaceA: surfaceA.id,
            surfaceB: surfaceB.id,
            kind: kind,
            points3D: points,
            pointsOnSurfaceA2D: points.map { project($0, onto: surfaceA) },
            pointsOnSurfaceB2D: points.map { project($0, onto: surfaceB) },
            tolerance: tolerance,
            sourceVolumeIDs: Array(Set([surfaceA.owner.volumeID, surfaceB.owner.volumeID]))
        )
    }

    private func project(_ point: DesignVector3, onto surface: CADAnalyticSurface) -> SketchPoint2D {
        switch surface.kind {
        case .plane:
            let offset = point - surface.origin
            return SketchPoint2D(u: offset.dot(surface.uAxis), v: offset.dot(surface.vAxis))
        case .cylinder:
            let offset = point - surface.origin
            let axial = offset.dot(surface.axis.normalized(fallback: .zAxis))
            let radial = offset - surface.axis.normalized(fallback: .zAxis) * axial
            var theta = atan2(radial.dot(surface.vAxis), radial.dot(surface.uAxis))
            if theta < 0 { theta += 2.0 * Double.pi }
            return SketchPoint2D(u: theta, v: axial)
        case .unsupported:
            return .zero
        }
    }

    private func circlePoints(
        center: DesignVector3,
        uAxis: DesignVector3,
        vAxis: DesignVector3,
        radius: Double,
        segments: Int
    ) -> [DesignVector3] {
        (0..<max(segments, 8)).map { index in
            let theta = Double(index) / Double(max(segments, 8)) * 2.0 * Double.pi
            return center + uAxis * cos(theta) * radius + vAxis * sin(theta) * radius
        }
    }

    private func circleMetrics(for volume: CADVolume) -> (center: SketchPoint2D, radius: Double)? {
        guard volume.profilePoints.count >= 8 else { return nil }
        let center = volume.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
            SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
        }
        let count = Double(volume.profilePoints.count)
        let averagedCenter = SketchPoint2D(u: center.u / count, v: center.v / count)
        let radius = volume.profilePoints.reduce(0.0) { total, point in
            total + point.distance(to: averagedCenter)
        } / count
        guard radius.isFinite, radius > 1e-9 else { return nil }
        return (averagedCenter, radius)
    }
}

struct CADTrimLoopResolver {
    func resolveTrimLoops(
        domain: CADSurfaceDomain2D,
        classifier: CADSolidMaterialClassifier
    ) -> CADTrimLoopResult {
        _ = classifier
        let tolerance = max(domain.tolerance, 1e-9)
        let outer = normalizeLoop(domain.outerDomainLoop, tolerance: tolerance)
        var innerLoops: [CADTrimLoop] = []
        var rejected: [CADTrimCurve2D] = []
        var openChains: [CADTrimCurve2D] = []
        var tiny = 0

        for curve in closedCurves(from: domain.trimCurves, tolerance: tolerance) {
            let points = normalizeLoop(curve.points, tolerance: tolerance)
            guard points.count >= 3 else {
                rejected.append(curve)
                continue
            }
            guard points.first?.distance(to: points.last ?? .zero) ?? .infinity <= tolerance else {
                openChains.append(curve)
                continue
            }
            guard abs(signedArea(points)) > tolerance * tolerance else {
                tiny += 1
                continue
            }
            innerLoops.append(CADTrimLoop(points: normalizedWinding(points, clockwise: true)))
        }

        let outerLoops = outer.count >= 3
            ? [CADTrimLoop(points: normalizedWinding(outer, clockwise: false))]
            : []
        let status: CADTrimLoopResolutionStatus = outerLoops.isEmpty || !openChains.isEmpty ? .invalid : .valid
        return CADTrimLoopResult(
            surfaceID: domain.surfaceID,
            outerLoops: outerLoops,
            innerLoops: innerLoops,
            rejectedCurves: rejected,
            openChains: openChains,
            diagnostics: CADTrimLoopDiagnostics(
                trimLoopCount: outerLoops.count + innerLoops.count,
                rejectedCurveCount: rejected.count,
                openChainCount: openChains.count,
                tinyLoopDiscardCount: tiny,
                selfIntersectingLoopCount: 0
            ),
            status: status
        )
    }

    private func closedCurves(
        from curves: [CADTrimCurve2D],
        tolerance: Double
    ) -> [CADTrimCurve2D] {
        var remaining = curves.filter { $0.points.count >= 2 }
        var closed: [CADTrimCurve2D] = []

        while let first = remaining.first {
            remaining.removeFirst()
            var chain = first.points
            var changed = true
            while changed {
                changed = false
                guard let head = chain.first, let tail = chain.last else { break }
                if head.distance(to: tail) <= tolerance {
                    chain[chain.count - 1] = head
                    break
                }
                if let index = remaining.firstIndex(where: { curve in
                    guard let firstPoint = curve.points.first,
                          let lastPoint = curve.points.last else { return false }
                    return firstPoint.distance(to: tail) <= tolerance
                        || lastPoint.distance(to: tail) <= tolerance
                        || firstPoint.distance(to: head) <= tolerance
                        || lastPoint.distance(to: head) <= tolerance
                }) {
                    var next = remaining.remove(at: index).points
                    if next.first?.distance(to: tail) ?? .infinity <= tolerance {
                        next.removeFirst()
                        chain.append(contentsOf: next)
                    } else if next.last?.distance(to: tail) ?? .infinity <= tolerance {
                        next.removeLast()
                        chain.append(contentsOf: next.reversed())
                    } else if next.last?.distance(to: head) ?? .infinity <= tolerance {
                        next.removeLast()
                        chain.insert(contentsOf: next, at: 0)
                    } else {
                        next.removeFirst()
                        chain.insert(contentsOf: next.reversed(), at: 0)
                    }
                    changed = true
                }
            }

            if let head = chain.first,
               let tail = chain.last,
               head.distance(to: tail) <= tolerance {
                chain[chain.count - 1] = head
                closed.append(CADTrimCurve2D(id: first.id, points: chain))
            } else if chain.count >= 8,
                      let head = chain.first,
                      let tail = chain.last,
                      head.distance(to: tail) <= averageSegmentLength(chain) * 1.5 {
                chain.append(head)
                closed.append(CADTrimCurve2D(id: first.id, points: chain))
            } else {
                closed.append(CADTrimCurve2D(id: first.id, points: chain))
            }
        }
        return closed
    }

    private func averageSegmentLength(_ points: [SketchPoint2D]) -> Double {
        guard points.count >= 2 else { return 0 }
        let total = zip(points, points.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
        return total / Double(points.count - 1)
    }

    func resolveTrimLoops(
        graph: CADSurfaceIntersectionGraph,
        classifier: CADSolidMaterialClassifier
    ) -> CADTrimLoopAggregateResult {
        let curveByID = Dictionary(uniqueKeysWithValues: graph.intersectionCurves.map { ($0.id, $0) })
        var results: [CADTrimLoopResult] = []
        var aggregate = CADTrimLoopDiagnostics(
            trimLoopCount: 0,
            rejectedCurveCount: 0,
            openChainCount: 0,
            tinyLoopDiscardCount: 0,
            selfIntersectingLoopCount: 0
        )
        for surface in graph.surfaces {
            let curveIDs = graph.adjacency[surface.id.rawValue] ?? []
            var domain = surface.domain
            domain.trimCurves = curveIDs.compactMap { id in
                guard let curve = curveByID[id] else { return nil }
                let points = curve.surfaceA == surface.id ? curve.pointsOnSurfaceA2D : curve.pointsOnSurfaceB2D
                return CADTrimCurve2D(id: id, points: points)
            }
            let result = resolveTrimLoops(domain: domain, classifier: classifier)
            aggregate.trimLoopCount += result.diagnostics.trimLoopCount
            aggregate.rejectedCurveCount += result.diagnostics.rejectedCurveCount
            aggregate.openChainCount += result.diagnostics.openChainCount
            aggregate.tinyLoopDiscardCount += result.diagnostics.tinyLoopDiscardCount
            aggregate.selfIntersectingLoopCount += result.diagnostics.selfIntersectingLoopCount
            results.append(result)
        }
        return CADTrimLoopAggregateResult(surfaceResults: results, diagnostics: aggregate)
    }

    private func normalizeLoop(_ points: [SketchPoint2D], tolerance: Double) -> [SketchPoint2D] {
        var normalized: [SketchPoint2D] = []
        for point in points where normalized.last?.distance(to: point) ?? .infinity > tolerance {
            normalized.append(point)
        }
        if normalized.count > 2,
           let first = normalized.first,
           let last = normalized.last,
           first.distance(to: last) <= tolerance {
            normalized[normalized.count - 1] = first
        }
        return normalized
    }

    private func normalizedWinding(_ points: [SketchPoint2D], clockwise: Bool) -> [SketchPoint2D] {
        let isClockwise = signedArea(points) < 0
        return isClockwise == clockwise ? points : Array(points.reversed())
    }

    private func signedArea(_ points: [SketchPoint2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            area += points[index].u * points[next].v - points[next].u * points[index].v
        }
        return area * 0.5
    }
}

struct CADBoundarySurfaceBuilder {
    func buildBoundaryMesh(
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions
    ) -> CADMeshBuildResult {
        let intersectionOptions = CADIntersectionOptions(
            tolerance: options.tolerance,
            cylinderSegments: options.cylinderSegments
        )
        let graphBuilder = CADSurfaceIntersectionGraphBuilder()
        let analyticSurfaces = graphBuilder.analyticSurfaces(solid: solid, options: intersectionOptions)
        let intersectionGraph = graphBuilder.buildGraph(
            solid: solid,
            surfaces: analyticSurfaces,
            classifier: classifier,
            options: intersectionOptions
        )
        let trimLoops = CADTrimLoopResolver().resolveTrimLoops(
            graph: intersectionGraph,
            classifier: classifier
        )
        let reconstruction = buildClosedShellReconstruction(
            solid: solid,
            options: options,
            intersectionGraph: intersectionGraph
        )
        let vertices = reconstruction.vertices
        let triangles = reconstruction.triangles
        let candidateSurfaceCount = reconstruction.candidateSurfaceCount
        let keptFragmentCount = reconstruction.keptFragmentCount
        let rejectedFragmentCount = reconstruction.rejectedFragmentCount

        let cleanup = cleanupMesh(
            vertices: vertices,
            triangles: triangles,
            solid: solid,
            classifier: classifier,
            options: options
        )
        let mesh = CADSolidMeshSnapshot(vertices: cleanup.vertices, triangles: cleanup.triangles)
        let diagnostics = CADSolidMeshValidator.diagnose(mesh, epsilon: options.tolerance.mergeEpsilon)
        let validationResults = CADSurfaceBoundaryValidator.validate(
            mesh: mesh,
            solid: solid,
            epsilon: options.tolerance.classificationEpsilon
        )
        let invalidBoundaryCount = validationResults.filter { $0.result == .invalid }.count
        let validationResult: CADOperationValidationResult = diagnostics.isClosedManifold
            ? .valid(debugDetails: ["source=CADBoundarySurfaceBuilder"])
            : .invalid(
                .topologyValidationFailed,
                message: "Boundary builder validation failed",
                debugDetails: [
                    "invalidBoundaryTriangles=\(invalidBoundaryCount)",
                    "nonManifoldEdges=\(diagnostics.nonManifoldEdgeCount)",
                    "boundaryEdges=\(diagnostics.boundaryEdgeCount)",
                    "duplicateFaces=\(diagnostics.duplicateFaceCount)"
                ]
            )
        let normals = cleanup.triangles.map { triangle -> DesignVector3 in
            guard cleanup.vertices.indices.contains(triangle.a),
                  cleanup.vertices.indices.contains(triangle.b),
                  cleanup.vertices.indices.contains(triangle.c) else {
                return .zAxis
            }
            let a = cleanup.vertices[triangle.a]
            let b = cleanup.vertices[triangle.b]
            let c = cleanup.vertices[triangle.c]
            return (b - a).cross(c - a).normalized(fallback: .zAxis)
        }
        let indices = cleanup.triangles.flatMap { [$0.a, $0.b, $0.c] }

        return CADMeshBuildResult(
            mesh: mesh,
            normals: normals,
            indices: indices,
            materials: Array(repeating: "body", count: cleanup.triangles.count),
            diagnostics: diagnostics,
            boundaryDiagnostics: CADBoundaryBuildDiagnostics(
                candidateSurfaceCount: candidateSurfaceCount,
                keptFragmentCount: keptFragmentCount,
                rejectedFragmentCount: rejectedFragmentCount,
                graphBuildCount: intersectionGraph.diagnostics.graphBuildCount,
                surfacePairTestCount: intersectionGraph.diagnostics.surfacePairTestCount,
                intersectionCurveCount: intersectionGraph.diagnostics.intersectionCurveCount,
                trimLoopCount: trimLoops.diagnostics.trimLoopCount,
                seamCrossingCurveCount: intersectionGraph.diagnostics.seamCrossingCurveCount,
                seamSplitCount: intersectionGraph.diagnostics.seamSplitCount,
                seamWeldedVertexCount: intersectionGraph.diagnostics.seamWeldedVertexCount,
                removedDuplicateVertices: cleanup.removedDuplicateVertices,
                removedDuplicateTriangles: cleanup.removedDuplicateTriangles,
                removedZeroAreaTriangles: cleanup.removedZeroAreaTriangles,
                removedSliverTriangles: cleanup.removedSliverTriangles,
                removedInvalidBoundaryTriangles: cleanup.removedInvalidBoundaryTriangles,
                finalVertexCount: cleanup.vertices.count,
                finalTriangleCount: cleanup.triangles.count
            ),
            validationResults: validationResults,
            validationResult: validationResult
        )
    }

    private struct ClosedShellReconstruction {
        var vertices: [DesignVector3]
        var triangles: [CADSolidTriangle]
        var candidateSurfaceCount: Int
        var keptFragmentCount: Int
        var rejectedFragmentCount: Int
    }

    private struct Segment2D {
        var a: SketchPoint2D
        var b: SketchPoint2D
    }

    private func buildClosedShellReconstruction(
        solid: CADSolid,
        options: CADBoundaryBuildOptions,
        intersectionGraph: CADSurfaceIntersectionGraph
    ) -> ClosedShellReconstruction {
        guard intersectionGraph.diagnostics.unsupportedIntersectionCount == 0,
              solid.additiveVolumes.count == 1,
              let base = solid.additiveVolumes.first,
              base.kind == .boxExtrusion || base.kind == .rectangularPrism,
              base.profilePoints.count >= 3 else {
            return ClosedShellReconstruction(vertices: [], triangles: [], candidateSurfaceCount: 0, keptFragmentCount: 0, rejectedFragmentCount: 0)
        }

        let axis = base.direction.normalized(fallback: .zAxis)
        let baseDepth = base.depthMeters
        let tolerance = max(options.tolerance.mergeEpsilon, 1e-7)
        var cutterProfiles: [[SketchPoint2D]] = []
        var rejectedCutters = 0

        for cutter in solid.cutterVolumes {
            guard cutter.kind == .rectangularPrism || cutter.kind == .cylinder,
                  abs(cutter.direction.normalized(fallback: axis).dot(axis)) > 1.0 - options.tolerance.angleEpsilon,
                  cutter.depthMeters >= baseDepth - options.tolerance.distanceEpsilon else {
                rejectedCutters += 1
                continue
            }
            let worldPoints = cutter.profilePoints.map {
                cutter.origin + cutter.uAxis * $0.u + cutter.vAxis * $0.v
            }
            let profile = normalizeLoop(
                worldPoints.map { projectToBase2D($0, base: base) },
                tolerance: tolerance,
                close: false
            )
            guard profile.count >= 3 else {
                rejectedCutters += 1
                continue
            }
            cutterProfiles.append(ensureWinding(profile, clockwise: false))
        }

        let unionHoles = unionBoundaryLoops(cutterProfiles, tolerance: tolerance)
            .filter { loop in
                loop.count >= 3
                    && abs(signedArea(loop)) > options.tolerance.areaEpsilon
                    && loop.allSatisfy { pointInPolygon($0, polygon: base.profilePoints, tolerance: tolerance) }
            }
            .map { ensureWinding($0, clockwise: true) }

        guard rejectedCutters == 0,
              (solid.cutterVolumes.isEmpty || !unionHoles.isEmpty) else {
            return ClosedShellReconstruction(
                vertices: [],
                triangles: [],
                candidateSurfaceCount: 1 + solid.cutterVolumes.count,
                keptFragmentCount: 0,
                rejectedFragmentCount: max(rejectedCutters, solid.cutterVolumes.count)
            )
        }

        var vertices: [DesignVector3] = []
        var triangles: [CADSolidTriangle] = []
        let outer = ensureWinding(base.profilePoints, clockwise: false)
        appendExtrudedPlanarShell(
            outer: outer,
            holes: unionHoles,
            base: base,
            vertices: &vertices,
            triangles: &triangles
        )
        return ClosedShellReconstruction(
            vertices: vertices,
            triangles: triangles,
            candidateSurfaceCount: 2 + outer.count + unionHoles.reduce(0) { $0 + $1.count },
            keptFragmentCount: triangles.count,
            rejectedFragmentCount: rejectedCutters
        )
    }

    private func appendExtrudedPlanarShell(
        outer: [SketchPoint2D],
        holes: [[SketchPoint2D]],
        base: CADVolume,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle]
    ) {
        let axis = base.direction.normalized(fallback: .zAxis)
        let capPolygon = bridgedPolygon(outer: outer, holes: holes)
        let capTriangles = earClip(capPolygon)

        func point3D(_ point: SketchPoint2D, depth: Double) -> DesignVector3 {
            base.origin + base.uAxis * point.u + base.vAxis * point.v + axis * depth
        }

        let bottomStart = vertices.count
        vertices.append(contentsOf: capPolygon.map { point3D($0, depth: 0) })
        let topStart = vertices.count
        vertices.append(contentsOf: capPolygon.map { point3D($0, depth: base.depthMeters) })

        for triangle in capTriangles {
            triangles.append(CADSolidTriangle(
                a: bottomStart + triangle.c,
                b: bottomStart + triangle.b,
                c: bottomStart + triangle.a
            ))
            triangles.append(CADSolidTriangle(
                a: topStart + triangle.a,
                b: topStart + triangle.b,
                c: topStart + triangle.c
            ))
        }

        let splitOuter = splitLoop(outer, by: capPolygon)
        appendLoopWall(loop: splitOuter, depth: base.depthMeters, base: base, inward: false, vertices: &vertices, triangles: &triangles)
        for hole in holes {
            appendLoopWall(loop: hole, depth: base.depthMeters, base: base, inward: true, vertices: &vertices, triangles: &triangles)
        }
    }

    private func splitLoop(_ loop: [SketchPoint2D], by points: [SketchPoint2D]) -> [SketchPoint2D] {
        guard loop.count >= 2 else { return loop }
        let tolerance = 1e-8
        var result: [SketchPoint2D] = []
        for index in loop.indices {
            let next = (index + 1) % loop.count
            let a = loop[index]
            let b = loop[next]
            var edgePoints: [(Double, SketchPoint2D)] = [(0, a), (1, b)]
            for point in points where distanceFromPoint(point, toSegmentA: a, b: b) <= tolerance {
                let t = parameter(of: point, onA: a, b: b)
                if t > tolerance, t < 1 - tolerance {
                    edgePoints.append((t, point))
                }
            }
            for entry in edgePoints.sorted(by: { $0.0 < $1.0 }) {
                if result.last?.distance(to: entry.1) ?? .infinity > tolerance {
                    result.append(entry.1)
                }
            }
            if result.last?.distance(to: b) ?? .infinity <= tolerance {
                result.removeLast()
                result.append(b)
            }
        }
        if result.count > 1, result[0].distance(to: result[result.count - 1]) <= tolerance {
            result.removeLast()
        }
        return result
    }

    private func appendLoopWall(
        loop: [SketchPoint2D],
        depth: Double,
        base: CADVolume,
        inward: Bool,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle]
    ) {
        guard loop.count >= 2 else { return }
        let axis = base.direction.normalized(fallback: .zAxis)
        func point3D(_ point: SketchPoint2D, _ depth: Double) -> DesignVector3 {
            base.origin + base.uAxis * point.u + base.vAxis * point.v + axis * depth
        }
        for index in loop.indices {
            let next = (index + 1) % loop.count
            let baseIndex = vertices.count
            let a = point3D(loop[index], 0)
            let b = point3D(loop[next], 0)
            let c = point3D(loop[next], depth)
            let d = point3D(loop[index], depth)
            vertices.append(contentsOf: [a, b, c, d])
            if inward {
                triangles.append(CADSolidTriangle(a: baseIndex, b: baseIndex + 2, c: baseIndex + 1))
                triangles.append(CADSolidTriangle(a: baseIndex, b: baseIndex + 3, c: baseIndex + 2))
            } else {
                triangles.append(CADSolidTriangle(a: baseIndex, b: baseIndex + 1, c: baseIndex + 2))
                triangles.append(CADSolidTriangle(a: baseIndex, b: baseIndex + 2, c: baseIndex + 3))
            }
        }
    }

    private func projectToBase2D(_ point: DesignVector3, base: CADVolume) -> SketchPoint2D {
        let delta = point - base.origin
        return SketchPoint2D(
            u: delta.dot(base.uAxis.normalized(fallback: .xAxis)),
            v: delta.dot(base.vAxis.normalized(fallback: .yAxis))
        )
    }

    private func unionBoundaryLoops(_ polygons: [[SketchPoint2D]], tolerance: Double) -> [[SketchPoint2D]] {
        guard !polygons.isEmpty else { return [] }
        var keptSegments: [Segment2D] = []
        for polygonIndex in polygons.indices {
            let polygon = polygons[polygonIndex]
            guard polygon.count >= 3 else { continue }
            for index in polygon.indices {
                let next = (index + 1) % polygon.count
                let a = polygon[index]
                let b = polygon[next]
                var splits: [Double] = [0, 1]
                for otherIndex in polygons.indices where otherIndex != polygonIndex {
                    let other = polygons[otherIndex]
                    for otherEdge in other.indices {
                        let otherNext = (otherEdge + 1) % other.count
                        appendIntersectionParameters(
                            segmentA: a,
                            segmentB: b,
                            otherA: other[otherEdge],
                            otherB: other[otherNext],
                            tolerance: tolerance,
                            parameters: &splits
                        )
                    }
                }
                splits = uniqueSorted(splits, tolerance: tolerance)
                for splitIndex in 0..<(splits.count - 1) {
                    let t0 = splits[splitIndex]
                    let t1 = splits[splitIndex + 1]
                    guard t1 - t0 > tolerance else { continue }
                    let start = interpolate(a, b, t0)
                    let end = interpolate(a, b, t1)
                    let mid = interpolate(a, b, (t0 + t1) * 0.5)
                    let insideOther = polygons.indices.contains { otherIndex in
                        otherIndex != polygonIndex
                            && pointStrictlyInsidePolygon(mid, polygon: polygons[otherIndex], tolerance: tolerance)
                    }
                    if !insideOther {
                        keptSegments.append(Segment2D(a: start, b: end))
                    }
                }
            }
        }
        return weldSegmentsIntoLoops(keptSegments, tolerance: tolerance)
    }

    private func appendIntersectionParameters(
        segmentA a: SketchPoint2D,
        segmentB b: SketchPoint2D,
        otherA c: SketchPoint2D,
        otherB d: SketchPoint2D,
        tolerance: Double,
        parameters: inout [Double]
    ) {
        let rU = b.u - a.u
        let rV = b.v - a.v
        let sU = d.u - c.u
        let sV = d.v - c.v
        let denominator = rU * sV - rV * sU
        if abs(denominator) > tolerance * tolerance {
            let qU = c.u - a.u
            let qV = c.v - a.v
            let t = (qU * sV - qV * sU) / denominator
            let u = (qU * rV - qV * rU) / denominator
            if t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance {
                parameters.append(min(max(t, 0), 1))
            }
            return
        }

        if distanceFromPoint(c, toSegmentA: a, b: b) <= tolerance {
            parameters.append(parameter(of: c, onA: a, b: b))
        }
        if distanceFromPoint(d, toSegmentA: a, b: b) <= tolerance {
            parameters.append(parameter(of: d, onA: a, b: b))
        }
    }

    private func weldSegmentsIntoLoops(_ segments: [Segment2D], tolerance: Double) -> [[SketchPoint2D]] {
        var remaining = segments
        var loops: [[SketchPoint2D]] = []
        while let first = remaining.first {
            remaining.removeFirst()
            var loop = [first.a, first.b]
            var extended = true
            while extended {
                extended = false
                guard let tail = loop.last else { break }
                if tail.distance(to: loop[0]) <= tolerance {
                    loop[loop.count - 1] = loop[0]
                    break
                }
                if let index = remaining.firstIndex(where: { $0.a.distance(to: tail) <= tolerance || $0.b.distance(to: tail) <= tolerance }) {
                    let segment = remaining.remove(at: index)
                    loop.append(segment.a.distance(to: tail) <= tolerance ? segment.b : segment.a)
                    extended = true
                }
            }
            let normalized = normalizeLoop(loop, tolerance: tolerance, close: false)
            if normalized.count >= 3 {
                loops.append(normalized)
            }
        }
        return loops
    }

    private func bridgedPolygon(outer: [SketchPoint2D], holes: [[SketchPoint2D]]) -> [SketchPoint2D] {
        var polygon = outer
        for hole in holes where hole.count >= 3 {
            polygon = bridgeHole(into: polygon, hole: hole)
        }
        return normalizeLoop(polygon, tolerance: 1e-9, close: false)
    }

    private func bridgeHole(into outer: [SketchPoint2D], hole: [SketchPoint2D]) -> [SketchPoint2D] {
        guard let holeIndex = hole.indices.max(by: {
            hole[$0].u == hole[$1].u ? hole[$0].v < hole[$1].v : hole[$0].u < hole[$1].u
        }) else { return outer }
        let h = hole[holeIndex]
        var best: (edge: Int, point: SketchPoint2D, distance: Double)?
        for index in outer.indices {
            let next = (index + 1) % outer.count
            let a = outer[index]
            let b = outer[next]
            guard (a.v > h.v) != (b.v > h.v) else { continue }
            let t = (h.v - a.v) / (b.v - a.v)
            let x = a.u + (b.u - a.u) * t
            guard x > h.u else { continue }
            let point = SketchPoint2D(u: x, v: h.v)
            let distance = x - h.u
            if best == nil || distance < best!.distance {
                best = (index, point, distance)
            }
        }
        guard let bridge = best else { return outer }
        var result: [SketchPoint2D] = []
        result.append(contentsOf: outer[...bridge.edge])
        result.append(bridge.point)
        result.append(h)
        for offset in 1...hole.count {
            let index = (holeIndex + offset) % hole.count
            result.append(hole[index])
        }
        result.append(h)
        result.append(bridge.point)
        if bridge.edge + 1 < outer.count {
            result.append(contentsOf: outer[(bridge.edge + 1)...])
        }
        return result
    }

    private func earClip(_ polygon: [SketchPoint2D]) -> [CADSolidTriangle] {
        let points = ensureWinding(polygon, clockwise: false)
        guard points.count >= 3 else { return [] }
        var indices = Array(points.indices)
        var triangles: [CADSolidTriangle] = []
        var guardCount = 0
        while indices.count > 3, guardCount < points.count * points.count {
            guardCount += 1
            var clipped = false
            for localIndex in indices.indices {
                let prev = indices[(localIndex + indices.count - 1) % indices.count]
                let current = indices[localIndex]
                let next = indices[(localIndex + 1) % indices.count]
                guard isConvex(points[prev], points[current], points[next]) else { continue }
                let containsPoint = indices.contains { candidate in
                    candidate != prev && candidate != current && candidate != next
                        && points[candidate].distance(to: points[prev]) > 1e-9
                        && points[candidate].distance(to: points[current]) > 1e-9
                        && points[candidate].distance(to: points[next]) > 1e-9
                        && pointInTriangle(points[candidate], points[prev], points[current], points[next])
                }
                guard !containsPoint else { continue }
                triangles.append(CADSolidTriangle(a: prev, b: current, c: next))
                indices.remove(at: localIndex)
                clipped = true
                break
            }
            if !clipped { break }
        }
        if indices.count == 3 {
            triangles.append(CADSolidTriangle(a: indices[0], b: indices[1], c: indices[2]))
        }
        return triangles
    }

    private func normalizeLoop(_ points: [SketchPoint2D], tolerance: Double, close: Bool) -> [SketchPoint2D] {
        var result: [SketchPoint2D] = []
        for point in points where result.last?.distance(to: point) ?? .infinity > tolerance {
            result.append(point)
        }
        if !close, result.count > 1, result[0].distance(to: result[result.count - 1]) <= tolerance {
            result.removeLast()
        }
        if close, result.count > 2, result[0].distance(to: result[result.count - 1]) > tolerance {
            result.append(result[0])
        }
        return result
    }

    private func ensureWinding(_ points: [SketchPoint2D], clockwise: Bool) -> [SketchPoint2D] {
        let isClockwise = signedArea(points) < 0
        return isClockwise == clockwise ? points : Array(points.reversed())
    }

    private func uniqueSorted(_ values: [Double], tolerance: Double) -> [Double] {
        values.map { min(max($0, 0), 1) }.sorted().reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > tolerance }) ?? true {
                result.append(value)
            }
        }
    }

    private func interpolate(_ a: SketchPoint2D, _ b: SketchPoint2D, _ t: Double) -> SketchPoint2D {
        SketchPoint2D(u: a.u + (b.u - a.u) * t, v: a.v + (b.v - a.v) * t)
    }

    private func parameter(of point: SketchPoint2D, onA a: SketchPoint2D, b: SketchPoint2D) -> Double {
        let du = b.u - a.u
        let dv = b.v - a.v
        let len2 = du * du + dv * dv
        guard len2 > 1e-18 else { return 0 }
        return ((point.u - a.u) * du + (point.v - a.v) * dv) / len2
    }

    private func pointStrictlyInsidePolygon(_ point: SketchPoint2D, polygon: [SketchPoint2D], tolerance: Double) -> Bool {
        if polygon.indices.contains(where: {
            let next = ($0 + 1) % polygon.count
            return distanceFromPoint(point, toSegmentA: polygon[$0], b: polygon[next]) <= tolerance
        }) {
            return false
        }
        return pointInPolygon(point, polygon: polygon, tolerance: tolerance)
    }

    private func pointInPolygon(_ point: SketchPoint2D, polygon: [SketchPoint2D], tolerance: Double) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if distanceFromPoint(point, toSegmentA: pi, b: pj) <= tolerance {
                return true
            }
            if (pi.v > point.v) != (pj.v > point.v) {
                let x = (pj.u - pi.u) * (point.v - pi.v) / (pj.v - pi.v) + pi.u
                if point.u < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private func pointInTriangle(_ p: SketchPoint2D, _ a: SketchPoint2D, _ b: SketchPoint2D, _ c: SketchPoint2D) -> Bool {
        let area = abs(cross(a, b, c))
        guard area > 1e-14 else { return false }
        let a1 = abs(cross(p, a, b))
        let a2 = abs(cross(p, b, c))
        let a3 = abs(cross(p, c, a))
        return abs((a1 + a2 + a3) - area) <= 1e-10
    }

    private func isConvex(_ a: SketchPoint2D, _ b: SketchPoint2D, _ c: SketchPoint2D) -> Bool {
        cross(a, b, c) > 1e-14
    }

    private func cross(_ a: SketchPoint2D, _ b: SketchPoint2D, _ c: SketchPoint2D) -> Double {
        (b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)
    }

    private func signedArea(_ points: [SketchPoint2D]) -> Double {
        guard points.count >= 3 else { return 0 }
        var area = 0.0
        for index in points.indices {
            let next = (index + 1) % points.count
            area += points[index].u * points[next].v - points[next].u * points[index].v
        }
        return area * 0.5
    }

    private func distanceFromPoint(
        _ point: SketchPoint2D,
        toSegmentA a: SketchPoint2D,
        b: SketchPoint2D
    ) -> Double {
        let abU = b.u - a.u
        let abV = b.v - a.v
        let lengthSquared = abU * abU + abV * abV
        guard lengthSquared > 1e-18 else { return point.distance(to: a) }
        let t = max(0, min(1, ((point.u - a.u) * abU + (point.v - a.v) * abV) / lengthSquared))
        return point.distance(to: SketchPoint2D(u: a.u + abU * t, v: a.v + abV * t))
    }

    private func appendVolumeSurfaces(
        _ volume: CADVolume,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle]
    ) -> (candidateSurfaces: Int, keptFragments: Int, rejectedFragments: Int) {
        switch volume.kind {
        case .boxExtrusion, .rectangularPrism:
            return appendPrismaticSurfaces(
                volume,
                solid: solid,
                classifier: classifier,
                options: options,
                vertices: &vertices,
                triangles: &triangles
            )
        case .cylinder:
            return appendCylindricalSurfaces(
                volume,
                solid: solid,
                classifier: classifier,
                options: options,
                vertices: &vertices,
                triangles: &triangles
            )
        case .unsupported:
            return (0, 0, 0)
        }
    }

    private func appendPrismaticSurfaces(
        _ volume: CADVolume,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle]
    ) -> (candidateSurfaces: Int, keptFragments: Int, rejectedFragments: Int) {
        guard volume.profilePoints.count >= 3 else { return (0, 0, 0) }
        var candidateSurfaces = 0
        var keptFragments = 0
        var rejectedFragments = 0
        let direction = volume.direction.normalized(fallback: .zAxis)

        let front = volume.profilePoints.map { volume.origin + volume.uAxis * $0.u + volume.vAxis * $0.v }
        let back = front.map { $0 + direction * volume.depthMeters }
        candidateSurfaces += 2
        appendPlanarGridSurface(
            points: front,
            normal: direction * -1,
            solid: solid,
            classifier: classifier,
            options: options,
            vertices: &vertices,
            triangles: &triangles,
            kept: &keptFragments,
            rejected: &rejectedFragments
        )
        appendPlanarGridSurface(
            points: back,
            normal: direction,
            solid: solid,
            classifier: classifier,
            options: options,
            vertices: &vertices,
            triangles: &triangles,
            kept: &keptFragments,
            rejected: &rejectedFragments
        )

        for index in volume.profilePoints.indices {
            candidateSurfaces += 1
            let next = (index + 1) % volume.profilePoints.count
            let a = front[index]
            let b = front[next]
            let c = back[next]
            let d = back[index]
            let normal = (b - a).cross(d - a).normalized(fallback: direction)
            appendBoundaryQuad(
                a,
                b,
                c,
                d,
                normal: normal,
                solid: solid,
                classifier: classifier,
                options: options,
                vertices: &vertices,
                triangles: &triangles,
                kept: &keptFragments,
                rejected: &rejectedFragments
            )
        }
        return (candidateSurfaces, keptFragments, rejectedFragments)
    }

    private func appendCylindricalSurfaces(
        _ volume: CADVolume,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle]
    ) -> (candidateSurfaces: Int, keptFragments: Int, rejectedFragments: Int) {
        guard let metrics = circleMetrics(for: volume) else { return (0, 0, 0) }
        let segments = max(options.cylinderSegments, 16)
        let depthSegments = max(options.depthSegments, 1)
        let axis = volume.direction.normalized(fallback: .zAxis)
        var kept = 0
        var rejected = 0
        var rings: [[DesignVector3]] = []
        for depthIndex in 0...depthSegments {
            let depth = volume.depthMeters * Double(depthIndex) / Double(depthSegments)
            var ring: [DesignVector3] = []
            for segment in 0..<segments {
                let theta = Double(segment) / Double(segments) * 2.0 * Double.pi
                let local = SketchPoint2D(
                    u: metrics.center.u + cos(theta) * metrics.radius,
                    v: metrics.center.v + sin(theta) * metrics.radius
                )
                ring.append(volume.origin + volume.uAxis * local.u + volume.vAxis * local.v + axis * depth)
            }
            rings.append(ring)
        }

        for depthIndex in 0..<depthSegments {
            for segment in 0..<segments {
                let next = (segment + 1) % segments
                let a = rings[depthIndex][segment]
                let b = rings[depthIndex][next]
                let c = rings[depthIndex + 1][next]
                let d = rings[depthIndex + 1][segment]
                let radial = ((a + b + c + d) * 0.25)
                    - (volume.origin + axis * (volume.depthMeters * (Double(depthIndex) + 0.5) / Double(depthSegments)))
                appendBoundaryQuad(
                    a,
                    b,
                    c,
                    d,
                    normal: radial.normalized(fallback: volume.uAxis),
                    solid: solid,
                    classifier: classifier,
                    options: options,
                    vertices: &vertices,
                    triangles: &triangles,
                    kept: &kept,
                    rejected: &rejected
                )
            }
        }

        let front = rings[0]
        let back = rings[rings.count - 1]
        appendPlanarGridSurface(
            points: front,
            normal: axis * -1,
            solid: solid,
            classifier: classifier,
            options: options,
            vertices: &vertices,
            triangles: &triangles,
            kept: &kept,
            rejected: &rejected
        )
        appendPlanarGridSurface(
            points: back,
            normal: axis,
            solid: solid,
            classifier: classifier,
            options: options,
            vertices: &vertices,
            triangles: &triangles,
            kept: &kept,
            rejected: &rejected
        )
        return (3, kept, rejected)
    }

    private func appendPlanarGridSurface(
        points: [DesignVector3],
        normal: DesignVector3,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle],
        kept: inout Int,
        rejected: inout Int
    ) {
        guard points.count >= 3,
              let bounds = CADSolidBounds(points: points) else { return }
        let resolution = max(options.planeGridResolution, 2)
        let stepX = (bounds.max.x - bounds.min.x) / Double(resolution)
        let stepY = (bounds.max.y - bounds.min.y) / Double(resolution)
        let stepZ = (bounds.max.z - bounds.min.z) / Double(resolution)

        let axisA: DesignVector3
        let axisB: DesignVector3
        let origin = points[0]
        let n = normal.normalized(fallback: .zAxis)
        if abs(n.z) >= abs(n.x), abs(n.z) >= abs(n.y) {
            axisA = .xAxis * max(stepX, options.tolerance.positionEpsilon)
            axisB = .yAxis * max(stepY, options.tolerance.positionEpsilon)
        } else if abs(n.y) >= abs(n.x) {
            axisA = .xAxis * max(stepX, options.tolerance.positionEpsilon)
            axisB = .zAxis * max(stepZ, options.tolerance.positionEpsilon)
        } else {
            axisA = .yAxis * max(stepY, options.tolerance.positionEpsilon)
            axisB = .zAxis * max(stepZ, options.tolerance.positionEpsilon)
        }

        for i in 0..<resolution {
            for j in 0..<resolution {
                let center = bounds.min
                    + axisA * (Double(i) + 0.5)
                    + axisB * (Double(j) + 0.5)
                let projected = center + n * ((origin - center).dot(n))
                let a = projected - axisA * 0.5 - axisB * 0.5
                let b = projected + axisA * 0.5 - axisB * 0.5
                let c = projected + axisA * 0.5 + axisB * 0.5
                let d = projected - axisA * 0.5 + axisB * 0.5
                appendBoundaryQuad(
                    a,
                    b,
                    c,
                    d,
                    normal: n,
                    solid: solid,
                    classifier: classifier,
                    options: options,
                    vertices: &vertices,
                    triangles: &triangles,
                    kept: &kept,
                    rejected: &rejected
                )
            }
        }
    }

    private func appendBoundaryQuad(
        _ a: DesignVector3,
        _ b: DesignVector3,
        _ c: DesignVector3,
        _ d: DesignVector3,
        normal: DesignVector3,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions,
        vertices: inout [DesignVector3],
        triangles: inout [CADSolidTriangle],
        kept: inout Int,
        rejected: inout Int
    ) {
        let center = (a + b + c + d) * 0.25
        guard isBoundaryFragment(center: center, normal: normal, solid: solid, classifier: classifier, options: options) else {
            rejected += 1
            return
        }
        let base = vertices.count
        vertices.append(contentsOf: [a, b, c, d])
        triangles.append(CADSolidTriangle(a: base, b: base + 1, c: base + 2))
        triangles.append(CADSolidTriangle(a: base, b: base + 2, c: base + 3))
        kept += 1
    }

    private func isBoundaryFragment(
        center: DesignVector3,
        normal: DesignVector3,
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions
    ) -> Bool {
        let n = normal.normalized(fallback: .zAxis)
        let offset = options.tolerance.classificationEpsilon
        let plus = classifier.classify(center + n * offset, in: solid)
        let minus = classifier.classify(center - n * offset, in: solid)
        return (plus == .material && minus == .empty)
            || (plus == .empty && minus == .material)
            || plus == .boundary
            || minus == .boundary
    }

    private func cleanupMesh(
        vertices: [DesignVector3],
        triangles: [CADSolidTriangle],
        solid: CADSolid,
        classifier: CADSolidMaterialClassifier,
        options: CADBoundaryBuildOptions
    ) -> (
        vertices: [DesignVector3],
        triangles: [CADSolidTriangle],
        removedDuplicateVertices: Int,
        removedDuplicateTriangles: Int,
        removedZeroAreaTriangles: Int,
        removedSliverTriangles: Int,
        removedInvalidBoundaryTriangles: Int
    ) {
        let epsilon = max(options.tolerance.mergeEpsilon, 1e-9)
        var weldedVertices: [DesignVector3] = []
        var remap: [Int: Int] = [:]
        var keyToIndex: [String: Int] = [:]
        for (index, vertex) in vertices.enumerated() {
            let key = "\(Int64((vertex.x / epsilon).rounded()))|\(Int64((vertex.y / epsilon).rounded()))|\(Int64((vertex.z / epsilon).rounded()))"
            if let existing = keyToIndex[key] {
                remap[index] = existing
            } else {
                let newIndex = weldedVertices.count
                keyToIndex[key] = newIndex
                remap[index] = newIndex
                weldedVertices.append(vertex)
            }
        }

        var cleaned: [CADSolidTriangle] = []
        var seenTriangles: Set<String> = []
        var removedDuplicateTriangles = 0
        var removedZeroAreaTriangles = 0
        var removedSliverTriangles = 0
        let removedInvalidBoundaryTriangles = 0

        for triangle in triangles {
            guard let aIndex = remap[triangle.a],
                  let bIndex = remap[triangle.b],
                  let cIndex = remap[triangle.c],
                  aIndex != bIndex,
                  bIndex != cIndex,
                  cIndex != aIndex else {
                removedZeroAreaTriangles += 1
                continue
            }
            let a = weldedVertices[aIndex]
            let b = weldedVertices[bIndex]
            let c = weldedVertices[cIndex]
            let area2 = (b - a).cross(c - a).length
            if area2 <= options.tolerance.areaEpsilon {
                removedZeroAreaTriangles += 1
                continue
            }
            let maxEdge = max((b - a).length, max((c - b).length, (a - c).length))
            if maxEdge > epsilon, area2 <= options.tolerance.areaEpsilon * maxEdge {
                removedSliverTriangles += 1
                continue
            }
            _ = solid
            _ = classifier
            let key = [aIndex, bIndex, cIndex].sorted().map(String.init).joined(separator: "|")
            if seenTriangles.contains(key) {
                removedDuplicateTriangles += 1
                continue
            }
            seenTriangles.insert(key)
            cleaned.append(CADSolidTriangle(a: aIndex, b: bIndex, c: cIndex))
        }

        return (
            weldedVertices,
            cleaned,
            vertices.count - weldedVertices.count,
            removedDuplicateTriangles,
            removedZeroAreaTriangles,
            removedSliverTriangles,
            removedInvalidBoundaryTriangles
        )
    }

    private func circleMetrics(for volume: CADVolume) -> (center: SketchPoint2D, radius: Double)? {
        guard volume.profilePoints.count >= 8 else { return nil }
        let center = volume.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
            SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
        }
        let count = Double(volume.profilePoints.count)
        let averagedCenter = SketchPoint2D(u: center.u / count, v: center.v / count)
        let radius = volume.profilePoints.reduce(0.0) { total, point in
            total + point.distance(to: averagedCenter)
        } / count
        guard radius.isFinite, radius > 1e-9 else { return nil }
        return (averagedCenter, radius)
    }
}

enum CADLimitedSolidKernel {
    static func makeSolid(
        id: UUID,
        from params: ExtrudedSolidParameters,
        meshCache: CADSolidMeshSnapshot? = nil
    ) -> CADSolid {
        if var committed = params.kernelResultSolid,
           committed.id == id,
           committed.cutterVolumes.count == params.boxBlindCutFeatures.count,
           Set(committed.cutterVolumes.map(\.id)) == Set(params.boxBlindCutFeatures.map(\.id)),
           meshCache == nil {
            let resolvedMeshCache = params.kernelVisualMesh ?? committed.visualMeshCache?.mesh
            committed.visualMeshCache = CADVisualMeshCache(
                mesh: resolvedMeshCache,
                diagnostics: resolvedMeshCache.map { CADSolidMeshValidator.diagnose($0) },
                generationVersion: committed.generationVersion
            )
            return committed
        }
        let additiveVolumes = baseVolumes(for: params)
        var cutterVolumes: [CADVolume] = []
        var currentSolid = partialSolid(id: id, additiveVolumes: additiveVolumes, cutterVolumes: [])
        for feature in params.boxBlindCutFeatures {
            guard let cutter = operationVolume(for: feature, in: params, currentSolid: currentSolid) else { continue }
            cutterVolumes.append(cutter)
            currentSolid = partialSolid(id: id, additiveVolumes: additiveVolumes, cutterVolumes: cutterVolumes)
        }
        let bounds = bounds(for: additiveVolumes)
        let resolvedMeshCache = meshCache ?? params.kernelVisualMesh
        let evaluatedState = evaluateState(
            additiveVolumes: additiveVolumes,
            cutterVolumes: cutterVolumes,
            boundingBox: bounds
        )
        return CADSolid(
            id: id,
            additiveVolumes: additiveVolumes,
            cutterVolumes: cutterVolumes,
            evaluatedState: evaluatedState,
            evaluatedBounds: bounds,
            validationState: .valid(debugDetails: ["source=legacy_extruded_solid"]),
            generationVersion: params.boxBlindCutFeatures.count + 1,
            legacyPrismaticRepresentation: CADPrismaticSolidRepresentation(
                baseProfile: params.profilePoints,
                sourceReference: params.sourceReference,
                depthMeters: params.depthMeters,
                direction: params.direction,
                faces: params.faces,
                removedVolumes: cutterVolumes
            ),
            visualMeshCache: CADVisualMeshCache(
                mesh: resolvedMeshCache,
                diagnostics: resolvedMeshCache.map { CADSolidMeshValidator.diagnose($0) },
                generationVersion: params.boxBlindCutFeatures.count + 1
            )
        )
    }

    static func appendingSubtractVolume(
        _ cut: ExtrudedSolidBoxBlindCutFeature,
        to solid: CADSolid,
        bodyParams: ExtrudedSolidParameters
    ) -> CADSolid? {
        guard let cutter = operationVolume(for: cut, in: bodyParams, currentSolid: solid) else { return nil }
        var next = solid
        next.cutterVolumes.append(cutter)
        next.evaluatedBounds = bounds(for: next.additiveVolumes)
        next.evaluatedState = evaluateState(
            additiveVolumes: next.additiveVolumes,
            cutterVolumes: next.cutterVolumes,
            boundingBox: next.evaluatedBounds
        )
        next.validationState = .valid(debugDetails: ["operation=subtract", "cutterVolumeID=\(cutter.id.uuidString)"])
        next.generationVersion += 1
        next.visualMeshCache = nil
        return next
    }

    static func makeSubtractVolume(
        for cut: ExtrudedSolidBoxBlindCutFeature,
        in bodyParams: ExtrudedSolidParameters
    ) -> CADVolume? {
        operationVolume(for: cut, in: bodyParams, currentSolid: makeSolid(id: UUID(), from: bodyParams))
    }

    static func validateSubtractOperation(
        bodyParams: ExtrudedSolidParameters,
        cut: ExtrudedSolidBoxBlindCutFeature,
        blockIntersectingCuts: Bool = false
    ) -> CADFeatureValidation {
        let sourceSolid = makeSolid(id: UUID(), from: bodyParams)
        guard let candidateVolume = operationVolume(for: cut, in: bodyParams, currentSolid: sourceSolid) else {
            return .cutBooleanFailed
        }
        guard let bodyBounds = sourceSolid.evaluatedBounds,
              candidateVolume.bounds.intersects(bodyBounds) else {
            return .cutToolDoesNotIntersectBody
        }

        if blockIntersectingCuts,
           sourceSolid.cutterVolumes.contains(where: { $0.bounds.intersects(candidateVolume.bounds) }) {
            return .cutIntersectsExistingVoidUnsupported
        }

        return .valid
    }

    static func cutIntersectsExistingVoid(
        bodyParams: ExtrudedSolidParameters,
        cut: ExtrudedSolidBoxBlindCutFeature
    ) -> Bool {
        let sourceSolid = makeSolid(id: UUID(), from: bodyParams)
        guard let candidateVolume = operationVolume(for: cut, in: bodyParams, currentSolid: sourceSolid) else {
            return false
        }
        return sourceSolid.cutterVolumes.contains { $0.bounds.intersects(candidateVolume.bounds) }
    }

    static func validateTopology(
        _ mesh: CADSolidMeshSnapshot
    ) -> CADTopologyValidationResult {
        let diagnostics = CADSolidMeshValidator.diagnose(mesh)
        if !diagnostics.isClosedManifold {
            return CADTopologyValidationResult(
                isValid: false,
                diagnostics: diagnostics,
                failure: .cutResultNotSolid
            )
        }
        return CADTopologyValidationResult(
            isValid: true,
            diagnostics: diagnostics,
            failure: nil
        )
    }

    private static func operationVolume(
        for feature: ExtrudedSolidBoxBlindCutFeature,
        in bodyParams: ExtrudedSolidParameters,
        currentSolid: CADSolid? = nil
    ) -> CADVolume? {
        guard let entryFace = bodyParams.faces.first(where: { $0.id == feature.entryFaceID }),
              feature.profilePoints.count >= 3,
              feature.cutDirection.isFinite else {
            return nil
        }

        let faceU = entryFace.uAxis.normalized(fallback: .xAxis)
        let faceV = entryFace.vAxis.normalized(fallback: .yAxis)
        let startPoints = feature.profilePoints.map { point in
            entryFace.origin + faceU * point.u + faceV * point.v
        }
        let direction = feature.cutDirection.normalized(fallback: entryFace.normal * -1)
        let depth: Double
        switch feature.depthMode {
        case .distance:
            depth = feature.depthMeters
        case .throughAll:
            depth = throughAllDepth(for: feature, entryFace: entryFace, currentSolid: currentSolid) ?? feature.depthMeters
        case .upToObject, .upToNearestFace:
            return nil
        }
        guard depth.isFinite, depth > 1e-6 else { return nil }

        let endPoints = startPoints.map { $0 + direction * depth }
        guard let bounds = CADSolidBounds(points: startPoints + endPoints) else { return nil }
        return CADVolume(
            id: feature.id,
            kind: volumeKind(for: feature.profileType),
            operationRole: .subtractive,
            profileType: feature.profileType,
            sourceSketchID: feature.sourceSketchID,
            sourceProfileID: feature.selectedProfileID,
            entryFaceID: feature.entryFaceID,
            profilePoints: feature.profilePoints,
            holes: [],
            origin: entryFace.origin,
            uAxis: faceU,
            vAxis: faceV,
            direction: direction,
            depthMeters: depth,
            depthMode: feature.depthMode,
            bounds: bounds
        )
    }

    private static func baseVolumes(for params: ExtrudedSolidParameters) -> [CADVolume] {
        let normal = normalVector(for: params.sourceReference).normalized(fallback: .zAxis)
        let axes = axesForSketchReference(params.sourceReference)
        let (frontOffset, backOffset) = params.direction.offsets(depth: params.depthMeters)
        let startOffset = min(frontOffset, backOffset)
        let endOffset = max(frontOffset, backOffset)
        let depth = endOffset - startOffset
        guard depth.isFinite, depth > 1e-6 else { return [] }

        let origin = originForSketchReference(params.sourceReference) + normal * startOffset
        let startPoints = params.profilePoints.map { point in
            origin + axes.u * point.u + axes.v * point.v
        }
        let endPoints = startPoints.map { $0 + normal * depth }
        guard let volumeBounds = CADSolidBounds(points: startPoints + endPoints) else { return [] }

        return [
            CADVolume(
                id: params.sourceSketchID,
                kind: .boxExtrusion,
                operationRole: .additive,
                profileType: .polygon,
                sourceSketchID: params.sourceSketchID,
                sourceProfileID: nil,
                entryFaceID: nil,
                profilePoints: params.profilePoints,
                holes: params.holes,
                origin: origin,
                uAxis: axes.u.normalized(fallback: .xAxis),
                vAxis: axes.v.normalized(fallback: .yAxis),
                direction: normal,
                depthMeters: depth,
                depthMode: .distance,
                bounds: volumeBounds
            )
        ]
    }

    private static func volumeKind(for profileType: CADCutV2ProfileType) -> CADVolumeKind {
        switch profileType {
        case .circle:
            return .cylinder
        case .rectangle:
            return .rectangularPrism
        case .polygon, .unsupported:
            return .unsupported
        }
    }

    private static func bounds(for volumes: [CADVolume]) -> CADSolidBounds? {
        var result: CADSolidBounds?
        for volume in volumes {
            result = result.map { $0.union(volume.bounds) } ?? volume.bounds
        }
        return result
    }

    private static func evaluateState(
        additiveVolumes: [CADVolume],
        cutterVolumes: [CADVolume],
        boundingBox: CADSolidBounds?
    ) -> CADSolidEvaluatedState {
        let additiveVolume = additiveVolumes.reduce(0.0) { $0 + $1.estimatedVolumeMeters3 }
        let cutterVolume = cutterVolumes.reduce(0.0) { $0 + $1.estimatedVolumeMeters3 }
        return CADSolidEvaluatedState(
            materialRuleVersion: 1,
            additiveVolumeCount: additiveVolumes.count,
            cutterVolumeCount: cutterVolumes.count,
            boundingBox: boundingBox,
            estimatedVolumeMeters3: max(additiveVolume - cutterVolume, 0),
            validationState: .valid(debugDetails: [
                "additiveVolumeEstimate=\(additiveVolume)",
                "cutterVolumeEstimate=\(cutterVolume)"
            ])
        )
    }

    private static func partialSolid(
        id: UUID,
        additiveVolumes: [CADVolume],
        cutterVolumes: [CADVolume]
    ) -> CADSolid {
        let bounds = bounds(for: additiveVolumes)
        return CADSolid(
            id: id,
            additiveVolumes: additiveVolumes,
            cutterVolumes: cutterVolumes,
            evaluatedState: evaluateState(
                additiveVolumes: additiveVolumes,
                cutterVolumes: cutterVolumes,
                boundingBox: bounds
            ),
            evaluatedBounds: bounds,
            validationState: .valid(debugDetails: ["source=partial_solid"]),
            generationVersion: cutterVolumes.count + 1,
            legacyPrismaticRepresentation: nil,
            visualMeshCache: nil
        )
    }

    private static func throughAllDepth(
        for feature: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        currentSolid: CADSolid?
    ) -> Double? {
        let direction = feature.cutDirection.normalized(fallback: entryFace.normal * -1)
        let entryU = entryFace.uAxis.normalized(fallback: .xAxis)
        let entryV = entryFace.vAxis.normalized(fallback: .yAxis)
        let center = feature.profilePoints.reduce(SketchPoint2D.zero) { partial, point in
            SketchPoint2D(u: partial.u + point.u, v: partial.v + point.v)
        }
        let count = max(Double(feature.profilePoints.count), 1.0)
        let entryCenter = entryFace.origin
            + entryU * (center.u / count)
            + entryV * (center.v / count)

        let forwardDistances = currentSolidSamplePoints(currentSolid)
            .map { ($0 - entryCenter).dot(direction) }
            .filter { $0.isFinite && $0 > 1e-6 }
        guard let maxDistance = forwardDistances.max() else { return nil }
        return maxDistance + 0.005
    }

    private static func currentSolidSamplePoints(_ solid: CADSolid?) -> [DesignVector3] {
        if let meshVertices = solid?.visualMeshCache?.mesh?.vertices,
           !meshVertices.isEmpty {
            return meshVertices
        }
        guard let bounds = solid?.evaluatedBounds else { return [] }
        return [
            DesignVector3(x: bounds.min.x, y: bounds.min.y, z: bounds.min.z),
            DesignVector3(x: bounds.min.x, y: bounds.min.y, z: bounds.max.z),
            DesignVector3(x: bounds.min.x, y: bounds.max.y, z: bounds.min.z),
            DesignVector3(x: bounds.min.x, y: bounds.max.y, z: bounds.max.z),
            DesignVector3(x: bounds.max.x, y: bounds.min.y, z: bounds.min.z),
            DesignVector3(x: bounds.max.x, y: bounds.min.y, z: bounds.max.z),
            DesignVector3(x: bounds.max.x, y: bounds.max.y, z: bounds.min.z),
            DesignVector3(x: bounds.max.x, y: bounds.max.y, z: bounds.max.z)
        ]
    }
}
