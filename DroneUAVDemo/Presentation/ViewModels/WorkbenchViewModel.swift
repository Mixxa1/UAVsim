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
        case .blueprints: return "Чертежи"
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
        stats = WorkbenchBuildAnalyzer.analyze(build)
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

    // MARK: Mutations

    func selectLibraryFrame(_ id: String) {
        guard selectedLibraryFrameID != id else { return }
        pushUndo()
        build.frame = .library(id: id)
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

    func rename(_ name: String) {
        guard build.name != name else { return }
        build.name = name
    }

    func setDescription(_ description: String) {
        guard build.buildDescription != description else { return }
        build.buildDescription = description
    }

    func newBuild() {
        pushUndo()
        build = .defaultQuad()
        build.id = UUID()
        build.name = "Новая сборка"
        build.revision += 1
        selectedCategory = .overview
        recompute()
        statusMessage = "Создан новый чертёж на основе лётного шаблона."
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
        stats = WorkbenchBuildAnalyzer.analyze(build)
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

    func applyPendingImport(as role: WorkbenchAssemblyRole) {
        guard let imported = pendingImport else { return }
        pushUndo()
        switch role {
        case .frame:
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
            statusMessage = "Чертёж «\(build.name)» сохранён в избранное."
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
            statusMessage = "Чертёж удалён из избранного."
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
