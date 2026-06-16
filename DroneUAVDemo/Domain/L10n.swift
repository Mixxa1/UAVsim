import Foundation

enum L10n {
    static func s(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }
    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), arguments: args)
    }
}
