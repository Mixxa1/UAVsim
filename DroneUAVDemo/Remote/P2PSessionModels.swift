import Foundation

struct P2PSessionPeer: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let role: OnlineTrialRole
    let isHost: Bool
    let controlledUAVID: UUID?

    init(
        id: UUID = UUID(),
        displayName: String,
        role: OnlineTrialRole,
        isHost: Bool,
        controlledUAVID: UUID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isHost = isHost
        self.controlledUAVID = controlledUAVID
    }
}

enum P2PSessionState {
    case idle
    case prepared(session: OnlineTrialSessionConfig, localPeer: P2PSessionPeer)
    case connecting(session: OnlineTrialSessionConfig, localPeer: P2PSessionPeer)
    case connected(session: OnlineTrialSessionConfig, peers: [P2PSessionPeer])
    case stopped
    case failed(message: String)
}

protocol P2PTransport: AnyObject {
    var state: P2PSessionState { get }

    func prepare(session: OnlineTrialSessionConfig, localPeer: P2PSessionPeer)
    func stop()
}

final class DisabledP2PTransport: P2PTransport {
    private(set) var state: P2PSessionState = .idle

    func prepare(session: OnlineTrialSessionConfig, localPeer: P2PSessionPeer) {
        state = .prepared(session: session, localPeer: localPeer)
    }

    func stop() {
        state = .stopped
    }
}
