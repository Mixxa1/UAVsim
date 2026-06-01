import Foundation
import AppKit
import SceneKit
import simd

// MARK: - Camera modes

enum CADCameraMode: String, CaseIterable, Equatable {
    case iso
    case top
    case front
    case side
    case fit

    var labelKey: String {
        switch self {
        case .iso:   return "cad.camera.iso"
        case .top:   return "cad.camera.top"
        case .front: return "cad.camera.front"
        case .side:  return "cad.camera.side"
        case .fit:   return "cad.camera.fit"
        }
    }

    var systemImage: String {
        switch self {
        case .iso:   return "cube"
        case .top:   return "arrow.down.to.line"
        case .front: return "square"
        case .side:  return "rectangle.portrait"
        case .fit:   return "arrow.up.left.and.arrow.down.right"
        }
    }
}

// MARK: - Canvas visibility and snap options

enum CADSnapKind: String, Equatable {
    case sketchVertex
    case activeCircleCenter
    case bodyVertex
    case bodyEdge
    case edgeMidpoint
    case constructionVertex
    case constructionLine
    case constructionIntersection
    case grid
    // Cross-sketch same-plane reference snap
    case referenceSketchVertex
    case referenceSketchEdgeMidpoint
    // Cross-plane projected snap
    case projectedSketchVertex
    case projectedSketchEdgeMidpoint

    var displayName: String {
        switch self {
        case .sketchVertex:               return NSLocalizedString("cad.snap.sketch_vertex", comment: "")
        case .activeCircleCenter:         return NSLocalizedString("cad.snap.circle_center", comment: "")
        case .bodyVertex:                 return NSLocalizedString("cad.snap.body_vertex", comment: "")
        case .bodyEdge:                   return NSLocalizedString("cad.snap.body_edge", comment: "")
        case .edgeMidpoint:               return NSLocalizedString("cad.snap.edge_midpoint", comment: "")
        case .constructionVertex:         return NSLocalizedString("cad.snap.construction_vertex", comment: "")
        case .constructionLine:           return NSLocalizedString("cad.snap.construction_line", comment: "")
        case .constructionIntersection:   return NSLocalizedString("cad.snap.construction_intersection", comment: "")
        case .grid:                       return NSLocalizedString("cad.snap.grid", comment: "")
        case .referenceSketchVertex:      return NSLocalizedString("cad.snap.reference_sketch_vertex", comment: "")
        case .referenceSketchEdgeMidpoint:return NSLocalizedString("cad.snap.reference_sketch_edge_midpoint", comment: "")
        case .projectedSketchVertex:      return NSLocalizedString("cad.snap.projected_sketch_vertex", comment: "")
        case .projectedSketchEdgeMidpoint:return NSLocalizedString("cad.snap.projected_sketch_edge_midpoint", comment: "")
        }
    }

    // Lower int = higher snap priority. Grid/axis are fallbacks not in this list.
    var priority: Int {
        switch self {
        case .sketchVertex:                return 0
        case .edgeMidpoint:               return 1
        case .activeCircleCenter:         return 3
        case .referenceSketchVertex:      return 4
        case .referenceSketchEdgeMidpoint:return 5
        case .bodyVertex:                 return 7
        case .bodyEdge:                   return 8
        case .projectedSketchVertex:      return 9
        case .projectedSketchEdgeMidpoint:return 10
        case .constructionVertex:         return 12
        case .constructionIntersection:   return 13
        case .constructionLine:           return 14
        case .grid:                       return 15
        }
    }
}

struct CADSnapOptions: Equatable {
    var isEnabled: Bool = true
    var snapToGrid: Bool = true
    var snapToSketchVertices: Bool = true
    var snapToBodyVertices: Bool = true
    var snapToBodyEdges: Bool = true
    var snapToEdgeMidpoints: Bool = true
    var snapToConstructionPoints: Bool = true
    var snapToConstructionLines: Bool = true
    var snapToConstructionIntersections: Bool = true
    var snapToReferenceSketches: Bool = true
    var snapTolerancePixels: Double = 12
    var gridStepMeters: Double = 0.05

    var effectiveSnapToGrid: Bool {
        isEnabled && snapToGrid
    }
}

struct CADSnapResult: Equatable {
    var rawPoint: SketchPoint2D
    var point: SketchPoint2D
    var screenPoint: CGPoint = .zero
    var kind: CADSnapKind?
    var displayName: String?
    var worldPoint: DesignVector3?
    var edgeStartWorld: DesignVector3?
    var edgeEndWorld: DesignVector3?
}

struct CADSnapCandidate: Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: CADSnapKind
    var worldPoint: DesignVector3
    var sketchPoint: SketchPoint2D
    var sourceAssetID: UUID?
    var sourceFaceID: UUID?
    /// ID of the sketch entity (line, rectangle, etc.) this candidate was derived from.
    var sourceEntityID: UUID?
    var displayName: String
    var priority: Int
    var edgeStartWorld: DesignVector3?
    var edgeEndWorld: DesignVector3?
}

struct DesignCanvasOptions: Equatable {
    var showGrid: Bool = true
    var showAxes: Bool = true
    var showReferencePlanes: Bool = true
    var showActivePlaneOverlay: Bool = true
    var showAttachmentPoints: Bool = true
    var showConstraintGlyphs: Bool = true
    var snapOptions: CADSnapOptions = CADSnapOptions()

    var snapToGrid: Bool {
        get { snapOptions.snapToGrid }
        set { snapOptions.snapToGrid = newValue }
    }

    var gridStepMeters: Double {
        get { snapOptions.gridStepMeters }
        set { snapOptions.gridStepMeters = newValue }
    }
}

enum CADSketchVisualLayer {
    static let overlay: Double = 0.00002
    static let grid: Double = 0.00004
    static let sketch: Double = 0.00006
    static let points: Double = 0.00008
    static let phantom: Double = 0.00010
    static let cursor: Double = 0.00012
}

enum CADViewportDebug {
    static var isEnabled = false

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        if isEnabled {
            print("[CADViewport] \(message())")
        }
        #endif
    }
}

private enum CADSceneRootName {
    static let worldGrid = "cad_world_grid"
    static let sketchGrid = "cad_sketch_grid"
    static let worldAxes = "cad_world_axes"
    static let planeAxes = "cad_plane_axes"
    static let referencePlanes = "cad_reference_planes"
    static let activePlaneOverlay = "cad_active_sketch_plane"
    static let assets = "assets_container"
    static let phantomLine = "cad_phantom_line"
    static let cursorMarker = "cad_cursor_marker"
    static let snapMarker = "cad_snap_marker"
    static let dimensionOverlay = "cad_dimension_overlay"
}

enum CADViewPreset: Equatable {
    case iso
    case xy
    case xz
    case yz
    case normalToSketch
    case normalToReference(SketchReference)
    case fitSelected
    case fitAll
}

enum CADGridMode: Equatable {
    case worldXZ
    case sketchPlane(SketchReference)
    case hidden
}

enum CADAxesMode: Equatable {
    case world3D
    case plane2D(SketchReference)
    case hidden
}

enum CADFocusTarget: Equatable {
    case selectedOrAll
    case asset(UUID)
    case workPlane(CADWorkPlane)
    case all
    case origin
}

struct CADCameraPreset: Equatable {
    var viewMode: SketchViewMode
    var cameraDirection: DesignVector3
    var upVector: DesignVector3
    var gridMode: CADGridMode
    var axesMode: CADAxesMode
    var useOrthographic: Bool
    var allowOrbit: Bool
    var allowPan: Bool
    var allowZoom: Bool
}

enum SketchViewMode: String, Equatable {
    case free3D
    case sketch2D
}

struct DesignViewportState: Equatable {
    var activePlane: SketchPlane
    var activePlaneOffsetMeters: Double
    var activeReference: SketchReference
    var viewMode: SketchViewMode
    var orientation: CADCameraMode
    var showGrid: Bool
    var showAxes: Bool
    var showReferencePlanes: Bool
    var showActivePlaneOverlay: Bool
    var showAttachmentPoints: Bool
    var showConstraintGlyphs: Bool
    var snapOptions: CADSnapOptions
    var selectedAssetID: UUID?
    var selectedAttachmentPointID: UUID?
    var selectedSketchLineID: UUID?
    var selectedSketchEntityID: UUID?
    var selectedSketchEntityIDs: Set<UUID>
    var selectedFaceID: UUID?
    var selectedCutFeatureID: UUID?
    var selectedCutTargetBodyID: UUID?
    var hoveredWorkPlaneID: String?
    var selectedWorkPlaneID: String?
    var activeTool: DesignWorkshopToolMode
    var isSketchPlaneEmphasized: Bool
    var movePreviewDelta: SketchPoint2D?
    var movePreviewEntityIDs: Set<UUID>
    var featurePreviewParams: ExtrudedSolidParameters?
    var featurePreviewIsCut: Bool

    init(
        activePlane: SketchPlane = .xz,
        activePlaneOffsetMeters: Double = 0,
        activeReference: SketchReference? = nil,
        viewMode: SketchViewMode = .free3D,
        orientation: CADCameraMode = .iso,
        showGrid: Bool = true,
        showAxes: Bool = true,
        showReferencePlanes: Bool = true,
        showActivePlaneOverlay: Bool = true,
        showAttachmentPoints: Bool = true,
        showConstraintGlyphs: Bool = true,
        snapOptions: CADSnapOptions = CADSnapOptions(),
        selectedAssetID: UUID? = nil,
        selectedAttachmentPointID: UUID? = nil,
        selectedSketchLineID: UUID? = nil,
        selectedSketchEntityID: UUID? = nil,
        selectedSketchEntityIDs: Set<UUID> = [],
        selectedFaceID: UUID? = nil,
        selectedCutFeatureID: UUID? = nil,
        selectedCutTargetBodyID: UUID? = nil,
        hoveredWorkPlaneID: String? = nil,
        selectedWorkPlaneID: String? = nil,
        activeTool: DesignWorkshopToolMode = .select,
        isSketchPlaneEmphasized: Bool = false,
        movePreviewDelta: SketchPoint2D? = nil,
        movePreviewEntityIDs: Set<UUID> = [],
        featurePreviewParams: ExtrudedSolidParameters? = nil,
        featurePreviewIsCut: Bool = false
    ) {
        self.activePlane = activePlane
        self.activePlaneOffsetMeters = activePlaneOffsetMeters
        self.activeReference = activeReference ?? .canonicalPlane(activePlane, offsetMeters: activePlaneOffsetMeters)
        self.viewMode = viewMode
        self.orientation = orientation
        self.showGrid = showGrid
        self.showAxes = showAxes
        self.showReferencePlanes = showReferencePlanes
        self.showActivePlaneOverlay = showActivePlaneOverlay
        self.showAttachmentPoints = showAttachmentPoints
        self.showConstraintGlyphs = showConstraintGlyphs
        self.snapOptions = snapOptions
        self.selectedAssetID = selectedAssetID
        self.selectedAttachmentPointID = selectedAttachmentPointID
        self.selectedSketchLineID = selectedSketchLineID
        self.selectedSketchEntityID = selectedSketchEntityID
        self.selectedSketchEntityIDs = selectedSketchEntityIDs
        self.selectedFaceID = selectedFaceID
        self.selectedCutFeatureID = selectedCutFeatureID
        self.selectedCutTargetBodyID = selectedCutTargetBodyID
        self.hoveredWorkPlaneID = hoveredWorkPlaneID
        self.selectedWorkPlaneID = selectedWorkPlaneID
        self.activeTool = activeTool
        self.isSketchPlaneEmphasized = isSketchPlaneEmphasized
        self.movePreviewDelta = movePreviewDelta
        self.movePreviewEntityIDs = movePreviewEntityIDs
        self.featurePreviewParams = featurePreviewParams
        self.featurePreviewIsCut = featurePreviewIsCut
    }

