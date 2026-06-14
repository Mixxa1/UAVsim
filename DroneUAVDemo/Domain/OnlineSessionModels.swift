import Foundation
import simd

enum OnlineTrialMode: String, Codable, Equatable {
    case lan
    case server
}

enum OnlineParticipantRole: String, Codable, Equatable, CaseIterable, Identifiable {
    case flight
    case spectator

    var id: String { rawValue }
}

enum OnlineSessionConnectionState: Equatable {
    case idle
    case hosting
    case joining
    case connected
    case disconnected
    case failed(String)
}

struct OnlineParticipant: Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var role: OnlineParticipantRole
    var isHost: Bool
    var isLocal: Bool
}

struct OnlineSessionState: Equatable {
    static let defaultPort: UInt16 = 7777

    var mode: OnlineTrialMode
    var connectionState: OnlineSessionConnectionState
    var localParticipant: OnlineParticipant?
    var participants: [OnlineParticipant]
    var hostAddress: String?
    var port: UInt16
}

struct SpectatorCameraState: Equatable {
    var position: SIMD3<Float>
    var yaw: Float
    var pitch: Float
    var moveSpeed: Float
    var fastMoveMultiplier: Float
    var mouseSensitivity: Float

    static func initial(near target: SIMD3<Float>) -> SpectatorCameraState {
        let position = SIMD3<Float>(target.x - 9.0, max(3.8, target.y + 5.0), target.z + 10.0)
        let direction = simd_normalize(target - position)
        let yaw = atan2(direction.x, -direction.z)
        let pitch = asin(direction.y).clamped(to: Float(-85.0).degreesToRadians...Float(85.0).degreesToRadians)
        return SpectatorCameraState(
            position: position,
            yaw: yaw,
            pitch: pitch,
            moveSpeed: 10.0,
            fastMoveMultiplier: 2.5,
            mouseSensitivity: 0.003
        )
    }
}

private extension Float {
    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
