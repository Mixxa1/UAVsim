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
        try? storage.delete(id: id)
        if selectedSummaryID == id { clearSelection() }
        refresh()
    }

    func saveAndEnforce(session: MissionReplaySession, report: MissionReport) {
        try? storage.save(session: session, report: report)
        storage.enforceRetention(retentionPolicy)
        refresh()
    }
}
