import SwiftUI
import SceneKit
import AppKit
import simd

/// Browser and viewer for photogrammetric mesh tiles.
///
/// The download-consent flow is the reason this screen exists in its own right rather than being
/// a button somewhere. A single tile is one to three gigabytes and the full Helsinki set is about
/// 190 GB, so the user is shown the whole catalogue with real sizes, told what a specific tile
/// will cost both compressed and unpacked, and nothing is fetched until they say so.
@MainActor
final class UAVWorldMeshBrowserModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case loadingCatalog
        case failed(String)
        case ready
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var tiles: [MeshTileDescriptor] = []
    @Published private(set) var scene: SCNScene?
    @Published private(set) var sceneToken = 0
    @Published private(set) var viewerStatistics: UAVWorldMeshStreamer.Statistics?
    @Published var pendingConfirmation: MeshTileDescriptor?

    let source = MeshTileSource.helsinki2017
    let store = MeshTileStore()

    /// Tiles are ordered by distance from here, so the city centre is at the top of the list
    /// rather than whatever the server happened to list first.
    let referenceCoordinate = GeoCoordinate(latitudeDegrees: 60.1695, longitudeDegrees: 24.9522)

    private(set) var streamer: UAVWorldMeshStreamer?
    private var originOffset = SIMD3<Double>(repeating: 0)

    var totalCatalogBytes: Int64 {
        tiles.reduce(0) { $0 + $1.compressedBytes }
    }

    var availableSpace: Int64 { store.availableCapacityBytes() }

    /// Shown with `~` for the home directory, the way a path is normally quoted to a user.
    var storageDirectoryPath: String {
        (store.rootDirectory(for: source).path as NSString).abbreviatingWithTildeInPath
    }

    func revealStorageDirectory() {
        let directory = store.rootDirectory(for: source)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Catalog

    func loadCatalog() {
        guard status != .loadingCatalog else { return }
        status = .loadingCatalog
        store.refreshInstalled(source: source)

        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = MeshTileCatalog(source: self.source)
                let fetched = try await catalog.fetch()
                let reference = self.referenceCoordinate
                let sorted = fetched.sorted {
                    $0.distanceMeters(to: reference) < $1.distanceMeters(to: reference)
                }
                await MainActor.run {
                    self.tiles = sorted
                    self.status = .ready
                }
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func isInstalled(_ tile: MeshTileDescriptor) -> Bool {
        store.installedKeys.contains(tile.key)
    }

    // MARK: - Download

    /// Called only from the confirmation sheet, after the user has seen the sizes.
    func confirmDownload(_ tile: MeshTileDescriptor) {
        pendingConfirmation = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.store.install(source: self.source, tile: tile)
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    func delete(_ tile: MeshTileDescriptor) {
        store.remove(source: source, key: tile.key)
    }

    // MARK: - Viewing

    func open(_ tile: MeshTileDescriptor) {
        let directory = store.tileDirectory(for: source, key: tile.key)
        Task { [weak self] in
            guard let self else { return }
            do {
                // Indexing only reads file names and one small XML, so it is safe to do here
                // even for a tile holding fourteen thousand files.
                let index = try ContextCaptureTileIndex(rootURL: directory)
                await MainActor.run {
                    self.installStreamer(index: index, tile: tile)
                }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func installStreamer(index: ContextCaptureTileIndex, tile: MeshTileDescriptor) {
        // Place the scene origin at the tile's centre. The tile key gives its projected origin,
        // and the export's own SRSOrigin gives the offset already baked into the vertices.
        guard let projected = source.projectedOrigin(forKey: tile.key) else { return }
        let centreEasting = projected.easting + source.tileSideMeters * 0.5
        let centreNorthing = projected.northing + source.tileSideMeters * 0.5
        let offset = SIMD3<Double>(
            index.georeference.originEasting - centreEasting,
            index.georeference.originNorthing - centreNorthing,
            0
        )
        originOffset = offset

        let cacheURL = store.tileDirectory(for: source, key: tile.key)
            .appendingPathComponent("bounds-cache.json")
        let tree = MeshQuadtree.build(index: index, originOffset: offset, cacheURL: cacheURL)

        let streamer = UAVWorldMeshStreamer(tree: tree, originOffset: offset)
        streamer.preloadRoots()
        self.streamer = streamer

        let scene = SCNScene()
        scene.rootNode.addChildNode(streamer.rootNode)
        scene.rootNode.addChildNode(
            UAVWorldSceneAssembler.makeSunNode(spanMeters: Float(source.tileSideMeters))
        )
        scene.lightingEnvironment.contents = UAVWorldSceneAssembler.makeSkyEnvironment()
        scene.lightingEnvironment.intensity = 1.5
        scene.background.contents = NSColor(calibratedRed: 0.46, green: 0.54, blue: 0.64, alpha: 1)

        self.scene = scene
        self.sceneToken += 1
    }

    /// Driven by the viewer's display link.
    func updateStreaming(camera: MeshStreamingPolicy.Camera) {
        guard let streamer else { return }
        streamer.update(camera: camera)
        viewerStatistics = streamer.statistics
    }
}

// MARK: - Viewer

private struct MeshViewerRepresentable: NSViewRepresentable {
    let scene: SCNScene?
    let sceneToken: Int
    let tileSideMeters: Double
    let onCameraChanged: (MeshStreamingPolicy.Camera) -> Void

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling2X
        view.backgroundColor = NSColor(calibratedRed: 0.46, green: 0.54, blue: 0.64, alpha: 1)
        view.rendersContinuously = true
        context.coordinator.onCameraChanged = onCameraChanged
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onCameraChanged = onCameraChanged
        guard context.coordinator.installedToken != sceneToken else { return }
        context.coordinator.installedToken = sceneToken

        view.scene = scene
        guard let scene else { return }

        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = 20000
        camera.fieldOfView = 55
        let node = SCNNode()
        node.camera = camera
        let distance = CGFloat(tileSideMeters * 0.55)
        node.position = SCNVector3(distance * 0.6, distance * 0.5, distance * 0.6)
        node.look(at: SCNVector3(0, 30, 0))
        scene.rootNode.addChildNode(node)
        view.pointOfView = node
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reads the camera each rendered frame and hands plain numbers to the model.
    ///
    /// `renderer(_:updateAtTime:)` is not guaranteed to run on the main thread and must not touch
    /// `@Published` state directly — a lesson this project has already paid for — so the camera
    /// is sampled here into value types and the actual streaming update is hopped onto the main
    /// actor.
    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        var installedToken = -1
        var onCameraChanged: ((MeshStreamingPolicy.Camera) -> Void)?
        private var lastUpdate: TimeInterval = 0

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // Selection is cheap but the scene-graph edits it triggers are not free; a few times
            // a second is plenty for camera movement and keeps the render thread clear.
            guard time - lastUpdate > 0.15 else { return }
            lastUpdate = time

            guard let pointOfView = renderer.pointOfView,
                  let camera = pointOfView.camera else { return }

            let transform = pointOfView.simdWorldTransform
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let forward = -SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
            let fov = Float(camera.fieldOfView) * .pi / 180.0
            let size = renderer.currentViewport.size
            let height = Float(max(size.height, 1))
            let aspect = Float(max(size.width, 1)) / height

            let sample = MeshStreamingPolicy.Camera(
                position: position,
                forward: forward,
                verticalFieldOfViewRadians: fov,
                viewportHeightPixels: height,
                aspectRatio: aspect
            )
            let callback = onCameraChanged
            Task { @MainActor in callback?(sample) }
        }
    }
}

// MARK: - Window content

struct UAVWorldMeshBrowserView: View {
    @StateObject private var model = UAVWorldMeshBrowserModel()
    @ObservedObject private var storeObserver: MeshTileStore

    init() {
        let model = UAVWorldMeshBrowserModel()
        _model = StateObject(wrappedValue: model)
        _storeObserver = ObservedObject(wrappedValue: model.store)
    }

    var body: some View {
        HSplitView {
            catalogPanel
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 520)

            ZStack {
                MeshViewerRepresentable(
                    scene: model.scene,
                    sceneToken: model.sceneToken,
                    tileSideMeters: model.source.tileSideMeters,
                    onCameraChanged: { model.updateStreaming(camera: $0) }
                )
                if model.scene == nil {
                    Text("world.mesh.viewer.empty")
                        .foregroundStyle(.secondary)
                }
                if let statistics = model.viewerStatistics {
                    VStack {
                        Spacer()
                        HStack {
                            statisticsOverlay(statistics)
                            Spacer()
                        }
                    }
                    .padding(12)
                }
            }
            .frame(minWidth: 520)
        }
        .frame(minWidth: 1000, minHeight: 680)
        .onAppear { model.loadCatalog() }
        .sheet(item: $model.pendingConfirmation) { tile in
            confirmationSheet(tile)
        }
    }

    // MARK: Catalog panel

    private var catalogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("world.mesh.browser.title")
                    .font(.title3.weight(.semibold))
                Text(model.source.displayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                // The headline warning: the whole dataset is far too big to fetch casually, and
                // the user should know that before picking anything.
                if !model.tiles.isEmpty {
                    Label(
                        L10n.f(
                            "world.mesh.browser.dataset_warning",
                            model.tiles.count,
                            model.totalCatalogBytes.formattedByteSize
                        ),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    Text(L10n.f("world.mesh.browser.free_space", model.availableSpace.formattedByteSize))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Where the gigabytes actually go. Application Support is hidden in Finder by
                    // default, so a user who wants to audit or reclaim the space cannot find it
                    // without being told — and being told is the least this owes them.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("world.mesh.browser.location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("world.mesh.browser.reveal") {
                                model.revealStorageDirectory()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Text(model.storageDirectoryPath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(L10n.f("world.mesh.browser.vintage", model.source.captureYear))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            switch model.status {
            case .loadingCatalog:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("world.mesh.browser.loading")
                }
                .font(.caption)
                .padding(16)
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(16)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ready:
                tileList
            }

            if let progress = storeObserver.progress {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(
                            progress.isExtracting
                                ? L10n.f("world.mesh.browser.extracting", progress.tileKey)
                                : L10n.f("world.mesh.browser.downloading", progress.tileKey)
                        )
                        .font(.caption)
                        Spacer()
                        if !progress.isExtracting {
                            Text(progress.percentText)
                                .font(.caption.monospacedDigit().weight(.semibold))
                        }
                    }

                    if progress.isExtracting {
                        // Unpacking gives no byte-level feedback, so an indeterminate bar is the
                        // honest form — a full bar would read as "finished" while several
                        // gigabytes are still being written.
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: progress.fraction)
                        Text("\(progress.receivedBytes.formattedByteSize) / \(progress.expectedBytes.formattedByteSize)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    private var tileList: some View {
        List(model.tiles) { tile in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.key)
                        .font(.system(.body, design: .monospaced))
                    Text(
                        L10n.f(
                            "world.mesh.browser.tile_detail",
                            tile.compressedBytes.formattedByteSize,
                            tile.estimatedExtractedBytes.formattedByteSize,
                            Int((tile.distanceMeters(to: model.referenceCoordinate) / 100).rounded()) * 100
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isInstalled(tile) {
                    Button("world.mesh.browser.open") { model.open(tile) }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { model.delete(tile) } label: {
                        Image(systemName: "trash")
                    }
                } else {
                    Button("world.mesh.browser.download") {
                        model.pendingConfirmation = tile
                    }
                    .disabled(storeObserver.progress != nil)
                }
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
    }

    // MARK: Confirmation

    private func confirmationSheet(_ tile: MeshTileDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("world.mesh.confirm.title")
                .font(.headline)

            Text(L10n.f("world.mesh.confirm.body", tile.key))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                confirmRow("world.mesh.confirm.download_size", tile.compressedBytes.formattedByteSize)
                confirmRow("world.mesh.confirm.disk_size", tile.estimatedExtractedBytes.formattedByteSize)
                confirmRow("world.mesh.confirm.total", tile.totalDiskBytes.formattedByteSize)
                confirmRow("world.mesh.confirm.available", model.availableSpace.formattedByteSize)
            }
            .font(.callout)

            Text("world.mesh.confirm.note")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("© \(model.source.attribution.displayName) — \(model.source.attribution.license)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("world.mesh.confirm.cancel") { model.pendingConfirmation = nil }
                Button("world.mesh.confirm.proceed") { model.confirmDownload(tile) }
                    .keyboardShortcut(.defaultAction)
                    // Only blocked when the free space is both known and genuinely too small.
                    .disabled(model.availableSpace > 0 && model.availableSpace < tile.totalDiskBytes)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func confirmRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(key))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private func statisticsOverlay(_ statistics: UAVWorldMeshStreamer.Statistics) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.f("world.mesh.viewer.nodes", statistics.visibleNodes, statistics.loadedGeometries))
            Text(L10n.f("world.mesh.viewer.triangles", statistics.triangles))
            Text(L10n.f("world.mesh.viewer.pending", statistics.pendingLoads, statistics.substitutedByAncestor))
            Text(String(format: "%.2f ms", statistics.lastSelectionMilliseconds))
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }
}
