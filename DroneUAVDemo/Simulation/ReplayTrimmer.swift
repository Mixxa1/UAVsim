import Foundation

struct ReplayTrimmer {
    func trimmedSession(
        from session: MissionReplaySession,
        range: ReplayTrimRange
    ) -> MissionReplaySession {
        let clampedRange = range.clamped(to: session.frames.last?.timestamp ?? session.duration)
        let trimmedFrames = session.frames
            .filter { clampedRange.contains($0.timestamp) }
            .map { frame in
                MissionReplayFrame(
                    id: UUID(),
                    timestamp: frame.timestamp - clampedRange.startTime,
                    position: frame.position,
                    velocity: frame.velocity,
                    attitude: frame.attitude,
                    flightModeDescription: frame.flightModeDescription,
                    autopilotDescription: frame.autopilotDescription,
                    activeWaypointIndex: frame.activeWaypointIndex,
                    batteryPercent: frame.batteryPercent,
                    payloadStatusDescription: frame.payloadStatusDescription,
                    warningCount: frame.warningCount
                )
            }

        let trimmedEvents = session.events
            .filter { clampedRange.contains($0.timestamp) }
            .map { event in
                MissionReplayEvent(
                    id: UUID(),
                    timestamp: event.timestamp - clampedRange.startTime,
                    type: event.type,
                    message: event.message,
                    position: event.position,
                    damage: event.damage
                )
            }

        let startedAt = session.startedAt.addingTimeInterval(clampedRange.startTime)
        return MissionReplaySession(
            id: UUID(),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(clampedRange.duration),
            frames: trimmedFrames,
            events: trimmedEvents,
            context: session.context
        )
    }
}
