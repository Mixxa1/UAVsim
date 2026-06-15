import SwiftUI
import simd

struct SceneViewportView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel
    var trialPhase: LANTrialPhase = .running
    var onEndTrial: (() -> Void)? = nil
    var onLeaveTrial: (() -> Void)? = nil
    @StateObject private var tabObserver = TabKeyObserver()

    var body: some View {
        let overlayInset = viewModel.isParametersPanelVisible ? 18.0 : 12.0

        ZStack(alignment: .topLeading) {
            DroneSceneViewRepresentable(
                scene: viewModel.scene,
                pointOfView: viewModel.activeCameraNode,
                cameraMode: viewModel.cameraConfiguration.mode,
                cameraSensitivity: viewModel.cameraConfiguration.sensitivity,
                freeMoveSpeed: viewModel.cameraConfiguration.free.moveSpeed,
                onLookDelta: { dx, dy in
                    viewModel.handlePointerLook(deltaX: dx, deltaY: dy)
                },
                onRenderFrame: { time, mode in
                    viewModel.handleSceneRenderFrame(atTime: time, cameraMode: mode)
                }
            )
            .ignoresSafeArea()

            if viewModel.isSpectatorMode {
                EmptyView()
            } else if !viewModel.isParametersPanelVisible || viewModel.isCompactTelemetryHUDEnabled {
                CompactTelemetryHUDView(
                    telemetry: viewModel.telemetry,
                    warningKeys: viewModel.warnings
                )
                .padding(.leading, overlayInset)
                .padding(.top, overlayInset)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let activeModule = viewModel.activeControlModule {
                        HStack(spacing: 8) {
                            Image(systemName: activeModule.iconSystemName)
                            Text(LocalizedStringKey(activeModule.titleKey))
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                    } else {
                        Text("hud.title")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroundControlPalette.textSecondary)
                    }

                    Text("\(localized("hud.camera")): \(localized(viewModel.cameraConfiguration.mode.titleKey)) | \(localized("hud.drone")): \(viewModel.selectedDroneProfile.uiDisplayName)")
                        .font(.caption2.monospaced())
                    if let warningKey = viewModel.warnings.first {
                        Text(LocalizedStringKey(warningKey))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(GroundControlPalette.warning)
                    }
                }
                .foregroundStyle(GroundControlPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                )
                .frame(maxWidth: 296, alignment: .leading)
                .padding(.leading, overlayInset)
                .padding(.top, overlayInset)
            }
        }
        .overlay(alignment: .top) {
            if !viewModel.isSpectatorMode, viewModel.isCompassVisible {
                CompassOverlayView(viewModel: viewModel.compassViewModel)
                    .padding(.top, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 10) {
                if viewModel.onlineTrialContext != nil {
                    OnlineTrialRuntimeOverlay(
                        context: viewModel.onlineTrialContext,
                        fleetState: viewModel.onlineFleetState,
                        remoteStates: viewModel.onlineInterpolatedRemoteStates,
                        snapshotTargetHz: 10,
                        isExpanded: tabObserver.isTabHeld,
                        trialPhase: trialPhase,
                        participantCount: viewModel.onlineTrialContext?.launchDescriptor.assignments.count ?? 1,
                        staleCount: viewModel.onlineTrialStaleRemoteCount,
                        onEndTrial: onEndTrial,
                        onLeaveTrial: onLeaveTrial
                    )
                    .animation(.easeInOut(duration: 0.12), value: tabObserver.isTabHeld)
                }

                if !viewModel.isSpectatorMode {
                    if viewModel.isTerrainMapVisible, !viewModel.isMissionMapVisible {
                        TerrainMapOverlayView(
                            snapshot: viewModel.terrainMapSnapshot,
                            telemetry: viewModel.telemetry,
                            targetMarker: viewModel.targetMarkerState,
                            dropZone: viewModel.missionPlanState.dropZone,
                            onSelectTarget: { viewModel.setTargetMarker(at: $0) },
                            onClearTarget: { viewModel.clearTargetMarker() }
                        )
                    }

                    if viewModel.cameraConfiguration.mode == .payload, viewModel.payloadCameraStatus.isActive {
                        PayloadCameraStatusOverlayView(status: viewModel.payloadCameraStatus)
                    }
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 12)
        }
        .background(Color.black)
        .onAppear { tabObserver.start(viewModel: viewModel) }
        .onDisappear { tabObserver.stop() }
    }
}

