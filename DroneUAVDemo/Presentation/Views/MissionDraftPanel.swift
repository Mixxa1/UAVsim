import SwiftUI
import simd

private struct ConstraintEditorField: View {
    let titleKey: String
    let unitKey: String
    let value: Binding<Double>
    let disabled: Bool

    @State private var draftText = ""
    @FocusState private var isFocused: Bool

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 8)
            TextField("", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
                .disabled(disabled)
                .focused($isFocused)
                .onAppear(perform: syncFromValue)
                .onChange(of: value.wrappedValue) { _ in
                    guard !isFocused else {
                        return
                    }
                    syncFromValue()
                }
                .onChange(of: draftText) { newValue in
                    guard isFocused,
                          let parsedValue = parse(newValue) else {
                        return
                    }
                    value.wrappedValue = parsedValue
                }
                .onChange(of: isFocused) { focused in
                    if !focused {
                        commitOrRevert()
                    }
                }
                .onSubmit(commitOrRevert)
                .controllerTextInputTarget(
                    id: "\(titleKey).constraint",
                    title: NSLocalizedString(titleKey, comment: ""),
                    currentText: { draftText },
                    onCommit: { text in
                        draftText = text
                        commitOrRevert()
                    }
                )
            Text(LocalizedStringKey(unitKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private func syncFromValue() {
        draftText = Self.formatter.string(from: NSNumber(value: value.wrappedValue)) ?? "0"
    }

    private func commitOrRevert() {
        guard let parsedValue = parse(draftText) else {
            syncFromValue()
            return
        }
        value.wrappedValue = parsedValue
        syncFromValue()
    }

    private func parse(_ text: String) -> Double? {
        let sanitized = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            return nil
        }
        return Double(sanitized)
    }
}

struct MissionDraftPanel: View {
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let missionStatus: MissionStatusSnapshot
    let onRemoveLastWaypoint: () -> Void
    let onClearRoute: () -> Void
    let onClearZones: () -> Void
    let onSetZoneRadius: (MissionZoneType, Float) -> Void
    let onSetMinimumAltitude: (Float) -> Void
    let onSetMaximumAltitude: (Float) -> Void
    let onSetMinimumSpeed: (Float) -> Void
    let onSetMaximumSpeed: (Float) -> Void
    let onPrepareMission: () -> Void
    let onStartMission: () -> Void
    let onPauseMission: () -> Void
    let onResumeMission: () -> Void
    let onAbortMission: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            routeSection
            sectionDivider
            zoneSection
            sectionDivider
            constraintsSection
            sectionDivider
            missionSection
            sectionDivider
            actionSection
        }
        .panelCard()
    }

    private var draftEditingLocked: Bool {
        executionState.status == .running || executionState.status == .paused
    }

    private var routeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("tactical.map.section.route")
            HStack(spacing: 8) {
                compactMetric("tactical.map.metric.waypoints", value: "\(state.workingDraft.waypoints.count)")
                compactMetric("tactical.map.metric.segments", value: "\(state.previewRoute?.segmentCount ?? 0)")
                compactMetric("tactical.map.metric.route_distance", value: routeDistanceText)
            }

            if state.workingDraft.waypoints.isEmpty {
                Text("tactical.map.route.empty")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(state.workingDraft.waypoints.suffix(4))) { waypoint in
                        waypointBadge(for: waypoint)
                    }
                }
            }

            missionPlanSummary
        }
    }

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("tactical.map.section.zones")
            zoneControl(type: .dropZone)
            zoneControl(type: .noFlyZone)
        }
    }

    private var missionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("mission.panel.section.execution")
            summaryRow("mission.status.field.plan", value: localized(missionStatus.planStatus.titleKey))
            summaryRow("mission.status.field.execution", value: localized(missionStatus.executionStatus.titleKey))

            VStack(alignment: .leading, spacing: 8) {
                actionButton("mission.panel.action.prepare", tint: GroundControlPalette.accent, action: onPrepareMission)
                    .disabled(!missionStatus.canPrepare)
                HStack(spacing: 8) {
                    actionButton("mission.panel.action.start", tint: GroundControlPalette.success, action: onStartMission)
                        .disabled(!missionStatus.canStart)
                    actionButton("mission.panel.action.pause", tint: GroundControlPalette.warning, action: onPauseMission)
                        .disabled(!missionStatus.canPause)
                }
                HStack(spacing: 8) {
                    actionButton("mission.panel.action.resume", tint: GroundControlPalette.accent, action: onResumeMission)
                        .disabled(!missionStatus.canResume)
                    actionButton("mission.panel.action.abort", tint: GroundControlPalette.danger, action: onAbortMission)
                        .disabled(!missionStatus.canAbort)
                }
            }
        }
    }

    private var constraintsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("mission.panel.section.constraints")
            constraintField(
                titleKey: "mission.constraints.altitude.minimum",
                value: Binding(
                    get: { Double(state.workingDraft.constraints.altitude.minimumMeters) },
                    set: { onSetMinimumAltitude(Float($0)) }
                ),
                unitKey: "mission.constraints.unit.meters"
            )
            constraintField(
                titleKey: "mission.constraints.altitude.maximum",
                value: Binding(
                    get: { Double(state.workingDraft.constraints.altitude.maximumMeters) },
                    set: { onSetMaximumAltitude(Float($0)) }
                ),
                unitKey: "mission.constraints.unit.meters"
            )
            constraintField(
                titleKey: "mission.constraints.speed.minimum",
                value: Binding(
                    get: { Double(state.workingDraft.constraints.speed.minimumMetersPerSecond) },
                    set: { onSetMinimumSpeed(Float($0)) }
                ),
                unitKey: "mission.constraints.unit.speed"
            )
            constraintField(
                titleKey: "mission.constraints.speed.maximum",
                value: Binding(
                    get: { Double(state.workingDraft.constraints.speed.maximumMetersPerSecond) },
                    set: { onSetMaximumSpeed(Float($0)) }
                ),
                unitKey: "mission.constraints.unit.speed"
            )
            Text("mission.constraints.hint")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("tactical.map.section.actions")
            HStack(spacing: 8) {
                actionButton("tactical.map.action.remove_last_waypoint", tint: GroundControlPalette.borderStrong, action: onRemoveLastWaypoint)
                    .disabled(draftEditingLocked || state.workingDraft.waypoints.isEmpty)
                actionButton("tactical.map.action.clear_route", tint: GroundControlPalette.borderStrong, action: onClearRoute)
                    .disabled(draftEditingLocked || state.workingDraft.waypoints.isEmpty)
            }
            actionButton("tactical.map.action.clear_zones", tint: GroundControlPalette.borderStrong, action: onClearZones)
                .disabled(draftEditingLocked || state.workingDraft.zones.isEmpty)
        }
    }

    private func zoneControl(type: MissionZoneType) -> some View {
        let matchingZones = state.workingDraft.zones.filter { $0.type == type }
        let zone = matchingZones.last
        let zoneCount = matchingZones.count
        let maxRadius = state.workingDraft.constraints.maximumZoneRadius(for: state.viewport)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(type.titleKey))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Spacer(minLength: 8)
                Text(zoneBadgeTitle(type: type, zoneCount: zoneCount))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(zone == nil ? GroundControlPalette.textSecondary : GroundControlPalette.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((zone == nil ? GroundControlPalette.inset : GroundControlPalette.warning.opacity(0.14)), in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke((zone == nil ? GroundControlPalette.border : GroundControlPalette.warning.opacity(0.72)), lineWidth: 1)
                    )
            }

            if let zone {
                Slider(
                    value: Binding(
                        get: { Double(zone.radius) },
                        set: { onSetZoneRadius(type, Float($0)) }
                    ),
                    in: Double(state.workingDraft.constraints.minimumZoneRadius)...Double(maxRadius),
                    step: 0.5
                )
                .disabled(draftEditingLocked)
                Text(
                    zoneDescription(
                        for: type,
                        zone: zone,
                        zoneCount: zoneCount
                    )
                )
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
            } else {
                Text("tactical.map.zone.empty")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    private func zoneBadgeTitle(type: MissionZoneType, zoneCount: Int) -> String {
        guard zoneCount > 0 else {
            return String(localized: "mission.status.value.none")
        }

        if type == .noFlyZone {
            return "\(zoneCount)x"
        }

        return String(localized: "mission.plan.status.ready")
    }

    private func zoneDescription(
        for type: MissionZoneType,
        zone: MissionZone,
        zoneCount: Int
    ) -> String {
        if type == .noFlyZone && zoneCount > 1 {
            return String(
                format: String(localized: "tactical.map.zone.radius.value.multiple"),
                zone.radius,
                zone.center.x,
                zone.center.y,
                zoneCount
            )
        }

        return String(
            format: String(localized: "tactical.map.zone.radius.value"),
            zone.radius,
            zone.center.x,
            zone.center.y
        )
    }

    private func waypointColor(_ waypoint: MissionWaypoint) -> Color {
        if executionState.waypointProgress.contains(where: { $0.target.waypointID == waypoint.id && $0.state == .completed }) {
            return GroundControlPalette.success
        }
        if executionState.activeTarget?.waypointID == waypoint.id {
            return GroundControlPalette.accent
        }
        return GroundControlPalette.textPrimary
    }

    private func sectionTitle(_ titleKey: String) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(GroundControlPalette.border.opacity(0.65))
            .frame(height: 1)
    }

    private func summaryRow(_ titleKey: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    private var missionPlanSummary: some View {
        Group {
            if let missionPlan {
                Text(
                    String(
                        format: localized("mission.panel.plan.summary"),
                        missionPlan.waypoints.count,
                        missionPlan.routePoints.count
                    )
                )
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
            } else {
                Text("mission.panel.plan.empty")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    private func compactMetric(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
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

    private func waypointBadge(for waypoint: MissionWaypoint) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(waypoint.label)
                .foregroundStyle(waypointColor(waypoint))
            Text(format(point: waypoint.position))
                .foregroundStyle(GroundControlPalette.textSecondary)
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

    private func constraintField(
        titleKey: String,
        value: Binding<Double>,
        unitKey: String
    ) -> some View {
        ConstraintEditorField(
            titleKey: titleKey,
            unitKey: unitKey,
            value: value,
            disabled: draftEditingLocked
        )
    }

    private func actionButton(
        _ titleKey: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: titleKey, action: action)
    }

    private var routeDistanceText: String {
        guard let previewRoute = state.previewRoute else {
            return localized("tactical.map.preview.none")
        }
        return String(format: "%.0f m", previewRoute.totalLengthMeters)
    }

    private func format(point: SIMD2<Float>) -> String {
        String(format: "%.1f / %.1f", point.x, point.y)
    }

    private func localized(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
}

extension View {
    func panelCard() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(GroundControlPalette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
    }
}
