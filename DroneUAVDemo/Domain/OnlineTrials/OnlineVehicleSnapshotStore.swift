import Foundation

struct OnlineRemoteVehicleSnapshotState: Codable, Equatable {
    var latestSnapshotsByVehicleID: [UUID: OnlineVehicleStateSnapshot] = [:]

    var snapshots: [OnlineVehicleStateSnapshot] {
        latestSnapshotsByVehicleID.values.sorted {
            if $0.participantName == $1.participantName {
                return $0.vehicleID.uuidString < $1.vehicleID.uuidString
            }
            return $0.participantName < $1.participantName
        }
    }

    mutating func apply(
        _ snapshot: OnlineVehicleStateSnapshot,
        ignoringLocalVehicleID localVehicleID: UUID?
    ) {
        if snapshot.vehicleID == localVehicleID {
            return
        }

        if let current = latestSnapshotsByVehicleID[snapshot.vehicleID],
           snapshot.sequenceNumber <= current.sequenceNumber {
            return
        }

        latestSnapshotsByVehicleID[snapshot.vehicleID] = snapshot
    }

    mutating func apply(
        _ batch: OnlineVehicleStateSnapshotBatch,
        ignoringLocalVehicleID localVehicleID: UUID?
    ) {
        for snapshot in batch.snapshots {
            apply(snapshot, ignoringLocalVehicleID: localVehicleID)
        }
    }

    mutating func removeStaleSnapshots(
        olderThan maxAgeSeconds: TimeInterval,
        now: TimeInterval = Date().timeIntervalSince1970
    ) {
        latestSnapshotsByVehicleID = latestSnapshotsByVehicleID.filter { _, snapshot in
            now - snapshot.timestamp <= maxAgeSeconds
        }
    }
}