// MARK: – Tab-hold key observer for the online detail panel

private final class TabKeyObserver: ObservableObject {
    @Published var isTabHeld = false
    private var monitor: Any?

    func start(viewModel: DroneSimulationViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak viewModel] event in
            guard let self, viewModel?.onlineTrialContext != nil else { return event }
            guard event.keyCode == 48 else { return event } // Tab
            if event.type == .keyDown, !event.isARepeat {
                self.isTabHeld = true
                return nil
            } else if event.type == .keyUp {
                self.isTabHeld = false
                return nil
            }
            return event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        isTabHeld = false
    }

    deinit { stop() }
}

private struct PayloadCameraStatusOverlayView: View {
    let status: PayloadCameraStatus

    private var altitudeText: String {
        String(format: "%06.1f m", max(0.0, status.altitude))
    }

    private var verticalSpeedText: String {
        String(format: "%+06.1f m/s", status.verticalSpeed)
    }

    private var elapsedTimeText: String {
        String(format: "%05.1f s", max(0.0, status.elapsedTime))
    }

    private var stateColor: Color {
        switch status.state {
        case .impact:
            return GroundControlPalette.warning
        case .rest:
            return GroundControlPalette.success
        case .falling:
            return GroundControlPalette.textPrimary
        case .inactive:
            return GroundControlPalette.textSecondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("overlay.payload_view.title")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(GroundControlPalette.textPrimary)
            metricRow(label: localized("overlay.payload_view.metric.alt"), value: altitudeText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.vertical_speed"), value: verticalSpeedText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.time"), value: elapsedTimeText, color: GroundControlPalette.textSecondary)
            metricRow(label: localized("overlay.payload_view.metric.state"), value: status.state.title, color: stateColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 248, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func metricRow(label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 38, alignment: .leading)
                .foregroundStyle(GroundControlPalette.textSecondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(color)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TerrainMapOverlayView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let telemetry: TelemetrySnapshot
    let targetMarker: TargetMarkerState?
    let dropZone: DropZoneState?
    let onSelectTarget: (SIMD2<Float>) -> Void
    let onClearTarget: () -> Void

    private var headingDegreesText: String {
        String(format: "%03.0f", bodyHeadingDegrees(fromYawRadians: snapshot.droneYawRadians))
    }

    private var mapSpanText: String {
        String(format: "%.0f m", snapshot.worldHalfExtent * 2.0)
    }

    private var signalRadiusText: String {
        String(format: "%.0f / %.0f m", snapshot.linkQualityRadius, snapshot.degradedLinkRadius)
    }

    private var autoNavigationLabel: String {
        telemetry.autoNavigationActive ? localized("telemetry.auto_nav.active") : localized("telemetry.auto_nav.inactive")
    }

    private var targetMetricsText: String {
        guard telemetry.targetDistanceMeters.isFinite, telemetry.targetBearingDegrees.isFinite else {
            return localized("overlay.terrain_map.target_metrics.empty")
        }

        return String(
            format: localized("overlay.terrain_map.target_metrics.format"),
            telemetry.targetDistanceMeters,
            telemetry.targetBearingDegrees
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("overlay.terrain_map.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("overlay.terrain_map.subtitle")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    if targetMarker != nil {
                        Button(action: onClearTarget) {
                            Text("overlay.terrain_map.clear")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(GroundControlPalette.textPrimary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(GroundControlPalette.inset, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Text("M")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(GroundControlPalette.inset, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
                        )
                }
            }

            ZStack {
                TerrainMapCanvas(
                    snapshot: snapshot,
                    routeTargetPosition: targetMarker?.position,
                    dropZone: dropZone,
                    highlightDropZone: telemetry.inDropZone
                )

                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0.0, coordinateSpace: .local)
                                .onEnded { value in
                                    let projection = TerrainMapProjection(snapshot: snapshot, size: geometry.size)
                                    guard let planarPoint = projection.unproject(value.location) else {
                                        return
                                    }
                                    onSelectTarget(planarPoint)
                                }
                        )
                }
            }
            .frame(width: 288, height: 288)
            .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(GroundControlPalette.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    String(
                        format: localized("overlay.terrain_map.heading_alt_objects.format"),
                        headingDegreesText,
                        snapshot.droneAltitude,
                        snapshot.objects.count
                    )
                )
                Text(
                    String(
                        format: localized("overlay.terrain_map.position_map.format"),
                        telemetry.x,
                        telemetry.z,
                        mapSpanText
                    )
                )
                Text(
                    String(
                        format: localized("overlay.terrain_map.status.format"),
                        signalRadiusText,
                        autoNavigationLabel
                    )
                )
                Text(targetMetricsText)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .padding(12)
        .frame(width: 332, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(GroundControlPalette.panel.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 16, y: 10)
    }
}

struct TerrainMapCanvas: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let routeTargetPosition: SIMD2<Float>?
    let dropZone: DropZoneState?
    let highlightDropZone: Bool
    var zoomFactor: CGFloat = 1.0

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let projection = TerrainMapProjection(
                snapshot: snapshot,
                size: size,
                zoomFactor: zoomFactor
            )

            context.fill(
                Path(projection.mapRect),
                with: .color(mapBackgroundColor.opacity(0.98))
            )
            context.clip(to: Path(projection.mapRect))
            drawGrid(in: &context, projection: projection)
            drawOperationalEnvelope(in: &context, projection: projection)
            drawTrail(in: &context, projection: projection)
            if let dropZone {
                drawDropZone(dropZone, in: &context, projection: projection)
            }
            drawNoFlyZones(in: &context, projection: projection)
            drawMissionRoute(in: &context, projection: projection)
            drawActiveLeg(in: &context, projection: projection)
            drawPredictedPath(in: &context, projection: projection)
            drawMissionWaypoints(in: &context, projection: projection)

            if let targetMarkerPosition = routeTargetPosition ?? snapshot.targetMarkerPosition {
                drawTargetLink(to: targetMarkerPosition, in: &context, projection: projection)
            }

            for object in snapshot.objects {
                drawObject(object, in: &context, projection: projection)
            }

            drawDock(in: &context, projection: projection)
            if let targetMarkerPosition = routeTargetPosition ?? snapshot.targetMarkerPosition {
                drawTargetMarker(at: targetMarkerPosition, in: &context, projection: projection)
            }
            drawDrone(in: &context, projection: projection)

            context.stroke(
                Path(projection.mapRect),
                with: .color(GroundControlPalette.borderStrong),
                lineWidth: 1.2
            )
        }
    }

    private var mapBackgroundColor: Color {
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
        var gridPath = Path()
        let divisions = 4

        for index in 1..<divisions {
            let ratio = CGFloat(index) / CGFloat(divisions)
            let x = projection.mapRect.minX + projection.mapRect.width * ratio
            let y = projection.mapRect.minY + projection.mapRect.height * ratio

            gridPath.move(to: CGPoint(x: x, y: projection.mapRect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: projection.mapRect.maxY))
            gridPath.move(to: CGPoint(x: projection.mapRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: projection.mapRect.maxX, y: y))
        }

        gridPath.move(to: CGPoint(x: projection.mapRect.midX, y: projection.mapRect.minY))
        gridPath.addLine(to: CGPoint(x: projection.mapRect.midX, y: projection.mapRect.maxY))
        gridPath.move(to: CGPoint(x: projection.mapRect.minX, y: projection.mapRect.midY))
        gridPath.addLine(to: CGPoint(x: projection.mapRect.maxX, y: projection.mapRect.midY))

        context.stroke(
            gridPath,
            with: .color(GroundControlPalette.border.opacity(0.72)),
            lineWidth: 0.8
        )
    }

    private func drawTrail(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.trail.count > 1 else {
            return
        }

        var trailPath = Path()
        trailPath.move(to: projection.project(snapshot.trail[0]))
        for point in snapshot.trail.dropFirst() {
            trailPath.addLine(to: projection.project(point))
        }

        context.stroke(
            trailPath,
            with: .color(GroundControlPalette.warning.opacity(0.64)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawOperationalEnvelope(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(.zero)
        drawRadius(snapshot.hardWorldBoundsRadius, color: GroundControlPalette.danger.opacity(0.36), style: StrokeStyle(lineWidth: 0.9, dash: [3, 6]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.degradedLinkRadius, color: GroundControlPalette.warning.opacity(0.52), style: StrokeStyle(lineWidth: 1.0, dash: [5, 4]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.linkQualityRadius, color: Color(red: 0.37, green: 0.73, blue: 0.96).opacity(0.78), style: StrokeStyle(lineWidth: 1.15, dash: [5, 4]), center: center, projection: projection, context: &context)
        drawRadius(snapshot.operationalRadius, color: GroundControlPalette.success.opacity(0.54), style: StrokeStyle(lineWidth: 1.0, dash: [2, 4]), center: center, projection: projection, context: &context)
    }

    private func drawRadius(
        _ radiusMeters: Float,
        color: Color,
        style: StrokeStyle,
        center: CGPoint,
        projection: TerrainMapProjection,
        context: inout GraphicsContext
    ) {
        guard radiusMeters > 0.01 else {
            return
        }
        let radius = projection.projectedRadius(for: radiusMeters)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        context.stroke(
            Path(ellipseIn: rect),
            with: .color(color),
            style: style
        )
    }

    private func drawTargetLink(
        to targetMarker: SIMD2<Float>,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        var path = Path()
        path.move(to: projection.project(snapshot.dronePosition))
        path.addLine(to: projection.project(targetMarker))

        context.stroke(
            path,
            with: .color(GroundControlPalette.warning.opacity(0.82)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 3])
        )
    }

    private func drawMissionRoute(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.missionRoutePoints.count > 1 else {
            return
        }

        var routePath = Path()
        routePath.move(to: projection.project(snapshot.missionRoutePoints[0]))
        for point in snapshot.missionRoutePoints.dropFirst() {
            routePath.addLine(to: projection.project(point))
        }

        context.stroke(
            routePath,
            with: .color(GroundControlPalette.accent.opacity(0.78)),
            style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawMissionWaypoints(
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
                    return GroundControlPalette.warning
                }
                return GroundControlPalette.accent
            }()
            let acceptanceRadius = projection.projectedRadius(for: waypoint.acceptanceRadius)
            let acceptanceRect = CGRect(
                x: center.x - acceptanceRadius,
                y: center.y - acceptanceRadius,
                width: acceptanceRadius * 2.0,
                height: acceptanceRadius * 2.0
            )
            context.fill(Path(ellipseIn: acceptanceRect), with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.11 : 0.07)))
            context.stroke(
                Path(ellipseIn: acceptanceRect),
                with: .color(tint.opacity(waypoint.isActive || waypoint.isAssistSelected ? 0.9 : 0.58)),
                style: StrokeStyle(lineWidth: waypoint.isActive || waypoint.isAssistSelected ? 1.7 : 1.15, dash: [5.0, 3.0])
            )

            let rect = CGRect(x: center.x - 6.0, y: center.y - 6.0, width: 12.0, height: 12.0)
            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.92)))
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(0.40)),
                lineWidth: 0.8
            )

            if waypoint.isAssistSelected {
                let outerRingRect = rect.insetBy(dx: -4.5, dy: -4.5)
                context.stroke(
                    Path(ellipseIn: outerRingRect),
                    with: .color(GroundControlPalette.warning.opacity(0.94)),
                    lineWidth: 1.2
                )
            } else if waypoint.isActive {
                let ringRect = rect.insetBy(dx: -3.5, dy: -3.5)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(GroundControlPalette.warning.opacity(0.88)),
                    lineWidth: 1.0
                )
            }

            context.draw(
                Text(waypoint.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.white),
                at: CGPoint(x: center.x, y: center.y - 13.5),
                anchor: .center
            )
        }
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
            with: .color(GroundControlPalette.warning.opacity(0.92)),
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
            with: .color(GroundControlPalette.borderStrong.opacity(0.86)),
            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [4.0, 3.0])
        )
    }

    private func drawNoFlyZones(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for zone in snapshot.noFlyZones {
            let center = projection.project(zone.center)
            let radius = projection.projectedRadius(for: zone.radius)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2.0,
                height: radius * 2.0
            )

            context.fill(
                Path(ellipseIn: rect),
                with: .color(GroundControlPalette.danger.opacity(0.08))
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(GroundControlPalette.danger.opacity(0.86)),
                style: StrokeStyle(lineWidth: 1.6, dash: [5, 4])
            )
        }
    }

    private func drawDropZone(
        _ dropZone: DropZoneState,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(dropZone.center)
        let radius = projection.projectedRadius(for: dropZone.radius)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )

        context.fill(
            Path(ellipseIn: rect),
            with: .color(GroundControlPalette.warning.opacity(highlightDropZone ? 0.18 : 0.10))
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(highlightDropZone ? GroundControlPalette.danger : GroundControlPalette.warning),
            style: StrokeStyle(lineWidth: highlightDropZone ? 2.2 : 1.4, dash: [6, 4])
        )
    }

    private func drawObject(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
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
            context.fill(path, with: .color(Color(red: 0.56, green: 0.60, blue: 0.66).opacity(0.82)))
            context.stroke(path, with: .color(Color.black.opacity(0.30)), lineWidth: 0.9)
        case .tree:
            let path = Path(ellipseIn: rect)
            context.fill(path, with: .color(Color(red: 0.29, green: 0.56, blue: 0.30).opacity(0.72)))
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.5)
        case .rock:
            let rockRect = rect.insetBy(dx: -0.4, dy: 0.2)
            let path = Path(ellipseIn: rockRect)
            context.fill(path, with: .color(Color(red: 0.64, green: 0.66, blue: 0.68).opacity(0.70)))
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
        case .crate:
            let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.68, green: 0.52, blue: 0.24).opacity(0.76)))
            context.stroke(path, with: .color(Color.black.opacity(0.22)), lineWidth: 0.6)
        case .pole:
            let poleRect = CGRect(
                x: center.x - 1.3,
                y: center.y - max(3.2, size.height * 0.5),
                width: 2.6,
                height: max(6.4, size.height)
            )
            let path = Path(roundedRect: poleRect, cornerRadius: 1.0, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.80, green: 0.67, blue: 0.28).opacity(0.84)))
        case .marker:
            var path = Path()
            path.move(to: CGPoint(x: center.x, y: center.y - size.height * 0.5))
            path.addLine(to: CGPoint(x: center.x + size.width * 0.5, y: center.y))
            path.addLine(to: CGPoint(x: center.x, y: center.y + size.height * 0.5))
            path.addLine(to: CGPoint(x: center.x - size.width * 0.5, y: center.y))
            path.closeSubpath()
            context.fill(path, with: .color(Color(red: 0.31, green: 0.73, blue: 0.86).opacity(0.80)))
            context.stroke(path, with: .color(Color.black.opacity(0.20)), lineWidth: 0.6)
        case .distantBelt:
            break
        }
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
        crosshair.move(to: CGPoint(x: center.x - 8, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 8, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 8))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 8))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.82)), lineWidth: 1.0)
    }

    private func drawTargetMarker(
        at targetMarker: SIMD2<Float>,
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(targetMarker)
        let outerRect = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        let innerRect = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)

        context.stroke(Path(ellipseIn: outerRect), with: .color(GroundControlPalette.warning), lineWidth: 1.6)
        context.fill(Path(ellipseIn: innerRect), with: .color(GroundControlPalette.warning))

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 10, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 10, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 10))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 10))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.78)), lineWidth: 1.0)
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

        let bodyRect = CGRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
        context.fill(Path(ellipseIn: bodyRect), with: .color(Color.white.opacity(0.92)))
    }
}

