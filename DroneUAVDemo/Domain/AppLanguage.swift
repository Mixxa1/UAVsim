import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case russian

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .russian:
            return Locale(identifier: "ru")
        }
    }

    var titleKey: String {
        switch self {
        case .system:
            return "language.system"
        case .english:
            return "language.english"
        case .russian:
            return "language.russian"
        }
    }
}
