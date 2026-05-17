import Foundation
import simd

struct MissionReportBuilder {
    func buildReport(from session: MissionReplaySession) -> MissionReport {
        let frames = session.frames
        let events = session.events

        let warningEvents = events.filter { $0.type == .warning }
        let warningCount = warningEvents.count

        var maxSpeed = 0.0
        var totalSpeed = 0.0
        var maxAltitude = 0.0
        var startBattery: Double?
        var minBattery: Double?

        for frame in frames {
            let v = frame.velocity.simd
            let speed = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
            if speed > maxSpeed { maxSpeed = speed }
            totalSpeed += speed
            if frame.position.y > maxAltitude { maxAltitude = frame.position.y }
            if let b = frame.batteryPercent {
                if startBattery == nil { startBattery = b }
                if minBattery == nil || b < minBattery! { minBattery = b }
            }
        }

        let avgSpeed = frames.isEmpty ? 0.0 : totalSpeed / Double(frames.count)

        let batteryUsed: Double? = {
            guard let s = startBattery, let m = minBattery else { return nil }
            return s - m
        }()

        let autopilotEventCount = events.filter {
            $0.type == .autopilotEnabled || $0.type == .autopilotDisabled
        }.count

        let missionRelatedEventCount = events.filter {
            switch $0.type {
            case .waypointReached, .missionCompleted, .missionAborted,
                 .payloadReleased, .payloadImpact:
                return true
            default:
                return false
            }
        }.count

        let summary = MissionReportSummary(
            durationSeconds: session.duration,
            frameCount: frames.count,
            eventCount: events.count,
            warningCount: warningCount,
            maxSpeedMetersPerSecond: maxSpeed,
            averageSpeedMetersPerSecond: avgSpeed,
            maxAltitudeMeters: maxAltitude,
            startBatteryPercent: startBattery,
            minBatteryPercent: minBattery,
            batteryUsedPercent: batteryUsed,
            autopilotEventCount: autopilotEventCount,
            missionRelatedEventCount: missionRelatedEventCount
        )

        return MissionReport(
            id: UUID(),
            generatedAt: Date(),
            sessionID: session.id,
            summary: summary,
            events: events,
            warnings: warningEvents,
            textSummary: buildTextSummary(summary: summary, events: events)
        )
    }

    private func fmt1(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    private func fmtBattery(_ v: Double?) -> String {
        guard let v else { return "n/a" }
        return fmt1(v)
    }

    private func buildTextSummary(summary: MissionReportSummary, events: [MissionReplayEvent]) -> String {
        var lines: [String] = []
        lines.append("BLACK BOX MISSION REPORT")
        lines.append("")
        lines.append("Flight:")
        lines.append("- Duration: \(fmt1(summary.durationSeconds)) s")
        lines.append("- Frames recorded: \(summary.frameCount)")
        lines.append("- Events: \(summary.eventCount)")
        lines.append("- Warnings: \(summary.warningCount)")
        lines.append("")
        lines.append("Performance:")
        lines.append("- Max speed: \(fmt1(summary.maxSpeedMetersPerSecond)) m/s")
        lines.append("- Average speed: \(fmt1(summary.averageSpeedMetersPerSecond)) m/s")
        lines.append("- Max altitude: \(fmt1(summary.maxAltitudeMeters)) m")
        lines.append("")
        lines.append("Battery:")
        lines.append("- Start battery: \(fmtBattery(summary.startBatteryPercent)) %")
        lines.append("- Min battery: \(fmtBattery(summary.minBatteryPercent)) %")
        lines.append("- Battery used: \(fmtBattery(summary.batteryUsedPercent)) %")
        lines.append("")
        lines.append("Autopilot:")
        lines.append("- Autopilot events: \(summary.autopilotEventCount)")
        lines.append("- Mission-related events: \(summary.missionRelatedEventCount)")
        lines.append("")
        lines.append("Events:")

        let display = Array(events.prefix(40))
        for event in display {
            lines.append("- \(fmt1(event.timestamp)) \(event.type.rawValue): \(event.message)")
        }
        if events.count > 40 {
            lines.append("- ... \(events.count - 40) more events")
        }

        return lines.joined(separator: "\n")
    }
}
