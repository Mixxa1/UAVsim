import Foundation

struct OnlineVehicleInterpolatedState: Codable, Equatable {
    var vehicleID: UUID
    var participantID: UUID
    var participantName: String
    var pose: OnlineVehiclePose
    var kinematics: OnlineVehicleKinematics
    var isArmed: Bool
    var flightModeLabel: String
    var sourceSnapshotAge: TimeInterval
}

struct OnlineVehicleSnapshotInterpolationBuffer: Codable, Equatable {
    var vehicleID: UUID
    var snapshots: [OnlineVehicleStateSnapshot] = []
    var maxSnapshots: Int = 6

    mutating func push(_ snapshot: OnlineVehicleStateSnapshot) {
        if let latest = snapshots.last,
           snapshot.sequenceNumber <= latest.sequenceNumber {
            return
        }
        snapshots.append(snapshot)
        if snapshots.count > maxSnapshots {
            snapshots.removeFirst(snapshots.count - maxSnapshots)
        }
    }

    mutating func removeStaleSnapshots(olderThan maxAgeSeconds: TimeInterval, now: TimeInterval) {
        snapshots.removeAll { now - $0.timestamp > maxAgeSeconds }
    }

    func interpolatedState(now: TimeInterval, interpolationDelay: TimeInterval = 0.15) -> OnlineVehicleInterpolatedState? {
        guard !snapshots.isEmpty else { return nil }

        let renderTime = now - interpolationDelay

        if snapshots.count == 1 {
            let s = snapshots[0]
            return OnlineVehicleInterpolatedState(
                vehicleID: s.vehicleID,
                participantID: s.participantID,
                participantName: s.participantName,
                pose: s.pose,
                kinematics: s.kinematics,
                isArmed: s.isArmed,
                flightModeLabel: s.flightModeLabel,
                sourceSnapshotAge: now - s.timestamp
            )
        }

        if renderTime <= snapshots[0].timestamp {
            let s = snapshots[0]
            return OnlineVehicleInterpolatedState(
                vehicleID: s.vehicleID,
                participantID: s.participantID,
                participantName: s.participantName,
                pose: s.pose,
                kinematics: s.kinematics,
                isArmed: s.isArmed,
                flightModeLabel: s.flightModeLabel,
                sourceSnapshotAge: now - s.timestamp
            )
        }

        if renderTime >= snapshots[snapshots.count - 1].timestamp {
            let s = snapshots[snapshots.count - 1]
            return OnlineVehicleInterpolatedState(
                vehicleID: s.vehicleID,
                participantID: s.participantID,
                participantName: s.participantName,
                pose: s.pose,
                kinematics: s.kinematics,
                isArmed: s.isArmed,
                flightModeLabel: s.flightModeLabel,
                sourceSnapshotAge: now - s.timestamp
            )
        }

        var previous = snapshots[0]
        var next = snapshots[snapshots.count - 1]

        for index in 0..<(snapshots.count - 1) {
            let a = snapshots[index]
            let b = snapshots[index + 1]
            if a.timestamp <= renderTime && renderTime <= b.timestamp {
                previous = a
                next = b
                break
            }
        }

        let duration = max(next.timestamp - previous.timestamp, 0.0001)
        let t = min(max((renderTime - previous.timestamp) / duration, 0.0), 1.0)

        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }

        let pose = OnlineVehiclePose(
            positionX: lerp(previous.pose.positionX, next.pose.positionX),
            positionY: lerp(previous.pose.positionY, next.pose.positionY),
            positionZ: lerp(previous.pose.positionZ, next.pose.positionZ),
            yaw: lerp(previous.pose.yaw, next.pose.yaw),
            pitch: lerp(previous.pose.pitch, next.pose.pitch),
            roll: lerp(previous.pose.roll, next.pose.roll)
        )

        let kinematics = OnlineVehicleKinematics(
            velocityX: lerp(previous.kinematics.velocityX, next.kinematics.velocityX),
            velocityY: lerp(previous.kinematics.velocityY, next.kinematics.velocityY),
            velocityZ: lerp(previous.kinematics.velocityZ, next.kinematics.velocityZ),
            speedMetersPerSecond: lerp(previous.kinematics.speedMetersPerSecond, next.kinematics.speedMetersPerSecond),
            altitudeMeters: lerp(previous.kinematics.altitudeMeters, next.kinematics.altitudeMeters)
        )

        return OnlineVehicleInterpolatedState(
            vehicleID: next.vehicleID,
            participantID: next.participantID,
            participantName: next.participantName,
            pose: pose,
            kinematics: kinematics,
            isArmed: next.isArmed,
            flightModeLabel: next.flightModeLabel,
            sourceSnapshotAge: now - next.timestamp
        )
    }
}

struct OnlineVehicleInterpolationStore: Equatable {
    var buffersByVehicleID: [UUID: OnlineVehicleSnapshotInterpolationBuffer] = [:]

    mutating func apply(
        _ snapshot: OnlineVehicleStateSnapshot,
        ignoringLocalVehicleID localVehicleID: UUID?
    ) {
        guard snapshot.vehicleID != localVehicleID else { return }
        if buffersByVehicleID[snapshot.vehicleID] == nil {
            buffersByVehicleID[snapshot.vehicleID] = OnlineVehicleSnapshotInterpolationBuffer(vehicleID: snapshot.vehicleID)
        }
        buffersByVehicleID[snapshot.vehicleID]?.push(snapshot)
    }

    mutating func apply(
        _ snapshotState: OnlineRemoteVehicleSnapshotState,
        ignoringLocalVehicleID localVehicleID: UUID?
    ) {
        for snapshot in snapshotState.snapshots {
            apply(snapshot, ignoringLocalVehicleID: localVehicleID)
        }
    }

    mutating func removeStaleSnapshots(olderThan maxAgeSeconds: TimeInterval, now: TimeInterval) {
        for key in buffersByVehicleID.keys {
            buffersByVehicleID[key]?.removeStaleSnapshots(olderThan: maxAgeSeconds, now: now)
        }
        buffersByVehicleID = buffersByVehicleID.filter { _, buffer in !buffer.snapshots.isEmpty }
    }

    func interpolatedStates(now: TimeInterval) -> [OnlineVehicleInterpolatedState] {
        buffersByVehicleID.values.compactMap { $0.interpolatedState(now: now) }
            .sorted {
                if $0.participantName == $1.participantName {
                    return $0.vehicleID.uuidString < $1.vehicleID.uuidString
                }
                return $0.participantName < $1.participantName
            }
    }
}
