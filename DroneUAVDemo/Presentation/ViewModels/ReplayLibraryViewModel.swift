import Foundation

@MainActor
final class ReplayLibraryViewModel: ObservableObject {
    @Published private(set) var summaries: [MissionReplayRecordSummary] = []
    @Published private(set) var selectedReport: MissionReport?
    @Published private(set) var selectedSummaryID: UUID?
    @Published var retentionPolicy: MissionReplayRetentionPolicy {
        didSet { settingsStore.savePolicy(retentionPolicy) }
    }

    private let storage: MissionReplayStorageService
    private let settingsStore: MissionReplaySettingsStore
    /// Writes are ordered, so a final recording cannot be overwritten by an older checkpoint.
    private let storageQueue = DispatchQueue(label: "uavsim.replay.persistence", qos: .utility)

    init(
        storage: MissionReplayStorageService = MissionReplayStorageService(),
        settingsStore: MissionReplaySettingsStore = MissionReplaySettingsStore()
    ) {
        self.storage = storage
        self.settingsStore = settingsStore
        self.retentionPolicy = settingsStore.loadPolicy()
    }

    func refresh() {
        summaries = storage.listSummaries()
        if let selectedSummaryID, summaries.contains(where: { $0.id == selectedSummaryID }) {
            // The final save replaces an earlier checkpoint under the same ID.
            select(id: selectedSummaryID)
            return
        }
        if let latest = summaries.first {
            select(id: latest.id)
        } else {
            clearSelection()
        }
    }

    func select(id: UUID) {
        selectedSummaryID = id
        selectedReport = try? storage.loadReport(id: id)
    }

    func loadSession(id: UUID) -> MissionReplaySession? {
        try? storage.loadSession(id: id)
    }

    func clearSelection() {
        selectedSummaryID = nil
        selectedReport = nil
    }

    func delete(id: UUID) {
        storageQueue.sync { try? storage.delete(id: id) }
        if selectedSummaryID == id { clearSelection() }
        refresh()
    }

    @discardableResult
    func saveAndEnforce(session: MissionReplaySession, report: MissionReport,
                        assetArchives: [String: MissionReplayVisualAssetArchive] = [:]) -> MissionReplaySession {
        let write = ReplayStorageWrite(storage: storage, session: session, report: report,
            policy: retentionPolicy, assetArchives: assetArchives)
        let resolved = storageQueue.sync { write.perform() }
        refresh()
        return resolved
    }

    /// Mission completion happens in the collision tick. Encoding scene archives/JSON and
    /// writing them there holds up the very frame that should show the flash. The recorder has
    /// already captured an immutable value snapshot; only persistence belongs on this queue.
    func saveAndEnforceInBackground(session: MissionReplaySession, report: MissionReport,
                                   assetArchives: [String: MissionReplayVisualAssetArchive] = [:]) {
        let write = ReplayStorageWrite(storage: storage, session: session, report: report,
            policy: retentionPolicy, assetArchives: assetArchives)
        storageQueue.async { [self] in
            _ = write.perform()
            DispatchQueue.main.async { self.refresh() }
        }
    }
}

/// Immutable session/report values cross to one serial writer. Storage coders are operation
/// local, and no SceneKit node or live recorder is accessed from the persistence worker.
private final class ReplayStorageWrite: @unchecked Sendable {
    let storage: MissionReplayStorageService
    let session: MissionReplaySession
    let report: MissionReport
    let policy: MissionReplayRetentionPolicy
    let assetArchives: [String: MissionReplayVisualAssetArchive]

    init(storage: MissionReplayStorageService, session: MissionReplaySession,
         report: MissionReport, policy: MissionReplayRetentionPolicy,
         assetArchives: [String: MissionReplayVisualAssetArchive]) {
        self.storage = storage; self.session = session; self.report = report; self.policy = policy
        self.assetArchives = assetArchives
    }

    func perform() -> MissionReplaySession {
        var resolved = session
        for (id, archive) in assetArchives {
            if let data = archive.resolvedData() {
                if resolved.visualAssets == nil { resolved.visualAssets = [:] }
                resolved.visualAssets?[id] = data
            } else {
                print("[ReplayStorage] Visual archive failed: \(id)")
            }
        }
        do {
            try storage.save(session: resolved, report: report)
            storage.enforceRetention(policy)
        } catch {
            print("[ReplayStorage] Save failed: \(error)")
        }
        return resolved
    }
}
