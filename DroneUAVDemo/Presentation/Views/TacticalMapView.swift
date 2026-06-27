import SwiftUI
import simd

struct TacticalMapView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let onSetMode: (TacticalMapMode) -> Void
    let onMapTap: (SIMD2<Float>) -> Void
    @State private var committedZoomFactor: CGFloat = 1.0
    @State private var committedPanOffset: CGSize = .zero
    @State private var isLegendPresented = false
    @GestureState private var gestureZoomFactor: CGFloat = 1.0
    @GestureState private var gesturePanOffset: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            GeometryReader { geometry in
                let panOffset = clampedPanOffset(
                    in: geometry.size,
                    offset: CGSize(
                        width: committedPanOffset.width + gesturePanOffset.width,
                        height: committedPanOffset.height + gesturePanOffset.height
                    )
                )

                ZStack(alignment: .topTrailing) {
                    TacticalMapCanvas(
                        snapshot: snapshot,
                        state: state,
                        missionPlan: missionPlan,
                        executionState: executionState,
                        zoomFactor: effectiveZoomFactor,
                        panOffset: panOffset
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0.0, coordinateSpace: .local)
                                .updating($gesturePanOffset) { value, gestureState, _ in
                                    guard Self.dragDistance(value.translation) >= 4.0 else {
                                        gestureState = .zero
                                        return
                                    }
                                    gestureState = value.translation
                                }
                                .onEnded { value in
                                    if Self.dragDistance(value.translation) >= 4.0 {
                                        committedPanOffset = clampedPanOffset(
                                            in: geometry.size,
                                            offset: CGSize(
                                                width: committedPanOffset.width + value.translation.width,
                                                height: committedPanOffset.height + value.translation.height
                                            )
                                        )
                                        return
                                    }

                                    let projection = TerrainMapProjection(
                                        snapshot: snapshot,
                                        size: geometry.size,
                                        zoomFactor: effectiveZoomFactor,
                                        panOffset: panOffset,
                                        fillsAvailableSpace: true
                                    )
                                    guard let planarPoint = projection.unproject(value.location) else {
                                        return
                                    }
                                    onMapTap(planarPoint)
                                }
                        )
                        .controllerPointTarget(id: "tactical.map.canvas") { localPoint in
                            let projection = TerrainMapProjection(
                                snapshot: snapshot,
                                size: geometry.size,
                                zoomFactor: effectiveZoomFactor,
                                panOffset: panOffset,
                                fillsAvailableSpace: true
                            )
                            guard let planarPoint = projection.unproject(localPoint) else {
                                return
                            }
                            onMapTap(planarPoint)
                        }

                    mapOverlayControls()
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .simultaneousGesture(magnificationGesture)
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )

            summaryBar
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                modeSelector
                Spacer(minLength: 8)
                instructionBadge
            }

            VStack(alignment: .leading, spacing: 8) {
                modeSelector
                instructionBadge
            }
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 8) {
            ForEach(TacticalMapMode.planningModes) { mode in
                modeButton(mode)
            }
        }
    }

    private var instructionBadge: some View {
        HStack(spacing: 8) {
            statusBadge(
                title: state.viewport.geofenceState.title,
                tint: geofenceTint(state.viewport.geofenceState)
            )
            Text(LocalizedStringKey(state.mode.instructionKey))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(GroundControlPalette.panelRaised, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private var summaryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                metricChip("tactical.map.metric.span", value: scaleDescriptor)
                metricChip("tactical.map.metric.route_distance", value: routeDistanceText)
                if let previewStatusText {
                    metricChip("tactical.map.metric.preview", value: previewStatusText)
                }
                metricChip("tactical.map.metric.drop_zone", value: dropZoneText)
                metricChip("tactical.map.metric.link_status", value: linkStatusText)
                metricChip("tactical.map.metric.safe_return", value: safeReturnText)
                metricChip("tactical.map.metric.edge_distance", value: edgeDistanceText)
                metricChip("tactical.map.metric.geofence", value: geofenceText)
                metricChip("tactical.map.metric.mode", value: modeTitle)
            }
        }
    }

    private var scaleDescriptor: String {
        let preset = Int(state.viewport.mapScale.numericPreset.rounded())
        return "\(preset) • \(Int(state.viewport.mapSideLengthMeters.rounded())) m"
    }

    private var routeDistanceText: String {
        guard let previewRoute = state.previewRoute else {
            return String(localized: "tactical.map.preview.none")
        }
        return String(format: "%.0f m", previewRoute.totalLengthMeters)
    }

    private var dropZoneText: String {
        guard let dropZone = state.workingDraft.dropZone else {
            return String(localized: "mission.status.value.none")
        }
        return String(format: "%.0f m", dropZone.radius)
    }

    private var linkStatusText: String {
        if state.viewport.isLinkLost {
            return String(localized: "tactical.map.link.lost")
        }
        if state.viewport.isInCriticalLinkZone {
            return String(localized: "tactical.map.link.critical")
        }
        if state.viewport.isInWarningLinkZone {
            return String(localized: "tactical.map.link.warning")
        }
        return String(localized: "tactical.map.link.nominal")
    }

    private var safeReturnText: String {
        let qualifier = state.viewport.canReachHomeSafely
            ? String(localized: "tactical.map.safe_return.ok")
            : String(localized: "tactical.map.safe_return.limit")
        return "\(qualifier) \(Int(state.viewport.estimatedSafeReturnRangeM.rounded())) m"
    }

    private var edgeDistanceText: String {
        let direction = NSLocalizedString("tactical.map.direction.\(state.viewport.nearestBoundaryDirection.rawValue)", comment: "")
        return "\(direction) \(Int(max(0.0, state.viewport.distanceToNearestMapEdge).rounded())) m"
    }

    private var geofenceText: String {
        "\(state.viewport.geofenceState.title) • \(Int(state.viewport.boundaryHalfExtent.rounded())) m"
    }

    private var modeTitle: String {
        NSLocalizedString(state.mode.titleKey, comment: "")
    }

    private var previewStatusText: String? {
        state.previewRoute?.previewStatusKey.map { NSLocalizedString($0, comment: "") }
    }

    @ViewBuilder
    private func mapOverlayControls() -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 8) {
                mapIconButton(
                    systemName: "scope",
                    accessibilityKey: "tactical.map.pan.center",
                    controllerID: "tactical.map.pan.center.quick"
                ) {
                    committedPanOffset = .zero
                }
                mapIconButton(
                    systemName: isLegendPresented ? "list.bullet.rectangle.fill" : "list.bullet.rectangle",
                    accessibilityKey: "tactical.map.legend.toggle"
                ) {
                    isLegendPresented.toggle()
                }
            }

            if isLegendPresented {
                TacticalMapLegendView(snapshot: snapshot, state: state)
                    .transition(.opacity)
            }
        }
    }

    private func mapIconButton(
        systemName: String,
        accessibilityKey: String,
        controllerID: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .frame(width: 28, height: 28)
                .background(GroundControlPalette.inset.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString(accessibilityKey, comment: ""))
        .accessibilityLabel(Text(LocalizedStringKey(accessibilityKey)))
        .controllerButtonTarget(id: controllerID ?? accessibilityKey, action: action)
    }

    private func clampedPanOffset(in size: CGSize, offset: CGSize) -> CGSize {
        let zoomAllowance = max(0.0, effectiveZoomFactor - 1.0)
        let cropCompensationX = max(0.0, size.height - size.width) * 0.5
        let cropCompensationY = max(0.0, size.width - size.height) * 0.5
        let horizontalLimit = cropCompensationX + max(0.0, size.width * zoomAllowance * 0.44)
        let verticalLimit = cropCompensationY + max(0.0, size.height * zoomAllowance * 0.44)

        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, offset.width)),
            height: min(verticalLimit, max(-verticalLimit, offset.height))
        )
    }

    private func modeButton(_ mode: TacticalMapMode) -> some View {
        Button {
            onSetMode(mode)
        } label: {
            Text(LocalizedStringKey(mode.titleKey))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(state.mode == mode ? GroundControlPalette.accent.opacity(0.22) : GroundControlPalette.inset)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(state.mode == mode ? GroundControlPalette.accent.opacity(0.62) : GroundControlPalette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .controllerButtonTarget(id: "tactical.map.mode.\(mode.rawValue)") {
            onSetMode(mode)
        }
    }

    private func metricChip(_ titleKey: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(LocalizedStringKey(titleKey))
            Text(value)
                .foregroundStyle(GroundControlPalette.textPrimary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(GroundControlPalette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(GroundControlPalette.panelRaised, in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func statusBadge(title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.72), lineWidth: 1)
            )
    }

    private func geofenceTint(_ state: MapGeofenceState) -> Color {
        switch state {
        case .nominal:
            return GroundControlPalette.success
        case .warning:
            return GroundControlPalette.warning
        case .critical, .outside:
            return GroundControlPalette.danger
        }
    }

    private var effectiveZoomFactor: CGFloat {
        min(6.0, max(1.0, committedZoomFactor * gestureZoomFactor))
    }

    private static func dragDistance(_ translation: CGSize) -> CGFloat {
        sqrt(translation.width * translation.width + translation.height * translation.height)
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

private struct TacticalMapLegendView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: GroundControlPalette.borderStrong, key: "tactical.map.legend.boundary")
            legendRow(color: GroundControlPalette.warning, key: "tactical.map.legend.warning_band")
            legendRow(color: GroundControlPalette.danger, key: "tactical.map.legend.critical_band")

            switch state.mode {
            case .waypoint:
                if state.previewRoute?.isFlyablePreview == true {
                    legendRow(color: GroundControlPalette.borderStrong.opacity(0.74), key: "tactical.map.legend.route_geometry")
                    legendRow(color: GroundControlPalette.accent, key: "tactical.map.legend.predicted_path")
                } else {
                    legendRow(color: GroundControlPalette.accent, key: "tactical.map.legend.route")
                }
                legendRow(color: GroundControlPalette.success, key: "tactical.map.legend.safe_return")
            case .dropZone:
                legendRow(color: GroundControlPalette.warning, key: "tactical.map.legend.drop_zone")
            case .noFlyZone:
                legendRow(color: GroundControlPalette.danger, key: "tactical.map.legend.no_fly")
            }

            if snapshot.payloadImpact != nil {
                legendRow(color: GroundControlPalette.warning, key: "tactical.map.legend.payload_impact")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(GroundControlPalette.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GroundControlPalette.border, lineWidth: 1)
        )
    }

    private func legendRow(color: Color, key: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 4)
            Text(LocalizedStringKey(key))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textSecondary)
        }
    }
}

