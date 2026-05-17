import Foundation

enum ReplayExportResolutionPreset: String, Codable, CaseIterable, Identifiable, Equatable {
    case p360
    case p480
    case p720
    case p1080
    case p1440

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p360:
            return "360p"
        case .p480:
            return "480p"
        case .p720:
            return "720p"
        case .p1080:
            return "1080p"
        case .p1440:
            return "1440p"
        }
    }

    var width: Int {
        switch self {
        case .p360:
            return 640
        case .p480:
            return 854
        case .p720:
            return 1280
        case .p1080:
            return 1920
        case .p1440:
            return 2560
        }
    }

    var height: Int {
        switch self {
        case .p360:
            return 360
        case .p480:
            return 480
        case .p720:
            return 720
        case .p1080:
            return 1080
        case .p1440:
            return 1440
        }
    }
}
