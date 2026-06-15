import Foundation
import SwiftUI

@MainActor
final class LANSessionViewModel: ObservableObject, OnlineTrialSnapshotTransport, OnlineSharedEventTransport {
    @Published var state: LANSessionState = .idle
    @Published var selectedRole: LANParticipantRole = .pilot
    @Published var displayName: String = "Участник"
    @Published var joinAddress: String = "127.0.0.1"
    @Published var portText: String = "7777"
    @Published var launchDescriptor: LANTrialLaunchDescriptor?
    @Published var shouldOpenTrialRuntime: Bool = false
    @Published private(set) var remoteSnapshotState = OnlineRemoteVehicleSnapshotState()
    @Published private(set) var sharedEvents: [OnlineSharedEvent] = []
    @Published private(set) var onlineDamageState = OnlineVehicleDamageState()
    // P2P v1.3: runtime diagnostics visible to DroneSimulationViewModel via onReceive.
    @Published private(set) var onlineDiagnostics = OnlineRuntimeNetworkDiagnostics()

    private let transport: LANSessionTransport
    private var sharedEventSequenceNumber: UInt64 = 0
    // P2P v1.2: host deduplication — pairKey → last accepted timestamp.
    private var recentEventPairKeys: [String: TimeInterval] = [:]
    private let sharedEventPairCooldownSeconds: TimeInterval = 2.0
    // P2P v1.3: ping/pong RTT tracking.
    private var pendingPingID: UUID? = nil
    private var pendingPingSentAt: TimeInterval? = nil
    // v1.5: profile ID of the UAV currently selected in the active simulation.
    // Set by ContentView before createHostSession / joinSession; passed in hello + assignments.
    var localVehicleProfileID: String? = nil

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
        // P2P v1.3.1: require at least one registered client before launch to prevent
        // the race where HOST presses launch before the client's .hello is processed.
        guard state.localParticipant?.isHost == true,
              state.trialPhase == .lobby,
              state.participants.count >= 2 else {
            return false
        }

