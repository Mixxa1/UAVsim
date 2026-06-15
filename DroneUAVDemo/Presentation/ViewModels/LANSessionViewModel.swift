import Foundation
import SwiftUI

@MainActor
final class LANSessionViewModel: ObservableObject {
    @Published var state: LANSessionState = .idle
    @Published var selectedRole: LANParticipantRole = .pilot
    @Published var displayName: String = "Участник"
    @Published var joinAddress: String = "127.0.0.1"
    @Published var portText: String = "7777"
    @Published var launchDescriptor: LANTrialLaunchDescriptor?
    @Published var shouldOpenTrialRuntime: Bool = false

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

    var hasPilotParticipants: Bool {
        state.participants.contains { $0.role == .pilot }
    }

    var canLaunchTrial: Bool {
        guard state.localParticipant?.isHost == true,
              state.trialPhase == .lobby else {
            return false
        }

        switch state.connectionState {
        case .hosting, .connected:
            return true
        case .idle, .joining, .disconnected, .failed:
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
        state.trialPhase = .lobby
        state.localParticipant = host
        state.participants = [host]
        state.config = config
        state.joinAddress = "0.0.0.0"
        state.port = port
        state.lastErrorMessage = nil
        launchDescriptor = nil
        shouldOpenTrialRuntime = false

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
        state.trialPhase = .lobby
        state.localParticipant = participant
        state.participants = [participant]
        state.config = nil
        state.joinAddress = joinAddress
        state.port = port
        state.lastErrorMessage = nil
        launchDescriptor = nil
        shouldOpenTrialRuntime = false

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
        launchDescriptor = nil
        shouldOpenTrialRuntime = false
        state = .idle
    }

    func launchTrial() {
        guard state.localParticipant?.isHost == true else { return }
        guard canLaunchTrial else { return }
        guard let host = state.localParticipant,
              let config = state.config else {
            state.connectionState = .failed
            state.lastErrorMessage = "LAN-сессия не готова к запуску."
            return
        }

        var nextSpawnIndex = 0
        let assignments = state.participants.map { participant in
            let isPilot = participant.role == .pilot
            let assignment = LANVehicleAssignment(
                participantID: participant.id,
                participantName: participant.displayName,
                role: participant.role,
                vehicleID: isPilot ? UUID() : nil,
                vehicleProfileID: isPilot ? "abstract_uav" : nil,
                spawnIndex: isPilot ? nextSpawnIndex : nil
            )
            if isPilot {
                nextSpawnIndex += 1
            }
            return assignment
        }

        let descriptor = LANTrialLaunchDescriptor(
            hostParticipantID: host.id,
            sessionConfig: config,
            assignments: assignments
        )

        state.trialPhase = .launching
        applyLaunchDescriptor(descriptor)

        let message = LANSessionMessage(
            type: .trialLaunch,
            senderID: host.id,
            trialLaunch: descriptor
        )
        transport.send(message)

        shouldOpenTrialRuntime = true
        state.trialPhase = .running
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

        case .trialStarted:
            break

        case .trialEnded:
            state.trialPhase = .ended
            shouldOpenTrialRuntime = false

        case .welcome, .participantList, .sessionConfig, .trialLaunch:
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

        case .trialLaunch:
            guard let descriptor = message.trialLaunch else { return }
            applyLaunchDescriptor(descriptor)
            state.connectionState = .connected
            state.trialPhase = .running
            state.lastErrorMessage = nil
            shouldOpenTrialRuntime = true

        case .trialEnded:
            state.trialPhase = .ended
            shouldOpenTrialRuntime = false

        case .disconnect:
            if message.participant?.isHost == true || message.senderID == state.config?.hostParticipantID {
                state.connectionState = .disconnected
            }

        case .hello, .roleSelected, .heartbeat, .trialStarted:
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

    private func applyLaunchDescriptor(_ descriptor: LANTrialLaunchDescriptor) {
        launchDescriptor = descriptor
        state.config = descriptor.sessionConfig

        for assignment in descriptor.assignments {
            guard let index = state.participants.firstIndex(where: { $0.id == assignment.participantID }) else {
                continue
            }
            state.participants[index].assignedVehicleID = assignment.vehicleID
        }

        if var local = state.localParticipant,
           let assignment = descriptor.assignment(for: local.id) {
            local.assignedVehicleID = assignment.vehicleID
            state.localParticipant = local
            upsertParticipant(local)
        }
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
