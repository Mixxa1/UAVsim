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

    /// "en"/"ru" code used to pick localized content from data files (e.g. bilingual legal
    /// documents). `.system` resolves from the OS preferred language, defaulting to English.
    var legalLanguageCode: String {
        switch self {
        case .english:
            return "en"
        case .russian:
            return "ru"
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ru") ? "ru" : "en"
        }
    }
}