        switch state.connectionState {
        case .hosting, .connected:
            return true
        case .idle, .joining, .disconnected, .failed:
            return false
        }
    }

    // v1.5: called by ContentView whenever the active UAV profile changes.
    func updateLocalVehicleProfileID(_ profileID: String?) {
        localVehicleProfileID = profileID
        if var local = state.localParticipant {
            local.selectedVehicleProfileID = profileID
            state.localParticipant = local
            upsertParticipant(local)
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
            assignedVehicleID: assignedVehicleID(for: selectedRole),
            selectedVehicleProfileID: localVehicleProfileID
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
        remoteSnapshotState = OnlineRemoteVehicleSnapshotState()

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
            assignedVehicleID: assignedVehicleID(for: selectedRole),
            selectedVehicleProfileID: localVehicleProfileID
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
        remoteSnapshotState = OnlineRemoteVehicleSnapshotState()

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

    func endTrial() {
        guard state.localParticipant?.isHost == true else { return }
        guard let local = state.localParticipant else { return }
        let message = LANSessionMessage(type: .trialEnded, senderID: local.id)
        transport.send(message)
        state.trialPhase = .ended
        shouldOpenTrialRuntime = false
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
        remoteSnapshotState = OnlineRemoteVehicleSnapshotState()
        sharedEvents = []
        onlineDamageState = OnlineVehicleDamageState()
        onlineDiagnostics = OnlineRuntimeNetworkDiagnostics()
        recentEventPairKeys = [:]
        pendingPingID = nil
        pendingPingSentAt = nil
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

        // v1.5.1: final fallback matches DroneSimulationViewModel's default profile for LAN trials
        // (repository.defaultProfile = UAVReferenceCatalog.defaultProfileID = "dji-matrice-350-rtk").
        // Using "abstract-uav" here caused remote replicas to show the small abstract model
        // while local UAV correctly used the default real model.
        let defaultFallbackProfileID = localVehicleProfileID ?? UAVReferenceCatalog.defaultProfileID

        var nextSpawnIndex = 0
        let assignments = state.participants.map { participant in
            let isPilot = participant.role == .pilot
            let profileID = participant.selectedVehicleProfileID ?? defaultFallbackProfileID
            let assignment = LANVehicleAssignment(
                participantID: participant.id,
                participantName: participant.displayName,
                role: participant.role,
                vehicleID: isPilot ? UUID() : nil,
                vehicleProfileID: isPilot ? profileID : nil,
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

        #if DEBUG
        print("[LAN][PROFILE] launchTrial: localProfileID=\(localVehicleProfileID ?? "nil") fallback=\(defaultFallbackProfileID)")
        for a in assignments {
            print("[LAN][PROFILE] assignment participant=\(a.participantName) participantID=\(a.participantID) profileID=\(a.vehicleProfileID ?? "nil") vehicleID=\(a.vehicleID?.uuidString ?? "nil")")
        }
        #endif

        // v1.4: reset per-trial state so no damage or events carry over from previous trial.
        sharedEvents = []
        onlineDamageState = OnlineVehicleDamageState()
        recentEventPairKeys = [:]

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

    func sendVehicleSnapshot(_ snapshot: OnlineVehicleStateSnapshot) {
        guard isSessionActive,
              let local = state.localParticipant else {
            return
        }

        let message = LANSessionMessage(
            type: .vehicleSnapshot,
            senderID: local.id,
            vehicleSnapshot: snapshot
        )
        transport.send(message)
        onlineDiagnostics.outgoingSnapshotCount += 1
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

        case .vehicleSnapshot:
            guard let snapshot = message.vehicleSnapshot else { return }
            remoteSnapshotState.apply(snapshot, ignoringLocalVehicleID: nil)
            remoteSnapshotState.removeStaleSnapshots(olderThan: 2.0)
            onlineDiagnostics.incomingSnapshotCount += 1
            transport.send(message)

        case .vehicleSnapshotBatch:
            guard let batch = message.vehicleSnapshotBatch else { return }
            remoteSnapshotState.apply(batch, ignoringLocalVehicleID: nil)
            remoteSnapshotState.removeStaleSnapshots(olderThan: 2.0)
            onlineDiagnostics.incomingSnapshotCount += batch.snapshots.count
            transport.send(message)

        case .sharedEvent:
            // P2P v1.2: host receives owner-reported event, orders/deduplicates, relays to all.
            if let event = message.sharedEvent {
                acceptAndBroadcastSharedEvent(event)
            }

        case .ping:
            // Reflect pong back to sender.
            if let local = state.localParticipant, let pingID = message.pingID {
                let pong = LANSessionMessage(type: .pong, senderID: local.id, pingID: pingID)
                transport.send(pong)
            }

        case .pong:
            break

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
            #if DEBUG
            print("[LAN][CLIENT] trialLaunch received: assignments=\(descriptor.assignments.count) localID=\(state.localParticipant?.id.uuidString.prefix(8) ?? "nil")")
            let localInDescriptor = descriptor.assignment(for: state.localParticipant?.id ?? UUID()) != nil
            print("[LAN][CLIENT] localParticipant in descriptor: \(localInDescriptor)")
            #endif
            // v1.4: clear per-trial state before entering runtime.
            sharedEvents = []
            onlineDamageState = OnlineVehicleDamageState()
            recentEventPairKeys = [:]
            applyLaunchDescriptor(descriptor)
            state.connectionState = .connected
            state.trialPhase = .running
            state.lastErrorMessage = nil
            shouldOpenTrialRuntime = true
            #if DEBUG
            print("[LAN][CLIENT] shouldOpenTrialRuntime=true launchDescriptor=\(launchDescriptor != nil)")
            #endif

        case .trialEnded:
            state.trialPhase = .ended
            shouldOpenTrialRuntime = false

        case .vehicleSnapshot:
            guard let snapshot = message.vehicleSnapshot else { return }
            remoteSnapshotState.apply(
                snapshot,
                ignoringLocalVehicleID: localVehicleIDForSnapshotFiltering()
            )
            remoteSnapshotState.removeStaleSnapshots(olderThan: 2.0)
            onlineDiagnostics.incomingSnapshotCount += 1

        case .vehicleSnapshotBatch:
            guard let batch = message.vehicleSnapshotBatch else { return }
            remoteSnapshotState.apply(
                batch,
                ignoringLocalVehicleID: localVehicleIDForSnapshotFiltering()
            )
            remoteSnapshotState.removeStaleSnapshots(olderThan: 2.0)
            onlineDiagnostics.incomingSnapshotCount += batch.snapshots.count

        case .disconnect:
            if message.participant?.isHost == true || message.senderID == state.config?.hostParticipantID {
                state.connectionState = .disconnected
            }

        case .sharedEvent:
            // P2P v1.2: clients receive host-ordered events and apply them directly.
            if let event = message.sharedEvent {
                applySharedEvent(event)
            }

        case .pong:
            // P2P v1.3: compute RTT from pending ping.
            if let pingID = message.pingID, pingID == pendingPingID,
               let sentAt = pendingPingSentAt {
                let now = Date().timeIntervalSince1970
                onlineDiagnostics.lastPongAt = now
                onlineDiagnostics.lastPingRoundtripMs = (now - sentAt) * 1000.0
                pendingPingID = nil
                pendingPingSentAt = nil
            }

        case .ping:
            break

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
        onlineDiagnostics.connectedParticipantCount = state.participants.count
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

    private func localVehicleIDForSnapshotFiltering() -> UUID? {
        guard let local = state.localParticipant else { return nil }
        return launchDescriptor?.assignment(for: local.id)?.vehicleID ?? local.assignedVehicleID
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

    // MARK: – P2P v1.2: Shared Event Relay

    // P2P v1.3: send test ping to measure RTT. No-op if not connected or already waiting for pong.
    func sendTestPing() {
        guard isSessionActive, let local = state.localParticipant, pendingPingID == nil else { return }
        let id = UUID()
        let now = Date().timeIntervalSince1970
        pendingPingID = id
        pendingPingSentAt = now
        onlineDiagnostics.lastPingAt = now
        let message = LANSessionMessage(type: .ping, senderID: local.id, pingID: id)
        transport.send(message)
    }

    // P2P v1.3: called when the runtime handoff is complete (lobby → runtime transition).
    func markRuntimeHandoffCompleted() {
        onlineDiagnostics.lastRuntimeHandoffAt = Date().timeIntervalSince1970
        onlineDiagnostics.connectedParticipantCount = state.participants.count
    }

    // Owner calls this to submit an event. If local is host, order/broadcast directly.
    // Otherwise, forward to host for ordering.
    func submitSharedEvent(_ event: OnlineSharedEvent) {
        guard isSessionActive, let local = state.localParticipant else { return }
        onlineDiagnostics.sharedEventSentCount += 1
        if local.isHost {
            acceptAndBroadcastSharedEvent(event)
        } else {
            let message = LANSessionMessage(
                type: .sharedEvent,
                senderID: local.id,
                sharedEvent: event
            )
            transport.send(message)
        }
    }

    // Host-only: assigns sequence number, deduplicates, applies locally, and broadcasts.
    private func acceptAndBroadcastSharedEvent(_ event: OnlineSharedEvent) {
        guard state.localParticipant?.isHost == true,
              let hostID = state.localParticipant?.id else { return }

        // Dedup by pairKey + cooldown.
        let now = Date().timeIntervalSince1970
        if let key = event.pairKey {
            if let lastTime = recentEventPairKeys[key], now - lastTime < sharedEventPairCooldownSeconds {
                return
            }
            recentEventPairKeys[key] = now
        }

        sharedEventSequenceNumber += 1
        var ordered = event
        ordered.sequenceNumber = sharedEventSequenceNumber
        ordered.orderedAt = now

        applySharedEvent(ordered)

        let message = LANSessionMessage(
            type: .sharedEvent,
            senderID: hostID,
            sharedEvent: ordered
        )
        transport.send(message)
    }

    // All participants (host + clients) apply accepted shared events.
    func applySharedEvent(_ event: OnlineSharedEvent) {
        guard !sharedEvents.contains(where: { $0.id == event.id }) else { return }
        onlineDiagnostics.sharedEventReceivedCount += 1

        sharedEvents.append(event)
        sharedEvents.sort { ($0.sequenceNumber, $0.emittedAt) < ($1.sequenceNumber, $1.emittedAt) }
        if sharedEvents.count > 50 { sharedEvents.removeFirst() }

        guard let descriptor = launchDescriptor,
              let localParticipant = state.localParticipant else { return }
        let context = OnlineTrialRuntimeContext(
            launchDescriptor: descriptor,
            localParticipant: localParticipant
        )
        onlineDamageState.apply(sharedEvent: event, vehicleSlots: context.vehicleSlots)
    }
}
