import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "en", german = "de"
    static let defaultsKey = "klangschrift.appLanguage"
    static var current: AppLanguage {
        let raw = UserDefaults(suiteName: "group.io.github.miggidev618.klangschrift")?.string(forKey: defaultsKey)
        return raw.flatMap(Self.init(rawValue:)) ?? .english
    }
    var title: String { self == .english ? "English" : "Deutsch" }
    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "de_CH") }

    func formattedBytes(_ bytes: Int) -> String {
        // ByteCountFormatter provides the decimal unit; NumberFormatter applies
        // the chosen app locale and rounds compact download sizes to whole MB.
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB]
        formatter.includesCount = false
        let unit = formatter.string(fromByteCount: Int64(bytes)).trimmingCharacters(in: .whitespaces)
        let number = NumberFormatter()
        number.locale = locale
        number.maximumFractionDigits = 0
        number.minimumFractionDigits = 0
        return "\(number.string(from: NSNumber(value: Double(bytes) / 1_000_000)) ?? "0") \(unit)"
    }
}

func L(_ en: String, _ de: String) -> String {
    AppLanguage.current == .german ? de : en
}
