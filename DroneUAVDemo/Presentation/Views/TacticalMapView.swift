import AppKit
import SceneKit
import SwiftUI
import simd

struct TacticalMapView: View {
    let snapshot: DroneSimulationViewModel.TerrainMapSnapshot
    let state: TacticalMapState
    let missionPlan: MissionPlan?
    let supportedLaunchModes: [LaunchMode]
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
            ForEach(availablePlanningModes) { mode in
                modeButton(mode)
            }
        }
    }

    private var availablePlanningModes: [TacticalMapMode] {
        TacticalMapMode.planningModes.filter { mode in
            mode != .launchObject || supportedLaunchModes.contains {
                $0.requiresLaunchObject && $0.isRuntimeImplemented
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
                if let launchPreview = state.launchPreview {
                    metricChip(
                        "tactical.map.metric.launch",
                        value: "\(Int(launchPreview.headingDegrees.rounded()))° • \(Int(launchPreview.corridorLengthMeters.rounded())) m"
                    )
                }
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
            case .launchObject:
                legendRow(color: GroundControlPalette.warning, key: "tactical.map.legend.launch_rail")
                legendRow(color: GroundControlPalette.accent, key: "tactical.map.legend.launch_corridor")
            case .dropZone:
                legendRow(color: GroundControlPalette.warning, key: "tactical.map.legend.drop_zone")
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

enum TerrainMapSatelliteTextureProvider {
    private static let textureSize = 512
    private static let cacheLock = NSLock()
    private static var cache: [TerrainPreset: CGImage] = [:]

    static func texture(for preset: TerrainPreset) -> CGImage {
        cacheLock.lock()
        if let cached = cache[preset] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let texture = makeTexture(for: preset)
        cacheLock.lock()
        cache[preset] = texture
        cacheLock.unlock()
        return texture
    }

    private static func makeTexture(for preset: TerrainPreset) -> CGImage {
        let style = TerrainMapSatelliteTextureStyle(preset: preset)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let textureDimension = CGFloat(textureSize)
        guard let context = CGContext(
            data: nil,
            width: textureSize,
            height: textureSize,
            bitsPerComponent: 8,
            bytesPerRow: textureSize * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return solidTexture(style.fallbackColor)
        }

        let bounds = CGRect(x: 0, y: 0, width: textureDimension, height: textureDimension)
        context.setFillColor(style.fallbackColor.cgColor)
        context.fill(bounds)

        if let albedo = albedoImage(for: preset) {
            drawTiled(albedo, into: context, tilePixels: style.tilePixels)
        }

        context.setBlendMode(.multiply)
        context.setFillColor(style.multiplyColor.withAlphaComponent(style.multiplyAlpha).cgColor)
        context.fill(bounds)

        context.setBlendMode(.overlay)
        context.setFillColor(NSColor.white.withAlphaComponent(style.highlightAlpha).cgColor)
        context.fill(CGRect(
            x: 0,
            y: textureDimension * 0.50,
            width: textureDimension,
            height: textureDimension * 0.50
        ))

        return context.makeImage() ?? solidTexture(style.fallbackColor)
    }

    private static func drawTiled(
        _ image: CGImage,
        into context: CGContext,
        tilePixels: CGFloat
    ) {
        let tile = max(16.0, tilePixels)
        var y: CGFloat = 0.0
        while y < CGFloat(textureSize) {
            var x: CGFloat = 0.0
            while x < CGFloat(textureSize) {
                context.draw(image, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
    }

    private static func albedoImage(for preset: TerrainPreset) -> CGImage? {
        let material: SCNMaterial? = switch preset {
        case .field, .forest:
            GenericGrassMaterialLoader.makeGrassMaterial(mapSizeMeters: 512.0)
        case .cargoYard:
            AsphaltMaterialLoader.makeAsphaltMaterial(mapSizeMeters: 512.0)
        case .city:
            AbandonedCityMaterialLoader.makeBrittleStoneMaterial(mapSizeMeters: 512.0)
        case .gridDemo:
            nil
        }

        guard let contents = material?.diffuse.contents else {
            return nil
        }
        return cgImage(from: contents)
    }

    private static func cgImage(from contents: Any) -> CGImage? {
        switch contents {
        case let image as CGImage:
            return image
        case let image as NSImage:
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        case let color as NSColor:
            return solidTexture(color)
        default:
            return nil
        }
    }

    private static func solidTexture(_ color: NSColor) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }
}

struct TerrainMapSatelliteTextureStyle {
    let fallbackColor: NSColor
    let multiplyColor: NSColor
    let multiplyAlpha: CGFloat
    let highlightAlpha: CGFloat
    let tilePixels: CGFloat

    init(preset: TerrainPreset) {
        switch preset {
        case .city:
            fallbackColor = NSColor(calibratedRed: 0.22, green: 0.21, blue: 0.18, alpha: 1.0)
            multiplyColor = NSColor(calibratedRed: 0.54, green: 0.56, blue: 0.50, alpha: 1.0)
            multiplyAlpha = 0.22
            highlightAlpha = 0.05
            tilePixels = 118.0
        case .cargoYard:
            fallbackColor = NSColor(calibratedRed: 0.18, green: 0.19, blue: 0.18, alpha: 1.0)
            multiplyColor = NSColor(calibratedRed: 0.58, green: 0.60, blue: 0.56, alpha: 1.0)
            multiplyAlpha = 0.20
            highlightAlpha = 0.04
            tilePixels = 120.0
        case .forest:
            fallbackColor = NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.08, alpha: 1.0)
            multiplyColor = NSColor(calibratedRed: 0.34, green: 0.48, blue: 0.30, alpha: 1.0)
            multiplyAlpha = 0.14
            highlightAlpha = 0.025
            tilePixels = 164.0
        case .field:
            fallbackColor = NSColor(calibratedRed: 0.17, green: 0.25, blue: 0.11, alpha: 1.0)
            multiplyColor = NSColor(calibratedRed: 0.42, green: 0.54, blue: 0.31, alpha: 1.0)
            multiplyAlpha = 0.13
            highlightAlpha = 0.035
            tilePixels = 168.0
        case .gridDemo:
            fallbackColor = NSColor(calibratedRed: 0.11, green: 0.15, blue: 0.11, alpha: 1.0)
            multiplyColor = NSColor(calibratedRed: 0.58, green: 0.66, blue: 0.52, alpha: 1.0)
            multiplyAlpha = 0.16
            highlightAlpha = 0.03
            tilePixels = 128.0
        }
    }
}

struct TerrainMapTerrainDetailRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEAD_BEEF : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
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

            drawMapBase(in: &context, projection: projection)
            context.clip(to: Path(projection.mapRect))
            drawSatelliteTexture(in: &context, projection: projection)
            drawSceneTerrainDetails(in: &context, projection: projection)
            drawObjects(in: &context, projection: projection)
            drawGrid(in: &context, projection: projection)
            drawGeofence(in: &context, projection: projection)
            drawServiceOverlays(in: &context, projection: projection)
            drawTrail(in: &context, projection: projection)
            drawZones(in: &context, projection: projection)
            drawLaunchObject(in: &context, projection: projection)
            drawMissionGeometry(in: &context, projection: projection)
            drawPreviewRoute(in: &context, projection: projection)
            drawActiveLeg(in: &context, projection: projection)
            drawPredictedPath(in: &context, projection: projection)
            drawPayloadImpact(in: &context, projection: projection)
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

    private func drawMapBase(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let rect = projection.mapRect
        context.fill(Path(rect), with: .color(backgroundColor.opacity(0.98)))

        let northShade = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.55)
        context.fill(Path(northShade), with: .color(Color.white.opacity(0.025)))

        let southShade = CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height * 0.5)
        context.fill(Path(southShade), with: .color(Color.black.opacity(0.06)))

        var vignette = Path()
        let inset = min(rect.width, rect.height) * 0.035
        vignette.addRect(rect)
        vignette.addRect(rect.insetBy(dx: inset, dy: inset))
        context.fill(
            vignette,
            with: .color(Color.black.opacity(0.14)),
            style: FillStyle(eoFill: true)
        )
    }

    private func drawSatelliteTexture(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let texture = TerrainMapSatelliteTextureProvider.texture(for: snapshot.preset)
        let image = Image(decorative: texture, scale: 1.0, orientation: .up)
        let halfExtent = max(1.0, snapshot.worldHalfExtent)
        let worldRect = projection.projectedRect(
            origin: SIMD2<Float>(-halfExtent, -halfExtent),
            size: SIMD2<Float>(halfExtent * 2.0, halfExtent * 2.0)
        )
        context.draw(image, in: worldRect.integral.insetBy(dx: -0.5, dy: -0.5))

        context.fill(Path(projection.mapRect), with: .color(satelliteColorGrade.opacity(0.18)))
    }

    private var satelliteColorGrade: Color {
        switch snapshot.preset {
        case .city:
            return Color(red: 0.10, green: 0.11, blue: 0.10)
        case .cargoYard:
            return Color(red: 0.08, green: 0.09, blue: 0.09)
        case .forest:
            return Color(red: 0.03, green: 0.10, blue: 0.04)
        case .field:
            return Color(red: 0.06, green: 0.12, blue: 0.04)
        case .gridDemo:
            return Color(red: 0.05, green: 0.07, blue: 0.06)
        }
    }

    private func drawSceneTerrainDetails(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard snapshot.preset == .field || snapshot.preset == .forest else {
            return
        }

        let coverageScale = max(1.0, snapshot.worldHalfExtent / 96.0)
        let detailScale = max(0.9, snapshot.mapScale.populationBudgetFactor * 0.58 + coverageScale * 0.42)
        let halfExtent = snapshot.worldHalfExtent * 0.92
        let isForest = snapshot.preset == .forest
        let primaryCount = isForest
            ? max(14, Int(12.0 + detailScale * 5.0))
            : max(5, Int(4.0 + detailScale * 1.8))
        let accentCount = isForest
            ? max(7, Int(5.0 + detailScale * 2.4))
            : max(2, Int(1.0 + detailScale * 0.8))
        let shadowCount = isForest
            ? max(8, Int(6.0 + detailScale * 2.2))
            : 0
        let seedOffset: UInt64 = isForest ? 0xF057 : 0xF13D
        var generator = TerrainMapTerrainDetailRandom(seed: snapshot.terrainSeed &+ seedOffset)

        for index in 0..<primaryCount {
            let width = Float.random(in: isForest ? 10.0...24.0 : 14.0...30.0, using: &generator)
            let height = Float.random(in: isForest ? 8.0...20.0 : 10.0...22.0, using: &generator)
            let color = index % 4 == 0
                ? terrainAccentColor(isForest: isForest)
                : terrainPrimaryColor(isForest: isForest)
            drawTerrainDetailPatch(
                width: width,
                height: height,
                halfExtent: halfExtent,
                color: color,
                projection: projection,
                generator: &generator,
                context: &context
            )
        }

        for _ in 0..<accentCount {
            drawTerrainDetailPatch(
                width: Float.random(in: 8.0...18.0, using: &generator),
                height: Float.random(in: 7.0...16.0, using: &generator),
                halfExtent: halfExtent,
                color: terrainAccentColor(isForest: isForest),
                projection: projection,
                generator: &generator,
                context: &context
            )
        }

        for _ in 0..<shadowCount {
            drawTerrainDetailPatch(
                width: Float.random(in: 5.0...11.0, using: &generator),
                height: Float.random(in: 4.0...10.0, using: &generator),
                halfExtent: halfExtent,
                color: Color.black.opacity(0.16),
                projection: projection,
                generator: &generator,
                context: &context
            )
        }
    }

    private func drawTerrainDetailPatch(
        width: Float,
        height: Float,
        halfExtent: Float,
        color: Color,
        projection: TerrainMapProjection,
        generator: inout TerrainMapTerrainDetailRandom,
        context: inout GraphicsContext
    ) {
        let position = SIMD2<Float>(
            Float.random(in: -halfExtent...halfExtent, using: &generator),
            Float.random(in: -halfExtent...halfExtent, using: &generator)
        )
        let rotation = CGFloat(Float.random(in: 0.0...(.pi * 2.0), using: &generator))

        let center = projection.project(position)
        let size = projection.projectedSize(for: SIMD2<Float>(width, height))
        let rect = CGRect(
            x: -size.width * 0.5,
            y: -size.height * 0.5,
            width: size.width,
            height: size.height
        )
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: rotation)
        let path = Path(ellipseIn: rect).applying(transform)
        context.fill(path, with: .color(color))
    }

    private func terrainPrimaryColor(isForest: Bool) -> Color {
        isForest
            ? Color(red: 0.18, green: 0.17, blue: 0.11).opacity(0.18)
            : Color(red: 0.45, green: 0.40, blue: 0.21).opacity(0.12)
    }

    private func terrainAccentColor(isForest: Bool) -> Color {
        isForest
            ? Color(red: 0.18, green: 0.24, blue: 0.12).opacity(0.15)
            : Color(red: 0.38, green: 0.44, blue: 0.20).opacity(0.10)
    }

    private func drawGrid(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        let divisions = max(1, MapViewportState.tacticalSectorDivisions)
        let halfExtent = max(1.0, snapshot.worldHalfExtent)
        let sectorStep = (halfExtent * 2.0) / Float(divisions)
        let subdivisionCount = gridSubdivisionCount(for: sectorStep, projection: projection)
        let minorStep = sectorStep / Float(subdivisionCount)
        let lineCount = divisions * subdivisionCount
        var minorPath = Path()
        var majorPath = Path()

        for index in 0...lineCount {
            let worldCoordinate = -halfExtent + Float(index) * minorStep
            let isMajorLine = index % subdivisionCount == 0
            if isMajorLine {
                appendGridLine(
                    coordinate: worldCoordinate,
                    halfExtent: halfExtent,
                    to: &majorPath,
                    projection: projection
                )
            } else {
                appendGridLine(
                    coordinate: worldCoordinate,
                    halfExtent: halfExtent,
                    to: &minorPath,
                    projection: projection
                )
            }
        }

        context.stroke(
            minorPath,
            with: .color(Color.white.opacity(0.075)),
            lineWidth: 0.5
        )
        context.stroke(
            majorPath,
            with: .color(Color.white.opacity(0.25)),
            lineWidth: 0.9
        )

        drawGridAxisLabels(
            in: &context,
            projection: projection,
            halfExtent: halfExtent,
            sectorStep: sectorStep,
            divisions: divisions
        )
    }

    private func appendGridLine(
        coordinate: Float,
        halfExtent: Float,
        to path: inout Path,
        projection: TerrainMapProjection
    ) {
        path.move(to: projection.project(SIMD2<Float>(coordinate, -halfExtent)))
        path.addLine(to: projection.project(SIMD2<Float>(coordinate, halfExtent)))
        path.move(to: projection.project(SIMD2<Float>(-halfExtent, coordinate)))
        path.addLine(to: projection.project(SIMD2<Float>(halfExtent, coordinate)))
    }

    private func gridSubdivisionCount(
        for sectorStep: Float,
        projection: TerrainMapProjection
    ) -> Int {
        let origin = projection.project(.zero)
        let next = projection.project(SIMD2<Float>(sectorStep, 0.0))
        let projectedStep = abs(next.x - origin.x)
        if projectedStep > 260.0 {
            return 4
        }
        if projectedStep > 150.0 {
            return 2
        }
        return 1
    }

    private func drawGridAxisLabels(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection,
        halfExtent: Float,
        sectorStep: Float,
        divisions: Int
    ) {
        let rect = projection.mapRect
        let labelBounds = rect.insetBy(dx: 16.0, dy: 16.0)

        for column in 0..<divisions {
            let worldX = -halfExtent + (Float(column) + 0.5) * sectorStep
            let screenX = projection.project(SIMD2<Float>(worldX, 0.0)).x
            guard (labelBounds.minX...labelBounds.maxX).contains(screenX) else {
                continue
            }
            drawGridAxisLabel(
                "\(column + 1)",
                at: CGPoint(x: screenX, y: rect.minY + 9.0),
                anchor: .top,
                context: &context
            )
        }

        for row in 0..<divisions {
            let worldY = -halfExtent + (Float(row) + 0.5) * sectorStep
            let screenY = projection.project(SIMD2<Float>(0.0, worldY)).y
            guard (labelBounds.minY...labelBounds.maxY).contains(screenY) else {
                continue
            }
            drawGridAxisLabel(
                gridRowLabel(row),
                at: CGPoint(x: rect.minX + 9.0, y: screenY),
                anchor: .leading,
                context: &context
            )
        }
    }

    private func drawGridAxisLabel(
        _ label: String,
        at point: CGPoint,
        anchor: UnitPoint,
        context: inout GraphicsContext
    ) {
        let text = Text(label)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
        context.draw(
            text.foregroundColor(Color.black.opacity(0.52)),
            at: CGPoint(x: point.x + 1.0, y: point.y + 1.0),
            anchor: anchor
        )
        context.draw(
            text.foregroundColor(Color.white.opacity(0.50)),
            at: point,
            anchor: anchor
        )
    }

    private func gridRowLabel(_ index: Int) -> String {
        var value = max(0, index)
        var label = ""

        repeat {
            let remainder = value % 26
            if let scalar = UnicodeScalar(65 + remainder) {
                label = String(scalar) + label
            } else {
                label = "A" + label
            }
            value = value / 26 - 1
        } while value >= 0

        return label
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

        var warningBand = Path()
        warningBand.addRect(criticalRect)
        warningBand.addRect(warningRect)
        context.fill(
            warningBand,
            with: .color(GroundControlPalette.warning.opacity(0.075)),
            style: FillStyle(eoFill: true)
        )

        var criticalBand = Path()
        criticalBand.addRect(boundaryRect)
        criticalBand.addRect(criticalRect)
        context.fill(
            criticalBand,
            with: .color(GroundControlPalette.danger.opacity(0.075)),
            style: FillStyle(eoFill: true)
        )

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
            with: .color(Color.black.opacity(0.42)),
            style: StrokeStyle(lineWidth: 3.0, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            trailPath,
            with: .color(GroundControlPalette.warning.opacity(0.58)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawZones(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        for zone in state.workingDraft.zones where zone.type == .dropZone {
            let center = projection.project(zone.center)
            let radius = projection.projectedRadiusSize(for: zone.radius)
            let rect = CGRect(
                x: center.x - radius.width,
                y: center.y - radius.height,
                width: radius.width * 2.0,
                height: radius.height * 2.0
            )

            context.fill(Path(ellipseIn: rect), with: .color(GroundControlPalette.warning.opacity(0.14)))
            context.stroke(Path(ellipseIn: rect), with: .color(GroundControlPalette.warning.opacity(0.92)), lineWidth: 1.6)
            context.draw(
                Text(String(format: NSLocalizedString("tactical.map.overlay.drop_zone_radius", comment: ""), zone.radius))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(GroundControlPalette.warning),
                at: CGPoint(x: rect.midX, y: rect.maxY + 10),
                anchor: .center
            )
        }
    }

    private func drawLaunchObject(
        in context: inout GraphicsContext,
        projection: TerrainMapProjection
    ) {
        guard let preview = state.launchPreview else {
            return
        }

        let isActive = state.mode == .launchObject
        let tint: Color = preview.isValid
            ? (preview.mode == .catapult ? GroundControlPalette.warning : GroundControlPalette.accent)
            : GroundControlPalette.danger
        let origin = projection.project(preview.origin)
        let corridorEnd = projection.project(preview.corridorEnd)

        var corridor = Path()
        corridor.move(to: origin)
        corridor.addLine(to: corridorEnd)
        context.stroke(
            corridor,
            with: .color(Color.black.opacity(0.46)),
            style: StrokeStyle(lineWidth: isActive ? 4.4 : 3.0, lineCap: .round, dash: [7.0, 5.0])
        )
        context.stroke(
            corridor,
            with: .color(tint.opacity(isActive ? 0.96 : 0.62)),
            style: StrokeStyle(lineWidth: isActive ? 2.2 : 1.3, lineCap: .round, dash: [7.0, 5.0])
        )

        if let railEnd = preview.railEnd {
            var rail = Path()
            rail.move(to: origin)
            rail.addLine(to: projection.project(railEnd))
            context.stroke(rail, with: .color(Color.black.opacity(0.62)), lineWidth: isActive ? 7.0 : 5.0)
            context.stroke(rail, with: .color(tint.opacity(0.96)), lineWidth: isActive ? 3.8 : 2.6)
        }

        let markerRect = CGRect(x: origin.x - 7.0, y: origin.y - 7.0, width: 14.0, height: 14.0)
        context.fill(Path(ellipseIn: markerRect), with: .color(tint.opacity(0.96)))
        context.stroke(Path(ellipseIn: markerRect), with: .color(Color.white.opacity(0.76)), lineWidth: 1.0)

        let deltaX = corridorEnd.x - origin.x
        let deltaY = corridorEnd.y - origin.y
        let deltaLength = max(CGFloat(0.001), hypot(deltaX, deltaY))
        let unitX = deltaX / deltaLength
        let unitY = deltaY / deltaLength
        let normalX = -unitY
        let normalY = unitX
        var arrow = Path()
        arrow.move(to: corridorEnd)
        arrow.addLine(to: CGPoint(
            x: corridorEnd.x - unitX * 12.0 + normalX * 5.0,
            y: corridorEnd.y - unitY * 12.0 + normalY * 5.0
        ))
        arrow.move(to: corridorEnd)
        arrow.addLine(to: CGPoint(
            x: corridorEnd.x - unitX * 12.0 - normalX * 5.0,
            y: corridorEnd.y - unitY * 12.0 - normalY * 5.0
        ))
        context.stroke(arrow, with: .color(tint.opacity(0.96)), lineWidth: 2.0)

        context.draw(
            Text(LocalizedStringKey(preview.objectType.titleKey))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(tint),
            at: CGPoint(x: origin.x, y: origin.y + 17.0),
            anchor: .center
        )
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
            with: .color(Color.black.opacity(0.46)),
            style: StrokeStyle(
                lineWidth: state.mode == .waypoint ? 4.2 : 2.8,
                lineCap: .round,
                lineJoin: .round
            )
        )
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
            with: .color(Color.black.opacity(0.34)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round, dash: [4.0, 4.0])
        )
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
            with: .color(Color.black.opacity(0.50)),
            style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round)
        )
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
            with: .color(Color.black.opacity(0.38)),
            style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round, dash: [4.0, 3.0])
        )
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
                context.fill(
                    Path(roundedRect: rect.offsetBy(dx: 1.2, dy: 1.6), cornerRadius: 1.5, style: .continuous),
                    with: .color(Color.black.opacity(0.30))
                )
                context.fill(path, with: .color(Color(red: 0.58, green: 0.60, blue: 0.56).opacity(0.76)))
                context.stroke(path, with: .color(Color.white.opacity(0.14)), lineWidth: 0.6)
            case .tree:
                drawSatelliteTree(object, center: center, size: size, context: &context)
            case .rock:
                let rockRect = rect.insetBy(dx: -0.4, dy: 0.2)
                context.fill(Path(ellipseIn: rockRect.offsetBy(dx: 0.8, dy: 0.9)), with: .color(Color.black.opacity(0.20)))
                context.fill(Path(ellipseIn: rockRect), with: .color(Color(red: 0.66, green: 0.65, blue: 0.58).opacity(0.68)))
                context.stroke(Path(ellipseIn: rockRect), with: .color(Color.white.opacity(0.10)), lineWidth: 0.5)
            case .cargoContainer:
                let path = Path(roundedRect: rect, cornerRadius: 1.2, style: .continuous)
                context.fill(
                    Path(roundedRect: rect.offsetBy(dx: 1.0, dy: 1.2), cornerRadius: 1.2, style: .continuous),
                    with: .color(Color.black.opacity(0.28))
                )
                context.fill(path, with: .color(Color(red: 0.70, green: 0.32, blue: 0.17).opacity(0.80)))
                context.stroke(path, with: .color(Color.white.opacity(0.12)), lineWidth: 0.55)
            case .crate:
                let path = Path(roundedRect: rect, cornerRadius: 1.4, style: .continuous)
                context.fill(path, with: .color(Color(red: 0.66, green: 0.51, blue: 0.24).opacity(0.76)))
                context.stroke(path, with: .color(Color.black.opacity(0.22)), lineWidth: 0.55)
            case .pole:
                let poleRect = CGRect(
                    x: center.x - 1.2,
                    y: center.y - max(3.0, size.height * 0.5),
                    width: 2.4,
                    height: max(6.0, size.height)
                )
                context.fill(Path(roundedRect: poleRect, cornerRadius: 1.0, style: .continuous), with: .color(Color(red: 0.80, green: 0.67, blue: 0.28).opacity(0.70)))
            case .marker:
                var markerPath = Path()
                markerPath.move(to: CGPoint(x: center.x, y: center.y - size.height * 0.5))
                markerPath.addLine(to: CGPoint(x: center.x + size.width * 0.5, y: center.y))
                markerPath.addLine(to: CGPoint(x: center.x, y: center.y + size.height * 0.5))
                markerPath.addLine(to: CGPoint(x: center.x - size.width * 0.5, y: center.y))
                markerPath.closeSubpath()
                context.fill(markerPath, with: .color(Color(red: 0.31, green: 0.73, blue: 0.86).opacity(0.70)))
                context.stroke(markerPath, with: .color(Color.black.opacity(0.22)), lineWidth: 0.55)
            }
        }
    }

    private func drawSatelliteTree(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        center: CGPoint,
        size: CGSize,
        context: inout GraphicsContext
    ) {
        let isForest = snapshot.preset == .forest
        let width = max(isForest ? 5.5 : 3.0, size.width * (isForest ? 1.15 : 0.58))
        let height = max(isForest ? 5.0 : 3.0, size.height * (isForest ? 1.05 : 0.52))
        let baseRect = CGRect(
            x: center.x - width * 0.5,
            y: center.y - height * 0.5,
            width: width,
            height: height
        )
        let shadowRect = baseRect.offsetBy(
            dx: 0.8 + treeNoise(object, salt: 17.0) * 0.8,
            dy: 1.0 + treeNoise(object, salt: 31.0) * 0.8
        )
        context.fill(
            Path(ellipseIn: shadowRect),
            with: .color(Color.black.opacity(isForest ? 0.20 : 0.12))
        )

        context.fill(
            Path(ellipseIn: baseRect),
            with: .color(Color(red: 0.04, green: 0.13, blue: 0.05).opacity(isForest ? 0.42 : 0.22))
        )
    }

    private func treeNoise(
        _ object: DroneSimulationViewModel.TerrainMapObject,
        salt: CGFloat
    ) -> CGFloat {
        let value = sin(
            CGFloat(object.position.x) * 12.9898
                + CGFloat(object.position.y) * 78.233
                + CGFloat(object.footprint.x) * 37.719
                + salt
        ) * 43758.5453
        return value - floor(value)
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
        let dockRect = CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)
        let dockPath = Path(roundedRect: dockRect, cornerRadius: 2.0, style: .continuous)
        context.fill(
            Path(roundedRect: dockRect.offsetBy(dx: 1.2, dy: 1.4), cornerRadius: 2.0, style: .continuous),
            with: .color(Color.black.opacity(0.42))
        )
        context.fill(dockPath, with: .color(GroundControlPalette.warning.opacity(0.94)))
        context.stroke(dockPath, with: .color(Color.white.opacity(0.62)), lineWidth: 0.8)

        var crosshair = Path()
        crosshair.move(to: CGPoint(x: center.x - 10, y: center.y))
        crosshair.addLine(to: CGPoint(x: center.x + 10, y: center.y))
        crosshair.move(to: CGPoint(x: center.x, y: center.y - 10))
        crosshair.addLine(to: CGPoint(x: center.x, y: center.y + 10))
        context.stroke(crosshair, with: .color(GroundControlPalette.warning.opacity(0.76)), lineWidth: 1.0)
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

            let pinRadius: CGFloat = waypoint.isActive || waypoint.isAssistSelected ? 8.5 : 7.4
            let bubbleCenter = CGPoint(x: center.x, y: center.y - pinRadius - 5.0)
            let bubbleRect = CGRect(
                x: bubbleCenter.x - pinRadius,
                y: bubbleCenter.y - pinRadius,
                width: pinRadius * 2.0,
                height: pinRadius * 2.0
            )
            var pointerPath = Path()
            pointerPath.move(to: center)
            pointerPath.addLine(to: CGPoint(x: center.x - pinRadius * 0.52, y: bubbleCenter.y + pinRadius * 0.44))
            pointerPath.addLine(to: CGPoint(x: center.x + pinRadius * 0.52, y: bubbleCenter.y + pinRadius * 0.44))
            pointerPath.closeSubpath()

            context.fill(pointerPath.offsetBy(dx: 1.2, dy: 1.5), with: .color(Color.black.opacity(0.42)))
            context.fill(Path(ellipseIn: bubbleRect.offsetBy(dx: 1.2, dy: 1.5)), with: .color(Color.black.opacity(0.42)))
            context.fill(pointerPath, with: .color(tint.opacity(0.96)))
            context.fill(Path(ellipseIn: bubbleRect), with: .color(tint.opacity(0.98)))
            context.stroke(pointerPath, with: .color(Color.white.opacity(0.50)), lineWidth: 0.7)
            context.stroke(Path(ellipseIn: bubbleRect), with: .color(Color.white.opacity(0.58)), lineWidth: 0.8)

            let rect = bubbleRect
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
                Text(waypoint.label)
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .foregroundColor(.white),
                at: bubbleCenter,
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

        context.fill(Path(ellipseIn: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)), with: .color(GroundControlPalette.warning.opacity(0.12)))
        context.fill(dronePath.offsetBy(dx: 1.2, dy: 1.5), with: .color(Color.black.opacity(0.46)))
        context.fill(dronePath, with: .color(GroundControlPalette.warning))
        context.stroke(dronePath, with: .color(Color.white.opacity(0.68)), lineWidth: 1.0)

        let bodyRect = CGRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4)
        context.fill(Path(ellipseIn: bodyRect), with: .color(Color.white.opacity(0.92)))
    }
}

extension TerrainMapProjection {
    func projectedRect(origin: SIMD2<Float>, size: SIMD2<Float>) -> CGRect {
        let first = project(origin)
        let second = project(origin + size)
        return CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)
        )
    }

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
