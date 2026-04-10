import SwiftUI

struct MissionTimelineView: View {
    let timeline: MissionTimeline?
    var compact: Bool = false

    @State private var severityFilter: MissionEventSeverityFilter = .all
    @State private var categoryFilter: MissionEventCategoryFilter = .all

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            MissionEventFilterBar(
                severityFilter: $severityFilter,
                categoryFilter: $categoryFilter
            )

            if let timeline {
                metrics(for: timeline)

                if filteredEvents(for: timeline).isEmpty {
                    emptyState("mission.timeline.empty.filtered")
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredEvents(for: timeline)) { event in
                            eventRow(event)
                        }
                    }
                }
            } else {
                emptyState("mission.timeline.empty")
            }
        }
        .panelCard()
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("mission.timeline.title")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
            Spacer(minLength: 8)
            if let timeline, let outcome = timeline.outcome {
                outcomeBadge(outcome)
            }
        }
    }

    private func metrics(for timeline: MissionTimeline) -> some View {
        HStack(spacing: 8) {
            compactMetric("mission.timeline.metric.events", value: "\(timeline.events.count)")
            compactMetric("mission.timeline.metric.warnings", value: "\(timeline.warningCount)")
            compactMetric("mission.timeline.metric.critical", value: "\(timeline.criticalCount)")
        }
    }

    private func filteredEvents(for timeline: MissionTimeline) -> [MissionEvent] {
        let source = compact ? Array(timeline.events.suffix(8)) : Array(timeline.events.suffix(20))
        return source.filter { event in
            severityFilter.includes(event.severity) &&
            categoryFilter.includes(event.category)
        }
    }

    private func eventRow(_ event: MissionEvent) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(timestampText(event.timestamp))
                    .foregroundStyle(GroundControlPalette.textSecondary)
                categoryBadge(event.category, severity: event.severity)
                Text(LocalizedStringKey(event.titleKey))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Spacer(minLength: 0)
            }

            Text(LocalizedStringKey(event.detailKey))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let waypointLabel = event.context.waypointLabel ?? nil {
                Text(waypointLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary.opacity(0.9))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func categoryBadge(_ category: MissionEventCategory, severity: MissionEventSeverity) -> some View {
        Text(LocalizedStringKey(category.titleKey))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(severityColor(severity).opacity(0.16), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(severityColor(severity).opacity(0.8), lineWidth: 1)
            )
    }

    private func compactMetric(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func emptyState(_ titleKey: String) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 12)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )
    }

    private func outcomeBadge(_ outcome: MissionOutcome) -> some View {
        Text(LocalizedStringKey(outcome.titleKey))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(outcomeColor(outcome).opacity(0.14), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(outcomeColor(outcome).opacity(0.8), lineWidth: 1)
            )
    }

    private func outcomeColor(_ outcome: MissionOutcome) -> Color {
        switch outcome {
        case .success:
            return GroundControlPalette.success
        case .partialSuccess, .returnedHome:
            return GroundControlPalette.warning
        case .aborted, .failed, .safetyTerminated:
            return GroundControlPalette.danger
        }
    }

    private func severityColor(_ severity: MissionEventSeverity) -> Color {
        switch severity {
        case .info:
            return GroundControlPalette.accent
        case .warning:
            return GroundControlPalette.warning
        case .critical:
            return GroundControlPalette.danger
        }
    }

    private func timestampText(_ date: Date) -> String {
        Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