struct TerrainMapProjection {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let size: CGSize
    let zoomFactor: CGFloat
    let panOffset: CGSize
    let fillsAvailableSpace: Bool
    // Mirror the operator-facing map horizontally so the scene reads
    // left-to-right the same way as in the reference screenshots.
    private let transform = TerrainMapTransform.mirroredHorizontally

    init(
        snapshot: DroneSimulationViewModel.TerrainMapSnapshot,
        size: CGSize,
        zoomFactor: CGFloat = 1.0,
        panOffset: CGSize = .zero,
        fillsAvailableSpace: Bool = false
    ) {
        self.snapshot = snapshot
        self.size = size
        self.zoomFactor = min(6.0, max(1.0, zoomFactor))
        self.panOffset = panOffset
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    var outerRect: CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
    }

    var mapRect: CGRect {
        guard !fillsAvailableSpace else {
            return outerRect
        }

        let side = min(outerRect.width, outerRect.height)
        return CGRect(
            x: outerRect.midX - side * 0.5,
            y: outerRect.midY - side * 0.5,
            width: side,
            height: side
        )
    }

    func project(_ point: SIMD2<Float>) -> CGPoint {
        CGPoint(
            x: projectionCenter.x + CGFloat(point.x) * xScale * transform.xAxisSign,
            y: projectionCenter.y + CGFloat(point.y) * yScale * transform.yAxisSign
        )
    }

