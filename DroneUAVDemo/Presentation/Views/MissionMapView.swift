import SwiftUI
import simd

struct MissionMapOverlayView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let missionPlan: MissionPlanningState
    let draftPlan: MissionPlanningState
    let mode: MissionMapMode
    let payloadState: PayloadState
    let statusLabels: [String]
    let isInDropZone: Bool
    let onSetMode: (MissionMapMode) -> Void
    let onSelectRouteTarget: (SIMD2<Float>) -> Void
    let onSelectDropZoneCenter: (SIMD2<Float>) -> Void
    let onSetDropZoneRadius: (Float) -> Void
    let onSetAutoReleaseEnabled: (Bool) -> Void
    let onClearRoute: () -> Void
    let onClearDropZone: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onExit: () -> Void
    @State private var committedZoomFactor: CGFloat = 1.0
    @GestureState private var gestureZoomFactor: CGFloat = 1.0

    private var routeInstructionKey: String {
        switch mode {
        case .navigation:
            return "mission.map.instruction.route"
        case .dropZone:
            return draftPlan.dropZone == nil
                ? "mission.map.instruction.drop_zone_center"
                : "mission.map.instruction.drop_zone_radius"
        }
    }

    private var mapSummaryText: String {
        let home = snapshot.dockPosition
        let format = NSLocalizedString("mission.map.summary.format", comment: "")
        return String.localizedStringWithFormat(
            format,
            snapshot.dronePosition.x,
            snapshot.dronePosition.y,
            home.x,
            home.y,
            snapshot.worldHalfExtent * 2.0
        )
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                header
                bodyContent
                footer
            }
            .padding(18)
            .frame(maxWidth: 1180, maxHeight: 860)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(GroundControlPalette.panel.opacity(0.985))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )
            .padding(28)
        }
        .zIndex(5)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("mission.map.title")
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("mission.map.subtitle")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer()

                buttonCapsule(titleKey: "mission.map.exit", tint: GroundControlPalette.borderStrong) {
                    onExit()
                }
            }

            HStack(spacing: 8) {
                modeButton(.navigation)
                modeButton(.dropZone)
                Spacer(minLength: 8)
                buttonCapsule(titleKey: "mission.map.clear_route", tint: GroundControlPalette.border) {
                    onClearRoute()
                }
                buttonCapsule(titleKey: "mission.map.clear_drop_zone", tint: GroundControlPalette.border) {
                    onClearDropZone()
                }
                buttonCapsule(titleKey: "mission.map.cancel", tint: GroundControlPalette.border) {
                    onCancel()
                }
                buttonCapsule(titleKey: "mission.map.confirm", tint: GroundControlPalette.accent) {
                    onConfirm()
                }
            }

            statusRow
        }
    }

    private var bodyContent: some View {
        HStack(alignment: .top, spacing: 16) {
            mapPanel
            sidePanel
                .frame(width: 300)
        }
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(routeInstructionKey))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)

            GeometryReader { geometry in
                ZStack {
                    TerrainMapCanvas(
                        snapshot: snapshot,
                        routeTargetPosition: draftPlan.routeTarget?.position,
                        dropZone: draftPlan.dropZone,
                        highlightDropZone: isInDropZone,
                        zoomFactor: effectiveZoomFactor
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0.0, coordinateSpace: .local)
                                .onEnded { value in
                                    let projection = TerrainMapProjection(
                                        snapshot: snapshot,
                                        size: geometry.size,
                                        zoomFactor: effectiveZoomFactor
                                    )
                                    guard let planarPoint = projection.unproject(value.location) else {
                                        return
                                    }
                                    switch mode {
                                    case .navigation:
                                        onSelectRouteTarget(planarPoint)
                                    case .dropZone:
                                        onSelectDropZoneCenter(planarPoint)
                                    }
                                }
                        )
                }
                .simultaneousGesture(magnificationGesture)
            }
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )

            Text(mapSummaryText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            infoSection(
                titleKey: "mission.map.section.route",
                value: routeValue
            )

            infoSection(
                titleKey: "mission.map.section.drop_zone",
                value: dropZoneValue
            )

            if draftPlan.dropZone != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("mission.map.section.zone_radius")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Slider(
                        value: Binding(
                            get: { Double(draftPlan.dropZone?.radius ?? 9.0) },
                            set: { onSetDropZoneRadius(Float($0)) }
                        ),
                        in: 1.0...Double(max(6.0, snapshot.worldHalfExtent * 0.6)),
                        step: 0.5
                    )
                    Text(
                        String.localizedStringWithFormat(
                            NSLocalizedString("mission.map.zone_radius.value", comment: ""),
                            draftPlan.dropZone?.radius ?? 0.0
                        )
                    )
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.warning)
                }
                .padding(12)
                .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("mission.map.section.payload_delivery")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textPrimary)

                Toggle(
                    isOn: Binding(
                        get: { draftPlan.autoReleaseEnabled },
                        set: onSetAutoReleaseEnabled
                    )
                ) {
                    Text("mission.map.auto_release")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }
                .toggleStyle(.switch)

                Text(
                    payloadState == .attached
                        ? String(localized: "mission.map.payload_ready")
                        : String(localized: "mission.map.payload_unavailable")
                )
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(payloadState == .attached ? GroundControlPalette.success : GroundControlPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            statusChip(titleKey: missionPlan.dropZone != nil ? "mission.map.active_drop_zone" : "mission.map.no_drop_zone", tint: missionPlan.dropZone != nil ? GroundControlPalette.warning : GroundControlPalette.border)
            statusChip(titleKey: missionPlan.routeTarget != nil ? "mission.map.active_route" : "mission.map.no_route", tint: missionPlan.routeTarget != nil ? GroundControlPalette.accent : GroundControlPalette.border)
            Spacer()
            Text("mission.map.footer_hint")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
    }

    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(statusLabels, id: \.self) { label in
                    statusChip(titleKey: label, tint: chipTint(for: label))
                }
            }
        }
    }

    private var routeValue: String {
        guard let routeTarget = draftPlan.routeTarget else {
            return String(localized: "mission.map.no_route_target")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("mission.map.route.value.format", comment: ""),
            routeTarget.position.x,
            routeTarget.position.y
        )
    }

    private var dropZoneValue: String {
        guard let dropZone = draftPlan.dropZone else {
            return String(localized: "mission.map.no_drop_zone_value")
        }
        return String.localizedStringWithFormat(
            NSLocalizedString("mission.map.drop_zone.value.format", comment: ""),
            dropZone.center.x,
            dropZone.center.y,
            dropZone.radius
        )
    }

    private func modeButton(_ buttonMode: MissionMapMode) -> some View {
        Button {
            onSetMode(buttonMode)
        } label: {
            Text(LocalizedStringKey(buttonMode.titleKey))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(mode == buttonMode ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(mode == buttonMode ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func buttonCapsule(titleKey: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(GroundControlPalette.inset, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.88), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func infoSection(titleKey: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func statusChip(titleKey: String, tint: Color) -> some View {
        Text(LocalizedStringKey(titleKey))
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.7), lineWidth: 1)
            )
    }

    private func chipTint(for label: String) -> Color {
        switch label {
        case "mission.status.map_active":
            return GroundControlPalette.accent
        case "mission.status.drop_zone_set":
            return GroundControlPalette.warning
        case "mission.status.delivery_ready":
            return GroundControlPalette.success
        case "mission.status.in_drop_zone":
            return GroundControlPalette.danger
        case "mission.status.payload_released":
            return GroundControlPalette.warning
        default:
            return GroundControlPalette.border
        }
    }

    private var effectiveZoomFactor: CGFloat {
        min(6.0, max(1.0, committedZoomFactor * gestureZoomFactor))
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureZoomFactor) { value, gestureState, _ in
                gestureState = value
            }
            .onEnded { value in
                committedZoomFactor = min(6.0, max(1.0, committedZoomFactor * value))
            }
    }
}
