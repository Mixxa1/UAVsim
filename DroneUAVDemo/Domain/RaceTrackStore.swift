import Foundation

/// On-disk library of race tracks, one JSON file per track.
///
/// Same shape and location as `WorkbenchBuildStore`'s blueprint library — a track built in one
/// session has to still be there in the next one, and a track is exactly the kind of thing a
/// pilot builds once and flies for weeks.
enum RaceTrackStore {
    private static let fileExtension = "uavtrack"

    struct Summary: Identifiable, Hashable {
        var id: UUID
        var name: String
        var gateCount: Int
        var laps: Int
        var lapLengthMeters: Float
        var bestLapSeconds: Double?
        var isGenerated: Bool
        var modifiedAt: Date
        var url: URL
    }

    @discardableResult
    static func save(_ track: RaceTrack) throws -> URL {
        var stored = track
        stored.updatedAt = Date()
        let directory = try libraryDirectory()
        let url = directory.appendingPathComponent("\(stored.id.uuidString).\(fileExtension)")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: url, options: .atomic)
        return url
    }

    static func load(from url: URL) throws -> RaceTrack {
        try JSONDecoder().decode(RaceTrack.self, from: Data(contentsOf: url))
    }

    static func list() -> [Summary] {
        guard let directory = try? libraryDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else {
            return []
        }
        return urls.compactMap { url -> Summary? in
            guard url.pathExtension.lowercased() == fileExtension,
                  let track = try? load(from: url) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return Summary(
                id: track.id,
                name: track.name,
                gateCount: track.gateCount,
                laps: track.laps,
                lapLengthMeters: track.lapLengthMeters,
                bestLapSeconds: track.bestLapSeconds,
                isGenerated: track.isGenerated,
                modifiedAt: modified,
                url: url
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func listTracks() -> [RaceTrack] {
        list().compactMap { try? load(from: $0.url) }
    }

    static func delete(_ summary: Summary) throws {
        try FileManager.default.removeItem(at: summary.url)
    }

    /// Records a completed run's times if they beat what the track already holds.
    static func recordResult(trackID: UUID, totalSeconds: Double, bestLapSeconds: Double) {
        guard let summary = list().first(where: { $0.id == trackID }),
              var track = try? load(from: summary.url) else {
            return
        }
        var changed = false
        if track.bestLapSeconds.map({ bestLapSeconds < $0 }) ?? true {
            track.bestLapSeconds = bestLapSeconds
            changed = true
        }
        if track.bestTotalSeconds.map({ totalSeconds < $0 }) ?? true {
            track.bestTotalSeconds = totalSeconds
            changed = true
        }
        guard changed else { return }
        _ = try? save(track)
    }

    private static func libraryDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("UAVSim", isDirectory: true)
            .appendingPathComponent("Race Tracks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
