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
    // 2-column grid, 8 m X separation, 8 m Z row depth, centered at ±4 m.
    // spawnIndex 0 → left front, 1 → right front, 2 → left back, …
    static func position(for spawnIndex: Int) -> SIMD3<Float> {
        let spacingX: Float = 8.0
        let spacingZ: Float = 8.0
        let row = spawnIndex / 2
        let col = spawnIndex % 2
        let x: Float = col == 0 ? -spacingX * 0.5 : spacingX * 0.5
        let z: Float = Float(row) * spacingZ
        return SIMD3<Float>(x, 0.0, z)
    }

    static func yawRadians(for spawnIndex: Int) -> Float {
        return 0
    }
}