    func unproject(_ point: CGPoint) -> SIMD2<Float>? {
        guard mapRect.contains(point) else {
            return nil
        }

        guard xScale > 0.0001, yScale > 0.0001 else {
            return nil
        }

        return SIMD2<Float>(
            Float((point.x - projectionCenter.x) / (xScale * transform.xAxisSign)),
            Float((point.y - projectionCenter.y) / (yScale * transform.yAxisSign))
        )
    }

    func projectedSize(for footprint: SIMD2<Float>) -> CGSize {
        return CGSize(
            width: max(3.0, CGFloat(footprint.x) * xScale),
            height: max(3.0, CGFloat(footprint.y) * yScale)
        )
    }

    func projectedRadius(for radius: Float) -> CGFloat {
        max(6.0, CGFloat(radius) * min(xScale, yScale))
    }

    func projectedRadiusSize(for radius: Float) -> CGSize {
        CGSize(
            width: max(6.0, CGFloat(radius) * xScale),
            height: max(6.0, CGFloat(radius) * yScale)
        )
    }

    func headingVector(forYawRadians yawRadians: Float) -> CGVector {
        transform.headingVector(
            yawRadians: yawRadians,
            projection: self
        )
    }

    private var projectionCenter: CGPoint {
        CGPoint(
            x: mapRect.midX + panOffset.width,
            y: mapRect.midY + panOffset.height
        )
    }

