import Foundation

enum PayloadCameraLifecycleState: String, Equatable {
    case inactive
    case falling
    case impact
    case rest

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .inactive:
            return "payload_camera.state.inactive"
        case .falling:
            return "payload_camera.state.falling"
        case .impact:
            return "payload_camera.state.impact"
        case .rest:
            return "payload_camera.state.rest"
        }
    }
}

struct PayloadCameraSceneSnapshot: Equatable {
    let releaseID: UUID
    let altitude: Float
    let verticalSpeed: Float
    let elapsedTime: TimeInterval
    let state: PayloadCameraLifecycleState
}

struct PayloadCameraStatus: Equatable {
    let isAvailable: Bool
    let isActive: Bool
    let altitude: Float
    let verticalSpeed: Float
    let elapsedTime: TimeInterval
    let state: PayloadCameraLifecycleState

    static let inactive = PayloadCameraStatus(
        isAvailable: false,
        isActive: false,
        altitude: 0.0,
        verticalSpeed: 0.0,
        elapsedTime: 0.0,
        state: .inactive
    )
}

final class PayloadCameraController {
    private enum OpticsConstants {
        static let minFocusDistanceMeters = 1.0
        static let maxFocusDistanceMeters = 500.0
        static let minFieldOfViewDegrees = 1.0
        static let minGimbalPitchDegrees = -90.0
        static let maxGimbalPitchDegrees = 35.0
        static let maxBlurRadius = 8.0
        static let maxMotionBlurRadius = 6.0
        static let autofocusResponse = 6.0
        static let passiveFocusAssistResponse = 2.8
        static let motionBlurRiseResponse = 12.0
        static let motionBlurDecayResponse = 5.0
        static let focusLockPulseDecay = 3.2
        static let outOfFocusSignalThreshold = 6.0
        static let focusLockThreshold = 0.35
        static let passiveAssistStabilityFloor = 0.55
        static let focusToleranceFactor = 0.08
    }

    private(set) var trackedReleaseID: UUID?
    private(set) var previousUAVMode: CameraMode?
    private(set) var autoSwitchAfterRelease: Bool = false
    private(set) var status: PayloadCameraStatus = .inactive
    private(set) var opticsState = PayloadCameraOpticsState()

    /// Applies the optics of the channel actually selected on the fitted camera module.
    ///
    /// The field of view is that channel's own, from its sensor and focal length, and the zoom
    /// range is what its lens can reach — so a 35 mm prime on full frame and a 34x turret behave
    /// like the different instruments they are instead of sharing one generic default. A hybrid
    /// turret's thermal core has its own optics too, so switching channel moves the coverage.
    ///
    /// `availableModes` is what the fitted hardware can actually do. A mode outside that list is
    /// snapped back to the first one the module offers — a bare LWIR core has no visible channel
    /// to fall back to, and a mapping camera has no thermal one to reach.
    func applyCameraModule(
        fieldOfViewDegrees: Double,
        maximumZoom: Double,
        availableModes: [PayloadCameraMode]
    ) {
        let base = min(max(fieldOfViewDegrees, 1.0), 170.0)
        opticsState.baseFieldOfViewDegrees = base
        opticsState.maxZoom = max(opticsState.minZoom, maximumZoom)
        opticsState.zoomLevel = min(max(opticsState.zoomLevel, opticsState.minZoom), opticsState.maxZoom)
        opticsState.currentFieldOfViewDegrees = base / max(0.001, opticsState.zoomLevel)
        if let fallback = availableModes.first, !availableModes.contains(opticsState.mode) {
            opticsState.mode = fallback
        }
    }

    private var pendingMissionSignals: [PayloadMissionSignal] = []
    private var lastEmittedPowerState: Bool?
    private var lastReportedTargetDistance: Double?
    private var focusLockArmed = true
    private var outOfFocusArmed = true

    func setAutoSwitchAfterRelease(_ enabled: Bool) {
        autoSwitchAfterRelease = enabled
    }

