import Foundation
import Combine
import CoreGraphics

private struct CADAxisAlignedBounds: Equatable {
    var min: DesignVector3
    var max: DesignVector3

    init?(points: [DesignVector3]) {
        guard !points.isEmpty,
              points.allSatisfy({ $0.isFinite }) else { return nil }
        min = DesignVector3(
            x: points.map(\.x).min() ?? 0,
            y: points.map(\.y).min() ?? 0,
            z: points.map(\.z).min() ?? 0
        )
        max = DesignVector3(
            x: points.map(\.x).max() ?? 0,
            y: points.map(\.y).max() ?? 0,
            z: points.map(\.z).max() ?? 0
        )
    }

    func intersects(_ other: CADAxisAlignedBounds, tolerance: Double = 1e-6) -> Bool {
        func overlap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
            Swift.min(a1, b1) - Swift.max(a0, b0) > tolerance
        }
        return overlap(min.x, max.x, other.min.x, other.max.x)
            && overlap(min.y, max.y, other.min.y, other.max.y)
            && overlap(min.z, max.z, other.min.z, other.max.z)
    }

    func expands(beyond other: CADAxisAlignedBounds, tolerance: Double = 1e-6) -> Bool {
        min.x < other.min.x - tolerance
            || min.y < other.min.y - tolerance
            || min.z < other.min.z - tolerance
            || max.x > other.max.x + tolerance
            || max.y > other.max.y + tolerance
            || max.z > other.max.z + tolerance
    }

    var diagonalLength: Double {
        (max - min).length
    }
}

private struct CADCutPreviewCacheKey: Equatable {
    var operation: CADFeatureOperation
    var profilePoints: [SketchPoint2D]
    var sourceReference: SketchReference
    var targetBodyID: UUID?
    var selectedProfileID: UUID?
    var depthMeters: Double
    var direction: ExtrudeDirection
    var depthMode: DepthMode
    var sourceSketchID: UUID

    init(state: CADFeaturePreviewState) {
        operation = state.operation
        profilePoints = state.profilePoints
        sourceReference = state.sourceReference
        targetBodyID = state.targetBodyID
        selectedProfileID = state.selectedProfileID
        depthMeters = state.depthMeters
        direction = state.direction
        depthMode = state.depthMode
        sourceSketchID = state.sourceSketchID
    }
}

// MARK: - Line Tool State Types

enum LineToolPhase: Equatable {
    case idle
    case waitingForStart
    case waitingForEnd(start: SketchPoint2D)
}

enum LineActiveParameter: Equatable {
    case startPoint
    case endPoint
    case length
    case angle
}

struct LineToolState: Equatable {
    var phase: LineToolPhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var activeParameter: LineActiveParameter = .startPoint
    var snapResult: CADSnapResult?

    var isActive: Bool { phase != .idle }

    var phantomStart: SketchPoint2D? {
        if case let .waitingForEnd(start) = phase { return start }
        return nil
    }

    var phantomEnd: SketchPoint2D? {
        guard case .waitingForEnd = phase else { return nil }
        return cursorPoint
    }

    var currentLengthMeters: Double? {
        guard let s = phantomStart else { return nil }
        return s.distance(to: cursorPoint)
    }

    var currentAngleDegrees: Double? {
        guard let s = phantomStart else { return nil }
        let du = cursorPoint.u - s.u
        let dv = cursorPoint.v - s.v
        guard abs(du) > 1e-6 || abs(dv) > 1e-6 else { return 0 }
        return atan2(dv, du) * 180.0 / Double.pi
    }
}

enum RectangleToolPhase: Equatable {
    case idle
    case waitingForFirstCorner
    case waitingForOppositeCorner(firstCorner: SketchPoint2D)
}

struct RectangleToolState: Equatable {
    var phase: RectangleToolPhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?

    var isActive: Bool { phase != .idle }

    var firstCorner: SketchPoint2D? {
        if case let .waitingForOppositeCorner(firstCorner) = phase { return firstCorner }
        return nil
    }

    var oppositeCorner: SketchPoint2D? {
        guard firstCorner != nil else { return nil }
        return cursorPoint
    }

    var widthMeters: Double? {
        guard let firstCorner else { return nil }
        return abs(cursorPoint.u - firstCorner.u)
    }

    var heightMeters: Double? {
        guard let firstCorner else { return nil }
        return abs(cursorPoint.v - firstCorner.v)
    }
}

enum CircleToolPhase: Equatable {
    case idle
    case waitingForCenter
    case waitingForRadius(center: SketchPoint2D)
}

struct CircleToolState: Equatable {
    var phase: CircleToolPhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?

    var isActive: Bool { phase != .idle }

    var center: SketchPoint2D? {
        if case let .waitingForRadius(center) = phase { return center }
        return nil
    }

    var radiusMeters: Double? {
        guard let center else { return nil }
        return center.distance(to: cursorPoint)
    }

    var diameterMeters: Double? {
        radiusMeters.map { $0 * 2 }
    }
}

// MARK: - Arc Tool State

enum ArcToolPhase: Equatable {
    case idle
    case waitingForStart
    case waitingForEnd(start: SketchPoint2D)
    case waitingForMid(start: SketchPoint2D, end: SketchPoint2D)
}

struct ArcToolState: Equatable {
    var phase: ArcToolPhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?

    var isActive: Bool { phase != .idle }

    var startPoint: SketchPoint2D? {
        switch phase {
        case let .waitingForEnd(start): return start
        case let .waitingForMid(start, _): return start
        default: return nil
        }
    }

    var endPoint: SketchPoint2D? {
        if case let .waitingForMid(_, end) = phase { return end }
        return nil
    }

    var phantomPoints: [SketchPoint2D]? {
        switch phase {
        case let .waitingForEnd(start):
            return [start, cursorPoint]
        case let .waitingForMid(start, end):
            let arc = SketchArc(start: start, end: end, midPoint: cursorPoint)
            let pts = arc.approximationPoints(segments: 32)
            return pts.isEmpty ? [start, cursorPoint, end] : pts
        default:
            return nil
        }
    }

    var chordLengthMeters: Double? {
        guard let s = startPoint else { return nil }
        switch phase {
        case .waitingForEnd: return s.distance(to: cursorPoint)
        case let .waitingForMid(_, end): return s.distance(to: end)
        default: return nil
        }
    }
}

// MARK: - Autoline Tool State

enum AutolineToolPhase: Equatable {
    case idle
    case drawing(points: [SketchPoint2D])
}

struct AutolineToolState: Equatable {
    var phase: AutolineToolPhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?

    var isActive: Bool { phase != .idle }

    var points: [SketchPoint2D] {
        if case let .drawing(pts) = phase { return pts }
        return []
    }

    var lastPoint: SketchPoint2D? { points.last }

    var segmentCount: Int { max(0, points.count - 1) }

    var currentLengthMeters: Double? {
        guard let last = lastPoint else { return nil }
        return last.distance(to: cursorPoint)
    }
}

// MARK: - Input Modes

enum RectangleInputMode: String, CaseIterable, Identifiable {
    case twoCorners
    case centerAndCorner
    case sizeFromFirstCorner

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .twoCorners:          return "cad.rect.mode.two_corners"
        case .centerAndCorner:     return "cad.rect.mode.center_corner"
        case .sizeFromFirstCorner: return "cad.rect.mode.size_first"
        }
    }
    var iconName: String {
        switch self {
        case .twoCorners:          return "rectangle.dashed"
        case .centerAndCorner:     return "rectangle.center.inset.filled"
        case .sizeFromFirstCorner: return "rectangle.leadinghalf.inset.filled"
        }
    }
}

enum CircleInputMode: String, CaseIterable, Identifiable {
    case radiusFromCenter
    case diameterTwoPoints

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .radiusFromCenter:    return "cad.circle.mode.radius"
        case .diameterTwoPoints:   return "cad.circle.mode.diameter"
        }
    }
}

struct CADWorkPlaneQuickAction: Equatable {
    var workPlane: CADWorkPlane
    var screenPoint: CGPoint
}

// MARK: - Construction Tool

enum ConstructionToolSubMode: String, CaseIterable, Identifiable {
    case segmentByTwoPoints
    case horizontalThroughPoint
    case verticalThroughPoint
    case pointAndAngle

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .segmentByTwoPoints:    return "cad.construction.mode.segment"
        case .horizontalThroughPoint: return "cad.construction.mode.horizontal"
        case .verticalThroughPoint:   return "cad.construction.mode.vertical"
        case .pointAndAngle:          return "cad.construction.mode.angle"
        }
    }

    var iconName: String {
        switch self {
        case .segmentByTwoPoints:    return "line.diagonal"
        case .horizontalThroughPoint: return "minus"
        case .verticalThroughPoint:   return "line.vertical"
        case .pointAndAngle:          return "angle"
        }
    }

    var isOneClick: Bool {
        switch self {
        case .segmentByTwoPoints: return false
        case .horizontalThroughPoint, .verticalThroughPoint, .pointAndAngle: return true
        }
    }
}

struct ConstructionToolState: Equatable {
    var subMode: ConstructionToolSubMode = .segmentByTwoPoints
    var firstPoint: SketchPoint2D?
    var cursorPoint: SketchPoint2D = .zero
    var angleDegrees: Double = 0
    var snapResult: CADSnapResult?

    var isActive: Bool { true }

    var phantomEndpoints: (SketchPoint2D, SketchPoint2D)? {
        let extent: Double = 5.0
        switch subMode {
        case .segmentByTwoPoints:
            guard let start = firstPoint else { return nil }
            return (start, cursorPoint)
        case .horizontalThroughPoint:
            let pt = firstPoint ?? cursorPoint
            return (SketchPoint2D(u: pt.u - extent, v: pt.v), SketchPoint2D(u: pt.u + extent, v: pt.v))
        case .verticalThroughPoint:
            let pt = firstPoint ?? cursorPoint
            return (SketchPoint2D(u: pt.u, v: pt.v - extent), SketchPoint2D(u: pt.u, v: pt.v + extent))
        case .pointAndAngle:
            let pt = firstPoint ?? cursorPoint
            let rad = angleDegrees * .pi / 180.0
            let dx = extent * cos(rad)
            let dy = extent * sin(rad)
            return (SketchPoint2D(u: pt.u - dx, v: pt.v - dy), SketchPoint2D(u: pt.u + dx, v: pt.v + dy))
        }
    }

    mutating func reset() {
        firstPoint = nil
        cursorPoint = .zero
        snapResult = nil
    }
}

enum DesignWorkshopToolMode: String, CaseIterable, Identifiable {
    case select
    case sketchLine
    case sketchAutoline
    case sketchRectangle
    case sketchCircle
    case sketchArc
    case sketchEdit
    case sketchConstruction
    case sketchMove
    case sketchCopy
    case sketchSplit
    case sketchTrim
    case sketchExtend
    case sketchParallel
    case sketchPerpendicular

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .select:               return "cad.tool.select"
        case .sketchLine:           return "cad.tool.line"
        case .sketchAutoline:       return "cad.tool.autoline"
        case .sketchRectangle:      return "cad.tool.rectangle"
        case .sketchCircle:         return "cad.tool.circle"
        case .sketchArc:            return "cad.tool.arc"
        case .sketchEdit:           return "cad.tool.sketch_edit"
        case .sketchConstruction:   return "cad.tool.construction"
        case .sketchMove:           return "cad.tool.move"
        case .sketchCopy:           return "cad.tool.copy"
        case .sketchSplit:          return "cad.tool.split"
        case .sketchTrim:           return "cad.tool.trim"
        case .sketchExtend:         return "cad.tool.extend"
        case .sketchParallel:       return "cad.tool.parallel"
        case .sketchPerpendicular:  return "cad.tool.perpendicular"
        }
    }

    var iconName: String {
        switch self {
        case .select:               return "cursorarrow"
        case .sketchLine:           return "line.diagonal"
        case .sketchAutoline:       return "scribble.variable"
        case .sketchRectangle:      return "rectangle"
        case .sketchCircle:         return "circle"
        case .sketchArc:            return "arc"
        case .sketchEdit:           return "pencil.line"
        case .sketchConstruction:   return "circle.dashed"
        case .sketchMove:           return "arrow.up.and.down.and.arrow.left.and.right"
        case .sketchCopy:           return "plus.square.on.square"
        case .sketchSplit:          return "scissors"
        case .sketchTrim:           return "minus.square"
        case .sketchExtend:         return "arrow.right.to.line"
        case .sketchParallel:       return "line.3.horizontal"
        case .sketchPerpendicular:  return "angle"
        }
    }

    var isSketchDrawingTool: Bool {
        switch self {
        case .sketchLine, .sketchAutoline, .sketchRectangle, .sketchCircle, .sketchArc, .sketchConstruction,
             .sketchParallel, .sketchPerpendicular:
            return true
        case .select, .sketchEdit, .sketchMove, .sketchCopy, .sketchSplit, .sketchTrim, .sketchExtend:
            return false
        }
    }

    var isSketchTool: Bool {
        switch self {
        case .sketchLine, .sketchAutoline, .sketchRectangle, .sketchCircle, .sketchArc, .sketchEdit,
             .sketchConstruction, .sketchMove, .sketchCopy, .sketchSplit, .sketchTrim, .sketchExtend,
             .sketchParallel, .sketchPerpendicular:
            return true
        case .select:
            return false
        }
    }
}

// MARK: - Modify Tool State Types

enum SketchMovePhase: Equatable {
    case idle
    case waitingForDestination(grabPoint: SketchPoint2D, original: SketchEntity)
}

struct SketchMoveToolState: Equatable {
    var phase: SketchMovePhase = .idle
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?
    var isCopy: Bool = false

    // Always active so that all canvas clicks route through handleMoveToolClick,
    // preventing the idle-phase click from being swallowed by onSketchLineSelected.
    var isActive: Bool { true }

    var phantomDelta: SketchPoint2D? {
        guard case let .waitingForDestination(grab, _) = phase else { return nil }
        return SketchPoint2D(u: cursorPoint.u - grab.u, v: cursorPoint.v - grab.v)
    }
}

enum SketchParallelPhase: Equatable {
    case waitingForSourceLine
    case waitingForThroughPoint(source: SketchLine)
}

struct SketchParallelToolState: Equatable {
    var phase: SketchParallelPhase = .waitingForSourceLine
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?
    var isPerpendicular: Bool = false

    var isActive: Bool { true }
}

struct SketchSplitToolState: Equatable {
    var cursorPoint: SketchPoint2D = .zero
    var snapResult: CADSnapResult?
    var phantomPoints: [SketchPoint2D]? = nil
    var hoveredEntityID: UUID? = nil
    var hoveredFromStart: Bool? = nil
    var pendingNewEndpoint: SketchPoint2D? = nil
    var isActive: Bool { true }
}

// MARK: - Trim / Extend Two-Phase Operation State

enum TrimExtendMode: Equatable {
    case target   // cursor-driven: projects cursor onto operation ray, snaps to intersections
    case numeric  // user-specified distance from numeric field
}

enum TrimExtendTargetType: Equatable {
    case none
    case cursorProjection  // fallback: cursor projected orthogonally onto operation ray/segment
    case intersection      // snapped to a real line-line intersection along the ray
    case snapVertex        // cursor snapped to a line endpoint near the ray
    case snapMidpoint      // cursor snapped to a midpoint near the ray
    case snapGrid          // cursor snapped to a grid point

    var labelKey: String {
        switch self {
        case .none:             return ""
        case .cursorProjection: return "cad.trim_extend.target_cursor"
        case .intersection:     return "cad.trim_extend.target_intersection"
        case .snapVertex:       return "cad.trim_extend.target_vertex"
        case .snapMidpoint:     return "cad.trim_extend.target_midpoint"
        case .snapGrid:         return "cad.trim_extend.target_grid"
        }
    }

    var iconName: String {
        switch self {
        case .none:             return "questionmark"
        case .cursorProjection: return "cursorarrow"
        case .intersection:     return "xmark.circle.fill"
        case .snapVertex:       return "smallcircle.filled.circle"
        case .snapMidpoint:     return "circle.lefthalf.filled"
        case .snapGrid:         return "grid"
        }
    }
}

enum TrimExtendValidation: Equatable {
    case valid
    case noTarget
    case distanceZero
    case distanceExceedsLength
    case zeroResultLength

    var isValid: Bool { self == .valid }

    var labelKey: String {
        switch self {
        case .valid:                 return "cad.trim_extend.status_valid"
        case .noTarget:              return "cad.trim_extend.status_no_target"
        case .distanceZero:          return "cad.trim_extend.status_distance_zero"
        case .distanceExceedsLength: return "cad.trim_extend.status_exceeds_length"
        case .zeroResultLength:      return "cad.trim_extend.status_zero_length"
        }
    }
}

struct TrimExtendOperationState: Equatable {
    var operationType: DesignWorkshopToolMode  // .sketchTrim or .sketchExtend
    var targetLineID: UUID
    var fromStart: Bool                         // which endpoint is the anchor (the moving end)
    var originalStart: SketchPoint2D
    var originalEnd: SketchPoint2D
    var anchorPoint: SketchPoint2D             // the selected (moving) endpoint — locked after click
    var oppositePoint: SketchPoint2D           // the fixed endpoint
    var mode: TrimExtendMode = .target
    var numericDistanceMM: Double = 0
    var candidateTargetPoint: SketchPoint2D? = nil
    var previewAnchorPoint: SketchPoint2D? = nil
    var isPreviewActive: Bool = false
    var validation: TrimExtendValidation = .noTarget
    var targetType: TrimExtendTargetType = .none
}

@MainActor
final class CADWorkshopViewModel: ObservableObject {

    // Stable UUID used as the asset ID for feature preview geometry — prevents spurious Equatable mismatches.
    static let featurePreviewSentinelID = UUID(uuidString: "FEA70000-0000-0000-0000-000000000000")!

    @Published private(set) var document: DesignDocument = DesignDocument() {
        didSet { rebuildProfileGraph() }
    }
    @Published private(set) var cadDocument: CADDocument = CADDocument()
    @Published var canvasOptions = DesignCanvasOptions()
    @Published var pendingCameraCommand: CADPreviewCameraCommand?
    @Published var autoFocusNewAssets: Bool = true
    @Published var selectedAttachmentPointID: UUID?
    @Published var selectedSketchLineID: UUID?
    @Published var selectedSketchEntityID: UUID?
    @Published var selectedSketchEntityIDs: Set<UUID> = []
    @Published var selectedFaceID: UUID?
    @Published var selectedCutFeatureID: UUID?
    @Published var selectedCutTargetBodyID: UUID?
    @Published var hoveredWorkPlaneID: String?
    @Published var selectedWorkPlane: CADWorkPlane?
    @Published var workPlaneQuickAction: CADWorkPlaneQuickAction?
    @Published var activeToolMode: DesignWorkshopToolMode = .select
    @Published var activeSketchPlane: SketchPlane = .xz
    @Published var activeSketchReference: SketchReference = .canonicalPlane(.xz, offsetMeters: 0)
    @Published var lineToolState: LineToolState = LineToolState()
    @Published var rectangleToolState: RectangleToolState = RectangleToolState()
    @Published var circleToolState: CircleToolState = CircleToolState()
    @Published var arcToolState: ArcToolState = ArcToolState()
    @Published var autolineToolState: AutolineToolState = AutolineToolState()
    @Published var constructionToolState: ConstructionToolState = ConstructionToolState()
    @Published var rectangleInputMode: RectangleInputMode = .twoCorners
    @Published var circleInputMode: CircleInputMode = .radiusFromCenter
    @Published var constructionMode: Bool = false
    @Published var cursorScreenPosition: CGPoint = .zero
    @Published var sketchMoveToolState: SketchMoveToolState = SketchMoveToolState()
    @Published var sketchParallelToolState: SketchParallelToolState = SketchParallelToolState()
    @Published var sketchSplitToolState: SketchSplitToolState = SketchSplitToolState()
    @Published var trimExtendOpState: TrimExtendOperationState? = nil
    @Published private(set) var sketchProfileGraph: SketchProfileGraph?
    @Published var selectedProfileAreaID: UUID?

    // Feature operation state (extrude / cut panel)
    @Published var featureOperation: CADFeatureOperation = .extrudeNewBody {
        didSet {
            featureApplyFailureReason = nil
            if oldValue.isCutV2 && !featureOperation.isCutV2 {
                clearAllTransientCADNodes(resetOperation: false)
            }
            // Through All is only meaningful for Cut — reset to Distance when switching to Extrude.
            if featureOperation == .extrudeNewBody && featureDepthMode == .throughAll {
                featureDepthMode = .distance
            }
            if featureOperation.isCutV2 && featureDirection == .symmetric {
                featureDirection = .positiveNormal
            }
            updateFeaturePreview()
        }
    }
    @Published var featureDepthMM: Double = 20.0 {
        didSet { updateFeaturePreview() }
    }
    @Published var featureDirection: ExtrudeDirection = .positiveNormal {
        didSet {
            if featureOperation.isCutV2 && featureDirection == .symmetric {
                featureDirection = oldValue == .negativeNormal ? .negativeNormal : .positiveNormal
                return
            }
            updateFeaturePreview()
        }
    }
    @Published var featureDepthMode: DepthMode = .distance {
        didSet { updateFeaturePreview() }
    }
    @Published var featureMaterial: DesignMaterial = .composite {
        didSet { updateFeaturePreview() }
    }
    @Published private(set) var featureValidation: CADFeatureValidation = .noProfile
    @Published private(set) var featurePreviewState: CADFeaturePreviewState?
    @Published private(set) var featureApplyFailureReason: CADFeatureValidation? = nil
    @Published private(set) var cutV1ApplyStatus: CADCutApplyStatus = .blocked
    @Published private(set) var lastCutApplyStatus: CADCutApplyStatus = .blocked
    @Published private(set) var lastCutApplyReason: String? = nil
    @Published private(set) var transientCutNodeCount: Int = 0
    @Published private(set) var cutterPreviewNodeCount: Int = 0
    @Published private(set) var bodyTransparentMaterialCount: Int = 0
    @Published private(set) var previewNodesRemovedAfterApply: Bool = false
    @Published var cadKernelRenderMode: CADKernelRenderMode = .kernelShadow
    @Published var allowValidatedIntersectingCutCommit: Bool = false
    @Published private(set) var lastKernelMeshCandidate: CADKernelMeshCandidate?

    @Published private(set) var viewportState: DesignViewportState = DesignViewportState()
    @Published private(set) var extrudeWarningKey: String?
    @Published private(set) var sketchWarningKey: String?

    // Direct-manipulation drag state (not @Published — updated frequently, triggers refreshViewportState separately)
    private var entityDragSnapshots: [UUID: SketchEntity] = [:]
    private var entityDragID: UUID?
    private var movePreviewDelta: SketchPoint2D?
    private var movePreviewEntityIDs: Set<UUID> = []
    private var activeBodyEditTransaction: CADBodyEditTransaction?
    private var cutPreviewCacheKey: CADCutPreviewCacheKey?
    private var cutPreviewRebuildCount = 0
    private var cutBooleanApplyCount = 0
    private var cutCommittedGeometryRebuildCount = 0
    private var kernelCandidateBuildCount = 0
    private var kernelCommitCount = 0
    private var kernelRejectCount = 0
    private var kernelShadowBuildCount = 0
    private var sceneGeometryReplacementCount = 0
    private var intersectingCutAttemptCount = 0
    private var intersectingCutCommitCount = 0
    private var intersectingCutRejectCount = 0
    // Sketch entity clipboard for Cmd+C / Cmd+V — supports multiple entities.
    private var sketchClipboard: [SketchEntity] = []

    var selectedAsset: DesignAsset? {
        document.selectedAsset
    }

    var selectedAssetID: UUID? {
        document.selectedAssetID
    }

    var selectedAttachmentPoint: AttachmentPoint? {
        guard let selectedAttachmentPointID else { return nil }
        return selectedAsset?.attachmentPoints.first { $0.id == selectedAttachmentPointID }
    }

    var selectedSketch: DesignSketch? {
        guard let selectedAsset,
              case let .sketch2D(parameters) = selectedAsset.kind else { return nil }
        return parameters.sketch
    }

    var selectedSketchLine: SketchLine? {
        guard let selectedSketchLineID else { return nil }
        return selectedSketch?.lines.first { $0.id == selectedSketchLineID }
    }

    var selectedSketchEntity: SketchEntity? {
        guard let selectedSketchEntityID else { return nil }
        return selectedSketch?.entity(with: selectedSketchEntityID)
    }

    var selectedSketchRectangle: SketchRectangle? {
        selectedSketchEntity?.rectangle
    }

    var selectedSketchCircle: SketchCircle? {
        selectedSketchEntity?.circle
    }

    var selectedSketchLineNumber: Int? {
        guard let selectedSketchLineID else { return nil }
        return selectedSketch?.lines.firstIndex { $0.id == selectedSketchLineID }.map { $0 + 1 }
    }

    var selectedSketchEntityNumber: Int? {
        guard let selectedSketchEntityID else { return nil }
        return selectedSketch?.entities.firstIndex { $0.id == selectedSketchEntityID }.map { $0 + 1 }
    }

    var selectedPlanarFace: DesignPlanarFace? {
        guard let selectedFaceID,
              let selectedAsset,
              case let .extrudedSolid(parameters) = selectedAsset.kind else { return nil }
        return parameters.faces.first { $0.id == selectedFaceID }
    }

    var isSelectedSketchPlaneLocked: Bool {
        selectedSketch?.hasGeometry == true || selectedSketch?.reference.isCanonical == false
    }

    /// True when the selected sketch has a valid profile area ready for extrusion.
    var canExtrudeWithSelectedProfile: Bool {
        guard let graph = sketchProfileGraph, !graph.isEmpty else { return false }
        if graph.count == 1 { return true }
        return selectedProfileAreaID != nil
    }

    var canApplyExtrudeFeature: Bool {
        validateFeatureOperation(operation: .extrudeNewBody, depthMode: .distance).isValid
    }

    var canPreviewCutV2Feature: Bool {
        validateFeatureOperation(operation: .cutRemoveMaterialV2).isValid
    }

    var canApplyCutV2Feature: Bool {
        cutCommitValidationResult.canCommit
    }

    var cutV2ApplyValidation: CADFeatureValidation {
        guard featureOperation == .cutRemoveMaterialV2 else { return .unsupportedOperation }
        guard featureValidation.isValid else { return featureValidation }
        guard let previewState = featurePreviewState,
              previewState.operation == .cutRemoveMaterialV2 else {
            return .noSelectedProfileArea
        }
        return validateCutV2Apply(state: previewState)
    }

    var cutCommitValidationResult: CutCommitValidationResult {
        buildCutCommitValidationResult()
    }

    var cutV2SelectedProfileDisplayName: String {
        guard let area = currentProfileArea() else {
            return localized("cad.cut_v2.profile.none")
        }
        let shortID = String(area.id.uuidString.prefix(8))
        return String(format: localized("cad.cut_v2.profile.selected_format"), shortID, area.areaMM2)
    }

    var cutV2ProfileTypeDisplayName: String {
        let type = cutV2ProfileType(for: currentProfileArea(), in: selectedSketch)
        return localized(type.displayNameKey)
    }

    var cutV2TargetBodyDisplayName: String {
        guard let targetID = cutTargetBodyID,
              let asset = document.assets.first(where: { $0.id == targetID }) else {
            return localized("cad.cut_v2.target.none")
        }
        return asset.name
    }

    var cutV2SketchPlaneDisplayName: String {
        guard let sketch = selectedSketch else { return "—" }
        switch sketch.reference {
        case .planarFace:
            return localized("cad.cut_v2.sketch_plane.face")
        case let .canonicalPlane(plane, _):
            return plane.displayName
        }
    }

    var cutV2PreviewStateDisplayName: String {
        let status: CADCutPreviewStatus
        if featureOperation != .cutRemoveMaterialV2 || featurePreviewState == nil {
            status = .notReady
        } else {
            status = featureValidation.isValid ? .ready : .invalid
        }
        return localized(status.displayNameKey)
    }

    var cutV2ApplyStateDisplayName: String {
        localized(cutV1ApplyStatus.displayNameKey)
    }

    var cutV2LastApplyStateDisplayName: String {
        localized(lastCutApplyStatus.displayNameKey)
    }

    var cutV2LastApplyReasonDisplayName: String {
        guard let lastCutApplyReason else {
            return localized("cad.cut_v2.commit.none")
        }
        return localized(lastCutApplyReason)
    }

    var cutCommitIntersectsExistingVoidDisplayName: String {
        localized(cutCommitValidationResult.intersectsExistingVoid
            ? "cad.cut_v2.commit.yes"
            : "cad.cut_v2.commit.no")
    }

    var cutCommitKernelValidationDisplayName: String {
        localized(cutCommitValidationResult.canCommit
            ? CADCutApplyStatus.supported.displayNameKey
            : CADCutApplyStatus.blocked.displayNameKey)
    }

    var cutCommitAllowedDisplayName: String {
        localized(cutCommitValidationResult.canCommit
            ? "cad.cut_v2.commit.yes"
            : "cad.cut_v2.commit.no")
    }

    var cutCommitFailureReasonDisplayName: String {
        guard let reason = cutCommitValidationResult.reason else {
            return localized("cad.cut_v2.commit.none")
        }
        return localized(reason)
    }

    var cutCommitBoundaryEdgesDisplayName: String {
        cutCommitValidationResult.boundaryEdgeCount.map(String.init)
            ?? localized("cad.cut_v2.commit.none")
    }

    var cutCommitBoundaryLoopsDisplayName: String {
        cutCommitValidationResult.boundaryLoopCount.map(String.init)
            ?? localized("cad.cut_v2.commit.none")
    }

    var cutCommitUISelectedBodyIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.uiSelectedBodyID)
    }

    var cutCommitKernelTargetBodyIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.kernelTargetBodyID)
    }

    var cutCommitApplyTargetBodyIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.applyTargetBodyID)
    }

    var cutCommitPreviewTargetBodyIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.previewTargetBodyID)
    }

    var cutCommitCommittedCutsCountDisplayName: String {
        String(currentCutDiagnosticsCommittedCutsCount)
    }

    var cutCommitCurrentBodyIDDisplayName: String {
        shortDebugID(cutTargetBodyID ?? document.selectedAssetID)
    }

    var cutCommitActiveSketchIDDisplayName: String {
        shortDebugID(selectedSketch?.id)
    }

    var cutCommitSelectedProfileTypeDisplayName: String {
        cutV2ProfileType(for: currentProfileArea(), in: selectedSketch).rawValue
    }

    var cutCommitAffectedFaceIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.affectedEntryFaceID ?? selectedFaceID)
    }

    var transientCutNodeCountDisplayName: String {
        String(transientCutNodeCount)
    }

    var cutterPreviewNodeCountDisplayName: String {
        String(cutterPreviewNodeCount)
    }

    var bodyTransparentMaterialCountDisplayName: String {
        String(bodyTransparentMaterialCount)
    }

    var previewNodesRemovedAfterApplyDisplayName: String {
        localized(previewNodesRemovedAfterApply
            ? "cad.cut_v2.commit.yes"
            : "cad.cut_v2.commit.no")
    }

    var cutCommitCandidateCutIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.candidateCutID)
    }

    var cutCommitAffectedEntryFaceIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.affectedEntryFaceID)
    }

    var cutCommitAffectedExitFaceIDDisplayName: String {
        shortDebugID(cutCommitValidationResult.affectedExitFaceID)
    }

    var cutCommitCutsOnEntryFaceDisplayName: String {
        String(cutCommitValidationResult.cutsOnEntryFace)
    }

    var cutCommitCutsOnExitFaceDisplayName: String {
        String(cutCommitValidationResult.cutsOnExitFace)
    }

    var cutCommitMultiCutValidationDisplayName: String {
        cutCommitValidationResult.multiCutValidationPassed
            ? "passed"
            : "blocked"
    }

    var cutCommitMeshVertexCountDisplayName: String {
        cutCommitValidationResult.meshVertexCount.map(String.init)
            ?? localized("cad.cut_v2.commit.none")
    }

    var cutCommitMeshTriangleCountDisplayName: String {
        cutCommitValidationResult.meshTriangleCount.map(String.init)
            ?? localized("cad.cut_v2.commit.none")
    }

    var cutCommitTrianglesInsideAnyHoleDisplayName: String {
        String(cutCommitValidationResult.trianglesInsideAnyHole)
    }

    var cutCommitCapFacesGeneratedDisplayName: String {
        String(cutCommitValidationResult.capFacesGenerated)
    }

    struct SelectedCutInspectorData: Equatable {
        var bodyID: UUID
        var cutID: UUID
        var displayIndex: Int
        var profileTypeName: String
        var depthModeName: String
        var depthMeters: Double
        var sourceSketchName: String
        var entryFaceDisplayName: String
    }

    var selectedCutInspectorData: SelectedCutInspectorData? {
        guard let bodyID = selectedCutTargetBodyID,
              let cutID = selectedCutFeatureID,
              let asset = document.assets.first(where: { $0.id == bodyID }),
              case let .extrudedSolid(params) = asset.kind,
              let index = params.boxBlindCutFeatures.firstIndex(where: { $0.id == cutID }) else {
            return nil
        }
        let cut = params.boxBlindCutFeatures[index]
        let face = params.faces.first(where: { $0.id == cut.entryFaceID })
        let faceName = face.map { "\($0.name) [\(shortDebugID($0.id))]" } ?? shortDebugID(cut.entryFaceID)
        return SelectedCutInspectorData(
            bodyID: bodyID,
            cutID: cut.id,
            displayIndex: index + 1,
            profileTypeName: localized(cut.profileType.displayNameKey),
            depthModeName: localized(cut.depthMode.displayNameKey),
            depthMeters: cut.depthMeters,
            sourceSketchName: cut.sourceSketchName,
            entryFaceDisplayName: faceName
        )
    }

    /// ID of the solid body to cut into. Returns the face's source asset when the sketch is on a body
    /// face, or auto-detects the first extruded solid whose source plane matches the sketch's canonical
    /// plane. Returns nil when no matching body exists.
    var cutTargetBodyID: UUID? {
        guard let sketch = selectedSketch else { return nil }

        // Sketch created by clicking on a body face — direct reference.
        if case let .planarFace(faceRef) = sketch.reference,
           document.assets.first(where: { $0.id == faceRef.sourceAssetID }) != nil {
            return faceRef.sourceAssetID
        }

        // Sketch on a canonical plane — find the first extruded solid whose source plane matches.
        if case let .canonicalPlane(sketchPlane, _) = sketch.reference {
            return document.assets.first(where: {
                if case let .extrudedSolid(p) = $0.kind { return p.sourcePlane == sketchPlane }
                return false
            })?.id
        }

        return nil
    }

    private func shortDebugID(_ id: UUID?) -> String {
        guard let id else { return "nil" }
        return String(id.uuidString.prefix(8))
    }

    /// Returns the CADCameraMode that looks normal to the active sketch plane, or nil when no sketch is selected.
    var viewOrientationForActiveSketch: CADCameraMode? {
        guard selectedSketch != nil else { return nil }
        return cameraMode(for: currentSketchReference().plane)
    }

    var activeSketchPlaneOffsetMeters: Double {
        guard let selectedAsset,
              case let .sketch2D(parameters) = selectedAsset.kind else { return 0 }
        return parameters.planeOffsetMeters
    }

    var activeCoordinateReference: SketchReference {
        currentSketchReference()
    }

    // MARK: Create

    func createBasicWing() {
        addNewAsset(kind: .basicWing(BasicWingParameters()), baseName: localized("cad.kind.basic_wing"))
    }

    func createFramePlate() {
        addNewAsset(kind: .framePlate(FramePlateParameters()), baseName: localized("cad.kind.frame_plate"))
    }

    func createBeam() {
        addNewAsset(kind: .beam(BeamParameters()), baseName: localized("cad.kind.beam"))
    }

    func createTube() {
        addNewAsset(kind: .tube(TubeParameters()), baseName: localized("cad.kind.tube"))
    }

    func createMountBracket() {
        addNewAsset(kind: .mountBracket(MountBracketParameters()), baseName: localized("cad.kind.mount_bracket"))
    }

    func createPayloadBox() {
        addNewAsset(kind: .payloadBox(PayloadBoxParameters()), baseName: localized("cad.kind.payload_box"))
    }

    func extrudeSelectedSketch(
        depthMeters: Double,
        direction: ExtrudeDirection,
        material: DesignMaterial
    ) {
        guard let asset = document.selectedAsset,
              case let .sketch2D(parameters) = asset.kind else {
            extrudeWarningKey = "cad.extrude.unsupported_contour"
            return
        }

        // Use the selected profile area when available; fall back to single-profile extraction.
        let profilePoints: [SketchPoint2D]
        if let areaID = selectedProfileAreaID,
           let area = sketchProfileGraph?.area(with: areaID),
           area.isExtrudable {
            profilePoints = area.outerLoop
        } else {
            let profileResult = parameters.sketch.orderedProfilePointsForExtrude()
            guard case let .success(pts) = profileResult else {
                if case let .failure(error) = profileResult {
                    extrudeWarningKey = error.messageKey
                } else {
                    extrudeWarningKey = ExtrudeValidationIssue.insufficientPoints.messageKey
                }
                return
            }
            profilePoints = pts
        }

        let solidID = UUID()
        let solidParams = ExtrudedSolidParameters(
            assetID: solidID,
            sourceSketchID: parameters.sketch.id,
            sourceSketchName: parameters.sketch.name,
            profilePoints: profilePoints,
            sourceReference: parameters.sketch.reference,
            depthMeters: clampFinite(depthMeters, to: 0.001...5.0),
            direction: direction,
            material: material
        )
        let solid = DesignAsset(
            id: solidID,
            name: uniqueNumberedName(base: localized("cad.kind.extruded_solid")),
            kind: sanitizedKind(.extrudedSolid(solidParams)),
            material: material
        )

        document.addAsset(solid)
        selectedAttachmentPointID = solid.attachmentPoints.first?.id
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        selectedFaceID = nil
        activeToolMode = .select
        resetDrawingToolStates(activating: nil)
        extrudeWarningKey = nil
        requestViewPreset(.iso, focus: .asset(solid.id))
    }

    // MARK: - Feature Operation (Extrude/Cut)

    func updateFeaturePreview() {
        let validation = validateFeatureOperation()
        featureValidation = validation
        featureApplyFailureReason = nil
        guard validation.isValid,
              let sketch = selectedSketch,
              let profileArea = currentProfileArea() else {
            if featureOperation.isCutV2 {
                rollbackCutV2Transaction()
                if cutPreviewCacheKey != nil || featurePreviewState != nil {
                    cutPreviewCacheKey = nil
                    cutPreviewRebuildCount += 1
                    logCutV2PreviewRebuild(validation: validation, previewState: nil)
                }
            }
            featurePreviewState = nil
            if featureOperation.isCutV2 {
                cutV1ApplyStatus = .blocked
                lastCutApplyStatus = .blocked
                lastCutApplyReason = validation.messageKey
                transientCutNodeCount = 0
                cutterPreviewNodeCount = 0
            }
            refreshViewportState()
            return
        }
        if featureOperation.isCutV2 {
            let build = makeCurrentCutRequest()
            guard let request = build.request,
                  let targetAsset = document.assets.first(where: { $0.id == request.targetBodyID }) else {
                featurePreviewState = nil
                cutV1ApplyStatus = .blocked
                lastCutApplyStatus = .blocked
                lastCutApplyReason = build.validation.messageKey
                transientCutNodeCount = 0
                cutterPreviewNodeCount = 0
                logCutV2PreviewRebuild(validation: build.validation, previewState: nil)
                refreshViewportState()
                return
            }
            beginCutV2Transaction(
                targetBodyID: request.targetBodyID,
                bodyParams: request.targetBodyGeometry,
                bodyMaterial: targetAsset.material,
                bodyTransform: targetAsset.transform,
                selectedProfileID: profileArea.id,
                sketchReference: sketch.reference
            )
            let previewState = CADCutPreviewBuilder.buildPreview(request)
            let nextKey = CADCutPreviewCacheKey(state: previewState)
            if cutPreviewCacheKey == nextKey,
               featurePreviewState == previewState {
                return
            }
            cutPreviewCacheKey = nextKey
            cutPreviewRebuildCount += 1
            cutV1ApplyStatus = .supported
            lastCutApplyStatus = .supported
            lastCutApplyReason = nil
            transientCutNodeCount = 1
            cutterPreviewNodeCount = 1
            bodyTransparentMaterialCount = 0
            previewNodesRemovedAfterApply = false
            featurePreviewState = previewState
            logCutV2PreviewRebuild(validation: .valid, previewState: previewState)
            refreshViewportState()
            return
        } else {
            activeBodyEditTransaction = nil
            cutPreviewCacheKey = nil
        }
        let depthM = clampFinite(featureDepthMM, to: 1...5000) / 1000.0
        let previewState = CADFeaturePreviewState(
            operation: featureOperation,
            profilePoints: profileArea.outerLoop,
            sourceReference: sketch.reference,
            targetBodyID: featureOperation.isCutV2 ? cutTargetBodyID : nil,
            selectedProfileID: profileArea.id,
            depthMeters: depthM,
            direction: featureDirection,
            depthMode: featureDepthMode,
            material: featureMaterial,
            sourceSketchID: sketch.id,
            sourceSketchName: sketch.name
        )
        featurePreviewState = previewState
        refreshViewportState()
    }

    func cancelFeaturePreview() {
        clearAllTransientCADNodes(resetOperation: false)
        refreshViewportState()
    }

    func applyFeatureOperation() {
        guard featureValidation.isValid,
              let previewState = featurePreviewState else { return }

        switch previewState.operation {
        case .extrudeNewBody:
            applyExtrudeNewBody(previewState)
        case .extrudeAddMaterial:
            featureApplyFailureReason = .unsupportedOperation
        case .cutRemoveMaterialV2:
            applyCutRemoveMaterialV2(previewState)
            if featureApplyFailureReason != nil {
                refreshViewportState()
                return
            }
        case .cutRemoveMaterial:
            featureApplyFailureReason = .unsupportedOperation
        }

        featurePreviewState = nil
        cutPreviewCacheKey = nil
        extrudeWarningKey = nil
        refreshViewportState()
    }

    private func applyExtrudeNewBody(_ state: CADFeaturePreviewState) {
        let solidID = UUID()
        let record = CADFeatureRecord(
            featureID: UUID(),
            operation: .extrudeNewBody,
            sourceSketchID: state.sourceSketchID,
            sourceSketchName: state.sourceSketchName,
            depthMeters: state.depthMeters,
            direction: state.direction,
            depthMode: state.depthMode,
            timestamp: Date()
        )
        var solidParams = ExtrudedSolidParameters(
            assetID: solidID,
            sourceSketchID: state.sourceSketchID,
            sourceSketchName: state.sourceSketchName,
            profilePoints: state.profilePoints,
            sourceReference: state.sourceReference,
            depthMeters: state.depthMeters,
            direction: state.direction,
            material: state.material,
            featureRecord: record
        )
        if cadKernelRenderMode != .conservativeLegacy {
            let solid = CADLimitedSolidKernel.makeSolid(id: solidID, from: solidParams)
            let candidate = buildKernelMeshCandidate(
                bodyID: solidID,
                solid: solid,
                featureID: record.featureID,
                operationType: .extrudeAdd,
                legacyParams: solidParams,
                legacyCommitted: cadKernelRenderMode != .kernelCommitValidated
            )
            if cadKernelRenderMode == .kernelCommitValidated,
               candidate.validationResult.isValid {
                solidParams.kernelVisualMesh = candidate.mesh
                kernelCommitCount += 1
                sceneGeometryReplacementCount += 1
                logKernelMeshCandidate(
                    candidate,
                    operationType: .extrudeAdd,
                    legacyParams: solidParams,
                    legacyCommitted: false,
                    kernelCommitted: true
                )
            } else if cadKernelRenderMode == .kernelCommitValidated {
                featureApplyFailureReason = .kernelCandidateValidationFailed
                return
            }
        }
        let solid = DesignAsset(
            id: solidID,
            name: uniqueNumberedName(base: localized("cad.kind.extruded_solid")),
            kind: sanitizedKind(.extrudedSolid(solidParams)),
            material: state.material
        )
        document.addAsset(solid)
        recordCADExtrudeNewBody(
            asset: solid,
            params: solidParams,
            state: state,
            featureRecord: record
        )
        selectedAttachmentPointID = solid.attachmentPoints.first?.id
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        selectedFaceID = nil
        activeToolMode = .select
        resetDrawingToolStates(activating: nil)
        requestViewPreset(.iso, focus: .asset(solid.id))
    }

    private func applyCutRemoveMaterialV2(_ state: CADFeaturePreviewState) {
        let build = makeCurrentCutRequest(depthMode: state.depthMode)
        guard let request = build.request else {
            featureApplyFailureReason = build.validation
            cutV1ApplyStatus = .blocked
            lastCutApplyStatus = .blocked
            lastCutApplyReason = build.validation.messageKey
            return
        }
        guard let targetAsset = document.assets.first(where: { $0.id == request.targetBodyID }) else {
            featureApplyFailureReason = .noCutTarget
            cutV1ApplyStatus = .blocked
            lastCutApplyStatus = .blocked
            lastCutApplyReason = CADFeatureValidation.noCutTarget.messageKey
            return
        }
        let bodyCountBefore = committedBodyCount
        let previewNodeCountBeforeApply = activeCutTemporaryNodeCount
        cutBooleanApplyCount += 1
        logCutV2Counters(reason: "apply-start")

        let beforeBounds = CADAxisAlignedBounds(points: request.targetBodyGeometry.vertices())
        let commitResult: CADCutCommitResult
        switch CADCutCommitEngine.commit(request) {
        case let .success(result):
            commitResult = result
        case let .failure(reason):
            featureApplyFailureReason = reason
            cutV1ApplyStatus = .blocked
            lastCutApplyStatus = .blocked
            lastCutApplyReason = reason.messageKey
            return
        }

        var updatedAsset = targetAsset
        updatedAsset.kind = .extrudedSolid(commitResult.bodyParams)
        updatedAsset.updateDerivedProperties()
        document.updateAsset(updatedAsset)
        recordCADCut(
            targetAsset: updatedAsset,
            resultParams: commitResult.bodyParams,
            appliedCut: commitResult.feature,
            state: state,
            validation: .valid
        )
        cutCommittedGeometryRebuildCount += 1
        sceneGeometryReplacementCount += 1

        logCutV2ApplyAfter(
            resultParams: commitResult.bodyParams,
            resultMeshStats: (
                vertexCount: commitResult.mesh.vertices.count,
                triangleCount: commitResult.mesh.triangles.count
            ),
            beforeBounds: beforeBounds,
            resultBounds: CADAxisAlignedBounds(points: commitResult.mesh.vertices),
            bodyCountBefore: bodyCountBefore,
            bodyCountAfter: committedBodyCount,
            removedPreviewNodeCount: previewNodeCountBeforeApply,
            appendedFeatureID: commitResult.feature.id,
            rebuildDiagnostics: commitResult.rebuildDiagnostics,
            multiCutValidation: commitResult.multiCutValidation
        )

        finishSuccessfulCutV2Apply(targetBodyID: request.targetBodyID)
        cutV1ApplyStatus = .committed
        lastCutApplyStatus = .committed
        lastCutApplyReason = nil
        recordCutCleanupGuard(previewNodesRemoved: previewNodeCountBeforeApply > 0)
    }

    private func finishSuccessfulCutV2Apply(targetBodyID: UUID) {
        activeBodyEditTransaction = nil
        cutPreviewCacheKey = nil
        featurePreviewState = nil
        featureApplyFailureReason = nil
        cutV1ApplyStatus = .blocked
        selectedProfileAreaID = nil
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        selectedSketchEntityIDs = []
        selectedAttachmentPointID = nil
        selectedFaceID = nil
        selectedWorkPlane = nil
        hoveredWorkPlaneID = nil
        activeToolMode = .select
        resetDrawingToolStates(activating: nil)
        trimExtendOpState = nil
        featureValidation = .noProfile
        extrudeWarningKey = nil
        sketchWarningKey = nil
        document.selectAsset(targetBodyID)
    }

    private func recordCADExtrudeNewBody(
        asset: DesignAsset,
        params: ExtrudedSolidParameters,
        state: CADFeaturePreviewState,
        featureRecord: CADFeatureRecord
    ) {
        let solid = CADLimitedSolidKernel.makeSolid(id: asset.id, from: params)
        let feature = CADFeature(
            id: featureRecord.featureID,
            type: .extrudeAdd,
            targetBodyID: asset.id,
            sourceSketchID: state.sourceSketchID,
            sourceProfileID: state.selectedProfileID,
            createdVolumeID: solid.additiveVolumes.first?.id,
            parameters: CADFeatureParameters(
                depthMeters: state.depthMeters,
                depthMode: state.depthMode,
                direction: state.direction,
                profileKind: .polygon
            ),
            timestamp: featureRecord.timestamp,
            order: cadDocument.features.count,
            validationResult: .valid(debugDetails: ["source=applyExtrudeNewBody"])
        )
        let body = CADBody(
            id: asset.id,
            name: asset.name,
            solid: solid,
            materialID: asset.material,
            visualMeshCache: solid.visualMeshCache,
            featureHistory: [feature.id]
        )
        cadDocument.bodies.append(body)
        cadDocument.features.append(feature)
        cadDocument.sketches = currentCADSketches()
        cadDocument.activeBodyID = asset.id
        cadDocument.activeSketchID = state.sourceSketchID
        logCADApply(
            operationType: .extrudeAdd,
            targetBodyID: asset.id,
            profileKind: .polygon,
            depthMode: state.depthMode,
            direction: state.direction,
            beforeSolid: nil,
            afterSolid: solid,
            validationResult: feature.validationResult,
            committed: true,
            previewNodesRemoved: 0
        )
    }

    private func recordCADCut(
        targetAsset: DesignAsset,
        resultParams: ExtrudedSolidParameters,
        appliedCut: ExtrudedSolidBoxBlindCutFeature,
        state: CADFeaturePreviewState,
        validation: CADFeatureValidation
    ) {
        guard validation.isValid else { return }
        let recordedSolid = cutV1RecordedSolid(id: targetAsset.id, resultParams: resultParams)
        let visualMeshCache = recordedSolid.visualMeshCache
        let validationResult = CADOperationValidationResult.valid(debugDetails: [
            "source=applyCutRemoveMaterialV2",
            "createdVolumeID=\(appliedCut.id.uuidString)"
        ])
        let feature = CADFeature(
            id: appliedCut.id,
            type: .extrudeCut,
            targetBodyID: targetAsset.id,
            sourceSketchID: appliedCut.sourceSketchID,
            sourceProfileID: appliedCut.selectedProfileID,
            createdVolumeID: appliedCut.id,
            parameters: CADFeatureParameters(
                depthMeters: appliedCut.depthMeters,
                depthMode: appliedCut.depthMode,
                direction: appliedCut.direction,
                profileKind: appliedCut.profileType
            ),
            timestamp: Date(),
            order: cadDocument.features.count,
            validationResult: validationResult
        )
        if let bodyIndex = cadDocument.bodies.firstIndex(where: { $0.id == targetAsset.id }) {
            cadDocument.bodies[bodyIndex].solid = recordedSolid
            cadDocument.bodies[bodyIndex].materialID = targetAsset.material
            cadDocument.bodies[bodyIndex].visualMeshCache = visualMeshCache
            cadDocument.bodies[bodyIndex].featureHistory.append(feature.id)
        } else {
            cadDocument.bodies.append(
                CADBody(
                    id: targetAsset.id,
                    name: targetAsset.name,
                    solid: recordedSolid,
                    materialID: targetAsset.material,
                    visualMeshCache: visualMeshCache,
                    featureHistory: [feature.id]
                )
            )
        }
        cadDocument.features.append(feature)
        cadDocument.sketches = currentCADSketches()
        cadDocument.activeBodyID = targetAsset.id
        cadDocument.activeSketchID = appliedCut.sourceSketchID
        print(
            "CAD Cut V1 Apply: " +
            "targetBodyID=\(targetAsset.id.uuidString) " +
            "profileKind=\(appliedCut.profileType.rawValue) " +
            "depthMode=\(appliedCut.depthMode.rawValue) " +
            "committed=true " +
            "previewNodesRemoved=\(activeCutTemporaryNodeCount)"
        )
        _ = state
    }

    private func cutV1RecordedSolid(
        id: UUID,
        resultParams: ExtrudedSolidParameters
    ) -> CADSolid {
        let mesh = resultParams.kernelVisualMesh
        let diagnostics = mesh.map { CADSolidMeshValidator.diagnose($0) }
        let bounds = mesh.flatMap { CADSolidBounds(points: $0.vertices) }
        let meshCache = CADVisualMeshCache(
            mesh: mesh,
            diagnostics: diagnostics,
            generationVersion: resultParams.boxBlindCutFeatures.count + 1
        )
        let validation = diagnostics?.isClosedManifold == false
            ? CADOperationValidationResult.invalid(
                .topologyValidationFailed,
                message: "Cut V1 mesh rebuild produced invalid topology"
            )
            : CADOperationValidationResult.valid(debugDetails: ["source=CADCutCommitEngine"])
        return CADSolid(
            id: id,
            additiveVolumes: [],
            cutterVolumes: [],
            evaluatedState: CADSolidEvaluatedState(
                materialRuleVersion: 1,
                additiveVolumeCount: 0,
                cutterVolumeCount: resultParams.boxBlindCutFeatures.count,
                boundingBox: bounds,
                estimatedVolumeMeters3: resultParams.volumeMeters3,
                validationState: validation
            ),
            evaluatedBounds: bounds,
            validationState: validation,
            generationVersion: resultParams.boxBlindCutFeatures.count + 1,
            legacyPrismaticRepresentation: CADPrismaticSolidRepresentation(
                baseProfile: resultParams.profilePoints,
                sourceReference: resultParams.sourceReference,
                depthMeters: resultParams.depthMeters,
                direction: resultParams.direction,
                faces: resultParams.faces,
                removedVolumes: []
            ),
            visualMeshCache: meshCache
        )
    }

    private func currentCADSketches() -> [DesignSketch] {
        document.assets.compactMap { asset in
            guard case let .sketch2D(parameters) = asset.kind else { return nil }
            return parameters.sketch
        }
    }

    private func cadOperationValidationResult(
        from validation: CADFeatureValidation
    ) -> CADOperationValidationResult {
        guard !validation.isValid else { return .valid() }
        let reason: CADOperationValidationReasonCode
        switch validation {
        case .noCutTarget:
            reason = .noTargetBody
        case .noProfile, .noActiveSketch, .noSelectedProfileArea:
            reason = .noSelectedProfile
        case .invalidProfileLoop:
            reason = .profileNotClosed
        case .invalidDepth, .insufficientDepth, .unsupportedDepthMode:
            reason = .invalidDepth
        case .cutNormalMisaligned, .invalidSketchPlaneFrame:
            reason = .invalidDirection
        case .cutToolDoesNotIntersectBody, .cutVolumeOutsideTarget, .profileOutsideFace:
            reason = .cutterDoesNotIntersectBody
        case .unsupportedProfileForCutV2:
            reason = .unsupportedProfileKind
        case .cutIntersectsExistingVoidUnsupported:
            reason = .unsupportedIntersectingCutUntilSolidKernelV02
        case .sameFaceIntersectingCutsDifferentDepthUnsupported,
             .distanceThroughAllIntersectionUnsupported,
             .crossFaceIntersectingCutUnsupported:
            reason = .unsupportedIntersectingCutUntilSolidKernelV02
        case .cutResultNotSolid,
             .cutResultBoundsInvalid,
             .cutBooleanInvalidResult,
             .cutMissingCylindricalWall,
             .cutMissingInternalWall,
             .cutMissingBlindBottom,
             .cutMissingExitOpening,
             .unaffectedGeometryWasRemoved,
             .cutVisibleTriangulationArtifact,
             .invalidEntryFaceTriangulation,
             .cutBooleanFailed,
             .kernelCandidateValidationFailed,
             .profileUnionFailed,
             .generatedMeshEmpty:
            reason = .topologyValidationFailed
        case .kernelCommitUnsupportedForCase:
            reason = .unsupportedIntersectionCaseV04
        case .intersectingCutSupportedPendingValidation:
            reason = .none
        case .intersectingCutValidationFailed,
             .kernelCandidateInvalid,
             .trimLoopResolutionFailed,
             .boundaryFragmentValidationFailed,
             .internalOrphanFaceDetected:
            reason = .topologyValidationFailed
        case .unsupportedIntersectingCutCase:
            reason = .unsupportedIntersectionCaseV04
        case .volumeRuleFailedAfterCut:
            reason = .topologyValidationFailed
        case .targetBodyNotSolid,
             .sketchNotOnFace,
             .unsupportedOperation:
            reason = .cadSolidRecordingFailed
        case .valid:
            reason = .none
        }
        return .invalid(
            reason,
            message: validation.messageKey ?? reason.rawValue,
            debugDetails: ["cadFeatureValidation=\(validation)"]
        )
    }

    @available(*, deprecated, message: "Legacy Cut is disabled. Use applyCutRemoveMaterialV2.")
    private func applyCutRemoveMaterialLegacyDisabled(_ state: CADFeaturePreviewState) {
        _ = state
        featureApplyFailureReason = .unsupportedOperation
    }

    private func validateFeatureOperation(
        operation operationOverride: CADFeatureOperation? = nil,
        depthMode depthModeOverride: DepthMode? = nil
    ) -> CADFeatureValidation {
        let operation = operationOverride ?? featureOperation
        let depthMode = depthModeOverride ?? featureDepthMode
        switch operation {
        case .extrudeNewBody:
            guard currentProfileArea() != nil else { return .noProfile }
            let depth = clampFinite(featureDepthMM, to: 0...Double.infinity)
            guard depth >= 1.0 else { return .insufficientDepth }
            return .valid
        case .cutRemoveMaterialV2:
            return validateCutV2Preview(depthMode: depthMode)
        case .extrudeAddMaterial, .cutRemoveMaterial:
            return .unsupportedOperation
        }
    }

    private func makeCurrentCutRequest(depthMode: DepthMode? = nil) -> (request: CADCutRequest?, validation: CADFeatureValidation) {
        guard let sketch = selectedSketch else { return (nil, .noActiveSketch) }
        guard let profileArea = currentProfileArea() else { return (nil, .noSelectedProfileArea) }
        guard !profileArea.hasHoles else { return (nil, .unsupportedProfileForCutV2) }
        guard validateProfileLoop(profileArea.outerLoop) else { return (nil, .invalidProfileLoop) }
        let profileType = cutV2ProfileType(for: profileArea, in: sketch)
        guard profileType == .rectangle || profileType == .circle else {
            return (nil, .unsupportedProfileForCutV2)
        }
        guard let targetID = cutTargetBodyID,
              let targetAsset = document.assets.first(where: { $0.id == targetID }),
              case let .extrudedSolid(bodyParams) = targetAsset.kind else {
            return (nil, .noCutTarget)
        }
        guard validateSketchPlaneFrame(sketch.reference) else { return (nil, .invalidSketchPlaneFrame) }
        guard let entryFace = cutV2EntryFace(
            sourceReference: sketch.reference,
            targetBodyID: targetID,
            bodyParams: bodyParams
        ) else {
            return (nil, .sketchNotOnFace)
        }
        let resolvedDepthMode = depthMode ?? featureDepthMode
        guard resolvedDepthMode == .distance || resolvedDepthMode == .throughAll else {
            return (nil, .unsupportedDepthMode(resolvedDepthMode))
        }

        let faceU = entryFace.uAxis.normalized(fallback: .xAxis)
        let faceV = entryFace.vAxis.normalized(fallback: .yAxis)
        let faceLocalProfile = profileArea.outerLoop.map { point -> SketchPoint2D in
            let world = sketchPointToWorld(point, reference: sketch.reference)
            let delta = world - entryFace.origin
            return SketchPoint2D(u: delta.dot(faceU), v: delta.dot(faceV))
        }
        guard validateProfileLoop(faceLocalProfile) else { return (nil, .invalidProfileLoop) }

        let cutDirection = CADCutRequest.inwardCutDirection(
            entryFaceNormal: entryFace.normal,
            entryFaceCenter: entryFace.center,
            bodyWorldVertices: bodyParams.vertices()
        )
        guard let thickness = CADCutGeometry.bodyThickness(
            entryFaceCenter: entryFace.center,
            bodyWorldVertices: bodyParams.vertices(),
            direction: cutDirection
        ) else {
            return (nil, .cutToolDoesNotIntersectBody)
        }
        let depthMeters: Double
        if resolvedDepthMode == .throughAll {
            depthMeters = thickness
        } else {
            let depth = clampFinite(featureDepthMM, to: 0...5000) / 1000.0
            guard depth > CADCutGeometry.epsilon else { return (nil, .invalidDepth) }
            depthMeters = depth
        }

        let circleMetrics = profileType == .circle
            ? cutV1CircleMetrics(profileArea: profileArea, sketch: sketch, entryFace: entryFace, localProfile: faceLocalProfile)
            : nil
        let request = CADCutRequest(
            targetBodyID: targetID,
            targetBodyGeometry: bodyParams,
            entryFaceID: entryFace.id,
            entryFaceOrigin: entryFace.origin,
            entryFaceCenter: entryFace.center,
            entryFaceNormal: entryFace.normal,
            entryFaceUAxis: entryFace.uAxis,
            entryFaceVAxis: entryFace.vAxis,
            entryFaceBounds: entryFace.bounds,
            sourceSketchReference: sketch.reference,
            profileType: profileType,
            profilePoints: faceLocalProfile,
            profileCenter: circleMetrics?.center,
            profileRadius: circleMetrics?.radius,
            depthMode: resolvedDepthMode,
            depthMeters: depthMeters,
            cutDirectionWorld: cutDirection,
            sourceSketchID: sketch.id,
            sourceSketchName: sketch.name,
            selectedProfileID: profileArea.id
        )
        let validation = CADCutValidator.validate(request)
        return (validation.isValid ? request : nil, validation)
    }

    private func validateCutV2Preview(depthMode: DepthMode? = nil) -> CADFeatureValidation {
        makeCurrentCutRequest(depthMode: depthMode).validation
    }

    private func cutV1CircleMetrics(
        profileArea: SketchProfileArea,
        sketch: DesignSketch,
        entryFace: DesignPlanarFace,
        localProfile: [SketchPoint2D]
    ) -> (center: SketchPoint2D, radius: Double)? {
        let faceU = entryFace.uAxis.normalized(fallback: .xAxis)
        let faceV = entryFace.vAxis.normalized(fallback: .yAxis)
        for entity in sketch.entities where entity.constructionStyle == .main {
            guard case let .circle(circle) = entity,
                  circle.isValidProfile,
                  loopsMatch(profileArea.outerLoop, circle.profilePoints()) else {
                continue
            }
            let worldCenter = sketchPointToWorld(circle.center, reference: sketch.reference)
            let delta = worldCenter - entryFace.origin
            return (SketchPoint2D(u: delta.dot(faceU), v: delta.dot(faceV)), circle.radiusMeters)
        }
        guard let center = CADCutGeometry.profileCenter(localProfile) else { return nil }
        let radius = localProfile.map { $0.distance(to: center) }.reduce(0, +) / Double(max(localProfile.count, 1))
        return (center, radius)
    }

    // Axis-aligned bounding box of a 2D polygon in sketch space.
    private func sketchBounds(_ pts: [SketchPoint2D]) -> (minU: Double, maxU: Double, minV: Double, maxV: Double) {
        let us = pts.map(\.u)
        let vs = pts.map(\.v)
        return (us.min() ?? 0, us.max() ?? 0, vs.min() ?? 0, vs.max() ?? 0)
    }

    // Shoelace signed area (abs value = area m², positive = CCW).
    private func sketchPolygonArea(_ pts: [SketchPoint2D]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var sum = 0.0
        let n = pts.count
        for i in 0..<n {
            let j = (i + 1) % n
            sum += pts[i].u * pts[j].v - pts[j].u * pts[i].v
        }
        return abs(sum * 0.5)
    }

    // True when the two axis-aligned bounding boxes overlap (or touch).
    private func sketchBoundsIntersect(
        _ a: (minU: Double, maxU: Double, minV: Double, maxV: Double),
        _ b: (minU: Double, maxU: Double, minV: Double, maxV: Double)
    ) -> Bool {
        a.minU <= b.maxU && a.maxU >= b.minU && a.minV <= b.maxV && a.maxV >= b.minV
    }

    private func cutToolBounds(for state: CADFeaturePreviewState) -> CADAxisAlignedBounds? {
        guard state.operation.isCutV2,
              state.depthMeters.isFinite,
              state.depthMeters > 0,
              state.direction == .positiveNormal || state.direction == .negativeNormal else {
            return nil
        }
        let normal = normalVector(for: state.sourceReference).normalized(fallback: .zAxis)
        let (frontOff, backOff) = state.direction.offsets(depth: state.depthMeters)
        let points = state.profilePoints.flatMap { point -> [DesignVector3] in
            let base = sketchPointToWorld(point, reference: state.sourceReference)
            return [
                base + normal * frontOff,
                base + normal * backOff,
            ]
        }
        return CADAxisAlignedBounds(points: points)
    }

    private func cutV2ProfileType(
        for area: SketchProfileArea?,
        in sketch: DesignSketch?
    ) -> CADCutV2ProfileType {
        guard let area,
              let sketch,
              !area.hasHoles,
              validateProfileLoop(area.outerLoop) else {
            return .unsupported
        }

        for entity in sketch.entities where entity.constructionStyle == .main {
            switch entity {
            case let .circle(circle) where circle.isValidProfile:
                if loopsMatch(area.outerLoop, circle.profilePoints()) { return .circle }
            case let .rectangle(rectangle) where rectangle.isValidProfile:
                if loopsMatch(area.outerLoop, rectangle.corners) { return .rectangle }
            default:
                break
            }
        }
        return .polygon
    }

    private func loopsMatch(
        _ lhs: [SketchPoint2D],
        _ rhs: [SketchPoint2D],
        tolerance: Double = 1e-5
    ) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }

        func matches(reversed: Bool, offset: Int) -> Bool {
            for index in lhs.indices {
                let rhsIndex: Int
                if reversed {
                    rhsIndex = (offset - index + rhs.count) % rhs.count
                } else {
                    rhsIndex = (offset + index) % rhs.count
                }
                if lhs[index].distance(to: rhs[rhsIndex]) > tolerance { return false }
            }
            return true
        }

        for offset in rhs.indices {
            if matches(reversed: false, offset: offset) || matches(reversed: true, offset: offset) {
                return true
            }
        }
        return false
    }

    private func logCutV2Counters(reason: String) {
        print(
            "CAD Cut v2 Counters: " +
            "reason=\(reason) " +
            "previewRebuildCount=\(cutPreviewRebuildCount) " +
            "booleanApplyCount=\(cutBooleanApplyCount) " +
            "geometryRebuildCount=\(cutCommittedGeometryRebuildCount)"
        )
    }

    private func logCutV2PreviewRebuild(
        validation: CADFeatureValidation,
        previewState: CADFeaturePreviewState?
    ) {
        guard featureOperation.isCutV2 else { return }
        logCutV2Counters(reason: "preview")

        let sketch = selectedSketch
        let profileArea = currentProfileArea()
        let targetID = cutTargetBodyID
        let bodyParams: ExtrudedSolidParameters? = targetID.flatMap { id in
            guard let asset = document.assets.first(where: { $0.id == id }),
                  case let .extrudedSolid(params) = asset.kind else { return nil }
            return params
        }
        let targetBounds = bodyParams.flatMap { CADAxisAlignedBounds(points: $0.vertices()) }
        let toolBounds = previewState.flatMap { cutToolBounds(for: $0) }
        let intersects = previewState.flatMap { state in
            bodyParams.map { cutToolMayIntersectBody(state: state, bodyParams: $0) }
        } ?? false
        let axes = sketch.map { axesForSketchReference($0.reference) }
        let origin = sketch.map { originForSketchReference($0.reference) }
        let depthValue = previewState?.depthMeters ?? 0
        let profileType = cutV2ProfileType(for: profileArea, in: sketch)
        let invalidReason = validation.isValid ? "none" : (validation.messageKey ?? "unknown")

        print(
            "CAD Cut v2 Preview: " +
            "sourceSketchID=\(sketch?.id.uuidString ?? "nil") " +
            "selectedProfileID=\(profileArea?.id.uuidString ?? "nil") " +
            "profileType=\(profileType.rawValue) " +
            "targetBodyID=\(targetID?.uuidString ?? "nil") " +
            "sketchPlaneOrigin=\(formatDebugVector(origin)) " +
            "sketchPlaneNormal=\(formatDebugVector(axes?.normal)) " +
            "direction=\(featureDirection.rawValue) " +
            "depthMode=\(featureDepthMode.rawValue) " +
            "depthValue=\(String(format: "%.4f", depthValue)) " +
            "targetBodyBounds=\(formatDebugBounds(targetBounds)) " +
            "cutToolBounds=\(formatDebugBounds(toolBounds)) " +
            "cutToolIntersectsBody=\(intersects) " +
            "transientPreviewNodeCount=\(activeCutTemporaryNodeCount) " +
            "previewCreated=\(previewState != nil && validation.isValid) " +
            "invalidReason=\(invalidReason)"
        )
    }

    private var committedBodyCount: Int {
        document.assets.filter {
            if case .extrudedSolid = $0.kind { return true }
            return false
        }.count
    }

    private var currentCutDiagnosticsCommittedCutsCount: Int {
        if featurePreviewState?.operation == .cutRemoveMaterialV2 {
            return cutCommitValidationResult.committedCutsCount
        }
        guard let bodyID = cutTargetBodyID ?? document.selectedAssetID,
              let asset = document.assets.first(where: { $0.id == bodyID }),
              case let .extrudedSolid(params) = asset.kind else {
            return 0
        }
        return params.stableCutFeatures.count
    }

    private var activeCutTemporaryNodeCount: Int {
        var count = 0
        if featurePreviewState?.operation == .cutRemoveMaterialV2 { count += 1 }
        if activeBodyEditTransaction?.previewNodeID != nil, count == 0 { count += 1 }
        return count
    }

    private func recordCutCleanupGuard(previewNodesRemoved: Bool) {
        transientCutNodeCount = 0
        cutterPreviewNodeCount = 0
        bodyTransparentMaterialCount = 0
        previewNodesRemovedAfterApply = previewNodesRemoved
    }

    private func logCutV2ApplyBefore(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters,
        profileType: CADCutV2ProfileType,
        meshStats: (vertexCount: Int, triangleCount: Int)?,
        bodyBounds: CADAxisAlignedBounds?,
        cutBounds: CADAxisAlignedBounds?,
        bodyCount: Int
    ) {
        let cutDirection = normalVector(for: state.sourceReference)
            .normalized(fallback: .zAxis) * (state.direction == .negativeNormal ? -1.0 : 1.0)
        print(
            "CAD Cut v2 Apply Before: " +
            "targetBodyID=\(state.targetBodyID?.uuidString ?? "nil") " +
            "committedMeshVertices=\(meshStats?.vertexCount ?? 0) " +
            "committedMeshTriangles=\(meshStats?.triangleCount ?? 0) " +
            "bodyVolumeEstimate=\(bodyParams.volumeMeters3) " +
            "existingCutFeatureCount=\(bodyParams.boxBlindCutFeatures.count) " +
            "cutProfileType=\(profileType.rawValue) " +
            "cutMode=\(state.depthMode.rawValue) " +
            "direction=\(state.direction.rawValue) " +
            "cutDirection=\(formatDebugVector(cutDirection)) " +
            "cutVolumeBBox=\(formatDebugBounds(cutBounds)) " +
            "bodyBBox=\(formatDebugBounds(bodyBounds)) " +
            "bodyCount=\(bodyCount) " +
            "operation=subtract"
        )
    }

    private func logCutV2ApplyAfter(
        resultParams: ExtrudedSolidParameters,
        resultMeshStats: (vertexCount: Int, triangleCount: Int)?,
        beforeBounds: CADAxisAlignedBounds?,
        resultBounds: CADAxisAlignedBounds?,
        bodyCountBefore: Int,
        bodyCountAfter: Int,
        removedPreviewNodeCount: Int,
        appendedFeatureID: UUID,
        rebuildDiagnostics: CADCutMeshRebuildDiagnostics,
        multiCutValidation: CADMultiCutValidationResult
    ) {
        let expanded = beforeBounds.flatMap { before in
            resultBounds.map { result in result.expands(beyond: before) }
        } ?? false
        let messageParts: [String] = [
            "CAD Cut v2 Apply After: ",
            "resultVertices=\(resultMeshStats?.vertexCount ?? 0) ",
            "resultTriangles=\(resultMeshStats?.triangleCount ?? 0) ",
            "resultVolumeEstimate=\(resultParams.volumeMeters3) ",
            "resultBBox=\(formatDebugBounds(resultBounds)) ",
            "bodyCount=\(bodyCountAfter) ",
            "bodyCountBefore=\(bodyCountBefore) ",
            "removedPreviewNodeCount=\(removedPreviewNodeCount) ",
            "featureAppendedID=\(appendedFeatureID.uuidString) ",
            "featureStackCount=\(resultParams.boxBlindCutFeatures.count) ",
            "totalCuts=\(rebuildDiagnostics.totalCutCount) ",
            "totalCutCount=\(rebuildDiagnostics.totalCutCount) ",
            "affectedFaceCount=\(rebuildDiagnostics.affectedFaceCount) ",
            "cutsGroupedByFace=\(rebuildDiagnostics.cutsGroupedByFace.joined(separator: ",")) ",
            "committedCutsCount=\(multiCutValidation.committedCutsCount) ",
            "candidateCutID=\(multiCutValidation.candidateCutID.uuidString) ",
            "affectedEntryFaceID=\(multiCutValidation.affectedEntryFaceID.uuidString) ",
            "affectedExitFaceID=\(multiCutValidation.affectedExitFaceID?.uuidString ?? "nil") ",
            "entryFaceID=\(rebuildDiagnostics.entryFaceID?.uuidString ?? "nil") ",
            "exitFaceID=\(rebuildDiagnostics.exitFaceID?.uuidString ?? "nil") ",
            "cutsOnEntryFace=\(multiCutValidation.cutsOnEntryFace) ",
            "cutsOnExitFace=\(multiCutValidation.cutsOnExitFace) ",
            "multiCutValidation=passed ",
            "cutVolumeIntersectionDetected=\(multiCutValidation.cutVolumeIntersectionDetected || rebuildDiagnostics.cutVolumeIntersectionDetected) ",
            "unsupportedIntersectingCutDetected=\(multiCutValidation.unsupportedIntersectingCutDetected || rebuildDiagnostics.unsupportedIntersectingCutDetected) ",
            "sameFaceOverlapGroupCount=\(rebuildDiagnostics.sameFaceOverlapGroupCount) ",
            "mergedProfileLoopCount=\(rebuildDiagnostics.mergedProfileLoopCount) ",
            "unionFailureCount=\(rebuildDiagnostics.unionFailureCount) ",
            "trianglesInsideMergedHole=\(rebuildDiagnostics.trianglesInsideMergedHole) ",
            "crossFaceIntersectionBlocked=\(multiCutValidation.crossFaceIntersectionBlocked || rebuildDiagnostics.crossFaceIntersectionBlocked) ",
            "meshVertexCount=\(resultMeshStats?.vertexCount ?? 0) ",
            "meshTriangleCount=\(resultMeshStats?.triangleCount ?? 0) ",
            "affectedFaceID=\(rebuildDiagnostics.affectedFaceID?.uuidString ?? "nil") ",
            "holeCountOnFace=\(rebuildDiagnostics.holeCountOnFace) ",
            "holeTypesOnFace=\(rebuildDiagnostics.holeTypesOnFace.joined(separator: ",")) ",
            "sameFaceTriangulationPassed=\(rebuildDiagnostics.sameFaceTriangulationPassed) ",
            "holeIntersectionDetected=\(rebuildDiagnostics.holeIntersectionDetected) ",
            "holeTouchDetected=\(rebuildDiagnostics.holeTouchDetected) ",
            "orphanTriangleCount=\(rebuildDiagnostics.orphanTriangleCount) ",
            "nonCoplanarFaceTriangleCount=\(rebuildDiagnostics.nonCoplanarFaceTriangleCount) ",
            "trianglesCrossingBetweenHoles=\(rebuildDiagnostics.trianglesCrossingBetweenHoles) ",
            "trianglesOutsideFace=\(rebuildDiagnostics.trianglesOutsideFace) ",
            "trianglesInsideAnyHole=\(rebuildDiagnostics.trianglesInsideAnyHole) ",
            "oldFullFaceRetained=\(rebuildDiagnostics.oldFullFaceRetained) ",
            "oldFullEntryFaceKept=\(rebuildDiagnostics.oldFullEntryFaceKept) ",
            "oldFullExitFaceKept=\(rebuildDiagnostics.oldFullExitFaceKept) ",
            "capFacesGenerated=\(rebuildDiagnostics.capFacesGenerated) ",
            "transientPreviewNodeCount=\(removedPreviewNodeCount) ",
            "operation=subtract",
        ]
        print(messageParts.joined())
        if expanded {
            print("Cut result expanded body bounds — possible additive/cutter leak.")
        }
        if bodyCountAfter > bodyCountBefore {
            print("CAD Cut v2 Warning: cut apply increased body count — possible leaked cutter body.")
        }
        logCutV2Counters(reason: "apply-finish")
    }

    private func logSolidKernelState(reason: String, solid: CADSolid) {
        print(
            "CAD Solid Kernel: " +
            "reason=\(reason) " +
            "bodyID=\(solid.id.uuidString) " +
            "additiveVolumes=\(solid.evaluatedState.additiveVolumeCount) " +
            "cutterVolumes=\(solid.evaluatedState.cutterVolumeCount) " +
            "regularizedVolumeEstimate=\(solid.evaluatedState.estimatedVolumeMeters3) " +
            "bounds=\(formatDebugBounds(solid.evaluatedBounds)) " +
            "generationVersion=\(solid.generationVersion)"
        )
    }

    private func logCADApply(
        operationType: CADFeatureType,
        targetBodyID: UUID,
        profileKind: CADCutV2ProfileType,
        depthMode: DepthMode,
        direction: ExtrudeDirection,
        beforeSolid: CADSolid?,
        afterSolid: CADSolid,
        validationResult: CADOperationValidationResult,
        committed: Bool,
        previewNodesRemoved: Int
    ) {
        print(
            "CAD Apply: " +
            "operationType=\(operationType.rawValue) " +
            "targetBodyID=\(targetBodyID.uuidString) " +
            "profileKind=\(profileKind.rawValue) " +
            "depthMode=\(depthMode.rawValue) " +
            "direction=\(direction.rawValue) " +
            "additiveVolumeCountBefore=\(beforeSolid?.additiveVolumes.count ?? 0) " +
            "cutterVolumeCountBefore=\(beforeSolid?.cutterVolumes.count ?? 0) " +
            "additiveVolumeCountAfter=\(afterSolid.additiveVolumes.count) " +
            "cutterVolumeCountAfter=\(afterSolid.cutterVolumes.count) " +
            "validationResult=\(validationResult.reasonCode.rawValue) " +
            "committed=\(committed) " +
            "reasonCode=\(validationResult.reasonCode.rawValue) " +
            "previewNodesRemoved=\(previewNodesRemoved)"
        )
    }

    private func buildKernelMeshCandidate(
        bodyID: UUID,
        solid: CADSolid,
        featureID: UUID?,
        operationType: CADFeatureType,
        legacyParams: ExtrudedSolidParameters?,
        legacyCommitted: Bool
    ) -> CADKernelMeshCandidate {
        kernelCandidateBuildCount += 1
        if cadKernelRenderMode == .kernelShadow {
            kernelShadowBuildCount += 1
        }
        let candidate = CADKernelMeshCandidateBuilder().buildCandidate(
            bodyID: bodyID,
            solid: solid,
            featureID: featureID
        )
        lastKernelMeshCandidate = candidate
        if !candidate.validationResult.isValid {
            kernelRejectCount += 1
        }
        logKernelMeshCandidate(
            candidate,
            operationType: operationType,
            legacyParams: legacyParams,
            legacyCommitted: legacyCommitted,
            kernelCommitted: false
        )
        return candidate
    }

    private func commitValidatedKernelMesh(
        _ candidate: CADKernelMeshCandidate,
        to bodyID: UUID,
        params: inout ExtrudedSolidParameters
    ) -> Bool {
        guard cadKernelRenderMode == .kernelCommitValidated,
              candidate.validationResult.isValid,
              candidate.bodyID == bodyID,
              let bodyIndex = cadDocument.bodies.firstIndex(where: { $0.id == bodyID }),
              isKernelCommitAllowed(candidate: candidate, params: params) else {
            kernelRejectCount += 1
            return false
        }
        params.kernelVisualMesh = candidate.mesh
        cadDocument.bodies[bodyIndex].solid.visualMeshCache = CADVisualMeshCache(
            mesh: candidate.mesh,
            diagnostics: candidate.diagnostics,
            generationVersion: candidate.sourceSolidVersion
        )
        cadDocument.bodies[bodyIndex].visualMeshCache = cadDocument.bodies[bodyIndex].solid.visualMeshCache
        kernelCommitCount += 1
        logKernelMeshCandidate(
            candidate,
            operationType: .extrudeCut,
            legacyParams: params,
            legacyCommitted: false,
            kernelCommitted: true
        )
        return true
    }

    private func commitValidatedCutKernelMesh(
        _ candidate: CADKernelMeshCandidate,
        to bodyID: UUID,
        params: inout ExtrudedSolidParameters
    ) -> Bool {
        guard candidate.validationResult.isValid,
              candidate.bodyID == bodyID,
              let bodyIndex = cadDocument.bodies.firstIndex(where: { $0.id == bodyID }),
              isKernelCommitAllowed(candidate: candidate, params: params) else {
            kernelRejectCount += 1
            return false
        }
        params.kernelVisualMesh = candidate.mesh
        cadDocument.bodies[bodyIndex].solid.visualMeshCache = CADVisualMeshCache(
            mesh: candidate.mesh,
            diagnostics: candidate.diagnostics,
            generationVersion: candidate.sourceSolidVersion
        )
        cadDocument.bodies[bodyIndex].visualMeshCache = cadDocument.bodies[bodyIndex].solid.visualMeshCache
        kernelCommitCount += 1
        logKernelMeshCandidate(
            candidate,
            operationType: .extrudeCut,
            legacyParams: params,
            legacyCommitted: false,
            kernelCommitted: true
        )
        return true
    }

    private func isKernelCommitAllowed(
        candidate: CADKernelMeshCandidate,
        params: ExtrudedSolidParameters
    ) -> Bool {
        guard candidate.validationResult.isValid,
              candidate.diagnostics.boundaryEdgeCount == 0,
              candidate.diagnostics.nonManifoldEdgeCount == 0,
              candidate.diagnostics.isClosedManifold,
              params.cutFeatures.isEmpty,
              params.holes.isEmpty else {
            return false
        }
        let classifier = CADSolidMaterialClassifier(epsilon: 1e-5)
        let solid = CADLimitedSolidKernel.makeSolid(id: candidate.bodyID, from: params)
        let debugReport = classifier.debugReport(for: solid)
        if debugReport.intersectingCutterVolumeCount > 0 {
            return allowValidatedIntersectingCutCommit
                && isPrimitiveCutSet(params: params)
        }
        return isPrimitiveCutSet(params: params)
    }

    private func isPrimitiveCutSet(params: ExtrudedSolidParameters) -> Bool {
        guard params.cutFeatures.isEmpty,
              params.holes.isEmpty else {
            return false
        }
        return params.boxBlindCutFeatures.allSatisfy { feature in
            (feature.profileType == .circle || feature.profileType == .rectangle)
                && (feature.depthMode == .throughAll || feature.depthMode == .distance)
        }
    }

    private func validateIntersectingCutCandidate(
        _ candidate: CADKernelMeshCandidate,
        before: ExtrudedSolidParameters,
        result: ExtrudedSolidParameters
    ) -> CADFeatureValidation {
        guard candidate.validationResult.isValid else { return .kernelCandidateInvalid }
        guard candidate.diagnostics.boundaryEdgeCount == 0,
              candidate.diagnostics.nonManifoldEdgeCount == 0,
              candidate.diagnostics.isClosedManifold else {
            return .cutResultNotSolid
        }
        guard let candidateBounds = CADAxisAlignedBounds(points: candidate.mesh.vertices),
              let beforeBounds = CADAxisAlignedBounds(points: before.vertices()),
              !candidateBounds.expands(beyond: beforeBounds, tolerance: 1e-5) else {
            return .volumeRuleFailedAfterCut
        }
        guard result.volumeMeters3 <= before.volumeMeters3 + 1e-9 else {
            return .volumeRuleFailedAfterCut
        }
        if candidate.boundaryDiagnostics?.removedInvalidBoundaryTriangles ?? 0 > 0 {
            return .boundaryFragmentValidationFailed
        }
        if candidate.boundaryDiagnostics?.trimLoopCount == 0 {
            return .trimLoopResolutionFailed
        }
        return .valid
    }

    private func reasonForRejectedIntersectingCandidate(_ candidate: CADKernelMeshCandidate) -> CADFeatureValidation {
        if !candidate.validationResult.isValid { return .intersectingCutValidationFailed }
        if candidate.boundaryDiagnostics?.removedInvalidBoundaryTriangles ?? 0 > 0 {
            return .boundaryFragmentValidationFailed
        }
        if candidate.boundaryDiagnostics?.trimLoopCount == 0 {
            return .trimLoopResolutionFailed
        }
        return .kernelCandidateInvalid
    }

    private func logKernelMeshCandidate(
        _ candidate: CADKernelMeshCandidate,
        operationType: CADFeatureType,
        legacyParams: ExtrudedSolidParameters?,
        legacyCommitted: Bool,
        kernelCommitted: Bool
    ) {
        let legacyMeshStats = legacyParams.flatMap { DesignAssetNodeFactory.debugMeshStats(for: $0) }
        let legacyBounds = legacyParams.flatMap { CADAxisAlignedBounds(points: $0.vertices()) }
        let boundary = candidate.boundaryDiagnostics
        print(
            "CAD Kernel Shadow Build: " +
            "operationType=\(operationType.rawValue) " +
            "bodyID=\(candidate.bodyID.uuidString) " +
            "featureID=\(candidate.featureID?.uuidString ?? "nil") " +
            "mode=\(cadKernelRenderMode.rawValue) " +
            "sourceMode=\(candidate.sourceMode.rawValue) " +
            "graphBuildSuccess=\((boundary?.graphBuildCount ?? 0) > 0) " +
            "trimLoopSuccess=\((boundary?.trimLoopCount ?? 0) >= 0) " +
            "meshBuildSuccess=\(!candidate.mesh.vertices.isEmpty && !candidate.mesh.triangles.isEmpty) " +
            "validationSuccess=\(candidate.validationResult.isValid) " +
            "reasonCode=\(candidate.validationResult.reasonCode.rawValue) " +
            "legacyCommitted=\(legacyCommitted) " +
            "kernelCommitted=\(kernelCommitted) " +
            "legacyVertices=\(legacyMeshStats?.vertexCount ?? 0) " +
            "legacyTriangles=\(legacyMeshStats?.triangleCount ?? 0) " +
            "kernelVertices=\(candidate.mesh.vertices.count) " +
            "kernelTriangles=\(candidate.mesh.triangles.count) " +
            "legacyBounds=\(formatDebugBounds(legacyBounds)) " +
            "kernelBounds=\(formatDebugBounds(candidate.bounds)) " +
            "nonManifoldEdges=\(candidate.diagnostics.nonManifoldEdgeCount) " +
            "boundaryEdges=\(candidate.diagnostics.boundaryEdgeCount) " +
            "orphanFaces=\(candidate.validationResults.filter { $0.reasonCode == .orphanFaceInsideVoid }.count) " +
            "internalFaces=\(candidate.validationResults.filter { $0.reasonCode == .internalFaceInsideMaterial }.count) " +
            "buildTimeMs=\(String(format: "%.2f", candidate.buildTimeMs)) " +
            "candidateBuilds=\(kernelCandidateBuildCount) " +
            "kernelCommits=\(kernelCommitCount) " +
            "kernelRejects=\(kernelRejectCount) " +
            "shadowBuilds=\(kernelShadowBuildCount) " +
            "intersectingAttempts=\(intersectingCutAttemptCount) " +
            "intersectingCommits=\(intersectingCutCommitCount) " +
            "intersectingRejects=\(intersectingCutRejectCount) " +
            "sceneGeometryReplacements=\(sceneGeometryReplacementCount)"
        )
    }

    private func logMaterialClassificationValidation(
        reason: String,
        solid: CADSolid,
        mesh: CADSolidMeshSnapshot?
    ) {
        let classifier = CADSolidMaterialClassifier(epsilon: 1e-5)
        let debugReport = classifier.debugReport(for: solid)
        let boundaryBuildResult = CADBoundarySurfaceBuilder().buildBoundaryMesh(
            solid: solid,
            classifier: classifier,
            options: CADBoundaryBuildOptions()
        )
        let validationResults = mesh.map {
            CADSurfaceBoundaryValidator.validate(mesh: $0, solid: solid, epsilon: 1e-5)
        } ?? []
        let invalidInternal = validationResults.filter { $0.reasonCode == .internalFaceInsideMaterial }.count
        let invalidVoid = validationResults.filter { $0.reasonCode == .orphanFaceInsideVoid }.count
        let unsupported = validationResults.filter { $0.result == .unsupported }.count
        let valid = validationResults.filter { $0.result == .valid }.count
        print(
            "CAD Solid Classification: " +
            "reason=\(reason) " +
            "additiveVolumes=\(debugReport.additiveVolumeCount) " +
            "cutterVolumes=\(debugReport.cutterVolumeCount) " +
            "supportedVolumeTypes=\(debugReport.supportedVolumeTypeCount) " +
            "unsupportedVolumes=\(debugReport.unsupportedVolumeCount) " +
            "intersectingCutterVolumes=\(debugReport.intersectingCutterVolumeCount) " +
            "boundaryValidationStatus=\(invalidInternal == 0 && invalidVoid == 0 ? "valid" : "warning") " +
            "validBoundaryFaces=\(valid) " +
            "internalFaces=\(invalidInternal) " +
            "orphanVoidFaces=\(invalidVoid) " +
            "unsupportedFaces=\(unsupported)"
        )
        if let boundaryDiagnostics = boundaryBuildResult.boundaryDiagnostics {
            print(
                "CAD Boundary Surface Builder: " +
                "reason=\(reason) " +
                "candidateSurfaces=\(boundaryDiagnostics.candidateSurfaceCount) " +
                "keptFragments=\(boundaryDiagnostics.keptFragmentCount) " +
                "rejectedFragments=\(boundaryDiagnostics.rejectedFragmentCount) " +
                "graphBuilds=\(boundaryDiagnostics.graphBuildCount) " +
                "surfacePairs=\(boundaryDiagnostics.surfacePairTestCount) " +
                "intersectionCurves=\(boundaryDiagnostics.intersectionCurveCount) " +
                "trimLoops=\(boundaryDiagnostics.trimLoopCount) " +
                "seamCrossingCurves=\(boundaryDiagnostics.seamCrossingCurveCount) " +
                "seamSplits=\(boundaryDiagnostics.seamSplitCount) " +
                "seamWeldedVertices=\(boundaryDiagnostics.seamWeldedVertexCount) " +
                "removedDuplicateVertices=\(boundaryDiagnostics.removedDuplicateVertices) " +
                "removedDuplicateTriangles=\(boundaryDiagnostics.removedDuplicateTriangles) " +
                "removedZeroAreaTriangles=\(boundaryDiagnostics.removedZeroAreaTriangles) " +
                "removedSliverTriangles=\(boundaryDiagnostics.removedSliverTriangles) " +
                "removedInvalidBoundaryTriangles=\(boundaryDiagnostics.removedInvalidBoundaryTriangles) " +
                "finalVertices=\(boundaryDiagnostics.finalVertexCount) " +
                "finalTriangles=\(boundaryDiagnostics.finalTriangleCount) " +
                "validation=\(boundaryBuildResult.validationResult.reasonCode.rawValue)"
            )
        }
        if debugReport.intersectingCutterVolumeCount > 0 {
            print(
                "CAD Solid Classification: intersecting cutter volumes detected; " +
                "classification evaluator ready; mesh split not enabled yet."
            )
        }
    }

    private func formatDebugVector(_ vector: DesignVector3?) -> String {
        guard let vector else { return "nil" }
        return String(format: "(%.4f,%.4f,%.4f)", vector.x, vector.y, vector.z)
    }

    private func formatDebugBounds(_ bounds: CADAxisAlignedBounds?) -> String {
        guard let bounds else { return "nil" }
        return "\(formatDebugVector(bounds.min))...\(formatDebugVector(bounds.max))"
    }

    private func formatDebugBounds(_ bounds: CADSolidBounds?) -> String {
        guard let bounds else { return "nil" }
        return "\(formatDebugVector(bounds.min))...\(formatDebugVector(bounds.max))"
    }

    /// Through All preview depth: projects body vertices onto the selected sketch-normal direction
    /// and adds a small bounds-based margin. If the direction points away from the body, this returns 0.
    private func throughAllCutDepth(
        sketchReference: SketchReference,
        direction: ExtrudeDirection,
        bodyParams: ExtrudedSolidParameters
    ) -> Double {
        let cutNormal = normalVector(for: sketchReference).normalized(fallback: .zAxis)
        let effectiveNormal = direction == .negativeNormal ? cutNormal * -1 : cutNormal
        let sketchOrigin = originForSketchReference(sketchReference)
        let bodyVerts = bodyParams.vertices()

        var maxExtent = 0.0
        for v in bodyVerts {
            let projection = (v - sketchOrigin).dot(effectiveNormal)
            if projection > maxExtent { maxExtent = projection }
        }
        guard maxExtent > 1e-6 else { return 0 }
        let bodyDiagonal = CADAxisAlignedBounds(points: bodyVerts)?.diagonalLength ?? bodyParams.depthMeters
        let margin = max(bodyDiagonal * 0.05, 0.005)
        return maxExtent + margin
    }

    private func beginCutV2Transaction(
        targetBodyID: UUID,
        bodyParams: ExtrudedSolidParameters,
        bodyMaterial: DesignMaterial,
        bodyTransform: DesignTransform,
        selectedProfileID: UUID,
        sketchReference: SketchReference
    ) {
        let axes = axesForSketchReference(sketchReference)
        let sketchPlaneFrame = CADSketchPlaneFrame(
            origin: originForSketchReference(sketchReference),
            basisU: axes.u,
            basisV: axes.v,
            normal: axes.normal
        )
        if let activeBodyEditTransaction,
           activeBodyEditTransaction.targetBodyID == targetBodyID,
           activeBodyEditTransaction.selectedProfileID == selectedProfileID,
           activeBodyEditTransaction.bodyGeometryBefore == bodyParams,
           activeBodyEditTransaction.sketchPlaneFrame == sketchPlaneFrame {
            return
        }
        activeBodyEditTransaction = CADBodyEditTransaction(
            transactionID: UUID(),
            operationType: .cutRemoveMaterialV2,
            targetBodyID: targetBodyID,
            bodyGeometryBefore: bodyParams,
            bodyMaterialBefore: bodyMaterial,
            bodyTransformBefore: bodyTransform,
            bodyRenderStateBefore: CADBodyRenderState(),
            bodyVisibilityBefore: true,
            selectedProfileID: selectedProfileID,
            sketchPlaneFrame: sketchPlaneFrame,
            previewNodeID: "cad.cut.cutterVolume"
        )
    }

    private func rollbackCutV2Transaction() {
        // Cut v2 preview is visual-only. It must never restore geometry from the transaction,
        // because the committed body may already include newer sequential cuts.
        activeBodyEditTransaction = nil
    }

    private func clearAllTransientCADNodes(resetOperation: Bool) {
        let previewNodesWereActive = activeCutTemporaryNodeCount > 0
        rollbackCutV2Transaction()
        cutPreviewCacheKey = nil
        featurePreviewState = nil
        featureApplyFailureReason = nil
        recordCutCleanupGuard(previewNodesRemoved: previewNodesWereActive)
        if resetOperation {
            lastKernelMeshCandidate = nil
        }
        if resetOperation, featureOperation != .extrudeNewBody {
            featureOperation = .extrudeNewBody
        }
    }

    private func validateCutV2Apply(state: CADFeaturePreviewState) -> CADFeatureValidation {
        guard state.operation == .cutRemoveMaterialV2 else { return .unsupportedOperation }
        return makeCurrentCutRequest(depthMode: state.depthMode).validation
    }

    private func cutValidationIndicatesIntersectingUnsupported(_ validation: CADFeatureValidation) -> Bool {
        switch validation {
        case .cutIntersectsExistingVoidUnsupported,
             .sameFaceIntersectingCutsDifferentDepthUnsupported,
             .distanceThroughAllIntersectionUnsupported,
             .crossFaceIntersectingCutUnsupported:
            return true
        default:
            return false
        }
    }

    private func buildCutCommitValidationResult() -> CutCommitValidationResult {
        let profileType = cutV2ProfileType(for: currentProfileArea(), in: selectedSketch)
        let depthMode = featureDepthMode
        let direction = featureDirection
        let uiTargetBodyID = cutTargetBodyID
        let previewTargetBodyID = featurePreviewState?.targetBodyID

        guard featureOperation == .cutRemoveMaterialV2 else {
            return .blocked(
                targetBodyID: uiTargetBodyID,
                uiSelectedBodyID: uiTargetBodyID,
                previewTargetBodyID: previewTargetBodyID,
                cutProfileType: profileType,
                cutDepthMode: depthMode,
                cutDirection: direction,
                reason: CADFeatureValidation.unsupportedOperation.messageKey
            )
        }

        guard let state = featurePreviewState,
              state.operation == .cutRemoveMaterialV2 else {
            return .blocked(
                targetBodyID: uiTargetBodyID,
                uiSelectedBodyID: uiTargetBodyID,
                previewTargetBodyID: previewTargetBodyID,
                cutProfileType: profileType,
                cutDepthMode: depthMode,
                cutDirection: direction,
                reason: CADFeatureValidation.noSelectedProfileArea.messageKey
            )
        }

        let build = makeCurrentCutRequest(depthMode: state.depthMode)
        guard let request = build.request else {
            let existingCutCount: Int = state.targetBodyID.flatMap { id in
                guard let asset = document.assets.first(where: { $0.id == id }),
                      case let .extrudedSolid(params) = asset.kind else { return nil }
                return params.stableCutFeatures.count
            } ?? 0
            return .blocked(
                targetBodyID: state.targetBodyID,
                uiSelectedBodyID: uiTargetBodyID,
                kernelTargetBodyID: state.targetBodyID,
                applyTargetBodyID: state.targetBodyID,
                previewTargetBodyID: state.targetBodyID,
                cutProfileType: profileType,
                cutDepthMode: state.depthMode,
                cutDirection: state.direction,
                intersectsExistingVoid: cutValidationIndicatesIntersectingUnsupported(build.validation),
                reason: build.validation.messageKey,
                committedCutsCount: existingCutCount,
                multiCutValidationReason: build.validation.messageKey
            )
        }

        let candidateCut = request.feature()
        let multiCutValidation = CADMultiCutValidator.validate(
            baseBody: request.targetBodyGeometry,
            existingCuts: request.targetBodyGeometry.stableCutFeatures,
            newCut: candidateCut
        )
        guard multiCutValidation.isValid else {
            return .blocked(
                targetBodyID: request.targetBodyID,
                uiSelectedBodyID: uiTargetBodyID,
                kernelTargetBodyID: request.targetBodyID,
                applyTargetBodyID: request.targetBodyID,
                previewTargetBodyID: request.targetBodyID,
                cutProfileType: request.profileType,
                cutDepthMode: request.depthMode,
                cutDirection: request.directionForSketchReference,
                intersectsExistingVoid: cutValidationIndicatesIntersectingUnsupported(multiCutValidation.validation),
                reason: multiCutValidation.reason,
                committedCutsCount: multiCutValidation.committedCutsCount,
                candidateCutID: multiCutValidation.candidateCutID,
                affectedEntryFaceID: multiCutValidation.affectedEntryFaceID,
                affectedExitFaceID: multiCutValidation.affectedExitFaceID,
                cutsOnEntryFace: multiCutValidation.cutsOnEntryFace,
                cutsOnExitFace: multiCutValidation.cutsOnExitFace,
                multiCutValidationPassed: false,
                multiCutValidationReason: multiCutValidation.reason
            )
        }

        var candidateParams = request.targetBodyGeometry
        candidateParams.stableCutFeatures = multiCutValidation.candidateCuts
        candidateParams.kernelVisualMesh = nil
        candidateParams.kernelResultSolid = nil
        candidateParams.refreshFaces(assetID: request.targetBodyID)
        guard let meshBuild = CADCutMeshRebuilder.rebuildBodyMesh(
            bodyID: request.targetBodyID,
            bodyParams: candidateParams
        ) else {
            return .blocked(
                targetBodyID: request.targetBodyID,
                uiSelectedBodyID: uiTargetBodyID,
                kernelTargetBodyID: request.targetBodyID,
                applyTargetBodyID: request.targetBodyID,
                previewTargetBodyID: request.targetBodyID,
                cutProfileType: request.profileType,
                cutDepthMode: request.depthMode,
                cutDirection: request.directionForSketchReference,
                reason: CADFeatureValidation.generatedMeshEmpty.messageKey,
                committedCutsCount: multiCutValidation.committedCutsCount,
                candidateCutID: multiCutValidation.candidateCutID,
                affectedEntryFaceID: multiCutValidation.affectedEntryFaceID,
                affectedExitFaceID: multiCutValidation.affectedExitFaceID,
                cutsOnEntryFace: multiCutValidation.cutsOnEntryFace,
                cutsOnExitFace: multiCutValidation.cutsOnExitFace,
                multiCutValidationPassed: true,
                multiCutValidationReason: CADFeatureValidation.generatedMeshEmpty.messageKey
            )
        }

        return CutCommitValidationResult(
            isValid: true,
            canCommit: true,
            targetBodyID: request.targetBodyID,
            uiSelectedBodyID: uiTargetBodyID,
            kernelTargetBodyID: request.targetBodyID,
            applyTargetBodyID: request.targetBodyID,
            previewTargetBodyID: request.targetBodyID,
            cutProfileType: request.profileType,
            cutDepthMode: request.depthMode,
            cutDirection: request.directionForSketchReference,
            intersectsExistingVoid: false,
            createsOpenShell: false,
            createsNonManifoldEdges: false,
            createsFloatingIsland: false,
            boundaryEdgeCount: nil,
            boundaryLoopCount: nil,
            kernelFallback: false,
            reason: nil,
            committedCutsCount: multiCutValidation.committedCutsCount,
            candidateCutID: multiCutValidation.candidateCutID,
            affectedEntryFaceID: multiCutValidation.affectedEntryFaceID,
            affectedExitFaceID: multiCutValidation.affectedExitFaceID,
            cutsOnEntryFace: multiCutValidation.cutsOnEntryFace,
            cutsOnExitFace: multiCutValidation.cutsOnExitFace,
            multiCutValidationPassed: true,
            multiCutValidationReason: nil,
            meshVertexCount: meshBuild.mesh.vertices.count,
            meshTriangleCount: meshBuild.mesh.triangles.count,
            trianglesInsideAnyHole: meshBuild.rebuildDiagnostics.trianglesInsideAnyHole,
            capFacesGenerated: meshBuild.rebuildDiagnostics.capFacesGenerated
        )
    }

    private func finalCanCommit(_ kernelResult: CADBooleanKernelResult) -> Bool {
        kernelResult.canCommit
            && kernelResult.validationResult.isValid
            && kernelResult.candidate?.diagnostics.isClosedManifold == true
            && kernelResult.resultSolid != nil
    }

    private func canUseKernelVisualMesh(_ kernelResult: CADBooleanKernelResult) -> Bool {
        guard finalCanCommit(kernelResult),
              let mesh = kernelResult.candidate?.mesh else {
            return false
        }
        return !mesh.vertices.isEmpty && !mesh.triangles.isEmpty
    }

    private func kernelCommitFailureReason(_ kernelResult: CADBooleanKernelResult) -> String {
        if !kernelResult.validationResult.message.isEmpty,
           kernelResult.validationResult.reasonCode != .none {
            return kernelResult.validationResult.message
        }
        if let diagnostics = kernelResult.candidate?.diagnostics {
            if diagnostics.hasOpenBoundary {
                return "Commit blocked: result shell is open."
            }
            if !diagnostics.isClosedManifold {
                return "Commit blocked: result is not a closed solid body."
            }
        }
        return CADFeatureValidation.cutResultNotSolid.messageKey ?? "cad.cut_v2.reason.cut_result_not_solid"
    }

    private func makeCurrentBoxBlindCutFeature() -> ExtrudedSolidBoxBlindCutFeature? {
        guard let state = featurePreviewState,
              state.operation == .cutRemoveMaterialV2,
              let selectedProfileID = state.selectedProfileID,
              let targetBodyID = state.targetBodyID,
              let targetAsset = document.assets.first(where: { $0.id == targetBodyID }),
              case let .extrudedSolid(bodyParams) = targetAsset.kind else {
            return nil
        }
        return buildBoxBlindCutFeature(
            state: state,
            bodyParams: bodyParams,
            selectedProfileID: selectedProfileID
        )
    }

    private func buildBoxBlindCutFeature(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters,
        selectedProfileID: UUID
    ) -> ExtrudedSolidBoxBlindCutFeature? {
        let validation = validateCutV2Apply(state: state)
        guard validation.isValid,
              let entryFace = cutV2EntryFace(state: state, bodyParams: bodyParams) else {
            return nil
        }

        let faceU = entryFace.uAxis.normalized(fallback: .xAxis)
        let faceV = entryFace.vAxis.normalized(fallback: .yAxis)
        let faceLocalProfile = state.profilePoints.map { point -> SketchPoint2D in
            let world = sketchPointToWorld(point, reference: state.sourceReference)
            let delta = world - entryFace.origin
            return SketchPoint2D(u: delta.dot(faceU), v: delta.dot(faceV))
        }
        guard validateProfileLoop(faceLocalProfile) else { return nil }

        let cutDirection = inwardCutDirection(entryFace: entryFace, bodyParams: bodyParams)
        let profileType = cutV2ProfileType(for: currentProfileArea(), in: selectedSketch)
        let thickness = cutV2LocalThickness(state: state, bodyParams: bodyParams) ?? state.depthMeters
        let resolvedDepthMode: DepthMode = state.depthMode == .distance && state.depthMeters >= thickness - 1e-6
            ? .throughAll
            : state.depthMode

        return ExtrudedSolidBoxBlindCutFeature(
            id: UUID(),
            profileType: profileType,
            entryFaceID: entryFace.id,
            profilePoints: faceLocalProfile,
            depthMeters: state.depthMeters,
            cutDirection: cutDirection,
            sourceSketchID: state.sourceSketchID,
            sourceSketchName: state.sourceSketchName,
            selectedProfileID: selectedProfileID,
            depthMode: resolvedDepthMode,
            direction: state.direction
        )
    }

    private func cutV2EntryFace(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters
    ) -> DesignPlanarFace? {
        guard let targetBodyID = state.targetBodyID else {
            return nil
        }
        return cutV2EntryFace(
            sourceReference: state.sourceReference,
            targetBodyID: targetBodyID,
            bodyParams: bodyParams
        )
    }

    private func cutV2EntryFace(
        sourceReference: SketchReference,
        targetBodyID: UUID,
        bodyParams: ExtrudedSolidParameters
    ) -> DesignPlanarFace? {
        guard case let .planarFace(faceReference) = sourceReference,
              faceReference.sourceAssetID == targetBodyID else {
            return nil
        }
        return bodyParams.faces.first { $0.id == faceReference.faceID }
    }

    private func inwardCutDirection(
        entryFace: DesignPlanarFace,
        bodyParams: ExtrudedSolidParameters
    ) -> DesignVector3 {
        let n = entryFace.normal.normalized(fallback: .zAxis)
        let verts = bodyParams.vertices()
        guard !verts.isEmpty else { return n * -1 }
        let center = verts.reduce(DesignVector3.zero) { partial, vertex in
            partial + vertex
        } * (1.0 / Double(verts.count))
        let toBody = center - entryFace.center
        return (toBody.dot(n) >= 0 ? n : n * -1).normalized(fallback: n * -1)
    }

    private func profileLiesOnSelectedFace(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters
    ) -> Bool {
        guard let face = cutV2EntryFace(state: state, bodyParams: bodyParams) else { return false }
        let faceNormal = face.normal.normalized(fallback: .zAxis)
        let faceU = face.uAxis.normalized(fallback: .xAxis)
        let faceV = face.vAxis.normalized(fallback: .yAxis)
        let tolerance = 1e-5
        return state.profilePoints.allSatisfy { point in
            let world = sketchPointToWorld(point, reference: state.sourceReference)
            let delta = world - face.origin
            let planeDistance = abs(delta.dot(faceNormal))
            let u = delta.dot(faceU)
            let v = delta.dot(faceV)
            return planeDistance <= tolerance
                && u >= face.bounds.minU - tolerance
                && u <= face.bounds.maxU + tolerance
                && v >= face.bounds.minV - tolerance
                && v <= face.bounds.maxV + tolerance
        }
    }

    private func cutV2LocalThickness(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters
    ) -> Double? {
        guard let entryFace = cutV2EntryFace(state: state, bodyParams: bodyParams) else { return nil }
        let cutDirection = inwardCutDirection(entryFace: entryFace, bodyParams: bodyParams)
        let origin = originForSketchReference(state.sourceReference)
        let projections = bodyParams.vertices().map { ($0 - origin).dot(cutDirection) }
        guard projections.allSatisfy({ $0.isFinite }) else { return nil }
        return projections.max() ?? 0
    }

    private func cutToolMayIntersectBody(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters
    ) -> Bool {
        guard state.operation.isCutV2,
              state.depthMeters.isFinite,
              state.depthMeters > 1e-6,
              state.direction == .positiveNormal || state.direction == .negativeNormal,
              validateProfileLoop(state.profilePoints) else {
            return false
        }

        guard let bodyBounds = CADAxisAlignedBounds(points: bodyParams.vertices()),
              let cutBounds = cutToolBounds(for: state),
              cutBounds.intersects(bodyBounds) else {
            return false
        }

        // Stabilization stage: preview/apply eligibility is volume-overlap based and cheap.
        // Do not sample prior cavities or run boolean-like tests while previewing.
        return (cutV2LocalThickness(state: state, bodyParams: bodyParams) ?? 0) > 1e-6
    }

    private func validateBoxBlindCutResult(
        before: ExtrudedSolidParameters,
        result: ExtrudedSolidParameters,
        appliedCut: ExtrudedSolidBoxBlindCutFeature
    ) -> CADFeatureValidation {
        guard validateSolidBody(result) else { return .cutResultNotSolid }
        guard result.profilePoints == before.profilePoints,
              result.sourceReference == before.sourceReference,
              result.depthMeters == before.depthMeters,
              result.direction == before.direction,
              result.material == before.material,
              result.holes == before.holes,
              result.holeDepths == before.holeDepths,
              result.cutFeatures == before.cutFeatures else {
            return .unaffectedGeometryWasRemoved
        }
        guard !result.faces.isEmpty else { return .cutResultNotSolid }
        guard result.boxBlindCutFeatures.count == before.boxBlindCutFeatures.count + 1,
              result.boxBlindCutFeatures.last == appliedCut else {
            return .cutBooleanFailed
        }
        guard result.volumeMeters3 <= before.volumeMeters3 + 1e-9 else {
            print(
                "CAD Cut v2 Hard Failure: cut increased volume " +
                "before=\(before.volumeMeters3) after=\(result.volumeMeters3)"
            )
            return .cutBooleanInvalidResult
        }
        guard (appliedCut.depthMode == .distance || appliedCut.depthMode == .throughAll),
              appliedCut.depthMeters.isFinite,
              (appliedCut.depthMode == .throughAll || appliedCut.depthMeters > 1e-6),
              appliedCut.cutDirection.isFinite,
              validateProfileLoop(appliedCut.profilePoints) else {
            return .cutBooleanFailed
        }
        guard let beforeBounds = CADAxisAlignedBounds(points: before.vertices()),
              let resultBounds = CADAxisAlignedBounds(points: result.vertices()),
              boundsApproximatelyEqual(beforeBounds, resultBounds) else {
            return .unaffectedGeometryWasRemoved
        }
        guard let entryFace = before.faces.first(where: { $0.id == appliedCut.entryFaceID }) else {
            return .cutBooleanFailed
        }
        let faceOuter = faceOuterLoop(entryFace)
        guard DesignAssetNodeFactory.validateCapTriangulation(
            outerProfile: faceOuter,
            holes: [appliedCut.profilePoints]
        ) else {
            return .cutVisibleTriangulationArtifact
        }

        switch appliedCut.profileType {
        case .circle:
            guard appliedCut.profilePoints.count >= 32 else { return .unsupportedProfileForCutV2 }
        case .rectangle:
            guard appliedCut.profilePoints.count == 4 else { return .unsupportedProfileForCutV2 }
        case .polygon, .unsupported:
            return .unsupportedProfileForCutV2
        }
        return .valid
    }

    private func faceOuterLoop(_ face: DesignPlanarFace) -> [SketchPoint2D] {
        [
            SketchPoint2D(u: face.bounds.minU, v: face.bounds.minV),
            SketchPoint2D(u: face.bounds.maxU, v: face.bounds.minV),
            SketchPoint2D(u: face.bounds.maxU, v: face.bounds.maxV),
            SketchPoint2D(u: face.bounds.minU, v: face.bounds.maxV),
        ]
    }

    private func boundsApproximatelyEqual(
        _ lhs: CADAxisAlignedBounds,
        _ rhs: CADAxisAlignedBounds,
        tolerance: Double = 1e-6
    ) -> Bool {
        abs(lhs.min.x - rhs.min.x) <= tolerance
            && abs(lhs.min.y - rhs.min.y) <= tolerance
            && abs(lhs.min.z - rhs.min.z) <= tolerance
            && abs(lhs.max.x - rhs.max.x) <= tolerance
            && abs(lhs.max.y - rhs.max.y) <= tolerance
            && abs(lhs.max.z - rhs.max.z) <= tolerance
    }

    @available(*, deprecated, message: "Legacy cap-parallel Cut builder is disabled for stabilized Cut v2.")
    private func buildCutV2Feature(
        state: CADFeaturePreviewState,
        bodyParams: ExtrudedSolidParameters,
        selectedProfileID: UUID
    ) -> ExtrudedSolidCutFeature? {
        guard state.operation.isCutV2,
              state.direction == .positiveNormal || state.direction == .negativeNormal,
              state.depthMeters.isFinite,
              state.depthMeters > 0,
              validateProfileLoop(state.profilePoints),
              validateSolidBody(bodyParams),
              cutV2NormalsAreParallel(sketchReference: state.sourceReference, bodyParams: bodyParams) else {
            return nil
        }

        let transformedProfile = state.profilePoints.map { point -> SketchPoint2D in
            let world = sketchPointToWorld(point, reference: state.sourceReference)
            return worldPointToSketch(world, reference: bodyParams.sourceReference)
        }
        guard transformedProfile.allSatisfy({ $0.u.isFinite && $0.v.isFinite }),
              validateProfileLoop(transformedProfile),
              profileIsInsideBody(transformedProfile, bodyProfile: bodyParams.profilePoints) else {
            return nil
        }

        let bodyNormal = normalVector(for: bodyParams.sourceReference).normalized(fallback: .zAxis)
        let sketchNormal = normalVector(for: state.sourceReference).normalized(fallback: .zAxis)
        let cutDirection = state.direction == .positiveNormal ? sketchNormal : sketchNormal * -1
        let signedDirection = cutDirection.dot(bodyNormal)
        guard abs(signedDirection) > 0.995 else { return nil }

        let bodyOrigin = originForSketchReference(bodyParams.sourceReference)
        let sketchOrigin = originForSketchReference(state.sourceReference)
        let startOffset = (sketchOrigin - bodyOrigin).dot(bodyNormal)
        let endOffset = startOffset + (signedDirection > 0 ? state.depthMeters : -state.depthMeters)
        let (frontOff, backOff) = bodyParams.direction.offsets(depth: bodyParams.depthMeters)
        let bodyMin = min(frontOff, backOff)
        let bodyMax = max(frontOff, backOff)
        let clippedStart = clamp(startOffset, min: bodyMin, max: bodyMax)
        let clippedEnd = clamp(endOffset, min: bodyMin, max: bodyMax)
        guard abs(clippedEnd - clippedStart) > 1e-6 else { return nil }

        return ExtrudedSolidCutFeature(
            id: UUID(),
            profilePoints: transformedProfile,
            startOffsetMeters: clippedStart,
            endOffsetMeters: clippedEnd,
            sourceSketchID: state.sourceSketchID,
            sourceSketchName: state.sourceSketchName,
            selectedProfileID: selectedProfileID,
            depthMode: state.depthMode,
            direction: state.direction
        )
    }

    @available(*, deprecated, message: "Legacy cap-parallel Cut validation is disabled for stabilized Cut v2.")
    private func validateCutV2Result(
        before: ExtrudedSolidParameters,
        result: ExtrudedSolidParameters,
        appliedCut: ExtrudedSolidCutFeature
    ) -> CADFeatureValidation {
        guard validateSolidBody(result) else { return .cutResultNotSolid }
        guard result.profilePoints == before.profilePoints,
              result.sourceReference == before.sourceReference,
              result.depthMeters == before.depthMeters,
              result.direction == before.direction else {
            return .unaffectedGeometryWasRemoved
        }
        guard result.vertices().allSatisfy({ $0.isFinite }) else { return .cutResultBoundsInvalid }
        guard validateProfileLoop(appliedCut.profilePoints) else { return .invalidProfileLoop }
        guard appliedCut.depthMeters > 1e-6 else { return .cutBooleanFailed }

        let (frontOff, backOff) = before.direction.offsets(depth: before.depthMeters)
        let startsAtFront = abs(appliedCut.startOffsetMeters - frontOff) < 1e-6
        let startsAtBack = abs(appliedCut.startOffsetMeters - backOff) < 1e-6
        let endsAtFront = abs(appliedCut.endOffsetMeters - frontOff) < 1e-6
        let endsAtBack = abs(appliedCut.endOffsetMeters - backOff) < 1e-6
        let frontOpen = startsAtFront || endsAtFront
        let backOpen = startsAtBack || endsAtBack
        let through = frontOpen && backOpen

        if appliedCut.depthMode == .distance && !through && (!frontOpen && !backOpen) {
            return .cutMissingBlindBottom
        }
        if appliedCut.depthMode == .throughAll && !through {
            return .cutMissingExitOpening
        }

        let frontHoles = result.cutFeatures.compactMap { feature -> [SketchPoint2D]? in
            abs(feature.startOffsetMeters - frontOff) < 1e-6 || abs(feature.endOffsetMeters - frontOff) < 1e-6
                ? feature.profilePoints
                : nil
        }
        let backHoles = result.cutFeatures.compactMap { feature -> [SketchPoint2D]? in
            abs(feature.startOffsetMeters - backOff) < 1e-6 || abs(feature.endOffsetMeters - backOff) < 1e-6
                ? feature.profilePoints
                : nil
        }
        guard DesignAssetNodeFactory.validateCapTriangulation(
            outerProfile: result.profilePoints,
            holes: before.holes + frontHoles
        ) else {
            return .cutVisibleTriangulationArtifact
        }
        guard DesignAssetNodeFactory.validateCapTriangulation(
            outerProfile: result.profilePoints,
            holes: backHoles
        ) else {
            return .cutVisibleTriangulationArtifact
        }
        return .valid
    }

    private func validateSolidBody(_ params: ExtrudedSolidParameters) -> Bool {
        validateProfileLoop(params.profilePoints)
            && params.depthMeters.isFinite
            && params.depthMeters > 0
            && params.vertices().allSatisfy { $0.isFinite }
            && params.areaMeters2 > 1e-8
            && params.volumeMeters3 > 0
    }

    private func validateSketchPlaneFrame(_ reference: SketchReference) -> Bool {
        let axes = axesForSketchReference(reference)
        let origin = originForSketchReference(reference)
        let u = axes.u.normalized(fallback: .xAxis)
        let v = axes.v.normalized(fallback: .yAxis)
        let n = axes.normal.normalized(fallback: .zAxis)
        return origin.isFinite
            && u.isFinite
            && v.isFinite
            && n.isFinite
            && abs(u.dot(v)) < 0.02
            && abs(u.dot(n)) < 0.02
            && abs(v.dot(n)) < 0.02
    }

    private func cutV2NormalsAreParallel(
        sketchReference: SketchReference,
        bodyParams: ExtrudedSolidParameters
    ) -> Bool {
        let sketchNormal = normalVector(for: sketchReference).normalized(fallback: .zAxis)
        let bodyNormal = normalVector(for: bodyParams.sourceReference).normalized(fallback: .zAxis)
        return abs(sketchNormal.dot(bodyNormal)) > 0.995
    }

    private func validateProfileLoop(_ points: [SketchPoint2D]) -> Bool {
        guard points.count >= 3 else { return false }
        guard points.allSatisfy({ $0.u.isFinite && $0.v.isFinite }) else { return false }
        guard abs(DesignSketch.polygonSignedAreaMeters2(points)) > 1e-8 else { return false }
        for i in points.indices {
            let next = (i + 1) % points.count
            guard points[i].distance(to: points[next]) > 1e-6 else { return false }
        }
        guard !hasSelfIntersections(points) else { return false }
        return true
    }

    private func hasSelfIntersections(_ points: [SketchPoint2D]) -> Bool {
        guard points.count >= 4 else { return false }
        for i in points.indices {
            let iNext = (i + 1) % points.count
            for j in points.indices {
                let jNext = (j + 1) % points.count
                guard i != j,
                      iNext != j,
                      jNext != i else { continue }
                if i == 0 && jNext == 0 { continue }
                if segmentsIntersect(a1: points[i], a2: points[iNext], b1: points[j], b2: points[jNext]) != nil {
                    return true
                }
            }
        }
        return false
    }

    private func profileIsInsideBody(_ profile: [SketchPoint2D], bodyProfile: [SketchPoint2D]) -> Bool {
        guard validateProfileLoop(bodyProfile) else { return false }
        return profile.allSatisfy { point in
            SketchProfileEngine.pointInPolygon(point, polygon: bodyProfile)
                || pointIsOnPolygonBoundary(point, polygon: bodyProfile, tolerance: 1e-6)
        }
    }

    private func pointIsOnPolygonBoundary(
        _ point: SketchPoint2D,
        polygon: [SketchPoint2D],
        tolerance: Double
    ) -> Bool {
        guard polygon.count >= 2 else { return false }
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            if closestPointOnSegment(from: point, segA: a, segB: b).distance(to: point) <= tolerance {
                return true
            }
        }
        return false
    }

    private func clamp(_ value: Double, min minValue: Double, max maxValue: Double) -> Double {
        Swift.min(Swift.max(value, minValue), maxValue)
    }

    private func currentProfileArea() -> SketchProfileArea? {
        if let areaID = selectedProfileAreaID,
           let area = sketchProfileGraph?.area(with: areaID),
           area.isExtrudable {
            return area
        }
        if let graph = sketchProfileGraph, graph.count == 1,
           let area = graph.areas.first, area.isExtrudable {
            return area
        }
        return nil
    }

    private func currentProfilePoints() -> [SketchPoint2D]? {
        currentProfileArea()?.outerLoop
    }

    func createSketch() {
        createSketch(on: activeSketchPlane)
    }

    func createSketch(on plane: SketchPlane) {
        activeSketchPlane = plane
        activeSketchReference = .canonicalPlane(plane, offsetMeters: 0)
        selectedWorkPlane = .canonical(plane)
        hoveredWorkPlaneID = selectedWorkPlane?.id
        workPlaneQuickAction = nil
        let name = uniqueNumberedName(base: localized("cad.kind.sketch"))
        let sketch = DesignSketch(name: name, reference: activeSketchReference)
        let asset = DesignAsset(
            name: name,
            kind: .sketch2D(SketchAssetParameters(sketch: sketch)),
            material: .composite
        )
        document.addAsset(asset)
        selectedAttachmentPointID = nil
        selectedFaceID = nil
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        activeToolMode = .sketchLine
        resetDrawingToolStates(activating: .sketchLine)
        refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: plane))
        pendingCameraCommand = CADPreviewCameraCommand(
            target: .viewPreset(.normalToReference(activeSketchReference), .workPlane(.canonical(plane)))
        )
    }

    func createSketchOnSelectedFace() {
        guard let face = selectedPlanarFace else {
            sketchWarningKey = "cad.warning.face_required"
            return
        }
        createSketch(on: .face(face))
    }

    func createSketch(on workPlane: CADWorkPlane) {
        switch workPlane {
        case let .canonical(plane):
            createSketch(on: plane)
        case let .face(face):
            createSketch(onFace: face)
        }
    }

    private func createSketch(onFace face: DesignPlanarFace) {
        let reference = SketchReference.planarFace(face.reference)
        activeSketchReference = reference
        activeSketchPlane = reference.plane
        selectedWorkPlane = .face(face)
        hoveredWorkPlaneID = selectedWorkPlane?.id
        workPlaneQuickAction = nil
        document.selectAsset(face.assetID)
        selectedFaceID = face.id
        let name = uniqueNumberedName(base: localized("cad.sketch.face_base_name"))
        let sketch = DesignSketch(name: name, reference: reference)
        let asset = DesignAsset(
            name: name,
            kind: .sketch2D(SketchAssetParameters(sketch: sketch)),
            material: .composite
        )
        document.addAsset(asset)
        selectedAttachmentPointID = nil
        selectedFaceID = nil
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        activeToolMode = .sketchLine
        resetDrawingToolStates(activating: .sketchLine)
        sketchWarningKey = nil
        refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: reference.plane))
        pendingCameraCommand = CADPreviewCameraCommand(
            target: .viewPreset(.normalToReference(reference), .workPlane(.face(face)))
        )
    }

    // MARK: Selection

    func selectAsset(_ id: UUID?) {
        let previousAssetID = document.selectedAssetID
        document.selectAsset(id)
        if previousAssetID != id {
            clearAllTransientCADNodes(resetOperation: false)
        }
        selectedCutFeatureID = nil
        selectedCutTargetBodyID = nil
        extrudeWarningKey = nil
        selectedFaceID = nil
        selectedWorkPlane = nil
        hoveredWorkPlaneID = nil
        workPlaneQuickAction = nil
        syncSelectionStateForSelectedAsset()
    }

    func selectCutFeature(bodyID: UUID, cutID: UUID) {
        guard let asset = document.assets.first(where: { $0.id == bodyID }),
              case let .extrudedSolid(params) = asset.kind,
              params.boxBlindCutFeatures.contains(where: { $0.id == cutID }) else {
            return
        }
        document.selectAsset(bodyID)
        selectedCutTargetBodyID = bodyID
        selectedCutFeatureID = cutID
        selectedAttachmentPointID = nil
        selectedFaceID = nil
        selectedWorkPlane = nil
        hoveredWorkPlaneID = nil
        workPlaneQuickAction = nil
        clearAllTransientCADNodes(resetOperation: false)
        refreshViewportState()
    }

    /// Select a sketch from the tree and immediately transition to its native 2D view.
    func selectSketchAndEnterNative(_ assetID: UUID) {
        selectAsset(assetID)
        guard let sketch = selectedSketch else { return }
        activeSketchReference = sketch.reference
        activeSketchPlane = sketch.reference.plane
        let preset = CADViewPreset.normalToReference(sketch.reference)
        refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: sketch.reference.plane))
        pendingCameraCommand = CADPreviewCameraCommand(target: .viewPreset(preset, .selectedOrAll))
    }

    func selectAttachmentPoint(_ id: UUID?) {
        guard let id,
              selectedAsset?.attachmentPoints.contains(where: { $0.id == id }) == true else {
            selectedAttachmentPointID = nil
            refreshViewportState()
            return
        }
        selectedAttachmentPointID = id
        selectedFaceID = nil
        selectedSketchEntityID = nil
        selectedSketchEntityIDs = []
        selectedSketchLineID = nil
        refreshViewportState()
    }

    func selectSketchLine(_ id: UUID?) {
        selectSketchEntity(id)
    }

    func selectSketchEntity(_ id: UUID?) {
        guard let id,
              let entity = selectedSketch?.entity(with: id) else {
            selectedSketchLineID = nil
            selectedSketchEntityID = nil
            selectedSketchEntityIDs = []
            refreshViewportState()
            return
        }
        selectedSketchEntityID = id
        selectedSketchEntityIDs = [id]
        selectedSketchLineID = entity.line?.id
        sketchWarningKey = nil
        refreshViewportState()
    }

    func toggleSketchEntitySelection(_ id: UUID?) {
        guard let id, let entity = selectedSketch?.entity(with: id) else { return }
        if selectedSketchEntityIDs.contains(id) {
            selectedSketchEntityIDs.remove(id)
            if selectedSketchEntityID == id {
                selectedSketchEntityID = selectedSketchEntityIDs.first
                selectedSketchLineID = selectedSketchEntityID.flatMap { selectedSketch?.entity(with: $0)?.line?.id }
            }
        } else {
            selectedSketchEntityIDs.insert(id)
            selectedSketchEntityID = id
            selectedSketchLineID = entity.line?.id
        }
        sketchWarningKey = nil
        refreshViewportState()
    }

    func selectPlanarFace(_ id: UUID?) {
        guard let id,
              let selectedAsset,
              case let .extrudedSolid(parameters) = selectedAsset.kind,
              let face = parameters.faces.first(where: { $0.id == id }) else {
            selectedFaceID = nil
            selectedCutFeatureID = nil
            selectedCutTargetBodyID = nil
            selectedWorkPlane = nil
            workPlaneQuickAction = nil
            refreshViewportState()
            return
        }
        selectedFaceID = id
        selectedCutFeatureID = nil
        selectedCutTargetBodyID = nil
        selectedWorkPlane = .face(face)
        hoveredWorkPlaneID = selectedWorkPlane?.id
        workPlaneQuickAction = nil
        selectedAttachmentPointID = nil
        sketchWarningKey = "cad.info.face_sketch_available"
        refreshViewportState()
    }

    func hoverWorkPlane(_ workPlane: CADWorkPlane?) {
        guard !activeToolMode.isSketchDrawingTool else { return }
        let nextID = workPlane?.id
        guard hoveredWorkPlaneID != nextID else { return }
        hoveredWorkPlaneID = nextID
        refreshViewportState()
    }

    func selectWorkPlane(_ workPlane: CADWorkPlane?, at screenPoint: CGPoint?, showQuickActions: Bool) {
        guard !activeToolMode.isSketchDrawingTool else { return }
        selectedWorkPlane = workPlane
        hoveredWorkPlaneID = workPlane?.id
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        selectedAttachmentPointID = nil

        guard let workPlane else {
            selectedFaceID = nil
            workPlaneQuickAction = nil
            refreshViewportState()
            return
        }

        switch workPlane {
        case let .canonical(plane):
            document.selectAsset(nil)
            selectedFaceID = nil
            activeSketchPlane = plane
            activeSketchReference = workPlane.reference
        case let .face(face):
            document.selectAsset(face.assetID)
            selectedFaceID = face.id
            activeSketchPlane = workPlane.reference.plane
            activeSketchReference = workPlane.reference
            sketchWarningKey = "cad.info.face_sketch_available"
        }

        if showQuickActions {
            workPlaneQuickAction = CADWorkPlaneQuickAction(
                workPlane: workPlane,
                screenPoint: screenPoint ?? CGPoint(x: 260, y: 120)
            )
        } else {
            workPlaneQuickAction = nil
        }
        refreshViewportState(viewMode: .free3D)
    }

    // MARK: Camera / canvas

    func applyCameraMode(_ mode: CADCameraMode) {
        switch mode {
        case .fit:
            requestViewPreset(.fitSelected, focus: .selectedOrAll)
        case .iso:
            requestViewPreset(.iso, focus: .selectedOrAll)
        case .top:
            requestViewPreset(.xz, focus: .selectedOrAll)
        case .front:
            requestViewPreset(.xy, focus: .selectedOrAll)
        case .side:
            requestViewPreset(.yz, focus: .selectedOrAll)
        }
    }

    private func requestViewPreset(
        _ preset: CADViewPreset,
        focus: CADFocusTarget = .selectedOrAll,
        viewMode forcedViewMode: SketchViewMode? = nil
    ) {
        CADViewportDebug.log("View preset requested: \(preset)")
        CADViewportDebug.log("ViewMode before: \(viewportState.viewMode.rawValue), orientation before: \(viewportState.orientation.rawValue)")
        CADViewportDebug.log("Selected asset ID: \(document.selectedAssetID?.uuidString ?? "nil")")
        CADViewportDebug.log("Selected sketch ID: \(selectedSketch?.id.uuidString ?? "nil")")
        activeToolMode = .select
        lineToolState = LineToolState()
        selectedSketchLineID = nil
        refreshViewportState(
            viewMode: forcedViewMode ?? viewMode(for: preset),
            orientation: cameraMode(for: preset)
        )
        CADViewportDebug.log("ViewMode after: \(viewportState.viewMode.rawValue), orientation after: \(viewportState.orientation.rawValue)")
        pendingCameraCommand = CADPreviewCameraCommand(target: .viewPreset(preset, focus))
    }

    func focusSelectionOrFit() {
        if let selectedAssetID = document.selectedAssetID {
            requestViewPreset(.fitSelected, focus: .asset(selectedAssetID))
        } else if !document.assets.isEmpty {
            requestViewPreset(.fitAll, focus: .all)
        } else {
            requestViewPreset(.iso, focus: .origin)
        }
    }

    func setShowGrid(_ isVisible: Bool) {
        var options = canvasOptions
        options.showGrid = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    func setShowAxes(_ isVisible: Bool) {
        var options = canvasOptions
        options.showAxes = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    func setShowReferencePlanes(_ isVisible: Bool) {
        var options = canvasOptions
        options.showReferencePlanes = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    func setShowActivePlaneOverlay(_ isVisible: Bool) {
        var options = canvasOptions
        options.showActivePlaneOverlay = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    func setShowAttachmentPoints(_ isVisible: Bool) {
        var options = canvasOptions
        options.showAttachmentPoints = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapEnabled(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.isEnabled = isEnabled
        canvasOptions = options
        if !isEnabled {
            lineToolState.snapResult = nil
        }
        refreshViewportState()
    }

    func setSnapToGrid(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToGrid = isEnabled
        if isEnabled {
            options.snapOptions.isEnabled = true
        }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToSketchVertices(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToSketchVertices = isEnabled
        if isEnabled {
            options.snapOptions.isEnabled = true
        }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToBodyVertices(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToBodyVertices = isEnabled
        if isEnabled {
            options.snapOptions.isEnabled = true
        }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToBodyEdges(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToBodyEdges = isEnabled
        if isEnabled {
            options.snapOptions.isEnabled = true
        }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToEdgeMidpoints(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToEdgeMidpoints = isEnabled
        if isEnabled {
            options.snapOptions.isEnabled = true
        }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToConstructionPoints(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToConstructionPoints = isEnabled
        if isEnabled { options.snapOptions.isEnabled = true }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToConstructionLines(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToConstructionLines = isEnabled
        if isEnabled { options.snapOptions.isEnabled = true }
        canvasOptions = options
        refreshViewportState()
    }

    func setSnapToConstructionIntersections(_ isEnabled: Bool) {
        var options = canvasOptions
        options.snapOptions.snapToConstructionIntersections = isEnabled
        if isEnabled { options.snapOptions.isEnabled = true }
        canvasOptions = options
        refreshViewportState()
    }

    func setShowConstraintGlyphs(_ isVisible: Bool) {
        var options = canvasOptions
        options.showConstraintGlyphs = isVisible
        canvasOptions = options
        refreshViewportState()
    }

    // MARK: - Parametric Tool Input

    func setActiveLineLength(_ meters: Double) {
        guard meters > 0.0001,
              case let .waitingForEnd(start) = lineToolState.phase else { return }
        let angle = lineToolState.currentAngleDegrees ?? 0
        let rad = angle * Double.pi / 180.0
        lineToolState.cursorPoint = SketchPoint2D(u: start.u + cos(rad) * meters,
                                                  v: start.v + sin(rad) * meters)
        lineToolState.snapResult = nil
    }

    func setActiveLineAngle(_ degrees: Double) {
        guard case let .waitingForEnd(start) = lineToolState.phase else { return }
        let len = lineToolState.currentLengthMeters ?? 0.1
        let rad = degrees * Double.pi / 180.0
        lineToolState.cursorPoint = SketchPoint2D(u: start.u + cos(rad) * len,
                                                  v: start.v + sin(rad) * len)
        lineToolState.snapResult = nil
    }

    func setActiveRectangleWidth(_ meters: Double) {
        guard meters > 0.0001,
              case let .waitingForOppositeCorner(firstCorner) = rectangleToolState.phase else { return }
        let signU = (rectangleToolState.cursorPoint.u >= firstCorner.u) ? 1.0 : -1.0
        let currentH = rectangleToolState.heightMeters ?? 0.1
        rectangleToolState.cursorPoint = SketchPoint2D(u: firstCorner.u + signU * meters,
                                                       v: firstCorner.v + (currentH >= 0 ? currentH : -currentH) * ((rectangleToolState.cursorPoint.v >= firstCorner.v) ? 1.0 : -1.0))
        rectangleToolState.snapResult = nil
    }

    func setActiveRectangleHeight(_ meters: Double) {
        guard meters > 0.0001,
              case let .waitingForOppositeCorner(firstCorner) = rectangleToolState.phase else { return }
        let signV = (rectangleToolState.cursorPoint.v >= firstCorner.v) ? 1.0 : -1.0
        let currentW = rectangleToolState.widthMeters ?? 0.1
        rectangleToolState.cursorPoint = SketchPoint2D(u: firstCorner.u + (currentW >= 0 ? currentW : -currentW) * ((rectangleToolState.cursorPoint.u >= firstCorner.u) ? 1.0 : -1.0),
                                                       v: firstCorner.v + signV * meters)
        rectangleToolState.snapResult = nil
    }

    func setActiveCircleRadius(_ meters: Double) {
        guard meters > 0.0001,
              case let .waitingForRadius(center) = circleToolState.phase else { return }
        let currentDir: SketchPoint2D
        let existing = circleToolState.cursorPoint
        let dist = center.distance(to: existing)
        if dist > 1e-6 {
            let scale = meters / dist
            currentDir = SketchPoint2D(u: center.u + (existing.u - center.u) * scale,
                                       v: center.v + (existing.v - center.v) * scale)
        } else {
            currentDir = SketchPoint2D(u: center.u + meters, v: center.v)
        }
        circleToolState.cursorPoint = currentDir
        circleToolState.snapResult = nil
    }

    func setActiveCircleDiameter(_ meters: Double) {
        setActiveCircleRadius(meters / 2.0)
    }

    // MARK: - Construction Tool Methods

    func setConstructionToolSubMode(_ mode: ConstructionToolSubMode) {
        constructionToolState.subMode = mode
        constructionToolState.firstPoint = nil
    }

    func setConstructionAngle(_ degrees: Double) {
        constructionToolState.angleDegrees = degrees.isFinite ? degrees : 0
    }

    func cancelConstructionTool() {
        constructionToolState.reset()
        activeToolMode = .select
        refreshViewportState()
    }

    func deleteSelectedSketchEntity() {
        let ids = selectedSketchEntityIDs.isEmpty
            ? (selectedSketchEntityID.map { [$0] } ?? [])
            : Array(selectedSketchEntityIDs)
        guard !ids.isEmpty,
              var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        parameters.sketch.entities.removeAll { ids.contains($0.id) }
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchEntityID = nil
        selectedSketchLineID = nil
        selectedSketchEntityIDs = []
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func copySelectedSketchEntity() {
        let ids = selectedSketchEntityIDs.isEmpty
            ? (selectedSketchEntityID.map { [$0] } ?? [])
            : Array(selectedSketchEntityIDs)
        sketchClipboard = ids.compactMap { selectedSketch?.entity(with: $0) }
    }

    func pasteSketchEntity() {
        guard !sketchClipboard.isEmpty,
              var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let offset = SketchPoint2D(u: 0.05, v: 0.05)
        var pastedIDs: [UUID] = []
        for entity in sketchClipboard {
            let pasted = entity.translated(by: offset).withNewID()
            parameters.sketch.entities.append(pasted)
            pastedIDs.append(pasted.id)
        }
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchEntityID = pastedIDs.last
        selectedSketchLineID = pastedIDs.last.flatMap { id in parameters.sketch.entities.first { $0.id == id }?.line?.id }
        selectedSketchEntityIDs = Set(pastedIDs)
        sketchWarningKey = nil
        refreshViewportState()
    }

    private func handleConstructionToolClick(_ snapResult: CADSnapResult) {
        let point = snapResult.point
        switch constructionToolState.subMode {
        case .segmentByTwoPoints:
            if let start = constructionToolState.firstPoint {
                guard point.distance(to: start) > 0.0005 else { return }
                addConstructionSegment(start: start, end: point)
                constructionToolState.firstPoint = nil
            } else {
                constructionToolState.firstPoint = point
            }
        case .horizontalThroughPoint:
            addConstructionHorizontal(throughPoint: point)
        case .verticalThroughPoint:
            addConstructionVertical(throughPoint: point)
        case .pointAndAngle:
            addConstructionAngle(throughPoint: point, angleDegrees: constructionToolState.angleDegrees)
        }
    }

    // MARK: - Move / Copy

    private func handleMoveToolClick(_ snapResult: CADSnapResult) {
        let point = snapResult.point
        let opName = sketchMoveToolState.isCopy ? "Copy" : "Move"
        switch sketchMoveToolState.phase {
        case .idle:
            guard let entity = selectedSketchEntity else {
                print("[CAD-\(opName)] no-op: no entity selected")
                return
            }
            print("[CAD-\(opName)] grab entity \(entity.id) at (\(point.u), \(point.v))")
            sketchMoveToolState.phase = .waitingForDestination(grabPoint: point, original: entity)
        case let .waitingForDestination(grab, original):
            let delta = SketchPoint2D(u: point.u - grab.u, v: point.v - grab.v)
            print("[CAD-\(opName)] apply to entity \(original.id), delta=(\(delta.u), \(delta.v))")
            applyMoveOrCopy(original: original, delta: delta, isCopy: sketchMoveToolState.isCopy)
            sketchMoveToolState.phase = .idle
        }
    }

    private func applyMoveOrCopy(original: SketchEntity, delta: SketchPoint2D, isCopy: Bool) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let translated = original.translated(by: delta)
        if isCopy {
            let copy = translated.withNewID()
            parameters.sketch.entities.append(copy)
            parameters.sketch.refreshClosedStatus()
            asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
            asset.updateDerivedProperties()
            document.updateAsset(asset)
            selectedSketchEntityID = copy.id
            selectedSketchEntityIDs = [copy.id]
            selectedSketchLineID = copy.line?.id
        } else {
            if let idx = parameters.sketch.entities.firstIndex(where: { $0.id == original.id }) {
                parameters.sketch.entities[idx] = translated
            }
            parameters.sketch.refreshClosedStatus()
            asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
            asset.updateDerivedProperties()
            document.updateAsset(asset)
            selectedSketchEntityID = translated.id
            selectedSketchEntityIDs = [translated.id]
            selectedSketchLineID = translated.line?.id
        }
        refreshViewportState()
    }

    func startMoveOperation() {
        guard selectedSketchEntity != nil else { return }
        setToolMode(.sketchMove)
    }

    func startCopyOperation() {
        guard selectedSketchEntity != nil else { return }
        setToolMode(.sketchCopy)
    }

    // MARK: - Direct Manipulation Drag

    func beginEntityDrag(entityID: UUID) {
        guard let sketch = selectedSketch else { return }
        // Move all currently selected entities if the dragged entity is part of the selection.
        let dragIDs: Set<UUID>
        if selectedSketchEntityIDs.contains(entityID) {
            dragIDs = selectedSketchEntityIDs
        } else {
            dragIDs = [entityID]
            selectSketchEntity(entityID)
        }
        entityDragSnapshots = Dictionary(uniqueKeysWithValues: dragIDs.compactMap { id in
            sketch.entity(with: id).map { (id, $0) }
        })
        entityDragID = entityID
    }

    func updateEntityDrag(totalDelta: SketchPoint2D) {
        guard !entityDragSnapshots.isEmpty else { return }
        movePreviewDelta = totalDelta
        movePreviewEntityIDs = Set(entityDragSnapshots.keys)
        refreshViewportState()
    }

    func endEntityDrag(totalDelta: SketchPoint2D) {
        commitEntityDrag()
    }

    func commitEntityDrag() {
        guard !entityDragSnapshots.isEmpty,
              let delta = movePreviewDelta,
              var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else {
            clearEntityDragState()
            return
        }
        for (id, snapshot) in entityDragSnapshots {
            if let idx = parameters.sketch.entities.firstIndex(where: { $0.id == id }) {
                parameters.sketch.entities[idx] = snapshot.translated(by: delta)
            }
        }
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        clearEntityDragState()
        refreshViewportState()
    }

    func cancelEntityDrag() {
        clearEntityDragState()
        refreshViewportState()
    }

    private func clearEntityDragState() {
        movePreviewDelta = nil
        movePreviewEntityIDs = []
        entityDragSnapshots = [:]
        entityDragID = nil
    }

    // MARK: - Split

    private func handleSplitToolClick(_ snapResult: CADSnapResult) {
        let point = snapResult.point
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let entityID = selectedSketchEntityID,
              let lineIdx = parameters.sketch.entities.firstIndex(where: { $0.id == entityID }),
              let line = parameters.sketch.entities[lineIdx].line else { return }
        let split = closestPointOnSegment(from: point, segA: line.start, segB: line.end)
        guard split.distance(to: line.start) > 0.0002, split.distance(to: line.end) > 0.0002 else { return }
        let lineA = SketchLine(start: line.start, end: split, constructionStyle: line.constructionStyle, lineStyle: line.lineStyle)
        let lineB = SketchLine(start: split, end: line.end, constructionStyle: line.constructionStyle, lineStyle: line.lineStyle)
        parameters.sketch.entities.remove(at: lineIdx)
        parameters.sketch.entities.insert(.line(lineB), at: lineIdx)
        parameters.sketch.entities.insert(.line(lineA), at: lineIdx)
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchEntityID = lineA.id
        selectedSketchLineID = lineA.id
        refreshViewportState()
    }

    func splitSelectedLine(at point: SketchPoint2D) {
        handleSplitToolClick(CADSnapResult(rawPoint: point, point: point, screenPoint: .zero, kind: .grid))
    }

    // MARK: - Trim

    private func handleTrimToolClick(_ snapResult: CADSnapResult) {
        guard let sketch = selectedSketch else { return }
        if trimExtendOpState != nil {
            // Phase 2: click is ignored — user must press Enter to apply or Escape to cancel.
            return
        }
        // Phase 1: lock the nearest endpoint as the operation anchor.
        lockTrimExtendEndpoint(at: snapResult.point, in: sketch, tool: .sketchTrim)
    }

    // MARK: - Extend

    private func handleExtendToolClick(_ snapResult: CADSnapResult) {
        guard let sketch = selectedSketch else { return }
        if trimExtendOpState != nil {
            return
        }
        lockTrimExtendEndpoint(at: snapResult.point, in: sketch, tool: .sketchExtend)
    }

    // Phase 1: pick the nearest endpoint and lock it as the operation anchor.
    private func lockTrimExtendEndpoint(at cursor: SketchPoint2D, in sketch: DesignSketch, tool: DesignWorkshopToolMode) {
        guard let (line, fromStart) = nearestEndpointForTrimExtend(at: cursor, in: sketch) else {
            sketchWarningKey = "cad.warning.select_line_first"
            return
        }
        let anchor = fromStart ? line.start : line.end
        let opposite = fromStart ? line.end : line.start
        var op = TrimExtendOperationState(
            operationType: tool,
            targetLineID: line.id,
            fromStart: fromStart,
            originalStart: line.start,
            originalEnd: line.end,
            anchorPoint: anchor,
            oppositePoint: opposite
        )
        // Compute initial target-mode preview from current cursor position.
        let initSnap = sketchSplitToolState.snapResult ?? CADSnapResult(rawPoint: cursor, point: cursor, screenPoint: .zero, kind: nil)
        updateTargetModePreview(snapResult: initSnap, sketch: sketch, op: &op)
        trimExtendOpState = op
        syncPhantomFromOpState(op)
        sketchWarningKey = nil
        print("[CAD] \(tool == .sketchTrim ? "trim" : "extend"): locked line=\(line.id) endpoint=\(fromStart ? "start" : "end")")
        refreshViewportState()
    }

    // Returns the nearest (line, fromStart) across all lines in the sketch, including construction lines.
    private func nearestEndpointForTrimExtend(at cursor: SketchPoint2D, in sketch: DesignSketch) -> (SketchLine, Bool)? {
        var bestDist = Double.infinity
        var bestLine: SketchLine? = nil
        var bestFromStart = true
        for entity in sketch.entities {
            guard let line = entity.line else { continue }
            let ds = cursor.distance(to: line.start)
            let de = cursor.distance(to: line.end)
            if ds < bestDist { bestDist = ds; bestLine = line; bestFromStart = true }
            if de < bestDist { bestDist = de; bestLine = line; bestFromStart = false }
        }
        return bestLine.map { ($0, bestFromStart) }
    }

    // Phase 2 cursor update: recompute target-mode preview from new cursor/snap position.
    private func updateTrimExtendFromCursor(snapResult: CADSnapResult, in sketch: DesignSketch) {
        guard var op = trimExtendOpState, op.mode == .target else { return }
        updateTargetModePreview(snapResult: snapResult, sketch: sketch, op: &op)
        trimExtendOpState = op
        syncPhantomFromOpState(op)
    }

    // Compute target-mode preview.
    //
    // Priority:
    //   1. Nearest line-line intersection in the valid operation direction (primary CAD snap).
    //   2. Cursor projection fallback — projects the cursor orthogonally onto the extension
    //      ray (Extend) or the current segment (Trim) so phantom always appears after endpoint
    //      selection, even when there is no intersecting geometry nearby.
    //
    // "Nearest" for intersection is nearest by parametric t on the ray, not cursor distance.
    // Snap from the snap system (grid/vertex/midpoint) is already baked into snapResult.point.
    private func updateTargetModePreview(snapResult: CADSnapResult, sketch: DesignSketch, op: inout TrimExtendOperationState) {
        let cursor = snapResult.point
        let anchor = op.anchorPoint
        let opposite = op.oppositePoint
        let isExtend = op.operationType == .sketchExtend

        // Compute unit operation direction.
        let rawDir: SketchPoint2D = isExtend
            ? SketchPoint2D(u: anchor.u - opposite.u, v: anchor.v - opposite.v)
            : SketchPoint2D(u: opposite.u - anchor.u, v: opposite.v - anchor.v)
        let rawLen = sqrt(rawDir.u * rawDir.u + rawDir.v * rawDir.v)
        guard rawLen > 1e-9 else {
            op.isPreviewActive = false; op.validation = .zeroResultLength; op.targetType = .none
            return
        }
        let dir = SketchPoint2D(u: rawDir.u / rawLen, v: rawDir.v / rawLen)
        let lineLen = rawLen  // distance from anchor to opposite

        // -- Step 1: find nearest valid line-line intersection along the ray --
        let otherLines = sketch.entities.compactMap(\.line).filter { $0.id != op.targetLineID }
        var bestIntersectionT = Double.infinity
        var bestIntersectionPt: SketchPoint2D? = nil
        for other in otherLines {
            if let pt = raySegmentIntersect(origin: anchor, direction: dir, segA: other.start, segB: other.end) {
                let t = (pt.u - anchor.u) * dir.u + (pt.v - anchor.v) * dir.v
                guard t > 0.0002 else { continue }
                if isExtend {
                    if t < bestIntersectionT { bestIntersectionT = t; bestIntersectionPt = pt }
                } else {
                    // Trim: must lie strictly between anchor and opposite.
                    if t < lineLen - 0.0002, t < bestIntersectionT {
                        bestIntersectionT = t; bestIntersectionPt = pt
                    }
                }
            }
        }

        // -- Step 2: compute cursor projection onto the operation ray (fallback) --
        let tCursor = (cursor.u - anchor.u) * dir.u + (cursor.v - anchor.v) * dir.v
        var cursorProjT: Double? = nil
        if isExtend {
            if tCursor > 0.0002 { cursorProjT = tCursor }
        } else {
            // For trim: clamp projection to inside the segment.
            let tc = min(max(tCursor, 0.0002), lineLen - 0.0002)
            if tc > 0.0001 && tc < lineLen - 0.0001 { cursorProjT = tc }
        }

        // -- Step 3: choose best target --
        // Intersection wins if it exists and cursor is near the ray.
        // Cursor projection wins otherwise (always shows phantom after anchor selection).
        var finalPt: SketchPoint2D? = nil
        var finalType: TrimExtendTargetType = .none

        if let intPt = bestIntersectionPt {
            // Use intersection; for Extend, prefer the one nearest to the cursor projection
            // so the user can "aim" at different targets by moving the cursor.
            if isExtend, let tc = cursorProjT {
                // Snap to intersection only when it's the closest one on the cursor side.
                // If cursor projects beyond the intersection, use intersection.
                // If cursor projects before the intersection, use cursor projection (user hasn't reached it).
                if tc >= bestIntersectionT - 0.001 {
                    finalPt = intPt; finalType = .intersection
                } else {
                    // Cursor is before the intersection — use cursor projection.
                    let projPt = SketchPoint2D(u: anchor.u + dir.u * tc, v: anchor.v + dir.v * tc)
                    finalPt = projPt; finalType = snapTargetType(from: snapResult)
                }
            } else {
                // For Trim, always use nearest valid intersection when it exists.
                finalPt = intPt; finalType = .intersection
            }
        } else if let tc = cursorProjT {
            let projPt = SketchPoint2D(u: anchor.u + dir.u * tc, v: anchor.v + dir.v * tc)
            finalPt = projPt; finalType = snapTargetType(from: snapResult)
        }

        // -- Validate and commit --
        if let target = finalPt, target.u.isFinite, target.v.isFinite {
            op.candidateTargetPoint = target
            op.previewAnchorPoint = target
            op.isPreviewActive = true
            op.validation = .valid
            op.targetType = finalType
            print("[CAD] \(isExtend ? "extend" : "trim") preview: mode=target type=\(finalType) newAnchor=(\(String(format: "%.4f", target.u)),\(String(format: "%.4f", target.v)))")
        } else {
            op.candidateTargetPoint = nil
            op.previewAnchorPoint = nil
            op.isPreviewActive = false
            op.validation = .noTarget
            op.targetType = .none
        }
    }

    private func snapTargetType(from snapResult: CADSnapResult) -> TrimExtendTargetType {
        switch snapResult.kind {
        case .grid:                                       return .snapGrid
        case .sketchVertex, .bodyVertex, .constructionVertex,
             .referenceSketchVertex, .projectedSketchVertex: return .snapVertex
        case .edgeMidpoint, .referenceSketchEdgeMidpoint,
             .projectedSketchEdgeMidpoint:                return .snapMidpoint
        default:                                          return .cursorProjection
        }
    }

    // Called from the right panel when the user types a numeric distance.
    // mm == 0 means the field was cleared → return to target mode and restore cursor preview.
    func setTrimExtendNumericDistance(_ mm: Double) {
        guard var op = trimExtendOpState else { return }
        op.numericDistanceMM = mm
        if mm > 0 {
            op.mode = .numeric
            updateNumericModePreview(op: &op)
        } else {
            op.mode = .target
            // Restore target-mode preview from the last known cursor/snap position.
            if let sketch = selectedSketch {
                let snap = sketchSplitToolState.snapResult
                    ?? CADSnapResult(rawPoint: sketchSplitToolState.cursorPoint,
                                     point: sketchSplitToolState.cursorPoint,
                                     screenPoint: .zero, kind: nil)
                updateTargetModePreview(snapResult: snap, sketch: sketch, op: &op)
            } else {
                op.isPreviewActive = false
                op.validation = .noTarget
                op.targetType = .none
            }
        }
        trimExtendOpState = op
        syncPhantomFromOpState(op)
    }

    // Compute numeric-mode preview: move anchor by fixed distance along the operation direction.
    private func updateNumericModePreview(op: inout TrimExtendOperationState) {
        let mm = op.numericDistanceMM
        guard mm > 0 else {
            op.isPreviewActive = false; op.validation = .distanceZero; return
        }
        let meters = mm / 1000.0
        let anchor = op.anchorPoint
        let opposite = op.oppositePoint
        let isExtend = op.operationType == .sketchExtend

        let rawDir: SketchPoint2D = isExtend
            ? SketchPoint2D(u: anchor.u - opposite.u, v: anchor.v - opposite.v)
            : SketchPoint2D(u: opposite.u - anchor.u, v: opposite.v - anchor.v)
        let rawLen = sqrt(rawDir.u * rawDir.u + rawDir.v * rawDir.v)
        guard rawLen > 1e-9 else {
            op.isPreviewActive = false; op.validation = .zeroResultLength; return
        }
        let dir = SketchPoint2D(u: rawDir.u / rawLen, v: rawDir.v / rawLen)

        if !isExtend {
            // Trim: distance must not reach or exceed the opposite endpoint.
            if meters >= rawLen - 0.0001 {
                op.isPreviewActive = false; op.validation = .distanceExceedsLength; return
            }
        }

        let newAnchor = SketchPoint2D(
            u: anchor.u + dir.u * meters,
            v: anchor.v + dir.v * meters
        )
        guard newAnchor.u.isFinite && newAnchor.v.isFinite else {
            op.isPreviewActive = false; op.validation = .zeroResultLength; return
        }
        op.previewAnchorPoint = newAnchor
        op.isPreviewActive = true
        op.validation = .valid
    }

    // Apply current valid preview to the model.
    func applyTrimExtendOperation() {
        guard let op = trimExtendOpState,
              op.isPreviewActive,
              let newAnchor = op.previewAnchorPoint else { return }
        let newStart = op.fromStart ? newAnchor : op.originalStart
        let newEnd   = op.fromStart ? op.originalEnd : newAnchor
        guard newStart.distance(to: newEnd) > 0.0001 else { return }

        applyTrimExtendEndpoint(entityID: op.targetLineID, fromStart: op.fromStart, newEndpoint: newAnchor)
        trimExtendOpState = nil
        sketchSplitToolState.phantomPoints = nil
        sketchSplitToolState.pendingNewEndpoint = nil
        print("[CAD] \(op.operationType == .sketchTrim ? "trim" : "extend") applied: line=\(op.targetLineID) result=applied")
    }

    // Cancel Phase 2 — returns to Phase 1 (picking endpoint), model unchanged.
    func cancelTrimExtendOperation() {
        guard trimExtendOpState != nil else { return }
        trimExtendOpState = nil
        sketchSplitToolState.phantomPoints = nil
        sketchSplitToolState.pendingNewEndpoint = nil
        sketchSplitToolState.hoveredEntityID = nil
        sketchSplitToolState.hoveredFromStart = nil
        refreshViewportState()
        print("[CAD] trim/extend cancelled")
    }

    // Bridge operation state into sketchSplitToolState.phantomPoints so the existing scene pipeline renders it.
    private func syncPhantomFromOpState(_ op: TrimExtendOperationState) {
        sketchSplitToolState.hoveredEntityID = op.targetLineID
        sketchSplitToolState.hoveredFromStart = op.fromStart
        if op.isPreviewActive, let newAnchor = op.previewAnchorPoint {
            let pts: [SketchPoint2D] = op.fromStart
                ? [newAnchor, op.oppositePoint]
                : [op.oppositePoint, newAnchor]
            sketchSplitToolState.phantomPoints = pts
            sketchSplitToolState.pendingNewEndpoint = newAnchor
        } else {
            sketchSplitToolState.phantomPoints = nil
            sketchSplitToolState.pendingNewEndpoint = nil
        }
    }

    // Shared apply: moves one endpoint of a line to newEndpoint, preserving all style properties.
    func applyTrimExtendEndpoint(entityID: UUID, fromStart: Bool, newEndpoint: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let idx = parameters.sketch.entities.firstIndex(where: { $0.id == entityID }),
              var line = parameters.sketch.entities[idx].line else { return }
        if fromStart { line.start = newEndpoint } else { line.end = newEndpoint }
        parameters.sketch.entities[idx] = .line(line)
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        sketchWarningKey = nil
        refreshViewportState()
    }

    // Apply trim/extend by a fixed distance from the panel Apply button (sets numeric mode and applies).
    func applyTrimExtendByDistance(mm: Double) {
        guard mm > 0 else { return }
        setTrimExtendNumericDistance(mm)
        applyTrimExtendOperation()
        sketchSplitToolState = SketchSplitToolState()
    }

    // MARK: - Parallel / Perpendicular

    private func handleParallelToolClick(_ snapResult: CADSnapResult) {
        let point = snapResult.point
        switch sketchParallelToolState.phase {
        case .waitingForSourceLine:
            guard let sketch = selectedSketch else { return }
            let line = sketch.lines
                .filter { $0.constructionStyle != .construction }
                .min(by: { closestPointOnSegment(from: point, segA: $0.start, segB: $0.end).distance(to: point)
                          < closestPointOnSegment(from: point, segA: $1.start, segB: $1.end).distance(to: point) })
            guard let sourceLine = line else { return }
            sketchParallelToolState.phase = .waitingForThroughPoint(source: sourceLine)
        case let .waitingForThroughPoint(source):
            addParallelOrPerpendicularLine(source: source, throughPoint: point,
                                          isPerpendicular: sketchParallelToolState.isPerpendicular)
            sketchParallelToolState.phase = .waitingForSourceLine
        }
    }

    private func addParallelOrPerpendicularLine(source: SketchLine, throughPoint: SketchPoint2D, isPerpendicular: Bool) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let dx = source.end.u - source.start.u
        let dy = source.end.v - source.start.v
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-9 else { return }
        let (ux, uy): (Double, Double) = isPerpendicular ? (-dy / len, dx / len) : (dx / len, dy / len)
        let halfLen = source.lengthMeters / 2.0
        let newLine = SketchLine(
            start: SketchPoint2D(u: throughPoint.u - ux * halfLen, v: throughPoint.v - uy * halfLen),
            end:   SketchPoint2D(u: throughPoint.u + ux * halfLen, v: throughPoint.v + uy * halfLen),
            constructionStyle: source.constructionStyle,
            lineStyle: source.lineStyle
        )
        parameters.sketch.entities.append(.line(newLine))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchEntityID = newLine.id
        selectedSketchLineID = newLine.id
        refreshViewportState()
    }

    // MARK: - Line Style

    func setLineStyleForSelectedEntity(_ style: CADLineStyle) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let entityID = selectedSketchEntityID,
              let idx = parameters.sketch.entities.firstIndex(where: { $0.id == entityID }) else { return }
        var entity = parameters.sketch.entities[idx]
        switch entity {
        case var .line(l):      l.lineStyle = style;  entity = .line(l)
        case var .rectangle(r): r.lineStyle = style;  entity = .rectangle(r)
        case var .circle(c):    c.lineStyle = style;  entity = .circle(c)
        case var .polyline(p):  p.lineStyle = style;  entity = .polyline(p)
        case var .arc(a):       a.lineStyle = style;  entity = .arc(a)
        }
        parameters.sketch.entities[idx] = entity
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        refreshViewportState()
    }

    func setShowCenterlinesForSelectedCircle(_ show: Bool) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let entityID = selectedSketchEntityID,
              let idx = parameters.sketch.entities.firstIndex(where: { $0.id == entityID }),
              case var .circle(c) = parameters.sketch.entities[idx] else { return }
        c.showCenterlines = show
        parameters.sketch.entities[idx] = .circle(c)
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        refreshViewportState()
    }

    private func addConstructionSegment(start: SketchPoint2D, end: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let line = SketchLine(
            start: sanitizedSketchPoint(start),
            end: sanitizedSketchPoint(end),
            constructionStyle: .construction
        )
        parameters.sketch.entities.append(.line(line))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchEntityID = line.id
        selectedSketchLineID = line.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    private func addConstructionHorizontal(throughPoint: SketchPoint2D) {
        let ext: Double = 5.0
        addConstructionSegment(
            start: SketchPoint2D(u: throughPoint.u - ext, v: throughPoint.v),
            end:   SketchPoint2D(u: throughPoint.u + ext, v: throughPoint.v)
        )
    }

    private func addConstructionVertical(throughPoint: SketchPoint2D) {
        let ext: Double = 5.0
        addConstructionSegment(
            start: SketchPoint2D(u: throughPoint.u, v: throughPoint.v - ext),
            end:   SketchPoint2D(u: throughPoint.u, v: throughPoint.v + ext)
        )
    }

    private func addConstructionAngle(throughPoint: SketchPoint2D, angleDegrees: Double) {
        let ext: Double = 5.0
        let rad = angleDegrees * .pi / 180.0
        let dx = ext * cos(rad)
        let dy = ext * sin(rad)
        addConstructionSegment(
            start: SketchPoint2D(u: throughPoint.u - dx, v: throughPoint.v - dy),
            end:   SketchPoint2D(u: throughPoint.u + dx, v: throughPoint.v + dy)
        )
    }

    func setGridStepMeters(_ step: Double) {
        var options = canvasOptions
        options.snapOptions.gridStepMeters = clampFinite(step, to: 0.01...0.1)
        canvasOptions = options
        refreshViewportState()
    }

    func setToolMode(_ mode: DesignWorkshopToolMode) {
        if featureOperation.isCutV2, featurePreviewState?.operation == .cutRemoveMaterialV2 {
            cancelFeaturePreview()
        }
        if mode.isSketchDrawingTool {
            if selectedSketch == nil {
                createSketch()
                if mode != .sketchLine {
                    setToolMode(mode)
                }
                return
            }
            if let sketch = selectedSketch {
                activeSketchPlane = sketch.plane
                activeSketchReference = sketch.reference
                // Do NOT cancel pendingCameraCommand here — the Representable may not have
                // applied it yet (e.g. face-sketch camera issued by createSketch(onFace:)).
                // The command has a UUID so the Representable applies it exactly once.
            }
            activeToolMode = mode
            resetDrawingToolStates(activating: mode)
            sketchWarningKey = nil
        } else {
            activeToolMode = mode
            resetDrawingToolStates(activating: mode)
        }
        refreshViewportState()
    }

    func selectSketchPlane(_ plane: SketchPlane) {
        let preset = viewPreset(for: plane)

        // Face sketch: view-only (face reference is immutable)
        if let sketch = selectedSketch, !sketch.reference.isCanonical {
            sketchWarningKey = nil
            requestViewPreset(preset, focus: .selectedOrAll, viewMode: .free3D)
            return
        }

        // Filled canonical sketch: plane is locked — XY/XZ/YZ acts as view button
        if let sketch = selectedSketch, sketch.hasGeometry, sketch.plane != plane {
            sketchWarningKey = nil
            requestViewPreset(preset, focus: .selectedOrAll, viewMode: .free3D)
            return
        }

        // Empty canonical sketch, or clicking the filled sketch's own plane:
        //   → normal sketch2D view (camera normal to sketch plane)
        let didChangePlane = activeSketchPlane != plane
        activeSketchPlane = plane
        activeSketchReference = .canonicalPlane(plane, offsetMeters: activeSketchPlaneOffsetMeters)
        selectedWorkPlane = .canonical(plane)
        hoveredWorkPlaneID = selectedWorkPlane?.id
        workPlaneQuickAction = nil
        if didChangePlane {
            resetLinePreviewForPlaneChange()
        }
        sketchWarningKey = nil
        if selectedSketch != nil {
            updateSelectedSketchPlane(plane)
        }
        requestViewPreset(preset, focus: .selectedOrAll, viewMode: .sketch2D)
    }

    /// Set camera to look normal to the selected sketch's reference plane (sketch2D mode).
    func setViewNormalToSketch() {
        let preset: CADViewPreset = selectedSketch.map { .normalToReference($0.reference) } ?? .normalToSketch
        requestViewPreset(preset, focus: .selectedOrAll, viewMode: .sketch2D)
    }

    func setViewNormalTo(workPlane: CADWorkPlane) {
        activeSketchReference = workPlane.reference
        activeSketchPlane = workPlane.reference.plane
        selectedWorkPlane = workPlane
        hoveredWorkPlaneID = workPlane.id
        workPlaneQuickAction = nil
        activeToolMode = .select
        lineToolState = LineToolState()
        refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: workPlane.reference.plane))
        pendingCameraCommand = CADPreviewCameraCommand(
            target: .viewPreset(.normalToReference(workPlane.reference), .workPlane(workPlane))
        )
    }

    func closeWorkPlaneQuickAction() {
        workPlaneQuickAction = nil
    }

    func setActiveSketchPlane(_ plane: SketchPlane) {
        selectSketchPlane(plane)
    }

    // MARK: Deletion / Duplication

    func deleteSelectedAsset() {
        guard let id = document.selectedAssetID else { return }
        clearAllTransientCADNodes(resetOperation: false)
        document.removeAsset(id: id)
        syncSelectionStateForSelectedAsset()
        focusSelectionOrFit()
    }

    func deleteSelectedCutFeature() {
        guard let bodyID = selectedCutTargetBodyID,
              let cutID = selectedCutFeatureID,
              let bodyIndex = document.assets.firstIndex(where: { $0.id == bodyID }),
              case var .extrudedSolid(params) = document.assets[bodyIndex].kind else {
            return
        }

        let originalCount = params.boxBlindCutFeatures.count
        params.boxBlindCutFeatures.removeAll { $0.id == cutID }
        guard params.boxBlindCutFeatures.count != originalCount else { return }

        params.kernelResultSolid = nil
        params.kernelVisualMesh = nil
        params.refreshFaces(assetID: bodyID)

        if !params.boxBlindCutFeatures.isEmpty {
            guard let rebuild = CADCutMeshRebuilder.rebuildBodyMesh(
                bodyID: bodyID,
                bodyParams: params
            ) else {
                featureApplyFailureReason = .generatedMeshEmpty
                return
            }
            params.kernelVisualMesh = rebuild.mesh
        }

        var updatedAsset = document.assets[bodyIndex]
        updatedAsset.kind = .extrudedSolid(params)
        updatedAsset.updateDerivedProperties()
        document.updateAsset(updatedAsset)

        if let cadBodyIndex = cadDocument.bodies.firstIndex(where: { $0.id == bodyID }) {
            let recordedSolid = cutV1RecordedSolid(id: bodyID, resultParams: params)
            cadDocument.bodies[cadBodyIndex].solid = recordedSolid
            cadDocument.bodies[cadBodyIndex].visualMeshCache = recordedSolid.visualMeshCache
            cadDocument.bodies[cadBodyIndex].featureHistory.removeAll { $0 == cutID }
        }
        cadDocument.features.removeAll { $0.id == cutID }
        cadDocument.activeBodyID = bodyID
        cadDocument.sketches = currentCADSketches()
        featureApplyFailureReason = nil

        selectedCutFeatureID = nil
        selectedCutTargetBodyID = nil
        clearAllTransientCADNodes(resetOperation: false)
        document.selectAsset(bodyID)
        syncSelectionStateForSelectedAsset()
    }

    func duplicateSelectedAsset() {
        guard let src = document.selectedAsset else { return }
        var shiftedTransform = src.transform
        shiftedTransform.positionX += 0.1
        var copy = DesignAsset(
            name: uniqueName(base: src.name + " " + localized("cad.asset.copy_suffix")),
            kind: duplicatedKind(src.kind),
            transform: sanitizedTransform(shiftedTransform),
            material: src.material
        )
        if case var .extrudedSolid(parameters) = copy.kind {
            parameters.refreshFaces(assetID: copy.id)
            copy.kind = .extrudedSolid(parameters)
        }
        copy.attachmentPoints = src.attachmentPoints.map { point in
            AttachmentPoint(
                name: point.name,
                localPosition: sanitizedVector(point.localPosition, range: -10.0...10.0),
                localRotation: sanitizedRotationVector(point.localRotation),
                role: point.role,
                isSystem: point.isSystem,
                isEnabled: point.isEnabled
            )
        }
        document.addAsset(copy)
        syncSelectionStateForSelectedAsset()
        requestFocusOnAsset(copy.id)
    }

    func updateSelectedAssetTransform(_ transform: DesignTransform) {
        guard var asset = document.selectedAsset else { return }
        asset.transform = sanitizedTransform(transform)
        document.updateAsset(asset)
    }

    // MARK: Parameter update

    func updateSelectedAssetKind(_ kind: DesignAssetKind) {
        guard var asset = document.selectedAsset else { return }
        let previousPointID = selectedAttachmentPointID
        asset.kind = sanitizedKind(kind)
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        if let previousPointID,
           asset.attachmentPoints.contains(where: { $0.id == previousPointID }) {
            selectedAttachmentPointID = previousPointID
        } else {
            selectedAttachmentPointID = asset.attachmentPoints.first?.id
        }
        if case let .sketch2D(parameters) = asset.kind {
            activeSketchPlane = parameters.sketch.plane
            activeSketchReference = parameters.sketch.reference
            if let selectedSketchLineID,
               !parameters.sketch.lines.contains(where: { $0.id == selectedSketchLineID }) {
                self.selectedSketchLineID = parameters.sketch.lines.first?.id
            }
            refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: parameters.sketch.plane))
        } else {
            refreshViewportState()
        }
    }

    func updateSelectedAssetMaterial(_ material: DesignMaterial) {
        guard var asset = document.selectedAsset else { return }
        asset.material = material
        if case var .extrudedSolid(parameters) = asset.kind {
            parameters.material = material
            asset.kind = .extrudedSolid(parameters)
        }
        asset.updateDerivedProperties()
        document.updateAsset(asset)
    }

    func updateSelectedExtrudedSolidDepth(_ depthMeters: Double) {
        guard var asset = document.selectedAsset,
              case var .extrudedSolid(parameters) = asset.kind else { return }
        parameters.depthMeters = clampFinite(depthMeters, to: 0.001...5.0)
        parameters.kernelVisualMesh = nil
        parameters.kernelResultSolid = nil
        parameters.refreshFaces(assetID: asset.id)
        selectedFaceID = nil
        asset.kind = .extrudedSolid(parameters)
        asset.updateDerivedProperties()
        document.updateAsset(asset)
    }

    func updateSelectedExtrudedSolidDirection(_ direction: ExtrudeDirection) {
        guard var asset = document.selectedAsset,
              case var .extrudedSolid(parameters) = asset.kind else { return }
        parameters.direction = direction
        parameters.kernelVisualMesh = nil
        parameters.kernelResultSolid = nil
        parameters.refreshFaces(assetID: asset.id)
        selectedFaceID = nil
        asset.kind = .extrudedSolid(parameters)
        asset.updateDerivedProperties()
        document.updateAsset(asset)
    }

    func updateSelectedAssetName(_ name: String) {
        guard var asset = document.selectedAsset else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        asset.name = trimmed.isEmpty
            ? localized("cad.asset.unnamed")
            : uniqueName(base: trimmed, excluding: asset.id)
        if case var .sketch2D(parameters) = asset.kind {
            parameters.sketch.name = asset.name
            asset.kind = .sketch2D(parameters)
        }
        document.updateAsset(asset)
    }

    // MARK: Sketch editing

    func updateSelectedSketchPlane(_ plane: SketchPlane) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        guard parameters.sketch.reference.isCanonical else {
            activeSketchPlane = parameters.sketch.plane
            activeSketchReference = parameters.sketch.reference
            sketchWarningKey = "cad.warning.sketch_plane_locked"
            refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: parameters.sketch.plane))
            return
        }
        if parameters.sketch.hasGeometry, parameters.sketch.plane != plane {
            activeSketchPlane = parameters.sketch.plane
            activeSketchReference = parameters.sketch.reference
            sketchWarningKey = "cad.warning.sketch_plane_locked"
            refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: parameters.sketch.plane))
            return
        }
        parameters.planeOffsetMeters = parameters.sketch.reference.isCanonical ? parameters.planeOffsetMeters : 0
        parameters.sketch.setCanonicalPlane(plane, offsetMeters: parameters.planeOffsetMeters)
        activeSketchPlane = plane
        activeSketchReference = parameters.sketch.reference
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func updateSelectedSketchPlaneOffset(_ offsetMeters: Double) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        parameters.planeOffsetMeters = clampFinite(offsetMeters, to: -10.0...10.0)
        parameters.syncPlaneOffset()
        activeSketchReference = parameters.sketch.reference
        activeSketchPlane = parameters.sketch.plane
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func addSketchLine(start: SketchPoint2D, end: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let line = SketchLine(
            start: sanitizedSketchPoint(start),
            end: sanitizedSketchPoint(end),
            constructionStyle: constructionMode ? .construction : .main
        )
        parameters.sketch.entities.append(.line(line))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchLineID = line.id
        selectedSketchEntityID = line.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func addSketchRectangle(firstCorner: SketchPoint2D, oppositeCorner: SketchPoint2D) {
        guard firstCorner.distance(to: oppositeCorner) > 0.0005,
              var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let rectangle = SketchRectangle(
            firstCorner: sanitizedSketchPoint(firstCorner),
            oppositeCorner: sanitizedSketchPoint(oppositeCorner),
            constructionStyle: constructionMode ? .construction : .main
        )
        guard rectangle.isValidProfile else { return }
        parameters.sketch.entities.append(.rectangle(rectangle))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = rectangle.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func addSketchCircle(center: SketchPoint2D, radiusMeters: Double) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let circle = SketchCircle(
            center: sanitizedSketchPoint(center),
            radiusMeters: clampFinite(radiusMeters, to: 0.0005...10.0),
            constructionStyle: constructionMode ? .construction : .main
        )
        guard circle.isValidProfile else { return }
        parameters.sketch.entities.append(.circle(circle))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = circle.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func updateSketchLine(_ id: UUID, start: SketchPoint2D, end: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        guard applySketchLineUpdate(
            id,
            proposedStart: start,
            proposedEnd: end,
            in: &parameters,
            ensureDimension: nil
        ) else { return }
        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = id
        selectedSketchEntityID = id
        extrudeWarningKey = nil
        refreshViewportState()
    }

    func updateSketchRectangle(_ id: UUID, firstCorner: SketchPoint2D, oppositeCorner: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let index = parameters.sketch.entities.firstIndex(where: { $0.id == id }) else { return }
        let rectangle = SketchRectangle(
            id: id,
            firstCorner: sanitizedSketchPoint(firstCorner),
            oppositeCorner: sanitizedSketchPoint(oppositeCorner)
        )
        guard rectangle.isValidProfile else { return }
        parameters.sketch.entities[index] = .rectangle(rectangle)
        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = id
        extrudeWarningKey = nil
        refreshViewportState()
    }

    func updateSketchCircle(_ id: UUID, center: SketchPoint2D, radiusMeters: Double) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let index = parameters.sketch.entities.firstIndex(where: { $0.id == id }) else { return }
        let circle = SketchCircle(
            id: id,
            center: sanitizedSketchPoint(center),
            radiusMeters: clampFinite(radiusMeters, to: 0.0005...10.0)
        )
        guard circle.isValidProfile else { return }
        parameters.sketch.entities[index] = .circle(circle)
        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = id
        extrudeWarningKey = nil
        refreshViewportState()
    }

    func deleteSketchLine(_ id: UUID) {
        deleteSketchEntity(id)
    }

    func deleteSketchEntity(_ id: UUID) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let index = parameters.sketch.entities.firstIndex(where: { $0.id == id }) else { return }
        parameters.sketch.entities.remove(at: index)
        parameters.sketch.dimensions.removeAll { $0.lineID == id }
        parameters.sketch.constraints.removeAll { $0.lineID == id }
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        let nextID = index < parameters.sketch.entities.count
            ? parameters.sketch.entities[index].id
            : parameters.sketch.entities.last?.id
        selectedSketchEntityID = nextID
        selectedSketchLineID = parameters.sketch.lines.first { $0.id == nextID }?.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func selectNextSketchLine() {
        guard let lines = selectedSketch?.lines, !lines.isEmpty else {
            selectedSketchLineID = nil
            return
        }
        guard let selectedSketchLineID,
              let index = lines.firstIndex(where: { $0.id == selectedSketchLineID }) else {
            selectSketchLine(lines.first?.id)
            return
        }
        selectSketchLine(lines[(index + 1) % lines.count].id)
    }

    func updateSelectedSketchLineLength(_ lengthMeters: Double) {
        guard let line = selectedSketchLine else { return }
        updateSketchLineDimension(
            line.id,
            proposedLine: line.withLength(clampFinite(lengthMeters, to: 0.001...20.0)),
            ensureDimension: .lineLength,
            requiresEndMove: true
        )
    }

    func updateSelectedSketchLineAngle(_ angleDegrees: Double) {
        guard let line = selectedSketchLine else { return }
        let normalizedAngle = clampFinite(angleDegrees, to: -360.0...360.0)
        if selectedSketch?.hasConstraint(.horizontal, lineID: line.id) == true,
           !isHorizontalAngle(normalizedAngle) {
            sketchWarningKey = "cad.warning.constraint_conflict"
            return
        }
        if selectedSketch?.hasConstraint(.vertical, lineID: line.id) == true,
           !isVerticalAngle(normalizedAngle) {
            sketchWarningKey = "cad.warning.constraint_conflict"
            return
        }
        updateSketchLineDimension(
            line.id,
            proposedLine: line.withAngleDegrees(normalizedAngle),
            ensureDimension: .lineAngle,
            requiresEndMove: true
        )
    }

    func setSelectedSketchLineConstraint(_ kind: SketchConstraintKind, enabled: Bool) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let lineID = selectedSketchLineID,
              let line = parameters.sketch.lines.first(where: { $0.id == lineID }) else { return }

        if enabled {
            guard !parameters.sketch.hasConstraint(kind, lineID: lineID) else { return }
            if kind == .horizontal,
               parameters.sketch.hasConstraint(.vertical, lineID: lineID),
               line.lengthMeters > 0.0005 {
                sketchWarningKey = "cad.warning.constraint_conflict"
                return
            }
            if kind == .vertical,
               parameters.sketch.hasConstraint(.horizontal, lineID: lineID),
               line.lengthMeters > 0.0005 {
                sketchWarningKey = "cad.warning.constraint_conflict"
                return
            }
            if kind == .horizontal,
               parameters.sketch.hasConstraint(.fixedStart, lineID: lineID),
               parameters.sketch.hasConstraint(.fixedEnd, lineID: lineID),
               abs(line.start.v - line.end.v) > 0.0005 {
                sketchWarningKey = "cad.warning.constraint_conflict"
                return
            }
            if kind == .vertical,
               parameters.sketch.hasConstraint(.fixedStart, lineID: lineID),
               parameters.sketch.hasConstraint(.fixedEnd, lineID: lineID),
               abs(line.start.u - line.end.u) > 0.0005 {
                sketchWarningKey = "cad.warning.constraint_conflict"
                return
            }
            parameters.sketch.constraints.append(SketchConstraint(kind: kind, lineID: lineID))
        } else {
            parameters.sketch.constraints.removeAll { $0.kind == kind && $0.lineID == lineID }
            commitSketchParameters(parameters, to: &asset)
            selectedSketchLineID = lineID
            sketchWarningKey = nil
            refreshViewportState()
            return
        }

        if kind == .horizontal || kind == .vertical {
            let adjustedLine = constrainedLine(line, in: parameters.sketch)
            guard applySketchLineUpdate(
                lineID,
                proposedStart: adjustedLine.start,
                proposedEnd: adjustedLine.end,
                in: &parameters,
                ensureDimension: nil
            ) else { return }
        }

        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = lineID
        sketchWarningKey = nil
        extrudeWarningKey = nil
        refreshViewportState()
    }

    func selectedSketchLineHasConstraint(_ kind: SketchConstraintKind) -> Bool {
        guard let selectedSketchLineID else { return false }
        return selectedSketch?.hasConstraint(kind, lineID: selectedSketchLineID) == true
    }

    // MARK: Sketch Dimension Management

    func addDimensionForSelectedLine(kind: SketchDimensionKind) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let lineID = selectedSketchLineID,
              let line = parameters.sketch.lines.first(where: { $0.id == lineID }) else { return }
        guard !parameters.sketch.hasDimension(kind, lineID: lineID) else { return }
        let value = dimensionValue(kind: kind, line: line)
        parameters.sketch.dimensions.append(SketchDimension(kind: kind, lineID: lineID, value: value))
        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = lineID
        refreshViewportState()
    }

    func addDimensionForSelectedRectangle(kind: SketchDimensionKind) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let entityID = selectedSketchEntityID,
              let entity = parameters.sketch.entity(with: entityID),
              case let .rectangle(rect) = entity else { return }
        guard !parameters.sketch.hasDimension(kind, lineID: entityID) else { return }
        let value: Double
        switch kind {
        case .rectangleWidth:  value = rect.widthMeters
        case .rectangleHeight: value = rect.heightMeters
        default: value = 0
        }
        parameters.sketch.dimensions.append(SketchDimension(kind: kind, lineID: entityID, value: value))
        commitSketchParameters(parameters, to: &asset)
        refreshViewportState()
    }

    func addDimensionForSelectedCircle(kind: SketchDimensionKind) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let entityID = selectedSketchEntityID,
              let entity = parameters.sketch.entity(with: entityID),
              case let .circle(circle) = entity else { return }
        guard !parameters.sketch.hasDimension(kind, lineID: entityID) else { return }
        let value: Double = kind == .circleDiameter ? circle.radiusMeters * 2 : circle.radiusMeters
        parameters.sketch.dimensions.append(SketchDimension(kind: kind, lineID: entityID, value: value))
        commitSketchParameters(parameters, to: &asset)
        refreshViewportState()
    }

    func removeSketchDimension(_ id: UUID) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        parameters.sketch.dimensions.removeAll { $0.id == id }
        commitSketchParameters(parameters, to: &asset)
        refreshViewportState()
    }

    func selectedSketchDimensions() -> [SketchDimension] {
        guard let asset = document.selectedAsset,
              case let .sketch2D(parameters) = asset.kind else { return [] }
        if let lineID = selectedSketchLineID {
            return parameters.sketch.dimensions.filter { $0.lineID == lineID }
        }
        if let entityID = selectedSketchEntityID {
            return parameters.sketch.dimensions.filter { $0.lineID == entityID }
        }
        return []
    }

    // MARK: Attachment point editing

    func addAttachmentPoint() {
        guard var asset = document.selectedAsset else { return }
        let point = AttachmentPoint(
            name: uniqueAttachmentPointName(
                base: localized("cad.attachment.custom_base"),
                in: asset
            ),
            localPosition: DesignVector3(
                x: 0,
                y: clampFinite(asset.massProperties.boundingHeight / 2 + 0.02, to: -10.0...10.0),
                z: 0
            ),
            role: .generic,
            isSystem: false,
            isEnabled: true
        )
        asset.attachmentPoints.append(point)
        document.updateAsset(asset)
        selectedAttachmentPointID = point.id
    }

    func deleteSelectedAttachmentPoint() {
        guard var asset = document.selectedAsset,
              let pointID = selectedAttachmentPointID,
              let index = asset.attachmentPoints.firstIndex(where: { $0.id == pointID }),
              asset.attachmentPoints[index].isSystem == false else { return }

        asset.attachmentPoints.remove(at: index)
        document.updateAsset(asset)
        selectedAttachmentPointID = index < asset.attachmentPoints.count
            ? asset.attachmentPoints[index].id
            : asset.attachmentPoints.last?.id
    }

    func updateSelectedAttachmentPointName(_ name: String) {
        guard var asset = document.selectedAsset,
              let pointIndex = selectedAttachmentPointIndex(in: asset),
              asset.attachmentPoints[pointIndex].isSystem == false else { return }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        asset.attachmentPoints[pointIndex].name = trimmed.isEmpty
            ? uniqueAttachmentPointName(base: localized("cad.attachment.custom_base"), in: asset)
            : trimmed
        document.updateAsset(asset)
    }

    func updateSelectedAttachmentPointRole(_ role: AttachmentRole) {
        guard var asset = document.selectedAsset,
              let pointIndex = selectedAttachmentPointIndex(in: asset) else { return }

        asset.attachmentPoints[pointIndex].role = role
        document.updateAsset(asset)
    }

    func updateSelectedAttachmentPointPosition(_ position: DesignVector3) {
        guard var asset = document.selectedAsset,
              let pointIndex = selectedAttachmentPointIndex(in: asset) else { return }

        asset.attachmentPoints[pointIndex].localPosition = sanitizedVector(position, range: -10.0...10.0)
        document.updateAsset(asset)
    }

    func updateSelectedAttachmentPointRotation(_ rotation: DesignVector3) {
        guard var asset = document.selectedAsset,
              let pointIndex = selectedAttachmentPointIndex(in: asset) else { return }

        asset.attachmentPoints[pointIndex].localRotation = sanitizedRotationVector(rotation)
        document.updateAsset(asset)
    }

    func toggleSelectedAttachmentPointEnabled() {
        guard var asset = document.selectedAsset,
              let pointIndex = selectedAttachmentPointIndex(in: asset) else { return }

        asset.attachmentPoints[pointIndex].isEnabled.toggle()
        document.updateAsset(asset)
    }

    func resetSelectedAssetSystemAttachmentPoints() {
        guard var asset = document.selectedAsset else { return }
        asset.resetSystemAttachmentPoints()
        document.updateAsset(asset)
        selectedAttachmentPointID = asset.attachmentPoints.first(where: \.isSystem)?.id
            ?? asset.attachmentPoints.first?.id
    }

    func attachmentPointWarningKeys(for asset: DesignAsset) -> [String] {
        var warnings: [String] = []

        let normalizedNames = asset.attachmentPoints.map {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if Set(normalizedNames).count < normalizedNames.count {
            warnings.append("cad.warning.attachment_duplicate_names")
        }

        if !asset.attachmentPoints.isEmpty,
           asset.attachmentPoints.allSatisfy({ !$0.isEnabled }) {
            warnings.append("cad.warning.attachment_all_disabled")
        }

        let expectedSystemNames = Set(DesignAsset.defaultAttachmentPoints(for: asset.kind).map(\.name))
        let existingSystemNames = Set(asset.attachmentPoints.filter(\.isSystem).map(\.name))
        if !expectedSystemNames.isSubset(of: existingSystemNames) {
            warnings.append("cad.warning.attachment_missing_system")
        }

        let halfWidth = asset.massProperties.boundingWidth / 2 + 0.25
        let halfHeight = asset.massProperties.boundingHeight / 2 + 0.25
        let halfDepth = asset.massProperties.boundingDepth / 2 + 0.25
        if asset.attachmentPoints.contains(where: { point in
            guard !point.isSystem else { return false }
            return abs(point.localX) > halfWidth
                || abs(point.localY) > halfHeight
                || abs(point.localZ) > halfDepth
        }) {
            warnings.append("cad.warning.attachment_far_from_bounds")
        }

        return warnings
    }

    func sourceSketchDisplayName(for parameters: ExtrudedSolidParameters) -> String {
        if let sourceAsset = document.assets.first(where: { $0.id == parameters.sourceSketchID }),
           case let .sketch2D(sourceParameters) = sourceAsset.kind {
            return sourceParameters.sketch.name
        }

        let snapshotName = parameters.sourceSketchName.trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshotName.isEmpty {
            return NSLocalizedString("cad.extrude.source_deleted", comment: "")
        }
        return String(
            format: NSLocalizedString("cad.extrude.source_deleted_named", comment: ""),
            snapshotName
        )
    }

    // MARK: Reset

    func resetDocument() {
        document = DesignDocument()
        cadDocument = CADDocument()
        clearAllTransientCADNodes(resetOperation: true)
        selectedAttachmentPointID = nil
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        selectedSketchEntityIDs = []
        selectedProfileAreaID = nil
        selectedFaceID = nil
        hoveredWorkPlaneID = nil
        selectedWorkPlane = nil
        workPlaneQuickAction = nil
        activeToolMode = .select
        activeSketchPlane = .xz
        activeSketchReference = .canonicalPlane(.xz, offsetMeters: 0)
        featureDepthMode = .distance
        resetDrawingToolStates(activating: nil)
        featureValidation = .noProfile
        lastCutApplyStatus = .blocked
        lastCutApplyReason = nil
        recordCutCleanupGuard(previewNodesRemoved: false)
        extrudeWarningKey = nil
        sketchWarningKey = nil
        requestViewPreset(.iso, focus: .origin)
        refreshViewportState()
    }

    // MARK: Sketch Tool Canvas Events

    func cancelLineTool() {
        resetDrawingToolStates(activating: nil)
        activeToolMode = .select
        refreshViewportState()
    }

    func finishLineCommand() {
        resetDrawingToolStates(activating: nil)
        activeToolMode = .select
        refreshViewportState()
    }

    func handleCanvasMouseMoved(_ snapResult: CADSnapResult) {
        cursorScreenPosition = snapResult.screenPoint
        switch activeToolMode {
        case .sketchLine:
            lineToolState.cursorPoint = snapResult.point
            lineToolState.snapResult = snapResult
        case .sketchRectangle:
            rectangleToolState.cursorPoint = snapResult.point
            rectangleToolState.snapResult = snapResult
        case .sketchCircle:
            circleToolState.cursorPoint = snapResult.point
            circleToolState.snapResult = snapResult
        case .sketchArc:
            arcToolState.cursorPoint = snapResult.point
            arcToolState.snapResult = snapResult
        case .sketchAutoline:
            autolineToolState.cursorPoint = snapResult.point
            autolineToolState.snapResult = snapResult
        case .sketchConstruction:
            constructionToolState.cursorPoint = snapResult.point
            constructionToolState.snapResult = snapResult
        case .sketchMove, .sketchCopy:
            sketchMoveToolState.cursorPoint = snapResult.point
            sketchMoveToolState.snapResult = snapResult
        case .sketchParallel, .sketchPerpendicular:
            sketchParallelToolState.cursorPoint = snapResult.point
            sketchParallelToolState.snapResult = snapResult
        case .sketchSplit, .sketchTrim, .sketchExtend:
            sketchSplitToolState.cursorPoint = snapResult.point
            sketchSplitToolState.snapResult = snapResult
            if let sketch = selectedSketch {
                if trimExtendOpState != nil {
                    // Phase 2: update target-mode preview from cursor/snap; numeric mode is untouched.
                    updateTrimExtendFromCursor(snapResult: snapResult, in: sketch)
                } else {
                    // Phase 1: hover preview using the existing endpoint-proximity phantom.
                    let result = trimExtendPhantom(at: snapResult.point, in: sketch, for: activeToolMode)
                    sketchSplitToolState.phantomPoints = result.phantomPoints
                    sketchSplitToolState.hoveredEntityID = result.hoveredEntityID
                    sketchSplitToolState.hoveredFromStart = result.hoveredFromStart
                    sketchSplitToolState.pendingNewEndpoint = result.pendingNewEndpoint
                }
            }
        case .select, .sketchEdit:
            return
        }
    }

    func handleCanvasClick(_ snapResult: CADSnapResult) {
        switch activeToolMode {
        case .sketchLine:
            handleLineToolClick(snapResult)
        case .sketchRectangle:
            handleRectangleToolClick(snapResult)
        case .sketchCircle:
            handleCircleToolClick(snapResult)
        case .sketchArc:
            handleArcToolClick(snapResult)
        case .sketchAutoline:
            handleAutolineToolClick(snapResult)
        case .sketchConstruction:
            handleConstructionToolClick(snapResult)
        case .sketchMove, .sketchCopy:
            handleMoveToolClick(snapResult)
        case .sketchSplit:
            handleSplitToolClick(snapResult)
        case .sketchTrim:
            handleTrimToolClick(snapResult)
        case .sketchExtend:
            handleExtendToolClick(snapResult)
        case .sketchParallel, .sketchPerpendicular:
            handleParallelToolClick(snapResult)
        case .select, .sketchEdit:
            if selectedSketch != nil,
               let graph = sketchProfileGraph,
               graph.count > 1,
               let area = graph.containingArea(for: snapResult.point) {
                selectProfileArea(area.id)
            }
            return
        }
    }

    private func handleLineToolClick(_ snapResult: CADSnapResult) {
        let snapped = snapResult.point
        switch lineToolState.phase {
        case .idle, .waitingForStart:
            lineToolState.phase = .waitingForEnd(start: snapped)
            lineToolState.cursorPoint = snapped
            lineToolState.activeParameter = .endPoint
            lineToolState.snapResult = snapResult
        case let .waitingForEnd(start):
            guard start.distance(to: snapped) > 0.0001 else { return }
            addSketchLine(start: start, end: snapped)
            lineToolState.phase = .waitingForEnd(start: snapped)
            lineToolState.cursorPoint = snapped
            lineToolState.activeParameter = .endPoint
            lineToolState.snapResult = snapResult
        }
    }

    private func handleRectangleToolClick(_ snapResult: CADSnapResult) {
        let snapped = snapResult.point
        switch rectangleToolState.phase {
        case .idle, .waitingForFirstCorner:
            rectangleToolState.phase = .waitingForOppositeCorner(firstCorner: snapped)
            rectangleToolState.cursorPoint = snapped
            rectangleToolState.snapResult = snapResult
        case let .waitingForOppositeCorner(firstCorner):
            guard firstCorner.distance(to: snapped) > 0.0005 else { return }
            addSketchRectangle(firstCorner: firstCorner, oppositeCorner: snapped)
            rectangleToolState = RectangleToolState(phase: .waitingForFirstCorner, cursorPoint: snapped, snapResult: snapResult)
        }
    }

    private func handleCircleToolClick(_ snapResult: CADSnapResult) {
        let snapped = snapResult.point
        switch circleToolState.phase {
        case .idle, .waitingForCenter:
            circleToolState.phase = .waitingForRadius(center: snapped)
            circleToolState.cursorPoint = snapped
            circleToolState.snapResult = snapResult
        case let .waitingForRadius(center):
            let radius = center.distance(to: snapped)
            guard radius > 0.0005 else { return }
            addSketchCircle(center: center, radiusMeters: radius)
            circleToolState = CircleToolState(phase: .waitingForCenter, cursorPoint: snapped, snapResult: snapResult)
        }
    }

    private func handleArcToolClick(_ snapResult: CADSnapResult) {
        let snapped = snapResult.point
        switch arcToolState.phase {
        case .idle, .waitingForStart:
            arcToolState.phase = .waitingForEnd(start: snapped)
            arcToolState.cursorPoint = snapped
        case let .waitingForEnd(start):
            guard start.distance(to: snapped) > 0.0005 else { return }
            arcToolState.phase = .waitingForMid(start: start, end: snapped)
            arcToolState.cursorPoint = snapped
        case let .waitingForMid(start, end):
            guard arcToolState.cursorPoint.distance(to: start) > 0.0005,
                  arcToolState.cursorPoint.distance(to: end) > 0.0005 else { return }
            addSketchArc(start: start, end: end, midPoint: arcToolState.cursorPoint)
            arcToolState = ArcToolState(phase: .waitingForStart, cursorPoint: snapped)
        }
    }

    private func handleAutolineToolClick(_ snapResult: CADSnapResult) {
        let snapped = snapResult.point
        switch autolineToolState.phase {
        case .idle:
            autolineToolState.phase = .drawing(points: [snapped])
            autolineToolState.cursorPoint = snapped
        case let .drawing(points):
            guard points.last?.distance(to: snapped) ?? 0 > 0.0005 else { return }
            autolineToolState.phase = .drawing(points: points + [snapped])
            autolineToolState.cursorPoint = snapped
        }
    }

    func commitAutolineTool(close: Bool = false) {
        var pts = autolineToolState.points
        guard pts.count >= 2 else {
            autolineToolState = AutolineToolState(phase: .idle)
            return
        }
        if close, pts.count >= 3, let first = pts.first, let last = pts.last,
           first.distance(to: last) > 0.0005 {
            pts.append(first)
        }
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let lineStyle: SketchEntityStyle = constructionMode ? .construction : .main
        for i in 0..<(pts.count - 1) {
            let line = SketchLine(start: sanitizedSketchPoint(pts[i]), end: sanitizedSketchPoint(pts[i + 1]), constructionStyle: lineStyle)
            parameters.sketch.entities.append(.line(line))
        }
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = nil
        extrudeWarningKey = nil
        sketchWarningKey = nil
        autolineToolState = AutolineToolState(phase: .idle)
        refreshViewportState()
    }

    func cancelAutolineTool() {
        autolineToolState = AutolineToolState(phase: .idle)
        activeToolMode = .select
        refreshViewportState()
    }

    func cancelArcTool() {
        arcToolState = ArcToolState(phase: .idle)
        activeToolMode = .select
        refreshViewportState()
    }

    func addSketchArc(start: SketchPoint2D, end: SketchPoint2D, midPoint: SketchPoint2D) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind else { return }
        let style: SketchEntityStyle = constructionMode ? .construction : .main
        let arc = SketchArc(
            start: sanitizedSketchPoint(start),
            end: sanitizedSketchPoint(end),
            midPoint: sanitizedSketchPoint(midPoint),
            constructionStyle: style
        )
        parameters.sketch.entities.append(.arc(arc))
        parameters.sketch.refreshClosedStatus()
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
        selectedSketchLineID = nil
        selectedSketchEntityID = arc.id
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    func handleCanvasKeyCode(_ keyCode: UInt16, character: String?) {
        switch keyCode {
        case 53: // Esc
            if featurePreviewState != nil {
                cancelFeaturePreview()
                return
            }
            if activeToolMode == .sketchTrim || activeToolMode == .sketchExtend {
                if trimExtendOpState != nil {
                    // Phase 2: cancel operation, stay in tool (return to Phase 1).
                    cancelTrimExtendOperation()
                } else {
                    // Phase 1: exit tool.
                    sketchSplitToolState = SketchSplitToolState()
                    trimExtendOpState = nil
                    activeToolMode = .select
                    refreshViewportState()
                }
                return
            }
            if activeToolMode == .sketchSplit {
                sketchSplitToolState = SketchSplitToolState()
                activeToolMode = .select
                refreshViewportState()
                return
            }
            if case .waitingForDestination = sketchMoveToolState.phase {
                sketchMoveToolState.phase = .idle
                refreshViewportState()
            } else if case .waitingForEnd = lineToolState.phase {
                lineToolState.phase = .waitingForStart
                lineToolState.activeParameter = .startPoint
            } else if case .waitingForOppositeCorner = rectangleToolState.phase {
                rectangleToolState.phase = .waitingForFirstCorner
            } else if case .waitingForRadius = circleToolState.phase {
                circleToolState.phase = .waitingForCenter
            } else if arcToolState.isActive {
                switch arcToolState.phase {
                case .waitingForMid(let start, _):
                    arcToolState.phase = .waitingForEnd(start: start)
                default:
                    cancelArcTool()
                }
            } else if autolineToolState.isActive {
                cancelAutolineTool()
            } else {
                cancelLineTool()
            }
        case 36: // Enter
            if featurePreviewState != nil, featureValidation.isValid {
                applyFeatureOperation()
                return
            }
            if activeToolMode == .sketchTrim || activeToolMode == .sketchExtend {
                if trimExtendOpState != nil {
                    // Phase 2: apply the current valid preview.
                    applyTrimExtendOperation()
                }
                // Phase 1: Enter with no locked endpoint is a no-op.
                return
            }
            if case let .waitingForEnd(start) = lineToolState.phase {
                let end = lineToolState.cursorPoint
                guard start.distance(to: end) > 0.0001 else { return }
                addSketchLine(start: start, end: end)
                lineToolState.phase = .waitingForEnd(start: end)
            } else if case let .waitingForOppositeCorner(firstCorner) = rectangleToolState.phase {
                let end = rectangleToolState.cursorPoint
                guard firstCorner.distance(to: end) > 0.0005 else { return }
                addSketchRectangle(firstCorner: firstCorner, oppositeCorner: end)
                rectangleToolState = RectangleToolState(phase: .waitingForFirstCorner, cursorPoint: end)
            } else if case let .waitingForRadius(center) = circleToolState.phase,
                      let radius = circleToolState.radiusMeters,
                      radius > 0.0005 {
                addSketchCircle(center: center, radiusMeters: radius)
                circleToolState = CircleToolState(phase: .waitingForCenter, cursorPoint: circleToolState.cursorPoint)
            } else if autolineToolState.points.count >= 2 {
                commitAutolineTool(close: false)
            }
        case 48: // Tab
            cycleLineActiveParameter()
        case 51, 117: // Backspace / Forward Delete
            deleteSelectedSketchEntity()
        case 0xC001: // Cmd+C
            copySelectedSketchEntity()
        case 0xC002: // Cmd+V
            pasteSketchEntity()
        default:
            if character?.lowercased() == "l" {
                setToolMode(.sketchLine)
            } else if character?.lowercased() == "r" {
                setToolMode(.sketchRectangle)
            } else if character?.lowercased() == "c" {
                setToolMode(.sketchCircle)
            } else if character?.lowercased() == "a" {
                setToolMode(.sketchArc)
            }
        }
    }

    private func orderedProfilePoints(from sketch: DesignSketch) -> [SketchPoint2D] {
        guard let first = sketch.lines.first else { return [] }
        var points: [SketchPoint2D] = [first.start, first.end]
        var remaining = Array(sketch.lines.dropFirst())

        while !remaining.isEmpty {
            let last = points[points.count - 1]
            if let idx = remaining.firstIndex(where: { $0.start.distance(to: last) < 0.001 }) {
                points.append(remaining.remove(at: idx).end)
            } else if let idx = remaining.firstIndex(where: { $0.end.distance(to: last) < 0.001 }) {
                points.append(remaining.remove(at: idx).start)
            } else { break }
        }
        if points.count >= 2, points[points.count - 1].distance(to: points[0]) < 0.001 {
            points.removeLast()
        }
        return points
    }

    private func cycleLineActiveParameter() {
        switch lineToolState.activeParameter {
        case .startPoint: lineToolState.activeParameter = .endPoint
        case .endPoint:   lineToolState.activeParameter = .length
        case .length:     lineToolState.activeParameter = .angle
        case .angle:      lineToolState.activeParameter = .endPoint
        }
    }

    private func updateSketchLineDimension(
        _ lineID: UUID,
        proposedLine: SketchLine,
        ensureDimension: SketchDimensionKind,
        requiresEndMove: Bool
    ) {
        guard var asset = document.selectedAsset,
              case var .sketch2D(parameters) = asset.kind,
              let currentLine = parameters.sketch.lines.first(where: { $0.id == lineID }) else { return }

        if requiresEndMove,
           parameters.sketch.hasConstraint(.fixedEnd, lineID: lineID),
           currentLine.end.distance(to: proposedLine.end) > 0.000001 {
            sketchWarningKey = "cad.warning.constraint_conflict"
            return
        }

        guard applySketchLineUpdate(
            lineID,
            proposedStart: proposedLine.start,
            proposedEnd: proposedLine.end,
            in: &parameters,
            ensureDimension: ensureDimension
        ) else { return }

        commitSketchParameters(parameters, to: &asset)
        selectedSketchLineID = lineID
        extrudeWarningKey = nil
        sketchWarningKey = nil
        refreshViewportState()
    }

    private func applySketchLineUpdate(
        _ id: UUID,
        proposedStart: SketchPoint2D,
        proposedEnd: SketchPoint2D,
        in parameters: inout SketchAssetParameters,
        ensureDimension: SketchDimensionKind?
    ) -> Bool {
        guard let oldLine = parameters.sketch.lines.first(where: { $0.id == id }) else { return false }

        var start = sanitizedSketchPoint(proposedStart)
        var end = sanitizedSketchPoint(proposedEnd)
        let hasFixedStart = parameters.sketch.hasConstraint(.fixedStart, lineID: id)
        let hasFixedEnd = parameters.sketch.hasConstraint(.fixedEnd, lineID: id)

        if hasFixedStart, start.distance(to: oldLine.start) > 0.000001 {
            start = oldLine.start
            sketchWarningKey = "cad.warning.constraint_conflict"
        }
        if hasFixedEnd, end.distance(to: oldLine.end) > 0.000001 {
            end = oldLine.end
            sketchWarningKey = "cad.warning.constraint_conflict"
        }

        let candidate = constrainedLine(SketchLine(id: id, start: start, end: end), in: parameters.sketch)
        if parameters.sketch.hasConstraintConflict {
            sketchWarningKey = "cad.warning.constraint_conflict"
            return false
        }

        guard let nextEntities = propagatedEntities(
            replacing: oldLine,
            with: candidate,
            in: parameters.sketch
        ) else {
            sketchWarningKey = "cad.warning.constraint_conflict"
            return false
        }

        parameters.sketch.entities = nextEntities
        if let ensureDimension {
            let measuredValue = dimensionValue(kind: ensureDimension, line: candidate)
            if let idx = parameters.sketch.dimensions.firstIndex(where: { $0.kind == ensureDimension && $0.lineID == id }) {
                parameters.sketch.dimensions[idx].value = measuredValue
            } else {
                parameters.sketch.dimensions.append(SketchDimension(kind: ensureDimension, lineID: id, value: measuredValue))
            }
        }
        parameters.sketch.refreshClosedStatus()
        return true
    }

    private func dimensionValue(kind: SketchDimensionKind, line: SketchLine) -> Double {
        switch kind {
        case .lineLength: return line.lengthMeters
        case .lineAngle: return line.angleDegrees
        case .horizontalDistance: return abs(line.end.u - line.start.u)
        case .verticalDistance: return abs(line.end.v - line.start.v)
        default: return 0
        }
    }

    private func constrainedLine(_ line: SketchLine, in sketch: DesignSketch) -> SketchLine {
        let hasHorizontal = sketch.hasConstraint(.horizontal, lineID: line.id)
        let hasVertical = sketch.hasConstraint(.vertical, lineID: line.id)
        let hasFixedStart = sketch.hasConstraint(.fixedStart, lineID: line.id)
        let hasFixedEnd = sketch.hasConstraint(.fixedEnd, lineID: line.id)
        guard !(hasHorizontal && hasVertical && line.lengthMeters > 0.0005) else {
            return line
        }

        var adjusted = line
        if hasHorizontal {
            if hasFixedEnd && !hasFixedStart {
                adjusted.start.v = adjusted.end.v
            } else {
                adjusted.end.v = adjusted.start.v
            }
        }
        if hasVertical {
            if hasFixedEnd && !hasFixedStart {
                adjusted.start.u = adjusted.end.u
            } else {
                adjusted.end.u = adjusted.start.u
            }
        }
        return adjusted
    }

    private func propagatedEntities(
        replacing oldLine: SketchLine,
        with newLine: SketchLine,
        in sketch: DesignSketch
    ) -> [SketchEntity]? {
        let oldStartMoved = oldLine.start.distance(to: newLine.start) > 0.000001
        let oldEndMoved = oldLine.end.distance(to: newLine.end) > 0.000001
        let tolerance = 0.005

        var nextEntities: [SketchEntity] = []
        for entity in sketch.entities {
            guard case var .line(line) = entity else {
                nextEntities.append(entity)
                continue
            }
            if line.id == oldLine.id {
                nextEntities.append(.line(newLine))
                continue
            }

            if oldStartMoved {
                if line.start.distance(to: oldLine.start) <= tolerance {
                    if sketch.hasConstraint(.fixedStart, lineID: line.id),
                       line.start.distance(to: newLine.start) > tolerance {
                        return nil
                    }
                    line.start = newLine.start
                }
                if line.end.distance(to: oldLine.start) <= tolerance {
                    if sketch.hasConstraint(.fixedEnd, lineID: line.id),
                       line.end.distance(to: newLine.start) > tolerance {
                        return nil
                    }
                    line.end = newLine.start
                }
            }

            if oldEndMoved {
                if line.start.distance(to: oldLine.end) <= tolerance {
                    if sketch.hasConstraint(.fixedStart, lineID: line.id),
                       line.start.distance(to: newLine.end) > tolerance {
                        return nil
                    }
                    line.start = newLine.end
                }
                if line.end.distance(to: oldLine.end) <= tolerance {
                    if sketch.hasConstraint(.fixedEnd, lineID: line.id),
                       line.end.distance(to: newLine.end) > tolerance {
                        return nil
                    }
                    line.end = newLine.end
                }
            }

            nextEntities.append(.line(constrainedLine(line, in: sketch)))
        }
        return nextEntities
    }

    private func commitSketchParameters(_ parameters: SketchAssetParameters, to asset: inout DesignAsset) {
        asset.kind = .sketch2D(sanitizedSketchParameters(parameters))
        asset.updateDerivedProperties()
        document.updateAsset(asset)
    }

    private func isHorizontalAngle(_ angle: Double) -> Bool {
        let normalized = normalizedDegrees(angle)
        return min(abs(normalized), abs(abs(normalized) - 180.0)) <= 0.5
    }

    private func isVerticalAngle(_ angle: Double) -> Bool {
        let normalized = abs(normalizedDegrees(angle))
        return abs(normalized - 90.0) <= 0.5
    }

    private func normalizedDegrees(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 360.0)
        if value > 180.0 { value -= 360.0 }
        if value < -180.0 { value += 360.0 }
        return value
    }

    // MARK: Private helpers

    private func addNewAsset(kind: DesignAssetKind, baseName: String) {
        let asset = DesignAsset(name: uniqueNumberedName(base: baseName), kind: sanitizedKind(kind))
        document.addAsset(asset)
        syncSelectionStateForSelectedAsset()
        if autoFocusNewAssets {
            requestFocusOnAsset(asset.id)
        }
    }

    private func requestFocusOnAsset(_ id: UUID) {
        requestViewPreset(.fitSelected, focus: .asset(id))
    }

    private func uniqueNumberedName(base: String) -> String {
        let cleanedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBase = cleanedBase.isEmpty ? localized("cad.asset.unnamed") : cleanedBase
        var index = 1
        var candidate = "\(finalBase) \(index)"
        let existingNames = Set(document.assets.map(\.name))
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(finalBase) \(index)"
        }
        return candidate
    }

    private func uniqueName(base: String, excluding excludedID: UUID? = nil) -> String {
        let cleanedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBase = cleanedBase.isEmpty ? localized("cad.asset.unnamed") : cleanedBase
        let existingNames = Set(document.assets.compactMap { asset in
            asset.id == excludedID ? nil : asset.name
        })
        guard existingNames.contains(finalBase) else { return finalBase }

        var index = 2
        var candidate = "\(finalBase) \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(finalBase) \(index)"
        }
        return candidate
    }

    private func uniqueAttachmentPointName(base: String, in asset: DesignAsset) -> String {
        let cleanedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBase = cleanedBase.isEmpty ? localized("cad.attachment.custom_base") : cleanedBase
        let existingNames = Set(asset.attachmentPoints.map(\.name))
        var index = 1
        var candidate = "\(finalBase) \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(finalBase) \(index)"
        }
        return candidate
    }

    private func selectedAttachmentPointIndex(in asset: DesignAsset) -> Int? {
        guard let selectedAttachmentPointID else { return nil }
        return asset.attachmentPoints.firstIndex { $0.id == selectedAttachmentPointID }
    }

    // MARK: - Profile Graph

    private func rebuildProfileGraph() {
        guard let sketch = selectedSketch else {
            sketchProfileGraph = nil
            selectedProfileAreaID = nil
            return
        }
        let prevCentroid: SketchPoint2D? = selectedProfileAreaID
            .flatMap { id in sketchProfileGraph?.area(with: id) }
            .map(\.centroid)

        let graph = SketchProfileEngine.buildProfileGraph(from: sketch)
        sketchProfileGraph = graph

        if graph.count == 1 {
            selectedProfileAreaID = graph.areas.first?.id
        } else if let prev = prevCentroid {
            // Try to re-select by nearest centroid (tolerate small moves after mutation)
            let match = graph.areas.min(by: {
                $0.centroid.distance(to: prev) < $1.centroid.distance(to: prev)
            })
            if let m = match, m.centroid.distance(to: prev) < 0.01 {
                selectedProfileAreaID = m.id
            } else {
                selectedProfileAreaID = nil
            }
        } else {
            selectedProfileAreaID = nil
        }
        updateFeaturePreview()
    }

    func selectProfileArea(_ areaID: UUID) {
        selectedProfileAreaID = areaID
        updateFeaturePreview()
    }

    private func resetDrawingToolStates(activating mode: DesignWorkshopToolMode?) {
        lineToolState = LineToolState()
        rectangleToolState = RectangleToolState()
        circleToolState = CircleToolState()
        arcToolState = ArcToolState()
        autolineToolState = AutolineToolState()
        constructionToolState.reset()
        sketchMoveToolState = SketchMoveToolState()
        sketchParallelToolState = SketchParallelToolState()
        sketchSplitToolState = SketchSplitToolState()
        trimExtendOpState = nil

        switch mode {
        case .sketchLine:
            lineToolState = LineToolState(phase: .waitingForStart, cursorPoint: .zero, activeParameter: .startPoint)
        case .sketchRectangle:
            rectangleToolState = RectangleToolState(phase: .waitingForFirstCorner, cursorPoint: .zero)
        case .sketchCircle:
            circleToolState = CircleToolState(phase: .waitingForCenter, cursorPoint: .zero)
        case .sketchArc:
            arcToolState = ArcToolState(phase: .waitingForStart, cursorPoint: .zero)
        case .sketchAutoline:
            autolineToolState = AutolineToolState(phase: .idle, cursorPoint: .zero)
        case .sketchConstruction:
            constructionToolState = ConstructionToolState()
        case .sketchMove:
            sketchMoveToolState = SketchMoveToolState(isCopy: false)
        case .sketchCopy:
            sketchMoveToolState = SketchMoveToolState(isCopy: true)
        case .sketchParallel:
            sketchParallelToolState = SketchParallelToolState(isPerpendicular: false)
        case .sketchPerpendicular:
            sketchParallelToolState = SketchParallelToolState(isPerpendicular: true)
        case .sketchSplit, .sketchTrim, .sketchExtend:
            sketchSplitToolState = SketchSplitToolState()
        case .select, .sketchEdit, .none:
            break
        }
    }

    private func syncSelectionStateForSelectedAsset() {
        sketchWarningKey = nil
        guard let asset = document.selectedAsset else {
            selectedAttachmentPointID = nil
            selectedSketchLineID = nil
            selectedSketchEntityID = nil
            selectedSketchEntityIDs = []
            selectedFaceID = nil
            selectedCutFeatureID = nil
            selectedCutTargetBodyID = nil
            refreshViewportState()
            return
        }

        if case let .sketch2D(parameters) = asset.kind {
            selectedAttachmentPointID = nil
            selectedFaceID = nil
            selectedCutFeatureID = nil
            selectedCutTargetBodyID = nil
            activeSketchPlane = parameters.sketch.plane
            activeSketchReference = parameters.sketch.reference
            selectedSketchEntityID = parameters.sketch.entities.first?.id
            selectedSketchEntityIDs = selectedSketchEntityID.map { [$0] } ?? []
            selectedSketchLineID = parameters.sketch.lines.first { $0.id == selectedSketchEntityID }?.id
            refreshViewportState(viewMode: .sketch2D, orientation: cameraMode(for: parameters.sketch.plane))
        } else {
            selectedAttachmentPointID = asset.attachmentPoints.first?.id
            selectedSketchLineID = nil
            selectedSketchEntityID = nil
            selectedSketchEntityIDs = []
            if case let .extrudedSolid(parameters) = asset.kind {
                if let selectedFaceID,
                   parameters.faces.contains(where: { $0.id == selectedFaceID }) {
                    self.selectedFaceID = selectedFaceID
                } else {
                    selectedFaceID = nil
                }
                if let selectedCutFeatureID,
                   parameters.boxBlindCutFeatures.contains(where: { $0.id == selectedCutFeatureID }) {
                    selectedCutTargetBodyID = asset.id
                } else {
                    selectedCutFeatureID = nil
                    selectedCutTargetBodyID = nil
                }
            } else {
                selectedFaceID = nil
                selectedCutFeatureID = nil
                selectedCutTargetBodyID = nil
            }
            refreshViewportState()
        }
    }

    private func refreshViewportState(
        viewMode: SketchViewMode? = nil,
        orientation: CADCameraMode? = nil
    ) {
        let nextState = DesignViewportState(
            activePlane: activeSketchPlane,
            activePlaneOffsetMeters: activeSketchPlaneOffsetMeters,
            activeReference: currentSketchReference(),
            viewMode: viewMode ?? viewportState.viewMode,
            orientation: orientation ?? viewportState.orientation,
            showGrid: canvasOptions.showGrid,
            showAxes: canvasOptions.showAxes,
            showReferencePlanes: canvasOptions.showReferencePlanes,
            showActivePlaneOverlay: canvasOptions.showActivePlaneOverlay,
            showAttachmentPoints: canvasOptions.showAttachmentPoints,
            showConstraintGlyphs: canvasOptions.showConstraintGlyphs,
            snapOptions: canvasOptions.snapOptions,
            selectedAssetID: document.selectedAssetID,
            selectedAttachmentPointID: selectedAttachmentPointID,
            selectedSketchLineID: selectedSketchLineID,
            selectedSketchEntityID: selectedSketchEntityID,
            selectedSketchEntityIDs: selectedSketchEntityIDs,
            selectedFaceID: selectedFaceID,
            selectedCutFeatureID: activeToolMode == .select ? selectedCutFeatureID : nil,
            selectedCutTargetBodyID: activeToolMode == .select ? selectedCutTargetBodyID : nil,
            hoveredWorkPlaneID: hoveredWorkPlaneID,
            selectedWorkPlaneID: selectedWorkPlane?.id,
            activeTool: activeToolMode,
            isSketchPlaneEmphasized: activeToolMode != .select || selectedSketch != nil,
            movePreviewDelta: movePreviewDelta,
            movePreviewEntityIDs: movePreviewEntityIDs,
            featurePreviewParams: featurePreviewState.map {
                $0.asExtrudedSolidParameters(assetID: CADWorkshopViewModel.featurePreviewSentinelID)
            },
            featurePreviewIsCut: featurePreviewState?.operation == .cutRemoveMaterialV2
        )
        if nextState != viewportState {
            viewportState = nextState
        }
    }

    private func currentSketchReference() -> SketchReference {
        if let selectedSketch {
            return selectedSketch.reference
        }
        return activeSketchReference
    }

    private func resetLinePreviewForPlaneChange() {
        guard activeToolMode.isSketchDrawingTool else { return }
        resetDrawingToolStates(activating: activeToolMode)
    }

    private func cameraMode(for plane: SketchPlane) -> CADCameraMode {
        switch plane {
        case .xy: return .front
        case .xz: return .top
        case .yz: return .side
        }
    }

    private func cameraMode(for preset: CADViewPreset) -> CADCameraMode {
        switch preset {
        case .iso:
            return .iso
        case .xy:
            return .front
        case .xz:
            return .top
        case .yz:
            return .side
        case .normalToSketch:
            return cameraMode(for: currentSketchReference().plane)
        case let .normalToReference(reference):
            return cameraMode(for: reference.plane)
        case .fitSelected, .fitAll:
            return .fit
        }
    }

    private func viewMode(for preset: CADViewPreset) -> SketchViewMode {
        switch preset {
        case .normalToSketch, .normalToReference(_):
            return .sketch2D
        case .iso, .xy, .xz, .yz, .fitSelected, .fitAll:
            return .free3D
        }
    }

    private func viewPreset(for plane: SketchPlane) -> CADViewPreset {
        switch plane {
        case .xy: return .xy
        case .xz: return .xz
        case .yz: return .yz
        }
    }

    private func duplicatedKind(_ kind: DesignAssetKind) -> DesignAssetKind {
        guard case var .sketch2D(parameters) = kind else {
            return kind
        }

        var lineIDMap: [UUID: UUID] = [:]
        parameters.sketch.id = UUID()
        parameters.sketch.entities = parameters.sketch.entities.map { entity in
            switch entity {
            case let .line(line):
                let newLine = SketchLine(start: line.start, end: line.end)
                lineIDMap[line.id] = newLine.id
                return .line(newLine)
            case let .rectangle(rect):
                return .rectangle(SketchRectangle(
                    firstCorner: rect.firstCorner,
                    oppositeCorner: rect.oppositeCorner,
                    constructionStyle: rect.constructionStyle
                ))
            case let .circle(circle):
                return .circle(SketchCircle(
                    center: circle.center,
                    radiusMeters: circle.radiusMeters,
                    constructionStyle: circle.constructionStyle
                ))
            case let .polyline(polyline):
                return .polyline(SketchPolyline(
                    points: polyline.points,
                    isClosed: polyline.isClosed,
                    constructionStyle: polyline.constructionStyle
                ))
            case let .arc(arc):
                return .arc(SketchArc(
                    start: arc.start,
                    end: arc.end,
                    midPoint: arc.midPoint,
                    constructionStyle: arc.constructionStyle
                ))
            }
        }
        parameters.sketch.dimensions = parameters.sketch.dimensions.compactMap { dimension in
            guard let mappedLineID = lineIDMap[dimension.lineID] else { return nil }
            return SketchDimension(kind: dimension.kind, lineID: mappedLineID)
        }
        parameters.sketch.constraints = parameters.sketch.constraints.compactMap { constraint in
            guard let mappedLineID = lineIDMap[constraint.lineID] else { return nil }
            return SketchConstraint(kind: constraint.kind, lineID: mappedLineID)
        }
        parameters.sketch.refreshClosedStatus()
        return .sketch2D(parameters)
    }

    private func sanitizedTransform(_ transform: DesignTransform) -> DesignTransform {
        DesignTransform(
            positionX: clampFinite(transform.positionX, to: -10.0...10.0),
            positionY: clampFinite(transform.positionY, to: -10.0...10.0),
            positionZ: clampFinite(transform.positionZ, to: -10.0...10.0),
            rotationX: clampFinite(transform.rotationX, to: -Double.pi * 2...Double.pi * 2),
            rotationY: clampFinite(transform.rotationY, to: -Double.pi * 2...Double.pi * 2),
            rotationZ: clampFinite(transform.rotationZ, to: -Double.pi * 2...Double.pi * 2),
            scale: clampFinite(transform.scale, to: 0.01...100.0)
        )
    }

    private func sanitizedVector(_ vector: DesignVector3, range: ClosedRange<Double>) -> DesignVector3 {
        DesignVector3(
            x: clampFinite(vector.x, to: range),
            y: clampFinite(vector.y, to: range),
            z: clampFinite(vector.z, to: range)
        )
    }

    private func sanitizedRotationVector(_ vector: DesignVector3) -> DesignVector3 {
        DesignVector3(
            x: clampFinite(vector.x, to: -Double.pi * 2...Double.pi * 2),
            y: clampFinite(vector.y, to: -Double.pi * 2...Double.pi * 2),
            z: clampFinite(vector.z, to: -Double.pi * 2...Double.pi * 2)
        )
    }

    private func sanitizedSketchPoint(_ point: SketchPoint2D) -> SketchPoint2D {
        SketchPoint2D(
            u: clampFinite(point.u, to: -10.0...10.0),
            v: clampFinite(point.v, to: -10.0...10.0)
        )
    }

    // Finds the nearest endpoint (start or end) of any non-construction line and computes
    // the phantom preview for Trim/Extend. Selection is endpoint-driven: moving the cursor
    // near a line's end determines which end the operation fires from.
    private func trimExtendPhantom(
        at cursor: SketchPoint2D,
        in sketch: DesignSketch,
        for tool: DesignWorkshopToolMode
    ) -> (phantomPoints: [SketchPoint2D]?, hoveredEntityID: UUID?, hoveredFromStart: Bool?, pendingNewEndpoint: SketchPoint2D?) {
        guard tool == .sketchTrim || tool == .sketchExtend else { return (nil, nil, nil, nil) }

        // Find the nearest endpoint across all non-construction lines.
        var bestDist = Double.infinity
        var bestLine: SketchLine? = nil
        var bestFromStart = true
        for entity in sketch.entities {
            guard let line = entity.line, line.constructionStyle != .construction else { continue }
            let ds = cursor.distance(to: line.start)
            let de = cursor.distance(to: line.end)
            if ds < bestDist { bestDist = ds; bestLine = line; bestFromStart = true }
            if de < bestDist { bestDist = de; bestLine = line; bestFromStart = false }
        }
        guard let line = bestLine else { return (nil, nil, nil, nil) }
        let fromStart = bestFromStart
        let origin: SketchPoint2D = fromStart ? line.start : line.end
        let otherLines = sketch.entities.compactMap(\.line).filter { $0.id != line.id }

        switch tool {
        case .sketchTrim:
            let dir = fromStart
                ? SketchPoint2D(u: line.end.u - line.start.u, v: line.end.v - line.start.v)
                : SketchPoint2D(u: line.start.u - line.end.u, v: line.start.v - line.end.v)
            let keepEnd: SketchPoint2D = fromStart ? line.end : line.start
            let len = sqrt(dir.u * dir.u + dir.v * dir.v)
            guard len > 1e-9 else { return (nil, line.id, fromStart, nil) }
            var nearestT = Double.infinity
            for other in otherLines {
                if let pt = raySegmentIntersect(origin: origin, direction: dir, segA: other.start, segB: other.end) {
                    let t = pt.distance(to: origin)
                    if t > 0.0002 && t < nearestT { nearestT = t }
                }
            }
            guard nearestT.isFinite else { return (nil, line.id, fromStart, nil) }
            let trimPt = SketchPoint2D(u: origin.u + dir.u / len * nearestT, v: origin.v + dir.v / len * nearestT)
            // pendingNewEndpoint = trimPt (the same point shown in the phantom)
            return ([trimPt, keepEnd], line.id, fromStart, trimPt)

        case .sketchExtend:
            let dir = fromStart
                ? SketchPoint2D(u: line.start.u - line.end.u, v: line.start.v - line.end.v)
                : SketchPoint2D(u: line.end.u - line.start.u, v: line.end.v - line.start.v)
            let len = sqrt(dir.u * dir.u + dir.v * dir.v)
            guard len > 1e-9 else { return (nil, line.id, fromStart, nil) }
            var nearestT = Double.infinity
            for other in otherLines {
                if let pt = raySegmentIntersect(origin: origin, direction: dir, segA: other.start, segB: other.end) {
                    let t = pt.distance(to: origin)
                    if t > 0.0002 && t < nearestT { nearestT = t }
                }
            }
            guard nearestT.isFinite else { return (nil, line.id, fromStart, nil) }
            let extPt = SketchPoint2D(u: origin.u + dir.u / len * nearestT, v: origin.v + dir.v / len * nearestT)
            return (fromStart ? [extPt, line.end] : [line.start, extPt], line.id, fromStart, extPt)

        default:
            return (nil, nil, nil, nil)
        }
    }

    // Returns the line entity closest to `pt` in sketch space, within a generous tolerance.
    // Used by Trim/Extend to auto-select the target line when nothing is pre-selected.
    private func nearestSketchLine(at pt: SketchPoint2D, in sketch: DesignSketch, tolerance: Double = 0.15) -> (SketchLine, Int)? {
        var bestLine: SketchLine? = nil
        var bestIdx: Int = 0
        var bestDist: Double = tolerance
        for (idx, entity) in sketch.entities.enumerated() {
            guard let line = entity.line, line.constructionStyle != .construction else { continue }
            let closest = closestPointOnSegment(from: pt, segA: line.start, segB: line.end)
            let dist = closest.distance(to: pt)
            if dist < bestDist {
                bestDist = dist
                bestLine = line
                bestIdx = idx
            }
        }
        return bestLine.map { ($0, bestIdx) }
    }

    private func sanitizedSketchParameters(_ parameters: SketchAssetParameters) -> SketchAssetParameters {
        var sanitized = parameters
        switch sanitized.sketch.reference {
        case let .canonicalPlane(plane, offsetMeters):
            sanitized.planeOffsetMeters = clampFinite(offsetMeters, to: -10.0...10.0)
            sanitized.sketch.setCanonicalPlane(plane, offsetMeters: sanitized.planeOffsetMeters)
        case let .planarFace(face):
            sanitized.sketch.setReference(.planarFace(face))
            sanitized.planeOffsetMeters = sanitized.sketch.planeOffsetMeters
        }
        sanitized.sketch.entities = parameters.sketch.entities.map { entity in
            switch entity {
            case let .line(line):
                return .line(SketchLine(
                    id: line.id,
                    start: sanitizedSketchPoint(line.start),
                    end: sanitizedSketchPoint(line.end),
                    constructionStyle: line.constructionStyle,
                    lineStyle: line.lineStyle
                ))
            case let .rectangle(rectangle):
                return .rectangle(SketchRectangle(
                    id: rectangle.id,
                    firstCorner: sanitizedSketchPoint(rectangle.firstCorner),
                    oppositeCorner: sanitizedSketchPoint(rectangle.oppositeCorner),
                    constructionStyle: rectangle.constructionStyle
                ))
            case let .circle(circle):
                return .circle(SketchCircle(
                    id: circle.id,
                    center: sanitizedSketchPoint(circle.center),
                    radiusMeters: clampFinite(circle.radiusMeters, to: 0.0005...10.0),
                    constructionStyle: circle.constructionStyle
                ))
            case let .polyline(polyline):
                return .polyline(SketchPolyline(
                    id: polyline.id,
                    points: polyline.points.map { sanitizedSketchPoint($0) },
                    isClosed: polyline.isClosed,
                    constructionStyle: polyline.constructionStyle
                ))
            case let .arc(arc):
                return .arc(SketchArc(
                    id: arc.id,
                    start: sanitizedSketchPoint(arc.start),
                    end: sanitizedSketchPoint(arc.end),
                    midPoint: sanitizedSketchPoint(arc.midPoint),
                    constructionStyle: arc.constructionStyle
                ))
            }
        }
        let validLineIDs = Set(sanitized.sketch.lines.map(\.id))
        sanitized.sketch.dimensions = parameters.sketch.dimensions.filter { validLineIDs.contains($0.lineID) }
        sanitized.sketch.constraints = parameters.sketch.constraints.filter { validLineIDs.contains($0.lineID) }
        sanitized.sketch.refreshClosedStatus()
        return sanitized
    }

    private func sanitizedKind(_ kind: DesignAssetKind) -> DesignAssetKind {
        switch kind {
        case let .basicWing(p):
            return .basicWing(BasicWingParameters(
                spanMeters: clampFinite(p.spanMeters, to: 0.1...3.0),
                rootChordMeters: clampFinite(p.rootChordMeters, to: 0.05...0.6),
                tipChordMeters: clampFinite(p.tipChordMeters, to: 0.02...0.4),
                thicknessMeters: clampFinite(p.thicknessMeters, to: 0.005...0.1),
                sweepDegrees: clampFinite(p.sweepDegrees, to: -30.0...45.0),
                dihedralDegrees: clampFinite(p.dihedralDegrees, to: -15.0...30.0),
                constructionType: p.constructionType
            ))
        case let .framePlate(p):
            return .framePlate(FramePlateParameters(
                widthMeters: clampFinite(p.widthMeters, to: 0.05...1.0),
                depthMeters: clampFinite(p.depthMeters, to: 0.05...1.0),
                thicknessMeters: clampFinite(p.thicknessMeters, to: 0.001...0.05)
            ))
        case let .beam(p):
            return .beam(BeamParameters(
                lengthMeters: clampFinite(p.lengthMeters, to: 0.05...2.0),
                widthMeters: clampFinite(p.widthMeters, to: 0.005...0.1),
                heightMeters: clampFinite(p.heightMeters, to: 0.005...0.1)
            ))
        case let .tube(p):
            let outerRadius = clampFinite(p.outerRadiusMeters, to: 0.002...0.1)
            let innerUpperBound = max(0.0005, outerRadius - 0.001)
            let innerRadius = clampFinite(p.innerRadiusMeters, to: 0.0005...innerUpperBound)
            return .tube(TubeParameters(
                lengthMeters: clampFinite(p.lengthMeters, to: 0.05...2.0),
                outerRadiusMeters: outerRadius,
                innerRadiusMeters: innerRadius
            ))
        case let .mountBracket(p):
            return .mountBracket(MountBracketParameters(
                plateWidthMeters: clampFinite(p.plateWidthMeters, to: 0.02...0.3),
                plateDepthMeters: clampFinite(p.plateDepthMeters, to: 0.02...0.3),
                plateThicknessMeters: clampFinite(p.plateThicknessMeters, to: 0.001...0.02),
                armLengthMeters: clampFinite(p.armLengthMeters, to: 0.01...0.3),
                armThicknessMeters: clampFinite(p.armThicknessMeters, to: 0.001...0.02)
            ))
        case let .payloadBox(p):
            return .payloadBox(PayloadBoxParameters(
                widthMeters: clampFinite(p.widthMeters, to: 0.02...0.5),
                heightMeters: clampFinite(p.heightMeters, to: 0.02...0.4),
                depthMeters: clampFinite(p.depthMeters, to: 0.02...0.4)
            ))
        case let .sketch2D(parameters):
            return .sketch2D(sanitizedSketchParameters(parameters))
        case let .extrudedSolid(p):
            var sanitized = p
            sanitized.profilePoints = p.profilePoints.map { sanitizedSketchPoint($0) }
            sanitized.depthMeters = clampFinite(p.depthMeters, to: 0.001...5.0)
            sanitized.sourcePlane = sanitized.sourceReference.plane
            sanitized.planeOffsetMeters = sanitized.sourceReference.planeOffsetMeters
            sanitized.refreshFaces(assetID: p.faces.first?.assetID ?? UUID())
            return .extrudedSolid(sanitized)
        }
    }

    private func clampFinite(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}
