import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case french

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .french: return "Français"
        }
    }

    var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .french: return Locale(identifier: "fr")
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "app.language") ?? "system") ?? .system
    }
}
