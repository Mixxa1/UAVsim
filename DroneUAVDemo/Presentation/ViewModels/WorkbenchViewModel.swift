import Foundation
import SwiftUI

enum WorkbenchCategory: Hashable, Identifiable {
    case overview
    case blueprints
    case frame
    case slot(WorkbenchComponentKind)

    var id: String {
        switch self {
        case .overview: return "overview"
        case .blueprints: return "blueprints"
        case .frame: return "frame"
        case let .slot(kind): return "slot.\(kind.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .overview: return "Сборка"
        case .blueprints: return "Пользовательские"
        case .frame: return "Рама"
        case let .slot(kind): return kind.shortName
        }
    }

    var symbolName: String {
        switch self {
        case .overview: return "list.bullet.rectangle"
        case .blueprints: return "square.stack.3d.up.fill"
        case .frame: return "square.on.square.intersection.dashed"
        case let .slot(kind): return kind.symbolName
        }
    }
}

enum WorkbenchAssemblyRole: Hashable, Identifiable {
    case frame
    case component(WorkbenchComponentKind)

    var id: String {
        switch self {
        case .frame: return "frame"
        case let .component(kind): return "component.\(kind.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .frame: return "Рама аппарата"
        case let .component(kind): return kind.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .frame: return "square.on.square.intersection.dashed"
        case let .component(kind): return kind.symbolName
        }
    }

    static let all: [WorkbenchAssemblyRole] = [.frame]
        + WorkbenchComponentKind.allCases.map { .component($0) }
}

@MainActor
final class WorkbenchViewModel: ObservableObject {
    @Published private(set) var build: WorkbenchBuild
    @Published private(set) var stats: WorkbenchBuildStats
    @Published var selectedCategory: WorkbenchCategory = .overview
    @Published var statusMessage = "Выберите категорию или нажмите на деталь в 3D-сцене."
    @Published private(set) var blueprints: [WorkbenchBlueprintSummary] = []
    @Published private(set) var cameraResetToken = 0
    @Published var pendingImport: WorkbenchConstructionImport?

    private var undoStack: [Data] = []
    private let undoDepth = 50

    init(build: WorkbenchBuild = .defaultQuad()) {
        self.build = build
        stats = Self.resolvedStats(for: build)
        refreshBlueprints()
    }

    var frameName: String { build.resolvedFrame.name }

    var selectedLibraryFrameID: String? {
        if case let .library(id) = build.frame { return id }
        return nil
    }

    var selectedComponent: WorkbenchComponentSpec? {
        guard case let .slot(kind) = selectedCategory else { return nil }
        return build.spec(for: kind)
    }

    var selectedCategoryTitle: String { selectedCategory.displayName }

    var canUndo: Bool { !undoStack.isEmpty }

    func components(for kind: WorkbenchComponentKind) -> [WorkbenchComponentSpec] {
        build.availableComponents(for: kind)
    }

    func selectedSpecID(for kind: WorkbenchComponentKind) -> String? {
        build.specID(for: kind)
    }

    func mountSurface(for kind: WorkbenchComponentKind) -> WorkbenchMountSurface {
        // Reflect the actually resolved physical zone. This keeps a legacy
        // Blueprint that requested an unsafe GPS/RX/battery face from leaving
        // a SwiftUI Picker with a value that is no longer offered by the UI.
        WorkbenchBuildAnalyzer.resolvedComponentLayout(for: build)[kind]?.surface
            ?? build.placement(for: kind).surface
    }

    // MARK: Mutations

    func selectLibraryFrame(_ id: String) {
        guard selectedLibraryFrameID != id else { return }
        pushUndo()
        build.frame = .library(id: id)
        if let frame = WorkbenchFrameLibrary.spec(id: id) {
            build.vehicleArchitecture = frame.architecture
        }
        build.revision += 1
        recompute()
        statusMessage = "Установлена рама «\(build.resolvedFrame.name)»."
    }

