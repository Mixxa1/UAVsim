import SwiftUI
import SceneKit
import AppKit

/// Standalone authoring window for real-world map packages.
///
/// Deliberately separate from the flight scene: a region can be fetched, built, inspected and
/// saved here without any of it touching the simulation. That keeps the risky part of this work
/// — integrating a five-hundred-building city into the existing scene and physics budget —
/// behind a boundary, so the geometry can be judged on its own first.
@MainActor
final class UAVWorldPreviewModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case working(String)
        case ready(String)
        case failed(String)
    }

    @Published var latitude = 40.7075
    @Published var longitude = -74.0113
    @Published var sideLengthMeters = 1000.0
    @Published var displayName = "New York — Lower Manhattan"
    @Published var regionName = "New York, USA"
    @Published var geoidSeparationMeters = -32.7

    @Published private(set) var status: Status = .idle
    @Published private(set) var scene: SCNScene?
    /// Bumped whenever a new scene is installed, so the representable knows to re-frame the
    /// camera without comparing scene object identity on every layout pass.
    @Published private(set) var sceneToken = 0
    @Published private(set) var report: [String] = []
    @Published private(set) var savedURL: URL?

    private var buildResult: UAVWorldBuildResult?
    private var importTask: Task<Void, Never>?

    var isWorking: Bool {
        if case .working = status { return true }
        return false
    }

    var canSave: Bool { buildResult != nil && !isWorking }

    // MARK: - Presets

    struct Preset: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let latitude: Double
        let longitude: Double
        let regionName: String
        let geoidSeparationMeters: Double
    }

    /// A spread of places with deliberately different open-data quality, because the point of a
    /// constructor is that fidelity follows the source. Lower Manhattan is exceptionally
    /// well-mapped; most regions are not, and seeing that difference is the fastest way to
    /// understand what the importer can and cannot promise.
    static let presets: [Preset] = [
        // Helsinki first: it is the one region where a real photogrammetric mesh is also
        // available, so it is the reference point for comparing what this procedural path
        // produces against what the mesh path produces for the same streets.
        Preset(title: "Helsinki — Keskusta", latitude: 60.1699, longitude: 24.9460,
               regionName: "Helsinki, Finland", geoidSeparationMeters: 18.5),
        Preset(title: "New York — Lower Manhattan", latitude: 40.7075, longitude: -74.0113,
               regionName: "New York, USA", geoidSeparationMeters: -32.7),
        Preset(title: "Chicago — The Loop", latitude: 41.8825, longitude: -87.6300,
               regionName: "Chicago, USA", geoidSeparationMeters: -33.6),
        Preset(title: "Amsterdam — Centrum", latitude: 52.3730, longitude: 4.8925,
               regionName: "Amsterdam, Netherlands", geoidSeparationMeters: 43.2),
        Preset(title: "Prague — Staré Město", latitude: 50.0870, longitude: 14.4210,
               regionName: "Prague, Czechia", geoidSeparationMeters: 44.5),
        Preset(title: "Tokyo — Marunouchi", latitude: 35.6810, longitude: 139.7660,
               regionName: "Tokyo, Japan", geoidSeparationMeters: 36.7)
    ]

    func apply(_ preset: Preset) {
        latitude = preset.latitude
        longitude = preset.longitude
        displayName = preset.title
        regionName = preset.regionName
        geoidSeparationMeters = preset.geoidSeparationMeters
    }

    // MARK: - Import

    func startImport() {
        importTask?.cancel()
        savedURL = nil

        guard let bounds = GeoBoundingBox(
            center: GeoCoordinate(latitudeDegrees: latitude, longitudeDegrees: longitude),
            sideLengthMeters: sideLengthMeters
        ) else {
            status = .failed(L10n.s("world.import.error.invalid_region"))
            return
        }

        let request = UAVWorldBuildRequest(
            identifier: Self.identifier(from: displayName),
            displayName: displayName,
            regionName: regionName,
            bounds: bounds,
            geoidSeparationMeters: geoidSeparationMeters
        )

        status = .working(L10n.s("world.preview.status.fetching"))
        report = []

        importTask = Task { [weak self] in
            guard let self else { return }
            let builder = UAVWorldBuilder()
            let source = OverpassBuildingSource()

            do {
                let result = try await builder.build(request: request, sources: [source])
                if Task.isCancelled { return }

                await MainActor.run {
                    self.status = .working(L10n.s("world.preview.status.building"))
                }

                let assembly = UAVWorldSceneAssembler.assemble(buildings: result.buildings)
                let scene = Self.makeScene(assembly: assembly)
                if Task.isCancelled { return }

                await MainActor.run {
                    self.buildResult = result
                    self.scene = scene
                    self.sceneToken += 1
                    self.report = Self.makeReport(result: result, assembly: assembly)
                    self.status = .ready(
                        L10n.f("world.preview.status.ready", result.buildings.count)
                    )
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancel() {
        importTask?.cancel()
        importTask = nil
        status = .idle
    }

    func save() {
        guard let buildResult else { return }
        do {
            let url = try UAVWorldPackageStore().write(buildResult)
            savedURL = url
            status = .ready(L10n.f("world.preview.status.saved", url.lastPathComponent))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func revealSavedPackage() {
        guard let savedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([savedURL])
    }

    // MARK: - Reporting

    private static func makeReport(
        result: UAVWorldBuildResult,
        assembly: UAVWorldSceneAssembler.Assembly
    ) -> [String] {
        let statistics = assembly.statistics
        let diagnostics = result.diagnostics

        var lines: [String] = []
        lines.append(L10n.f("world.preview.report.buildings", result.buildings.count))
        lines.append(
            L10n.f(
                "world.preview.report.osm_layers",
                result.manifest.statistics.waterPolygonCount,
                result.manifest.statistics.roadSegmentCount,
                result.manifest.statistics.bridgeCount,
                result.manifest.statistics.vegetationCount
            )
        )
        lines.append(
            L10n.f(
                "world.preview.report.measured",
                Int((result.manifest.statistics.measuredHeightFraction * 100).rounded())
            )
        )
        lines.append(L10n.f("world.preview.report.triangles", statistics.triangles))
        lines.append(L10n.f("world.preview.report.tallest", Int(statistics.tallestMeters.rounded())))
        lines.append(
            L10n.f(
                "world.preview.report.rejected",
                diagnostics.rejectedSliver,
                diagnostics.rejectedDegenerate,
                diagnostics.mergedDuplicates
            )
        )
        if statistics.skippedGeometryFailures > 0 {
            lines.append(
                L10n.f("world.preview.report.geometry_failures", statistics.skippedGeometryFailures)
            )
        }

        // Facade mix: the single most useful check that the classifier produced a plausible
        // city rather than a monoculture.
        var byClass: [UAVWorldFacadeClass: Int] = [:]
        for building in result.buildings {
            byClass[building.facadeClass, default: 0] += 1
        }
        let mix = byClass
            .sorted { $0.value > $1.value }
            .map { "\($0.key.rawValue) \($0.value)" }
            .joined(separator: ", ")
        lines.append(L10n.f("world.preview.report.facade_mix", mix))

        for attribution in result.manifest.attributions {
            lines.append("© \(attribution.displayName) — \(attribution.license)")
        }
        return lines
    }

    private static func identifier(from displayName: String) -> String {
        let lowered = displayName.lowercased()
        let allowed = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "imported-world" : collapsed
    }

    // MARK: - Scene

    private static func makeScene(assembly: UAVWorldSceneAssembler.Assembly) -> SCNScene {
        let scene = SCNScene()
        scene.rootNode.addChildNode(assembly.root)
        scene.rootNode.addChildNode(
            UAVWorldSceneAssembler.makePlaceholderGround(spanMeters: assembly.statistics.spanMeters)
        )

        scene.rootNode.addChildNode(
            UAVWorldSceneAssembler.makeSunNode(spanMeters: assembly.statistics.spanMeters)
        )

        // Physically-based materials take their ambient term from the lighting environment, not
        // from an `.ambient` light — without this every shadowed facade renders black.
        scene.lightingEnvironment.contents = UAVWorldSceneAssembler.makeSkyEnvironment()
        scene.lightingEnvironment.intensity = 1.6

        scene.background.contents = NSColor(calibratedRed: 0.42, green: 0.50, blue: 0.60, alpha: 1)
        return scene
    }
}

// MARK: - Scene view

private struct UAVWorldPreviewSceneView: NSViewRepresentable {
    let scene: SCNScene?
    let sceneToken: Int
    let framingSpanMeters: Float

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = NSColor(calibratedRed: 0.42, green: 0.50, blue: 0.60, alpha: 1)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        // Only react to an actual new scene. Re-framing on every layout pass would fight the
        // user's camera control, and writing back into the model from here is what previously
        // produced a render/update feedback loop in this project.
        guard context.coordinator.installedToken != sceneToken else { return }
        context.coordinator.installedToken = sceneToken

        view.scene = scene
        guard scene != nil else { return }

        let camera = SCNCamera()
        camera.zNear = 1
        camera.zFar = Double(framingSpanMeters * 6 + 2000)
        camera.fieldOfView = 55

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        // An oblique view from a corner, at roughly the altitude a UAV would survey from — the
        // angle the whole exercise is meant to be judged at.
        let distance = max(framingSpanMeters * 0.9, 300)
        cameraNode.position = SCNVector3(
            CGFloat(distance * 0.7),
            CGFloat(distance * 0.55),
            CGFloat(distance * 0.7)
        )
        cameraNode.look(at: SCNVector3(0, CGFloat(framingSpanMeters * 0.04), 0))
        scene?.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var installedToken = -1
    }
}

// MARK: - Window content

struct UAVWorldPreviewView: View {
    @StateObject private var model = UAVWorldPreviewModel()

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

            ZStack {
                UAVWorldPreviewSceneView(
                    scene: model.scene,
                    sceneToken: model.sceneToken,
                    framingSpanMeters: Float(model.sideLengthMeters)
                )
                if model.scene == nil {
                    Text("world.preview.empty")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 900, minHeight: 620)
    }

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("world.preview.title")
                    .font(.title3.weight(.semibold))

                Text("world.preview.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Picker("world.preview.preset", selection: presetBinding) {
                    Text("world.preview.preset.custom").tag(-1)
                    ForEach(Array(UAVWorldPreviewModel.presets.enumerated()), id: \.offset) { index, preset in
                        Text(preset.title).tag(index)
                    }
                }

                LabeledContent("world.preview.latitude") {
                    TextField("", value: $model.latitude, format: .number.precision(.fractionLength(6)))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("world.preview.longitude") {
                    TextField("", value: $model.longitude, format: .number.precision(.fractionLength(6)))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("world.preview.size") {
                    TextField("", value: $model.sideLengthMeters, format: .number.precision(.fractionLength(0)))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("world.preview.name") {
                    TextField("", text: $model.displayName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button(model.isWorking ? "world.preview.cancel" : "world.preview.import") {
                        model.isWorking ? model.cancel() : model.startImport()
                    }
                    .keyboardShortcut(.return)

                    Button("world.preview.save") {
                        model.save()
                    }
                    .disabled(!model.canSave)
                }

                statusView

                if !model.report.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(model.report.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.savedURL != nil {
                    Button("world.preview.reveal") {
                        model.revealSavedPackage()
                    }
                    .buttonStyle(.link)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var presetBinding: Binding<Int> {
        Binding(
            get: {
                UAVWorldPreviewModel.presets.firstIndex {
                    abs($0.latitude - model.latitude) < 1e-6
                        && abs($0.longitude - model.longitude) < 1e-6
                } ?? -1
            },
            set: { index in
                guard index >= 0, index < UAVWorldPreviewModel.presets.count else { return }
                model.apply(UAVWorldPreviewModel.presets[index])
            }
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch model.status {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).font(.caption)
            }
        case .ready(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
