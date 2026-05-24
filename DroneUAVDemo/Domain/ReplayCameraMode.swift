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
            return "Свободный наблюдатель"
        case .chase:
            return "Преследование"
        case .orbit:
            return "Орбита"
        case .topDown:
            return "Вид сверху"
        case .fpvApproximation:
            return "От первого лица"
        case .payloadFollow:
            return "За грузом"
        case .cinematicEvent:
            return "Событие"
        }
    }
}
