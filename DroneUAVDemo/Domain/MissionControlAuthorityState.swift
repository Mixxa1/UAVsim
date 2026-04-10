import Foundation

enum MissionAuthorityLossState: String, Equatable {
    case stable
    case transientLost
    case confirmedLost
}

struct MissionControlAuthorityState: Equatable {
    var expectedAuthority: FlightControlAuthority
    var actualAuthority: FlightControlAuthority
    var sourceOwnsTarget: Bool
    var hasBoundMissionTarget: Bool
    var requiresMissionAuthority: Bool
    var isAuthorityConfirmed: Bool
    var lossState: MissionAuthorityLossState
    var lossDuration: TimeInterval
    var didRecoverTransientLoss: Bool
    var failureReason: MissionFailureReason?

    var isAuthorityLost: Bool {
        requiresMissionAuthority && lossState == .confirmedLost
    }

    var isAuthorityTransientLoss: Bool {
        requiresMissionAuthority && lossState == .transientLost
    }

    static let idle = MissionControlAuthorityState(
        expectedAuthority: .none,
        actualAuthority: .none,
        sourceOwnsTarget: false,
        hasBoundMissionTarget: false,
        requiresMissionAuthority: false,
        isAuthorityConfirmed: true,
        lossState: .stable,
        lossDuration: 0.0,
        didRecoverTransientLoss: false,
        failureReason: nil
    )
}
