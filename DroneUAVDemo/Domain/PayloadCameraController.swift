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
    private(set) var trackedReleaseID: UUID?
    private(set) var previousUAVMode: CameraMode?
    private(set) var autoSwitchAfterRelease: Bool = false
    private(set) var status: PayloadCameraStatus = .inactive

    func setAutoSwitchAfterRelease(_ enabled: Bool) {
        autoSwitchAfterRelease = enabled
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
