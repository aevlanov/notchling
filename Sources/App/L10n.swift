import Foundation

/// Язык интерфейса: русский или английский. Выбирается при первом запуске и в меню.
enum AppLanguage: String, CaseIterable {
    case en, ru

    var displayName: String {
        switch self {
        case .en: "English"
        case .ru: "Русский"
        }
    }
}

enum L10n {
    private static let key = "language"

    /// Выбран ли язык явно (если нет — при запуске спросим).
    static var isChosen: Bool { UserDefaults.standard.string(forKey: key) != nil }

    static var language: AppLanguage {
        get {
            if let raw = UserDefaults.standard.string(forKey: key), let l = AppLanguage(rawValue: raw) { return l }
            // По умолчанию — язык системы.
            let sys = Locale.preferredLanguages.first?.lowercased() ?? "en"
            return sys.hasPrefix("ru") ? .ru : .en
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// Строка интерфейса на текущем языке: tr("Русский текст", "English text").
func tr(_ ru: String, _ en: String) -> String {
    L10n.language == .ru ? ru : en
}
