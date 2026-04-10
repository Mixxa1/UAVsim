import SwiftUI

enum MissionEventSeverityFilter: String, CaseIterable, Identifiable {
    case all
    case info
    case warning
    case critical

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all:
            return "mission.timeline.filter.severity.all"
        case .info:
            return "mission.timeline.filter.severity.info"
        case .warning:
            return "mission.timeline.filter.severity.warning"
        case .critical:
            return "mission.timeline.filter.severity.critical"
        }
    }

    func includes(_ severity: MissionEventSeverity) -> Bool {
        switch self {
        case .all:
            return true
        case .info:
            return severity == .info
        case .warning:
            return severity == .warning
        case .critical:
            return severity == .critical
        }
    }
}

enum MissionEventCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case planning
    case operatorAction
    case execution
    case safety
    case failsafe
    case payload
    case diagnostics

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .all:
            return "mission.timeline.filter.category.all"
        case .planning:
            return MissionEventCategory.planning.titleKey
        case .operatorAction:
            return MissionEventCategory.operatorAction.titleKey
        case .execution:
            return MissionEventCategory.execution.titleKey
        case .safety:
            return MissionEventCategory.safety.titleKey
        case .failsafe:
            return MissionEventCategory.failsafe.titleKey
        case .payload:
            return MissionEventCategory.payload.titleKey
        case .diagnostics:
            return MissionEventCategory.diagnostics.titleKey
        }
    }

    func includes(_ category: MissionEventCategory) -> Bool {
        switch self {
        case .all:
            return true
        case .planning:
            return category == .planning
        case .operatorAction:
            return category == .operatorAction
        case .execution:
            return category == .execution
        case .safety:
            return category == .safety
        case .failsafe:
            return category == .failsafe
        case .payload:
            return category == .payload
        case .diagnostics:
            return category == .diagnostics
        }
    }
}

struct MissionEventFilterBar: View {
    @Binding var severityFilter: MissionEventSeverityFilter
    @Binding var categoryFilter: MissionEventCategoryFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            severityRow
            categoryRow
        }
    }

    private var severityRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("mission.timeline.filter.severity")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)

                ForEach(MissionEventSeverityFilter.allCases) { item in
                    Button {
                        severityFilter = item
                    } label: {
                        Text(LocalizedStringKey(item.titleKey))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(severityFilter == item ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(severityFilter == item ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.inset)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke((severityFilter == item ? GroundControlPalette.accent : GroundControlPalette.border).opacity(0.8), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("mission.timeline.filter.category")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)

                ForEach(MissionEventCategoryFilter.allCases) { item in
                    Button {
                        categoryFilter = item
                    } label: {
                        Text(LocalizedStringKey(item.titleKey))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(categoryFilter == item ? GroundControlPalette.textPrimary : GroundControlPalette.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(categoryFilter == item ? GroundControlPalette.accent.opacity(0.16) : GroundControlPalette.inset)
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke((categoryFilter == item ? GroundControlPalette.accent : GroundControlPalette.border).opacity(0.8), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
