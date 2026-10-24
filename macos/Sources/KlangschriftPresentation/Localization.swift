import Foundation

/// One catalog and one lookup path for all app-owned presentation text.
/// The preference is captured once at startup; changing it takes effect next launch.
public enum AppLocalization {
    public static let preferenceKey = "klangschrift.appLanguage"
    public static let launchLanguage = preference(in: .standard)
    public static func preference(in defaults: UserDefaults) -> String {
        let value = defaults.string(forKey: preferenceKey) ?? "system"
        return ["system", "de", "en"].contains(value) ? value : "system"
    }
    public static var language: String { resolvedLanguage(launchLanguage) }
    public static var locale: Locale { Locale(identifier: language) }

    public static func resolvedLanguage(_ requested: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if requested == "de" || requested == "en" { return requested }
        for preference in preferredLanguages {
            let code = preference.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)
            if let code, code == "de" || code == "en" { return code }
        }
        return "de"
    }
    public static func requiresRestart(for requested: String, launch: String = launchLanguage,
                                       preferredLanguages: [String] = Locale.preferredLanguages) -> Bool {
        resolvedLanguage(requested, preferredLanguages: preferredLanguages) !=
            resolvedLanguage(launch, preferredLanguages: preferredLanguages)
    }
    public static func text(_ key: String, language: String? = nil, arguments: [CVarArg] = []) -> String {
        let selected = resolvedLanguage(language ?? launchLanguage)
        let bundle = Bundle.module.url(forResource: selected, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .module
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: Locale(identifier: selected), arguments: arguments)
    }
    /// Localizes product-owned display messages without touching model IDs, names or dictated data.
    /// Exact catalog keys are preferred. Interpolated legacy messages are matched against
    /// catalog templates, keeping the product/worker modules independent of UI resources.
    public static func productText(_ value: String, language: String? = nil) -> String {
        let exact = text(value, language: language)
        if exact != value { return exact }
        for template in productTemplates {
            let segments = template.components(separatedBy: "%@")
            let pattern = "^" + segments.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { continue }
            let arguments: [CVarArg] = (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: value).map { text(String(value[$0]), language: language) }
            }
            return text(template, language: language, arguments: arguments)
        }
        return value
    }
    private static let productTemplates: [String] = {
        guard let folder = Bundle.module.url(forResource: "de", withExtension: "lproj"),
              let data = try? Data(contentsOf: folder.appendingPathComponent("Localizable.strings")),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { return [] }
        return table.keys.filter { $0.contains("%@") }.sorted()
    }()

}

public func L(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.text(key, arguments: arguments)
}