    var isSketch2DMode: Bool {
        viewMode == .sketch2D
    }

    var canvasOptions: DesignCanvasOptions {
        DesignCanvasOptions(
            showGrid: showGrid,
            showAxes: showAxes,
            showReferencePlanes: showReferencePlanes,
            showActivePlaneOverlay: showActivePlaneOverlay,
            showAttachmentPoints: showAttachmentPoints,
            showConstraintGlyphs: showConstraintGlyphs,
            snapOptions: snapOptions
        )
    }

    var gridStepMeters: Double {
        snapOptions.gridStepMeters
    }

    var snapToGrid: Bool {
        snapOptions.snapToGrid
    }

    func needsCameraSync(comparedTo previous: DesignViewportState?) -> Bool {
        guard let previous else { return true }
        return previous.activePlane != activePlane
            || previous.activePlaneOffsetMeters != activePlaneOffsetMeters
            || previous.activeReference != activeReference
            || previous.viewMode != viewMode
            || previous.orientation != orientation
    }

    func needsGridSync(comparedTo previous: DesignViewportState?) -> Bool {
        guard let previous else { return true }
        return previous.activePlane != activePlane
            || previous.activePlaneOffsetMeters != activePlaneOffsetMeters
            || previous.activeReference != activeReference
            || previous.viewMode != viewMode
            || previous.orientation != orientation
            || previous.gridStepMeters != gridStepMeters
            || previous.showGrid != showGrid
            || previous.showReferencePlanes != showReferencePlanes
            || previous.hoveredWorkPlaneID != hoveredWorkPlaneID
            || previous.selectedWorkPlaneID != selectedWorkPlaneID
    }

    func needsAxesSync(comparedTo previous: DesignViewportState?) -> Bool {
        guard let previous else { return true }
        return previous.activePlane != activePlane
            || previous.activeReference != activeReference
            || previous.viewMode != viewMode
            || previous.orientation != orientation
            || previous.showAxes != showAxes
    }

    func needsPlaneOverlaySync(comparedTo previous: DesignViewportState?) -> Bool {
        guard let previous else { return true }
        return previous.activePlane != activePlane
            || previous.activePlaneOffsetMeters != activePlaneOffsetMeters
            || previous.activeReference != activeReference
            || previous.isSketchPlaneEmphasized != isSketchPlaneEmphasized
            || previous.showActivePlaneOverlay != showActivePlaneOverlay
    }
}

enum CADPreviewCameraTarget: Equatable {
    case mode(CADCameraMode)
    case focusAsset(UUID)
    case viewPreset(CADViewPreset, CADFocusTarget)
    case enterIsoHardReset(UUID?)
    case isoFocusAsset(UUID)
    case isoFitSelectedOrAll
    case fitAll
    case resetDefault
}

struct CADPreviewCameraCommand: Equatable {
    let id: UUID
    let target: CADPreviewCameraTarget

    init(id: UUID = UUID(), target: CADPreviewCameraTarget) {
        self.id = id
        self.target = target
    }
}

// MARK: - Scene builder

final class DesignPreviewSceneBuilder {

    static func buildScene() -> SCNScene {
        let scene = SCNScene()
        addLighting(to: scene)
        addWorldGrid(to: scene)
        addWorldAxes(to: scene)
        return scene
    }

