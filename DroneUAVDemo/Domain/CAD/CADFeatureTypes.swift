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

// MARK: - Cut v2 Stage 1 Preview Metadata

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

    var isSupportedStage1: Bool {
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
    case unsupportedProfileForCutV2Stage1
    case cutApplyDisabledStage1
    case cutApplyThroughAllDisabledStage2
    case throughAllCircleCutApplyNotReady
    case unsupportedCutApplyStage2A
    case distanceCutReachesOrExceedsBodyThicknessStage2A
    case cutResultNotSolid
    case cutResultBoundsInvalid
    case cutMissingCylindricalWall
    case cutMissingBlindBottom
    case cutMissingExitOpening
    case unaffectedGeometryWasRemoved
    case cutVisibleTriangulationArtifact
    case invalidEntryFaceTriangulation
    case cutBooleanFailed

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
        case .unsupportedProfileForCutV2Stage1: return "cad.cut_v2.reason.unsupported_profile_for_cut_v2_stage1"
        case .cutApplyDisabledStage1:        return "cad.cut_v2.stage1.apply_disabled"
        case .cutApplyThroughAllDisabledStage2: return "cad.cut_v2.stage2.through_all_apply_disabled"
        case .throughAllCircleCutApplyNotReady: return "cad.cut_v2.reason.through_all_circle_cut_apply_not_ready"
        case .unsupportedCutApplyStage2A:     return "cad.cut_v2.reason.unsupported_cut_apply_stage2a"
        case .distanceCutReachesOrExceedsBodyThicknessStage2A: return "cad.cut_v2.reason.distance_cut_reaches_or_exceeds_body_thickness_stage2a"
        case .cutResultNotSolid:             return "cad.cut_v2.reason.cut_result_not_solid"
        case .cutResultBoundsInvalid:        return "cad.cut_v2.reason.cut_result_bounds_invalid"
        case .cutMissingCylindricalWall:     return "cad.cut_v2.reason.cut_missing_cylindrical_wall"
        case .cutMissingBlindBottom:         return "cad.cut_v2.reason.cut_missing_blind_bottom"
        case .cutMissingExitOpening:         return "cad.cut_v2.reason.cut_missing_exit_opening"
        case .unaffectedGeometryWasRemoved:  return "cad.cut_v2.reason.unaffected_geometry_was_removed"
        case .cutVisibleTriangulationArtifact: return "cad.cut_v2.reason.cut_visible_triangulation_artifact"
        case .invalidEntryFaceTriangulation: return "cad.cut_v2.reason.invalid_entry_face_triangulation"
        case .cutBooleanFailed:              return "cad.cut_v2.reason.cut_boolean_failed"
        }
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
