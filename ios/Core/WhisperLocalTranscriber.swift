import Foundation
import FluidAudio
@preconcurrency import WhisperKit

/// The app's FIFO gate spans every prepare/inference call. This box permits the
/// native SDK's async functions while retaining one resident, serialized owner.
private final class WhisperResident: @unchecked Sendable {
    let model: WhisperKit
    init(_ model: WhisperKit) { self.model = model }
}
actor WhisperLocalTranscriber {
    private let modelID: DictationModelID
    private let directory: URL
    private var resident: WhisperResident?
    private var verified = false
    init(modelID: DictationModelID, resourceRoot: URL?) {
        self.modelID = modelID
        directory = resourceRoot.map { $0.appendingPathComponent(DictationModelDescriptor.descriptor(for: modelID).bundleDirectory) } ?? DictationModelStorage.directory(for: modelID)
    }
    func prepare(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        _ = try await load(operationID: operationID, permit: permit, observer: observer)
        try Task.checkCancellation()
    }
    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String {
        let current = try await load(operationID: operationID, observer: observer)
        let samples = try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .audioLoad, observer: observer) {
            let samples = try RecordingAudioResampler.samples(from: recording)
            guard !samples.isEmpty else { throw LocalTranscriberError.emptyAudio }
            return samples
        }
        let spellings = (try? TranscriptPersistence.loadSpellings()) ?? []
        let promptTokens = WhisperModelProfile.promptTokens(for: modelID, spellings: spellings, tokenizer: current.model.tokenizer)
        let options = WhisperModelProfile.decodingOptions(for: modelID, promptTokens: promptTokens)
        return try await runAsyncTranscriptionStage(operationID: operationID, modelID: modelID, stage: .generate, observer: observer) {
            let results = try await current.model.transcribe(audioArray: samples, decodeOptions: options)
            return try validatedTranscriptionText(DictationTextSpacing.join(results.map(\.text)))
        }
    }
    private func load(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> WhisperResident {
        try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .verify, cacheHit: verified, observer: observer) {
            try permit?.check()
            if !verified { try DictationModelManifest.validate(modelID, directory: directory); verified = true }
        }
        if let resident {
            _ = try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .modelLoad, cacheHit: true, observer: observer) { true }
            return resident
        }
        let directory = directory
        let loaded = try await runAsyncTranscriptionStage(operationID: operationID, modelID: modelID, stage: .modelLoad, observer: observer) {
            try permit?.check()
            let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
            let config = WhisperKitConfig(modelFolder: directory.path, tokenizerFolder: directory.appendingPathComponent("Tokenizer"), computeOptions: compute, verbose: false, prewarm: false, load: true, download: false)
            return WhisperResident(try await WhisperKit(config))
        }
        try Task.checkCancellation()
        resident = loaded
        return loaded
    }
}

enum WhisperModelProfile {
    static let maximumPromptTokens = 96

    static func isWhisper(_ id: DictationModelID) -> Bool {
        [.whisperTinyCoreML, .whisperTinyENCoreML, .whisperBaseCoreML, .whisperBaseENCoreML].contains(id)
    }
    static func promptTokens(for id: DictationModelID, spellings: [PersonalSpelling], tokenizer: (any WhisperTokenizer)?) -> [Int]? {
        guard let tokenizer else { return nil }
        return promptTokens(for: id, spellings: spellings, encode: { tokenizer.encode(text: $0) }, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
    }
    static func promptTokens(for id: DictationModelID, spellings: [PersonalSpelling], encode: (String) -> [Int], specialTokenBegin: Int) -> [Int]? {
        guard isWhisper(id), let prompt = RecognitionHintPrompt.text(from: spellings) else { return nil }
        let tokens = encode(" " + prompt)
            .filter { $0 < specialTokenBegin }
            .prefix(maximumPromptTokens)
        return tokens.isEmpty ? nil : Array(tokens)
    }
    static func decodingOptions(for id: DictationModelID, language: DictationLanguage = .selected(), promptTokens: [Int]? = nil) -> DecodingOptions {
        let english = id == .whisperTinyENCoreML || id == .whisperBaseENCoreML
        return DecodingOptions(task: .transcribe, language: english ? "en" : language.code, usePrefillPrompt: true, detectLanguage: !english && language == .automatic, skipSpecialTokens: true, withoutTimestamps: false, promptTokens: isWhisper(id) ? promptTokens : nil, concurrentWorkerCount: 1)
    }
}

enum DictationLanguage: String, CaseIterable {
    case german = "de", english = "en", automatic = "auto"
    var title: String { switch self { case .german: "Deutsch"; case .english: "Englisch"; case .automatic: "Automatisch" } }
    static let defaultsKey = "klangschrift.dictation-language.v1"
    var code: String? { switch self { case .german: "de"; case .english: "en"; case .automatic: nil } }
    static func migrateLegacyValue(defaults: UserDefaults = .standard) {
        guard let value = defaults.string(forKey: defaultsKey),
              let language = Self.allCases.first(where: { $0.title == value }) else { return }
        defaults.set(language.rawValue, forKey: defaultsKey)
    }
    static func selected(defaults: UserDefaults = .standard) -> Self {
        let value = defaults.string(forKey: defaultsKey)
        return value.flatMap(Self.init(rawValue:)) ?? Self.allCases.first(where: { $0.title == value }) ?? .german
    }
}

/// Preserve recognition content while separating independently returned segments.
enum DictationTextSpacing {
    static func join(_ segments: [String]) -> String {
        segments.reduce(into: "") { result, segment in
            guard !segment.isEmpty else { return }
            if let last = result.last, let first = segment.first,
               !last.isWhitespace, !first.isWhitespace {
                result.append(" ")
            }
            result.append(segment)
        }
    }
}
