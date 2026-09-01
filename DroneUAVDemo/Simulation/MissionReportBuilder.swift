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

        let rfSummary = buildRFSummary(
            frames.compactMap(\.rfSnapshot),
            artifacts: session.rfArtifacts
        )

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
            missionRelatedEventCount: missionRelatedEventCount,
            rf: rfSummary
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
        if let rf = summary.rf {
            lines.append("")
            lines.append("RF control link:")
            lines.append("- Samples: \(rf.sampleCount)")
            lines.append("- Minimum RSSI: \(fmtOptional(rf.minimumRSSIDBm)) dBm")
            lines.append("- Minimum SINR: \(fmtOptional(rf.minimumSINRDB)) dB")
            lines.append("- Minimum margin: \(fmtOptional(rf.minimumLinkMarginDB)) dB")
            lines.append("- Mean PER: \(fmtPercent(rf.averagePacketErrorRate))")
            lines.append("- Mean delivery: \(fmtPercent(rf.averageDeliveryRatio))")
            lines.append("- Maximum command age: \(fmt1(rf.maximumCommandAgeSeconds)) s")
            lines.append("- Retry attempts: \(rf.retryAttempts)")
            lines.append("- TTL expired: \(rf.expiredPackets)")
            lines.append("- Back-pressure samples: \(rf.backpressureSampleCount)")
            lines.append("- Lost samples: \(rf.lostSampleCount)")
            if let baselineBucketCount = rf.baselineBucketCount {
                lines.append("- Calibration baseline buckets: \(baselineBucketCount)")
            }
            if let acceptanceScenarioCount = rf.acceptanceScenarioCount,
               let acceptancePassedCount = rf.acceptancePassedCount {
                lines.append("- Acceptance suite: \(acceptancePassedCount)/\(acceptanceScenarioCount) passed")
            }
            if let qosPolicyCount = rf.qosPolicyCount {
                lines.append("- QoS policies captured: \(qosPolicyCount)")
            }
            if let performanceGateCount = rf.performanceGateCount,
               let performanceGatePassedCount = rf.performanceGatePassedCount {
                lines.append("- RF scale gates: \(performanceGatePassedCount)/\(performanceGateCount) passed")
            }
        }
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

    private func buildRFSummary(
        _ snapshots: [MissionReplayRFSnapshot],
        artifacts: MissionReplayRFArtifacts?
    ) -> MissionReportRFSummary? {
        guard !snapshots.isEmpty || artifacts != nil else { return nil }
        let rssi = snapshots.compactMap(\.rssiDBm)
        let sinr = snapshots.compactMap(\.sinrDB)
        let margins = snapshots.compactMap(\.linkMarginDB)
        let per = snapshots.compactMap(\.packetErrorRate)
        let delivery = snapshots.compactMap(\.deliveryRatio)
        let utilization = snapshots.compactMap(\.sharedChannelUtilization)
        return MissionReportRFSummary(
            sampleCount: snapshots.count,
            minimumRSSIDBm: rssi.min(),
            minimumSINRDB: sinr.min(),
            minimumLinkMarginDB: margins.min(),
            averagePacketErrorRate: average(per),
            averageDeliveryRatio: average(delivery),
            maximumCommandAgeSeconds: snapshots.map(\.commandAgeSeconds).max() ?? 0,
            maximumQueueDepth: snapshots.compactMap(\.queueDepth).max() ?? 0,
            retryAttempts: snapshots.compactMap(\.retryAttempts).max() ?? 0,
            expiredPackets: snapshots.compactMap(\.expiredPackets).max() ?? 0,
            maximumSharedChannelUtilization: utilization.max(),
            backpressureSampleCount: snapshots.filter {
                !$0.backpressuredLinkRawValues.isEmpty
            }.count,
            lostSampleCount: snapshots.filter {
                $0.controlAvailabilityRawValue == RFControlLinkAvailability.lost.rawValue
            }.count,
            baselineBucketCount: artifacts?.calibrationReport?.buckets.count,
            acceptanceScenarioCount: artifacts?.acceptanceResults.count,
            acceptancePassedCount: artifacts?.acceptanceResults.filter(\.passed).count,
            qosPolicyCount: artifacts?.qosConfiguration?.linkPolicies.count,
            performanceGateCount: artifacts?.performanceResults?.count,
            performanceGatePassedCount: artifacts?.performanceResults?.filter(\.passed).count
        )
    }

    private func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func fmtOptional(_ value: Double?) -> String {
        value.map(fmt1) ?? "n/a"
    }

    private func fmtPercent(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(fmt1(value * 100)) %"
    }
}
