import Foundation

struct MissionSafetyState: Equatable {
    var readiness: MissionRunReadiness
    var blockReason: MissionBlockReason?
    var warnings: [MissionWarning]
    var authorityState: MissionControlAuthorityState
    var runtimeConstraints: MissionRuntimeConstraintState
    var failsafeMode: MissionFailsafeMode
    var abortReason: MissionAbortReason?

    var isStartBlocked: Bool {
        readiness != .ready
    }

    static let idle = MissionSafetyState(
        readiness: .draft,
        blockReason: nil,
        warnings: [],
        authorityState: .idle,
        runtimeConstraints: .idle,
        failsafeMode: .none,
        abortReason: nil
    )
}
