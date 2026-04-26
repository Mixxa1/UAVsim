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
                .onChange(of: value.wrappedValue) { _, _ in
                    guard !isFocused else {
                        return
                    }
                    syncFromValue()
                }
                .onChange(of: draftText) { _, newValue in
                    guard isFocused,
                          let parsedValue = parse(newValue) else {
                        return
                    }
                    value.wrappedValue = parsedValue
                }
                .onChange(of: isFocused) { _, focused in
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
    let supportedLaunchModes: [LaunchMode]
    let executionState: MissionExecutionState
    let missionStatus: MissionStatusSnapshot
    let fixedWingAssistState: FixedWingAssistState
    let fixedWingAssistWaypoints: [FixedWingAssistWaypointOption]
    let onRemoveLastWaypoint: () -> Void
    let onClearRoute: () -> Void
    let onClearZones: () -> Void
    let onSetZoneRadius: (MissionZoneType, Float) -> Void
    let onSetMinimumAltitude: (Float) -> Void
    let onSetMaximumAltitude: (Float) -> Void
    let onSetMinimumSpeed: (Float) -> Void
    let onSetMaximumSpeed: (Float) -> Void
    let onSetLaunchMode: (LaunchMode) -> Void
    let onSetLaunchHeading: (Float) -> Void
    let onClearLaunchObject: () -> Void
    let onPrepareMission: () -> Void
    let onStartMission: () -> Void
    let onPauseMission: () -> Void
    let onResumeMission: () -> Void
    let onAbortMission: () -> Void
    let onSelectFixedWingAssistWaypoint: (UUID) -> Void
    let onSetFixedWingAutoAdvanceEnabled: (Bool) -> Void
    let onActivateFixedWingAssist: (FixedWingAssistMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            routeSection
            sectionDivider
            launchSection
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

    private var launchSection: some View {
        let launchMode = state.workingDraft.selectedLaunchMode
        let launchObject = state.workingDraft.launchObject

        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("tactical.map.section.launch")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(supportedLaunchModes) { mode in
                        modePill(mode)
                    }
                }
            }

            summaryRow(
                "tactical.map.launch.mode",
                value: localized(launchMode.titleKey)
            )

            if launchMode == .standard {
                Text("tactical.map.launch.standard_hint")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            } else if let launchObject {
                summaryRow(
                    "tactical.map.launch.object",
                    value: localized(launchObject.type.titleKey)
                )
                summaryRow(
                    "tactical.map.launch.position",
                    value: "\(format(point: launchObject.position)) • \(state.viewport.sectorID(for: launchObject.position))"
                )
                summaryRow(
                    "tactical.map.launch.heading",
                    value: "\(Int(launchObject.headingDegrees.rounded()))°"
                )

                Slider(
                    value: Binding(
                        get: { Double(launchObject.headingDegrees) },
                        set: { onSetLaunchHeading(Float($0)) }
                    ),
                    in: 0.0...359.0,
                    step: 1.0
                )
                .disabled(draftEditingLocked)

                actionButton("tactical.map.action.clear_launch_object", tint: GroundControlPalette.borderStrong, action: onClearLaunchObject)
                    .disabled(draftEditingLocked || state.workingDraft.launchObject == nil)
            } else {
                Text("tactical.map.launch.place_object_hint")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var missionSection: some View {
        if state.viewport.airframeClass == .fixedWing {
            fixedWingAssistSection
        } else {
            legacyMissionExecutionSection
        }
    }

    private var legacyMissionExecutionSection: some View {
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

    private var fixedWingAssistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("mission.panel.section.execution")
            summaryRow("mission.status.field.plan", value: localized(missionStatus.planStatus.titleKey))
            summaryRow("fixed_wing.assist.mode", value: localized(fixedWingAssistState.mode.titleKey))
            summaryRow("fixed_wing.assist.status", value: localized(fixedWingAssistState.interceptState.titleKey))
            summaryRow(
                "fixed_wing.assist.feasibility",
                value: fixedWingAssistState.interceptFeasibilityState.map { localized($0.titleKey) } ?? localized("common.na")
            )
            summaryRow("fixed_wing.assist.active_waypoint", value: selectedAssistWaypoint?.label ?? localized("fixed_wing.assist.waypoint.none"))
            summaryRow("fixed_wing.assist.waypoint_mode", value: localized(fixedWingAssistState.waypointMode.titleKey))
            Toggle(
                "fixed_wing.assist.auto_advance",
                isOn: Binding(
                    get: { fixedWingAssistState.autoAdvanceEnabled },
                    set: onSetFixedWingAutoAdvanceEnabled
                )
            )
            .toggleStyle(.switch)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)

            HStack(spacing: 8) {
                actionButton("fixed_wing.assist.action.previous", tint: GroundControlPalette.borderStrong) {
                    if let previousWaypoint = adjacentAssistWaypoint(step: -1) {
                        onSelectFixedWingAssistWaypoint(previousWaypoint.id)
                    }
                }
                .disabled(adjacentAssistWaypoint(step: -1) == nil)

                actionButton("fixed_wing.assist.action.next", tint: GroundControlPalette.borderStrong) {
                    if let nextWaypoint = adjacentAssistWaypoint(step: 1) {
                        onSelectFixedWingAssistWaypoint(nextWaypoint.id)
                    }
                }
                .disabled(adjacentAssistWaypoint(step: 1) == nil)
            }

            if !fixedWingAssistWaypoints.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(fixedWingAssistWaypoints) { waypoint in
                        assistWaypointButton(waypoint)
                    }
                }
            } else {
                Text("fixed_wing.assist.waypoint.none")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    actionButton("mode.manual", tint: GroundControlPalette.borderStrong) {
                        onActivateFixedWingAssist(.manual)
                    }
                    actionButton("mode.fixed_wing_heading_hold", tint: GroundControlPalette.accent) {
                        onActivateFixedWingAssist(.headingHold)
                    }
                }

                HStack(spacing: 8) {
                    actionButton("mode.fixed_wing_altitude_hold", tint: GroundControlPalette.accent) {
                        onActivateFixedWingAssist(.altitudeHold)
                    }
                    actionButton("fixed_wing.assist.action.intercept_selected", tint: GroundControlPalette.success) {
                        onActivateFixedWingAssist(.waypointIntercept)
                    }
                    .disabled(selectedAssistWaypoint == nil)
                }
            }

            if let autoAdvanceStatusKey,
                      fixedWingAssistState.autoAdvanceSuppressed {
                Text(LocalizedStringKey(autoAdvanceStatusKey))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if fixedWingAssistState.interceptFeasibilityState == .poorGeometry {
                Text("fixed_wing.assist.feasibility.warning")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                debugField(
                    "fixed_wing.assist.debug.active_index",
                    value: fixedWingAssistState.activeWaypointIndex.map(String.init) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.auto_advance_enabled",
                    value: fixedWingAssistState.autoAdvanceEnabled ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.next_index",
                    value: fixedWingAssistState.nextWaypointIndex.map(String.init) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.has_prev_waypoint",
                    value: fixedWingAssistState.hasPrevWaypoint ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.has_next_waypoint",
                    value: fixedWingAssistState.hasNextWaypoint ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.is_penultimate_waypoint",
                    value: fixedWingAssistState.isPenultimateWaypoint ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.is_final_waypoint",
                    value: fixedWingAssistState.isFinalWaypoint ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.flyby_center_waypoint_index",
                    value: fixedWingAssistState.flyByCenterWaypointIndex.map(String.init) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.active_triple_indices",
                    value: fixedWingAssistState.activeTripleIndices ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.active_id",
                    value: fixedWingAssistState.activeWaypointID?.uuidString ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.captured_ids",
                    value: fixedWingAssistState.capturedWaypointIDs.isEmpty
                        ? localized("common.na")
                        : fixedWingAssistState.capturedWaypointIDs.map(\.uuidString).joined(separator: ", ")
                )
                debugField(
                    "fixed_wing.assist.debug.intercept_state",
                    value: fixedWingAssistState.interceptState.rawValue
                )
                debugField(
                    "fixed_wing.assist.debug.capture_completed_reason",
                    value: fixedWingAssistState.captureCompletedReason ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.feasibility",
                    value: fixedWingAssistState.interceptFeasibilityState?.rawValue ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.distance",
                    value: fixedWingAssistState.distanceToActiveWaypointMeters.map { String(format: "%.1f m", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.heading_error",
                    value: fixedWingAssistState.headingErrorDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.raw_heading_error",
                    value: fixedWingAssistState.rawHeadingErrorDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.turn_radius",
                    value: fixedWingAssistState.estimatedTurnRadiusMeters.map { String(format: "%.1f m", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.commanded_bank",
                    value: fixedWingAssistState.commandedBankDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.filtered_bank",
                    value: fixedWingAssistState.filteredBankCommandDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.turn_direction",
                    value: fixedWingAssistState.commandedTurnDirection.rawValue
                )
                debugField(
                    "fixed_wing.assist.debug.transition_reason",
                    value: fixedWingAssistState.stateTransitionReason ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.auto_advance_suppressed",
                    value: fixedWingAssistState.autoAdvanceSuppressed ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.auto_advance_suppressed_reason",
                    value: fixedWingAssistState.autoAdvanceSuppressedReason ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.heading_error_to_next_waypoint",
                    value: fixedWingAssistState.headingErrorToNextWaypointDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.next_waypoint_in_forward_sector",
                    value: fixedWingAssistState.nextWaypointInForwardSector ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.enough_turn_in_distance",
                    value: fixedWingAssistState.enoughTurnInDistance ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.collision_risk_to_next_waypoint",
                    value: fixedWingAssistState.collisionRiskToNextWaypoint.map { String(format: "%.2f", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.obstacle_in_turn_corridor",
                    value: fixedWingAssistState.obstacleInTurnCorridor ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.blocked_path_to_next_waypoint",
                    value: fixedWingAssistState.blockedPathToNextWaypoint ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.lateral_guidance_suppressed_for_poor_geometry",
                    value: fixedWingAssistState.lateralGuidanceSuppressedForPoorGeometry ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.current_leg_start",
                    value: fixedWingAssistState.currentLegStart.map(format(point:)) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.current_leg_middle",
                    value: fixedWingAssistState.currentLegMiddle.map(format(point:)) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.current_leg_end",
                    value: fixedWingAssistState.currentLegEnd.map(format(point:)) ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.inbound_course_deg",
                    value: fixedWingAssistState.inboundCourseDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.outbound_course_deg",
                    value: fixedWingAssistState.outboundCourseDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.course_change_deg",
                    value: fixedWingAssistState.courseChangeDegrees.map { String(format: "%.1f deg", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.lead_distance",
                    value: fixedWingAssistState.leadDistanceMeters.map { String(format: "%.1f m", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.flyby_transition_active",
                    value: fixedWingAssistState.flyByTransitionActive ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.turn_transition_active",
                    value: fixedWingAssistState.turnTransitionActive ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.flyby_transition_feasible",
                    value: fixedWingAssistState.flyByTransitionFeasible ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.active_guidance_mode",
                    value: fixedWingAssistState.activeGuidanceMode
                )
                debugField(
                    "fixed_wing.assist.debug.preview_uses_cached_flyby_plan",
                    value: fixedWingAssistState.previewUsesCachedFlyByPlan ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.controller_uses_cached_flyby_plan",
                    value: fixedWingAssistState.controllerUsesCachedFlyByPlan ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.guidance_direct_to_waypoint_suppressed",
                    value: fixedWingAssistState.guidanceDirectToWaypointSuppressed ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.terminal_capture_allowed",
                    value: fixedWingAssistState.terminalCaptureAllowed ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.guidance_type",
                    value: fixedWingAssistState.activeGuidanceTargetType
                )
                debugField(
                    "fixed_wing.assist.debug.using_obsolete_fixed_wing_mode",
                    value: fixedWingAssistState.usingObsoleteFixedWingMode ? "true" : "false"
                )
                debugField(
                    "fixed_wing.assist.debug.flyby_plan_recompute_count",
                    value: String(fixedWingAssistState.flyByPlanRecomputeCount)
                )
                debugField(
                    "fixed_wing.assist.debug.full_route_rebuild_count",
                    value: String(fixedWingAssistState.fullRouteRebuildCount)
                )
                debugField(
                    "fixed_wing.assist.debug.overlay_rebuild_count",
                    value: String(fixedWingAssistState.overlayRebuildCount)
                )
                debugField(
                    "fixed_wing.assist.debug.guidance_recompute_count",
                    value: String(fixedWingAssistState.guidanceRecomputeCount)
                )
                debugField(
                    "fixed_wing.assist.debug.frame_time",
                    value: fixedWingAssistState.frameTimeMs.map { String(format: "%.2f ms", $0) } ?? localized("common.na")
                )
                debugField(
                    "fixed_wing.assist.debug.heavy_map_rebuild_count",
                    value: String(fixedWingAssistState.heavyMapRebuildCount)
                )
                debugField(
                    "fixed_wing.assist.debug.frame_time_during_transition",
                    value: fixedWingAssistState.frameTimeDuringTransitionMs.map { String(format: "%.2f ms", $0) } ?? localized("common.na")
                )
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            Text("fixed_wing.assist.hint")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var selectedAssistWaypoint: FixedWingAssistWaypointOption? {
        if let selectedID = fixedWingAssistState.selectedWaypointID,
           let selected = fixedWingAssistWaypoints.first(where: { $0.id == selectedID }) {
            return selected
        }
        if let activeWaypointIndex = fixedWingAssistState.activeWaypointIndex,
           fixedWingAssistWaypoints.indices.contains(activeWaypointIndex) {
            return fixedWingAssistWaypoints[activeWaypointIndex]
        }
        return fixedWingAssistWaypoints.first
    }

    private var selectedAssistWaypointIndex: Int? {
        guard let selectedID = selectedAssistWaypoint?.id else {
            return nil
        }
        return fixedWingAssistWaypoints.firstIndex(where: { $0.id == selectedID })
    }

    private var autoAdvanceStatusKey: String? {
        guard fixedWingAssistState.autoAdvanceSuppressed else {
            return nil
        }

        switch fixedWingAssistState.autoAdvanceSuppressedReason {
        case "poor_geometry_next_waypoint":
            return "fixed_wing.assist.auto_advance.status.paused_poor_geometry"
        case "turn_transition_segment_too_short",
             "turn_transition_angle_too_sharp",
             "turn_transition_insufficient_radius",
             "fly_by_transition_not_feasible":
            return "fixed_wing.assist.auto_advance.status.paused_poor_geometry"
        case "obstacle_in_turn_corridor",
             "blocked_turn_corridor",
             "obstacle_ahead",
             "blocked_path_to_next_waypoint",
             "collision_risk_to_next_waypoint":
            return "fixed_wing.assist.auto_advance.status.paused_obstacle_ahead"
        default:
            return nil
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

    private func assistWaypointButton(_ waypoint: FixedWingAssistWaypointOption) -> some View {
        let isSelected = selectedAssistWaypoint?.id == waypoint.id
        let isCaptured = fixedWingAssistState.capturedWaypointIDs.contains(waypoint.id)
        let tint: Color = {
            if isSelected {
                return GroundControlPalette.warning
            }
            if isCaptured {
                return GroundControlPalette.success
            }
            return GroundControlPalette.border
        }()
        let fillColor: Color = {
            if isSelected {
                return GroundControlPalette.warning.opacity(0.18)
            }
            if isCaptured {
                return GroundControlPalette.success.opacity(0.12)
            }
            return GroundControlPalette.inset
        }()

        return Button {
            onSelectFixedWingAssistWaypoint(waypoint.id)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(waypoint.label)
                    .foregroundStyle(isSelected ? GroundControlPalette.warning : (isCaptured ? GroundControlPalette.success : GroundControlPalette.textPrimary))
                Text(format(point: waypoint.position))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(isSelected ? 0.92 : 0.72), lineWidth: isSelected ? 1.4 : 1.0)
            )
        }
        .buttonStyle(.plain)
    }

    private func debugField(_ titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(titleKey))
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
                .textSelection(.enabled)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func adjacentAssistWaypoint(step: Int) -> FixedWingAssistWaypointOption? {
        guard let currentIndex = selectedAssistWaypointIndex else {
            return fixedWingAssistWaypoints.first
        }
        let nextIndex = currentIndex + step
        guard fixedWingAssistWaypoints.indices.contains(nextIndex) else {
            return nil
        }
        return fixedWingAssistWaypoints[nextIndex]
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

    private func modePill(_ mode: LaunchMode) -> some View {
        Button {
            onSetLaunchMode(mode)
        } label: {
            Text(LocalizedStringKey(mode.titleKey))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(state.workingDraft.selectedLaunchMode == mode ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(state.workingDraft.selectedLaunchMode == mode ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: "tactical.launch.mode.\(mode.rawValue)") {
            onSetLaunchMode(mode)
        }
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
