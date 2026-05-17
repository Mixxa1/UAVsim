import Foundation

final class MissionReplayRecorder {
    private(set) var currentSession: MissionReplaySession?
    private(set) var lastCompletedSession: MissionReplaySession?

    let minFrameInterval: TimeInterval
    let maxFrameCount: Int

    private var lastFrameTimestamp: TimeInterval?
    private var didReachFrameLimit: Bool = false

    init(
        minFrameInterval: TimeInterval = 0.1,
        maxFrameCount: Int = 30_000
    ) {
        self.minFrameInterval = minFrameInterval
        self.maxFrameCount = maxFrameCount
    }

    var isRecording: Bool { currentSession != nil }
    var currentSessionStartedAt: Date? { currentSession?.startedAt }

    func startSession(at date: Date = Date(), timestamp: TimeInterval = 0) {
        startSession(at: date, timestamp: timestamp, context: nil)
    }

    func startSession(at date: Date = Date(), timestamp: TimeInterval = 0, context: MissionReplayContextSnapshot?) {
        guard currentSession == nil else { return }
        var session = MissionReplaySession(
            id: UUID(),
            startedAt: date,
            endedAt: nil,
            frames: [],
            events: [],
            context: context
        )
        let event = MissionReplayEvent(
            id: UUID(),
            timestamp: timestamp,
            type: .sessionStarted,
            message: "Session started",
            position: nil
        )
        session.events.append(event)
        currentSession = session
        lastFrameTimestamp = nil
        didReachFrameLimit = false
    }

    func stopSession(at date: Date = Date(), timestamp: TimeInterval) {
        guard var session = currentSession else { return }
        let event = MissionReplayEvent(
            id: UUID(),
            timestamp: timestamp,
            type: .sessionStopped,
            message: "Session stopped",
            position: nil
        )
        session.events.append(event)
        session.endedAt = date
        lastCompletedSession = session
        currentSession = nil
        lastFrameTimestamp = nil
    }

    func discardCurrentSession() {
        currentSession = nil
        lastFrameTimestamp = nil
        didReachFrameLimit = false
    }

    func recordFrame(_ frame: MissionReplayFrame) {
        guard var session = currentSession else { return }

        if session.frames.count >= maxFrameCount {
            if !didReachFrameLimit {
                didReachFrameLimit = true
                let event = MissionReplayEvent(
                    id: UUID(),
                    timestamp: frame.timestamp,
                    type: .recordingLimitReached,
                    message: "Recording limit reached: \(maxFrameCount) frames",
                    position: frame.position
                )
                session.events.append(event)
                currentSession = session
            }
            return
        }

        if let last = lastFrameTimestamp {
            guard frame.timestamp - last >= minFrameInterval else { return }
        }

        session.frames.append(frame)
        currentSession = session
        lastFrameTimestamp = frame.timestamp
    }

    func recordEvent(_ event: MissionReplayEvent) {
        guard var session = currentSession else { return }
        session.events.append(event)
        currentSession = session
    }
}
