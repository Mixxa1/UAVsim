import Foundation

struct OnlineVehicleInterpolatedState: Codable, Equatable {
    var vehicleID: UUID
    var participantID: UUID
    var participantName: String
    var pose: OnlineVehiclePose
    var kinematics: OnlineVehicleKinematics
    var isArmed: Bool
    var flightModeLabel: String
    // Age is measured in receiver-local time so clock skew between sender/receiver does not inflate it.
    var sourceSnapshotAge: TimeInterval
}

// Wraps a received snapshot with the local receive time, eliminating sender-clock dependency
// from the interpolation timeline. If machines have different clocks (common on LAN), using
// snapshot.timestamp (sender clock) causes the interpolation render window to never align,
// producing a seconds-long visual lag or snapshots that never expire.
struct OnlineTimestampedSnapshot: Equatable {
    var snapshot: OnlineVehicleStateSnapshot
    var receivedAtLocalTime: TimeInterval
}

struct OnlineVehicleSnapshotInterpolationBuffer: Equatable {
    var vehicleID: UUID
    var entries: [OnlineTimestampedSnapshot] = []
    var maxEntries: Int = 8
    private var latestSequenceNumber: UInt64 = 0

    init(vehicleID: UUID) {
        self.vehicleID = vehicleID
    }

    mutating func push(_ snapshot: OnlineVehicleStateSnapshot, receivedAt: TimeInterval) {
        guard snapshot.sequenceNumber > latestSequenceNumber else { return }
        latestSequenceNumber = snapshot.sequenceNumber
        entries.append(OnlineTimestampedSnapshot(snapshot: snapshot, receivedAtLocalTime: receivedAt))
        trim(now: receivedAt)
    }

    mutating func trim(now: TimeInterval) {
        entries.removeAll { now - $0.receivedAtLocalTime > 1.0 }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    mutating func removeStaleSnapshots(olderThan maxAgeSeconds: TimeInterval, now: TimeInterval) {
        entries.removeAll { now - $0.receivedAtLocalTime > maxAgeSeconds }
    }

    func interpolatedState(now: TimeInterval, interpolationDelay: TimeInterval = 0.12) -> OnlineVehicleInterpolatedState? {
        guard !entries.isEmpty else { return nil }

        let renderTime = now - interpolationDelay

        if entries.count == 1 {
            let e = entries[0]
            return makeState(from: e.snapshot, sourceAge: now - e.receivedAtLocalTime)
        }

        if renderTime <= entries[0].receivedAtLocalTime {
            let e = entries[0]
            return makeState(from: e.snapshot, sourceAge: now - e.receivedAtLocalTime)
        }

        if renderTime >= entries[entries.count - 1].receivedAtLocalTime {
            let e = entries[entries.count - 1]
            return makeState(from: e.snapshot, sourceAge: now - e.receivedAtLocalTime)
        }

        for index in 0..<(entries.count - 1) {
            let a = entries[index]
            let b = entries[index + 1]
            if a.receivedAtLocalTime <= renderTime && renderTime <= b.receivedAtLocalTime {
                let duration = max(b.receivedAtLocalTime - a.receivedAtLocalTime, 0.0001)
                let t = min(max((renderTime - a.receivedAtLocalTime) / duration, 0.0), 1.0)
                return interpolated(from: a.snapshot, to: b.snapshot, t: t, sourceAge: now - b.receivedAtLocalTime)
            }
        }

        let last = entries[entries.count - 1]
        return makeState(from: last.snapshot, sourceAge: now - last.receivedAtLocalTime)
    }

    private func makeState(from s: OnlineVehicleStateSnapshot, sourceAge: TimeInterval) -> OnlineVehicleInterpolatedState {
        OnlineVehicleInterpolatedState(
            vehicleID: s.vehicleID,
            participantID: s.participantID,
            participantName: s.participantName,
            pose: s.pose,
            kinematics: s.kinematics,
            isArmed: s.isArmed,
            flightModeLabel: s.flightModeLabel,
            sourceSnapshotAge: sourceAge
        )
    }

    private func interpolated(
        from a: OnlineVehicleStateSnapshot,
        to b: OnlineVehicleStateSnapshot,
        t: Double,
        sourceAge: TimeInterval
    ) -> OnlineVehicleInterpolatedState {
        func lerp(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }

        let pose = OnlineVehiclePose(
            positionX: lerp(a.pose.positionX, b.pose.positionX),
            positionY: lerp(a.pose.positionY, b.pose.positionY),
            positionZ: lerp(a.pose.positionZ, b.pose.positionZ),
            yaw: lerp(a.pose.yaw, b.pose.yaw),
            pitch: lerp(a.pose.pitch, b.pose.pitch),
            roll: lerp(a.pose.roll, b.pose.roll)
        )
        let kinematics = OnlineVehicleKinematics(
            velocityX: lerp(a.kinematics.velocityX, b.kinematics.velocityX),
            velocityY: lerp(a.kinematics.velocityY, b.kinematics.velocityY),
            velocityZ: lerp(a.kinematics.velocityZ, b.kinematics.velocityZ),
            speedMetersPerSecond: lerp(a.kinematics.speedMetersPerSecond, b.kinematics.speedMetersPerSecond),
            altitudeMeters: lerp(a.kinematics.altitudeMeters, b.kinematics.altitudeMeters)
        )
        return OnlineVehicleInterpolatedState(
            vehicleID: b.vehicleID,
            participantID: b.participantID,
            participantName: b.participantName,
            pose: pose,
            kinematics: kinematics,
            isArmed: b.isArmed,
            flightModeLabel: b.flightModeLabel,
            sourceSnapshotAge: sourceAge
        )
    }
}

struct OnlineVehicleInterpolationStore: Equatable {
    var buffersByVehicleID: [UUID: OnlineVehicleSnapshotInterpolationBuffer] = [:]

    mutating func apply(
        _ snapshot: OnlineVehicleStateSnapshot,
        ignoringLocalVehicleID localVehicleID: UUID?,
        receivedAt: TimeInterval
    ) {
        guard snapshot.vehicleID != localVehicleID else { return }
        if buffersByVehicleID[snapshot.vehicleID] == nil {
            buffersByVehicleID[snapshot.vehicleID] = OnlineVehicleSnapshotInterpolationBuffer(vehicleID: snapshot.vehicleID)
        }
        buffersByVehicleID[snapshot.vehicleID]?.push(snapshot, receivedAt: receivedAt)
    }

    mutating func apply(
        _ snapshotState: OnlineRemoteVehicleSnapshotState,
        ignoringLocalVehicleID localVehicleID: UUID?,
        receivedAt: TimeInterval
    ) {
        for snapshot in snapshotState.snapshots {
            apply(snapshot, ignoringLocalVehicleID: localVehicleID, receivedAt: receivedAt)
        }
    }

    mutating func removeStaleSnapshots(olderThan maxAgeSeconds: TimeInterval, now: TimeInterval) {
        for key in buffersByVehicleID.keys {
            buffersByVehicleID[key]?.removeStaleSnapshots(olderThan: maxAgeSeconds, now: now)
        }
        buffersByVehicleID = buffersByVehicleID.filter { _, buffer in !buffer.entries.isEmpty }
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

    var totalBufferDepth: Int {
        buffersByVehicleID.values.reduce(0) { $0 + $1.entries.count }
    }
}