    func setSpec(_ id: String?, for kind: WorkbenchComponentKind) {
        guard build.specID(for: kind) != id else { return }
        pushUndo()
        build.setSpec(id, for: kind)
        recompute()
        if let spec = build.spec(for: kind) {
            statusMessage = "\(kind.displayName): \(spec.displayName)."
        } else {
            statusMessage = "\(kind.displayName): слот освобождён."
        }
    }

    func setMountSurface(_ surface: WorkbenchMountSurface, for kind: WorkbenchComponentKind) {
        guard build.placement(for: kind).surface != surface else { return }
        pushUndo()
        build.setMountSurface(surface, for: kind)
        recompute()
        statusMessage = "\(kind.displayName): монтаж — \(surface.displayName.lowercased())."
    }

    func rename(_ name: String) {
        guard build.name != name else { return }
        build.name = name
    }

    func setDescription(_ description: String) {
        guard build.buildDescription != description else { return }
        build.buildDescription = description
    }

    func newBuild(_ architecture: WorkbenchVehicleArchitecture = .multicopter) {
        pushUndo()
        switch architecture {
        case .multicopter: build = .defaultQuad()
        case .fixedWing: build = .defaultFixedWing()
        case .liftCruiseVTOL: build = .defaultVTOL()
        }
        build.id = UUID()
        build.revision += 1
        selectedCategory = .overview
        recompute()
        statusMessage = "Создан новый аппарат: \(architecture.displayName)."
    }

    func undo() {
        guard let data = undoStack.popLast(),
              var restored = WorkbenchBuildStore.restore(from: data) else { return }
        restored.revision = build.revision + 1
        build = restored
        recompute()
        statusMessage = "Последнее изменение отменено."
    }

    func resetCamera() {
        cameraResetToken += 1
        statusMessage = "Камера возвращена к сборке."
    }

    private func recompute() {
        stats = Self.resolvedStats(for: build)
    }

    /// Analyzer totals retain every propulsion unit for electrical sizing.
    /// In a lift+cruise aircraft the forward propeller cannot contribute to
    /// hover, so the inspector/readiness values must use only lift rotors.
    private static func resolvedStats(for build: WorkbenchBuild) -> WorkbenchBuildStats {
        var result = WorkbenchBuildAnalyzer.analyze(build)
        let frame = build.resolvedFrame
        guard frame.architecture == .liftCruiseVTOL else { return result }

        let p = WorkbenchComponentSpec.ParamKey.self
        let singleThrust = build.spec(for: .motor)?.param(p.motorMaxThrustN) ?? 0
        result.totalMaxThrustN = singleThrust * Double(frame.liftMotorCount)
        let weight = result.totalMassKg * 9.80665
        result.thrustToWeight = weight > 0 ? result.totalMaxThrustN / weight : 0

        if result.batteryEnergyWh > 0,
           let motorPower = build.spec(for: .motor)?.param(p.motorMaxPowerW),
           motorPower > 0,
           frame.liftMotorCount > 0,
           result.thrustToWeight > 0 {
            let hoverThrottle = sqrt(min(1, 1 / result.thrustToWeight))
            let hoverPower = motorPower * Double(frame.liftMotorCount)
                * pow(hoverThrottle, 1.55)
            result.estimatedHoverTimeMin = result.batteryEnergyWh
                / max(hoverPower, 1) * 60 * 0.82
        }
        return result
    }

    private func pushUndo() {
        if let data = WorkbenchBuildStore.snapshot(build) {
            undoStack.append(data)
            if undoStack.count > undoDepth { undoStack.removeFirst() }
        }
    }

    // MARK: CAD import and role assignment

    func prepareImport(from url: URL) {
        do {
            pendingImport = try WorkbenchConstruction.load(from: url)
            statusMessage = "3D-сборка загружена. Назначьте ей роль в аппарате."
        } catch {
            pendingImport = nil
            statusMessage = "Не удалось открыть CAD-сборку: \(error.localizedDescription)"
        }
    }

