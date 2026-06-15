import Foundation

@MainActor
final class LANSessionViewModel: ObservableObject {
    @Published var state: LANSessionState = .idle
    @Published var selectedRole: LANParticipantRole = .pilot
    @Published var displayName: String = "Участник"
    @Published var joinAddress: String = "127.0.0.1"
    @Published var portText: String = "7777"

    func createHostSession() {
        guard let port = resolvedPort() else {
            fail(message: "Порт должен быть числом от 1 до 65535.")
            return
        }

        let participant = LANParticipant(
            displayName: resolvedDisplayName(),
            role: selectedRole,
            isHost: true,
            assignedVehicleID: selectedRole == .pilot ? UUID() : nil
        )
        let config = LANSessionConfig.defaultConfig(hostParticipantID: participant.id)

        state = LANSessionState(
            mode: .host,
            connectionState: .hosting,
            localParticipant: participant,
            participants: [participant],
            config: config,
            joinAddress: "",
            port: port,
            lastErrorMessage: nil
        )
    }

    func joinSession() {
        guard let port = resolvedPort() else {
            fail(message: "Порт должен быть числом от 1 до 65535.")
            return
        }

        let trimmedAddress = joinAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddress.isEmpty else {
            fail(message: "Введите адрес LAN-сессии.")
            return
        }

        let participant = LANParticipant(
            displayName: resolvedDisplayName(),
            role: selectedRole,
            assignedVehicleID: selectedRole == .pilot ? UUID() : nil
        )

        state = LANSessionState(
            mode: .client,
            connectionState: .connected,
            localParticipant: participant,
            participants: [participant],
            config: nil,
            joinAddress: trimmedAddress,
            port: port,
            lastErrorMessage: nil
        )
    }

    func selectRole(_ role: LANParticipantRole) {
        selectedRole = role

        guard var participant = state.localParticipant else { return }
        participant.role = role
        participant.assignedVehicleID = role == .pilot ? (participant.assignedVehicleID ?? UUID()) : nil
        state.localParticipant = participant

        if let index = state.participants.firstIndex(where: { $0.id == participant.id }) {
            state.participants[index] = participant
        }
    }

    func leaveSession() {
        state = .idle
    }

    func applyReceivedMessage(_ message: LANSessionMessage) {
        switch message.type {
        case .hello, .welcome, .roleSelected:
            guard let participant = message.participant else { return }
            upsertParticipant(participant)
            if message.type == .welcome, state.localParticipant?.id == participant.id {
                state.localParticipant = participant
                selectedRole = participant.role
            }
        case .participantList:
            state.participants = message.participants ?? state.participants
        case .sessionConfig:
            state.config = message.config
        case .heartbeat:
            guard var participant = message.participant else { return }
            participant.lastSeenTime = Date(timeIntervalSince1970: message.timestamp)
            upsertParticipant(participant)
        case .disconnect:
            if let participant = message.participant {
                state.participants.removeAll { $0.id == participant.id }
            } else if message.senderID == state.localParticipant?.id {
                leaveSession()
            }
        }
    }

    private func upsertParticipant(_ participant: LANParticipant) {
        if let index = state.participants.firstIndex(where: { $0.id == participant.id }) {
            state.participants[index] = participant
        } else {
            state.participants.append(participant)
        }
    }

    private func resolvedDisplayName() -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Участник" : trimmed
    }

    private func resolvedPort() -> UInt16? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(trimmed), value > 0 else { return nil }
        return value
    }

    private func fail(message: String) {
        state = LANSessionState(
            mode: state.mode,
            connectionState: .failed,
            localParticipant: state.localParticipant,
            participants: state.participants,
            config: state.config,
            joinAddress: joinAddress,
            port: UInt16(portText) ?? state.port,
            lastErrorMessage: message
        )
    }
}
