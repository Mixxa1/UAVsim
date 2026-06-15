import Foundation
import simd

struct OnlineTrialFleetState: Codable, Equatable {
    var localParticipantID: UUID
    var localVehicleID: UUID?
    var vehicles: [OnlineTrialVehicleSlot]

    var localVehicle: OnlineTrialVehicleSlot? {
        guard let localVehicleID else { return nil }
        return vehicles.first { $0.vehicleID == localVehicleID }
    }

    var remoteVehicles: [OnlineTrialVehicleSlot] {
        vehicles.filter { $0.vehicleID != localVehicleID }
    }

    var isSpectator: Bool {
        localVehicleID == nil
    }
}

enum OnlineTrialSpawnLayout {
    static func position(for spawnIndex: Int) -> SIMD3<Float> {
        let spacing: Float = 6.0
        let row = spawnIndex / 4
        let col = spawnIndex % 4
        return SIMD3<Float>(
            Float(col) * spacing - spacing * 1.5,
            0.0,
            Float(row) * spacing
        )
    }
}
