import AppKit
import SceneKit
import simd

// MARK: - Reconstruction status

struct ReplayReconstructionStatus {
    enum Quality: String {
        case full     = "Полный"
        case partial  = "Частичный"
        case fallback = "Резервный"
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
        uavDisplayName: "Generic",
        terrainDisplayName: "n/a",
        weatherDisplayName: "n/a",
        payloadDisplayName: "none",
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
    private var lastKnownFrame: MissionReplayFrame?
    private var loadedFrames: [MissionReplayFrame] = []
    private var loadedEvents: [MissionReplayEvent] = []
    private var loadedContext: MissionReplayContextSnapshot?
    private var selectedReplayEvent: MissionReplayEvent?

    private(set) var reconstructionStatus: ReplayReconstructionStatus = .none

    init() {
        scene = SCNScene()
        cameraNode = SCNNode()
        replayDroneNode = SCNNode()
        groundNode = SCNNode()
        pathNode = SCNNode()
        eventMarkersNode = SCNNode()
        environmentNode = SCNNode()
        buildScene()
    }

    // MARK: - Session loading (legacy, no profiles)

    func loadSession(_ session: MissionReplaySession, events: [MissionReplayEvent] = []) {
        loadSession(session, availableDroneProfiles: [], fallbackProfile: nil, events: events)
    }

    // MARK: - Session loading (visual reconstruction)

    func loadSession(
        _ session: MissionReplaySession,
        availableDroneProfiles: [DroneModelProfile],
        fallbackProfile: DroneModelProfile? = nil,
        events: [MissionReplayEvent] = []
    ) {
        pathNode.childNodes.forEach { $0.removeFromParentNode() }
        eventMarkersNode.childNodes.forEach { $0.removeFromParentNode() }
        environmentNode.childNodes.forEach { $0.removeFromParentNode() }

        let context = session.context
        loadedContext = context

        let uavResult = buildReplayUAV(
            context: context,
            availableDroneProfiles: availableDroneProfiles,
            fallbackProfile: fallbackProfile
        )
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

        var warnings: [String] = []
        if context == nil {
            warnings.append("This replay was recorded before visual context snapshots were added. Fallback visual reconstruction is used.")
        }
        if !uavResult.profileFound {
            warnings.append("Original UAV profile was not found. Generic replay UAV is used.")
        }

        reconstructionStatus = ReplayReconstructionStatus(
            uavDisplayName: uavResult.displayName,
            terrainDisplayName: envResult.description,
            weatherDisplayName: context?.weatherPresetRawValue?.capitalized ?? "n/a",
            payloadDisplayName: context?.payloadResolvedName ?? "none",
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
        updateCameraForCurrentMode(frame: lastKnownFrame)
    }

    func setTopDownHeight(_ height: Float) {
        topDownHeight = max(30, min(400, height))
        updateCameraForCurrentMode(frame: lastKnownFrame)
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
            return "Payload camera unavailable: no payload release or impact events."
        }
        return "Payload trajectory unavailable. Using event focus fallback."
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
        scene.rootNode.addChildNode(groundNode)
        scene.rootNode.addChildNode(environmentNode)
        scene.rootNode.addChildNode(replayDroneNode)
        scene.rootNode.addChildNode(pathNode)
        scene.rootNode.addChildNode(eventMarkersNode)
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
    }

    private func buildReplayUAV(
        context: MissionReplayContextSnapshot?,
        availableDroneProfiles: [DroneModelProfile],
        fallbackProfile: DroneModelProfile?
    ) -> UAVBuildResult {
        replayDroneNode.childNodes.forEach { $0.removeFromParentNode() }

        var foundProfile: DroneModelProfile?

        if let context = context {
            if let profileID = context.selectedDroneProfileID {
                foundProfile = availableDroneProfiles.first { $0.id == profileID }
            }
            if foundProfile == nil, let profileName = context.selectedDroneProfileName {
                foundProfile = availableDroneProfiles.first { $0.displayName == profileName }
            }
        }

        let resolvedProfile = foundProfile ?? fallbackProfile

        if let profile = resolvedProfile {
            let visual = DroneModelBuilder.build(profile: profile)
            replayDroneNode.addChildNode(visual.rootNode)
            let name = profile.displayName
            return UAVBuildResult(displayName: name, profileFound: foundProfile != nil)
        }

        buildGenericDroneProxy()
        let fallbackName = context?.selectedDroneProfileName.map { "\($0) (not found)" } ?? "Generic"
        return UAVBuildResult(displayName: fallbackName, profileFound: false)
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
        let description: String
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
            applyReplayTerrainVisualStyle(for: .field, halfExtent: 800.0)
            buildWorldBoundsIndicator(halfExtent: 800.0)
            return EnvironmentBuildResult(description: "n/a", hasEnvironment: false)
        }

        let config = TerrainConfiguration(
            preset: preset,
            mapScale: mapScale,
            density: preset.defaultDensity,
            seed: seed,
            safeSpawnRadius: 15.0
        )

        let svc = ScenePopulationService(rootNode: environmentNode)
        svc.populate(with: config, visualQuality: visualQuality)
        applyReplayTerrainVisualStyle(for: preset, halfExtent: config.scenicHalfExtent)
        buildWorldBoundsIndicator(halfExtent: config.worldHalfExtent)

        let desc = "\(preset.rawValue) / \(mapScale.rawValue)"
        return EnvironmentBuildResult(description: desc, hasEnvironment: true)
    }

    private func rebuildReplayEnvironment(quality: EnvironmentVisualQuality) {
        environmentNode.childNodes.forEach { $0.removeFromParentNode() }
        _ = buildReplayEnvironment(from: loadedContext, visualQuality: quality)
    }

    private func applyReplayTerrainVisualStyle(for terrain: TerrainPreset, halfExtent: Float) {
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

        let groundMaterial = (EnvironmentProceduralMaterials.groundMaterial(for: terrain).copy() as? SCNMaterial)
            ?? EnvironmentProceduralMaterials.groundMaterial(for: terrain)
        let repeatCount = max(8.0, min(28.0, halfExtent / 28.0))
        groundMaterial.diffuse.wrapS = .repeat
        groundMaterial.diffuse.wrapT = .repeat
        groundMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(
            CGFloat(repeatCount),
            CGFloat(repeatCount),
            1.0
        )
        groundMaterial.roughness.contents = 0.96
        groundMaterial.metalness.contents = 0.0
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