    private var projectedExtent: CGFloat {
        CGFloat(max(1.0, snapshot.worldHalfExtent / Float(zoomFactor)))
    }

    private var xScale: CGFloat {
        projectionScale
    }

    private var yScale: CGFloat {
        projectionScale
    }

    private var projectionScale: CGFloat {
        let fillDimension = fillsAvailableSpace
            ? max(mapRect.width, mapRect.height)
            : min(mapRect.width, mapRect.height)
        return fillDimension / max(1.0, projectedExtent * 2.0)
    }
}

private struct TerrainMapTransform {
    var xAxisSign: CGFloat
    var yAxisSign: CGFloat

    static let defaultNorthUp = TerrainMapTransform(xAxisSign: 1.0, yAxisSign: -1.0)
    static let rotated180 = TerrainMapTransform(xAxisSign: -1.0, yAxisSign: 1.0)
    static let mirroredHorizontally = TerrainMapTransform(xAxisSign: 1.0, yAxisSign: 1.0)

    func project(
        _ point: SIMD2<Float>,
        mapRect: CGRect,
        scale: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: mapRect.midX + CGFloat(point.x) * scale * xAxisSign,
            y: mapRect.midY + CGFloat(point.y) * scale * yAxisSign
        )
    }

    func unproject(
        _ point: CGPoint,
        mapRect: CGRect,
        scale: CGFloat
    ) -> SIMD2<Float> {
        SIMD2<Float>(
            Float((point.x - mapRect.midX) / (scale * xAxisSign)),
            Float((point.y - mapRect.midY) / (scale * yAxisSign))
        )
    }

    func headingVector(
        yawRadians: Float,
        projection: TerrainMapProjection
    ) -> CGVector {
        let origin = projection.project(SIMD2<Float>(repeating: 0.0))
        let forwardWorld = SIMD2<Float>(
            sin(yawRadians),
            cos(yawRadians)
        )
        let tip = projection.project(forwardWorld)
        let delta = CGVector(
            dx: tip.x - origin.x,
            dy: tip.y - origin.y
        )
        let length = sqrt(delta.dx * delta.dx + delta.dy * delta.dy)
        guard length > 0.0001 else {
            return CGVector(dx: 0.0, dy: -1.0)
        }
        return CGVector(dx: delta.dx / length, dy: delta.dy / length)
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
