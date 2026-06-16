import Foundation

enum RuntimeVisibilityState: Equatable {
    case activeVisible
    case inactiveVisible
    case minimized
    case hidden
}

struct RuntimePerformancePolicy: Equatable {
    let visibilityState: RuntimeVisibilityState
    let targetRenderFPS: Int
    let snapshotSendInterval: TimeInterval
    let backgroundTickDivisor: Int

    static let `default` = RuntimePerformancePolicy(.activeVisible)

    init(_ state: RuntimeVisibilityState) {
        visibilityState = state
        switch state {
        case .activeVisible:
            targetRenderFPS = 60
            snapshotSendInterval = 0.1
            backgroundTickDivisor = 1
        case .inactiveVisible:
            targetRenderFPS = 30
            snapshotSendInterval = 0.2
            backgroundTickDivisor = 1
        case .minimized, .hidden:
            targetRenderFPS = 4
            snapshotSendInterval = 0.5
            backgroundTickDivisor = 12
        }
    }

    var isThrottled: Bool { backgroundTickDivisor > 1 }
}
