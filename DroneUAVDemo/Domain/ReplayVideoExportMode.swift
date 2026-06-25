import Foundation

enum ReplayVideoExportMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case fast
    case quality

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .fast:
            return "replay.export_mode.fast"
        case .quality:
            return "replay.export_mode.quality"
        }
    }

    var displayName: String {
        L10n.s(titleKey, language: L10n.currentLanguage())
    }

    private var descriptionKey: String {
        switch self {
        case .fast:
            return "replay.export_mode.fast.description"
        case .quality:
            return "replay.export_mode.quality.description"
        }
    }

    var description: String {
        L10n.s(descriptionKey, language: L10n.currentLanguage())
    }
}
