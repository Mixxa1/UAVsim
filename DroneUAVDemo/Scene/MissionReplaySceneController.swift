import AppKit
import SceneKit
import simd

// MARK: - Onboard mount gizmo

enum ReplayGizmoToolKind {
    case move, rotate
}

enum ReplayGizmoAxis: CaseIterable {
    case x, y, z

    var localUnit: SIMD3<Float> {
        switch self {
        case .x: return SIMD3<Float>(1, 0, 0)
        case .y: return SIMD3<Float>(0, 1, 0)
        case .z: return SIMD3<Float>(0, 0, 1)
        }
    }

    func nodeName(for kind: ReplayGizmoToolKind) -> String {
        let suffix: String
        switch self {
        case .x: suffix = "X"
        case .y: suffix = "Y"
        case .z: suffix = "Z"
        }
        switch kind {
        case .move: return "replayGizmoMove\(suffix)"
        case .rotate: return "replayGizmoRotate\(suffix)"
        }
    }

    static func matching(nodeName name: String?, kind: ReplayGizmoToolKind) -> ReplayGizmoAxis? {
        allCases.first { $0.nodeName(for: kind) == name }
    }
}

// MARK: - Reconstruction status

struct ReplayReconstructionStatus {
    enum Quality: String {
        case full
        case partial
        case fallback

        var titleKey: String {
            "replay.quality.\(rawValue)"
        }
    }

    var uavDisplayName: String
    var terrainDisplayName: String
    var weatherDisplayName: String
    var payloadDisplayName: String
    var quality: Quality
    var hasContext: Bool
    var profileFound: Bool
    var warningMessages: [String]

    static let none = ReplayReconstructionStatus(
        uavDisplayName: L10n.s("replay.uav.generic", language: L10n.currentLanguage()),
        terrainDisplayName: L10n.s("common.na", language: L10n.currentLanguage()),
        weatherDisplayName: L10n.s("common.na", language: L10n.currentLanguage()),
        payloadDisplayName: L10n.s("replay.payload.none", language: L10n.currentLanguage()),
        quality: .fallback,
        hasContext: false,
        profileFound: false,
        warningMessages: []
    )
}

struct MissionReplayExportRenderOptions: Equatable {
    var mode: ReplayVideoExportMode
    var showPathTrail: Bool
    var showEventMarkers: Bool
    var showOverlay: Bool
    var environmentQuality: EnvironmentVisualQuality
    var enableShadows: Bool
    var enableAntialiasing: Bool

    static func options(for settings: ReplayVideoExportSettings) -> MissionReplayExportRenderOptions {
        let clamped = settings.clamped
        switch clamped.exportMode {
        case .fast:
            return MissionReplayExportRenderOptions(
                mode: .fast,
                showPathTrail: false,
                showEventMarkers: false,
                showOverlay: false,
                environmentQuality: .simplified,
                enableShadows: false,
                enableAntialiasing: false
            )
        case .quality:
            return MissionReplayExportRenderOptions(
                mode: .quality,
                showPathTrail: clamped.includePathTrail,
                showEventMarkers: clamped.includeEventMarkers,
                showOverlay: clamped.includeOverlay,
                environmentQuality: .detailed,
                enableShadows: true,
                enableAntialiasing: true
            )
        }
    }
}

// MARK: - Controller

final class MissionReplaySceneController {
    private enum CinematicShotKind {
        case establishing
        case sideTracking
        case closeFollow
        case overheadReveal
        case eventContext
    }

    let scene: SCNScene
    let cameraNode: SCNNode
    private(set) var cameraMode: ReplayCameraMode = .freeObserver

    private let replayDroneNode: SCNNode
    private let groundNode: SCNNode
    private let pathNode: SCNNode
    private let eventMarkersNode: SCNNode
    private let environmentNode: SCNNode
    private let skyCloudsNode: SCNNode
    private let weatherEnvelopeNode: SCNNode
    private let abandonedCitySceneComposer = AbandonedCitySceneComposer()
    private var activeWeatherPreset: WeatherPreset = .normal

    private static let skyCloudInstanceRadius: Float = 180
    private static let skyCloudAltitudeAboveDrone: Float = 90
    private static let weatherEnvelopeRadius: Float = 250.0
    // Mid-range stand-in for the live sim's `0.25 + intensity * 0.55` envelope opacity —
    // MissionReplayContextSnapshot only captures which weather preset was recorded, not the
    // intensity/wind values, so the exact recorded strength can't be reconstructed.
    private static let weatherEnvelopeReplayOpacity: CGFloat = 0.55
    private static let skyCloudInstanceOffsets: [(SCNVector3, Float)] = [
        (SCNVector3(0, 0, 500), 0),
        (SCNVector3(420, 15, -380), 1.1),
        (SCNVector3(-480, -10, 300), 2.6),
        (SCNVector3(350, 20, 420), 4.0),
        (SCNVector3(-520, 5, -280), 5.4)
    ]

    var wantsWeatherDepthOfField: Bool {
        activeWeatherPreset == .fog || activeWeatherPreset == .smog
    }

    private var orbitYawRadians: Float = 0
    private var orbitPitchRadians: Float = -0.35
    private var orbitDistance: Float = 14
    private var chaseDistance: Float = 14
    private var chaseHeight: Float = 5
    private var chaseSmoothPos: SIMD3<Float>?
    private var chaseSmoothTarget: SIMD3<Float>?
    private var cinematicSmoothPos: SIMD3<Float>?
    private var cinematicSmoothTarget: SIMD3<Float>?
    private var smoothedScrollDelta: Float = 0
    private(set) var topDownHeight: Float = 120

    // Separate orbit tunables from `.orbit` mode's — zooming in close (down to a few cm) to
    // precisely place the gizmo on a small drone shouldn't leave `.orbit` mode unexpectedly
    // zoomed in too when the user switches away.
    private var mountEditYawRadians: Float = 0.6
    private var mountEditPitchRadians: Float = -0.25
    private var mountEditDistance: Float = 1.6
    private(set) var onboardMountIsEditing: Bool = true
    private(set) var onboardMountOffset: SIMD3<Float> = MissionReplaySceneController.loadPersistedOnboardMountOffset()
    private(set) var onboardMountRotation: simd_quatf = MissionReplaySceneController.loadPersistedOnboardMountRotation()
    private var onboardMountGizmoNode: SCNNode?
    private var moveHandlesNode: SCNNode?
    private var rotateHandlesNode: SCNNode?
    private var eyePupilNode: SCNNode?
    private var onboardMountBodyScale: Float = 0.3
    private var activeGizmoAxis: ReplayGizmoAxis?
    private var activeGizmoHandleKind: ReplayGizmoToolKind?

    static let defaultOnboardMountOffset = SIMD3<Float>(0, 0.15, -0.25)
    private static let onboardMountOffsetLimit: Float = 2.5
    private static let onboardMountOffsetDefaultsKeyPrefix = "replay.onboardMountOffset.v1"
    private static let onboardMountRotationDefaultsKeyPrefix = "replay.onboardMountRotation.v1"

    private static func gizmoHandleLength(forBodyScale scale: Float) -> Float {
        max(0.12, min(0.6, scale * 0.9))
    }

    private static func gizmoRotateRingRadius(forBodyScale scale: Float) -> Float {
        gizmoHandleLength(forBodyScale: scale) * 1.6
    }

    private static func gizmoEyeRadius(forBodyScale scale: Float) -> Float {
        gizmoHandleLength(forBodyScale: scale) * 0.12 * 1.6
    }

    /// Moves the eye's pupil to the point on the eyeball's surface facing the current look
    /// direction — the eyeball itself is rigidly attached to the drone via normal scene-graph
    /// parenting, so only the *extra* onboardMountRotation needs accounting for here.
    private func updateEyePupil(rotation: simd_quatf) {
        guard let pupilNode = eyePupilNode else { return }
        let eyeRadius = Self.gizmoEyeRadius(forBodyScale: onboardMountBodyScale)
        let forward = rotation.act(SIMD3<Float>(0, 0, -1))
        pupilNode.simdPosition = forward * (eyeRadius * 0.78)
    }

    private var lastKnownFrame: MissionReplayFrame?
    private var loadedFrames: [MissionReplayFrame] = []
    private var loadedEvents: [MissionReplayEvent] = []
    private var loadedContext: MissionReplayContextSnapshot?
    private var selectedReplayEvent: MissionReplayEvent?

    private(set) var reconstructionStatus: ReplayReconstructionStatus = .none

    private static func loadPersistedOnboardMountOffset() -> SIMD3<Float> {
        let defaults = UserDefaults.standard
        let key = onboardMountOffsetDefaultsKeyPrefix
        guard defaults.object(forKey: "\(key).x") != nil else {
            return defaultOnboardMountOffset
        }
        return SIMD3<Float>(
            Float(defaults.double(forKey: "\(key).x")),
            Float(defaults.double(forKey: "\(key).y")),
            Float(defaults.double(forKey: "\(key).z"))
        )
    }

