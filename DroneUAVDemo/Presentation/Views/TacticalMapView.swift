import SwiftUI
import simd

struct TacticalMapView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState
    let onSetMode: (TacticalMapMode) -> Void
    let onMapTap: (SIMD2<Float>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(TacticalMapMode.allCases) { mode in
                    modeButton(mode)
                }
                Spacer(minLength: 8)
                Text(LocalizedStringKey(state.mode.instructionKey))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GroundControlPalette.textSecondary)
            }

            GeometryReader { geometry in
                ZStack {
                    TacticalMapCanvas(
                        snapshot: snapshot,
                        state: state,
                        missionPlan: missionPlan,
                        executionState: executionState
                    )

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0.0, coordinateSpace: .local)
                                .onEnded { value in
                                    let projection = TerrainMapProjection(snapshot: snapshot, size: geometry.size)
                                    guard let planarPoint = projection.unproject(value.location) else {
                                        return
                                    }
                                    onMapTap(planarPoint)
                                }
                        )
                        .controllerPointTarget(id: "tactical.map.canvas") { localPoint in
                            let projection = TerrainMapProjection(snapshot: snapshot, size: geometry.size)
                            guard let planarPoint = projection.unproject(localPoint) else {
                                return
                            }
                            onMapTap(planarPoint)
                        }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(GroundControlPalette.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(GroundControlPalette.borderStrong, lineWidth: 1)
            )

            HStack(spacing: 10) {
                metricChip("tactical.map.metric.span", value: String(format: "%.0f m", state.viewport.worldHalfExtent * 2.0))
                metricChip("tactical.map.metric.route_distance", value: routeDistanceText)
                metricChip("tactical.map.metric.waypoints", value: "\(state.workingDraft.waypoints.count)")
                metricChip("tactical.map.metric.zones", value: "\(state.workingDraft.zones.count)")
                Spacer(minLength: 8)
            }
        }
    }

    private var routeDistanceText: String {
        guard let previewRoute = state.previewRoute else {
            return String(localized: "tactical.map.preview.none")
        }
        return String(format: "%.0f m", previewRoute.totalLengthMeters)
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
}

private struct TacticalMapCanvas: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let executionState: MissionExecutionState

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let projection = TerrainMapProjection(snapshot: snapshot, size: size)

            context.fill(Path(projection.mapRect), with: .color(backgroundColor.opacity(0.98)))
            drawGrid(in: &context, projection: projection)
            drawSignalBoundary(in: &context, projection: projection)
            drawZones(in: &context, projection: projection)
            drawPreviewRoute(in: &context, projection: projection)
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
        let divisions = 4

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
            with: .color(GroundControlPalette.border.opacity(0.54)),
            lineWidth: 0.8
        )
    }

    private func drawSignalBoundary(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let center = projection.project(.zero)
        let radius = projection.projectedRadius(for: snapshot.signalBoundaryRadius)
        let rect = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2.0,
            height: radius * 2.0
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(Color(red: 0.37, green: 0.73, blue: 0.96).opacity(0.42)),
            style: StrokeStyle(lineWidth: 1.0, dash: [5.0, 4.0])
        )
    }

    private func drawZones(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for zone in state.workingDraft.zones {
            let center = projection.project(zone.center)
            let radius = projection.projectedRadius(for: zone.radius)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2.0,
                height: radius * 2.0
            )

            let tint = zone.type == .dropZone
                ? GroundControlPalette.warning
                : GroundControlPalette.danger
            context.fill(
                Path(ellipseIn: rect),
                with: .color(tint.opacity(zone.type == .dropZone ? 0.14 : 0.10))
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(tint.opacity(0.88)),
                lineWidth: 1.4
            )
        }
    }

    private func drawPreviewRoute(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard state.draftStatus.isPreviewAvailable,
              let previewRoute = state.previewRoute,
              previewRoute.points.count > 1 else {
            return
        }

        var path = Path()
        path.move(to: projection.project(previewRoute.points[0]))
        for point in previewRoute.points.dropFirst() {
            path.addLine(to: projection.project(point))
        }

        context.stroke(
            path,
            with: .color(GroundControlPalette.accent.opacity(0.92)),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
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
            case .crate, .pole, .marker:
                continue
            case .distantBelt:
                break
            }
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
        for waypoint in state.workingDraft.waypoints {
            let center = projection.project(waypoint.position)
            let rect = CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)
            let isCompleted = executionState.waypointProgress.contains {
                $0.target.waypointID == waypoint.id && $0.state == .completed
            }
            let isActive = executionState.activeTarget?.waypointID == waypoint.id
            let tint: Color = {
                if isCompleted {
                    return GroundControlPalette.success
                }
                if isActive {
                    return GroundControlPalette.warning
                }
                return GroundControlPalette.accent
            }()

            context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(0.92)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.42)), lineWidth: 0.8)
            if isActive {
                let ringRect = rect.insetBy(dx: -4.0, dy: -4.0)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(GroundControlPalette.warning.opacity(0.88)),
                    lineWidth: 1.1
                )
            }
            context.draw(
                Text(waypoint.label)
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
        let heading = CGFloat(snapshot.droneYawRadians)
        let forward = CGVector(dx: sin(heading), dy: cos(heading))
        let right = CGVector(dx: -forward.dy, dy: forward.dx)

        func point(_ origin: CGPoint, offset: CGVector, scale: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + offset.dx * scale, y: origin.y + offset.dy * scale)
        }

        let nose = point(center, offset: forward, scale: 10)
        let tail = point(center, offset: forward, scale: -5.5)
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