    func setOpticsAvailability(
        isAvailable: Bool,
        isPowered: Bool,
        feedLabel: String? = nil
    ) {
        opticsState.isAvailable = isAvailable
        opticsState.isPowered = isPowered
        if let feedLabel {
            opticsState.feedLabel = feedLabel
        }

        if !isAvailable || !isPowered {
            opticsState.isRecording = false
            opticsState.autofocusEnabled = false
            opticsState.targetDistanceMeters = nil
            opticsState.focusErrorMeters = 0.0
            opticsState.blurRadius = 0.0
            opticsState.motionBlurRadius = 0.0
            opticsState.focusLockPulse = 0.0
            opticsState.targetLockEnabled = false
        }

        if lastEmittedPowerState != isPowered {
            pendingMissionSignals.append(.cameraPowered(isPowered))
            lastEmittedPowerState = isPowered
        }
    }

    func setPayloadCameraMode(_ mode: PayloadCameraMode) {
        opticsState.mode = mode
    }

    func setStabilizationMode(_ mode: PayloadCameraStabilizationMode) {
        opticsState.stabilizationMode = mode
        opticsState.targetLockEnabled = mode == .targetLock
    }

    func updateStabilization(
        speedMetersPerSecond: Double,
        airframeClass: AirframeClass
    ) {
        let strength: Double

        switch opticsState.stabilizationMode {
        case .off:
            strength = 0.0
        case .horizonLock:
            strength = airframeClass == .multirotor ? 0.88 : 0.72
        case .targetLock:
            strength = airframeClass == .multirotor ? 0.96 : 0.84
        case .lowSpeedStabilized:
            if airframeClass == .multirotor {
                let speedFactor = min(max(speedMetersPerSecond / opticsState.stabilizationSpeedLimitMps, 0.0), 1.0)
                strength = pow(1.0 - speedFactor, 0.65)
            } else {
                let slowPenalty = min(max((6.0 - speedMetersPerSecond) / 6.0, 0.0), 1.0)
                let fastPenalty = min(max((speedMetersPerSecond - 22.0) / 12.0, 0.0), 1.0)
                strength = min(max(0.78 - slowPenalty * 0.36 - fastPenalty * 0.22, 0.22), 0.82)
            }
        }

        opticsState.stabilizationStrength = strength
        opticsState.targetLockEnabled = opticsState.stabilizationMode == .targetLock
    }

    func setZoom(_ value: Double) {
        let clampedZoom = min(max(value, opticsState.minZoom), opticsState.maxZoom)
        opticsState.zoomLevel = clampedZoom
        opticsState.currentFieldOfViewDegrees = max(
            OpticsConstants.minFieldOfViewDegrees,
            opticsState.baseFieldOfViewDegrees / clampedZoom
        )
    }

    func setFocusDistance(_ meters: Double) {
        opticsState.focusDistanceMeters = min(
            max(meters, OpticsConstants.minFocusDistanceMeters),
            OpticsConstants.maxFocusDistanceMeters
        )
        opticsState.autofocusEnabled = false
        focusLockArmed = true
        outOfFocusArmed = true
    }

    func adjustGimbal(yawDeltaDegrees: Double, pitchDeltaDegrees: Double) {
        opticsState.gimbalYawDegrees = normalizedYawDegrees(opticsState.gimbalYawDegrees + yawDeltaDegrees)
        opticsState.gimbalPitchDegrees = min(
            max(
                opticsState.gimbalPitchDegrees + pitchDeltaDegrees,
                OpticsConstants.minGimbalPitchDegrees
            ),
            OpticsConstants.maxGimbalPitchDegrees
        )
    }

    func resetGimbalOrientation() {
        opticsState.gimbalYawDegrees = 0.0
        opticsState.gimbalPitchDegrees = -12.0
    }

    func setAutofocusEnabled(_ enabled: Bool) {
        guard opticsState.isAvailable, opticsState.isPowered else {
            opticsState.autofocusEnabled = false
            return
        }
        opticsState.autofocusEnabled = enabled
        focusLockArmed = true
        outOfFocusArmed = true
    }

    func toggleRecording() {
        guard opticsState.isAvailable, opticsState.isPowered else {
            return
        }
        opticsState.isRecording.toggle()
        pendingMissionSignals.append(opticsState.isRecording ? .recordingStarted : .recordingStopped)
    }

