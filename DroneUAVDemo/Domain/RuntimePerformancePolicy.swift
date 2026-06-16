import Foundation

// MARK: - RuntimeVisibilityState
// Set by NSWindowDelegate events (miniaturize, key/resign, hide/unhide).
// The VM derives RuntimeActivityState from this + user-input recency.

enum RuntimeVisibilityState: Equatable {
    case activeVisible
    case inactiveVisible
    case minimized
    case hidden

    var label: String {
        switch self {
        case .activeVisible:   return "active"
        case .inactiveVisible: return "inactive"
        case .minimized:       return "minimized"
        case .hidden:          return "hidden"
        }
    }
}

// MARK: - RuntimeActivityState
// Combines window visibility with user-input recency for fine-grained throttle.

enum RuntimeActivityState: Equatable {
    case interacting      // key window + recent user input (< 1 s ago)
    case activeIdle       // key window + no recent input
    case backgroundIdle   // visible but not key/main
    case minimized
    case hidden

    var label: String {
        switch self {
        case .interacting:    return "interacting"
        case .activeIdle:     return "activeIdle"
        case .backgroundIdle: return "bgIdle"
        case .minimized:      return "minimized"
        case .hidden:         return "hidden"
        }
    }

    // True when the SceneKit render loop should be running.
    var isRendering: Bool {
        switch self {
        case .interacting, .activeIdle, .backgroundIdle: return true
        case .minimized, .hidden: return false
        }
    }
}

// MARK: - RuntimePerformancePolicy

struct RuntimePerformancePolicy: Equatable {
    let activityState: RuntimeActivityState
    let targetRenderFPS: Int
    let snapshotSendInterval: TimeInterval
    let backgroundTickDivisor: Int
    /// True → SCNView.isPlaying = false (scene render loop stopped entirely).
    let stopRendering: Bool
    /// Minimum seconds between sceneController.applyOnlineInterpolatedRemoteStates() calls.
    let remoteSceneApplyInterval: TimeInterval
    /// Minimum seconds between @Published overlay / remote-states updates.
    let overlayPublishInterval: TimeInterval

    static let `default` = RuntimePerformancePolicy(.interacting)

    init(_ state: RuntimeActivityState) {
        activityState = state
        switch state {
        case .interacting:
            targetRenderFPS = 60
            snapshotSendInterval = 0.1        // 10 Hz TX
            backgroundTickDivisor = 1
            stopRendering = false
            remoteSceneApplyInterval = 0.016  // ≈ 60 Hz
            overlayPublishInterval = 0.1      // 10 Hz

        case .activeIdle:
            targetRenderFPS = 30
            snapshotSendInterval = 0.2        // 5 Hz TX
            backgroundTickDivisor = 2         // 30 Hz physics
            stopRendering = false
            remoteSceneApplyInterval = 0.033  // ≈ 30 Hz
            overlayPublishInterval = 0.5      // 2 Hz

        case .backgroundIdle:
            // Visible-but-inactive window (e.g. observer watching remote UAV while piloting in another window).
            // 30 FPS / 30 Hz replica apply keeps remote movement smooth; alpha = dt*14 ≈ 0.46 (lerp, not snap).
            // Local physics at 15 Hz (backgroundTickDivisor=2) is fine for an idle UAV.
            targetRenderFPS = 30
            snapshotSendInterval = 0.5        // 2 Hz TX (local UAV idle)
            backgroundTickDivisor = 2         // 15 Hz local physics
            stopRendering = false
            remoteSceneApplyInterval = 0.033  // 30 Hz
            overlayPublishInterval = 1.0      // 1 Hz

        case .minimized, .hidden:
            // isPlaying = false handled separately via FocusableSCNView window notifications
            // so that SCNView is paused even when SwiftUI defers body updates for minimized windows.
            targetRenderFPS = 1
            snapshotSendInterval = 0.5        // 2 Hz TX
            backgroundTickDivisor = 12        // 5 Hz physics
            stopRendering = true
            remoteSceneApplyInterval = .infinity  // no apply; one-shot on restore
            overlayPublishInterval = 2.0
        }
    }

    var isThrottled: Bool { backgroundTickDivisor > 1 }
}
