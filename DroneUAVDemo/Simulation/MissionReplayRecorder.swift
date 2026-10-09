import Foundation

final class MissionReplayRecorder {
    private(set) var currentSession: MissionReplaySession?
    private(set) var lastCompletedSession: MissionReplaySession?

    let minFrameInterval: TimeInterval
    let maxFrameCount: Int
    let archivesVisualAssetsInBackground: Bool
    private(set) var visualAssetArchives: [String: MissionReplayVisualAssetArchive] = [:]

    private var lastFrameTimestamp: TimeInterval?
    private var timelineOffset: TimeInterval = 0
    private var pausedAt: Date?
    var timelineTimestamp: TimeInterval {
        guard let startedAt = currentSessionStartedAt else { return 0 }
        return max(0, (pausedAt ?? Date()).timeIntervalSince(startedAt) - timelineOffset)
    }
    func pauseTimeline() { if pausedAt == nil { pausedAt = Date() } }
    func resumeTimeline(at timestamp: TimeInterval? = nil) {
        guard let startedAt = currentSessionStartedAt else { pausedAt = nil; return }
        let target = timestamp ?? timelineTimestamp
        if timestamp != nil {
            currentSession?.frames.removeAll { $0.timestamp > target }
            currentSession?.events.removeAll { $0.timestamp > target }
            currentSession?.environmentChanges?.removeAll { $0.timestamp > target }
            lastFrameTimestamp = currentSession?.frames.last?.timestamp
            didReachFrameLimit = false
            visualNodeBaselines.removeAll(); visualNodePaths.removeAll(); visualGeometryIDs.removeAll()
        }
        timelineOffset = Date().timeIntervalSince(startedAt) - target
        pausedAt = nil
        currentSession?.recordedDuration = target
    }
    private var didReachFrameLimit: Bool = false
    var visualNodeBaselines: [String: [String: MissionReplayNodeState]] = [:]
    var visualNodePaths: [String: [ObjectIdentifier: String]] = [:]
    var visualGeometryIDs: [String: [ObjectIdentifier: ObjectIdentifier]] = [:]
    var visualAssetIDs: [String: String] = [:]

    init(
        minFrameInterval: TimeInterval = 0.1,
        maxFrameCount: Int = 30_000,
        archivesVisualAssetsInBackground: Bool = false
    ) {
        self.minFrameInterval = minFrameInterval
        self.maxFrameCount = maxFrameCount
        self.archivesVisualAssetsInBackground = archivesVisualAssetsInBackground
    }

    var isRecording: Bool { currentSession != nil }
    var currentSessionStartedAt: Date? { currentSession?.startedAt }

    /// A durable snapshot of an ongoing flight. It has a fixed duration for playback, but does
    /// not stop the producer: impacts and debris after the mission result still get recorded.
    func checkpoint(at date: Date = Date()) -> MissionReplaySession? {
        guard var session = currentSession else { return nil }
        session.endedAt = date
        session.recordedDuration = timelineTimestamp
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
        session.recordedDuration = timestamp
        currentSession = session
        timelineOffset = 0; pausedAt = nil
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualGeometryIDs.removeAll()
        visualAssetIDs.removeAll()
        visualAssetArchives.removeAll()
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
        session.recordedDuration = timestamp
        lastCompletedSession = session
        currentSession = nil
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualGeometryIDs.removeAll()
        visualAssetIDs.removeAll()
        visualAssetArchives.removeAll()
        lastFrameTimestamp = nil
    }

    func discardCurrentSession() {
        currentSession = nil
        visualNodeBaselines.removeAll()
        visualNodePaths.removeAll()
        visualGeometryIDs.removeAll()
        visualAssetIDs.removeAll()
        visualAssetArchives.removeAll()
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
        currentSession?.recordedDuration = frame.timestamp
    }

    var needsFrame: Bool {
        guard let session = currentSession else { return false }
        if session.frames.count >= maxFrameCount { return !didReachFrameLimit }
        guard let lastFrameTimestamp else { return true }
        return timelineTimestamp - lastFrameTimestamp >= minFrameInterval
    }

    /// The producer archives geometry only on first encounter, not at the recording cadence.
    func hasVisualAsset(id: String) -> Bool {
        currentSession?.visualAssets?[id] != nil || visualAssetArchives[id] != nil
    }

    func registerVisualAsset(id: String, makeData: () -> Data?) -> Bool {
        guard currentSession != nil else { return false }
        if currentSession?.visualAssets?[id] != nil { return true }
        guard let data = makeData() else { return false }
        if currentSession?.visualAssets == nil { currentSession?.visualAssets = [:] }
        currentSession?.visualAssets?[id] = data
        return true
    }

    /// The scene adapter hands over a detached, immutable copy. Its archive is produced on a
    /// worker, never by reading the live scene there. Persistence receives these same futures
    /// alongside a value snapshot, so even an immediate exit waits for all referenced geometry.
    func registerDeferredVisualAsset(id: String, makeData: @escaping @Sendable () -> Data?) {
        guard isRecording, !hasVisualAsset(id: id) else { return }
        visualAssetArchives[id] = MissionReplayVisualAssetArchive(makeData: makeData)
    }

    func recordEnvironment(_ context: MissionReplayContextSnapshot, at timestamp: TimeInterval) {
        guard let session = currentSession else { return }
        guard context != (session.environmentChanges?.last?.context ?? session.context) else { return }
        if currentSession?.environmentChanges == nil { currentSession?.environmentChanges = [] }
        currentSession?.environmentChanges?.append(MissionReplayEnvironmentChange(timestamp: timestamp, context: context))
    }

    func recordEvent(_ event: MissionReplayEvent) {
        currentSession?.events.append(event)
    }
}

/// One archive owns one immutable source and publishes its Data once. Readers can resolve it
/// from the persistence queue; no completion callback ever mutates the live recorder.
final class MissionReplayVisualAssetArchive: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "uavsim.replay.asset-archives", qos: .utility)
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var result: Data?

    init(makeData: @escaping @Sendable () -> Data?) {
        completion.enter()
        Self.queue.async { [self] in
            let data = autoreleasepool(invoking: makeData)
            lock.lock(); result = data; lock.unlock()
            completion.leave()
        }
    }

    func resolvedData() -> Data? {
        completion.wait()
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