    func updateTargetDistance(_ meters: Double?) {
        let previousTarget = opticsState.targetDistanceMeters
        opticsState.targetDistanceMeters = meters
        if let meters,
           lastReportedTargetDistance == nil || abs((lastReportedTargetDistance ?? 0.0) - meters) >= 0.5 {
            pendingMissionSignals.append(.targetMeasured(distanceMeters: meters))
            lastReportedTargetDistance = meters
        } else if meters == nil {
            lastReportedTargetDistance = nil
        }
        if previousTarget == nil || meters == nil || abs((previousTarget ?? 0.0) - (meters ?? 0.0)) >= 0.25 {
            focusLockArmed = true
            outOfFocusArmed = true
        }
    }

    func updateOptics(
        dt: TimeInterval,
        platformStability: Double = 0.0,
        motionDisturbance: Double = 0.0
    ) {
        setZoom(opticsState.zoomLevel)

        guard opticsState.isAvailable, opticsState.isPowered else {
            opticsState.focusErrorMeters = 0.0
            opticsState.blurRadius = 0.0
            opticsState.motionBlurRadius = 0.0
            opticsState.focusLockPulse = 0.0
            return
        }

        opticsState.focusLockPulse = max(0.0, opticsState.focusLockPulse - dt * OpticsConstants.focusLockPulseDecay)

        if let target = opticsState.targetDistanceMeters {
            let focusResponse: Double
            if opticsState.autofocusEnabled {
                focusResponse = OpticsConstants.autofocusResponse
            } else {
                let normalizedAssist = (platformStability - OpticsConstants.passiveAssistStabilityFloor) / (1.0 - OpticsConstants.passiveAssistStabilityFloor)
                let assistWeight = min(max(normalizedAssist, 0.0), 1.0)
                focusResponse = OpticsConstants.passiveFocusAssistResponse * assistWeight
            }

            if focusResponse > 0.0 {
                let blend = min(max(dt, 0.0) * focusResponse, 1.0)
                opticsState.focusDistanceMeters += (target - opticsState.focusDistanceMeters) * blend
            }
        }

        if let target = opticsState.targetDistanceMeters {
            opticsState.focusErrorMeters = abs(target - opticsState.focusDistanceMeters)
        } else {
            opticsState.focusErrorMeters = 0.0
        }

        let tolerance = max(1.0, opticsState.focusDistanceMeters * OpticsConstants.focusToleranceFactor)
        let focusNormalized = min(opticsState.focusErrorMeters / tolerance, 1.0)
        let focusBlurRadius = focusNormalized * OpticsConstants.maxBlurRadius
        let visibleMotion = min(
            max(
                motionDisturbance * (1.0 - opticsState.vibrationSuppression * opticsState.stabilizationStrength),
                0.0
            ),
            1.0
        )
        let motionTargetRadius = visibleMotion * OpticsConstants.maxMotionBlurRadius
        let motionResponse = motionTargetRadius > opticsState.motionBlurRadius
            ? OpticsConstants.motionBlurRiseResponse
            : OpticsConstants.motionBlurDecayResponse
        let motionBlend = min(max(dt, 0.0) * motionResponse, 1.0)
        opticsState.motionBlurRadius += (motionTargetRadius - opticsState.motionBlurRadius) * motionBlend
        opticsState.blurRadius = min(
            OpticsConstants.maxBlurRadius,
            max(focusBlurRadius, opticsState.motionBlurRadius) + min(focusBlurRadius, opticsState.motionBlurRadius) * 0.35
        )

        if let target = opticsState.targetDistanceMeters,
           focusLockArmed,
           opticsState.focusErrorMeters <= OpticsConstants.focusLockThreshold {
            pendingMissionSignals.append(.focusLocked(distanceMeters: target))
            opticsState.focusLockPulse = 1.0
            focusLockArmed = false
        } else if opticsState.focusErrorMeters > OpticsConstants.focusLockThreshold {
            focusLockArmed = true
        }

        if outOfFocusArmed,
           opticsState.blurRadius >= OpticsConstants.outOfFocusSignalThreshold {
            pendingMissionSignals.append(.outOfFocus(errorMeters: opticsState.focusErrorMeters))
            outOfFocusArmed = false
        } else if opticsState.blurRadius < OpticsConstants.outOfFocusSignalThreshold * 0.5 {
            outOfFocusArmed = true
        }

        opticsState.targetLockEnabled = opticsState.stabilizationMode == .targetLock
    }

