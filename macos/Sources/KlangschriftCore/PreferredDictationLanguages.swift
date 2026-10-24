import Foundation

/// Separate additive preference: existing persisted settings envelopes remain readable.
public enum PreferredDictationLanguages {
    public static let defaults = ["de", "en"]
    public static let supported = ["de", "en", "fr", "es", "it", "pt", "nl"]
    public static let key = "klangschrift.preferredDictationLanguages"
    public static func normalized(_ codes: [String]) -> [String] {
        var result: [String] = []
        for code in codes where supported.contains(code) && !result.contains(code) { result.append(code) }
        return result.isEmpty ? defaults : result
    }
    public static func load(from defaults: UserDefaults = .standard) -> [String] {
        normalized(defaults.stringArray(forKey: key) ?? Self.defaults)
    }
    public static func save(_ codes: [String], to defaults: UserDefaults = .standard) {
        defaults.set(normalized(codes), forKey: key)
    }
}
