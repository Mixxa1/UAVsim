import Foundation

enum ReplayVideoExportMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case fast
    case quality

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .quality:
            return "Quality"
        }
    }

    var description: String {
        switch self {
        case .fast:
            return "Lightweight export. Lower heat, fewer details, faster output."
        case .quality:
            return "Detailed export. More scene details, slower rendering, higher CPU usage."
        }
    }
}
