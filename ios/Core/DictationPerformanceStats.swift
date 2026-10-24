import AVFoundation
import Foundation

public struct DictationPerformanceStats: Codable, Sendable, Equatable {
    public var successfulJobs: Int = 0
    public var audioSeconds: Double = 0
    public var generateMS: UInt64 = 0
    public var totalMS: UInt64 = 0
    public var loadMS: UInt64 = 0
    public var modelLoads: Int = 0
    public var summary: String {
        guard successfulJobs > 0 else { return "Noch nicht gemessen" }
        let jobs = Double(successfulJobs)
        return String(format: "%d Diktate · Ø %.1f s Audio / %.2f s Verarbeitung · Laden gesamt %.2f s (%d)", successfulJobs, audioSeconds / jobs, Double(totalMS) / 1000 / jobs, Double(loadMS) / 1000, modelLoads)
    }
}
/// Stores only numeric measurements keyed by the model ID. No audio, transcript or context.
public enum DictationPerformanceStore {
    static let key = "klangschrift.model-performance.v1."
    public static func read(_ id: DictationModelID, defaults: UserDefaults = .standard) -> DictationPerformanceStats {
        guard let data = defaults.data(forKey: key + id.rawValue), let stats = try? JSONDecoder().decode(DictationPerformanceStats.self, from: data) else { return .init() }
        return stats
    }
    static func recordPreparation(_ id: DictationModelID, loadMS: UInt64, loaded: Bool, defaults: UserDefaults = .standard) {
        guard loaded else { return }
        var stats = read(id, defaults: defaults); stats.loadMS += loadMS; stats.modelLoads += 1
        defaults.set(try? JSONEncoder().encode(stats), forKey: key + id.rawValue)
    }
    static func record(_ id: DictationModelID, audioSeconds: Double, generateMS: UInt64, totalMS: UInt64, loadMS: UInt64, loaded: Bool, defaults: UserDefaults = .standard) {
        guard audioSeconds.isFinite, audioSeconds > 0 else { return }
        var stats = read(id, defaults: defaults)
        stats.successfulJobs += 1; stats.audioSeconds += audioSeconds; stats.generateMS += generateMS
        stats.totalMS += totalMS; stats.loadMS += loadMS; stats.modelLoads += loaded ? 1 : 0
        defaults.set(try? JSONEncoder().encode(stats), forKey: key + id.rawValue)
    }
}
final class JobMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var generate: UInt64 = 0, load: UInt64 = 0, verify: UInt64 = 0
    private var cacheHit = false
    private var attemptedGenerate = false
    private var loaded = false
    func observe(_ event: LocalTranscriptionStageEvent) {
        lock.lock(); defer { lock.unlock() }
        if event.stage == .generate && event.outcome == .started { attemptedGenerate = true }
        guard event.outcome != .started else { return }
        if event.stage == .verify { verify += event.durationMS ?? 0 }
        if event.stage == .modelLoad { cacheHit = event.cacheHit }
        if event.stage == .generate { generate += event.durationMS ?? 0 }
        if event.stage == .modelLoad && !event.cacheHit { load += event.durationMS ?? 0; loaded = event.outcome == .completed }
    }
    var generateAttempted: Bool { lock.lock(); defer { lock.unlock() }; return attemptedGenerate }
    func sample(origin: ModelLoadOrigin, outcome: ModelOperationOutcome, inference: Bool, queueMS: UInt64, fullMS: UInt64, ordinal: UInt64) -> ModelLoadSample {
        lock.lock(); defer { lock.unlock() }
        return ModelLoadSample(origin: origin, outcome: outcome, inference: inference, queueMS: queueMS, verifyMS: verify, nativeInitMS: load, fullMS: fullMS, generateMS: generate, cacheHit: cacheHit, inferenceOrdinal: attemptedGenerate ? ordinal : 0)
    }
    func savePreparation(model: DictationModelID) {
        lock.lock(); defer { lock.unlock() }
        DictationPerformanceStore.recordPreparation(model, loadMS: load, loaded: loaded)
    }
    func save(model: DictationModelID, recording: URL, totalMS: UInt64) {
        guard let file = try? AVAudioFile(forReading: recording), file.processingFormat.sampleRate > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        DictationPerformanceStore.record(model, audioSeconds: Double(file.length) / file.processingFormat.sampleRate, generateMS: generate, totalMS: totalMS, loadMS: load, loaded: loaded)
    }
}

/// AP8 fixed synthetic reference corpus, measured on Mac14,2 on 2026-10-22.
/// Mac reference speed is not an iPhone hardware measurement. No size-based guesses.
public struct ModelReferenceMeasurement: Sendable {
    public let qualityStars: Int
    public let speedStars: Int
    public let wordErrorRate: Double
    public let realTimeFactor: Double
    public static func measured(_ id: DictationModelID) -> Self? {
        switch id {
        case .whisperBaseCoreML: return .init(qualityStars: 5, speedStars: 5, wordErrorRate: 0.012048192771084338, realTimeFactor: 0.02614490256358671)
        case .moonshineSmallStreamingDE: return .init(qualityStars: 3, speedStars: 5, wordErrorRate: 0.0625, realTimeFactor: 0.03992499999344723)
        default: return nil
        }
    }
}