    static func addCamera(to view: SCNView) {
        let cameraNode = SCNNode()
        cameraNode.name = "previewCamera"
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = 200
        camera.automaticallyAdjustsZRange = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.8, 0.6, 1.1)
        cameraNode.look(at: SCNVector3(0, 0.05, 0.10))
        view.scene?.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
    }

    // Apply a named camera mode to the view (animated, uses explicit eulerAngles for strict orthogonality)
    static func applyMode(_ mode: CADCameraMode, to view: SCNView, assets: [DesignAsset], animated: Bool = true) {
        if mode == .iso {
            let sphere = boundingSphere(for: assets)
            applyIsoCamera(to: view, center: sphere.center, radius: sphere.radius, animated: animated)
            applyAxisVisibility(for: .iso, in: view)
            return
        }

        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return }

        let (center, radius) = boundingSphere(for: assets)
        let cx = Float(center.x)
        let cy = Float(center.y)
        let cz = Float(center.z)
        let r  = Float(radius)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.35 : 0

        switch mode {
        case .iso:
            break
        case .top:
            view.allowsCameraControl = false
            let dist = max(r * 3.0, 2.0)
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(max(r * 2.2, 0.8))
            cameraNode.position = SCNVector3(cx, cy - dist, cz)
            cameraNode.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)

        case .front:
            view.allowsCameraControl = false
            let dist = max(r * 3.0, 2.0)
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(max(r * 2.2, 0.8))
            cameraNode.position = SCNVector3(cx, cy, cz + dist)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)

        case .side:
            view.allowsCameraControl = false
            let dist = max(r * 3.0, 2.0)
            camera.usesOrthographicProjection = true
            camera.orthographicScale = Double(max(r * 2.2, 0.8))
            cameraNode.position = SCNVector3(cx - dist, cy, cz)
            cameraNode.eulerAngles = SCNVector3(0, -Float.pi / 2, 0)

        case .fit:
            let fitDist = max(r * 2.5, 0.6)
            view.allowsCameraControl = true
            camera.usesOrthographicProjection = false
            camera.fieldOfView = 45
            cameraNode.position = SCNVector3(cx + fitDist * 0.7, cy + fitDist * 0.6, cz + fitDist)
            cameraNode.look(at: SCNVector3(cx, cy, cz))
        }

        view.defaultCameraController.target = SCNVector3(cx, cy, cz)
        view.pointOfView = cameraNode
        SCNTransaction.commit()

        applyAxisVisibility(for: mode, in: view)
    }

    static func applyCommand(
        _ command: CADPreviewCameraCommand,
        to view: SCNView,
        document: DesignDocument,
        viewportState: DesignViewportState,
        canvasOptions: DesignCanvasOptions? = nil
    ) {
        CADViewportDebug.log("Camera command apply: \(command.target), id: \(command.id)")
        // Always instant (no animation) — button-triggered jumps must not animate while
        // allowsCameraControl is active, since the controller fights a live animation.
        switch command.target {
        case let .mode(mode):
            if mode == .fit {
                applyViewPreset(.fitSelected, focus: .selectedOrAll, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
            } else if mode == .iso {
                applyViewPreset(.iso, focus: .selectedOrAll, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
            } else {
                applyViewPreset(viewPreset(for: mode), focus: .selectedOrAll, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
            }
        case let .focusAsset(assetID):
            applyViewPreset(.fitSelected, focus: .asset(assetID), to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case let .viewPreset(preset, focus):
            applyViewPreset(preset, focus: focus, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case let .enterIsoHardReset(assetID):
            applyViewPreset(.iso, focus: assetID.map(CADFocusTarget.asset) ?? .selectedOrAll, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case let .isoFocusAsset(assetID):
            applyViewPreset(.iso, focus: .asset(assetID), to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case .isoFitSelectedOrAll:
            applyViewPreset(.iso, focus: .selectedOrAll, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case .fitAll:
            applyViewPreset(.fitAll, focus: .all, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        case .resetDefault:
            applyViewPreset(.iso, focus: .origin, to: view, document: document, viewportState: viewportState, canvasOptions: canvasOptions)
        }
    }

    static func applyViewPreset(
        _ preset: CADViewPreset,
        focus: CADFocusTarget,
        to view: SCNView,
        document: DesignDocument,
        viewportState: DesignViewportState,
        canvasOptions: DesignCanvasOptions? = nil
    ) {
        removePhantomLine(from: view)
        removeCursorMarker(from: view)

        let cameraPreset = cameraPreset(for: preset, document: document, viewportState: viewportState)
        applyGridMode(cameraPreset.gridMode, options: canvasOptions, to: view)
        applyAxesMode(cameraPreset.axesMode, options: canvasOptions, to: view)
        applyPlaneOverlay(for: cameraPreset.gridMode, options: canvasOptions, to: view)
        updateReferencePlanes(for: viewportState, options: canvasOptions, cameraPreset: cameraPreset, in: view)
        // Restore visibility for iso/free-3D presets (ensures body/sketch visible after sketch2D mode).
        if case .worldXZ = cameraPreset.gridMode {
            restoreCADLayerVisibilityForIso(canvasOptions: canvasOptions, to: view)
        } else {
            restoreAssetLayerVisibility(options: canvasOptions, to: view)
        }

        let sphere = resolveFocusTarget(focus, document: document)
        CADViewportDebug.log("View preset: \(preset)")
        CADViewportDebug.log("Focus target: \(sphere.center.x), \(sphere.center.y), \(sphere.center.z)")
        CADViewportDebug.log("Bounds radius: \(sphere.radius)")
        CADViewportDebug.log("World grid visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden == false)")
        CADViewportDebug.log("World axes visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.worldAxes, recursively: false)?.isHidden == false)")
        CADViewportDebug.log("Sketch grid visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden == false)")

        applyCameraPreset(cameraPreset, focus: sphere, to: view)

        // Safety: if the camera ended up in an invalid state (NaN, bad scale, etc.),
        // recover to a safe framing of all scene content.
        if !isCameraValid(in: view) {
            recoverViewportCamera(in: view, document: document, reason: "post-preset validation")
        }
    }

    static func enterIsoViewHardReset(
        to view: SCNView,
        document: DesignDocument,
        focusAssetID: UUID? = nil,
        canvasOptions: DesignCanvasOptions? = nil,
        animated: Bool
    ) {
        removePhantomLine(from: view)
        removeCursorMarker(from: view)
        restoreCADLayerVisibilityForIso(canvasOptions: canvasOptions, to: view)
        applyIsoView(
            to: view,
            document: document,
            focusAssetID: focusAssetID,
            canvasOptions: canvasOptions,
            animated: animated
        )
    }

    static func applyIsoView(
        to view: SCNView,
        document: DesignDocument,
        focusAssetID: UUID? = nil,
        canvasOptions: DesignCanvasOptions? = nil,
        animated: Bool
    ) {
        restoreCADLayerVisibilityForIso(canvasOptions: canvasOptions, to: view)

        let explicitlyFocusedAsset = focusAssetID.flatMap { id in
            document.assets.first(where: { $0.id == id })
        }
        let selectedAsset = explicitlyFocusedAsset ?? document.selectedAsset
        let selectedAssetIsValid = selectedAsset.map(isValidAssetForCamera) ?? false
        let focusAssets = selectedAssetIsValid ? selectedAsset.map { [$0] } ?? [] : document.assets
        let sphere = boundingSphere(for: focusAssets)
        let sketchCount = document.assets.filter {
            if case .sketch2D = $0.kind { return true }
            return false
        }.count
        let solidCount = document.assets.filter {
            if case .extrudedSolid = $0.kind { return true }
            return false
        }.count

        CADViewportDebug.log("Iso pressed")
        CADViewportDebug.log("Visible solids: \(solidCount)")
        CADViewportDebug.log("Visible sketches: \(sketchCount)")
        CADViewportDebug.log("Selected asset valid: \(selectedAssetIsValid)")
        CADViewportDebug.log("Focus target: \(sphere.center.x), \(sphere.center.y), \(sphere.center.z)")
        CADViewportDebug.log("Bounds radius: \(sphere.radius)")
        CADViewportDebug.log("World grid visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden == false)")
        CADViewportDebug.log("World axes visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.worldAxes, recursively: false)?.isHidden == false)")
        CADViewportDebug.log("Sketch grid visible: \(view.scene?.rootNode.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden == false)")

        applyIsoCamera(to: view, center: sphere.center, radius: sphere.radius, animated: animated)
        applyAxisVisibility(for: .iso, in: view)
    }

    private static func cameraPreset(
        for preset: CADViewPreset,
        document: DesignDocument,
        viewportState: DesignViewportState
    ) -> CADCameraPreset {
        switch preset {
        case .iso, .fitSelected, .fitAll:
            return CADCameraPreset(
                viewMode: .free3D,
                cameraDirection: DesignVector3(x: 1, y: 1, z: 1),
                upVector: .yAxis,
                gridMode: .worldXZ,
                axesMode: .world3D,
                useOrthographic: true,
                allowOrbit: true,
                allowPan: true,
                allowZoom: true
            )
        case .xy:
            let reference = SketchReference.canonicalPlane(.xy, offsetMeters: viewportState.activePlaneOffsetMeters)
            return planeCameraPreset(
                reference: reference,
                cameraDirection: .zAxis,
                upVector: .yAxis
            )
        case .xz:
            let reference = SketchReference.canonicalPlane(.xz, offsetMeters: viewportState.activePlaneOffsetMeters)
            return planeCameraPreset(
                reference: reference,
                cameraDirection: .yAxis,
                upVector: .zAxis
            )
        case .yz:
            let reference = SketchReference.canonicalPlane(.yz, offsetMeters: viewportState.activePlaneOffsetMeters)
            return planeCameraPreset(
                reference: reference,
                cameraDirection: .xAxis,
                upVector: .yAxis
            )
        case .normalToSketch:
            let reference = selectedSketchReference(in: document) ?? viewportState.activeReference
            let axes = axesForSketchReference(reference)
            return planeCameraPreset(
                reference: reference,
                cameraDirection: axes.normal,
                upVector: axes.v
            )
        case let .normalToReference(reference):
            let axes = axesForSketchReference(reference)
            return planeCameraPreset(
                reference: reference,
                cameraDirection: axes.normal,
                upVector: axes.v
            )
        }
    }

    private static func planeCameraPreset(
        reference: SketchReference,
        cameraDirection: DesignVector3,
        upVector: DesignVector3
    ) -> CADCameraPreset {
        CADCameraPreset(
            viewMode: .sketch2D,
            cameraDirection: cameraDirection,
            upVector: upVector,
            gridMode: .sketchPlane(reference),
            axesMode: .plane2D(reference),
            useOrthographic: true,
            allowOrbit: false,
            allowPan: true,
            allowZoom: true
        )
    }

    private static func selectedSketchReference(in document: DesignDocument) -> SketchReference? {
        guard let selected = document.selectedAsset,
              case let .sketch2D(parameters) = selected.kind else { return nil }
        return parameters.sketch.reference
    }

    private static func viewPreset(for mode: CADCameraMode) -> CADViewPreset {
        switch mode {
        case .iso: return .iso
        case .top: return .xz
        case .front: return .xy
        case .side: return .yz
        case .fit: return .fitSelected
        }
    }

    private static func referenceForCameraMode(_ mode: CADCameraMode, offsetMeters: Double) -> SketchReference {
        switch mode {
        case .front:
            return .canonicalPlane(.xy, offsetMeters: offsetMeters)
        case .top:
            return .canonicalPlane(.xz, offsetMeters: offsetMeters)
        case .side:
            return .canonicalPlane(.yz, offsetMeters: offsetMeters)
        case .iso, .fit:
            return .canonicalPlane(.xz, offsetMeters: 0)
        }
    }

    private static func resolveFocusTarget(
        _ focus: CADFocusTarget,
        document: DesignDocument
    ) -> (center: SCNVector3, radius: Float) {
        switch focus {
        case .origin:
            return (SCNVector3(0, 0, 0), 0.7)
        case let .workPlane(workPlane):
            let center = workPlane.center
            return (
                SCNVector3(Float(center.x), Float(center.y), Float(center.z)),
                Float(workPlane.focusRadius)
            )
        case let .asset(assetID):
            if let asset = document.assets.first(where: { $0.id == assetID }),
               isValidAssetForCamera(asset) {
                return boundingSphere(for: [asset])
            }
            return resolveFocusTarget(.selectedOrAll, document: document)
        case .all:
            return boundingSphere(for: document.assets)
        case .selectedOrAll:
            if let selected = document.selectedAsset,
               isValidAssetForCamera(selected) {
                return boundingSphere(for: [selected])
            }
            return boundingSphere(for: document.assets)
        }
    }

    private static func applyFocusOrFit(to view: SCNView, document: DesignDocument) {
        if let selected = document.selectedAsset {
            applyMode(.fit, to: view, assets: [selected], animated: false)
        } else if !document.assets.isEmpty {
            applyMode(.fit, to: view, assets: document.assets, animated: false)
        } else {
            applyMode(.iso, to: view, assets: [])
        }
    }

    static func applyViewportState(
        _ state: DesignViewportState,
        to view: SCNView,
        document: DesignDocument,
        previousState: DesignViewportState?,
        animated: Bool
    ) {
        // Viewport state updates are allowed to rebuild CAD layers, but they must
        // not refit or reorient the camera during normal sketch/document editing.
        // Camera movement is reserved for explicit CADPreviewCameraCommand events.
        if previousState == nil, state.needsCameraSync(comparedTo: previousState) {
            applyCameraOrientation(state, to: view, document: document, animated: animated)
        }

        if state.needsGridSync(comparedTo: previousState) {
            updateVisibleGrid(for: state, in: view)
        }

        if state.needsPlaneOverlaySync(comparedTo: previousState) {
            updateActivePlaneOverlay(
                reference: state.activeReference,
                emphasized: state.isSketchPlaneEmphasized,
                visible: state.showActivePlaneOverlay,
                in: view
            )
        }

        if state.needsAxesSync(comparedTo: previousState) {
            updateVisibleAxes(for: state, in: view)
        }

        applyCanvasOptions(state.canvasOptions, to: view)
        updateReferencePlanes(
            for: state,
            options: state.canvasOptions,
            cameraPreset: cameraPreset(for: viewPreset(for: state.orientation), document: document, viewportState: state),
            in: view
        )
        if state.viewMode == .free3D, state.orientation == .iso {
            restoreCADLayerVisibilityForIso(canvasOptions: state.canvasOptions, to: view)
        }

        // Update dimension annotation overlay whenever viewport state changes
        if let assetID = state.selectedAssetID,
           let asset = document.assets.first(where: { $0.id == assetID }),
           case let .sketch2D(params) = asset.kind {
            updateDimensionAnnotations(sketch: params.sketch, reference: state.activeReference, in: view)
        } else {
            removeDimensionAnnotations(from: view)
        }
    }

    private static func applyCameraOrientation(
        _ state: DesignViewportState,
        to view: SCNView,
        document: DesignDocument,
        animated: Bool
    ) {
        if state.viewMode == .sketch2D {
            applyViewPreset(
                .normalToSketch,
                focus: .selectedOrAll,
                to: view,
                document: document,
                viewportState: state,
                canvasOptions: state.canvasOptions
            )
            return
        }

        applyViewPreset(
            viewPreset(for: state.orientation),
            focus: .selectedOrAll,
            to: view,
            document: document,
            viewportState: state,
            canvasOptions: state.canvasOptions
        )
    }

    static func setSketch2DView(
        reference: SketchReference,
        to view: SCNView,
        assets: [DesignAsset],
        animated: Bool = false
    ) {
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return }

        let (center, radius) = boundingSphere(for: assets)
        let safeRadius = safeCameraRadius(radius)
        let axes = axesForSketchReference(reference)
        let referenceOrigin = originForSketchReference(reference)
        let targetVector = sketchCameraTarget(for: reference, sceneCenter: center, referenceOrigin: referenceOrigin)
        let distance = max(Double(safeRadius) * 3.0, 2.0)
        let normal = axes.normal.normalized(fallback: .zAxis)
        let positionVector = targetVector + normal * distance
        let controllerTarget = SCNVector3(
            Float(targetVector.x),
            Float(targetVector.y),
            Float(targetVector.z)
        )

        // Disable control first to prevent controller from fighting the orientation change.
        view.allowsCameraControl = false
        view.defaultCameraController.stopInertia()
        cameraNode.removeAllActions()

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.18 : 0
        camera.usesOrthographicProjection = true
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = max(200.0, distance * 3.0)
        camera.orthographicScale = Double(min(max(safeRadius * 2.2, 0.8), 20.0))
        camera.automaticallyAdjustsZRange = false
        setCameraBasis(
            cameraNode,
            position: positionVector,
            xAxis: axes.u,
            yAxis: axes.v,
            zAxis: normal
        )
        SCNTransaction.commit()

        view.defaultCameraController.target = controllerTarget
        view.defaultCameraController.pointOfView = cameraNode
        view.pointOfView = cameraNode
        // allowsCameraControl stays false in sketch2D — orbit is locked, only pan/zoom via gestures.

        applyAxisVisibility(for: cameraMode(for: reference.plane), in: view)
    }

    // Apply canvas visibility options (grid, axes, attachment point markers)
    static func applyCanvasOptions(_ options: DesignCanvasOptions, to view: SCNView) {
        guard let scene = view.scene else { return }
        let root = scene.rootNode
        root.childNode(withName: CADSceneRootName.referencePlanes, recursively: false)?.isHidden = !options.showReferencePlanes
        root.childNode(withName: CADSceneRootName.activePlaneOverlay, recursively: false)?.isHidden = !options.showActivePlaneOverlay
        if let container = root.childNode(withName: CADSceneRootName.assets, recursively: false) {
            for assetNode in container.childNodes {
                for child in assetNode.childNodes where child.name?.hasPrefix("ap_") == true {
                    child.isHidden = !options.showAttachmentPoints
                }
            }
        }
    }

    static func restoreCADLayerVisibilityForIso(
        canvasOptions options: DesignCanvasOptions?,
        to view: SCNView
    ) {
        guard let scene = view.scene else { return }
        let root = scene.rootNode
        rebuildWorldGrid(gridStepMeters: options?.gridStepMeters ?? DesignCanvasOptions().gridStepMeters, in: view)
        ensureWorldAxes(in: view)

        root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = options.map { !$0.showGrid } ?? false
        root.childNode(withName: CADSceneRootName.worldAxes, recursively: false)?.isHidden = options.map { !$0.showAxes } ?? false
        root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = true
        root.childNode(withName: CADSceneRootName.planeAxes, recursively: false)?.isHidden = true
        root.childNode(withName: CADSceneRootName.referencePlanes, recursively: false)?.isHidden = options.map { !$0.showReferencePlanes } ?? false
        root.childNode(withName: CADSceneRootName.activePlaneOverlay, recursively: false)?.isHidden = true
        root.childNode(withName: CADSceneRootName.phantomLine, recursively: false)?.isHidden = false
        root.childNode(withName: CADSceneRootName.cursorMarker, recursively: false)?.isHidden = false

        if let container = root.childNode(withName: CADSceneRootName.assets, recursively: false) {
            container.isHidden = false
            for assetNode in container.childNodes {
                assetNode.isHidden = false
                for child in assetNode.childNodes where child.name?.hasPrefix("ap_") == true {
                    child.isHidden = options.map { !$0.showAttachmentPoints } ?? child.isHidden
                }
            }
        }
    }

    private static func updateReferencePlanes(
        for state: DesignViewportState,
        options: DesignCanvasOptions?,
        cameraPreset: CADCameraPreset,
        in view: SCNView
    ) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.referencePlanes, recursively: false)?.removeFromParentNode()

        let shouldShow = (options?.showReferencePlanes ?? true)
            && state.viewMode == .free3D
            && cameraPreset.gridMode == .worldXZ
        guard shouldShow else { return }

        let container = SCNNode()
        container.name = CADSceneRootName.referencePlanes
        for plane in SketchPlane.allCases {
            let workPlane = CADWorkPlane.canonical(plane)
            container.addChildNode(
                makeReferencePlaneNode(
                    workPlane,
                    hovered: state.hoveredWorkPlaneID == workPlane.id,
                    selected: state.selectedWorkPlaneID == workPlane.id
                )
            )
        }
        scene.rootNode.addChildNode(container)
    }

    private static func makeReferencePlaneNode(
        _ workPlane: CADWorkPlane,
        hovered: Bool,
        selected: Bool
    ) -> SCNNode {
        let container = SCNNode()
        container.name = "workPlaneContainer:\(workPlane.id)"

        let halfSize = max(workPlane.focusRadius, 0.35)
        let geometry = planeQuadGeometry(
            reference: workPlane.reference,
            halfSize: halfSize,
            normalOffsetMeters: CADSketchVisualLayer.overlay
        )
        geometry.firstMaterial = referencePlaneMaterial(for: workPlane.reference.plane, hovered: hovered, selected: selected)

        let surface = SCNNode(geometry: geometry)
        surface.name = "workPlane:\(workPlane.reference.plane.rawValue)"
        surface.renderingOrder = selected ? -8 : (hovered ? -9 : -10)
        container.addChildNode(surface)

        let axes = axesForSketchReference(workPlane.reference)
        let origin = originForSketchReference(workPlane.reference) + axes.normal * CADSketchVisualLayer.phantom
        let corners = [
            origin + axes.u * -halfSize + axes.v * -halfSize,
            origin + axes.u *  halfSize + axes.v * -halfSize,
            origin + axes.u *  halfSize + axes.v *  halfSize,
            origin + axes.u * -halfSize + axes.v *  halfSize,
        ]
        let outlineMaterial = referencePlaneOutlineMaterial(selected: selected, hovered: hovered)
        for index in 0..<corners.count {
            let next = (index + 1) % corners.count
            addGridLine(from: scnVector(corners[index]), to: scnVector(corners[next]), material: outlineMaterial, container: container)
        }

        let labelPoint = corners[2] + axes.u * 0.04 + axes.v * 0.04
        container.addChildNode(makeReferencePlaneLabel(workPlane.reference.plane.displayName, at: labelPoint, selected: selected || hovered))
        return container
    }

    private static func referencePlaneMaterial(
        for plane: SketchPlane,
        hovered: Bool,
        selected: Bool
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        let alpha: CGFloat = selected ? 0.18 : (hovered ? 0.13 : 0.065)
        switch plane {
        case .xy:
            material.diffuse.contents = CGColor(red: 0.20, green: 0.55, blue: 1.0, alpha: alpha)
            material.emission.contents = CGColor(red: 0.05, green: 0.20, blue: 0.45, alpha: alpha)
        case .xz:
            material.diffuse.contents = CGColor(red: 0.12, green: 0.78, blue: 0.76, alpha: alpha)
            material.emission.contents = CGColor(red: 0.03, green: 0.28, blue: 0.26, alpha: alpha)
        case .yz:
            material.diffuse.contents = CGColor(red: 0.95, green: 0.36, blue: 0.38, alpha: alpha)
            material.emission.contents = CGColor(red: 0.35, green: 0.08, blue: 0.10, alpha: alpha)
        }
        return material
    }

    private static func referencePlaneOutlineMaterial(selected: Bool, hovered: Bool) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        let alpha: CGFloat = selected ? 0.92 : (hovered ? 0.72 : 0.38)
        material.diffuse.contents = CGColor(red: 0.80, green: 0.94, blue: 1.0, alpha: alpha)
        material.emission.contents = CGColor(red: 0.18, green: 0.44, blue: 0.62, alpha: alpha)
        return material
    }

    private static func makeReferencePlaneLabel(_ text: String, at point: DesignVector3, selected: Bool) -> SCNNode {
        let geometry = SCNText(string: text, extrusionDepth: 0.0004)
        geometry.font = NSFont.systemFont(ofSize: 1, weight: .bold)
        geometry.flatness = 0.2
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = CGColor(red: 0.88, green: 0.96, blue: 1.0, alpha: selected ? 0.95 : 0.62)
        material.emission.contents = CGColor(red: 0.20, green: 0.38, blue: 0.52, alpha: selected ? 0.70 : 0.30)
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.name = "workPlaneLabel"
        node.position = scnVector(point)
        node.scale = SCNVector3(0.035, 0.035, 0.035)
        node.renderingOrder = 1
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    private static func applyGridMode(
        _ mode: CADGridMode,
        options: DesignCanvasOptions?,
        to view: SCNView
    ) {
        guard let scene = view.scene else { return }
        let root = scene.rootNode
        let showGrid = options?.showGrid ?? true

        switch mode {
        case .worldXZ:
            rebuildWorldGrid(gridStepMeters: options?.gridStepMeters ?? DesignCanvasOptions().gridStepMeters, in: view)
            root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = !showGrid
            root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = true
        case let .sketchPlane(reference):
            rebuildSketchGrid(
                reference: reference,
                gridStepMeters: options?.gridStepMeters ?? DesignCanvasOptions().gridStepMeters,
                in: view
            )
            root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = !showGrid
            root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = true
        case .hidden:
            root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = true
            root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = true
        }
    }

    private static func applyAxesMode(
        _ mode: CADAxesMode,
        options: DesignCanvasOptions?,
        to view: SCNView
    ) {
        ensureWorldAxes(in: view)
        ensurePlaneAxes(in: view)
        guard let root = view.scene?.rootNode else { return }
        let showAxes = options?.showAxes ?? true
        let worldAxes = root.childNode(withName: CADSceneRootName.worldAxes, recursively: false)
        let planeAxes = root.childNode(withName: CADSceneRootName.planeAxes, recursively: false)

        switch mode {
        case .world3D:
            worldAxes?.isHidden = !showAxes
            planeAxes?.isHidden = true
            if let worldAxes {
                applyAxisVisibility(for: .iso, to: worldAxes)
            }
        case let .plane2D(reference):
            worldAxes?.isHidden = true
            planeAxes?.isHidden = !showAxes
            if let planeAxes {
                applyAxisVisibility(for: cameraMode(for: reference.plane), to: planeAxes)
            }
        case .hidden:
            worldAxes?.isHidden = true
            planeAxes?.isHidden = true
        }
    }

    private static func applyPlaneOverlay(
        for gridMode: CADGridMode,
        options: DesignCanvasOptions?,
        to view: SCNView
    ) {
        switch gridMode {
        case let .sketchPlane(reference):
            updateActivePlaneOverlay(
                reference: reference,
                emphasized: false,
                visible: options?.showActivePlaneOverlay ?? true,
                in: view
            )
        case .worldXZ, .hidden:
            view.scene?.rootNode.childNode(
                withName: CADSceneRootName.activePlaneOverlay,
                recursively: false
            )?.removeFromParentNode()
        }
    }

    private static func restoreAssetLayerVisibility(
        options: DesignCanvasOptions?,
        to view: SCNView
    ) {
        guard let container = view.scene?.rootNode.childNode(
            withName: CADSceneRootName.assets,
            recursively: false
        ) else { return }
        container.isHidden = false
        for assetNode in container.childNodes {
            assetNode.isHidden = false
            for child in assetNode.childNodes where child.name?.hasPrefix("ap_") == true {
                child.isHidden = options.map { !$0.showAttachmentPoints } ?? child.isHidden
            }
        }
    }

    static func applyActiveSketchPlane(
        plane: SketchPlane,
        offsetMeters: Double,
        emphasized: Bool,
        to view: SCNView
    ) {
        updateActivePlaneOverlay(
            reference: .canonicalPlane(plane, offsetMeters: offsetMeters),
            emphasized: emphasized,
            visible: true,
            in: view
        )
        rebuildGrid(
            reference: .canonicalPlane(plane, offsetMeters: offsetMeters),
            gridStepMeters: DesignCanvasOptions().gridStepMeters,
            in: view
        )
    }

    private static func updateActivePlaneOverlay(
        reference: SketchReference,
        emphasized: Bool,
        visible: Bool,
        in view: SCNView
    ) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.activePlaneOverlay, recursively: false)?.removeFromParentNode()
        guard visible else { return }

        let size = emphasized ? 1.4 : 1.1
        let geometry = planeQuadGeometry(
            reference: reference,
            halfSize: size / 2,
            normalOffsetMeters: CADSketchVisualLayer.overlay
        )
        let material = SCNMaterial()
        material.isDoubleSided = true
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.diffuse.contents = CGColor(red: 0.16, green: 0.62, blue: 0.92, alpha: emphasized ? 0.16 : 0.08)
        material.emission.contents = CGColor(red: 0.06, green: 0.25, blue: 0.34, alpha: emphasized ? 0.20 : 0.10)
        geometry.firstMaterial = material

        let node = SCNNode(geometry: geometry)
        node.name = CADSceneRootName.activePlaneOverlay
        node.renderingOrder = -20

        scene.rootNode.addChildNode(node)
    }

    static func rebuildGrid(
        reference: SketchReference,
        gridStepMeters: Double,
        in view: SCNView
    ) {
        rebuildSketchGrid(reference: reference, gridStepMeters: gridStepMeters, in: view)
    }

    private static func rebuildSketchGrid(
        reference: SketchReference,
        gridStepMeters: Double,
        in view: SCNView
    ) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.removeFromParentNode()
        let container = buildGrid(
            for: reference,
            rootName: CADSceneRootName.sketchGrid,
            normalOffsetMeters: CADSketchVisualLayer.grid,
            gridStepMeters: gridStepMeters
        )
        scene.rootNode.addChildNode(container)
    }

    private static func rebuildWorldGrid(gridStepMeters: Double, in view: SCNView) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.removeFromParentNode()
        let container = buildGrid(
            for: .canonicalPlane(.xz, offsetMeters: 0),
            rootName: CADSceneRootName.worldGrid,
            normalOffsetMeters: CADSketchVisualLayer.grid,
            gridStepMeters: gridStepMeters
        )
        scene.rootNode.addChildNode(container)
    }

    static func applyAxisVisibility(
        for mode: CADCameraMode,
        in view: SCNView,
        rootName: String = CADSceneRootName.worldAxes
    ) {
        guard let axesNode = view.scene?.rootNode.childNode(withName: rootName, recursively: false) else { return }
        applyAxisVisibility(for: mode, to: axesNode)
    }

    private static func applyAxisVisibility(for mode: CADCameraMode, to axesNode: SCNNode) {
        let axisX = axesNode.childNode(withName: "axis_x", recursively: false)
        let axisY = axesNode.childNode(withName: "axis_y", recursively: false)
        let axisZ = axesNode.childNode(withName: "axis_z", recursively: false)

        switch mode {
        case .iso, .fit:
            axisX?.isHidden = false; axisY?.isHidden = false; axisZ?.isHidden = false
            axisX?.opacity = 1.0; axisY?.opacity = 1.0; axisZ?.opacity = 1.0
        case .top:   // XZ view — show X, Z; dim Y
            axisX?.isHidden = false; axisY?.isHidden = true; axisZ?.isHidden = false
            axisX?.opacity = 1.0; axisY?.opacity = 0; axisZ?.opacity = 1.0
        case .front: // XY view — show X, Y; dim Z
            axisX?.isHidden = false; axisY?.isHidden = false; axisZ?.isHidden = true
            axisX?.opacity = 1.0; axisY?.opacity = 1.0; axisZ?.opacity = 0
        case .side:  // YZ view — show Y, Z; dim X
            axisX?.isHidden = true; axisY?.isHidden = false; axisZ?.isHidden = false
            axisX?.opacity = 0; axisY?.opacity = 1.0; axisZ?.opacity = 1.0
        }
    }

    private static func updateVisibleGrid(for state: DesignViewportState, in view: SCNView) {
        guard let scene = view.scene else { return }
        let root = scene.rootNode

        if state.viewMode == .free3D, (state.orientation == .iso || state.orientation == .fit) {
            rebuildWorldGrid(gridStepMeters: state.gridStepMeters, in: view)
            root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = !state.showGrid
            root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = true
            return
        }

        let reference: SketchReference
        if state.viewMode == .free3D {
            reference = referenceForCameraMode(state.orientation, offsetMeters: state.activePlaneOffsetMeters)
        } else {
            reference = state.activeReference
        }
        rebuildSketchGrid(
            reference: reference,
            gridStepMeters: state.gridStepMeters,
            in: view
        )
        root.childNode(withName: CADSceneRootName.sketchGrid, recursively: false)?.isHidden = !state.showGrid
        root.childNode(withName: CADSceneRootName.worldGrid, recursively: false)?.isHidden = true
    }

    private static func updateVisibleAxes(for state: DesignViewportState, in view: SCNView) {
        ensureWorldAxes(in: view)
        ensurePlaneAxes(in: view)
        guard let root = view.scene?.rootNode else { return }
        let worldAxes = root.childNode(withName: CADSceneRootName.worldAxes, recursively: false)
        let planeAxes = root.childNode(withName: CADSceneRootName.planeAxes, recursively: false)

        if state.viewMode == .free3D, (state.orientation == .iso || state.orientation == .fit) {
            planeAxes?.isHidden = true
            worldAxes?.isHidden = !state.showAxes
            if let worldAxes {
                applyAxisVisibility(for: state.orientation, to: worldAxes)
            }
            return
        }

        let reference: SketchReference
        if state.viewMode == .free3D {
            reference = referenceForCameraMode(state.orientation, offsetMeters: state.activePlaneOffsetMeters)
        } else {
            reference = state.activeReference
        }
        worldAxes?.isHidden = true
        planeAxes?.isHidden = !state.showAxes
        if let planeAxes {
            applyAxisVisibility(for: cameraMode(for: reference.plane), to: planeAxes)
        }
    }

    // MARK: Phantom Line

    static func updatePhantomLine(from start: DesignVector3, to end: DesignVector3, in view: SCNView) {
        updatePhantomPath(points: [start, end], closed: false, in: view)
    }

    static func updatePhantomPath(points: [DesignVector3], closed: Bool, in view: SCNView) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.phantomLine, recursively: false)?.removeFromParentNode()
        guard points.count >= 2 else { return }

        let container = SCNNode()
        container.name = CADSceneRootName.phantomLine
        let segmentCount = closed ? points.count : points.count - 1
        for index in 0..<segmentCount {
            let next = (index + 1) % points.count
            addPhantomSegment(from: points[index], to: points[next], to: container)
        }

        if let start = points.first {
            let startMat = SCNMaterial(); startMat.lightingModel = .constant
            startMat.writesToDepthBuffer = false
            startMat.readsFromDepthBuffer = false
            startMat.diffuse.contents = CGColor(red: 0.35, green: 1.0, blue: 0.35, alpha: 1.0)
            let startSph = SCNSphere(radius: 0.007); startSph.segmentCount = 10; startSph.firstMaterial = startMat
            let startNode = SCNNode(geometry: startSph)
            startNode.renderingOrder = 26
            startNode.position = SCNVector3(Float(start.x), Float(start.y), Float(start.z))
            container.addChildNode(startNode)
        }

        if let end = points.last {
            let endMat = SCNMaterial(); endMat.lightingModel = .constant
            endMat.writesToDepthBuffer = false
            endMat.readsFromDepthBuffer = false
            endMat.diffuse.contents = CGColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 1.0)
            let endSph = SCNSphere(radius: 0.006); endSph.segmentCount = 10; endSph.firstMaterial = endMat
            let endNode = SCNNode(geometry: endSph)
            endNode.renderingOrder = 26
            endNode.position = SCNVector3(Float(end.x), Float(end.y), Float(end.z))
            container.addChildNode(endNode)
        }

        scene.rootNode.addChildNode(container)
    }

    private static func addPhantomSegment(from start: DesignVector3, to end: DesignVector3, to container: SCNNode) {
        let sx = Float(start.x); let sy = Float(start.y); let sz = Float(start.z)
        let ex = Float(end.x);   let ey = Float(end.y);   let ez = Float(end.z)
        let delta = SIMD3<Float>(ex - sx, ey - sy, ez - sz)
        let length = simd_length(delta)
        guard length > 0.0005 else { return }

        let cyl = SCNCylinder(radius: 0.002, height: CGFloat(length))
        cyl.radialSegmentCount = 8
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents  = CGColor(red: 1.0, green: 0.62, blue: 0.10, alpha: 0.92)
        mat.emission.contents = CGColor(red: 0.5,  green: 0.28, blue: 0.04, alpha: 0.70)
        cyl.firstMaterial = mat
        let lineNode = SCNNode(geometry: cyl)
        lineNode.renderingOrder = 25
        lineNode.position = SCNVector3((sx + ex) / 2, (sy + ey) / 2, (sz + ez) / 2)
        lineNode.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
        container.addChildNode(lineNode)
    }

    static func removePhantomLine(from view: SCNView) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.phantomLine, recursively: false)?.removeFromParentNode()
    }

    // MARK: Cursor Marker

    static func updateCursorMarker(at point: DesignVector3, in view: SCNView) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.cursorMarker, recursively: false)?.removeFromParentNode()
        guard let scene = view.scene else { return }
        let container = SCNNode()
        container.name = CADSceneRootName.cursorMarker
        let mat = SCNMaterial(); mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.72)
        let armLen: CGFloat = 0.018
        let px = Float(point.x); let py = Float(point.y); let pz = Float(point.z)
        for euler in [SCNVector3(0, 0, Float.pi / 2), SCNVector3(Float.pi / 2, 0, 0)] {
            let arm = SCNCylinder(radius: 0.0007, height: armLen)
            arm.radialSegmentCount = 6
            arm.firstMaterial = mat
            let node = SCNNode(geometry: arm)
            node.renderingOrder = 27
            node.position = SCNVector3(px, py, pz)
            node.eulerAngles = euler
            container.addChildNode(node)
        }
        let dot = SCNSphere(radius: 0.003); dot.segmentCount = 8; dot.firstMaterial = mat
        let dotNode = SCNNode(geometry: dot)
        dotNode.renderingOrder = 28
        dotNode.position = SCNVector3(px, py, pz)
        container.addChildNode(dotNode)
        scene.rootNode.addChildNode(container)
    }

    static func removeCursorMarker(from view: SCNView) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.cursorMarker, recursively: false)?.removeFromParentNode()
    }

    // MARK: Snap Marker

    static func updateSnapMarker(
        at point: DesignVector3,
        kind: CADSnapKind,
        label: String?,
        edgeStart: DesignVector3? = nil,
        edgeEnd: DesignVector3? = nil,
        in view: SCNView
    ) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.snapMarker, recursively: false)?.removeFromParentNode()
        guard let scene = view.scene else { return }

        let container = SCNNode()
        container.name = CADSceneRootName.snapMarker

        if let edgeStart, let edgeEnd {
            let highlight = makeSnapEdgeHighlight(from: edgeStart, to: edgeEnd)
            container.addChildNode(highlight)
        }

        let marker = SCNSphere(radius: snapMarkerRadius(for: kind))
        marker.segmentCount = 12
        marker.firstMaterial = snapMarkerMaterial(for: kind)
        let markerNode = SCNNode(geometry: marker)
        markerNode.name = "snapMarker:\(kind.rawValue)"
        markerNode.renderingOrder = 30
        markerNode.position = SCNVector3(Float(point.x), Float(point.y), Float(point.z))
        container.addChildNode(markerNode)

        if let label, !label.isEmpty {
            let text = SCNText(string: label, extrusionDepth: 0.0002)
            text.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
            text.flatness = 0.3
            text.alignmentMode = CATextLayerAlignmentMode.center.rawValue
            text.firstMaterial = snapLabelMaterial()
            let textNode = SCNNode(geometry: text)
            textNode.name = "snapLabel:\(kind.rawValue)"
            textNode.renderingOrder = 31
            textNode.position = SCNVector3(Float(point.x + 0.012), Float(point.y + 0.012), Float(point.z + 0.012))
            textNode.scale = SCNVector3(0.0012, 0.0012, 0.0012)
            let billboard = SCNBillboardConstraint()
            billboard.freeAxes = .all
            textNode.constraints = [billboard]
            container.addChildNode(textNode)
        }

        scene.rootNode.addChildNode(container)
    }

    static func removeSnapMarker(from view: SCNView) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.snapMarker, recursively: false)?.removeFromParentNode()
    }

    private static func makeSnapEdgeHighlight(from start: DesignVector3, to end: DesignVector3) -> SCNNode {
        let sx = Float(start.x), sy = Float(start.y), sz = Float(start.z)
        let ex = Float(end.x), ey = Float(end.y), ez = Float(end.z)
        let delta = SIMD3<Float>(ex - sx, ey - sy, ez - sz)
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }

        let cyl = SCNCylinder(radius: 0.003, height: CGFloat(length))
        cyl.radialSegmentCount = 8
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents = CGColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 0.90)
        mat.emission.contents = CGColor(red: 0.25, green: 0.35, blue: 0.52, alpha: 0.60)
        cyl.firstMaterial = mat

        let node = SCNNode(geometry: cyl)
        node.name = "snapEdgeHighlight"
        node.renderingOrder = 29
        node.position = SCNVector3((sx + ex) / 2, (sy + ey) / 2, (sz + ez) / 2)
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
        return node
    }

    private static func snapMarkerRadius(for kind: CADSnapKind) -> CGFloat {
        switch kind {
        case .bodyVertex, .edgeMidpoint:
            return 0.007
        case .bodyEdge:
            return 0.006
        case .sketchVertex:
            return 0.0065
        case .activeCircleCenter:
            return 0.007
        case .grid:
            return 0.004
        case .constructionVertex, .constructionIntersection:
            return 0.006
        case .constructionLine:
            return 0.005
        case .referenceSketchVertex, .referenceSketchEdgeMidpoint:
            return 0.006
        case .projectedSketchVertex, .projectedSketchEdgeMidpoint:
            return 0.005
        }
    }

    private static func snapMarkerMaterial(for kind: CADSnapKind) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        let color: CGColor
        switch kind {
        case .sketchVertex:
            color = CGColor(red: 0.52, green: 0.92, blue: 1.0, alpha: 1.0)
        case .bodyVertex:
            color = CGColor(red: 1.0, green: 0.78, blue: 0.55, alpha: 1.0)
        case .bodyEdge:
            color = CGColor(red: 0.95, green: 0.95, blue: 0.88, alpha: 1.0)
        case .edgeMidpoint:
            color = CGColor(red: 0.48, green: 1.0, blue: 0.48, alpha: 1.0)
        case .grid:
            color = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.72)
        case .activeCircleCenter:
            color = CGColor(red: 0.52, green: 1.0, blue: 0.78, alpha: 1.0)
        case .constructionVertex:
            color = CGColor(red: 0.85, green: 0.48, blue: 1.0, alpha: 1.0)
        case .constructionLine:
            color = CGColor(red: 0.70, green: 0.36, blue: 1.0, alpha: 0.90)
        case .constructionIntersection:
            color = CGColor(red: 1.0, green: 0.36, blue: 0.85, alpha: 1.0)
        case .referenceSketchVertex, .referenceSketchEdgeMidpoint:
            color = CGColor(red: 0.52, green: 0.78, blue: 1.0, alpha: 0.85)
        case .projectedSketchVertex, .projectedSketchEdgeMidpoint:
            color = CGColor(red: 0.60, green: 0.88, blue: 0.72, alpha: 0.80)
        }
        material.diffuse.contents = color
        material.emission.contents = color
        return material
    }

    private static func snapLabelMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = false
        material.diffuse.contents = CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 0.92)
        material.emission.contents = CGColor(red: 0.7, green: 0.78, blue: 0.9, alpha: 0.70)
        return material
    }

    // MARK: Dimension Annotations

    static func updateDimensionAnnotations(
        sketch: DesignSketch,
        reference: SketchReference,
        in view: SCNView
    ) {
        guard let scene = view.scene else { return }
        scene.rootNode.childNode(withName: CADSceneRootName.dimensionOverlay, recursively: false)?.removeFromParentNode()
        guard !sketch.dimensions.isEmpty else { return }

        let container = SCNNode()
        container.name = CADSceneRootName.dimensionOverlay

        for dim in sketch.dimensions {
            guard let annotationNode = makeDimensionAnnotation(dim, sketch: sketch, reference: reference) else { continue }
            container.addChildNode(annotationNode)
        }

        scene.rootNode.addChildNode(container)
    }

    static func removeDimensionAnnotations(from view: SCNView) {
        view.scene?.rootNode.childNode(withName: CADSceneRootName.dimensionOverlay, recursively: false)?.removeFromParentNode()
    }

    private static func makeDimensionAnnotation(
        _ dim: SketchDimension,
        sketch: DesignSketch,
        reference: SketchReference
    ) -> SCNNode? {
        guard let (text, anchor, leaderEnd) = dimensionAnnotationContent(dim, sketch: sketch, reference: reference) else { return nil }

        let group = SCNNode()
        group.name = "dim_\(dim.id.uuidString)"

        // Leader line from geometry to label
        let leaderNode = makeLeaderLine(from: leaderEnd, to: anchor)
        leaderNode.renderingOrder = 15
        group.addChildNode(leaderNode)

        // Text label
        let textGeo = SCNText(string: text, extrusionDepth: 0.0002)
        textGeo.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        textGeo.flatness = 0.25
        textGeo.firstMaterial = dimensionTextMaterial()
        let textNode = SCNNode(geometry: textGeo)
        textNode.name = "dimLabel"
        textNode.renderingOrder = 16
        textNode.scale = SCNVector3(0.0013, 0.0013, 0.0013)
        textNode.position = SCNVector3(Float(anchor.x), Float(anchor.y), Float(anchor.z))
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        textNode.constraints = [billboard]
        group.addChildNode(textNode)

        return group
    }

    private static func dimensionAnnotationContent(
        _ dim: SketchDimension,
        sketch: DesignSketch,
        reference: SketchReference
    ) -> (text: String, anchor: DesignVector3, leaderEnd: DesignVector3)? {
        let normalOff = CADSketchVisualLayer.points + 0.001

        switch dim.kind {
        case .lineLength, .lineAngle, .horizontalDistance, .verticalDistance:
            guard let line = sketch.lines.first(where: { $0.id == dim.lineID }) else { return nil }
            let mid2D = SketchPoint2D(u: (line.start.u + line.end.u) / 2, v: (line.start.v + line.end.v) / 2)
            let midWorld = offsetWorldPoint(mid2D, reference: reference, normalOffsetMeters: normalOff)
            let offsetWorld = offsetWorldPoint(
                SketchPoint2D(u: mid2D.u + dim.displayOffset.u, v: mid2D.v + dim.displayOffset.v),
                reference: reference,
                normalOffsetMeters: normalOff
            )
            let value: Double
            let textStr: String
            switch dim.kind {
            case .lineLength:
                value = line.lengthMeters
                textStr = String(format: "%.1f mm", value * 1000)
            case .lineAngle:
                value = line.angleDegrees
                textStr = String(format: "%.1f°", value)
            case .horizontalDistance:
                value = abs(line.end.u - line.start.u)
                textStr = String(format: "%.1f mm", value * 1000)
            case .verticalDistance:
                value = abs(line.end.v - line.start.v)
                textStr = String(format: "%.1f mm", value * 1000)
            default:
                return nil
            }
            return (textStr, offsetWorld, midWorld)

        case .rectangleWidth, .rectangleHeight:
            guard let entity = sketch.entities.first(where: { $0.id == dim.lineID }),
                  case let .rectangle(rect) = entity else { return nil }
            let corners = rect.corners
            guard corners.count == 4 else { return nil }
            let mid2D: SketchPoint2D
            let value: Double
            let textStr: String
            if dim.kind == .rectangleWidth {
                mid2D = SketchPoint2D(u: (corners[0].u + corners[1].u) / 2, v: (corners[0].v + corners[1].v) / 2)
                value = abs(corners[1].u - corners[0].u)
                textStr = String(format: "%.1f mm", value * 1000)
            } else {
                mid2D = SketchPoint2D(u: (corners[1].u + corners[2].u) / 2, v: (corners[1].v + corners[2].v) / 2)
                value = abs(corners[2].v - corners[1].v)
                textStr = String(format: "%.1f mm", value * 1000)
            }
            let midWorld = offsetWorldPoint(mid2D, reference: reference, normalOffsetMeters: normalOff)
            let offsetWorld = offsetWorldPoint(
                SketchPoint2D(u: mid2D.u + dim.displayOffset.u, v: mid2D.v + dim.displayOffset.v),
                reference: reference,
                normalOffsetMeters: normalOff
            )
            return (textStr, offsetWorld, midWorld)

        case .circleRadius, .circleDiameter:
            guard let entity = sketch.entities.first(where: { $0.id == dim.lineID }),
                  case let .circle(circle) = entity else { return nil }
            let midWorld = offsetWorldPoint(circle.center, reference: reference, normalOffsetMeters: normalOff)
            let offsetWorld = offsetWorldPoint(
                SketchPoint2D(u: circle.center.u + dim.displayOffset.u, v: circle.center.v + dim.displayOffset.v),
                reference: reference,
                normalOffsetMeters: normalOff
            )
            if dim.kind == .circleRadius {
                return (String(format: "R%.1f mm", circle.radiusMeters * 1000), offsetWorld, midWorld)
            } else {
                return (String(format: "⌀%.1f mm", circle.radiusMeters * 2000), offsetWorld, midWorld)
            }
        }
    }

    private static func makeLeaderLine(from start: DesignVector3, to end: DesignVector3) -> SCNNode {
        let sx = Float(start.x), sy = Float(start.y), sz = Float(start.z)
        let ex = Float(end.x), ey = Float(end.y), ez = Float(end.z)
        let delta = SIMD3<Float>(ex - sx, ey - sy, ez - sz)
        let length = simd_length(delta)
        guard length > 0.0001 else { return SCNNode() }

        let cyl = SCNCylinder(radius: 0.0015, height: CGFloat(length))
        cyl.radialSegmentCount = 6
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents = CGColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 0.80)
        mat.emission.contents = CGColor(red: 0.18, green: 0.25, blue: 0.38, alpha: 0.55)
        cyl.firstMaterial = mat

        let node = SCNNode(geometry: cyl)
        node.name = "dimLeader"
        node.position = SCNVector3((sx + ex) / 2, (sy + ey) / 2, (sz + ez) / 2)
        node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(delta))
        return node
    }

    private static func dimensionTextMaterial() -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        mat.diffuse.contents = CGColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 0.95)
        mat.emission.contents = CGColor(red: 0.22, green: 0.32, blue: 0.48, alpha: 0.65)
        return mat
    }

    // MARK: Camera safety

    private static func applyCameraPreset(
        _ preset: CADCameraPreset,
        focus: (center: SCNVector3, radius: Float),
        to view: SCNView
    ) {
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return }

        let safeCenter = safeCameraCenter(focus.center)
        let safeRadius = safeCameraRadius(focus.radius)
        let direction = preset.cameraDirection.normalized(fallback: .zAxis)
        let up = preset.upVector.normalized(fallback: .yAxis)
        let distance = max(Double(safeRadius) * 4.2, 2.0)
        let positionVector = DesignVector3(
            x: Double(safeCenter.x) + direction.x * distance,
            y: Double(safeCenter.y) + direction.y * distance,
            z: Double(safeCenter.z) + direction.z * distance
        )
        let position = SCNVector3(
            Float(positionVector.x),
            Float(positionVector.y),
            Float(positionVector.z)
        )
        let target = SCNVector3(
            Float(safeCenter.x),
            Float(safeCenter.y),
            Float(safeCenter.z)
        )
        let orthographicScale = Double(min(max(safeRadius * 2.7, 0.8), 20.0))
        let previousScale = camera.orthographicScale

        // Disable camera control before touching camera node — prevents the controller
        // from fighting position changes during the transition from sketch2D pan mode.
        view.allowsCameraControl = false
        view.defaultCameraController.stopInertia()
        cameraNode.removeAllActions()

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        camera.usesOrthographicProjection = preset.useOrthographic
        camera.orthographicScale = orthographicScale
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = max(200.0, distance + Double(safeRadius) * 8.0)
        camera.automaticallyAdjustsZRange = false
        cameraNode.position = position
        cameraNode.look(
            at: target,
            up: SCNVector3(Float(up.x), Float(up.y), Float(up.z)),
            localFront: SCNVector3(0, 0, -1)
        )
        SCNTransaction.commit()

        // Update controller state after transaction — must be outside so it takes the new
        // camera position as the controller's base state, not the previous pan/sketch state.
        view.defaultCameraController.interactionMode = preset.allowOrbit ? .orbitTurntable : .pan
        view.defaultCameraController.target = target
        view.defaultCameraController.pointOfView = cameraNode
        view.pointOfView = cameraNode
        view.defaultCameraController.stopInertia()
        view.allowsCameraControl = preset.allowOrbit || preset.allowPan || preset.allowZoom
        CADViewportDebug.log("Camera changed by command. Old scale: \(previousScale), new scale: \(orthographicScale)")
    }

    // MARK: Camera Recovery

    /// Resets the camera to a safe position that frames scene content.
    /// Called when the camera ends up in an invalid or blank-screen state after a view transition.
    static func recoverViewportCamera(
        in view: SCNView,
        document: DesignDocument,
        reason: String = "unknown"
    ) {
        CADViewportDebug.log("Camera recovery triggered: \(reason)")
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return }

        // Pick the best content to frame: all valid assets, or origin if nothing available.
        let validAssets = document.assets.filter { isValidAssetForCamera($0) }
        let sphere: (center: SCNVector3, radius: Float)
        if validAssets.isEmpty {
            sphere = (SCNVector3(0, 0, 0), 0.7)
        } else {
            sphere = boundingSphere(for: validAssets)
        }

        let safeCenter = safeCameraCenter(sphere.center)
        let safeRadius = safeCameraRadius(sphere.radius)
        let distance = max(Double(safeRadius) * 4.2, 2.0)
        let direction = simd_normalize(SIMD3<Float>(1, 1, 1))
        let position = SCNVector3(
            Float(safeCenter.x) + direction.x * Float(distance),
            Float(safeCenter.y) + direction.y * Float(distance),
            Float(safeCenter.z) + direction.z * Float(distance)
        )

        view.allowsCameraControl = false
        view.defaultCameraController.stopInertia()
        cameraNode.removeAllActions()

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(min(max(safeRadius * 2.7, 0.8), 20.0))
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = max(200.0, distance + Double(safeRadius) * 8.0)
        camera.automaticallyAdjustsZRange = false
        cameraNode.position = position
        cameraNode.look(at: safeCenter)
        SCNTransaction.commit()

        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = safeCenter
        view.defaultCameraController.pointOfView = cameraNode
        view.pointOfView = cameraNode
        view.defaultCameraController.stopInertia()
        view.allowsCameraControl = true

        // Restore scene visibility in case something was hidden.
        restoreCADLayerVisibilityForIso(canvasOptions: nil, to: view)
        CADViewportDebug.log("Camera recovery complete: center=\(safeCenter), radius=\(safeRadius)")
    }

    /// Calls recoverViewportCamera only when the camera is currently invalid.
    static func recoverIfCameraInvalid(in view: SCNView, document: DesignDocument) {
        if !isCameraValid(in: view) {
            recoverViewportCamera(in: view, document: document, reason: "post-command validation")
        }
    }

    private static func isCameraValid(in view: SCNView) -> Bool {
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return false }
        let p = cameraNode.position
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return false }
        guard abs(p.x) < 10_000, abs(p.y) < 10_000, abs(p.z) < 10_000 else { return false }
        guard camera.orthographicScale > 0, camera.orthographicScale.isFinite else { return false }
        guard camera.zNear < camera.zFar else { return false }
        return true
    }

    private static func applyIsoCamera(
        to view: SCNView,
        center: SCNVector3,
        radius: Float,
        animated: Bool
    ) {
        guard let cameraNode = view.scene?.rootNode.childNode(withName: "previewCamera", recursively: false),
              let camera = cameraNode.camera else { return }

        let safeCenter = safeCameraCenter(center)
        let safeRadius = safeCameraRadius(radius)
        let direction = simd_normalize(SIMD3<Float>(1.0, 1.0, 1.0))
        let distance: Float = max(safeRadius * 4.2, 2.0)
        let centerX = Float(safeCenter.x)
        let centerY = Float(safeCenter.y)
        let centerZ = Float(safeCenter.z)
        let positionX: Float = centerX + direction.x * distance
        let positionY: Float = centerY + direction.y * distance
        let positionZ: Float = centerZ + direction.z * distance
        let position = SCNVector3(positionX, positionY, positionZ)
        let orthographicScale = Double(min(max(safeRadius * 2.7, 0.8), 20.0))

        // Disable control before camera move to prevent controller fighting the transition.
        view.allowsCameraControl = false
        view.defaultCameraController.stopInertia()
        cameraNode.removeAllActions()

        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.25 : 0
        camera.usesOrthographicProjection = true
        camera.orthographicScale = orthographicScale
        camera.fieldOfView = 45
        camera.zNear = 0.001
        camera.zFar = Double(max(Float(200.0), distance + safeRadius * 8.0))
        camera.automaticallyAdjustsZRange = false
        cameraNode.position = position
        cameraNode.look(at: safeCenter)
        SCNTransaction.commit()

        // Wire controller AFTER transaction so it sees the new camera position as its base.
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = safeCenter
        view.pointOfView = cameraNode
        view.defaultCameraController.pointOfView = cameraNode
        view.defaultCameraController.stopInertia()
        view.allowsCameraControl = true
    }

    private static func safeCameraCenter(_ center: SCNVector3) -> SCNVector3 {
        guard center.x.isFinite,
              center.y.isFinite,
              center.z.isFinite,
              abs(center.x) < 10_000,
              abs(center.y) < 10_000,
              abs(center.z) < 10_000 else {
            return SCNVector3(0, 0, 0)
        }
        return center
    }

    private static func safeCameraRadius(_ radius: Float) -> Float {
        guard radius.isFinite, radius > 0, radius < 10_000 else { return 0.7 }
        return max(radius, 0.15)
    }

    // MARK: Bounding sphere

    private static func boundingSphere(for assets: [DesignAsset]) -> (center: SCNVector3, radius: Float) {
        let validAssets = assets.filter { isValidAssetForCamera($0) }
        guard !validAssets.isEmpty else {
            return (SCNVector3(0, 0, 0), 0.7)
        }
        var minX = Float.infinity, minY = Float.infinity, minZ = Float.infinity
        var maxX = -Float.infinity, maxY = -Float.infinity, maxZ = -Float.infinity

        for asset in validAssets {
            let scale = Float(max(0.01, min(asset.transform.scale, 100.0)))
            let bw = Float(asset.massProperties.boundingWidth  / 2) * scale
            let bh = Float(asset.massProperties.boundingHeight / 2) * scale
            let bd = Float(asset.massProperties.boundingDepth  / 2) * scale
            // Use center-of-mass (world space for extruded/sketch) + transform offset
            let px = Float(asset.massProperties.centerOfMassX + asset.transform.positionX)
            let py = Float(asset.massProperties.centerOfMassY + asset.transform.positionY)
            let pz = Float(asset.massProperties.centerOfMassZ + asset.transform.positionZ)
            minX = min(minX, px - bw); maxX = max(maxX, px + bw)
            minY = min(minY, py - bh); maxY = max(maxY, py + bh)
            minZ = min(minZ, pz - bd); maxZ = max(maxZ, pz + bd)
        }

        guard minX.isFinite, maxX.isFinite, minY.isFinite, maxY.isFinite, minZ.isFinite, maxZ.isFinite else {
            return (SCNVector3(0, 0, 0), 0.7)
        }
        guard minX <= maxX, minY <= maxY, minZ <= maxZ else {
            return (SCNVector3(0, 0, 0), 0.7)
        }

        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2
        let cz = (minZ + maxZ) / 2
        let radius = max(
            (maxX - minX) / 2,
            (maxY - minY) / 2,
            (maxZ - minZ) / 2,
            0.15
        )
        return (safeCameraCenter(SCNVector3(cx, cy, cz)), safeCameraRadius(radius))
    }

    private static func isValidAssetForCamera(_ asset: DesignAsset) -> Bool {
        // Empty sketches have centroid at origin and no real geometry —
        // including them drags the bounding sphere toward origin regardless of where solids are.
        if case let .sketch2D(params) = asset.kind, !params.sketch.hasGeometry {
            return false
        }
        let mp = asset.massProperties
        let transform = asset.transform
        let positionIsFinite = transform.positionX.isFinite
            && transform.positionY.isFinite
            && transform.positionZ.isFinite
            && abs(transform.positionX) < 10_000
            && abs(transform.positionY) < 10_000
            && abs(transform.positionZ) < 10_000
        let scaleIsFinite = transform.scale.isFinite
            && transform.scale > 0
            && transform.scale < 1_000
        return mp.boundingWidth.isFinite && mp.boundingWidth > 0
            && mp.boundingHeight.isFinite && mp.boundingHeight > 0
            && mp.boundingDepth.isFinite && mp.boundingDepth > 0
            && mp.boundingWidth < 10_000
            && mp.boundingHeight < 10_000
            && mp.boundingDepth < 10_000
            && mp.centerOfMassX.isFinite
            && mp.centerOfMassY.isFinite
            && mp.centerOfMassZ.isFinite
            && abs(mp.centerOfMassX) < 10_000
            && abs(mp.centerOfMassY) < 10_000
            && abs(mp.centerOfMassZ) < 10_000
            && positionIsFinite
            && scaleIsFinite
    }

    // MARK: Private helpers

    private static func cameraMode(for plane: SketchPlane) -> CADCameraMode {
        switch plane {
        case .xy: return .front
        case .xz: return .top
        case .yz: return .side
        }
    }

    private static func sketchCameraTarget(
        for reference: SketchReference,
        sceneCenter: SCNVector3,
        referenceOrigin: DesignVector3
    ) -> DesignVector3 {
        let center = DesignVector3(
            x: Double(sceneCenter.x),
            y: Double(sceneCenter.y),
            z: Double(sceneCenter.z)
        )
        switch reference {
        case .canonicalPlane:
            let axes = axesForSketchReference(reference)
            let projected = worldPointToSketch(center, reference: reference)
            return referenceOrigin + axes.u * projected.u + axes.v * projected.v
        case let .planarFace(face):
            // Use the face's geometric center so the camera frames the whole face,
            // not just the first vertex (corner) which is face.origin.
            return face.faceCenter
        }
    }

    private static func setCameraBasis(
        _ cameraNode: SCNNode,
        position: DesignVector3,
        xAxis: DesignVector3,
        yAxis: DesignVector3,
        zAxis: DesignVector3
    ) {
        let x = xAxis.normalized(fallback: .xAxis)
        let y = yAxis.normalized(fallback: .yAxis)
        let z = zAxis.normalized(fallback: .zAxis)
        cameraNode.simdTransform = simd_float4x4(
            SIMD4<Float>(Float(x.x), Float(x.y), Float(x.z), 0),
            SIMD4<Float>(Float(y.x), Float(y.y), Float(y.z), 0),
            SIMD4<Float>(Float(z.x), Float(z.y), Float(z.z), 0),
            SIMD4<Float>(Float(position.x), Float(position.y), Float(position.z), 1)
        )
    }

    private static func planeQuadGeometry(
        reference: SketchReference,
        halfSize: Double,
        normalOffsetMeters: Double
    ) -> SCNGeometry {
        // For face references, center the overlay quad on the face's geometric center
        // rather than its anchor vertex (face.origin), so the overlay visually frames the face.
        let quadCenter: DesignVector3
        if case let .planarFace(face) = reference {
            quadCenter = face.faceCenter
        } else {
            quadCenter = originForSketchReference(reference)
        }
        let origin = quadCenter + normalVector(for: reference) * normalOffsetMeters
        let axes = axesForSketchReference(reference)
        let corners = [
            origin + axes.u * -halfSize + axes.v * -halfSize,
            origin + axes.u *  halfSize + axes.v * -halfSize,
            origin + axes.u *  halfSize + axes.v *  halfSize,
            origin + axes.u * -halfSize + axes.v *  halfSize,
        ]
        let vertices = corners.map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        return SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
    }

    private static func addLighting(to scene: SCNScene) {
        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 350
        ambientLight.color = CGColor(red: 0.95, green: 0.97, blue: 1.0, alpha: 1.0)
        ambient.light = ambientLight
        scene.rootNode.addChildNode(ambient)

        let dirNode = SCNNode()
        let dirLight = SCNLight()
        dirLight.type = .directional
        dirLight.intensity = 850
        dirLight.castsShadow = false
        dirLight.color = CGColor(red: 1.0, green: 0.98, blue: 0.93, alpha: 1.0)
        dirNode.light = dirLight
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 6, 0)
        scene.rootNode.addChildNode(dirNode)

        let fillNode = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 300
        fillLight.color = CGColor(red: 0.7, green: 0.8, blue: 1.0, alpha: 1.0)
        fillNode.light = fillLight
        fillNode.eulerAngles = SCNVector3(Float.pi / 6, -Float.pi * 0.7, 0)
        scene.rootNode.addChildNode(fillNode)
    }

    private static func addWorldGrid(to scene: SCNScene) {
        let container = buildGrid(
            for: .canonicalPlane(.xz, offsetMeters: 0),
            rootName: CADSceneRootName.worldGrid,
            normalOffsetMeters: CADSketchVisualLayer.grid,
            gridStepMeters: DesignCanvasOptions().gridStepMeters
        )
        scene.rootNode.addChildNode(container)
    }

    // Build a grid node for the given sketch plane at the given offset.
    // Grid lines use writesToDepthBuffer=false + renderingOrder=-5 to avoid z-fighting.
    static func buildGrid(
        for reference: SketchReference,
        rootName: String,
        normalOffsetMeters: Double,
        gridStepMeters: Double
    ) -> SCNNode {
        let container = SCNNode()
        container.name = rootName

        let extent = 5.0
        let minor = min(max(gridStepMeters, 0.005), 1.0)
        let majorEvery = 10

        let majorMat = gridMaterial(alpha: 0.60, bright: true)
        let minorMat = gridMaterial(alpha: 0.25, bright: false)

        let steps = max(1, Int((extent * 2 / minor).rounded()))
        let origin = originForSketchReference(reference) + normalVector(for: reference) * normalOffsetMeters
        let axes = axesForSketchReference(reference)
        for index in 0...steps {
            let coord = -extent + Double(index) * minor
            let isMajor = index % majorEvery == 0
            let mat = isMajor ? majorMat : minorMat
            let a1 = origin + axes.u * coord + axes.v * -extent
            let b1 = origin + axes.u * coord + axes.v *  extent
            let a2 = origin + axes.u * -extent + axes.v * coord
            let b2 = origin + axes.u *  extent + axes.v * coord
            addGridLine(from: scnVector(a1), to: scnVector(b1), material: mat, container: container)
            addGridLine(from: scnVector(a2), to: scnVector(b2), material: mat, container: container)
        }

        return container
    }

    private static func scnVector(_ vector: DesignVector3) -> SCNVector3 {
        SCNVector3(Float(vector.x), Float(vector.y), Float(vector.z))
    }

    private static func gridMaterial(alpha: CGFloat, bright: Bool) -> SCNMaterial {
        let mat = SCNMaterial()
        let v: CGFloat = bright ? 0.50 : 0.32
        mat.diffuse.contents = CGColor(red: v, green: v + 0.05, blue: v + 0.10, alpha: alpha)
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.readsFromDepthBuffer = false
        return mat
    }

    private static func addGridLine(from a: SCNVector3, to b: SCNVector3,
                                    material: SCNMaterial, container: SCNNode) {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let dz = b.z - a.z
        let length = sqrt(dx*dx + dy*dy + dz*dz)
        guard length > 0.001 else { return }

        let cyl = SCNCylinder(radius: 0.0006, height: CGFloat(length))
        cyl.firstMaterial = material
        cyl.radialSegmentCount = 4

        let node = SCNNode(geometry: cyl)
        node.renderingOrder = -5
        node.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        node.simdOrientation = simd_quatf(
            from: SIMD3<Float>(0, 1, 0),
            to: simd_normalize(SIMD3<Float>(Float(dx), Float(dy), Float(dz)))
        )
        container.addChildNode(node)
    }

    private static func addWorldAxes(to scene: SCNScene) {
        let container = buildAxes(rootName: CADSceneRootName.worldAxes)
        scene.rootNode.addChildNode(container)
    }

    private static func addPlaneAxes(to scene: SCNScene) {
        let container = buildAxes(rootName: CADSceneRootName.planeAxes)
        container.isHidden = true
        scene.rootNode.addChildNode(container)
    }

    private static func ensureWorldAxes(in view: SCNView) {
        guard let scene = view.scene else { return }
        if scene.rootNode.childNode(withName: CADSceneRootName.worldAxes, recursively: false) == nil {
            addWorldAxes(to: scene)
        }
    }

    private static func ensurePlaneAxes(in view: SCNView) {
        guard let scene = view.scene else { return }
        if scene.rootNode.childNode(withName: CADSceneRootName.planeAxes, recursively: false) == nil {
            addPlaneAxes(to: scene)
        }
    }

    private static func buildAxes(rootName: String) -> SCNNode {
        let container = SCNNode()
        container.name = rootName
        // Axes sit above the grid (-5) but below sketch geometry (21+).
        // readsFromDepthBuffer=false means renderingOrder is the only draw-order signal.
        container.renderingOrder = 8

        let len: Float = 0.5
        let r: CGFloat = 0.003
        let half = len / 2

        struct AxisSpec {
            let name: String
            let pos: SCNVector3
            let euler: SCNVector3
            let cr: CGFloat; let cg: CGFloat; let cb: CGFloat
            let tipX: Float; let tipY: Float; let tipZ: Float
        }

        let axes: [AxisSpec] = [
            AxisSpec(name: "axis_x", pos: SCNVector3(half, 0, 0), euler: SCNVector3(0, 0, -Float.pi / 2),
                     cr: 0.92, cg: 0.22, cb: 0.20, tipX: half, tipY: 0, tipZ: 0),
            AxisSpec(name: "axis_y", pos: SCNVector3(0, half, 0), euler: SCNVector3(0, 0, 0),
                     cr: 0.22, cg: 0.80, cb: 0.30, tipX: 0, tipY: half, tipZ: 0),
            AxisSpec(name: "axis_z", pos: SCNVector3(0, 0, half), euler: SCNVector3(Float.pi / 2, 0, 0),
                     cr: 0.22, cg: 0.48, cb: 1.00, tipX: 0, tipY: 0, tipZ: half),
        ]

        for ax in axes {
            let axisNode = SCNNode()
            axisNode.name = ax.name

            let color = CGColor(red: ax.cr, green: ax.cg, blue: ax.cb, alpha: 1.0)
            let mat = SCNMaterial()
            mat.diffuse.contents = color
            mat.lightingModel = .constant
            mat.writesToDepthBuffer = false
            mat.readsFromDepthBuffer = false

            let shaft = SCNCylinder(radius: r, height: CGFloat(len))
            shaft.radialSegmentCount = 8
            shaft.firstMaterial = mat
            let shaftNode = SCNNode(geometry: shaft)
            shaftNode.renderingOrder = 8
            shaftNode.position = ax.pos
            shaftNode.eulerAngles = ax.euler
            axisNode.addChildNode(shaftNode)

            let cone = SCNCone(topRadius: 0, bottomRadius: r * 2.5, height: r * 8)
            cone.radialSegmentCount = 8
            cone.firstMaterial = mat
            let coneNode = SCNNode(geometry: cone)
            coneNode.renderingOrder = 8
            coneNode.position = SCNVector3(Float(ax.pos.x) + ax.tipX,
                                           Float(ax.pos.y) + ax.tipY,
                                           Float(ax.pos.z) + ax.tipZ)
            coneNode.eulerAngles = ax.euler
            axisNode.addChildNode(coneNode)

            container.addChildNode(axisNode)
        }

        return container
    }
}
