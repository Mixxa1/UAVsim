import Foundation

enum ReplayCameraMode: String, CaseIterable, Identifiable, Codable, Equatable {
    case freeObserver
    case chase
    case orbit
    case topDown
    case fpvApproximation
    case payloadFollow
    case cinematicEvent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .freeObserver:
            return "Free Observer"
        case .chase:
            return "Chase"
        case .orbit:
            return "Orbit"
        case .topDown:
            return "Top-Down"
        case .fpvApproximation:
            return "FPV Approx"
        case .payloadFollow:
            return "Payload"
        case .cinematicEvent:
            return "Cinematic Event"
        }
    }
}
