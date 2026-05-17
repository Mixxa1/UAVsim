import Foundation

struct ReplayTelemetryPoint: Identifiable, Equatable {
    let id: UUID
    let timestamp: TimeInterval
    let value: Double
}

struct ReplayTelemetrySeries: Identifiable, Equatable {
    let id: UUID
    let title: String
    let unit: String
    let points: [ReplayTelemetryPoint]
}

struct ReplayTelemetrySeriesBuilder {
    private let maxPointCount = 2_000

    func buildAltitudeSeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Altitude", unit: "m", session: session, trimRange: trimRange) { $0.position.y }
    }

    func buildSpeedSeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Speed", unit: "m/s", session: session, trimRange: trimRange) { frame in
            let velocity = frame.velocity.simd
            return (velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z).squareRoot()
        }
    }

    func buildBatterySeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Battery", unit: "%", session: session, trimRange: trimRange) { $0.batteryPercent }
    }

    func buildRollSeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Roll", unit: "deg", session: session, trimRange: trimRange) {
            $0.attitude.rollRadians * 180.0 / .pi
        }
    }

    func buildPitchSeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Pitch", unit: "deg", session: session, trimRange: trimRange) {
            $0.attitude.pitchRadians * 180.0 / .pi
        }
    }

    func buildYawSeries(from session: MissionReplaySession, trimRange: ReplayTrimRange?) -> ReplayTelemetrySeries {
        buildSeries(title: "Yaw", unit: "deg", session: session, trimRange: trimRange) {
            $0.attitude.yawRadians * 180.0 / .pi
        }
    }

    private func buildSeries(
        title: String,
        unit: String,
        session: MissionReplaySession,
        trimRange: ReplayTrimRange?,
        value: (MissionReplayFrame) -> Double?
    ) -> ReplayTelemetrySeries {
        let range = trimRange?.clamped(to: session.duration)
        let filteredFrames = session.frames
            .sorted { $0.timestamp < $1.timestamp }
            .filter { frame in
                guard let range else { return true }
                return range.contains(frame.timestamp)
            }

        let sampledFrames = downsample(filteredFrames)
        let points = sampledFrames.compactMap { frame -> ReplayTelemetryPoint? in
            guard let v = value(frame), v.isFinite else { return nil }
            let timestamp = range.map { frame.timestamp - $0.startTime } ?? frame.timestamp
            return ReplayTelemetryPoint(id: frame.id, timestamp: timestamp, value: v)
        }

        return ReplayTelemetrySeries(id: UUID(), title: title, unit: unit, points: points)
    }

    private func downsample(_ frames: [MissionReplayFrame]) -> [MissionReplayFrame] {
        guard frames.count > maxPointCount else { return frames }
        let step = Double(frames.count - 1) / Double(maxPointCount - 1)
        var sampled: [MissionReplayFrame] = []
        sampled.reserveCapacity(maxPointCount)
        for index in 0..<maxPointCount {
            let sourceIndex = min(frames.count - 1, Int((Double(index) * step).rounded()))
            sampled.append(frames[sourceIndex])
        }
        return sampled
    }
}
