import Foundation

/// Lightweight localization entry point: follows system language (en / zh-Hans).
enum L10n {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}
