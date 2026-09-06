import Foundation

enum OnlineVehicleOperationalState: String, Codable, Equatable, CaseIterable {
    case normal
    case damaged
    case disabled
    case crashed

    var damageRank: Int {
        switch self { case .normal: return 0; case .damaged: return 1; case .disabled: return 2; case .crashed: return 3 }
    }
}

struct OnlineVehicleDamageRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var vehicleID: UUID
    var participantID: UUID?
    var participantName: String
    var operationalState: OnlineVehicleOperationalState
    var sourceEventID: UUID?
    var updatedAt: TimeInterval
    var sourceSequenceNumber: UInt64? = nil

    init(
        id: UUID = UUID(),
        vehicleID: UUID,
        participantID: UUID?,
        participantName: String,
        operationalState: OnlineVehicleOperationalState,
        sourceEventID: UUID?,
        updatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.vehicleID = vehicleID
        self.participantID = participantID
        self.participantName = participantName
        self.operationalState = operationalState
        self.sourceEventID = sourceEventID
        self.updatedAt = updatedAt
    }

    var isControlDisabled: Bool {
        operationalState == .disabled || operationalState == .crashed
    }
}

struct OnlineVehicleDamageState: Codable, Equatable {
    var recordsByVehicleID: [UUID: OnlineVehicleDamageRecord] = [:]
    /// The trial these records belong to. Latched from the first event applied, so a late packet
    /// from the previous trial cannot damage an aircraft in this one.
    var runID: UUID?

    var records: [OnlineVehicleDamageRecord] {
        recordsByVehicleID.values.sorted { $0.participantName < $1.participantName }
    }

    func record(for vehicleID: UUID) -> OnlineVehicleDamageRecord? {
        recordsByVehicleID[vehicleID]
    }

    func isControlDisabled(vehicleID: UUID?) -> Bool {
        guard let vehicleID else { return false }
        return recordsByVehicleID[vehicleID]?.isControlDisabled == true
    }

    /// Folds one ordered shared event into the damage picture.
    ///
    /// Three things make this idempotent rather than merely last-write-wins, which is what a
    /// distributed authority needs: the state belongs to exactly one trial, a repeat of the same
    /// event ID changes nothing, and an event that arrives out of order — or that would *undo*
    /// damage already recorded — is ignored rather than applied.
    mutating func apply(
        sharedEvent event: OnlineSharedEvent,
        vehicleSlots: [OnlineTrialVehicleSlot]
    ) {
        guard runID == nil || runID == event.sessionID else { return }
        runID = event.sessionID
        for vehicleID in Set(event.affectedVehicleIDs) {
            let newState: OnlineVehicleOperationalState
            // Each vehicle in a collision can come out of it differently. Events from before
            // per-vehicle results existed carry one shared result for everyone involved.
            let result = event.vehicleResults?[vehicleID.uuidString] ?? event.result
            switch result {
            case .none, .ignored, .completed, .failed: continue
            case .damaged: newState = .damaged
            case .disabled: newState = .disabled
            case .crashed: newState = .crashed
            }
            if let existing = recordsByVehicleID[vehicleID] {
                guard existing.sourceEventID != event.id,
                      newState.damageRank >= existing.operationalState.damageRank else { continue }
                if let sequence = existing.sourceSequenceNumber, event.sequenceNumber <= sequence { continue }
            }
            let slot = vehicleSlots.first { $0.vehicleID == vehicleID }
            var record = OnlineVehicleDamageRecord(
                vehicleID: vehicleID,
                participantID: slot?.participantID,
                participantName: slot?.participantName ?? "UAV",
                operationalState: newState,
                sourceEventID: event.id,
                updatedAt: event.orderedAt ?? event.emittedAt
            )
            record.sourceSequenceNumber = event.sequenceNumber
            recordsByVehicleID[vehicleID] = record
        }
    }
}
