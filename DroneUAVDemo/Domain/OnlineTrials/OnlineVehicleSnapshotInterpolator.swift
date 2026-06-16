import Foundation

struct OnlineVehicleInterpolatedState: Codable, Equatable {
    var vehicleID: UUID
    var participantID: UUID
    var participantName: String
    var pose: OnlineVehiclePose
    var kinematics: OnlineVehicleKinematics
    var isArmed: Bool
    var flightModeLabel: String
    // Age measured in receiver-local time so clock skew between sender/receiver does not inflate it.
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

    // Returns true if the snapshot was accepted, false if out-of-order (for diagnostics).
    @discardableResult
    mutating func push(_ snapshot: OnlineVehicleStateSnapshot, receivedAt: TimeInterval) -> Bool {
        guard snapshot.sequenceNumber > latestSequenceNumber else { return false }
        latestSequenceNumber = snapshot.sequenceNumber
        entries.append(OnlineTimestampedSnapshot(snapshot: snapshot, receivedAtLocalTime: receivedAt))
        trim(now: receivedAt)
        return true
    }

    mutating func trim(now: TimeInterval) {
        // If the newest entry itself is stale, the buffer built up a backlog — clear it all
        // rather than trying to "play back" old data which causes the seconds-long lag.
        if let last = entries.last, now - last.receivedAtLocalTime > 1.0 {
            entries.removeAll()
            return
        }
        entries.removeAll { now - $0.receivedAtLocalTime > 1.0 }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    mutating func removeStaleSnapshots(olderThan maxAgeSeconds: TimeInterval, now: TimeInterval) {
        if let last = entries.last, now - last.receivedAtLocalTime > maxAgeSeconds {
            entries.removeAll()
            return
        }
        entries.removeAll { now - $0.receivedAtLocalTime > maxAgeSeconds }
    }

    func interpolatedState(now: TimeInterval, interpolationDelay: TimeInterval = 0.12) -> OnlineVehicleInterpolatedState? {
        guard !entries.isEmpty else { return nil }

        let renderTime = now - interpolationDelay

        if entries.count == 1 {
            let e = entries[0]
            return makeExtrapolatedOrHeld(e: e, renderTime: renderTime, now: now)
        }

        if renderTime <= entries[0].receivedAtLocalTime {
            let e = entries[0]
            return makeState(from: e.snapshot, sourceAge: now - e.receivedAtLocalTime)
        }

        if renderTime >= entries[entries.count - 1].receivedAtLocalTime {
            // renderTime is past all received data — extrapolate from latest if recent enough.
            // Pass previous entry so makeExtrapolatedOrHeld can derive velocity from position delta
            // when the sender reports zero kinematics (e.g. brief physics stall or idle state).
            let prev: OnlineTimestampedSnapshot? = entries.count >= 2 ? entries[entries.count - 2] : nil
            return makeExtrapolatedOrHeld(e: entries[entries.count - 1], prev: prev, renderTime: renderTime, now: now)
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
        let prev: OnlineTimestampedSnapshot? = entries.count >= 2 ? entries[entries.count - 2] : nil
        return makeExtrapolatedOrHeld(e: last, prev: prev, renderTime: renderTime, now: now)
    }

    // Extrapolate position by velocity when we're past the latest snapshot but it's recent.
    // Uses sender-reported kinematics; if they are all zero (sender idle or stale physics),
    // falls back to velocity computed from the two most recent received positions.
    // Clamps extrapolation to 0.10–0.15 s; holds latest pose if snapshot is older than 0.35 s.
    private func makeExtrapolatedOrHeld(
        e: OnlineTimestampedSnapshot,
        prev: OnlineTimestampedSnapshot? = nil,
        renderTime: TimeInterval,
        now: TimeInterval
    ) -> OnlineVehicleInterpolatedState {
        let age = now - e.receivedAtLocalTime
        guard age <= 0.35 else { return makeState(from: e.snapshot, sourceAge: age) }

        let extrapolationTime = max(0, renderTime - e.receivedAtLocalTime)
        guard extrapolationTime > 0, extrapolationTime <= 0.15 else {
            return makeState(from: e.snapshot, sourceAge: age)
        }

        // Prefer sender-reported velocity; fall back to position-derived velocity when zero.
        var vx = e.snapshot.kinematics.velocityX
        var vy = e.snapshot.kinematics.velocityY
        var vz = e.snapshot.kinematics.velocityZ
        let kinematicsAreZero = abs(vx) < 0.001 && abs(vy) < 0.001 && abs(vz) < 0.001
        if kinematicsAreZero, let p = prev {
            let dt = max(e.receivedAtLocalTime - p.receivedAtLocalTime, 0.001)
            vx = (e.snapshot.pose.positionX - p.snapshot.pose.positionX) / dt
            vy = (e.snapshot.pose.positionY - p.snapshot.pose.positionY) / dt
            vz = (e.snapshot.pose.positionZ - p.snapshot.pose.positionZ) / dt
        }

        let ex = extrapolationTime
        let extrapolatedPose = OnlineVehiclePose(
            positionX: e.snapshot.pose.positionX + vx * ex,
            positionY: e.snapshot.pose.positionY + vy * ex,
            positionZ: e.snapshot.pose.positionZ + vz * ex,
            yaw: e.snapshot.pose.yaw,
            pitch: e.snapshot.pose.pitch,
            roll: e.snapshot.pose.roll
        )
        return OnlineVehicleInterpolatedState(
            vehicleID: e.snapshot.vehicleID,
            participantID: e.snapshot.participantID,
            participantName: e.snapshot.participantName,
            pose: extrapolatedPose,
            kinematics: e.snapshot.kinematics,
            isArmed: e.snapshot.isArmed,
            flightModeLabel: e.snapshot.flightModeLabel,
            sourceSnapshotAge: age
        )
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
    private(set) var outOfOrderDropCount: UInt64 = 0
    // CACurrentMediaTime() timestamp of the most recently accepted snapshot from any vehicle.
    private(set) var latestReceivedAt: TimeInterval? = nil

    mutating func apply(
        _ snapshot: OnlineVehicleStateSnapshot,
        ignoringLocalVehicleID localVehicleID: UUID?,
        receivedAt: TimeInterval
    ) {
        guard snapshot.vehicleID != localVehicleID else { return }
        if buffersByVehicleID[snapshot.vehicleID] == nil {
            buffersByVehicleID[snapshot.vehicleID] = OnlineVehicleSnapshotInterpolationBuffer(vehicleID: snapshot.vehicleID)
        }
        let accepted = buffersByVehicleID[snapshot.vehicleID]?.push(snapshot, receivedAt: receivedAt) ?? true
        if accepted {
            if latestReceivedAt == nil || receivedAt > latestReceivedAt! { latestReceivedAt = receivedAt }
        } else {
            outOfOrderDropCount &+= 1
        }
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
