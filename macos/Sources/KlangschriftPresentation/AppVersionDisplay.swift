import Foundation

public enum AppVersionDisplay {
    public static var value: String { format(shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, includeLabel: false) }
    public static var current: String { string(bundle: .main) }

    public static func string(bundle: Bundle) -> String {
        format(shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
               build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    public static func format(shortVersion: String?, build: String?, includeLabel: Bool = true) -> String {
        guard let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !version.isEmpty,
              let build = build?.trimmingCharacters(in: .whitespacesAndNewlines), !build.isEmpty else {
            return "Entwicklungsbuild"
        }
        return "\(includeLabel ? "Version " : "")\(version) (Build \(build))"
    }
}