private struct TacticalMapCanvas: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let zoomFactor: CGFloat
    let panOffset: CGSize

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let projection = TerrainMapProjection(
                snapshot: snapshot,
                size: size,
                zoomFactor: zoomFactor,
                panOffset: panOffset,
                fillsAvailableSpace: true
            )

            context.fill(Path(projection.mapRect), with: .color(backgroundColor.opacity(0.98)))
            context.clip(to: Path(projection.mapRect))
            drawGrid(in: &context, projection: projection)
            drawGeofence(in: &context, projection: projection)
            drawServiceOverlays(in: &context, projection: projection)
            drawZones(in: &context, projection: projection)
            drawMissionGeometry(in: &context, projection: projection)
            drawPreviewRoute(in: &context, projection: projection)
            drawActiveLeg(in: &context, projection: projection)
            drawPredictedPath(in: &context, projection: projection)
            drawPayloadImpact(in: &context, projection: projection)
            drawObjects(in: &context, projection: projection)
            drawDock(in: &context, projection: projection)
            drawWaypoints(in: &context, projection: projection)
            drawDrone(in: &context, projection: projection)
            context.stroke(
                Path(projection.mapRect),
                with: .color(GroundControlPalette.borderStrong),
                lineWidth: 1.2
            )
        }
    }

    private var backgroundColor: Color {
        switch snapshot.preset {
        case .city:
            return Color(red: 0.10, green: 0.12, blue: 0.15)
        case .cargoYard:
            return Color(red: 0.16, green: 0.15, blue: 0.13)
        case .forest:
            return Color(red: 0.10, green: 0.15, blue: 0.11)
        case .field:
            return Color(red: 0.13, green: 0.16, blue: 0.11)
        case .gridDemo:
            return GroundControlPalette.inset
        }
    }

    private func drawGrid(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        var path = Path()
        let divisions = MapViewportState.tacticalSectorDivisions

        for index in 1..<divisions {
            let ratio = CGFloat(index) / CGFloat(divisions)
            let x = projection.mapRect.minX + projection.mapRect.width * ratio
            let y = projection.mapRect.minY + projection.mapRect.height * ratio
            path.move(to: CGPoint(x: x, y: projection.mapRect.minY))
            path.addLine(to: CGPoint(x: x, y: projection.mapRect.maxY))
            path.move(to: CGPoint(x: projection.mapRect.minX, y: y))
            path.addLine(to: CGPoint(x: projection.mapRect.maxX, y: y))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.border.opacity(0.40)),
            lineWidth: 0.7
        )

        let sectorStep = state.viewport.boundaryHalfExtent * 2.0 / Float(divisions)
        for row in 0..<divisions {
            for column in 0..<divisions {
                let labelLocalPosition = SIMD2<Float>(
                    (-state.viewport.boundaryHalfExtent) + (Float(column) + 0.18) * sectorStep,
                    state.viewport.boundaryHalfExtent - (Float(row) + 0.18) * sectorStep
                )
                let worldPosition = state.viewport.dockPosition + labelLocalPosition
                let screenPosition = projection.project(worldPosition)
                let sectorID = state.viewport.sectorID(for: worldPosition, divisions: divisions)
                context.draw(
                    Text(sectorID)
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(GroundControlPalette.textSecondary.opacity(0.34)),
                    at: screenPosition,
                    anchor: .topLeading
                )
            }
        }
    }

    private func drawGeofence(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let home = state.viewport.dockPosition
        let boundaryRect = projection.projectedSquare(center: home, halfExtent: state.viewport.boundaryHalfExtent)
        let warningRect = projection.projectedSquare(
            center: home,
            halfExtent: max(1.0, state.viewport.boundaryHalfExtent - state.viewport.warningBandDepth)
        )
        let criticalRect = projection.projectedSquare(
            center: home,
            halfExtent: max(1.0, state.viewport.boundaryHalfExtent - state.viewport.criticalBandDepth)
        )

        context.fill(Path(boundaryRect), with: .color(GroundControlPalette.warning.opacity(0.06)))
        context.fill(Path(criticalRect), with: .color(backgroundColor.opacity(0.45)))
        context.fill(Path(warningRect), with: .color(backgroundColor.opacity(0.76)))

        context.stroke(
            Path(boundaryRect),
            with: .color(GroundControlPalette.borderStrong.opacity(0.92)),
            style: StrokeStyle(lineWidth: 1.4, dash: [5.0, 4.0])
        )
        context.stroke(
            Path(warningRect),
            with: .color(GroundControlPalette.warning.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.0, dash: [4.0, 4.0])
        )
        context.stroke(
            Path(criticalRect),
            with: .color(GroundControlPalette.danger.opacity(0.82)),
            style: StrokeStyle(lineWidth: 1.0, dash: [3.0, 3.0])
        )

        let edgePoint = projection.project(state.viewport.clampedToWorld(state.viewport.dronePosition))
        context.draw(
            Text(String(localized: "tactical.map.overlay.boundary"))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(GroundControlPalette.textPrimary),
            at: CGPoint(x: boundaryRect.minX + 44, y: boundaryRect.minY + 10),
            anchor: .center
        )
        context.fill(
            Path(ellipseIn: CGRect(x: edgePoint.x - 2.5, y: edgePoint.y - 2.5, width: 5, height: 5)),
            with: .color(geofenceMarkerColor)
        )
    }

    private var geofenceMarkerColor: Color {
        switch state.viewport.geofenceState {
        case .nominal:
            return GroundControlPalette.success
        case .warning:
            return GroundControlPalette.warning
        case .critical, .outside:
            return GroundControlPalette.danger
        }
    }

    private func drawServiceOverlays(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(state.viewport.dockPosition)

        if state.mode == .waypoint, state.viewport.estimatedSafeReturnRangeM > 0.0 {
            drawRadius(
                min(state.viewport.boundaryHalfExtent, state.viewport.estimatedSafeReturnRangeM * 0.48),
                color: GroundControlPalette.success.opacity(0.44),
                style: StrokeStyle(lineWidth: 1.0, dash: [2.0, 4.0]),
                center: center,
                projection: projection,
                context: &context,
                label: String(localized: "tactical.map.overlay.safe_return")
            )
        }

        if state.viewport.isInWarningLinkZone || state.viewport.isInCriticalLinkZone || state.viewport.isLinkLost {
            drawRadius(
                state.viewport.linkQualityRadius,
                color: Color(red: 0.37, green: 0.73, blue: 0.96).opacity(0.50),
                style: StrokeStyle(lineWidth: 0.9, dash: [5.0, 4.0]),
                center: center,
                projection: projection,
                context: &context,
                label: String(localized: "tactical.map.overlay.link")
            )
        }
    }

    private func drawRadius(
        _ radiusMeters: Float,
        color: Color,
        style: StrokeStyle,
        center: CGPoint,
        projection: TerrainMapProjection,
        context: inout GraphicsContext,
        label: String? = nil
    ) {
        guard radiusMeters > 0.01 else {
            return
        }
        let radius = projection.projectedRadiusSize(for: radiusMeters)
        let rect = CGRect(
            x: center.x - radius.width,
            y: center.y - radius.height,
            width: radius.width * 2.0,
            height: radius.height * 2.0
        )
        context.stroke(Path(ellipseIn: rect), with: .color(color), style: style)
        if let label {
            context.draw(
                Text(label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(color),
                at: CGPoint(x: rect.midX, y: rect.minY + 10),
                anchor: .center
            )
        }
    }

    private func drawZones(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for zone in state.workingDraft.zones {
            let center = projection.project(zone.center)
            let radius = projection.projectedRadiusSize(for: zone.radius)
            let rect = CGRect(
                x: center.x - radius.width,
                y: center.y - radius.height,
                width: radius.width * 2.0,
                height: radius.height * 2.0
            )

            switch zone.type {
            case .dropZone:
                context.fill(Path(ellipseIn: rect), with: .color(GroundControlPalette.warning.opacity(0.14)))
                context.stroke(Path(ellipseIn: rect), with: .color(GroundControlPalette.warning.opacity(0.92)), lineWidth: 1.6)
                context.draw(
                    Text(String(format: NSLocalizedString("tactical.map.overlay.drop_zone_radius", comment: ""), zone.radius))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(GroundControlPalette.warning),
                    at: CGPoint(x: rect.midX, y: rect.maxY + 10),
                    anchor: .center
                )
            case .noFlyZone:
                context.fill(Path(ellipseIn: rect), with: .color(GroundControlPalette.danger.opacity(0.14)))
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(GroundControlPalette.danger.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.4, dash: [4.0, 3.0])
                )
                context.draw(
                    Text(String(localized: "tactical.map.overlay.no_fly"))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(GroundControlPalette.danger),
                    at: CGPoint(x: rect.midX, y: rect.minY + 10),
                    anchor: .center
                )
            }
        }
    }

    private func drawPreviewRoute(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard state.draftStatus.isPreviewAvailable,
              let previewRoute = state.previewRoute,
              previewRoute.missionPlanPoints.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(previewRoute.missionPlanPoints[0]))
        for point in previewRoute.missionPlanPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.accent.opacity(state.mode == .waypoint ? 0.94 : 0.42)),
            style: StrokeStyle(lineWidth: state.mode == .waypoint ? 2.4 : 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawMissionGeometry(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard state.mode == .waypoint,
              let previewRoute = state.previewRoute,
              previewRoute.visibleExecutionPoints.count > 1 else {
            return
        }

        guard previewRoute.isFlyablePreview,
              previewRoute.visibleExecutionPoints != previewRoute.missionPlanPoints else {
            return
        }

        var path = Path()
        path.move(to: projection.project(previewRoute.visibleExecutionPoints[0]))
        for point in previewRoute.visibleExecutionPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.borderStrong.opacity(0.58)),
            style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round, dash: [4.0, 4.0])
        )
    }

    private func drawActiveLeg(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.activeLegPoints.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(snapshot.activeLegPoints[0]))
        for point in snapshot.activeLegPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.warning.opacity(0.94)),
            style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawPredictedPath(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.predictedPathPoints.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(snapshot.predictedPathPoints[0]))
        for point in snapshot.predictedPathPoints.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.borderStrong.opacity(0.84)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round, dash: [4.0, 3.0])
        )
    }

    private func drawObjects(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for object in snapshot.objects {
            let center = projection.project(object.position)
            let size = projection.projectedSize(for: object.footprint)
            let rect = CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5,
                width: size.width,
                height: size.height
            )

            switch object.kind {
            case .building:
                let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
                context.fill(path, with: .color(Color(red: 0.56, green: 0.60, blue: 0.66).opacity(0.64)))
            case .tree:
                context.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.29, green: 0.56, blue: 0.30).opacity(0.56)))
            case .rock:
                context.fill(Path(ellipseIn: rect), with: .color(Color(red: 0.64, green: 0.66, blue: 0.68).opacity(0.52)))
            case .cargoContainer:
                let path = Path(roundedRect: rect, cornerRadius: 1.2, style: .continuous)
                context.fill(path, with: .color(Color(red: 0.72, green: 0.34, blue: 0.18).opacity(0.72)))
            case .crate, .pole, .marker:
                continue
            }
        }
    }

    private func drawPayloadImpact(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard let impact = snapshot.payloadImpact else {
            return
        }

        let center = projection.project(impact.position)
        let falloffRadius = projection.projectedRadiusSize(for: impact.falloffRadius)
        let coreRadius = projection.projectedRadiusSize(for: impact.coreRadius)
        let falloffRect = CGRect(
            x: center.x - falloffRadius.width,
            y: center.y - falloffRadius.height,
            width: falloffRadius.width * 2.0,
            height: falloffRadius.height * 2.0
        )
        let coreRect = CGRect(
            x: center.x - coreRadius.width,
            y: center.y - coreRadius.height,
            width: coreRadius.width * 2.0,
            height: coreRadius.height * 2.0
        )
        let tint: Color = switch impact.outcome {
        case .generic:
            GroundControlPalette.warning
        case .onTarget:
            GroundControlPalette.success
        case .nearTarget:
            GroundControlPalette.warning
        case .offTarget:
            GroundControlPalette.danger
        }

        context.fill(Path(ellipseIn: falloffRect), with: .color(tint.opacity(0.09)))
        context.stroke(
            Path(ellipseIn: falloffRect),
            with: .color(tint.opacity(0.42)),
            style: StrokeStyle(lineWidth: 1.0, dash: [4.0, 4.0])
        )
        context.fill(Path(ellipseIn: coreRect), with: .color(tint.opacity(0.22)))
        context.stroke(Path(ellipseIn: coreRect), with: .color(tint.opacity(0.92)), lineWidth: 1.4)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 8.0, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 8.0, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 8.0))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 8.0))
        context.stroke(crosshair, with: .color(tint.opacity(0.92)), lineWidth: 1.0)

        context.draw(
            Text(NSLocalizedString(impact.outcome.overlayTitleKey, comment: ""))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(tint),
            at: CGPoint(x: center.x, y: falloffRect.maxY + 10.0),
            anchor: .center
        )
    }

    private func drawDock(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(snapshot.dockPosition)
        let dockRect = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
        let dockPath = Path(roundedRect: dockRect, cornerRadius: 1.5, style: .continuous)
        context.stroke(dockPath, with: .color(GroundControlPalette.warning), lineWidth: 1.4)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 7, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 7, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 7))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 7))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.78)), lineWidth: 1.0)
    }

    private func drawWaypoints(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for waypoint in snapshot.missionWaypoints {
            let center = projection.project(waypoint.position)
            let tint: Color = {
                if waypoint.isCompleted {
                    return GroundControlPalette.success
                }
                if waypoint.isAssistSelected {
                    return GroundControlPalette.warning
                }
                if waypoint.isActive {
                    return GroundControlPalette.accent
                }
                return GroundControlPalette.accent
            }()
            let acceptanceRadius = projection.projectedRadiusSize(for: waypoint.acceptanceRadius)
            let acceptanceRect = CGRect(
                x: center.x - acceptanceRadius.width,
                y: center.y - acceptanceRadius.height,
                width: acceptanceRadius.width * 2.0,
                height: acceptanceRadius.height * 2.0
            )
            context.fill(Path(ellipseIn: acceptanceRect), with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.12 : 0.075)))
            context.stroke(
                Path(ellipseIn: acceptanceRect),
                with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.92 : 0.62)),
                style: StrokeStyle(lineWidth: waypoint.isActive || waypoint.isAssistSelected ? 1.8 : 1.25, dash: [5.0, 3.0])
            )

            let rect = CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.94)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.42)), lineWidth: 0.8)
            if waypoint.isAssistSelected {
                let outerRingRect = rect.insetBy(dx: -5.0, dy: -5.0)
                context.stroke(
                    Path(ellipseIn: outerRingRect),
                    with: .color(GroundControlPalette.warning.opacity(0.94)),
                    lineWidth: 1.4
                )
            } else if waypoint.isActive {
                let ringRect = rect.insetBy(dx: -4.0, dy: -4.0)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(GroundControlPalette.warning.opacity(0.88)),
                    lineWidth: 1.1
                )
            }
            context.draw(
                Text("\(waypoint.label) • \(state.viewport.sectorID(for: waypoint.position))")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white),
                at: CGPoint(x: center.x + 0.0, y: center.y - 14),
                anchor: .center
            )
        }
    }

    private func drawDrone(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(snapshot.dronePosition)
        let forward = projection.headingVector(forYawRadians: snapshot.droneYawRadians)
        // Keep the marker orientation consistent for every airframe.
        let markerForward = CGVector(dx: -forward.dx, dy: -forward.dy)
        let right = CGVector(dx: -markerForward.dy, dy: markerForward.dx)

        func point(_ origin: CGPoint, offset: CGVector, scale: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + offset.dx * scale, y: origin.y + offset.dy * scale)
        }

        let nose = point(center, offset: markerForward, scale: 10)
        let tail = point(center, offset: markerForward, scale: -5.5)
        let left = point(tail, offset: right, scale: 4.8)
        let rightPoint = point(tail, offset: right, scale: -4.8)

        var dronePath = Path()
        dronePath.move(to: nose)
        dronePath.addLine(to: left)
        dronePath.addLine(to: center)
        dronePath.addLine(to: rightPoint)
        dronePath.closeSubpath()

        context.fill(dronePath, with: .color(GroundControlPalette.danger))
        context.stroke(dronePath, with: .color(Color.white.opacity(0.36)), lineWidth: 0.9)
    }
}

private extension TerrainMapProjection {
    func projectedSquare(center: SIMD2<Float>, halfExtent: Float) -> CGRect {
        let topLeft = project(SIMD2<Float>(center.x - halfExtent, center.y + halfExtent))
        let bottomRight = project(SIMD2<Float>(center.x + halfExtent, center.y - halfExtent))
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }
}
