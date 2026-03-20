import Foundation
import simd

enum CameraMode: String, CaseIterable, Identifiable {
    case free
    case follow
    case orbit
    case fpv
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free:
            return "Free"
        case .follow:
            return "Chase"
        case .orbit:
            return "Orbit"
        case .fpv:
            return "FPV"
        case .top:
            return "Top"
        }
    }

    var titleKey: String {
        switch self {
        case .free:
            return "camera.mode.free"
        case .follow:
            return "camera.mode.follow"
        case .orbit:
            return "camera.mode.orbit"
        case .fpv:
            return "camera.mode.fpv"
        case .top:
            return "camera.mode.top"
        }
    }

    func next() -> CameraMode {
        switch self {
        case .free:
            return .follow
        case .follow:
            return .orbit
        case .orbit:
            return .fpv
        case .fpv:
            return .top
        case .top:
            return .free
        }
    }

    static func fromStoredRaw(_ rawValue: String) -> CameraMode? {
        switch rawValue {
        case CameraMode.free.rawValue:
            return .free
        case CameraMode.follow.rawValue, "thirdPerson":
            return .follow
        case CameraMode.orbit.rawValue:
            return .orbit
        case CameraMode.fpv.rawValue:
            return .fpv
        case CameraMode.top.rawValue, "topDown":
            return .top
        default:
            return nil
        }
    }
}

enum CameraSensitivityProfile: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .low:
            return "camera.sensitivity.low"
        case .medium:
            return "camera.sensitivity.medium"
        case .high:
            return "camera.sensitivity.high"
        }
    }

    var multiplier: Float {
        switch self {
        case .low:
            return 0.75
        case .medium:
            return 1.0
        case .high:
            return 1.35
        }
    }
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case cinematic
    case pilot
    case inspection
    case wideFollow
    case tightFollow
    case fpv

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .cinematic:
            return "camera.preset.cinematic"
        case .pilot:
            return "camera.preset.pilot"
        case .inspection:
            return "camera.preset.inspection"
        case .wideFollow:
            return "camera.preset.wide_follow"
        case .tightFollow:
            return "camera.preset.tight_follow"
        case .fpv:
            return "camera.preset.fpv"
        }
    }
}

struct FreeCameraState {
    var moveSpeed: Float
    var zoomSensitivity: Float
    var distance: Float
    var minDistance: Float
    var maxDistance: Float
}

struct FollowCameraState {
    var distance: Float
    var height: Float
    var lateralOffset: Float
    var minDistance: Float
    var maxDistance: Float
}

struct OrbitCameraState {
    var distance: Float
    var height: Float
    var angularSpeed: Float
    var minDistance: Float
    var maxDistance: Float
}

struct FPVCameraState {
    var stabilization: Float
    var shake: Float
    var yawLimitDeg: Float
    var pitchLimitDeg: Float
    var nearClip: Float
    var mountOffset: SIMD3<Float>
    var hideObstructingParts: Bool
}

struct TopCameraState {
    var height: Float
    var minHeight: Float
    var maxHeight: Float
    var forwardLead: Float
}

struct CameraConfiguration {
    var mode: CameraMode
    var fov: Float
    var sensitivity: Float
    var smoothing: Float

    var invertLookX: Bool
    var invertLookY: Bool
    var sensitivityProfile: CameraSensitivityProfile
    var lookNudgeStepDeg: Float

    var free: FreeCameraState
    var follow: FollowCameraState
    var orbit: OrbitCameraState
    var fpv: FPVCameraState
    var top: TopCameraState

    var orbitDistance: Float {
        get { orbit.distance }
        set { orbit.distance = newValue.clamped(to: orbit.minDistance...orbit.maxDistance) }
    }

    var followOffset: SIMD3<Float> {
        get { SIMD3<Float>(follow.lateralOffset, follow.height, follow.distance) }
        set {
            follow.lateralOffset = newValue.x
            follow.height = newValue.y
            follow.distance = newValue.z.clamped(to: follow.minDistance...follow.maxDistance)
        }
    }

