import Foundation

enum PayloadState: String, Hashable {
    case noPayload
    case attached
    case removed
    case released
    case falling
    case landed
    case cleanedUp

    var title: String {
        switch self {
        case .noPayload:
            return NSLocalizedString("payload.state.no_payload", comment: "")
        case .attached:
            return NSLocalizedString("payload.state.attached", comment: "")
        case .removed:
            return NSLocalizedString("payload.state.removed", comment: "")
        case .released:
            return NSLocalizedString("payload.state.released", comment: "")
        case .falling:
            return NSLocalizedString("payload.state.falling", comment: "")
        case .landed:
            return NSLocalizedString("payload.state.landed", comment: "")
        case .cleanedUp:
            return NSLocalizedString("payload.state.cleaned_up", comment: "")
        }
    }
}

enum PayloadCameraMode: String, Codable, CaseIterable, Identifiable {
    case optical
    case thermalStub
    case nightStub

    var id: String { rawValue }
}

enum PayloadCameraStabilizationMode: String, Codable, CaseIterable, Identifiable {
    case off
    case horizonLock
    case targetLock
    case lowSpeedStabilized

    var id: String { rawValue }
}

enum PayloadMissionSignal: Equatable {
    case cameraPowered(Bool)
    case recordingStarted
    case recordingStopped
    case focusLocked(distanceMeters: Double)
    case targetMeasured(distanceMeters: Double)
    case outOfFocus(errorMeters: Double)
    case rangefinderPowered(Bool)
    case rangeMeasured(distanceMeters: Double)
    case hosePowered(Bool)
}

struct PayloadCameraOpticsState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    var isRecording: Bool

    var mode: PayloadCameraMode

    var zoomLevel: Double
    var minZoom: Double
    var maxZoom: Double

    var baseFieldOfViewDegrees: Double
    var currentFieldOfViewDegrees: Double

    var focusDistanceMeters: Double
    var targetDistanceMeters: Double?
    var autofocusEnabled: Bool
    var focusErrorMeters: Double
    var blurRadius: Double
    var motionBlurRadius: Double
    var focusLockPulse: Double

    var stabilizationMode: PayloadCameraStabilizationMode
    var stabilizationStrength: Double
    var stabilizationSpeedLimitMps: Double
    var angularDamping: Double
    var vibrationSuppression: Double
    var targetLockEnabled: Bool

    var gimbalYawDegrees: Double
    var gimbalPitchDegrees: Double

    var feedLabel: String

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        isRecording: Bool = false,
        mode: PayloadCameraMode = .optical,
        zoomLevel: Double = 1.0,
        minZoom: Double = 1.0,
        maxZoom: Double = 50.0,
        baseFieldOfViewDegrees: Double = 55.0,
        currentFieldOfViewDegrees: Double = 55.0,
        focusDistanceMeters: Double = 25.0,
        targetDistanceMeters: Double? = nil,
        autofocusEnabled: Bool = false,
        focusErrorMeters: Double = 0.0,
        blurRadius: Double = 0.0,
        motionBlurRadius: Double = 0.0,
        focusLockPulse: Double = 0.0,
        stabilizationMode: PayloadCameraStabilizationMode = .lowSpeedStabilized,
        stabilizationStrength: Double = 1.0,
        stabilizationSpeedLimitMps: Double = 4.0,
        angularDamping: Double = 0.85,
        vibrationSuppression: Double = 0.75,
        targetLockEnabled: Bool = false,
        gimbalYawDegrees: Double = 0.0,
        gimbalPitchDegrees: Double = -12.0,
        feedLabel: String = "EO CAM"
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.isRecording = isRecording
        self.mode = mode
        self.zoomLevel = zoomLevel
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.baseFieldOfViewDegrees = baseFieldOfViewDegrees
        self.currentFieldOfViewDegrees = currentFieldOfViewDegrees
        self.focusDistanceMeters = focusDistanceMeters
        self.targetDistanceMeters = targetDistanceMeters
        self.autofocusEnabled = autofocusEnabled
        self.focusErrorMeters = focusErrorMeters
        self.blurRadius = blurRadius
        self.motionBlurRadius = motionBlurRadius
        self.focusLockPulse = focusLockPulse
        self.stabilizationMode = stabilizationMode
        self.stabilizationStrength = stabilizationStrength
        self.stabilizationSpeedLimitMps = stabilizationSpeedLimitMps
        self.angularDamping = angularDamping
        self.vibrationSuppression = vibrationSuppression
        self.targetLockEnabled = targetLockEnabled
        self.gimbalYawDegrees = gimbalYawDegrees
        self.gimbalPitchDegrees = gimbalPitchDegrees
        self.feedLabel = feedLabel
    }
}
