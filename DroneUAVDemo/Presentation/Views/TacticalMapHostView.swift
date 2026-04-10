import SwiftUI
import simd

struct TacticalMapHostView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let missionStatus: MissionStatusSnapshot
    let missionTimeline: MissionTimeline?
    let missionDebrief: MissionDebrief?
    let onSetMode: (TacticalMapMode) -> Void
    let onMapTap: (SIMD2<Float>) -> Void
    let onRemoveLastWaypoint: () -> Void
    let onClearRoute: () -> Void
    let onClearZones: () -> Void
    let onSetZoneRadius: (MissionZoneType, Float) -> Void
    let onSetMinimumAltitude: (Float) -> Void
    let onSetMaximumAltitude: (Float) -> Void
    let onSetMinimumSpeed: (Float) -> Void
    let onSetMaximumSpeed: (Float) -> Void
    let onSaveDraft: () -> Void
    let onPrepareMission: () -> Void
    let onStartMission: () -> Void
    let onPauseMission: () -> Void
    let onResumeMission: () -> Void
    let onAbortMission: () -> Void
    let onCancel: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                TacticalMapHeader(
                    state: state,
                    onSaveDraft: onSaveDraft,
                    onCancel: onCancel,
                    onExit: onExit
                )

                GeometryReader { geometry in
                    let compact = geometry.size.width < 1120 || geometry.size.height < 700
                    let contentLayout = compact
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                        : AnyLayout(HStackLayout(alignment: .top, spacing: 14))

                    contentLayout {
                        TacticalMapView(
                            snapshot: snapshot,
                            state: state,
                            missionPlan: missionPlan,
                            executionState: executionState,
                            onSetMode: onSetMode,
                            onMapTap: onMapTap
                        )
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: compact ? 520 : .infinity
                        )

                        MissionSidebar(
                            state: state,
                            missionPlan: missionPlan,
                            executionState: executionState,
                            missionStatus: missionStatus,
                            missionTimeline: missionTimeline,
                            missionDebrief: missionDebrief,
                            compact: compact,
                            onRemoveLastWaypoint: onRemoveLastWaypoint,
                            onClearRoute: onClearRoute,
                            onClearZones: onClearZones,
                            onSetZoneRadius: onSetZoneRadius,
                            onSetMinimumAltitude: onSetMinimumAltitude,
                            onSetMaximumAltitude: onSetMaximumAltitude,
                            onSetMinimumSpeed: onSetMinimumSpeed,
                            onSetMaximumSpeed: onSetMaximumSpeed,
                            onPrepareMission: onPrepareMission,
                            onStartMission: onStartMission,
                            onPauseMission: onPauseMission,
                            onResumeMission: onResumeMission,
                            onAbortMission: onAbortMission
                        )
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 1280, maxHeight: 840)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(GroundControlPalette.panel.opacity(0.985))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
            .padding(24)
        }
        .zIndex(5)
    }
}

private struct MissionSidebar: View {
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let missionStatus: MissionStatusSnapshot
    let missionTimeline: MissionTimeline?
    let missionDebrief: MissionDebrief?
    let compact: Bool
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
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                MissionStatusPanel(snapshot: missionStatus)
                MissionTimelineView(
                    timeline: missionTimeline,
                    compact: true
                )
                MissionDebriefView(
                    debrief: missionDebrief,
                    compact: true
                )
                MissionDraftPanel(
                    state: state,
                    missionPlan: missionPlan,
                    executionState: executionState,
                    missionStatus: missionStatus,
                    onRemoveLastWaypoint: onRemoveLastWaypoint,
                    onClearRoute: onClearRoute,
                    onClearZones: onClearZones,
                    onSetZoneRadius: onSetZoneRadius,
                    onSetMinimumAltitude: onSetMinimumAltitude,
                    onSetMaximumAltitude: onSetMaximumAltitude,
                    onSetMinimumSpeed: onSetMinimumSpeed,
                    onSetMaximumSpeed: onSetMaximumSpeed,
                    onPrepareMission: onPrepareMission,
                    onStartMission: onStartMission,
                    onPauseMission: onPauseMission,
                    onResumeMission: onResumeMission,
                    onAbortMission: onAbortMission
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: compact ? nil : 308)
    }
}

private struct TacticalMapHeader: View {
    let state: TacticalMapState
    let onSaveDraft: () -> Void
    let onCancel: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("tactical.map.title")
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)
                Text("tactical.map.subtitle")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            Spacer(minLength: 8)

            headerBadge(
                state.isDraftDirty
                    ? "tactical.map.badge.draft_dirty"
                    : "tactical.map.badge.draft_synced",
                tint: state.isDraftDirty ? GroundControlPalette.warning : GroundControlPalette.success
            )

            headerButton("tactical.map.action.save_draft", tint: GroundControlPalette.accent, action: onSaveDraft)
                .disabled(!state.draftStatus.canSave || !state.isDraftDirty)
            headerButton("tactical.map.action.cancel", tint: GroundControlPalette.borderStrong, action: onCancel)
                .disabled(!state.isDraftDirty)
            headerButton("tactical.map.action.exit", tint: GroundControlPalette.borderStrong, action: onExit)
        }
    }

    private func headerBadge(_ titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.72), lineWidth: 1)
            )
    }

    private func headerButton(
        _ titleKey: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(GroundControlPalette.inset, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.85), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
