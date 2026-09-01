import Foundation

final class MissionReplayPlayer: ObservableObject {
    @Published private(set) var isLoaded: Bool = false
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var playbackSpeed: Double = 1.0
    @Published private(set) var currentFrame: MissionReplayFrame?

    static let allowedSpeeds: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0]

    private var frames: [MissionReplayFrame] = []
    private var framePointer: Int = 0

    // MARK: - Lifecycle

    func load(session: MissionReplaySession) {
        frames = session.frames.sorted { $0.timestamp < $1.timestamp }
        duration = frames.last?.timestamp ?? session.duration
        currentTime = 0
        framePointer = 0
        currentFrame = interpolatedFrame(at: currentTime)
        playbackSpeed = 1.0
        isLoaded = true
        isPlaying = false
    }

    func unload() {
        isPlaying = false
        frames = []
        framePointer = 0
        currentTime = 0
        duration = 0
        playbackSpeed = 1.0
        currentFrame = nil
        isLoaded = false
    }

    // MARK: - Transport

    func play() {
        guard isLoaded, !frames.isEmpty else { return }
        isPlaying = true
    }

    func pause() {
        isPlaying = false
    }

    func stop() {
        isPlaying = false
        currentTime = 0
        framePointer = 0
        currentFrame = interpolatedFrame(at: currentTime)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    // MARK: - Speed

    func speedUp() {
        let speeds = Self.allowedSpeeds
        guard let idx = speeds.firstIndex(of: playbackSpeed), idx < speeds.count - 1 else { return }
        playbackSpeed = speeds[idx + 1]
    }

    func slowDown() {
        let speeds = Self.allowedSpeeds
        guard let idx = speeds.firstIndex(of: playbackSpeed), idx > 0 else { return }
        playbackSpeed = speeds[idx - 1]
    }

    func setPlaybackSpeed(_ speed: Double) {
        let nearest = Self.allowedSpeeds.min { abs($0 - speed) < abs($1 - speed) } ?? 1.0
        playbackSpeed = nearest
    }

    // MARK: - Seek

    func seek(to time: TimeInterval) {
        guard isLoaded else { return }
        currentTime = max(0, min(time, duration))
        updateFramePointerBinarySearch()
        currentFrame = interpolatedFrame(at: currentTime)
    }

    // MARK: - Tick

    func update(deltaTime: TimeInterval) {
        guard isPlaying, !frames.isEmpty else { return }

        currentTime += deltaTime * playbackSpeed
        if currentTime >= duration {
            currentTime = duration
            isPlaying = false
        }

        advanceFramePointerForward()
        currentFrame = interpolatedFrame(at: currentTime)
    }

    // MARK: - Frame pointer

    private func advanceFramePointerForward() {
        while framePointer + 1 < frames.count,
              frames[framePointer + 1].timestamp <= currentTime {
            framePointer += 1
        }
    }

    private func updateFramePointerBinarySearch() {
        guard !frames.isEmpty else { return }
        var lo = 0
        var hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].timestamp <= currentTime {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        framePointer = lo
    }

    private func interpolatedFrame(at time: TimeInterval) -> MissionReplayFrame? {
        guard !frames.isEmpty else { return nil }
        guard framePointer + 1 < frames.count else { return frames[framePointer] }

        let start = frames[framePointer]
        let end = frames[framePointer + 1]
        let span = max(0.0001, end.timestamp - start.timestamp)
        let t = max(0, min(1, (time - start.timestamp) / span))
        let chosen = t < 0.5 ? start : end

        return MissionReplayFrame(
            id: chosen.id,
            timestamp: time,
            position: interpolate(start.position, end.position, t),
            velocity: interpolate(start.velocity, end.velocity, t),
            attitude: MissionAttitudeSnapshot(
                rollRadians: interpolateAngle(start.attitude.rollRadians, end.attitude.rollRadians, t),
                pitchRadians: interpolateAngle(start.attitude.pitchRadians, end.attitude.pitchRadians, t),
                yawRadians: interpolateAngle(start.attitude.yawRadians, end.attitude.yawRadians, t)
            ),
            flightModeDescription: chosen.flightModeDescription,
            autopilotDescription: chosen.autopilotDescription,
            activeWaypointIndex: chosen.activeWaypointIndex,
            batteryPercent: interpolateOptional(start.batteryPercent, end.batteryPercent, t),
            payloadStatusDescription: chosen.payloadStatusDescription,
            warningCount: max(start.warningCount, end.warningCount),
            rfSnapshot: chosen.rfSnapshot
        )
    }

    private func interpolate(_ a: CodableVector3D, _ b: CodableVector3D, _ t: Double) -> CodableVector3D {
        CodableVector3D(
            x: a.x + (b.x - a.x) * t,
            y: a.y + (b.y - a.y) * t,
            z: a.z + (b.z - a.z) * t
        )
    }

    private func interpolateOptional(_ a: Double?, _ b: Double?, _ t: Double) -> Double? {
        guard let a, let b else { return a ?? b }
        return a + (b - a) * t
    }

    private func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let delta = atan2(sin(b - a), cos(b - a))
        return a + delta * t
    }
}
