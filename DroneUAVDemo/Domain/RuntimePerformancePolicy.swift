import Foundation

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

struct RuntimePerformancePolicy: Equatable {
    let visibilityState: RuntimeVisibilityState
    let targetRenderFPS: Int
    let snapshotSendInterval: TimeInterval
    let backgroundTickDivisor: Int
    // When true the SCNView should stop playing entirely (isPlaying = false).
    let stopRendering: Bool

    static let `default` = RuntimePerformancePolicy(.activeVisible)

    init(_ state: RuntimeVisibilityState) {
        visibilityState = state
        switch state {
        case .activeVisible:
            targetRenderFPS = 60
            snapshotSendInterval = 0.1
            backgroundTickDivisor = 1
            stopRendering = false
        case .inactiveVisible:
            targetRenderFPS = 30
            snapshotSendInterval = 0.2
            backgroundTickDivisor = 2   // 30 Hz physics; render is already 30 fps
            stopRendering = false
        case .minimized, .hidden:
            // preferredFramesPerSecond = 1 is a safety backstop; isPlaying=false is the real gate.
            targetRenderFPS = 1
            snapshotSendInterval = 0.5
            backgroundTickDivisor = 12
            stopRendering = true
        }
    }

    var isThrottled: Bool { backgroundTickDivisor > 1 }
}
