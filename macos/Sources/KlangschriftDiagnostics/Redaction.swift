import Foundation
public enum DiagnosticCode: String, Sendable { case helperConfigured, helperPrepared, insertionBlocked, audioCleanup, cryptoFailure }
public struct SafeDiagnosticEvent: Sendable, Equatable {
    public let code: DiagnosticCode; public let attributes: [String: String]
    public init(code: DiagnosticCode, attributes: [String: String] = [:]) {
        self.code = code
        self.attributes = attributes.filter { key, value in
            ["component", "status", "duration_bucket", "model_revision"].contains(key) && value.count <= 64 && value.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || $0.properties.numericType != nil || "._-".unicodeScalars.contains($0)) }
        }
    }
    public func encoded() -> String { (["code=\(code.rawValue)"] + attributes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }).joined(separator: " ") }
}
public enum DiagnosticRedactor {
    public static func redact(_ message: String) -> String {
        let patterns = ["(?i)(transcript|audio|clipboard|secret|token|password)\\s*[:=]\\s*[^\\s]+", "/Users/[^\\s]+"]
        return patterns.reduce(message) { value, pattern in value.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression) }
    }
}
