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
                 .payloadReleased, .payloadImpact, .scenarioEvent:
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

    /// Regenerate presentation text in the selected app language without changing recorded data.
    func localizedReport(_ report: MissionReport) -> MissionReport {
        MissionReport(id: report.id, generatedAt: report.generatedAt, sessionID: report.sessionID,
            summary: report.summary, events: report.events, warnings: report.warnings,
            textSummary: buildTextSummary(summary: report.summary, events: report.events))
    }

    private func fmt1(_ value: Double) -> String {
        String(format: "%.1f", locale: L10n.currentLanguage().locale, value)
    }

    private func buildTextSummary(summary: MissionReportSummary, events: [MissionReplayEvent]) -> String {
        var lines = [L10n.s("replay.report.title"), "", L10n.s("blackbox.section.flight")]
        func metric(_ key: String, _ value: String) {
            lines.append("- \(L10n.s(key)): \(value)")
        }
        func section(_ key: String) {
            lines.append("")
            lines.append(L10n.s(key))
        }
        func battery(_ value: Double?) -> String {
            value.map { "\(fmt1($0)) %" } ?? L10n.s("common.na")
        }
        metric("blackbox.duration", L10n.f("common.time.seconds", summary.durationSeconds))
        metric("blackbox.frames", String(summary.frameCount))
        metric("blackbox.events", String(summary.eventCount))
        metric("blackbox.warnings", String(summary.warningCount))
        section("blackbox.section.performance")
        metric("blackbox.max_speed", L10n.f("common.speed.meters_per_second", summary.maxSpeedMetersPerSecond))
        metric("blackbox.avg_speed", L10n.f("common.speed.meters_per_second", summary.averageSpeedMetersPerSecond))
        metric("blackbox.max_alt", L10n.f("common.distance.m_precise", summary.maxAltitudeMeters))
        section("blackbox.section.battery")
        metric("blackbox.battery_start", battery(summary.startBatteryPercent))
        metric("blackbox.battery_min", battery(summary.minBatteryPercent))
        metric("blackbox.battery_used", battery(summary.batteryUsedPercent))
        section("blackbox.section.autopilot")
        metric("blackbox.autopilot_events", String(summary.autopilotEventCount))
        metric("blackbox.mission_events", String(summary.missionRelatedEventCount))
        if let rf = summary.rf {
            section("blackbox.section.radio")
            metric("blackbox.rf.samples", String(rf.sampleCount))
            metric("blackbox.rf.min_rssi", rf.minimumRSSIDBm.map { L10n.f("common.signal.dbm", $0) } ?? L10n.s("common.na"))
            metric("blackbox.rf.min_sinr", rf.minimumSINRDB.map { L10n.f("common.signal.db", $0) } ?? L10n.s("common.na"))
            metric("blackbox.rf.min_margin", rf.minimumLinkMarginDB.map { L10n.f("common.signal.db", $0) } ?? L10n.s("common.na"))
            metric("blackbox.rf.mean_per", fmtPercent(rf.averagePacketErrorRate))
            metric("blackbox.rf.delivery", fmtPercent(rf.averageDeliveryRatio))
            metric("blackbox.rf.max_age", L10n.f("common.time.seconds_precise", rf.maximumCommandAgeSeconds))
            metric("blackbox.rf.retries", String(rf.retryAttempts))
            metric("blackbox.rf.expired", String(rf.expiredPackets))
            metric("blackbox.rf.backpressure", String(rf.backpressureSampleCount))
            metric("blackbox.rf.lost", String(rf.lostSampleCount))
            if let count = rf.baselineBucketCount { metric("blackbox.rf.baseline_buckets", String(count)) }
            if let count = rf.acceptanceScenarioCount, let passed = rf.acceptancePassedCount {
                metric("blackbox.rf.acceptance", "\(passed)/\(count)")
            }
            if let count = rf.qosPolicyCount { metric("blackbox.rf.qos_policies", String(count)) }
            if let count = rf.performanceGateCount, let passed = rf.performanceGatePassedCount {
                metric("blackbox.rf.performance_gates", "\(passed)/\(count)")
            }
        }
        section("blackbox.events")
        for event in events.prefix(40) {
            lines.append("- \(L10n.f("replay.event.timestamp", event.timestamp)): \(L10n.s(event.message))")
        }
        if events.count > 40 { lines.append(L10n.f("blackbox.events.more", events.count - 40)) }
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

    private func fmtPercent(_ value: Double?) -> String {
        guard let value else { return L10n.s("common.na") }
        return "\(fmt1(value * 100)) %"
    }
}
