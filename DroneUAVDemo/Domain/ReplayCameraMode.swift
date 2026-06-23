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

    var titleKey: String {
        switch self {
        case .freeObserver:
            return "replay.camera_mode.free_observer"
        case .chase:
            return "replay.camera_mode.chase"
        case .orbit:
            return "replay.camera_mode.orbit"
        case .topDown:
            return "replay.camera_mode.top_down"
        case .fpvApproximation:
            return "replay.camera_mode.fpv"
        case .payloadFollow:
            return "replay.camera_mode.payload_follow"
        case .cinematicEvent:
            return "replay.camera_mode.cinematic_event"
        }
    }

    var displayName: String {
        L10n.s(titleKey, language: L10n.currentLanguage())
    }
}
