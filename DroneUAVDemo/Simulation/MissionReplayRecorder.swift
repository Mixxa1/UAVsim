import Foundation

final class MissionReplayRecorder {
    private(set) var currentSession: MissionReplaySession?
    private(set) var lastCompletedSession: MissionReplaySession?

    let minFrameInterval: TimeInterval
    let maxFrameCount: Int

    private var lastFrameTimestamp: TimeInterval?
    private var didReachFrameLimit: Bool = false
    var visualNodeBaselines: [String: [String: MissionReplayNodeState]] = [:]
    var visualNodePaths: [String: [ObjectIdentifier: String]] = [:]
    var visualAssetIDs: [String: String] = [:]

    init(
        minFrameInterval: TimeInterval = 0.1,
        maxFrameCount: Int = 30_000
    ) {
        self.minFrameInterval = minFrameInterval
        self.maxFrameCount = maxFrameCount
    }

    var isRecording: Bool { currentSession != nil }
    var currentSessionStartedAt: Date? { currentSession?.startedAt }

    /// A durable snapshot of an ongoing flight. It has a fixed duration for playback, but does
    /// not stop the producer: impacts and debris after the mission result still get recorded.
    func checkpoint(at date: Date = Date()) -> MissionReplaySession? {
        guard var session = currentSession else { return nil }
        session.endedAt = date
        return session
    }

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
            message: L10n.s("replay.event.session_started", language: L10n.currentLanguage()),
            position: nil
        )
        session.events.append(event)
        currentSession = session
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualAssetIDs.removeAll()
        lastFrameTimestamp = nil
        didReachFrameLimit = false
    }

    func stopSession(at date: Date = Date(), timestamp: TimeInterval) {
        guard var session = currentSession else { return }
        let event = MissionReplayEvent(
            id: UUID(),
            timestamp: timestamp,
            type: .sessionStopped,
            message: L10n.s("replay.event.session_stopped", language: L10n.currentLanguage()),
            position: nil
        )
        session.events.append(event)
        session.endedAt = date
        lastCompletedSession = session
        currentSession = nil
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualAssetIDs.removeAll()
        lastFrameTimestamp = nil
    }

    func discardCurrentSession() {
        currentSession = nil
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualAssetIDs.removeAll()
        lastFrameTimestamp = nil
        didReachFrameLimit = false
    }

    func updateRFArtifacts(_ artifacts: MissionReplayRFArtifacts) {
        currentSession?.rfArtifacts = artifacts
    }

    func recordFrame(_ frame: MissionReplayFrame, force: Bool = false) {
        guard let count = currentSession?.frames.count else { return }

        if count >= maxFrameCount {
            if !didReachFrameLimit {
                didReachFrameLimit = true
                let event = MissionReplayEvent(
                    id: UUID(),
                    timestamp: frame.timestamp,
                    type: .recordingLimitReached,
                    message: L10n.f("replay.event.recording_limit_reached", language: L10n.currentLanguage(), maxFrameCount),
                    position: frame.position
                )
                currentSession?.events.append(event)
            }
            return
        }

        if !force, let last = lastFrameTimestamp {
            guard frame.timestamp - last >= minFrameInterval else { return }
        }

        currentSession?.frames.append(frame)
        lastFrameTimestamp = frame.timestamp
    }

    var needsFrame: Bool {
        guard let session = currentSession else { return false }
        if session.frames.count >= maxFrameCount { return !didReachFrameLimit }
        guard let lastFrameTimestamp else { return true }
        return Date().timeIntervalSince(session.startedAt) - lastFrameTimestamp >= minFrameInterval
    }

    /// The producer archives geometry only on first encounter, not at the recording cadence.
    func registerVisualAsset(id: String, makeData: () -> Data?) -> Bool {
        guard currentSession != nil else { return false }
        if currentSession?.visualAssets?[id] != nil { return true }
        guard let data = makeData() else { return false }
        if currentSession?.visualAssets == nil { currentSession?.visualAssets = [:] }
        currentSession?.visualAssets?[id] = data
        return true
    }

    func recordEvent(_ event: MissionReplayEvent) {
        currentSession?.events.append(event)
    }
}