    private func persistOnboardMountOffset() {
        let defaults = UserDefaults.standard
        let key = Self.onboardMountOffsetDefaultsKeyPrefix
        defaults.set(Double(onboardMountOffset.x), forKey: "\(key).x")
        defaults.set(Double(onboardMountOffset.y), forKey: "\(key).y")
        defaults.set(Double(onboardMountOffset.z), forKey: "\(key).z")
    }

    private static func loadPersistedOnboardMountRotation() -> simd_quatf {
        let defaults = UserDefaults.standard
        let key = onboardMountRotationDefaultsKeyPrefix
        guard defaults.object(forKey: "\(key).w") != nil else {
            return simd_quatf(real: 1, imag: .zero)
        }
        return simd_quatf(
            real: Float(defaults.double(forKey: "\(key).w")),
            imag: SIMD3<Float>(
                Float(defaults.double(forKey: "\(key).x")),
                Float(defaults.double(forKey: "\(key).y")),
                Float(defaults.double(forKey: "\(key).z"))
            )
        )
    }

    private func persistOnboardMountRotation() {
        let defaults = UserDefaults.standard
        let key = Self.onboardMountRotationDefaultsKeyPrefix
        defaults.set(Double(onboardMountRotation.imag.x), forKey: "\(key).x")
        defaults.set(Double(onboardMountRotation.imag.y), forKey: "\(key).y")
        defaults.set(Double(onboardMountRotation.imag.z), forKey: "\(key).z")
        defaults.set(Double(onboardMountRotation.real), forKey: "\(key).w")
    }

    init() {
        scene = SCNScene()
        cameraNode = SCNNode()
        replayDroneNode = SCNNode()
        groundNode = SCNNode()
        pathNode = SCNNode()
        eventMarkersNode = SCNNode()
        environmentNode = SCNNode()
        skyCloudsNode = SCNNode()
        weatherEnvelopeNode = SCNNode()
        buildScene()
    }

    // MARK: - Session loading

    func loadSession(_ session: MissionReplaySession, events: [MissionReplayEvent] = []) {
        pathNode.childNodes.forEach { $0.removeFromParentNode() }
        eventMarkersNode.childNodes.forEach { $0.removeFromParentNode() }
        environmentNode.childNodes.forEach { $0.removeFromParentNode() }

        let context = session.context
        loadedContext = context

        let uavResult = buildReplayUAV(context: context)
        if uavResult.bodyScale != onboardMountBodyScale {
            onboardMountBodyScale = uavResult.bodyScale
            rebuildGizmoHandles(bodyScale: uavResult.bodyScale)
        }
        let envResult = buildReplayEnvironment(from: context)

        let sorted = session.frames.sorted { $0.timestamp < $1.timestamp }
        loadedFrames = sorted
        loadedEvents = events
        buildPathTrail(from: sorted)
        buildEventMarkers(events: events, frames: sorted)

        let overallQuality: ReplayReconstructionStatus.Quality
        if uavResult.profileFound && envResult.hasEnvironment {
            overallQuality = .full
        } else if uavResult.profileFound || envResult.hasEnvironment {
            overallQuality = .partial
        } else {
            overallQuality = .fallback
        }

        let language = L10n.currentLanguage()
        var warnings: [String] = []
        if context == nil {
            warnings.append(L10n.s("replay.warning.no_context", language: language))
        }
        if !uavResult.profileFound {
            warnings.append(L10n.s("replay.warning.uav_not_found", language: language))
        }

        let terrainDisplayName: String
        if let preset = envResult.terrainPreset, let mapScale = envResult.mapScale {
            terrainDisplayName = "\(L10n.s(preset.titleKey, language: language)) / \(L10n.s(mapScale.titleKey, language: language))"
        } else {
            terrainDisplayName = L10n.s("common.na", language: language)
        }

        let weatherDisplayName = context?.weatherPresetRawValue
            .flatMap(WeatherPreset.init(rawValue:))
            .map { L10n.s($0.titleKey, language: language) }
            ?? L10n.s("common.na", language: language)

        reconstructionStatus = ReplayReconstructionStatus(
            uavDisplayName: uavResult.displayName,
            terrainDisplayName: terrainDisplayName,
            weatherDisplayName: weatherDisplayName,
            payloadDisplayName: context?.payloadResolvedName ?? L10n.s("replay.payload.none", language: language),
            quality: overallQuality,
            hasContext: context != nil,
            profileFound: uavResult.profileFound,
            warningMessages: warnings
        )

        chaseSmoothPos = nil
        chaseSmoothTarget = nil
        cinematicSmoothPos = nil
        cinematicSmoothTarget = nil

        if let first = sorted.first {
            let fx = Float(first.position.x)
            let fy = Float(first.position.y)
            let fz = Float(first.position.z)
            cameraNode.simdPosition = SIMD3<Float>(fx, fy + 10, fz + 25)
            cameraNode.eulerAngles = SCNVector3(-0.36, 0, 0)
        } else {
            resetCameraToDefault()
        }

        lastKnownFrame = sorted.first
        update(frame: sorted.first)
    }

    // MARK: - Camera mode

