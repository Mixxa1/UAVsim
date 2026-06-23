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

        // `title`/`unit` are localization keys (resolved at display time by the view), not text —
        // `id` is the separate stable matching key, unaffected by language.
        let metrics = [
            metric("duration", "replay.compare.duration", firstStats.duration, secondStats.duration, "replay.unit.seconds"),
            metric("frames", "replay.compare.frames", Double(firstStats.frameCount), Double(secondStats.frameCount), "replay.unit.frames_short"),
            metric("events", "replay.compare.events", Double(firstStats.eventCount), Double(secondStats.eventCount), ""),
            metric("warnings", "replay.compare.warnings", Double(firstStats.warningCount), Double(secondStats.warningCount), ""),
            metric("maxSpeed", "replay.compare.max_speed", firstStats.maxSpeed, secondStats.maxSpeed, "replay.unit.meters_per_second"),
            metric("averageSpeed", "replay.compare.avg_speed", firstStats.averageSpeed, secondStats.averageSpeed, "replay.unit.meters_per_second"),
            metric("maxAltitude", "replay.compare.max_altitude", firstStats.maxAltitude, secondStats.maxAltitude, "replay.unit.meters"),
            metric("batteryUsed", "replay.compare.battery_used", firstStats.batteryUsed, secondStats.batteryUsed, "replay.unit.percent")
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
        let language = L10n.currentLanguage()
        func t(_ key: String) -> String { L10n.s(key, language: language) }

        let faster: String
        if second.maxSpeed > first.maxSpeed {
            faster = t("replay.compare.summary.second_faster")
        } else if first.maxSpeed > second.maxSpeed {
            faster = t("replay.compare.summary.first_faster")
        } else {
            faster = t("replay.compare.summary.same_speed")
        }

        let duration = second.duration > first.duration ? t("replay.compare.summary.second_longer") :
            first.duration > second.duration ? t("replay.compare.summary.first_longer") : t("replay.compare.summary.same_duration")

        let battery = (second.batteryUsed ?? -1) > (first.batteryUsed ?? -1) ? t("replay.compare.summary.second_more_battery") :
            (first.batteryUsed ?? -1) > (second.batteryUsed ?? -1) ? t("replay.compare.summary.first_more_battery") : t("replay.compare.summary.battery_comparable")

        let warnings = second.warningCount > first.warningCount ? t("replay.compare.summary.second_more_warnings") :
            first.warningCount > second.warningCount ? t("replay.compare.summary.first_more_warnings") : t("replay.compare.summary.same_warnings")

        return [faster, duration, battery, warnings].joined(separator: " ")
    }
}
