import SwiftUI
import simd

struct SceneViewportView: View {
    @ObservedObject var viewModel: DroneSimulationViewModel

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
                }
            )
            .ignoresSafeArea()

            if !viewModel.isParametersPanelVisible || viewModel.isCompactTelemetryHUDEnabled {
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
        .overlay(alignment: .topTrailing) {
            if viewModel.isTerrainMapVisible {
                TerrainMapOverlayView(
                    snapshot: viewModel.terrainMapSnapshot,
                    telemetry: viewModel.telemetry
                )
                .padding(.top, 12)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
            }
        }
        .background(Color.black)
    }
}

private struct TerrainMapOverlayView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let telemetry: TelemetrySnapshot

    private var headingDegreesText: String {
        let degrees = snapshot.droneYawRadians * 180.0 / .pi
        let normalized = degrees.truncatingRemainder(dividingBy: 360.0)
        let wrapped = normalized < 0.0 ? normalized + 360.0 : normalized
        return String(format: "%03.0f", wrapped)
    }

    private var mapSpanText: String {
        String(format: "%.0f m", snapshot.worldHalfExtent * 2.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TERRAIN MAP")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textPrimary)
                    Text("Scene bounds / dock / obstacles / UAV")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(GroundControlPalette.textSecondary)
                }

                Spacer(minLength: 8)

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

            TerrainMapCanvas(snapshot: snapshot)
                .frame(width: 288, height: 288)
                .background(GroundControlPalette.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(GroundControlPalette.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("HDG \(headingDegreesText)°   ALT \(String(format: "%.1f", snapshot.droneAltitude)) m   OBJ \(snapshot.objects.count)")
                Text("X \(String(format: "%+.1f", telemetry.x))   Z \(String(format: "%+.1f", telemetry.z))   MAP \(mapSpanText)")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(GroundControlPalette.textSecondary)
        }
        .padding(12)
        .frame(width: 316, alignment: .leading)
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

private struct TerrainMapCanvas: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            let outerRect = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 10)
            let side = min(outerRect.width, outerRect.height)
            let mapRect = CGRect(
                x: outerRect.midX - side * 0.5,
                y: outerRect.midY - side * 0.5,
                width: side,
                height: side
            )

            context.fill(
                Path(mapRect),
                with: .color(GroundControlPalette.inset.opacity(0.98))
            )
            drawGrid(in: &context, mapRect: mapRect)
            drawTrail(in: &context, mapRect: mapRect)

            for object in snapshot.objects {
                drawObject(object, in: &context, mapRect: mapRect)
            }

            drawDock(in: &context, mapRect: mapRect)
            drawDrone(in: &context, mapRect: mapRect)

            context.stroke(
                Path(mapRect),
                with: .color(GroundControlPalette.borderStrong),
                lineWidth: 1.2
            )
        }
    }

    private func drawGrid(in context: inout GraphicsContext, mapRect: CGRect) {
        var gridPath = Path()
        let divisions = 4

        for index in 1..<divisions {
            let ratio = CGFloat(index) / CGFloat(divisions)
            let x = mapRect.minX + mapRect.width * ratio
            let y = mapRect.minY + mapRect.height * ratio

            gridPath.move(to: CGPoint(x: x, y: mapRect.minY))
            gridPath.addLine(to: CGPoint(x: x, y: mapRect.maxY))
            gridPath.move(to: CGPoint(x: mapRect.minX, y: y))
            gridPath.addLine(to: CGPoint(x: mapRect.maxX, y: y))
        }

        gridPath.move(to: CGPoint(x: mapRect.midX, y: mapRect.minY))
        gridPath.addLine(to: CGPoint(x: mapRect.midX, y: mapRect.maxY))
        gridPath.move(to: CGPoint(x: mapRect.minX, y: mapRect.midY))
        gridPath.addLine(to: CGPoint(x: mapRect.maxX, y: mapRect.midY))

        context.stroke(
            gridPath,
            with: .color(GroundControlPalette.border.opacity(0.72)),
            lineWidth: 0.8
        )
    }

    private func drawTrail(in context: inout GraphicsContext, mapRect: CGRect) {
        guard snapshot.trail.count > 1 else {
            return
        }

        var trailPath = Path()
        let firstPoint = project(snapshot.trail[0], in: mapRect)
        trailPath.move(to: firstPoint)
        for point in snapshot.trail.dropFirst() {
            trailPath.addLine(to: project(point, in: mapRect))
        }

        context.stroke(
            trailPath,
            with: .color(GroundControlPalette.warning.opacity(0.64)),
            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawObject(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        in context: inout GraphicsContext,
        mapRect: CGRect
    ) {
        let center = project(object.position, in: mapRect)
        let size = projectedSize(for: object.footprint, in: mapRect)
        let rect = CGRect(
            x: center.x - size.width * 0.5,
            y: center.y - size.height * 0.5,
            width: size.width,
            height: size.height
        )

        switch object.kind {
        case .building:
            let path = Path(roundedRect: rect, cornerRadius: 2, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.32, green: 0.56, blue: 0.78).opacity(0.72)))
            context.stroke(path, with: .color(Color.white.opacity(0.22)), lineWidth: 0.8)
        case .tree:
            let path = Path(ellipseIn: rect)
            context.fill(path, with: .color(Color(red: 0.31, green: 0.57, blue: 0.34).opacity(0.72)))
            context.stroke(path, with: .color(Color.black.opacity(0.24)), lineWidth: 0.6)
        case .rock:
            let rockRect = rect.insetBy(dx: -0.5, dy: 0.3)
            let path = Path(ellipseIn: rockRect)
            context.fill(path, with: .color(Color(red: 0.55, green: 0.57, blue: 0.60).opacity(0.80)))
            context.stroke(path, with: .color(Color.black.opacity(0.18)), lineWidth: 0.6)
        case .crate:
            let path = Path(roundedRect: rect, cornerRadius: 1.5, style: .continuous)
            context.fill(path, with: .color(Color(red: 0.68, green: 0.52, blue: 0.24).opacity(0.76)))
            context.stroke(path, with: .color(Color.black.opacity(0.22)), lineWidth: 0.6)
        case .pole:
            let poleRect = CGRect(x: center.x - 1.3, y: center.y - max(3.2, size.height * 0.5), width: 2.6, height: max(6.4, size.height))
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

    private func drawDock(in context: inout GraphicsContext, mapRect: CGRect) {
        let center = project(snapshot.dockPosition, in: mapRect)
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

    private func drawDrone(in context: inout GraphicsContext, mapRect: CGRect) {
        let center = project(snapshot.dronePosition, in: mapRect)
        let heading = CGFloat(snapshot.droneYawRadians)
        let forward = CGVector(dx: -sin(heading), dy: -cos(heading))
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

        let bodyRect = CGRect(x: center.x - 2.1, y: center.y - 2.1, width: 4.2, height: 4.2)
        context.fill(Path(ellipseIn: bodyRect), with: .color(Color.white.opacity(0.92)))
    }

    private func project(_ point: SIMD2<Float>, in mapRect: CGRect) -> CGPoint {
        let extent = max(1.0, snapshot.worldHalfExtent)
        let scale = min(mapRect.width, mapRect.height) / CGFloat(extent * 2.0)
        return CGPoint(
            x: mapRect.midX + CGFloat(point.x) * scale,
            y: mapRect.midY - CGFloat(point.y) * scale
        )
    }

    private func projectedSize(for footprint: SIMD2<Float>, in mapRect: CGRect) -> CGSize {
        let extent = max(1.0, snapshot.worldHalfExtent)
        let scale = min(mapRect.width, mapRect.height) / CGFloat(extent * 2.0)
        return CGSize(
            width: max(3.0, CGFloat(footprint.x) * scale),
            height: max(3.0, CGFloat(footprint.y) * scale)
        )
    }
}

private func localized(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