    var fpvStabilization: Float {
        get { fpv.stabilization }
        set { fpv.stabilization = newValue.clamped(to: 0.0...1.0) }
    }

    var fpvShake: Float {
        get { fpv.shake }
        set { fpv.shake = newValue.clamped(to: 0.0...0.5) }
    }

    var cameraDistance: Float {
        switch mode {
        case .free:
            return free.distance
        case .follow:
            return follow.distance
        case .orbit:
            return orbit.distance
        case .fpv:
            return 0.0
        case .top:
            return top.height
        }
    }

    var effectiveLookSensitivity: Float {
        sensitivity.clamped(to: 0.2...2.5) * sensitivityProfile.multiplier
    }

    mutating func setCameraDistance(_ value: Float) {
        switch mode {
        case .free:
            free.distance = value.clamped(to: free.minDistance...free.maxDistance)
        case .follow:
            follow.distance = value.clamped(to: follow.minDistance...follow.maxDistance)
        case .orbit:
            orbit.distance = value.clamped(to: orbit.minDistance...orbit.maxDistance)
        case .fpv:
            break
        case .top:
            top.height = value.clamped(to: top.minHeight...top.maxHeight)
        }
    }

    mutating func applyPreset(_ preset: CameraPreset) {
        switch preset {
        case .cinematic:
            mode = .follow
            fov = 54.0
            sensitivity = 0.85
            smoothing = 0.82
            follow.distance = 10.5
            follow.height = 3.6
            follow.lateralOffset = 0.0
            orbit.distance = 11.4
            orbit.height = 3.8
        case .pilot:
            mode = .follow
            fov = 76.0
            sensitivity = 1.15
            smoothing = 0.62
            follow.distance = 7.4
            follow.height = 2.3
            follow.lateralOffset = 0.0
            orbit.distance = 8.0
            orbit.height = 2.6
        case .inspection:
            mode = .orbit
            fov = 64.0
            sensitivity = 1.0
            smoothing = 0.70
            orbit.distance = 4.6
            orbit.height = 1.8
            orbit.angularSpeed = 0.28
        case .wideFollow:
            mode = .follow
            fov = 68.0
            sensitivity = 0.95
            smoothing = 0.72
            follow.distance = 12.8
            follow.height = 4.8
        case .tightFollow:
            mode = .follow
            fov = 72.0
            sensitivity = 1.1
            smoothing = 0.64
            follow.distance = 4.2
            follow.height = 1.5
        case .fpv:
            mode = .fpv
            fov = 86.0
            sensitivity = 1.1
            smoothing = 0.58
            fpv.stabilization = 0.30
            fpv.nearClip = 0.02
            fpv.yawLimitDeg = 28.0
            fpv.pitchLimitDeg = 22.0
        }

        setCameraDistance(cameraDistance)
    }

    static let `default` = CameraConfiguration(
        mode: .follow,
        fov: 56.0,
        sensitivity: 1.0,
        smoothing: 0.72,
        invertLookX: false,
        invertLookY: false,
        sensitivityProfile: .medium,
        lookNudgeStepDeg: 1.8,
        free: FreeCameraState(
            moveSpeed: 4.0,
            zoomSensitivity: 1.0,
            distance: 14.0,
            minDistance: 2.0,
            maxDistance: 80.0
        ),
        follow: FollowCameraState(
            distance: 6.8,
            height: 2.4,
            lateralOffset: 0.0,
            minDistance: 2.0,
            maxDistance: 24.0
        ),
        orbit: OrbitCameraState(
            distance: 6.8,
            height: 2.4,
            angularSpeed: 0.42,
            minDistance: 2.0,
            maxDistance: 28.0
        ),
        fpv: FPVCameraState(
            stabilization: 0.45,
            shake: 0.07,
            yawLimitDeg: 24.0,
            pitchLimitDeg: 18.0,
            nearClip: 0.02,
            mountOffset: SIMD3<Float>(0.0, 0.006, -0.014),
            hideObstructingParts: true
        ),
        top: TopCameraState(
            height: 34.0,
            minHeight: 8.0,
            maxHeight: 120.0,
            forwardLead: 0.0
        )
    )
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