    func applyPendingImport(
        as role: WorkbenchAssemblyRole,
        frameArchitecture: WorkbenchVehicleArchitecture? = nil
    ) {
        guard let imported = pendingImport else { return }
        pushUndo()
        switch role {
        case .frame:
            if let frameArchitecture {
                build.vehicleArchitecture = frameArchitecture
            }
            build.frame = .imported(imported.construction)
            build.revision += 1
            selectedCategory = .frame
            statusMessage = "Сборка «\(imported.construction.name)» назначена рамой."
        case let .component(kind):
            let component = makeComponent(from: imported.construction, kind: kind,
                                          sourceName: imported.sourceURL.lastPathComponent)
            build.installImportedComponent(component)
            selectedCategory = .slot(kind)
            statusMessage = "CAD-сборка назначена как «\(kind.displayName)»."
        }
        if let notice = imported.notice { statusMessage += " \(notice)" }
        pendingImport = nil
        recompute()
    }

    func cancelPendingImport() { pendingImport = nil }

    private func makeComponent(
        from construction: WorkbenchConstruction,
        kind: WorkbenchComponentKind,
        sourceName: String
    ) -> WorkbenchComponentSpec {
        let cadSize = construction.dimensionsMeters
        let sceneSize = CodableVector3D(
            x: max(cadSize.x, 0.005),
            y: max(cadSize.z, 0.005),
            z: max(cadSize.y, 0.005))
        return WorkbenchComponentSpec(
            id: "cad-\(kind.rawValue)-\(UUID().uuidString)",
            kind: kind,
            brand: "CADNext",
            displayName: construction.name.isEmpty ? sourceName : construction.name,
            summary: "Импортировано из \(sourceName)",
            massKg: max(construction.massKg, 0.001),
            proxy: WorkbenchComponentProxy(shape: .box, size: sceneSize,
                                           colorHex: color(for: kind)),
            importedMesh: construction.mesh,
            params: [:])
    }

    private func color(for kind: WorkbenchComponentKind) -> String {
        switch kind {
        case .motor: return "#39434F"
        case .propeller: return "#23272D"
        case .battery: return "#3AA675"
        case .camera, .sensor, .gps: return "#366889"
        case .payload: return "#6D7784"
        default: return "#637180"
        }
    }

    // MARK: Blueprints

    func saveFavorite() {
        do {
            _ = try WorkbenchBuildStore.saveToLibrary(build)
            refreshBlueprints()
            statusMessage = "Модель «\(build.name)» сохранена в каталог «Пользовательские»."
        } catch {
            statusMessage = "Не удалось сохранить чертёж: \(error.localizedDescription)"
        }
    }

    func refreshBlueprints() {
        blueprints = WorkbenchBuildStore.listLibrary()
    }

    func loadBlueprint(_ summary: WorkbenchBlueprintSummary) {
        loadBlueprint(from: summary.url)
    }

    func deleteBlueprint(_ summary: WorkbenchBlueprintSummary) {
        do {
            try WorkbenchBuildStore.deleteFromLibrary(summary)
            refreshBlueprints()
            statusMessage = "Модель удалена из каталога «Пользовательские»."
        } catch {
            statusMessage = "Не удалось удалить чертёж: \(error.localizedDescription)"
        }
    }

    func save(to url: URL) {
        do {
            try WorkbenchBuildStore.save(build, to: url)
            statusMessage = "Чертёж экспортирован: \(url.lastPathComponent)."
        } catch {
            statusMessage = "Не удалось экспортировать: \(error.localizedDescription)"
        }
    }

    func loadBlueprint(from url: URL) {
        do {
            var loaded = try WorkbenchBuildStore.load(from: url)
            pushUndo()
            loaded.revision = build.revision + 1
            build = loaded
            recompute()
            selectedCategory = .overview
            statusMessage = "Открыт чертёж «\(loaded.name)»."
        } catch {
            statusMessage = "Не удалось открыть чертёж: \(error.localizedDescription)"
        }
    }
}
