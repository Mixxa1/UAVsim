import Foundation

enum L10n {
    static func s(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }

    /// Explicit-language lookup for code with no SwiftUI environment to inherit a locale from
    /// (AppKit windows, the replay scene/export layers). `NSLocalizedString` alone always
    /// resolves via the system locale, not the in-app `AppLanguage` picker — SwiftUI views get
    /// the picker's choice for free via `.environment(\.locale:)`, this is the equivalent for
    /// everything else.
    static func s(_ key: String, language: AppLanguage) -> String {
        guard let bundle = bundle(for: language) else {
            return NSLocalizedString(key, comment: "")
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    static func f(_ key: String, language: AppLanguage, _ args: CVarArg...) -> String {
        let format = bundle(for: language)?.localizedString(forKey: key, value: nil, table: nil)
            ?? NSLocalizedString(key, comment: "")
        return String(format: format, arguments: args)
    }

    static func currentLanguage() -> AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? AppLanguage.system.rawValue) ?? .system
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        guard language != .system,
              let path = Bundle.main.path(forResource: language.locale.identifier, ofType: "lproj") else {
            return nil
        }
        return Bundle(path: path)
    }
}
