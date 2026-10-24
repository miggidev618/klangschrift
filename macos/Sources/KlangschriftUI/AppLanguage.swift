import KlangschriftPresentation
import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, de, en
    public var id: String { rawValue }
    public var title: String { switch self { case .system: L("Systemsprache"); case .de: "Deutsch"; case .en: "English" } }
    public var locale: Locale { self == .system ? AppLocalization.locale : Locale(identifier: rawValue) }
}

/// Kept outside the strictly decoded database settings envelope.
/// Reading a missing/invalid preference does not write to UserDefaults.
@MainActor public final class AppLanguageStore {
    public static let key = AppLocalization.preferenceKey
    private let defaults: UserDefaults
    public private(set) var language: AppLanguage
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = defaults.string(forKey: Self.key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
    public func setLanguage(_ language: AppLanguage) {
        self.language = language
        defaults.set(language.rawValue, forKey: Self.key)
    }
}

/// Explicit-language lookup is useful for previews and tests; production uses the launch language.
public func L(_ key: String, language: AppLanguage) -> String {
    AppLocalization.text(key, language: language == .system ? nil : language.rawValue)
}
