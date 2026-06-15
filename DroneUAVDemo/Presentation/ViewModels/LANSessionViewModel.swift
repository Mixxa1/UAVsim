import Foundation
import SwiftUI

@MainActor
final class LANSessionViewModel: ObservableObject {
    @Published var state: LANSessionState = .idle
    @Published var selectedRole: LANParticipantRole = .pilot
    @Published var displayName: String = "Участник"
    @Published var joinAddress: String = "127.0.0.1"
    @Published var portText: String = "7777"

    private let transport: LANSessionTransport

    init(transport: LANSessionTransport = NetworkLANSessionTransport()) {
        self.transport = transport

        self.transport.onMessage = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.applyReceivedMessage(message)
            }
        }

        self.transport.onConnectionStateChanged = { [weak self] connectionState, error in
            Task { @MainActor [weak self] in
                guard !(self?.state.mode == nil && connectionState == .disconnected) else { return }
                self?.state.connectionState = connectionState
                self?.state.lastErrorMessage = error
            }
        }
    }

    var isSessionActive: Bool {
        switch state.connectionState {
        case .hosting, .joining, .connected:
            return true
        case .idle, .disconnected, .failed:
            return false
        }
    }

    func createHostSession() {
        guard let port = resolvedPort() else {
            fail(message: "Порт должен быть числом от 1 до 65535.")
            return
        }

        let host = LANParticipant(
            displayName: sanitizedDisplayName(),
            role: selectedRole,
            isHost: true,
            assignedVehicleID: assignedVehicleID(for: selectedRole)
        )

        let config = LANSessionConfig.defaultConfig(hostParticipantID: host.id)

        state.mode = .host
        state.connectionState = .hosting
        state.localParticipant = host
        state.participants = [host]
        state.config = config
        state.joinAddress = "0.0.0.0"
        state.port = port
        state.lastErrorMessage = nil

        do {
            try transport.startHost(port: port)
        } catch {
            state.connectionState = .failed
            state.lastErrorMessage = error.localizedDescription
        }
    }

    func joinSession() {
        guard let port = resolvedPort() else {
            fail(message: "Порт должен быть числом от 1 до 65535.")
            return
        }

        let participant = LANParticipant(
            displayName: sanitizedDisplayName(),
            role: selectedRole,
            isHost: false,
            assignedVehicleID: assignedVehicleID(for: selectedRole)
        )

        state.mode = .client
        state.connectionState = .joining
        state.localParticipant = participant
        state.participants = [participant]
        state.config = nil
        state.joinAddress = joinAddress
        state.port = port
        state.lastErrorMessage = nil

        do {
            try transport.connect(to: joinAddress, port: port)

            let hello = LANSessionMessage(
                type: .hello,
                senderID: participant.id,
                participant: participant
            )
            transport.send(hello)
        } catch {
            state.connectionState = .failed
            state.lastErrorMessage = error.localizedDescription
        }
    }

    func selectRole(_ role: LANParticipantRole) {
        selectedRole = role

        guard var local = state.localParticipant else { return }
        local.role = role
        local.assignedVehicleID = assignedVehicleID(for: role, existingID: local.assignedVehicleID)
        state.localParticipant = local
        upsertParticipant(local)

        guard isSessionActive else { return }

        let message = LANSessionMessage(
            type: .roleSelected,
            senderID: local.id,
            participant: local
        )
        transport.send(message)

        if state.mode == .host {
            broadcastParticipantList()
        }
    }

    func leaveSession() {
        if let local = state.localParticipant {
            let message = LANSessionMessage(
                type: .disconnect,
                senderID: local.id,
                participant: local
            )
            transport.send(message)
        }

        transport.stop()
        state = .idle
    }

    func applyReceivedMessage(_ message: LANSessionMessage) {
        switch state.mode {
        case .host:
            applyHostMessage(message)

        case .client:
            applyClientMessage(message)

        case .none:
            break
        }
    }

    private func applyHostMessage(_ message: LANSessionMessage) {
        guard let hostID = state.localParticipant?.id else { return }

        switch message.type {
        case .hello:
            if let participant = message.participant {
                upsertParticipant(participant)
            }

            let welcome = LANSessionMessage(
                type: .welcome,
                senderID: hostID,
                config: state.config
            )
            transport.send(welcome)
            broadcastParticipantList()

        case .roleSelected:
            if let participant = message.participant {
                upsertParticipant(participant)
                broadcastParticipantList()
            }

        case .disconnect:
            state.participants.removeAll { $0.id == message.senderID }
            broadcastParticipantList()

        case .heartbeat:
            updateLastSeen(for: message.senderID)

        case .welcome, .participantList, .sessionConfig:
            break
        }
    }

    private func applyClientMessage(_ message: LANSessionMessage) {
        switch message.type {
        case .welcome:
            state.config = message.config
            state.connectionState = .connected
            state.lastErrorMessage = nil

        case .participantList:
            if let participants = message.participants {
                state.participants = participants
            }

        case .sessionConfig:
            state.config = message.config

        case .disconnect:
            if message.participant?.isHost == true || message.senderID == state.config?.hostParticipantID {
                state.connectionState = .disconnected
            }

        case .hello, .roleSelected, .heartbeat:
            break
        }
    }

    private func broadcastParticipantList() {
        guard let local = state.localParticipant else { return }

        let message = LANSessionMessage(
            type: .participantList,
            senderID: local.id,
            participants: state.participants
        )
        transport.send(message)
    }

    private func upsertParticipant(_ participant: LANParticipant) {
        if let index = state.participants.firstIndex(where: { $0.id == participant.id }) {
            state.participants[index] = participant
        } else {
            state.participants.append(participant)
        }
    }

    private func updateLastSeen(for participantID: UUID) {
        guard let index = state.participants.firstIndex(where: { $0.id == participantID }) else { return }
        state.participants[index].lastSeenTime = Date()
    }

    private func resolvedPort() -> UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0 else {
            return nil
        }
        return value
    }

    private func sanitizedDisplayName() -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Участник" : trimmed
    }

    private func assignedVehicleID(for role: LANParticipantRole, existingID: UUID? = nil) -> UUID? {
        role == .pilot ? (existingID ?? UUID()) : nil
    }

    private func fail(message: String) {
        state.connectionState = .failed
        state.lastErrorMessage = message
    }
}
