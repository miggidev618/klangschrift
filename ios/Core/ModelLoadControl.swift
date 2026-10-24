import Foundation

public enum ModelLoadOrigin: Int, Codable, Sendable { case automatic, mainDictation, keyboard, manual }
public enum ModelOperationOutcome: Int, Codable, Sendable { case completed, cancelled, failed }
/// Shared with native worker queues. Invalidation cannot interrupt an SDK call already begun.
public final class ModelLoadPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    private var claims: [UUID: Set<DictationModelID>] = [:]
    public init() {}
    public func invalidate() { lock.lock(); allowed = false; lock.unlock() }
    public var isValid: Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func claim(_ models: Set<DictationModelID>) -> UUID {
        lock.lock(); defer { lock.unlock() }; let token = UUID(); claims[token] = models; allowed = false; return token
    }
    func release(_ token: UUID) { lock.lock(); claims[token] = nil; lock.unlock() }
    func hasDemand(for model: DictationModelID) -> Bool { lock.lock(); defer { lock.unlock() }; return claims.values.contains { $0.contains(model) } }
    public func check() throws { if !isValid { throw CancellationError() } }
}

public struct ModelLoadSample: Codable, Equatable, Sendable {
    public let origin: ModelLoadOrigin
    public let outcome: ModelOperationOutcome
    public let inference: Bool
    public let queueMS: UInt64
    public let verifyMS: UInt64
    public let nativeInitMS: UInt64
    public let fullMS: UInt64
    public let generateMS: UInt64
    public let cacheHit: Bool
    /// Zero if generation was never reached; otherwise ordinal within this resident instance.
    public let inferenceOrdinal: UInt64
}
public enum ModelLoadMetricsStore {
    private static let lock = NSLock()
    static let key = "klangschrift.model-load.v1."
    public static let capacity = 32
    public static func read(_ id: DictationModelID, defaults: UserDefaults = .standard) -> [ModelLoadSample] {
        lock.lock(); defer { lock.unlock() }
        return decode(id, defaults: defaults)
    }
    private static func decode(_ id: DictationModelID, defaults: UserDefaults) -> [ModelLoadSample] {
        guard let data = defaults.data(forKey: key + id.rawValue), let entries = try? JSONDecoder().decode([ModelLoadSample].self, from: data) else { return [] }
        return Array(entries.suffix(capacity))
    }
    static func record(_ id: DictationModelID, sample: ModelLoadSample, defaults: UserDefaults = .standard) {
        lock.lock(); defer { lock.unlock() }
        var samples = decode(id, defaults: defaults); samples.append(sample)
        defaults.set(try? JSONEncoder().encode(Array(samples.suffix(capacity))), forKey: key + id.rawValue)
    }
    public static func summary(_ id: DictationModelID) -> String? {
        guard let sample = read(id).last(where: { !$0.inference }) else { return nil }
        let label = sample.outcome == .completed ? "Letzte Vorbereitung" : sample.outcome == .cancelled ? "Vorbereitung abgebrochen" : "Vorbereitung fehlgeschlagen"
        return String(format: "%@: %.2f s · Warten %.2f s · Prüfen %.2f s · Initialisieren %.2f s%@", label, Double(sample.fullMS)/1000, Double(sample.queueMS)/1000, Double(sample.verifyMS)/1000, Double(sample.nativeInitMS)/1000, sample.cacheHit ? " · aus RAM" : "")
    }
}
