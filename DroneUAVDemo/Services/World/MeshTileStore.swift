import Foundation

/// Manages mesh tiles on disk: what is installed, how much room a download needs, and the
/// download itself.
///
/// Tiles are large enough that none of this can be implicit. A single central tile is about
/// 1.8 GB compressed and 4.5 GB extracted, so the store reports sizes before anything starts,
/// refuses to begin without enough free space, and keeps everything under Application Support
/// where it survives app updates and the user can find and delete it.
@MainActor
final class MeshTileStore: ObservableObject {

    enum StoreError: LocalizedError {
        case insufficientSpace(needed: Int64, available: Int64)
        case downloadFailed(String)
        case extractionFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .insufficientSpace(let needed, let available):
                return L10n.f(
                    "world.mesh.store.error.space",
                    needed.formattedByteSize,
                    available.formattedByteSize
                )
            case .downloadFailed(let detail):
                return L10n.f("world.mesh.store.error.download", detail)
            case .extractionFailed(let detail):
                return L10n.f("world.mesh.store.error.extract", detail)
            case .cancelled:
                return L10n.s("world.mesh.store.error.cancelled")
            }
        }
    }

    struct Progress: Equatable {
        var tileKey: String
        var receivedBytes: Int64
        var expectedBytes: Int64
        var isExtracting: Bool

        var fraction: Double {
            guard expectedBytes > 0 else { return 0 }
            return min(1.0, Double(receivedBytes) / Double(expectedBytes))
        }

        var percentText: String {
            String(format: "%.0f%%", fraction * 100)
        }
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var installedKeys: Set<String> = []

    private let fileManager: FileManager
    private var activeTask: Task<Void, Error>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Locations

    func rootDirectory(for source: MeshTileSource) -> URL {
        InternalStorePaths.worlds(fileManager: fileManager)
            .appendingPathComponent("MeshTiles", isDirectory: true)
            .appendingPathComponent(source.identifier, isDirectory: true)
    }

    func tileDirectory(for source: MeshTileSource, key: String) -> URL {
        rootDirectory(for: source).appendingPathComponent(key, isDirectory: true)
    }

    func isInstalled(source: MeshTileSource, key: String) -> Bool {
        let metadata = tileDirectory(for: source, key: key)
            .appendingPathComponent("metadata.xml")
        return fileManager.fileExists(atPath: metadata.path)
    }

    func refreshInstalled(source: MeshTileSource) {
        let root = rootDirectory(for: source)
        let entries = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        installedKeys = Set(entries.filter { isInstalled(source: source, key: $0) })
    }

    func installedBytes(source: MeshTileSource, key: String) -> Int64 {
        directorySize(tileDirectory(for: source, key: key))
    }

    /// Free space on the volume holding the tile store, or 0 when it cannot be determined.
    ///
    /// `resourceValues(forKeys:)` fails outright on a path that does not exist, and the store
    /// directory is not created until the first download — so querying it directly reported
    /// "0 KB free" on a machine with hundreds of gigabytes, which then failed every install
    /// before it started. The directory is created up front, and the query walks up to the
    /// deepest ancestor that does exist as a further guard.
    func availableCapacityBytes() -> Int64 {
        let directory = InternalStorePaths.worlds(fileManager: fileManager)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var probe = directory
        while true {
            if fileManager.fileExists(atPath: probe.path),
               let values = try? probe.resourceValues(
                   forKeys: [.volumeAvailableCapacityForImportantUsageKey]
               ),
               let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { return 0 }
            probe = parent
        }
    }

    // MARK: - Download

    /// Downloads and extracts a tile.
    ///
    /// Callers must have shown the user the size and received explicit approval — this method
    /// deliberately does not prompt, so there is exactly one place in the app where that decision
    /// is made and it is in the UI where the numbers are visible.
    func install(
        source: MeshTileSource,
        tile: MeshTileDescriptor
    ) async throws {
        // A margin over the estimate, because the extraction ratio varies with tile content.
        let needed = Int64(Double(tile.totalDiskBytes) * 1.15)
        let available = availableCapacityBytes()
        // Zero means the capacity could not be read, not that the disk is full. Refusing on an
        // unknown is worse than attempting and failing with a real error from the file system.
        if available > 0, available < needed {
            throw StoreError.insufficientSpace(needed: needed, available: available)
        }

        let root = rootDirectory(for: source)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let archiveURL = root.appendingPathComponent("\(tile.key).zip")
        let destination = tileDirectory(for: source, key: tile.key)

        progress = Progress(
            tileKey: tile.key,
            receivedBytes: 0,
            expectedBytes: tile.compressedBytes,
            isExtracting: false
        )
        defer { progress = nil }

        let delegate = DownloadProgressDelegate { [weak self] received, expected in
            Task { @MainActor in
                guard let self, self.progress?.tileKey == tile.key else { return }
                self.progress?.receivedBytes = received
                if expected > 0 { self.progress?.expectedBytes = expected }
            }
        }
        // The delegate is attached to the *call*, not the session. `download(from:)` takes
        // ownership of the downloaded file itself, which conflicts with a session-level
        // `URLSessionDownloadDelegate` also claiming it; the per-task delegate parameter is the
        // supported way to observe progress without fighting the async API for the result.
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (temporaryURL, response) = try await session.download(
                from: tile.downloadURL,
                delegate: delegate
            )
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw StoreError.downloadFailed("HTTP \(http.statusCode)")
            }
            try? fileManager.removeItem(at: archiveURL)
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        } catch is CancellationError {
            throw StoreError.cancelled
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.downloadFailed(error.localizedDescription)
        }

        progress?.isExtracting = true

        // Extraction runs off the main actor; a 4.5 GB unpack would otherwise freeze the UI for
        // the better part of a minute.
        let extractionResult = await Task.detached(priority: .userInitiated) { [fileManager] in
            do {
                try? fileManager.removeItem(at: destination)
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                try Self.unzip(archive: archiveURL, into: destination)
                // The archive is removed once extracted: keeping both would double an already
                // multi-gigabyte footprint for no benefit.
                try? fileManager.removeItem(at: archiveURL)
                return Result<Void, Error>.success(())
            } catch {
                return Result<Void, Error>.failure(error)
            }
        }.value

        if case .failure(let error) = extractionResult {
            try? fileManager.removeItem(at: destination)
            try? fileManager.removeItem(at: archiveURL)
            throw StoreError.extractionFailed(error.localizedDescription)
        }

        // ContextCapture archives contain a single top-level folder; flatten it so the tile
        // directory holds `metadata.xml` directly and the index can find it.
        Self.flattenSingleChildDirectory(at: destination, fileManager: fileManager)
        refreshInstalled(source: source)
    }

    func remove(source: MeshTileSource, key: String) {
        try? fileManager.removeItem(at: tileDirectory(for: source, key: key))
        refreshInstalled(source: source)
    }

    // MARK: - Helpers

    private nonisolated static func unzip(archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-oq", archive.path, "-d", destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unzip exited \(process.terminationStatus)"
            throw StoreError.extractionFailed(message)
        }
    }

    private nonisolated static func flattenSingleChildDirectory(
        at directory: URL,
        fileManager: FileManager
    ) {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // Already flat if metadata sits at the top level.
        if entries.contains(where: { $0.lastPathComponent == "metadata.xml" }) { return }
        guard entries.count == 1, let inner = entries.first else { return }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: inner.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let innerEntries = try? fileManager.contentsOfDirectory(
                at: inner,
                includingPropertiesForKeys: nil
              ) else {
            return
        }

        for entry in innerEntries {
            let target = directory.appendingPathComponent(entry.lastPathComponent)
            try? fileManager.moveItem(at: entry, to: target)
        }
        try? fileManager.removeItem(at: inner)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Reports byte-level download progress, which `URLSession`'s async `download(from:)` does not
/// surface on its own — and for a multi-gigabyte transfer a progress bar is not a nicety.
private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// Required by the protocol, and deliberately empty: attached as a *per-task* delegate, the
    /// async `download(from:delegate:)` call owns the completed file and hands it back to the
    /// caller. Moving or opening it here would race that.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
    }
}