    func consumeMissionSignals() -> [PayloadMissionSignal] {
        let output = pendingMissionSignals
        pendingMissionSignals.removeAll(keepingCapacity: true)
        return output
    }

    private func normalizedYawDegrees(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360.0)
        if wrapped <= -180.0 {
            wrapped += 360.0
        } else if wrapped > 180.0 {
            wrapped -= 360.0
        }
        return wrapped
    }

    func canActivatePayloadView() -> Bool {
        trackedReleaseID != nil
    }

    func registerPayloadRelease(
        releaseID: UUID?,
        currentMode: CameraMode
    ) -> CameraMode? {
        guard let releaseID else {
            clearTracking()
            return nil
        }

        trackedReleaseID = releaseID
        status = PayloadCameraStatus(
            isAvailable: true,
            isActive: false,
            altitude: 0.0,
            verticalSpeed: 0.0,
            elapsedTime: 0.0,
            state: .falling
        )

        guard autoSwitchAfterRelease else {
            return nil
        }

        return activatePayloadView(from: currentMode)
    }

    func activatePayloadView(from currentMode: CameraMode) -> CameraMode? {
        guard trackedReleaseID != nil else {
            return nil
        }

        if currentMode != .payload {
            previousUAVMode = sanitizedRestoreMode(currentMode)
        }
        status = PayloadCameraStatus(
            isAvailable: true,
            isActive: true,
            altitude: status.altitude,
            verticalSpeed: status.verticalSpeed,
            elapsedTime: status.elapsedTime,
            state: status.state == .inactive ? .falling : status.state
        )

        return currentMode == .payload ? nil : .payload
    }

    func leavePayloadViewManually() {
        previousUAVMode = nil
        if status.isAvailable {
            status = PayloadCameraStatus(
                isAvailable: true,
                isActive: false,
                altitude: status.altitude,
                verticalSpeed: status.verticalSpeed,
                elapsedTime: status.elapsedTime,
                state: status.state
            )
        } else {
            status = .inactive
        }
    }

    func sync(
        sceneSnapshot: PayloadCameraSceneSnapshot?,
        currentMode: CameraMode
    ) -> CameraMode? {
        guard let trackedReleaseID else {
            status = .inactive
            return nil
        }

        guard let sceneSnapshot, sceneSnapshot.releaseID == trackedReleaseID else {
            self.trackedReleaseID = nil
            if currentMode == .payload {
                return restorePreviousMode()
            }
            previousUAVMode = nil
            status = .inactive
            return nil
        }

        status = PayloadCameraStatus(
            isAvailable: true,
            isActive: currentMode == .payload,
            altitude: max(0.0, sceneSnapshot.altitude),
            verticalSpeed: sceneSnapshot.verticalSpeed,
            elapsedTime: max(0.0, sceneSnapshot.elapsedTime),
            state: sceneSnapshot.state
        )
        return nil
    }

    func handleLifecycleState(
        _ payloadState: PayloadState,
        currentMode: CameraMode
    ) -> CameraMode? {
        switch payloadState {
        case .landed:
            return nil
        case .cleanedUp, .removed, .noPayload:
            trackedReleaseID = nil
            if currentMode == .payload {
                return restorePreviousMode()
            }
            previousUAVMode = nil
            status = .inactive
            return nil
        case .released, .falling:
            return nil
        case .attached:
            clearTracking()
            return nil
        }
    }

    func clearTracking() {
        trackedReleaseID = nil
        previousUAVMode = nil
        status = .inactive
    }

    private func restorePreviousMode() -> CameraMode {
        let restoreMode = sanitizedRestoreMode(previousUAVMode ?? .follow)
        previousUAVMode = nil
        status = .inactive
        return restoreMode
    }

    private func sanitizedRestoreMode(_ mode: CameraMode) -> CameraMode {
        mode == .payload ? .follow : mode
    }
}
