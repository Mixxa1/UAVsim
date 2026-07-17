import Foundation

struct WorkbenchBlueprintSummary: Identifiable, Hashable {
    var id: UUID
    var name: String
    var modifiedAt: Date
    var frameName: String
    var componentCount: Int
    var url: URL
}

/// JSON blueprint persistence plus the local favorites library shown inside
/// the Workbench. Imported meshes are embedded by `WorkbenchBuild`, making a
/// saved blueprint self-contained.
enum WorkbenchBuildStore {
    static let fileExtension = "uavbuild"

    static func save(_ build: WorkbenchBuild, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(build)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> WorkbenchBuild {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WorkbenchBuild.self, from: data)
    }

    static func snapshot(_ build: WorkbenchBuild) -> Data? {
        try? JSONEncoder().encode(build)
    }

    static func restore(from data: Data) -> WorkbenchBuild? {
        try? JSONDecoder().decode(WorkbenchBuild.self, from: data)
    }

    static func saveToLibrary(_ build: WorkbenchBuild) throws -> URL {
        let directory = try libraryDirectory()
        let url = directory
            .appendingPathComponent(build.id.uuidString)
            .appendingPathExtension(fileExtension)
        try save(build, to: url)
        return url
    }

    static func listLibrary() -> [WorkbenchBlueprintSummary] {
        guard let directory = try? libraryDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }

        return urls.compactMap { url -> WorkbenchBlueprintSummary? in
            guard url.pathExtension.lowercased() == fileExtension,
                  let build = try? load(from: url) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return WorkbenchBlueprintSummary(
                id: build.id,
                name: build.name,
                modifiedAt: modified,
                frameName: build.resolvedFrame.name,
                componentCount: WorkbenchBuildAnalyzer.analyze(build).componentCount,
                url: url)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func listLibraryBuilds() -> [WorkbenchBuild] {
        listLibrary().compactMap { try? load(from: $0.url) }
    }

    static func deleteFromLibrary(_ summary: WorkbenchBlueprintSummary) throws {
        try FileManager.default.removeItem(at: summary.url)
    }

    private static func libraryDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let directory = base
            .appendingPathComponent("UAVSim", isDirectory: true)
            .appendingPathComponent("Workbench Blueprints", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}
