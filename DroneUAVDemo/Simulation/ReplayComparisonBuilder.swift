import Foundation

struct ReplayComparisonBuilder {
    func compare(
        first: MissionReplaySession,
        firstReport: MissionReport?,
        second: MissionReplaySession,
        secondReport: MissionReport?
    ) -> ReplayComparisonResult {
        let firstStats = stats(for: first, report: firstReport)
        let secondStats = stats(for: second, report: secondReport)

        let metrics = [
            metric("duration", "Duration", firstStats.duration, secondStats.duration, "s"),
            metric("frames", "Frames", Double(firstStats.frameCount), Double(secondStats.frameCount), "fr"),
            metric("events", "Events", Double(firstStats.eventCount), Double(secondStats.eventCount), ""),
            metric("warnings", "Warnings", Double(firstStats.warningCount), Double(secondStats.warningCount), ""),
            metric("maxSpeed", "Max Speed", firstStats.maxSpeed, secondStats.maxSpeed, "m/s"),
            metric("averageSpeed", "Average Speed", firstStats.averageSpeed, secondStats.averageSpeed, "m/s"),
            metric("maxAltitude", "Max Altitude", firstStats.maxAltitude, secondStats.maxAltitude, "m"),
            metric("batteryUsed", "Battery Used", firstStats.batteryUsed, secondStats.batteryUsed, "%")
        ]

        return ReplayComparisonResult(
            firstReplayID: first.id,
            secondReplayID: second.id,
            metrics: metrics,
            summaryText: summary(first: firstStats, second: secondStats)
        )
    }

    private func metric(_ id: String, _ title: String, _ first: Double?, _ second: Double?, _ unit: String) -> ReplayComparisonMetric {
        let delta: Double?
        if let first, let second {
            delta = second - first
        } else {
            delta = nil
        }
        return ReplayComparisonMetric(
            id: id,
            title: title,
            firstValue: first,
            secondValue: second,
            unit: unit,
            delta: delta
        )
    }

    private struct Stats {
        var duration: Double
        var frameCount: Int
        var eventCount: Int
        var warningCount: Int
        var maxSpeed: Double
        var averageSpeed: Double
        var maxAltitude: Double
        var batteryUsed: Double?
    }

    private func stats(for session: MissionReplaySession, report: MissionReport?) -> Stats {
        if let summary = report?.summary {
            return Stats(
                duration: summary.durationSeconds,
                frameCount: summary.frameCount,
                eventCount: summary.eventCount,
                warningCount: summary.warningCount,
                maxSpeed: summary.maxSpeedMetersPerSecond,
                averageSpeed: summary.averageSpeedMetersPerSecond,
                maxAltitude: summary.maxAltitudeMeters,
                batteryUsed: summary.batteryUsedPercent
            )
        }

        let speeds = session.frames.map { frame in
            let v = frame.velocity.simd
            return (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        }
        let maxSpeed = speeds.max() ?? 0
        let averageSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let maxAltitude = session.frames.map(\.position.y).max() ?? 0
        let batteryValues = session.frames.compactMap(\.batteryPercent)
        let batteryUsed = batteryValues.first.flatMap { start in
            batteryValues.min().map { max(0, start - $0) }
        }

        return Stats(
            duration: session.frames.last?.timestamp ?? session.duration,
            frameCount: session.frames.count,
            eventCount: session.events.count,
            warningCount: session.events.filter { $0.type == .warning }.count,
            maxSpeed: maxSpeed,
            averageSpeed: averageSpeed,
            maxAltitude: maxAltitude,
            batteryUsed: batteryUsed
        )
    }

    private func summary(first: Stats, second: Stats) -> String {
        let faster: String
        if second.maxSpeed > first.maxSpeed {
            faster = "Second replay reached a higher max speed."
        } else if first.maxSpeed > second.maxSpeed {
            faster = "First replay reached a higher max speed."
        } else {
            faster = "Both replays reached the same max speed."
        }

        let duration = second.duration > first.duration ? "Second replay is longer." :
            first.duration > second.duration ? "First replay is longer." : "Both replays have the same duration."

        let battery = (second.batteryUsed ?? -1) > (first.batteryUsed ?? -1) ? "Second replay used more battery." :
            (first.batteryUsed ?? -1) > (second.batteryUsed ?? -1) ? "First replay used more battery." : "Battery use is comparable or unavailable."

        let warnings = second.warningCount > first.warningCount ? "Second replay has more warnings." :
            first.warningCount > second.warningCount ? "First replay has more warnings." : "Warning counts are equal."

        return [faster, duration, battery, warnings].joined(separator: " ")
    }
}
