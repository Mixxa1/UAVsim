import Foundation

/// Reads and writes `.uavworld` packages.
///
/// A package is a directory, not a single archive: layers are large, independent, and will grow
/// to include terrain rasters and imagery that the renderer wants to memory-map rather than
/// decode wholesale. A directory also lets a later streaming loader read one tile without
/// touching the rest, which a zip container would prevent.
///
/// Layer files are JSON at this stage. That is a deliberate, revisitable choice: the Lower
/// Manhattan extract is ~500 buildings and 6700 vertices, where JSON costs well under a
/// megabyte and buys inspectability while the format is still moving. It will not survive a
/// city-scale, imagery-bearing world, and `UAVWorldManifest.currentFormatVersion` exists so the
/// switch to a binary layout is a version bump rather than a migration crisis.
struct UAVWorldPackageStore {
    enum StoreError: LocalizedError {
        case unsupportedFormatVersion(found: Int, supported: Int)
        case missingManifest(URL)
        case missingLayer(String)
        case writeFailed(underlying: Error)
        case readFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormatVersion(let found, let supported):
                return L10n.f("world.package.error.version", found, supported)
            case .missingManifest(let url):
                return L10n.f("world.package.error.manifest", url.lastPathComponent)
            case .missingLayer(let name):
                return L10n.f("world.package.error.layer", name)
            case .writeFailed(let underlying):
                return L10n.f("world.package.error.write", underlying.localizedDescription)
            case .readFailed(let underlying):
                return L10n.f("world.package.error.read", underlying.localizedDescription)
            }
        }
    }

    static let packageExtension = "uavworld"
    private static let manifestFileName = "manifest.json"
    private static let buildingsFileName = "buildings.json"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Locations

    func packagesDirectory() -> URL {
        InternalStorePaths.worlds(fileManager: fileManager)
    }

    func packageURL(identifier: String) -> URL {
        packagesDirectory()
            .appendingPathComponent("\(identifier).\(Self.packageExtension)", isDirectory: true)
    }

    /// Every package currently installed, newest first. Manifests that fail to read are skipped
    /// rather than aborting the listing — one corrupt package must not hide the others.
    func installedManifests() -> [(url: URL, manifest: UAVWorldManifest)] {
        let root = packagesDirectory()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return entries
            .filter { $0.pathExtension == Self.packageExtension }
            .compactMap { url in
                guard let manifest = try? readManifest(at: url) else { return nil }
                return (url, manifest)
            }
            .sorted { $0.manifest.generatedAt > $1.manifest.generatedAt }
    }

    // MARK: - Write

    /// Writes the package atomically: everything lands in a sibling staging directory first and
    /// is swapped in only once complete, so an interrupted import cannot leave a half-written
    /// world that the loader would happily open.
    @discardableResult
    func write(_ result: UAVWorldBuildResult) throws -> URL {
        let destination = packageURL(identifier: result.manifest.identifier)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".staging-\(result.manifest.identifier)-\(UUID().uuidString)",
                isDirectory: true
            )

        do {
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Sorted keys keep two builds of the same region byte-comparable, which makes it
            // possible to tell "the source data changed" from "the importer changed".
            encoder.outputFormatting = [.sortedKeys]

            try encoder.encode(result.manifest)
                .write(to: staging.appendingPathComponent(Self.manifestFileName))
            try encoder.encode(result.buildings)
                .write(to: staging.appendingPathComponent(Self.buildingsFileName))

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
            return destination
        } catch {
            try? fileManager.removeItem(at: staging)
            throw StoreError.writeFailed(underlying: error)
        }
    }

    // MARK: - Read

    func readManifest(at packageURL: URL) throws -> UAVWorldManifest {
        let manifestURL = packageURL.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw StoreError.missingManifest(packageURL)
        }

        let manifest: UAVWorldManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(
                UAVWorldManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw StoreError.readFailed(underlying: error)
        }

        // Refuse a package written by a newer importer outright. Reading it on a best-effort
        // basis would mean flying against geometry this build does not fully understand, which
        // is exactly the kind of silent wrongness a simulator must not have.
        guard manifest.formatVersion <= UAVWorldManifest.currentFormatVersion else {
            throw StoreError.unsupportedFormatVersion(
                found: manifest.formatVersion,
                supported: UAVWorldManifest.currentFormatVersion
            )
        }
        return manifest
    }

    func readBuildings(at packageURL: URL) throws -> [UAVWorldBuilding] {
        let url = packageURL.appendingPathComponent(Self.buildingsFileName)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StoreError.missingLayer(Self.buildingsFileName)
        }
        do {
            return try JSONDecoder().decode(
                [UAVWorldBuilding].self,
                from: Data(contentsOf: url)
            )
        } catch {
            throw StoreError.readFailed(underlying: error)
        }
    }

    func delete(identifier: String) throws {
        let url = packageURL(identifier: identifier)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
