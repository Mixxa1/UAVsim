import Foundation

enum OnlineVehicleOperationalState: String, Codable, Equatable, CaseIterable {
    case normal
    case damaged
    case disabled
    case crashed
}

struct OnlineVehicleDamageRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var vehicleID: UUID
    var participantID: UUID?
    var participantName: String
    var operationalState: OnlineVehicleOperationalState
    var sourceEventID: UUID?
    var updatedAt: TimeInterval

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

    mutating func apply(
        sharedEvent event: OnlineSharedEvent,
        vehicleSlots: [OnlineTrialVehicleSlot]
    ) {
        let newState: OnlineVehicleOperationalState
        switch event.result {
        case .none, .ignored, .completed, .failed:
            return
        case .damaged:
            newState = .damaged
        case .disabled:
            newState = .disabled
        case .crashed:
            newState = .crashed
        }

        for vehicleID in event.affectedVehicleIDs {
            let slot = vehicleSlots.first { $0.vehicleID == vehicleID }
            recordsByVehicleID[vehicleID] = OnlineVehicleDamageRecord(
                vehicleID: vehicleID,
                participantID: slot?.participantID,
                participantName: slot?.participantName ?? "UAV",
                operationalState: newState,
                sourceEventID: event.id
            )
        }
    }
}