    func setCameraMode(_ mode: ReplayCameraMode) {
        cameraMode = mode
        chaseSmoothPos = nil
        chaseSmoothTarget = nil
        cinematicSmoothPos = nil
        cinematicSmoothTarget = nil
        smoothedScrollDelta = 0
        activeGizmoAxis = nil
        activeGizmoHandleKind = nil
        if mode == .onboardMount {
            onboardMountIsEditing = true
        }
        // The directional sun light's shadow map is sized/projected to cover the whole
        // kilometer-scale scene (ground + environment), so its effective resolution at the
        // centimeter scale of this drone's own fuselage/wing is far too coarse for clean
        // self-shadowing — the wing box intersects the fuselage capsule right at body-center,
        // and the shadow that intersection casts on itself comes out as blocky, unstable "shadow
        // acne" that's invisible from any previous camera distance but fills a large fraction of
        // frame at onboard-mount range, and visibly swims frame to frame (matches "large,
        // irregular, moves on its own" reports). Only the aircraft's own self-shadow is at issue —
        // disable it just for this mode; every other mode keeps the existing look untouched.
        setDroneSelfShadowing(enabled: mode != .onboardMount)
        updateGizmoVisibility()
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    private func setDroneSelfShadowing(enabled: Bool) {
        // Sweeps the gizmo's nodes too, harmlessly — it's hidden outside onboard-mount edit and
        // a hidden node never casts a shadow regardless of this flag.
        replayDroneNode.enumerateChildNodes { node, _ in
            node.castsShadow = enabled
        }
    }

    func setTopDownHeight(_ height: Float) {
        topDownHeight = max(30, min(400, height))
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    // MARK: - Onboard mount gizmo control

    func setOnboardMountEditing(_ editing: Bool) {
        onboardMountIsEditing = editing
        activeGizmoAxis = nil
        activeGizmoHandleKind = nil
        updateGizmoVisibility()
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    private func updateGizmoVisibility() {
        // Move arrows and rotate rings are both shown together (no separate tool-mode toggle) —
        // grab whichever handle you want, the hit node's own name tells beginGizmoDrag which kind
        // of drag math to use.
        let showGizmo = cameraMode == .onboardMount && onboardMountIsEditing
        onboardMountGizmoNode?.isHidden = !showGizmo
        moveHandlesNode?.isHidden = !showGizmo
        rotateHandlesNode?.isHidden = !showGizmo
    }

    func setOnboardMountOffset(_ offset: SIMD3<Float>) {
        let limit = Self.onboardMountOffsetLimit
        let clamped = SIMD3<Float>(
            max(-limit, min(limit, offset.x)),
            max(-limit, min(limit, offset.y)),
            max(-limit, min(limit, offset.z))
        )
        onboardMountOffset = clamped
        onboardMountGizmoNode?.simdPosition = clamped
        persistOnboardMountOffset()
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    func setOnboardMountRotation(_ rotation: simd_quatf) {
        let normalized = simd_normalize(rotation)
        onboardMountRotation = normalized
        rotateHandlesNode?.simdOrientation = normalized
        updateEyePupil(rotation: normalized)
        persistOnboardMountRotation()
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    func resetOnboardMountOffset() {
        setOnboardMountOffset(Self.defaultOnboardMountOffset)
        setOnboardMountRotation(simd_quatf(real: 1, imag: .zero))
    }

    /// Whether the view should route the next drag to gizmo-axis hit-testing instead of
    /// normal camera-drag handling.
    var canInteractWithGizmo: Bool {
        cameraMode == .onboardMount && onboardMountIsEditing
    }

    var isDraggingGizmoAxis: Bool { activeGizmoAxis != nil }

    func beginGizmoDrag(axis: ReplayGizmoAxis, kind: ReplayGizmoToolKind) {
        activeGizmoAxis = axis
        activeGizmoHandleKind = kind
    }

    func endGizmoDrag() {
        activeGizmoAxis = nil
        activeGizmoHandleKind = nil
    }

    /// World-space origin + unit direction of the axis/tangent currently being dragged, recomputed
    /// live since the drone (and so the gizmo, which is its child) can be rotating during playback.
    /// For `.move` this is the axis itself; for `.rotate` it's the screen-facing tangent at the
    /// ring (the direction "around the ring" closest to the camera), since rotation handles are
    /// dragged tangentially rather than straight along a line.
    func gizmoAxisWorldRay() -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let axis = activeGizmoAxis, let kind = activeGizmoHandleKind,
              let gizmoNode = onboardMountGizmoNode else { return nil }
        let origin = gizmoNode.simdWorldPosition
        switch kind {
        case .move:
            let direction = replayDroneNode.simdOrientation.act(axis.localUnit)
            return (origin, direction)
        case .rotate:
            let axisWorldDir = replayDroneNode.simdOrientation.act(onboardMountRotation.act(axis.localUnit))
            let toCamera = cameraNode.simdPosition - origin
            let toCameraLength = simd_length(toCamera)
            guard toCameraLength > 0.0001 else { return nil }
            let tangent = simd_cross(axisWorldDir, toCamera / toCameraLength)
            let tangentLength = simd_length(tangent)
            guard tangentLength > 0.0001 else { return nil }
            return (origin, tangent / tangentLength)
        }
    }

    func applyGizmoDrag(incrementalAxisDelta: Float) {
        guard let axis = activeGizmoAxis, let kind = activeGizmoHandleKind else { return }
        switch kind {
        case .move:
            var newOffset = onboardMountOffset
            switch axis {
            case .x: newOffset.x += incrementalAxisDelta
            case .y: newOffset.y += incrementalAxisDelta
            case .z: newOffset.z += incrementalAxisDelta
            }
            setOnboardMountOffset(newOffset)
        case .rotate:
            // incrementalAxisDelta is an arc length (axisDelta's "direction" was a tangent unit
            // vector here, not the rotation axis) — divide by the ring's radius to recover radians.
            let radius = Self.gizmoRotateRingRadius(forBodyScale: onboardMountBodyScale)
            let angle = incrementalAxisDelta / radius
            let increment = simd_quatf(angle: angle, axis: axis.localUnit)
            // Composed on the right (gimbal-local), matching the rings tracking the *current*
            // accumulated rotation visually — each drag rotates relative to where it's currently
            // aimed, like a camera gimbal, not relative to the drone's original fixed body axes.
            setOnboardMountRotation(onboardMountRotation * increment)
        }
    }

    func setSelectedEvent(_ event: MissionReplayEvent?) {
        selectedReplayEvent = event
        cinematicSmoothPos = nil
        cinematicSmoothTarget = nil
        if cameraMode == .cinematicEvent || cameraMode == .payloadFollow {
            updateCameraForCurrentMode(frame: lastKnownFrame)
        }
    }

    var hasPayloadCameraTarget: Bool {
        payloadFocusPosition(for: lastKnownFrame) != nil
    }

    var payloadCameraStatusText: String? {
        guard loadedEvents.contains(where: { $0.type == .payloadReleased || $0.type == .payloadImpact }) else {
            return L10n.s("replay.payload_camera.unavailable_no_events", language: L10n.currentLanguage())
        }
        return L10n.s("replay.payload_camera.unavailable_fallback", language: L10n.currentLanguage())
    }

    func prepareForVideoExport(_ options: MissionReplayExportRenderOptions) {
        scene.isPaused = true
        cameraNode.camera?.wantsHDR = false
        cameraNode.camera?.motionBlurIntensity = 0
        if !environmentNode.childNodes.isEmpty {
            rebuildReplayEnvironment(quality: options.environmentQuality)
        }
        environmentNode.isHidden = false
        pathNode.isHidden = !options.showPathTrail
        eventMarkersNode.isHidden = !options.showEventMarkers
        configureExportShadowCasting(enabled: options.enableShadows)
        configureOverlayNode(pathNode)
        configureOverlayNode(eventMarkersNode)
    }

    func updateCameraForCurrentMode(
        frame: MissionReplayFrame?,
        replayTime: TimeInterval? = nil,
        duration: TimeInterval? = nil
    ) {
        guard let frame else { return }
        let cameraReplayTime = replayTime ?? frame.timestamp
        let replayDuration = max(0.001, duration ?? loadedFrames.last?.timestamp ?? frame.timestamp)
        let dronePos = replayDroneNode.simdPosition
        switch cameraMode {
        case .freeObserver:
            break
        case .chase:
            let yaw = Float(frame.attitude.yawRadians)
            let forward = SIMD3<Float>(sin(yaw), 0, -cos(yaw))
            let desired = dronePos - forward * chaseDistance + SIMD3<Float>(0, chaseHeight, 0)
            let desiredTarget = dronePos + SIMD3<Float>(0, 0.45, 0)
            if chaseSmoothPos == nil { chaseSmoothPos = desired }
            if chaseSmoothTarget == nil { chaseSmoothTarget = desiredTarget }
            chaseSmoothPos = chaseSmoothPos! + (desired - chaseSmoothPos!) * 0.08
            chaseSmoothTarget = chaseSmoothTarget! + (desiredTarget - chaseSmoothTarget!) * 0.10
            cameraNode.simdPosition = chaseSmoothPos!
            lookAtWithLockedHorizon(chaseSmoothTarget!)
        case .orbit:
            let offset = SIMD3<Float>(
                orbitDistance * cos(orbitPitchRadians) * sin(orbitYawRadians),
                orbitDistance * sin(-orbitPitchRadians),
                orbitDistance * cos(orbitPitchRadians) * cos(orbitYawRadians)
            )
            cameraNode.simdPosition = dronePos + offset
            lookAtWithLockedHorizon(dronePos)
        case .topDown:
            cameraNode.simdPosition = SIMD3<Float>(dronePos.x, dronePos.y + topDownHeight, dronePos.z)
            lookAtWithLockedHorizon(dronePos)
        case .fpvApproximation:
            let forward = replayDroneNode.simdOrientation.act(SIMD3<Float>(0, 0, -1))
            let up = replayDroneNode.simdOrientation.act(SIMD3<Float>(0, 1, 0))
            cameraNode.simdPosition = dronePos + forward * 1.0 + up * 0.35
            cameraNode.simdOrientation = replayDroneNode.simdOrientation
        case .onboardMount:
            if onboardMountIsEditing {
                // External view so the gizmo (attached to the drone, at the configured offset)
                // stays visible and draggable — can't see/drag a gizmo marking your own camera's
                // position from inside that same camera.
                updateMountEditCamera(around: dronePos)
            } else {
                let offset = replayDroneNode.simdOrientation.act(onboardMountOffset)
                cameraNode.simdPosition = dronePos + offset
                cameraNode.simdOrientation = replayDroneNode.simdOrientation * onboardMountRotation
            }
        case .payloadFollow:
            guard let target = payloadFocusPosition(for: frame) else {
                updateOrbitCamera(around: dronePos)
                return
            }
            updateSmoothEventCamera(around: target, frame: frame, distance: 16, height: 5)
        case .cinematicEvent:
            updateCinematicCamera(
                frame: frame,
                replayTime: cameraReplayTime,
                duration: replayDuration,
                selectedEvent: selectedReplayEvent
            )
        }
    }

    func jumpCameraToFrame(_ frame: MissionReplayFrame?) {
        guard let frame else { return }
        let fx = Float(frame.position.x)
        let fy = Float(frame.position.y)
        let fz = Float(frame.position.z)
        replayDroneNode.simdPosition = SIMD3<Float>(fx, fy, fz)
        let yaw   = simd_quatf(angle: Float(frame.attitude.yawRadians),   axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: Float(frame.attitude.pitchRadians), axis: SIMD3<Float>(1, 0, 0))
        let roll  = simd_quatf(angle: Float(frame.attitude.rollRadians),  axis: SIMD3<Float>(0, 0, 1))
        replayDroneNode.simdOrientation = yaw * pitch * roll
        lastKnownFrame = frame
        chaseSmoothPos = nil
        chaseSmoothTarget = nil
        cinematicSmoothPos = nil
        cinematicSmoothTarget = nil

        if cameraMode == .freeObserver {
            cameraNode.simdPosition = SIMD3<Float>(fx, fy + 10, fz + 25)
            cameraNode.eulerAngles = SCNVector3(-0.36, 0, 0)
        } else {
            updateCameraForCurrentMode(frame: frame)
        }
    }

    func handleDragInput(dx: Float, dy: Float) {
        switch cameraMode {
        case .freeObserver:
            rotateCamera(yawDelta: dx * 0.005, pitchDelta: dy * 0.005)
        case .orbit:
            orbitYawRadians += dx * 0.005
            orbitPitchRadians = max(-1.2, min(0.6, orbitPitchRadians - dy * 0.005))
            updateCameraForCurrentMode(frame: lastKnownFrame)
        case .onboardMount:
            // Dragging a gizmo handle is routed by the view straight to applyGizmoDrag(...)
            // instead of here — this only runs for drags that didn't hit a handle.
            guard onboardMountIsEditing else { return }
            mountEditYawRadians += dx * 0.005
            mountEditPitchRadians = max(-1.2, min(0.6, mountEditPitchRadians - dy * 0.005))
            updateCameraForCurrentMode(frame: lastKnownFrame)
        default:
            break
        }
    }

    func handleScrollInput(delta: Float) {
        let clamped = max(-0.4, min(0.4, delta))
        guard abs(clamped) >= 0.002 else { return }
        smoothedScrollDelta = smoothedScrollDelta * 0.60 + clamped * 0.40
        let scroll = smoothedScrollDelta

        switch cameraMode {
        case .freeObserver:
            zoomCamera(scroll * 10.0)
        case .orbit:
            orbitDistance = max(4, min(80, orbitDistance - scroll * 6.0))
        case .topDown:
            setTopDownHeight(topDownHeight - scroll * 40.0)
            return
        case .chase:
            chaseDistance = max(6, min(40, chaseDistance - scroll * 6.0))
        case .payloadFollow, .cinematicEvent:
            orbitDistance = max(6, min(80, orbitDistance - scroll * 6.0))
        case .onboardMount:
            guard onboardMountIsEditing else { return }
            // Much tighter range than `.orbit` — the gizmo sits directly on a drone body that
            // may only be tens of centimeters across, so precise placement needs to zoom in far
            // closer than viewing the whole scene ever does.
            mountEditDistance = max(0.3, min(20, mountEditDistance - scroll * 2.0))
        default:
            break
        }
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    // MARK: - Per-frame update

    func update(frame: MissionReplayFrame?) {
        update(frame: frame, replayTime: nil, duration: nil)
    }

    func update(
        frame: MissionReplayFrame?,
        replayTime: TimeInterval?,
        duration: TimeInterval?
    ) {
        guard let frame else { return }
        lastKnownFrame = frame
        replayDroneNode.simdPosition = SIMD3<Float>(
            Float(frame.position.x),
            Float(frame.position.y),
            Float(frame.position.z)
        )
        let yaw   = simd_quatf(angle: Float(frame.attitude.yawRadians),   axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: Float(frame.attitude.pitchRadians), axis: SIMD3<Float>(1, 0, 0))
        let roll  = simd_quatf(angle: Float(frame.attitude.rollRadians),  axis: SIMD3<Float>(0, 0, 1))
        replayDroneNode.simdOrientation = yaw * pitch * roll

        skyCloudsNode.simdPosition = SIMD3<Float>(
            replayDroneNode.simdPosition.x,
            replayDroneNode.simdPosition.y + Self.skyCloudAltitudeAboveDrone,
            replayDroneNode.simdPosition.z
        )
        if !weatherEnvelopeNode.isHidden {
            weatherEnvelopeNode.simdPosition = replayDroneNode.simdPosition
        }

        updateCameraForCurrentMode(frame: frame, replayTime: replayTime, duration: duration)
    }

    func resetCameraToDefault() {
        cameraNode.simdPosition = SIMD3<Float>(0, 10, 25)
        cameraNode.eulerAngles = SCNVector3(-0.36, 0, 0)
    }

    // MARK: - Observer camera control (fullscreen WASD)

    private var freeObserverYaw:   Float = 0
    private var freeObserverPitch: Float = -0.36

    /// Move observer camera along its local axes.  localDelta is in camera-local space (X right, Y up, Z back).
    func moveCamera(localDelta: SIMD3<Float>) {
        guard cameraMode == .freeObserver else { return }
        let m = cameraNode.simdWorldTransform
        let worldDelta = SIMD3<Float>(
            m.columns.0.x * localDelta.x + m.columns.1.x * localDelta.y + m.columns.2.x * localDelta.z,
            m.columns.0.y * localDelta.x + m.columns.1.y * localDelta.y + m.columns.2.y * localDelta.z,
            m.columns.0.z * localDelta.x + m.columns.1.z * localDelta.y + m.columns.2.z * localDelta.z
        )
        cameraNode.simdPosition += worldDelta
    }

    /// Rotate observer camera by yaw (world Y) and pitch (local X) deltas in radians.
    func rotateCamera(yawDelta: Float, pitchDelta: Float) {
        guard cameraMode == .freeObserver else { return }
        freeObserverYaw   += yawDelta
        freeObserverPitch  = max(-1.50, min(1.50, freeObserverPitch + pitchDelta))
        let yawQ   = simd_quatf(angle: freeObserverYaw,   axis: SIMD3<Float>(0, 1, 0))
        let pitchQ = simd_quatf(angle: freeObserverPitch, axis: SIMD3<Float>(1, 0, 0))
        cameraNode.simdOrientation = yawQ * pitchQ
    }

    /// Move observer camera forward/backward (positive = forward).
    func zoomCamera(_ delta: Float) {
        guard cameraMode == .freeObserver else { return }
        let m = cameraNode.simdWorldTransform
        // Camera -Z is its forward direction in world space
        let forward = SIMD3<Float>(-m.columns.2.x, -m.columns.2.y, -m.columns.2.z)
        cameraNode.simdPosition += forward * delta
    }

    /// Reset observer camera to a good vantage point near the last known frame.
    func resetCamera() {
        freeObserverYaw   = 0
        freeObserverPitch = -0.36
        if let last = lastKnownFrame {
            cameraNode.simdPosition = SIMD3<Float>(
                Float(last.position.x),
                Float(last.position.y) + 10,
                Float(last.position.z) + 25
            )
        } else {
            cameraNode.simdPosition = SIMD3<Float>(0, 10, 25)
        }
        let yawQ   = simd_quatf(angle: freeObserverYaw,   axis: SIMD3<Float>(0, 1, 0))
        let pitchQ = simd_quatf(angle: freeObserverPitch, axis: SIMD3<Float>(1, 0, 0))
        cameraNode.simdOrientation = yawQ * pitchQ
    }

    private func updateOrbitCamera(around target: SIMD3<Float>) {
        let offset = SIMD3<Float>(
            orbitDistance * cos(orbitPitchRadians) * sin(orbitYawRadians),
            orbitDistance * sin(-orbitPitchRadians),
            orbitDistance * cos(orbitPitchRadians) * cos(orbitYawRadians)
        )
        cameraNode.simdPosition = target + offset
        lookAtWithLockedHorizon(target)
    }

    private func updateMountEditCamera(around target: SIMD3<Float>) {
        let offset = SIMD3<Float>(
            mountEditDistance * cos(mountEditPitchRadians) * sin(mountEditYawRadians),
            mountEditDistance * sin(-mountEditPitchRadians),
            mountEditDistance * cos(mountEditPitchRadians) * cos(mountEditYawRadians)
        )
        cameraNode.simdPosition = target + offset
        lookAtWithLockedHorizon(target)
    }

    private func updateCinematicCamera(
        frame: MissionReplayFrame,
        replayTime: TimeInterval,
        duration: TimeInterval,
        selectedEvent: MissionReplayEvent?
    ) {
        guard let currentPosition = cinematicTarget(frame: frame, selectedEvent: selectedEvent) else {
            updateOrbitCamera(around: replayDroneNode.simdPosition)
            return
        }

        let velocity = SIMD3<Float>(
            Float(frame.velocity.x),
            Float(frame.velocity.y),
            Float(frame.velocity.z)
        )
        let forward = stableForwardDirection(frame: frame, velocity: velocity)
        let side = stableSideDirection(from: forward, replayTime: replayTime)
        let shot = cinematicShotKind(
            replayTime: replayTime,
            duration: duration,
            selectedEvent: selectedEvent,
            frame: frame
        )
        let eventTarget = relevantEventTarget(
            selectedEvent: selectedEvent,
            currentPosition: currentPosition,
            replayTime: replayTime
        )
        let resolvedShot: CinematicShotKind = (shot == .eventContext && eventTarget == nil) ? .sideTracking : shot

        let desired: (position: SIMD3<Float>, target: SIMD3<Float>, smoothing: Float)
        switch resolvedShot {
        case .establishing:
            desired = (
                currentPosition - forward * 30.0 + SIMD3<Float>(0, 14.0, 0) + side * 10.0,
                currentPosition + forward * 5.0,
                0.08
            )
        case .sideTracking:
            desired = (
                currentPosition + side * 14.0 - forward * 4.0 + SIMD3<Float>(0, 2.0, 0),
                currentPosition + forward * 4.0,
                0.12
            )
        case .closeFollow:
            desired = (
                currentPosition - forward * 8.0 + SIMD3<Float>(0, 3.0, 0) + side * 2.0,
                currentPosition + forward * 3.0,
                0.14
            )
        case .overheadReveal:
            desired = (
                currentPosition - forward * 12.0 + SIMD3<Float>(0, 25.0, 0),
                currentPosition,
                0.10
            )
        case .eventContext:
            let pointOfInterest = eventTarget ?? currentPosition
            desired = (
                currentPosition + side * 12.0 + SIMD3<Float>(0, 5.0, 0) - forward * 8.0,
                (currentPosition + pointOfInterest) * 0.5,
                0.10
            )
        }

        if cinematicSmoothPos == nil { cinematicSmoothPos = desired.position }
        if cinematicSmoothTarget == nil { cinematicSmoothTarget = desired.target }
        cinematicSmoothPos = smoothCameraPosition(current: cinematicSmoothPos!, target: desired.position, factor: desired.smoothing)
        cinematicSmoothTarget = smoothCameraPosition(current: cinematicSmoothTarget!, target: desired.target, factor: min(0.16, desired.smoothing + 0.04))
        cameraNode.simdPosition = cinematicSmoothPos!
        lookAtWithLockedHorizon(cinematicSmoothTarget!)
    }

    private func cinematicShotKind(
        replayTime: TimeInterval,
        duration: TimeInterval,
        selectedEvent: MissionReplayEvent?,
        frame: MissionReplayFrame
    ) -> CinematicShotKind {
        let normalized = duration > 0 ? replayTime / duration : 0
        if normalized <= 0.15 { return .establishing }

        if let selectedEvent, abs(selectedEvent.timestamp - replayTime) <= 6.0 {
            return .eventContext
        }

        let velocity = SIMD3<Float>(
            Float(frame.velocity.x),
            0,
            Float(frame.velocity.z)
        )
        let speed = simd_length(velocity)
        if speed < 0.45 {
            return Int(replayTime / 10.0).isMultiple(of: 2) ? .establishing : .overheadReveal
        }

        switch Int(replayTime / 10.0) % 3 {
        case 0:
            return .sideTracking
        case 1:
            return .closeFollow
        default:
            return .overheadReveal
        }
    }

    private func cinematicTarget(
        frame: MissionReplayFrame?,
        selectedEvent: MissionReplayEvent?
    ) -> SIMD3<Float>? {
        let source = frame ?? lastKnownFrame
        guard let source else { return nil }
        return SIMD3<Float>(
            Float(source.position.x),
            Float(source.position.y),
            Float(source.position.z)
        )
    }

    private func relevantEventTarget(
        selectedEvent: MissionReplayEvent?,
        currentPosition: SIMD3<Float>,
        replayTime: TimeInterval
    ) -> SIMD3<Float>? {
        guard let selectedEvent else { return nil }
        guard abs(selectedEvent.timestamp - replayTime) <= 8.0 else { return nil }
        guard let eventTarget = eventFocusPosition(selectedEvent, fallbackFrame: nil) else { return nil }
        guard simd_length(eventTarget - currentPosition) <= 120.0 else { return nil }
        return eventTarget
    }

    private func stableSideDirection(from forward: SIMD3<Float>, replayTime: TimeInterval) -> SIMD3<Float> {
        let candidate = SIMD3<Float>(forward.z, 0, -forward.x)
        let length = simd_length(candidate)
        let base = length > 0.001 ? candidate / length : SIMD3<Float>(1, 0, 0)
        let alternator: Float = Int(replayTime / 10.0).isMultiple(of: 2) ? 1 : -1
        return base * alternator
    }

    private func updateSmoothEventCamera(
        around target: SIMD3<Float>,
        frame: MissionReplayFrame,
        distance: Float,
        height: Float
    ) {
        let phase = Float(frame.timestamp) * 0.28
        let desiredTarget = target
        let desiredPosition = target + SIMD3<Float>(
            sin(phase) * distance,
            height,
            cos(phase) * distance
        )

        if cinematicSmoothPos == nil { cinematicSmoothPos = desiredPosition }
        if cinematicSmoothTarget == nil { cinematicSmoothTarget = desiredTarget }
        cinematicSmoothPos = cinematicSmoothPos! + (desiredPosition - cinematicSmoothPos!) * 0.08
        cinematicSmoothTarget = cinematicSmoothTarget! + (desiredTarget - cinematicSmoothTarget!) * 0.12
        cameraNode.simdPosition = cinematicSmoothPos!
        lookAtWithLockedHorizon(cinematicSmoothTarget!)
    }

    private func stableForwardDirection(frame: MissionReplayFrame, velocity: SIMD3<Float>) -> SIMD3<Float> {
        let horizontalVelocity = SIMD3<Float>(velocity.x, 0, velocity.z)
        let speed = simd_length(horizontalVelocity)
        if speed > 0.25 {
            return horizontalVelocity / speed
        }
        let yaw = Float(frame.attitude.yawRadians)
        return SIMD3<Float>(sin(yaw), 0, -cos(yaw))
    }

    private func smoothCameraPosition(
        current: SIMD3<Float>,
        target: SIMD3<Float>,
        factor: Float
    ) -> SIMD3<Float> {
        current + (target - current) * max(0.01, min(1.0, factor))
    }

    private func lookAtWithLockedHorizon(_ target: SIMD3<Float>) {
        lookAtWithLockedHorizon(
            camera: cameraNode,
            target: SCNVector3(target.x, target.y, target.z)
        )
    }

    private func lookAtWithLockedHorizon(camera: SCNNode, target: SCNVector3) {
        let position = camera.simdPosition
        let target = SIMD3<Float>(Float(target.x), Float(target.y), Float(target.z))
        let toTarget = target - position
        let distance = simd_length(toTarget)
        guard distance > 0.001 else { return }

        let forward = toTarget / distance
        let worldUp = SIMD3<Float>(0, 1, 0)
        let referenceUp = abs(simd_dot(forward, worldUp)) > 0.98 ? SIMD3<Float>(0, 0, -1) : worldUp
        let backward = -forward
        let right = simd_normalize(simd_cross(referenceUp, backward))
        let lockedUp = simd_normalize(simd_cross(backward, right))
        let rotation = simd_float3x3(columns: (right, lockedUp, backward))
        camera.simdOrientation = simd_quatf(rotation)
    }

    private func payloadFocusPosition(for frame: MissionReplayFrame?) -> SIMD3<Float>? {
        let payloadEvents = loadedEvents.filter { $0.type == .payloadReleased || $0.type == .payloadImpact }
        guard !payloadEvents.isEmpty else { return nil }
        let currentTime = frame?.timestamp ?? lastKnownFrame?.timestamp ?? 0
        let nearest = payloadEvents.min { lhs, rhs in
            abs(lhs.timestamp - currentTime) < abs(rhs.timestamp - currentTime)
        }
        guard let event = nearest else { return nil }
        return eventFocusPosition(event, fallbackFrame: frame)
    }

    private func eventFocusPosition(_ event: MissionReplayEvent, fallbackFrame: MissionReplayFrame?) -> SIMD3<Float>? {
        if let p = event.position {
            return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        }
        if let position = framePosition(at: event.timestamp, frames: loadedFrames) {
            return position
        }
        guard let fallbackFrame else { return nil }
        return SIMD3<Float>(
            Float(fallbackFrame.position.x),
            Float(fallbackFrame.position.y),
            Float(fallbackFrame.position.z)
        )
    }

    // MARK: - Scene construction

    private func buildScene() {
        buildGround()
        buildLights()
        buildCamera()
        pathNode.castsShadow = false
        eventMarkersNode.castsShadow = false
        skyCloudsNode.name = "replaySkyCloudsNode"
        weatherEnvelopeNode.name = "replayWeatherEnvelopeNode"
        weatherEnvelopeNode.isHidden = true
        setUpSkyClouds()
        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(environmentNode)
        scene.rootNode.addChildNode(replayDroneNode)
        scene.rootNode.addChildNode(pathNode)
        scene.rootNode.addChildNode(eventMarkersNode)
        scene.rootNode.addChildNode(skyCloudsNode)
        scene.rootNode.addChildNode(weatherEnvelopeNode)
        buildOnboardMountGizmo()
    }

    private func buildOnboardMountGizmo() {
        let root = SCNNode()
        root.name = "replayGizmoRoot"
        root.simdPosition = onboardMountOffset
        root.isHidden = true
        root.castsShadow = false
        replayDroneNode.addChildNode(root)
        onboardMountGizmoNode = root

        let moveNode = SCNNode()
        moveNode.name = "replayGizmoMoveRoot"
        moveNode.castsShadow = false
        root.addChildNode(moveNode)
        moveHandlesNode = moveNode

        let rotateNode = SCNNode()
        rotateNode.name = "replayGizmoRotateRoot"
        rotateNode.simdOrientation = onboardMountRotation
        rotateNode.isHidden = true
        rotateNode.castsShadow = false
        root.addChildNode(rotateNode)
        rotateHandlesNode = rotateNode

        rebuildGizmoHandles(bodyScale: onboardMountBodyScale)
    }

    private static func gizmoAxisColor(_ axis: ReplayGizmoAxis) -> NSColor {
        switch axis {
        case .x: return NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.22, alpha: 1.0)
        case .y: return NSColor(calibratedRed: 0.25, green: 0.92, blue: 0.30, alpha: 1.0)
        case .z: return NSColor(calibratedRed: 0.28, green: 0.55, blue: 0.98, alpha: 1.0)
        }
    }

    private static func makeOverlayMaterial(color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.55)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }

    private func rebuildGizmoHandles(bodyScale: Float) {
        guard let root = onboardMountGizmoNode, let moveNode = moveHandlesNode, let rotateNode = rotateHandlesNode else { return }
        moveNode.childNodes.forEach { $0.removeFromParentNode() }
        rotateNode.childNodes.forEach { $0.removeFromParentNode() }
        root.childNodes.filter { $0.name == "replayGizmoEyeball" }.forEach { $0.removeFromParentNode() }

        let length = Self.gizmoHandleLength(forBodyScale: bodyScale)
        let radius = length * 0.12

        for axis in ReplayGizmoAxis.allCases {
            let cylinder = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
            cylinder.materials = [Self.makeOverlayMaterial(color: Self.gizmoAxisColor(axis))]

            let handle = SCNNode(geometry: cylinder)
            handle.name = axis.nodeName(for: .move)
            handle.castsShadow = false
            handle.renderingOrder = 50
            switch axis {
            case .x:
                handle.simdPosition = SIMD3<Float>(length * 0.5, 0, 0)
                handle.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            case .y:
                handle.simdPosition = SIMD3<Float>(0, length * 0.5, 0)
            case .z:
                handle.simdPosition = SIMD3<Float>(0, 0, length * 0.5)
                handle.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            }
            moveNode.addChildNode(handle)
        }

        // Eyeball + pupil instead of a plain marker sphere — the pupil's position (set in
        // updateEyePupil, driven by onboardMountRotation) shows which way the camera is currently
        // aimed at a glance, which a uniform sphere never could regardless of the rotation rings.
        let eyeRadius = Self.gizmoEyeRadius(forBodyScale: bodyScale)
        let eyeballSphere = SCNSphere(radius: CGFloat(eyeRadius))
        eyeballSphere.materials = [Self.makeOverlayMaterial(color: NSColor(calibratedWhite: 0.95, alpha: 1.0))]
        let eyeballNode = SCNNode(geometry: eyeballSphere)
        eyeballNode.name = "replayGizmoEyeball"
        eyeballNode.castsShadow = false
        eyeballNode.renderingOrder = 50
        root.addChildNode(eyeballNode)

        let pupilSphere = SCNSphere(radius: CGFloat(eyeRadius * 0.42))
        pupilSphere.materials = [Self.makeOverlayMaterial(color: NSColor(calibratedWhite: 0.05, alpha: 1.0))]
        let pupilNode = SCNNode(geometry: pupilSphere)
        pupilNode.name = "replayGizmoEyePupil"
        pupilNode.castsShadow = false
        pupilNode.renderingOrder = 51
        eyeballNode.addChildNode(pupilNode)
        eyePupilNode = pupilNode
        updateEyePupil(rotation: onboardMountRotation)

        // Rings: a torus's own "hole" axis is local Y by default, so the Y ring needs no
        // reorientation — X and Z reuse the exact same +90°-about-Z / +90°-about-X rotations as
        // the move cylinders above, for the same reason (re-pointing a Y-aligned primitive).
        let ringRadius = Self.gizmoRotateRingRadius(forBodyScale: bodyScale)
        let pipeRadius = length * 0.05
        for axis in ReplayGizmoAxis.allCases {
            let torus = SCNTorus(ringRadius: CGFloat(ringRadius), pipeRadius: CGFloat(pipeRadius))
            torus.materials = [Self.makeOverlayMaterial(color: Self.gizmoAxisColor(axis))]

            let ring = SCNNode(geometry: torus)
            ring.name = axis.nodeName(for: .rotate)
            ring.castsShadow = false
            ring.renderingOrder = 50
            switch axis {
            case .x:
                ring.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1))
            case .y:
                break
            case .z:
                ring.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            }
            rotateNode.addChildNode(ring)
        }
    }

    private func setUpSkyClouds() {
        for (offset, yaw) in Self.skyCloudInstanceOffsets {
            guard let node = WeatherCloudAssetLoader.shared.makeSkyCloudsNode(
                offset: offset,
                yaw: yaw,
                targetRadius: Self.skyCloudInstanceRadius
            ) else {
                continue
            }
            skyCloudsNode.addChildNode(node)
        }
    }

    private func updateReplayWeatherEnvelope(_ preset: WeatherPreset) {
        weatherEnvelopeNode.childNodes.forEach { $0.removeFromParentNode() }
        let node: SCNNode?
        switch preset {
        case .fog:
            node = WeatherCloudAssetLoader.shared.makeFogEnvelopeNode(targetRadius: Self.weatherEnvelopeRadius)
        case .smog:
            node = WeatherCloudAssetLoader.shared.makeSmogEnvelopeNode(targetRadius: Self.weatherEnvelopeRadius)
        default:
            node = nil
        }
        if let node {
            weatherEnvelopeNode.addChildNode(node)
        }
        weatherEnvelopeNode.isHidden = weatherEnvelopeNode.childNodes.isEmpty
        weatherEnvelopeNode.opacity = Self.weatherEnvelopeReplayOpacity
    }

    private func configureOverlayNode(_ node: SCNNode) {
        node.castsShadow = false
        node.geometry?.materials.forEach { material in
            material.lightingModel = .constant
            material.writesToDepthBuffer = false
        }
        node.enumerateChildNodes { child, _ in
            child.castsShadow = false
            child.geometry?.materials.forEach { material in
                material.lightingModel = .constant
                material.writesToDepthBuffer = false
            }
        }
    }

    private func configureExportShadowCasting(enabled: Bool) {
        scene.rootNode.enumerateChildNodes { node, _ in
            node.castsShadow = enabled
            node.light?.castsShadow = enabled
        }
        pathNode.castsShadow = false
        eventMarkersNode.castsShadow = false
        // Sky decoration and weather haze never cast shadows in the live sim either (baked in
        // via WeatherCloudAssetLoader.sanitize()/makeEnvelopeSphere) — the blanket sweep above
        // would otherwise have these billboard cards and the fog/smog sphere throw shadows onto
        // the ground in quality-mode exports, which never happens during live play or interactive
        // replay. Recursing explicitly (not just the container node) since castsShadow isn't
        // inherited from a parent — the sweep above already flipped every descendant individually.
        for root in [skyCloudsNode, weatherEnvelopeNode] {
            root.castsShadow = false
            root.enumerateChildNodes { node, _ in node.castsShadow = false }
        }
    }

    private func buildGround() {
        let ground = SCNPlane(width: 1600, height: 1600)
        groundNode.name = "replayGround"
        groundNode.geometry = ground
        groundNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
        applyReplayTerrainVisualStyle(for: .field, halfExtent: 800)
    }

    private func buildLights() {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 380
        ambientLight.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 820
        sunLight.castsShadow = true
        sunLight.shadowMode = .deferred
        sunLight.shadowRadius = 4
        sunLight.shadowSampleCount = 4
        sunLight.color = NSColor(red: 1.0, green: 0.97, blue: 0.88, alpha: 1.0)
        let sunNode = SCNNode()
        sunNode.light = sunLight
        sunNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 5, 0)
        scene.rootNode.addChildNode(sunNode)
    }

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 68
        camera.zNear = 0.1
        camera.zFar = 4000
        camera.wantsHDR = false
        cameraNode.camera = camera
        resetCameraToDefault()
        scene.rootNode.addChildNode(cameraNode)
    }

    // MARK: - UAV visual reconstruction

    private struct UAVBuildResult {
        let displayName: String
        let profileFound: Bool
        let bodyScale: Float
    }

    /// Rebuilds an embedded Workbench assembly first, then resolves against the full canonical
    /// catalog (`LIPODroneModelRepository`) rather than a
    /// caller-supplied list — the previous version relied on whichever screen happened to open
    /// the replay viewer to thread a non-empty `availableDroneProfiles` array through, and the
    /// start-screen entry point (`ReplayCenterWindowHost.open` with no active simulation) and the
    /// video exporter (`ReplayVideoExportService`) both always passed `[]`, so real recordings of
    /// real catalog UAVs fell back to the generic placeholder even though the exact model was
    /// resolvable. Runs the recorded ID through `canonicalModelID` first so recordings saved under
    /// a since-renamed legacy model ID (see `LIPODroneModelRepository.legacyModelIDMap`) still match.
    private func buildReplayUAV(context: MissionReplayContextSnapshot?) -> UAVBuildResult {
        // The onboard-mount gizmo also lives under replayDroneNode (so it inherits the drone's
        // per-frame transform for free) — skip it here or reloading a session would silently
        // delete it along with the old visual model.
        replayDroneNode.childNodes
            .filter { $0.name != "replayGizmoRoot" }
            .forEach { $0.removeFromParentNode() }

        // Workbench profiles are intentionally not required to exist in the canonical catalog.
        // The portable build snapshot contains every selected component (including imported CAD
        // meshes), so it is the authoritative replay visual when present.
        if let workbenchBuild = context?.workbenchBuild {
            let profile = UAVBuildProfileSynthesizer.synthesizeProfile(for: workbenchBuild)
            let visual = DroneModelBuilder.build(profile: profile)
            replayDroneNode.addChildNode(visual.rootNode)
            return UAVBuildResult(
                displayName: profile.displayName,
                profileFound: true,
                bodyScale: profile.collisionRadius
            )
        }

        let allProfiles = LIPODroneModelRepository().allProfiles
        var foundProfile: DroneModelProfile?

        if let context = context {
            if let profileID = context.selectedDroneProfileID {
                let canonicalID = LIPODroneModelRepository.canonicalModelID(profileID)
                foundProfile = allProfiles.first { $0.id == canonicalID }
            }
            if foundProfile == nil, let profileName = context.selectedDroneProfileName {
                foundProfile = allProfiles.first { $0.displayName == profileName }
            }
        }

        if let profile = foundProfile {
            let visual = DroneModelBuilder.build(profile: profile)
            replayDroneNode.addChildNode(visual.rootNode)
            return UAVBuildResult(displayName: profile.displayName, profileFound: true, bodyScale: profile.collisionRadius)
        }

        buildGenericDroneProxy()
        let language = L10n.currentLanguage()
        let fallbackName = context?.selectedDroneProfileName.map {
            L10n.f("replay.uav.not_found_named", language: language, $0)
        } ?? L10n.s("replay.uav.generic", language: language)
        return UAVBuildResult(displayName: fallbackName, profileFound: false, bodyScale: 0.3)
    }

    private func buildGenericDroneProxy() {
        let fuselage = SCNBox(width: 0.14, height: 0.08, length: 0.44, chamferRadius: 0.025)
        let fuselageMat = SCNMaterial()
        fuselageMat.diffuse.contents = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
        fuselage.materials = [fuselageMat]
        replayDroneNode.addChildNode(SCNNode(geometry: fuselage))

        for side: Float in [-1, 1] {
            let wing = SCNBox(width: 0.50, height: 0.018, length: 0.14, chamferRadius: 0.005)
            let wingMat = SCNMaterial()
            wingMat.diffuse.contents = NSColor(red: 0.82, green: 0.34, blue: 0.07, alpha: 1)
            wing.materials = [wingMat]
            let wingNode = SCNNode(geometry: wing)
            wingNode.simdPosition = SIMD3<Float>(side * 0.25, 0, 0.02)
            replayDroneNode.addChildNode(wingNode)
        }

        let tail = SCNBox(width: 0.02, height: 0.12, length: 0.08, chamferRadius: 0.005)
        let tailMat = SCNMaterial()
        tailMat.diffuse.contents = NSColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 1)
        tail.materials = [tailMat]
        let tailNode = SCNNode(geometry: tail)
        tailNode.simdPosition = SIMD3<Float>(0, 0.05, 0.20)
        replayDroneNode.addChildNode(tailNode)

        let nose = SCNSphere(radius: 0.048)
        let noseMat = SCNMaterial()
        noseMat.diffuse.contents = NSColor(red: 0.08, green: 0.92, blue: 0.32, alpha: 1)
        nose.materials = [noseMat]
        let noseNode = SCNNode(geometry: nose)
        noseNode.simdPosition = SIMD3<Float>(0, 0, -0.24)
        replayDroneNode.addChildNode(noseNode)
    }

    // MARK: - Environment reconstruction

    private struct EnvironmentBuildResult {
        let terrainPreset: TerrainPreset?
        let mapScale: MapScale?
        let hasEnvironment: Bool
    }

    private func buildReplayEnvironment(
        from context: MissionReplayContextSnapshot?,
        visualQuality: EnvironmentVisualQuality = .detailed
    ) -> EnvironmentBuildResult {
        guard let context = context,
              let presetRaw = context.terrainPresetRawValue,
              let preset = TerrainPreset(rawValue: presetRaw),
              let scaleRaw = context.mapScaleRawValue,
              let mapScale = MapScale(rawValue: scaleRaw),
              let seed = context.terrainSeed else {
            activeWeatherPreset = .normal
            updateReplayWeatherEnvelope(.normal)
            applyReplayTerrainVisualStyle(for: .field, halfExtent: 800.0)
            buildWorldBoundsIndicator(halfExtent: 800.0)
            return EnvironmentBuildResult(terrainPreset: nil, mapScale: nil, hasEnvironment: false)
        }

        let config = TerrainConfiguration(
            preset: preset,
            mapScale: mapScale,
            density: preset.defaultDensity,
            seed: seed,
            safeSpawnRadius: 15.0
        )

        let weather = context.weatherPresetRawValue.flatMap(WeatherPreset.init(rawValue:)) ?? .normal
        EnvironmentObjectFactory.snowWeatherActive = (weather == .snow)
        activeWeatherPreset = weather
        updateReplayWeatherEnvelope(weather)

        if preset == .city {
            _ = abandonedCitySceneComposer.rebuild(in: environmentNode, terrain: config)
        } else {
            let svc = ScenePopulationService(rootNode: environmentNode)
            svc.populate(with: config, visualQuality: visualQuality)
        }
        applyReplayTerrainVisualStyle(for: preset, halfExtent: config.scenicHalfExtent, weather: weather)
        buildWorldBoundsIndicator(halfExtent: config.worldHalfExtent)

        return EnvironmentBuildResult(terrainPreset: preset, mapScale: mapScale, hasEnvironment: true)
    }

    private func rebuildReplayEnvironment(quality: EnvironmentVisualQuality) {
        environmentNode.childNodes.forEach { $0.removeFromParentNode() }
        _ = buildReplayEnvironment(from: loadedContext, visualQuality: quality)
    }

    private func applyReplayTerrainVisualStyle(
        for terrain: TerrainPreset,
        halfExtent: Float,
        weather: WeatherPreset = .normal
    ) {
        let sky = replaySkyGradientImage(for: terrain)
        scene.background.contents = sky
        scene.lightingEnvironment.contents = sky

        let lighting: (sun: CGFloat, ambient: CGFloat, environment: CGFloat)
        switch terrain {
        case .gridDemo:
            lighting = (1500, 420, 0.82)
        case .field:
            lighting = (1840, 520, 1.18)
        case .forest:
            lighting = (1720, 500, 1.08)
        case .cargoYard:
            lighting = (1810, 470, 1.02)
        case .city:
            lighting = (1760, 450, 0.96)
        }
        scene.lightingEnvironment.intensity = lighting.environment

        for node in scene.rootNode.childNodes {
            guard let light = node.light else { continue }
            switch light.type {
            case .ambient:
                light.intensity = lighting.ambient
            case .directional:
                light.intensity = lighting.sun
                light.color = NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.88, alpha: 1.0)
            default:
                break
            }
        }

        if let plane = groundNode.geometry as? SCNPlane {
            let size = CGFloat(max(400, halfExtent * 2 + 48))
            plane.width = size
            plane.height = size
        }

        let mapSizeMeters = max(400.0, halfExtent * 2.0 + 48.0)
        let groundMaterial: SCNMaterial
        switch terrain {
        case .city:
            groundMaterial = AbandonedCityMaterialLoader.makeBrittleStoneMaterial(mapSizeMeters: mapSizeMeters)
        case .cargoYard:
            groundMaterial = weather == .snow
                ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                : AsphaltMaterialLoader.makeAsphaltMaterial(mapSizeMeters: mapSizeMeters)
        case .field, .forest:
            groundMaterial = weather == .snow
                ? SnowTerrainMaterialLoader.makeSnowMaterial(mapSizeMeters: mapSizeMeters)
                : GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: mapSizeMeters)
        case .gridDemo:
            let proc = (EnvironmentProceduralMaterials.groundMaterial(for: terrain).copy() as? SCNMaterial)
                ?? EnvironmentProceduralMaterials.groundMaterial(for: terrain)
            let repeatCount = max(8.0, min(28.0, halfExtent / 28.0))
            proc.diffuse.wrapS = .repeat
            proc.diffuse.wrapT = .repeat
            proc.diffuse.contentsTransform = SCNMatrix4MakeScale(
                CGFloat(repeatCount),
                CGFloat(repeatCount),
                1.0
            )
            proc.roughness.contents = 0.96
            proc.metalness.contents = 0.0
            groundMaterial = proc
        }
        groundNode.geometry?.materials = [groundMaterial]
    }

    private func replaySkyGradientImage(for terrain: TerrainPreset) -> NSImage {
        let size = NSSize(width: 1024, height: 768)
        let image = NSImage(size: size)
        image.lockFocus()

        let topColor: NSColor
        let midColor: NSColor
        let horizonColor: NSColor

        switch terrain {
        case .gridDemo:
            topColor = NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.28, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.17, green: 0.28, blue: 0.42, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.37, green: 0.52, blue: 0.66, alpha: 1.0)
        case .field:
            topColor = NSColor(calibratedRed: 0.24, green: 0.46, blue: 0.74, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.49, green: 0.69, blue: 0.86, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.83, green: 0.84, blue: 0.69, alpha: 1.0)
        case .forest:
            topColor = NSColor(calibratedRed: 0.16, green: 0.33, blue: 0.51, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.34, green: 0.54, blue: 0.63, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.70, green: 0.76, blue: 0.66, alpha: 1.0)
        case .cargoYard:
            topColor = NSColor(calibratedRed: 0.22, green: 0.38, blue: 0.58, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.51, green: 0.64, blue: 0.72, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.80, green: 0.74, blue: 0.60, alpha: 1.0)
        case .city:
            topColor = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.35, alpha: 1.0)
            midColor = NSColor(calibratedRed: 0.39, green: 0.46, blue: 0.57, alpha: 1.0)
            horizonColor = NSColor(calibratedRed: 0.74, green: 0.68, blue: 0.60, alpha: 1.0)
        }

        if let gradient = NSGradient(colors: [topColor, midColor, horizonColor]) {
            gradient.draw(in: NSRect(origin: .zero, size: size), angle: -90.0)
        }

        let hazeRect = NSRect(
            x: size.width * 0.12,
            y: size.height * 0.06,
            width: size.width * 0.76,
            height: size.height * 0.24
        )
        let hazePath = NSBezierPath(ovalIn: hazeRect)
        NSColor.white.withAlphaComponent(0.10).setFill()
        hazePath.fill()

        image.unlockFocus()
        return image
    }

    private func buildWorldBoundsIndicator(halfExtent h: Float) {
        let corners: [SCNVector3] = [
            SCNVector3(-h, 0.05, -h),
            SCNVector3( h, 0.05, -h),
            SCNVector3( h, 0.05,  h),
            SCNVector3(-h, 0.05,  h)
        ]
        let vertexSource = SCNGeometrySource(vertices: corners)
        let indices: [Int32] = [0, 1, 1, 2, 2, 3, 3, 0]
        let lineElement = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [vertexSource], elements: [lineElement])
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(red: 0.50, green: 0.50, blue: 0.55, alpha: 0.55)
        mat.isDoubleSided = true
        geometry.materials = [mat]
        let boundsNode = SCNNode(geometry: geometry)
        boundsNode.name = "worldBoundsIndicator"
        environmentNode.addChildNode(boundsNode)
    }

    // MARK: - Path trail

    private func buildPathTrail(from frames: [MissionReplayFrame]) {
        guard frames.count >= 2 else { return }

        let maxSamples = 500
        let sampled: [MissionReplayFrame]
        if frames.count <= maxSamples {
            sampled = frames
        } else {
            let step = frames.count / maxSamples
            var tmp: [MissionReplayFrame] = []
            tmp.reserveCapacity(maxSamples + 1)
            var i = 0
            while i < frames.count {
                tmp.append(frames[i])
                i += step
            }
            if tmp.last?.id != frames.last?.id, let last = frames.last {
                tmp.append(last)
            }
            sampled = tmp
        }

        guard sampled.count >= 2 else { return }

        let vertices = sampled.map {
            SCNVector3(Float($0.position.x), Float($0.position.y), Float($0.position.z))
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)

        var indices: [Int32] = []
        indices.reserveCapacity((sampled.count - 1) * 2)
        for i in 0..<(sampled.count - 1) {
            indices.append(Int32(i))
            indices.append(Int32(i + 1))
        }
        let lineElement = SCNGeometryElement(indices: indices, primitiveType: .line)

        let geometry = SCNGeometry(sources: [vertexSource], elements: [lineElement])
        let lineMat = SCNMaterial()
        lineMat.diffuse.contents = NSColor(red: 0.24, green: 0.64, blue: 1.0, alpha: 0.90)
        lineMat.lightingModel = .constant
        lineMat.isDoubleSided = true
        lineMat.writesToDepthBuffer = false
        geometry.materials = [lineMat]

        let lineNode = SCNNode(geometry: geometry)
        lineNode.castsShadow = false
        pathNode.addChildNode(lineNode)
    }

    // MARK: - Event markers

    private func buildEventMarkers(events: [MissionReplayEvent], frames: [MissionReplayFrame]) {
        let capped = Array(events.prefix(200))
        for event in capped {
            guard let pos = markerPosition(for: event, frames: frames) else { continue }
            let node = makeMarkerNode(for: event.type)
            node.simdPosition = SIMD3<Float>(pos.x, pos.y + 0.5, pos.z)
            eventMarkersNode.addChildNode(node)
        }
    }

    private func markerPosition(for event: MissionReplayEvent, frames: [MissionReplayFrame]) -> SIMD3<Float>? {
        if let p = event.position {
            return SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        }
        guard let nearest = nearestFrame(to: event.timestamp, in: frames) else { return nil }
        return SIMD3<Float>(
            Float(nearest.position.x),
            Float(nearest.position.y),
            Float(nearest.position.z)
        )
    }

    private func makeMarkerNode(for type: MissionReplayEventType) -> SCNNode {
        let (geometry, color) = markerAppearance(for: type)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.28)
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]
        let node = SCNNode(geometry: geometry)
        node.castsShadow = false
        return node
    }

    private func markerAppearance(for type: MissionReplayEventType) -> (SCNGeometry, NSColor) {
        switch type {
        case .sessionStarted, .sessionStopped, .recordingLimitReached:
            return (SCNCylinder(radius: 0.12, height: 0.35),
                    NSColor(red: 0.20, green: 0.85, blue: 0.90, alpha: 1))
        case .armed:
            return (SCNSphere(radius: 0.18),
                    NSColor(red: 0.20, green: 0.90, blue: 0.30, alpha: 1))
        case .disarmed:
            return (SCNSphere(radius: 0.18),
                    NSColor(red: 0.95, green: 0.85, blue: 0.10, alpha: 1))
        case .autopilotEnabled:
            return (SCNSphere(radius: 0.15),
                    NSColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1))
        case .autopilotDisabled:
            return (SCNSphere(radius: 0.15),
                    NSColor(red: 0.55, green: 0.55, blue: 0.60, alpha: 1))
        case .warning:
            return (SCNPyramid(width: 0.28, height: 0.35, length: 0.28),
                    NSColor(red: 1.00, green: 0.45, blue: 0.10, alpha: 1))
        case .takeoff:
            return (SCNCone(topRadius: 0.0, bottomRadius: 0.14, height: 0.35),
                    NSColor(red: 0.90, green: 0.90, blue: 0.95, alpha: 1))
        case .landing:
            return (SCNCone(topRadius: 0.14, bottomRadius: 0.0, height: 0.35),
                    NSColor(red: 0.80, green: 0.80, blue: 0.85, alpha: 1))
        case .waypointReached:
            return (SCNSphere(radius: 0.18),
                    NSColor(red: 0.10, green: 0.80, blue: 0.45, alpha: 1))
        case .missionCompleted:
            return (SCNSphere(radius: 0.22),
                    NSColor(red: 1.00, green: 0.82, blue: 0.00, alpha: 1))
        case .missionAborted:
            return (SCNSphere(radius: 0.22),
                    NSColor(red: 0.90, green: 0.20, blue: 0.20, alpha: 1))
        case .payloadAttached:
            return (SCNBox(width: 0.22, height: 0.22, length: 0.22, chamferRadius: 0.03),
                    NSColor(red: 0.90, green: 0.55, blue: 0.10, alpha: 1))
        case .payloadReleased:
            return (SCNBox(width: 0.22, height: 0.22, length: 0.22, chamferRadius: 0.03),
                    NSColor(red: 0.95, green: 0.80, blue: 0.15, alpha: 1))
        case .payloadImpact:
            return (SCNBox(width: 0.28, height: 0.14, length: 0.28, chamferRadius: 0.02),
                    NSColor(red: 0.95, green: 0.20, blue: 0.15, alpha: 1))
        }
    }

    private func framePosition(at timestamp: TimeInterval, frames: [MissionReplayFrame]) -> SIMD3<Float>? {
        guard let frame = nearestFrame(to: timestamp, in: frames) else { return nil }
        return SIMD3<Float>(Float(frame.position.x), Float(frame.position.y), Float(frame.position.z))
    }

    private func nearestFrame(to timestamp: TimeInterval, in frames: [MissionReplayFrame]) -> MissionReplayFrame? {
        guard let first = frames.first else { return nil }
        guard timestamp > first.timestamp else { return first }
        guard let last = frames.last, timestamp < last.timestamp else { return frames.last }

        var low = 0
        var high = frames.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if frames[mid].timestamp < timestamp {
                low = mid
            } else {
                high = mid
            }
        }

        let before = frames[low]
        let after = frames[high]
        return abs(before.timestamp - timestamp) <= abs(after.timestamp - timestamp) ? before : after
    }
}
