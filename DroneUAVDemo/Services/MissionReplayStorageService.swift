import Foundation

final class MissionReplayStorageService {
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let directory: URL?

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        self.directory = directory
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Directories

    private var replaysDirectory: URL {
        directory ?? InternalStorePaths.replays(fileManager: fileManager)
    }

    private func sessionDirectory(for id: UUID) -> URL {
        replaysDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func summaryURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("summary.json")
    }

    private func sessionURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("session.json")
    }

    private func reportURL(for id: UUID) -> URL {
        sessionDirectory(for: id).appendingPathComponent("report.json")
    }

    // MARK: - Public API

    func listSummaries() -> [MissionReplayRecordSummary] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: replaysDirectory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return contents.compactMap { dir -> MissionReplayRecordSummary? in
            guard let uuidString = dir.lastPathComponent.nilIfEmpty,
                  let id = UUID(uuidString: uuidString) else { return nil }
            guard let data = try? Data(contentsOf: summaryURL(for: id)),
                  let summary = try? decoder.decode(MissionReplayRecordSummary.self, from: data) else { return nil }
            return summary
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func save(session: MissionReplaySession, report: MissionReport) throws {
        let id = session.id
        let dir = sessionDirectory(for: id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let startedAt = session.startedAt
        let endedAt = session.endedAt
        let summary = MissionReplayRecordSummary(
            id: id,
            createdAt: Date(),
            startedAt: startedAt,
            endedAt: endedAt,
            durationSeconds: session.duration,
            frameCount: session.frames.count,
            eventCount: session.events.count,
            warningCount: session.events.filter { $0.type == .warning }.count,
            maxSpeedMetersPerSecond: report.summary.maxSpeedMetersPerSecond,
            maxAltitudeMeters: report.summary.maxAltitudeMeters,
            title: MissionReplayRecordSummary.makeTitle(from: startedAt)
        )

        var stored = session
        if let assets = session.visualAssets, !assets.isEmpty {
            var files: [String: String] = [:]
            for (index, asset) in assets.sorted(by: { $0.key < $1.key }).enumerated() {
                let name = "visual-\(index).scnarchive"
                try asset.value.write(to: dir.appendingPathComponent(name), options: .atomic)
                files[asset.key] = name
            }
            stored.visualAssetFiles = files
            stored.visualAssets = nil
        }
        try encoder.encode(stored).write(to: sessionURL(for: id), options: .atomic)
        try encoder.encode(report).write(to: reportURL(for: id), options: .atomic)
        // Publish a selectable library entry only once its session and report are present.
        try encoder.encode(summary).write(to: summaryURL(for: id), options: .atomic)
    }

    func loadSession(id: UUID) throws -> MissionReplaySession {
        let data = try Data(contentsOf: sessionURL(for: id))
        var session = try decoder.decode(MissionReplaySession.self, from: data)
        if let files = session.visualAssetFiles {
            var assets = session.visualAssets ?? [:]
            for (assetID, name) in files where name == URL(fileURLWithPath: name).lastPathComponent {
                if let data = try? Data(contentsOf: sessionDirectory(for: id).appendingPathComponent(name)) {
                    assets[assetID] = data
                }
            }
            session.visualAssets = assets
        }
        return session
    }

    func loadReport(id: UUID) throws -> MissionReport {
        let data = try Data(contentsOf: reportURL(for: id))
        return MissionReportBuilder().localizedReport(try decoder.decode(MissionReport.self, from: data))
    }

    func delete(id: UUID) throws {
        let dir = sessionDirectory(for: id)
        try fileManager.removeItem(at: dir)
    }

    func enforceRetention(_ policy: MissionReplayRetentionPolicy) {
        guard policy.isAutoDeleteEnabled else { return }
        let clamped = policy.clamped
        let summaries = listSummaries()
        guard summaries.count > clamped.maxStoredReplayCount else { return }
        let toDelete = summaries.dropFirst(clamped.maxStoredReplayCount)
        for summary in toDelete {
            try? delete(id: summary.id)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
