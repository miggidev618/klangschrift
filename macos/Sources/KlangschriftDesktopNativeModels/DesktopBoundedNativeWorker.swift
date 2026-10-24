import KlangschriftCore
import Darwin
import Foundation
import CoreML
import KlangschriftDesktopModelCatalog
import KlangschriftDesktopModels
import FluidAudio
import MoonshineVoice
@preconcurrency import WhisperKit
import SherpaOnnxC

/// Executes a Moonshine model on the worker process' native-owner executor.
/// The type is deliberately desktop-scoped; it shares no iOS lifecycle or UI
/// symbols. A process owns one inference, so cancellation can be confirmed by
/// reaping that process even when an SDK call itself is not cooperative.
public actor DesktopMoonshineFileRunner {
    private let modelID: String
    private let modelDirectory: URL
    private var transcriber: Transcriber?

    public init(modelID: String, modelDirectory: URL) throws {
        guard try DesktopNativeSDKBindings.binding(for: modelID) == .moonshine else {
            throw DesktopRuntimeError.unavailable
        }
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    public func prepare() throws {
        guard transcriber == nil else { return }
        transcriber = try Transcriber(
            modelPath: modelDirectory.path,
            modelArch: try DesktopNativeRunnerContract.moonshineArchitecture(for: modelID),
            options: options(for: modelID)
        )
    }

    public func transcribe(audioFile: URL) throws -> String {
        try prepare()
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioFile)
        guard !samples.isEmpty, let transcriber else { throw DesktopRuntimeError.nativeFailure }
        let transcript = try transcriber.transcribeWithoutStreaming(audioData: samples, sampleRate: 16_000, flags: 0)
        let text = transcript.lines.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DesktopRuntimeError.noSpeech }
        return text
    }

    public func unload() {
        transcriber?.close()
        transcriber = nil
    }

    private func options(for id: String) -> [TranscriberOption] {
        var result = [TranscriberOption(name: "ort_providers", value: "CPU")]
        switch id {
        case "moonshine-tiny-streaming-ar", "moonshine-tiny-streaming-ja", "moonshine-small-streaming-ja", "moonshine-tiny-streaming-zh":
            result.append(.init(name: "max_tokens_per_second", value: "13.0"))
        default:
            break
        }
        return result
    }
}

/// Native FluidAudio/Core ML owner. `loadLocal` receives only an already
/// installer-validated directory and therefore cannot fetch a model, tokenizer
/// or repository at prepare/transcribe time.
public actor DesktopFluidAudioFileRunner {
    private let modelID: String
    private let modelDirectory: URL
    private var manager: AsrManager?

    public init(modelID: String, modelDirectory: URL) throws {
        guard try DesktopNativeSDKBindings.binding(for: modelID) == .fluidAudio else {
            throw DesktopRuntimeError.unavailable
        }
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    public func prepare() async throws {
        guard manager == nil else { return }
        // These fixed markers distinguish the two local SDK boundaries without
        // retaining a path, SDK error string, model data or audio content.
        // They are useful when the bounded child is reaped during a prepare.
        nativeDiagnosticStage("fluid_prepare_started")
        // On this verified host the two Parakeet encoders complete their
        // local Core ML load with CPU-only, whereas their ANE selection does
        // not complete within the bounded child diagnostic. Do not broaden
        // this fallback to Phonon: its CPU-only encoder did not complete
        // either, so it remains an explicit open native-runtime outcome.
        let encoderComputeUnits = try DesktopNativeRunnerContract.fluidEncoderCompute(for: modelID)
        let models = try await AsrModels.loadLocalAsync(
            from: modelDirectory,
            version: try DesktopNativeRunnerContract.fluidVersion(for: modelID),
            encoderComputeUnits: encoderComputeUnits,
            phaseHandler: { nativeDiagnosticStage("fluid_\($0)") }
        )
        nativeDiagnosticStage("fluid_models_loaded")
        manager = AsrManager(models: models)
        nativeDiagnosticStage("fluid_manager_created")
    }

    public func transcribe(audioFile: URL) async throws -> String {
        try await prepare()
        guard let manager else { throw DesktopRuntimeError.nativeFailure }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audioFile, decoderState: &state)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DesktopRuntimeError.noSpeech }
        return text
    }

    public func unload() { manager = nil }

}

/// Native WhisperKit owner with explicit local directories and `download:
/// false`. The SDK never receives a hub URL or a cache-discovery path.
public actor DesktopWhisperKitFileRunner {
    private let modelID: String
    private let modelDirectory: URL
    private var model: WhisperKit?

    public init(modelID: String, modelDirectory: URL) throws {
        guard try DesktopNativeSDKBindings.binding(for: modelID) == .whisperKit else {
            throw DesktopRuntimeError.unavailable
        }
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    public func prepare() async throws {
        guard model == nil else { return }
        let configuration = try DesktopNativeRunnerContract.whisperConfiguration(for: modelID, modelDirectory: modelDirectory)
        model = try await WhisperKit(configuration)
    }

    public func transcribe(audioFile: URL) async throws -> String {
        try await transcribe(audioFile: audioFile, language: .automatic)
    }
    public func transcribe(audioFile: URL, language: DesktopDictationLanguage) async throws -> String {
        try await transcribe(audioFile: audioFile, language: language, preferredLanguages: PreferredDictationLanguages.defaults)
    }
    public func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String]) async throws -> String {
        try await transcribe(audioFile: audioFile, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: nil)
    }
    private var lastSuccessfulLanguage: DesktopDictationLanguage?
    public func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String {
        try await prepare()
        guard let model else { throw DesktopRuntimeError.nativeFailure }
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioFile)
        guard !samples.isEmpty else { throw DesktopRuntimeError.nativeFailure }
        let englishOnly = modelID == "whisper-tiny-en-coreml" || modelID == "whisper-base-en-coreml"
        let policy = WhisperPreferredLanguagePolicy(preferredLanguages: preferredLanguages, lastSuccessfulLanguage: lastSuccessfulLanguage)
        let duration = Double(samples.count) / 16_000
        var detected: String?
        if !englishOnly && language == .automatic && policy.needsDetection(duration: duration) {
            do { detected = try await model.detectLangauge(audioArray: samples).language }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        try Task.checkCancellation()
        let chosen = englishOnly ? language : policy.choose(requested: language, duration: duration, detected: detected)
        let promptTokens = recognitionHintPrompt.flatMap { prompt in
            model.tokenizer.map { Array($0.encode(text: prompt).prefix(RecognitionHintPrompt.maximumWhisperPromptTokens)) }
        }
        let results = try await model.transcribe(audioArray: samples, decodeOptions: try DesktopNativeRunnerContract.whisperDecodingOptions(for: modelID, language: chosen, promptTokens: promptTokens))
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DesktopRuntimeError.noSpeech }
        try Task.checkCancellation()
        if !englishOnly { lastSuccessfulLanguage = chosen }
        return text
    }

    public func unload() { model = nil }

}

/// Serialized Sherpa C-ABI owner. It consumes a local, installer-validated
/// Zipformer directory and has no HTTP or cache lookup path.
private final class DesktopSherpaRecognizer: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    deinit { SherpaOnnxDestroyOnlineRecognizer(pointer) }
}

public actor DesktopSherpaZipformerFileRunner {
    private let modelID: String
    private let modelDirectory: URL
    private var recognizer: DesktopSherpaRecognizer?

    public init(modelID: String, modelDirectory: URL) throws {
        guard modelID == "sherpa-zipformer-en-int8", try DesktopNativeSDKBindings.binding(for: modelID) == .sherpaOnnx else {
            throw DesktopRuntimeError.unavailable
        }
        self.modelID = modelID
        self.modelDirectory = modelDirectory
    }

    public func prepare() throws {
        guard recognizer == nil else { return }
        let values = try DesktopNativeRunnerContract.sherpaFilePaths(for: modelID, modelDirectory: modelDirectory) + ["cpu", "greedy_search"]
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        config.feat_config.feature_dim = 80
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.num_threads = 1
        config.model_config.provider = UnsafePointer(strings[4])
        config.decoding_method = UnsafePointer(strings[5])
        guard let loaded = SherpaOnnxCreateOnlineRecognizer(&config) else { throw DesktopRuntimeError.nativeFailure }
        recognizer = DesktopSherpaRecognizer(loaded)
    }

    public func transcribe(audioFile: URL) throws -> String {
        try prepare()
        guard let recognizer else { throw DesktopRuntimeError.nativeFailure }
        nativeDiagnosticStage("sherpa_transcribe_started")
        let nativeRecognizer = recognizer.pointer
        let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(audioFile)
        guard !samples.isEmpty, let stream = SherpaOnnxCreateOnlineStream(nativeRecognizer) else { throw DesktopRuntimeError.nativeFailure }
        nativeDiagnosticStage("sherpa_stream_created")
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            for start in stride(from: 0, to: samples.count, by: 3_200) {
                let count = min(3_200, samples.count - start)
                SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress!.advanced(by: start), Int32(count))
                while SherpaOnnxIsOnlineStreamReady(nativeRecognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(nativeRecognizer, stream) }
            }
        }
        nativeDiagnosticStage("sherpa_audio_accepted")
        let tail = [Float](repeating: 0, count: 8_000)
        tail.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress!, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(stream)
        nativeDiagnosticStage("sherpa_input_finished")
        while SherpaOnnxIsOnlineStreamReady(nativeRecognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(nativeRecognizer, stream) }
        nativeDiagnosticStage("sherpa_decoded")
        guard let result = SherpaOnnxGetOnlineStreamResult(nativeRecognizer, stream) else { throw DesktopRuntimeError.nativeFailure }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        nativeDiagnosticStage("sherpa_result_received")
        guard let pointer = result.pointee.text else { throw DesktopRuntimeError.nativeFailure }
        let text = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DesktopRuntimeError.noSpeech }
        nativeDiagnosticStage("sherpa_text_received")
        return text
    }

    public func unload() {
        recognizer = nil
    }
}

/// Internal, SDK-shaped selection seam for source contracts. Every entry is
/// called by the production runners above; it neither loads an SDK model nor
/// touches an installer directory beyond forming its fixed local paths.
enum DesktopNativeRunnerContract {
    static func moonshineArchitecture(for id: String) throws -> ModelArch {
        switch id {
        case "moonshine-tiny-streaming-de", "moonshine-tiny-streaming-en", "moonshine-tiny-streaming-ar", "moonshine-tiny-streaming-ja", "moonshine-tiny-streaming-zh", "moonshine-tiny-streaming-es", "moonshine-tiny-streaming-tl", "moonshine-tiny-streaming-vi":
            return .tinyStreaming
        case "moonshine-small-streaming-de", "moonshine-small-streaming-en", "moonshine-small-streaming-ja", "moonshine-small-streaming-es":
            return .smallStreaming
        case "moonshine-medium-streaming-en":
            return .mediumStreaming
        default:
            throw DesktopRuntimeError.unavailable
        }
    }

    static func fluidVersion(for id: String) throws -> AsrModelVersion {
        switch id {
        case "phonon2-coreml", "phonon2-compact-coreml": return .phonon2
        case "parakeet-v3-coreml": return .v3
        case "parakeet-redux-coreml": return .redux
        default: throw DesktopRuntimeError.unavailable
        }
    }

    static func fluidEncoderCompute(for id: String) throws -> MLComputeUnits {
        _ = try fluidVersion(for: id)
        switch id {
        case "parakeet-v3-coreml", "parakeet-redux-coreml": return .cpuOnly
        default: return .cpuAndNeuralEngine
        }
    }

    static func whisperConfiguration(for id: String, modelDirectory: URL) throws -> WhisperKitConfig {
        guard try DesktopNativeSDKBindings.binding(for: id) == .whisperKit else {
            throw DesktopRuntimeError.unavailable
        }
        let compute = ModelComputeOptions(
            melCompute: .cpuOnly,
            audioEncoderCompute: .cpuAndNeuralEngine,
            textDecoderCompute: .cpuAndNeuralEngine
        )
        return WhisperKitConfig(
            modelFolder: modelDirectory.path,
            tokenizerFolder: modelDirectory.appendingPathComponent("Tokenizer"),
            computeOptions: compute,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
    }

    static func whisperDecodingOptions(for id: String, language: DesktopDictationLanguage = .automatic, promptTokens: [Int]? = nil) throws -> DecodingOptions {
        guard try DesktopNativeSDKBindings.binding(for: id) == .whisperKit else {
            throw DesktopRuntimeError.unavailable
        }
        let english = id == "whisper-tiny-en-coreml" || id == "whisper-base-en-coreml"
        return DecodingOptions(
            task: .transcribe,
            language: english ? "en" : language.whisperCode,
            usePrefillPrompt: !english,
            detectLanguage: !english && language == .automatic,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            concurrentWorkerCount: 1
        )
    }

    static func sherpaFilePaths(for id: String, modelDirectory: URL) throws -> [String] {
        guard id == "sherpa-zipformer-en-int8", try DesktopNativeSDKBindings.binding(for: id) == .sherpaOnnx else {
            throw DesktopRuntimeError.unavailable
        }
        return [
            "encoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.int8.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "tokens.txt"
        ].map { modelDirectory.appendingPathComponent($0).path }
    }
}

/// Fixed worker-only progress markers refine a native failure without
/// exposing an SDK error, local path, audio content, or transcript. The
/// bounded parent accepts only lower-case underscore marker values.
private func nativeDiagnosticStage(_ name: String) {
    fputs("KLANGSCHRIFT_WORKER_STAGE=\(name)\n", stderr)
    fflush(stderr)
}

/// Common worker-side model protocol. Each concrete actor remains off the
/// main actor and owns its respective SDK instance.
public protocol DesktopFileInferenceRunner: Sendable {
    func prepare() async throws
    func transcribe(audioFile: URL) async throws -> String
    func transcribe(audioFile: URL, language: DesktopDictationLanguage) async throws -> String
    func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String]) async throws -> String
    func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String
    func unload() async
}

public extension DesktopFileInferenceRunner {
    func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String {
        try await transcribe(audioFile: audioFile, language: language, preferredLanguages: preferredLanguages)
    }
    func transcribe(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String]) async throws -> String {
        try await transcribe(audioFile: audioFile, language: language)
    }
    /// Fixed-language engines keep their existing decoding behavior.
    func transcribe(audioFile: URL, language: DesktopDictationLanguage) async throws -> String {
        try await transcribe(audioFile: audioFile)
    }
}

extension DesktopMoonshineFileRunner: DesktopFileInferenceRunner {}
extension DesktopFluidAudioFileRunner: DesktopFileInferenceRunner {}
extension DesktopWhisperKitFileRunner: DesktopFileInferenceRunner {}
extension DesktopSherpaZipformerFileRunner: DesktopFileInferenceRunner {}

public enum DesktopFileInferenceRunners {
    public static func make(modelID: String, modelDirectory: URL) throws -> any DesktopFileInferenceRunner {
        switch try DesktopNativeSDKBindings.binding(for: modelID) {
        case .moonshine: return try DesktopMoonshineFileRunner(modelID: modelID, modelDirectory: modelDirectory)
        case .fluidAudio: return try DesktopFluidAudioFileRunner(modelID: modelID, modelDirectory: modelDirectory)
        case .whisperKit: return try DesktopWhisperKitFileRunner(modelID: modelID, modelDirectory: modelDirectory)
        case .sherpaOnnx: return try DesktopSherpaZipformerFileRunner(modelID: modelID, modelDirectory: modelDirectory)
        }
    }
}

public struct DesktopNativeWorkerConfiguration: Sendable {
    public let executableURL: URL
    public let modelManifest: DesktopModelInstallManifest
    public let installerRoot: URL
    /// Product default remains 30 seconds. Tests may inject a shorter value to
    /// prove that a silent child cannot hold the reader beyond its deadline.
    public let prepareTimeout: TimeInterval

    public init(executableURL: URL, modelManifest: DesktopModelInstallManifest, installerRoot: URL, prepareTimeout: TimeInterval = 30) {
        self.executableURL = executableURL
        self.modelManifest = modelManifest
        self.installerRoot = installerRoot
        self.prepareTimeout = prepareTimeout
    }
}

/// This is the only exception to the ordinary 30-second worker preparation
/// deadline. It deliberately binds model ID, pinned artifact revision, local
/// FluidAudio runtime and the existing ANE compute selection together. It is
/// not a general long-prepare setting and is unavailable for audio requests.
public enum DesktopPhononFirstPrepareContract {
    public static let artifactRevision = "a812a0dfef205660787ef6234317ab79acf4d5d6"
    public static let runtime = "FluidAudio-AP04"
    public static let compute = "cpuAndNeuralEngine"
    public static let timeout: TimeInterval = 180

    public static func permits(_ manifest: DesktopModelInstallManifest) -> Bool {
        guard ["phonon2-coreml", "phonon2-compact-coreml"].contains(manifest.modelID),
              manifest.revision == artifactRevision,
              (try? DesktopNativeSDKBindings.binding(for: manifest.modelID)) == .fluidAudio else { return false }
        return true
    }
}

/// Narrow installation seam for the bounded worker.  Production always uses
/// `DesktopModelInstaller`; the seam exists solely to exercise cancellation at
/// the two installer awaits without weakening manifest validation.
protocol DesktopWorkerInstallation: Sendable {
    func validateInstalled(_ manifest: DesktopModelInstallManifest) async throws
    func destination(for manifest: DesktopModelInstallManifest) async -> URL
}

extension DesktopModelInstaller: DesktopWorkerInstallation {}

/// Test-only synchronization seam for the actual interactive reader. It is
/// absent from the public configuration and cannot be enabled by product code.
final class DesktopWorkerReaderGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func blockBeforeLineConsumption() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval = 2) -> Bool {
        condition.lock(); defer { condition.unlock() }
        if entered { return true }
        return condition.wait(until: Date().addingTimeInterval(timeout)) && entered
    }

    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

enum DesktopWorkerTermination: Equatable, Sendable {
    case alreadyExited
    case terminated
    case forced
    case unknown

    var reaped: Bool { self != .unknown }
}

private enum DesktopWorkerLineRead: Sendable {
    case line(String)
    case deadline
    case closed
}

private enum DesktopWorkerReadyResult: Sendable, Equatable {
    case ready
    case deadline
    case outputClosed
    case unexpectedReadyMessage

    var failure: DesktopNativeReadyFailure? {
        switch self {
        case .ready: nil
        case .deadline: .deadline
        case .outputClosed: .outputClosed
        case .unexpectedReadyMessage: .unexpectedReadyMessage
        }
    }
}

private extension DesktopNativeFailureStage {
    init?(workerStage: String?) {
        guard let workerStage else { return nil }
        switch workerStage {
        case "fluid_prepare_started": self = .fluidPrepareStarted
        case "fluid_models_loaded": self = .fluidModelsLoaded
        case "fluid_manager_created": self = .fluidManagerCreated
        case "runner_init", "prepare", "startup_failed": self = .workerStartup
        case let stage where stage.hasPrefix("fluid_"): self = .fluidSDKPhase
        default: return nil
        }
    }
}

/// A native adapter with a hard cancellation boundary. `cancelAndReap` returns
/// `true` only after the child has exited; a timeout escalates from SIGTERM to
/// SIGKILL. A `false` outcome quarantines this adapter and it cannot create a
/// replacement worker. It does not own the input audio file and therefore
/// cannot alter AP02's WAV ownership or unknown-reap cleanup rules.
public actor DesktopBoundedWorkerModel: DesktopNativeModel {
    private let configuration: DesktopNativeWorkerConfiguration
    private let installer: any DesktopWorkerInstallation
    private let readerGate: DesktopWorkerReaderGate?
    private let beforeReapForTesting: (@Sendable () async -> Bool?)?
    private var reapingWorker: DesktopInteractiveWorkerProcess?
    private var reapTask: Task<Bool, Never>?
    private(set) var reapParticipantsForTesting = 0
    private var residentWorker: DesktopInteractiveWorkerProcess?
    private var startingWorker: DesktopInteractiveWorkerProcess?
    private var lastWorkerStage: String?
    private var reapUnconfirmed = false
    /// This exists before installer validation.  Cancellation must be able to
    /// invalidate an attempt which has not yet created a Process.
    private var preparingAttempt: UInt64?
    /// A reaping attempt is an admission barrier, not merely a later state
    /// update.  No replacement prepare may begin until it has a confirmed
    /// outcome (or the model is quarantined).
    private var reaping = false
    /// Changes before every new start and cancellation/unload. A READY line
    /// from an invalidated child must never publish a resident model.
    private var workerEpoch: UInt64 = 0
    private var lastNativeFailureDiagnostic: DesktopNativeFailureDiagnostic?

    public init(configuration: DesktopNativeWorkerConfiguration) {
        self.configuration = configuration
        self.installer = DesktopModelInstaller(root: configuration.installerRoot)
        self.readerGate = nil
        self.beforeReapForTesting = nil
    }

    init(configuration: DesktopNativeWorkerConfiguration, installer: any DesktopWorkerInstallation, readerGate: DesktopWorkerReaderGate? = nil, beforeReapForTesting: (@Sendable () async -> Bool?)? = nil) {
        self.configuration = configuration
        self.installer = installer
        self.readerGate = readerGate
        self.beforeReapForTesting = beforeReapForTesting
    }

    public func prepare() async throws {
        try await prepare(with: configuration.prepareTimeout)
    }

    public func prepare(for purpose: DesktopRuntimePreparePurpose) async throws {
        switch purpose {
        case .interactive:
            try await prepare(with: configuration.prepareTimeout)
        case .phononFirstPrepare:
            guard DesktopPhononFirstPrepareContract.permits(configuration.modelManifest) else {
                throw DesktopRuntimeError.unavailable
            }
            try await prepare(with: DesktopPhononFirstPrepareContract.timeout)
        }
    }

    private func prepare(with timeout: TimeInterval) async throws {
        guard !reapUnconfirmed else { throw DesktopRuntimeError.reapUnconfirmed }
        guard !reaping else { throw DesktopRuntimeError.unavailable }
        guard residentWorker == nil else { PerfLog.current?.mark(.workerSpawned, newWorker: false); return }
        workerEpoch &+= 1
        let attempt = workerEpoch
        preparingAttempt = attempt
        try await installer.validateInstalled(configuration.modelManifest)
        guard preparingAttempt == attempt, workerEpoch == attempt, !reaping else { throw DesktopRuntimeError.cancelled }
        guard residentWorker == nil else {
            if preparingAttempt == attempt { preparingAttempt = nil }
            return
        }
        let directory = await installer.destination(for: configuration.modelManifest)
        guard preparingAttempt == attempt, workerEpoch == attempt, !reaping else { throw DesktopRuntimeError.cancelled }
        let worker = try DesktopInteractiveWorkerProcess(
            executableURL: configuration.executableURL,
            modelID: configuration.modelManifest.modelID,
            modelDirectory: directory,
            readerGate: readerGate
        )
        startingWorker = worker
        guard preparingAttempt == attempt, workerEpoch == attempt, !reaping else {
            guard await reap(worker) else { throw DesktopRuntimeError.reapUnconfirmed }
            throw DesktopRuntimeError.cancelled
        }
        let ready = await worker.waitUntilReady(timeout: timeout)
        guard ready == .ready else {
            captureDiagnosticStage(from: worker)
            if startingWorker === worker && workerEpoch == attempt { preparingAttempt = nil; workerEpoch &+= 1 }
            let reaped = await reap(worker)
            captureDiagnosticStage(from: worker)
            lastNativeFailureDiagnostic = .init(stage: DesktopNativeFailureStage(workerStage: lastWorkerStage), readyFailure: ready.failure!, reap: reaped ? .confirmed : .unknown)
            guard reaped else { throw DesktopRuntimeError.reapUnconfirmed }
            throw DesktopRuntimeError.nativeFailure
        }
        guard startingWorker === worker && preparingAttempt == attempt && workerEpoch == attempt && !reaping else {
            captureDiagnosticStage(from: worker)
            guard await reap(worker) else { throw DesktopRuntimeError.reapUnconfirmed }
            captureDiagnosticStage(from: worker)
            throw DesktopRuntimeError.cancelled
        }
        startingWorker = nil
        preparingAttempt = nil
        residentWorker = worker
    }

    public func transcribe(audioFile: URL, job: DesktopRuntimeJob) async throws -> String {
        try await prepare()
        guard let residentWorker else { throw DesktopRuntimeError.nativeFailure }
        PerfLog.current?.mark(.workerSpawned, newWorker: false)
        return try await residentWorker.transcribe(audioFile: audioFile, job: job)
    }

    public func cancelAndReap(job: DesktopRuntimeJob) async -> Bool { await stopWorkers() }

    public func unload() async -> Bool { await stopWorkers() }

    private func stopWorkers() async -> Bool {
        workerEpoch &+= 1
        preparingAttempt = nil
        if let startingWorker {
            guard await reap(startingWorker) else { return false }
        }
        if let residentWorker {
            guard await reap(residentWorker) else { return false }
        }
        return !reapUnconfirmed && !reaping
    }

    /// Internal, redacted diagnostic only. It is intentionally not surfaced
    /// through product errors or UI copy; it identifies a fixed worker stage,
    /// never SDK stderr, a path, audio content or a transcript.
    func latestWorkerStage() -> String? {
        residentWorker?.latestDiagnosticStage() ?? startingWorker?.latestDiagnosticStage() ?? lastWorkerStage
    }

    public func nativeFailureDiagnostic() -> DesktopNativeFailureDiagnostic? { lastNativeFailureDiagnostic }

    public func workerIdentity() async -> UUID? { residentWorker?.identity }
    public func requiresWorkerIdentity() async -> Bool { true }

    private func captureDiagnosticStage(from worker: DesktopInteractiveWorkerProcess) {
        if let stage = worker.latestDiagnosticStage() { lastWorkerStage = stage }
    }

    // Register before suspension and retain the owner until confirmation. A
    // concurrent prepare failure, cancel or unload joins this exact receipt.
    private func reap(_ worker: DesktopInteractiveWorkerProcess) async -> Bool {
        reapParticipantsForTesting += 1
        let task: Task<Bool, Never>
        if reapingWorker === worker, let existing = reapTask {
            task = existing
        } else {
            // Normally there is only one owner. Never overlap a late old-owner
            // teardown with a different concrete worker's in-flight reap.
            guard !reaping, !reapUnconfirmed else { return false }
            reaping = true
            let beforeReap = beforeReapForTesting
            task = Task {
                let injected = await beforeReap?()
                let outcome = await worker.terminateAndReap()
                // The seam can force unknown, never manufacture confirmation.
                return outcome.reaped && injected != false
            }
            reapingWorker = worker
            reapTask = task
        }
        let confirmed = await task.value
        captureDiagnosticStage(from: worker)
        if reapingWorker === worker {
            if confirmed {
                if startingWorker === worker { startingWorker = nil }
                if residentWorker === worker { residentWorker = nil }
                reaping = false
            } else { reapUnconfirmed = true }
        }
        return confirmed
    }

}

private struct DesktopWorkerResult: Decodable {
    let jobID: String
    let generation: UInt64
    let modelID: String
    let text: String
    let status: String?
    enum CodingKeys: String, CodingKey { case jobID = "job_id", generation, modelID = "model_id", text, status }
}

/// Persistent, serial worker transport. A resident worker never reads the
/// network and keeps exactly one SDK model warm. Its only input is a local file
/// path; cancellation terminates and reaps the owning process.
private final class DesktopInteractiveWorkerProcess: @unchecked Sendable {
    let identity = UUID()
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let exitCondition = NSCondition()
    private var exited = false
    private var outputBuffer = Data()
    private let outputCondition = NSCondition()
    private var outputClosed = false
    private let diagnostics = DesktopWorkerDiagnosticStages()
    private let readerGate: DesktopWorkerReaderGate?

    init(executableURL: URL, modelID: String, modelDirectory: URL, readerGate: DesktopWorkerReaderGate? = nil) throws {
        self.readerGate = readerGate
        process.executableURL = executableURL
        process.arguments = ["--serve", "--model-id", modelID, "--model-directory", modelDirectory.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in self?.signalExit() }
        try process.run()
        PerfLog.current?.mark(.workerSpawned, newWorker: true)
        // A pipe can report EOF before its child owns the writer. Start both
        // drains only after `run()` has established that ownership.
        drainOutput(output.fileHandleForReading)
        drain(errors.fileHandleForReading)
    }

    deinit { process.terminationHandler = nil }

    func waitUntilReady(timeout: TimeInterval) async -> DesktopWorkerReadyResult {
        switch await readLine(timeout: timeout) {
        case .deadline: return .deadline
        case .closed: return .outputClosed
        case let .line(line): return line == "KLANGSCHRIFT_READY" ? .ready : .unexpectedReadyMessage
        }
    }

    func transcribe(audioFile: URL, job: DesktopRuntimeJob) async throws -> String {
        let request = WorkerRequest(jobID: job.id.uuidString, generation: job.generation, audioFile: audioFile.path, language: job.language, preferredLanguages: job.preferredLanguages, recognitionHintPrompt: job.recognitionHintPrompt)
        let encoded = try JSONEncoder().encode(request).base64EncodedString() + "\n"
        guard let bytes = encoded.data(using: .utf8) else { throw DesktopRuntimeError.nativeFailure }
        do { try input.fileHandleForWriting.write(contentsOf: bytes) }
        catch { throw DesktopRuntimeError.nativeFailure }
        while case let .line(line) = await readLine(timeout: 600) {
            guard line.hasPrefix("KLANGSCHRIFT_RESULT:"),
                  let data = Data(base64Encoded: String(line.dropFirst("KLANGSCHRIFT_RESULT:".count))),
                  let result = try? JSONDecoder().decode(DesktopWorkerResult.self, from: data) else {
                if line == "KLANGSCHRIFT_ERROR" { throw DesktopRuntimeError.nativeFailure }
                continue
            }
            guard result.jobID == job.id.uuidString, result.generation == job.generation, result.modelID == job.modelID else { throw DesktopRuntimeError.staleResult }
            if result.status == "noSpeech", result.text.isEmpty { throw DesktopRuntimeError.noSpeech }
            guard (result.status == "text" || result.status == nil), !result.text.isEmpty else { throw DesktopRuntimeError.nativeFailure }
            return result.text
        }
        throw DesktopRuntimeError.nativeFailure
    }

    func terminateAndReap() async -> DesktopWorkerTermination {
        if await waitForExit(timeout: 0) { return .alreadyExited }
        process.terminate()
        if await waitForExit(timeout: 2) { return .terminated }
        if process.processIdentifier > 0 { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        return await waitForExit(timeout: 2) ? .forced : .unknown
    }

    func latestDiagnosticStage() -> String? { diagnostics.latest() }

    private func readLine(timeout: TimeInterval) async -> DesktopWorkerLineRead {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.readLineBlocking(timeout: timeout))
            }
        }
    }

    private func readLineBlocking(timeout: TimeInterval) -> DesktopWorkerLineRead {
        let now = DispatchTime.now().uptimeNanoseconds
        let nanos = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = now > UInt64.max - nanos ? UInt64.max : now + nanos
        outputCondition.lock()
        defer { outputCondition.unlock() }
        while true {
            // Check before consuming an already-buffered line: a reader that
            // was descheduled beyond the monotonic deadline must not convert a
            // late READY into a resident worker.
            let current = DispatchTime.now().uptimeNanoseconds
            guard current < deadline else { return .deadline }
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                readerGate?.blockBeforeLineConsumption()
                // The test gate deliberately holds the actual reader after a
                // READY line is buffered. Recheck the same monotonic deadline
                // before accepting that late line.
                guard DispatchTime.now().uptimeNanoseconds < deadline else { return .deadline }
                let line = outputBuffer.prefix(upTo: newline)
                outputBuffer.removeSubrange(...newline)
                return .line(String(decoding: line, as: UTF8.self))
            }
            if outputClosed { return .closed }
            waitForOutputSignal(until: deadline)
        }
    }

    /// `availableData` may block indefinitely. Keep it in one drain task;
    /// waiting callers use the condition and enforce their own monotone clock.
    private func drainOutput(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while let self {
                let data = handle.availableData
                self.outputCondition.lock()
                if data.isEmpty { self.outputClosed = true }
                else { self.outputBuffer.append(data) }
                self.outputCondition.broadcast()
                self.outputCondition.unlock()
                if data.isEmpty { break }
            }
            try? handle.close()
        }
    }

    private func drain(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [diagnostics] in
            // `availableData` blocks until a marker is written or EOF. Unlike
            // `readDataToEndOfFile`, it makes the latest fixed stage available
            // while a still-running SDK call is being diagnosed.
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                diagnostics.record(data)
            }
            try? handle.close()
        }
    }

    private func signalExit() {
        exitCondition.lock(); exited = true; exitCondition.broadcast(); exitCondition.unlock()
        outputCondition.lock(); outputCondition.broadcast(); outputCondition.unlock()
    }
    private func waitForOutputSignal(until deadline: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.outputCondition.lock()
            self.outputCondition.broadcast()
            self.outputCondition.unlock()
        }
        timer.resume()
        outputCondition.wait()
        timer.setEventHandler {}
        timer.cancel()
    }
    private func waitForExit(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: self.waitForExitBlocking(timeout: timeout)) }
        }
    }
    private func waitForExitBlocking(timeout: TimeInterval) -> Bool {
        exitCondition.lock(); defer { exitCondition.unlock() }
        if exited { return true }
        guard timeout > 0 else { return false }
        let start = DispatchTime.now().uptimeNanoseconds
        let nanos = UInt64(timeout * 1_000_000_000)
        let deadline = start > UInt64.max - nanos ? UInt64.max : start + nanos
        while !exited {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return false }
            waitForExitSignal(until: deadline)
        }
        return true
    }

    private func waitForExitSignal(until deadline: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitCondition.lock()
            self.exitCondition.broadcast()
            self.exitCondition.unlock()
        }
        timer.resume()
        exitCondition.wait()
        timer.setEventHandler {}
        timer.cancel()
    }

    private struct WorkerRequest: Encodable {
        let jobID: String
        let generation: UInt64
        let audioFile: String
        let language: DesktopDictationLanguage
        let preferredLanguages: [String]
        let recognitionHintPrompt: String?
        enum CodingKeys: String, CodingKey { case jobID = "job_id", generation, audioFile = "audio_file", language, preferredLanguages, recognitionHintPrompt = "recognition_hint_prompt" }
    }
}

/// Bounded parser for the worker's deliberately fixed stderr markers. It
/// drops every other stderr byte, including potentially sensitive SDK output.
private final class DesktopWorkerDiagnosticStages: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: String?

    func record(_ data: Data) {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let marker = "KLANGSCHRIFT_WORKER_STAGE="
            guard line.hasPrefix(marker) else { continue }
            let candidate = String(line.dropFirst(marker.count))
            guard !candidate.isEmpty, candidate.count <= 40,
                  candidate.unicodeScalars.allSatisfy({ ($0.value >= 97 && $0.value <= 122) || $0.value == 95 }) else { continue }
            lock.lock()
            // A concrete safe SDK substage is more useful than the generic
            // catch marker emitted by the worker main loop. Preserve a family
            // boundary so a `transcribe_failed` or `startup_failed` suffix
            // cannot erase the diagnostic boundary.
            let preservesSpecificBoundary = stage?.hasPrefix("sherpa_") == true || stage?.hasPrefix("fluid_") == true
            if !((candidate == "transcribe_failed" || candidate == "startup_failed") && preservesSpecificBoundary) {
                stage = candidate
            }
            lock.unlock()
        }
    }

    func latest() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return stage
    }
}

final class DesktopWorkerProcess: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let exitCondition = NSCondition()
    private let outputGroup = DispatchGroup()
    private let dataLock = NSLock()
    private var exited = false
    private var stdout = Data()
    private var stderr = Data()

    init(executableURL: URL, modelID: String, modelDirectory: URL, audioFile: URL, job: DesktopRuntimeJob) throws {
        process.executableURL = executableURL
        process.arguments = [
            "--model-id", modelID,
            "--model-directory", modelDirectory.path,
            "--audio-file", audioFile.path,
            "--job-id", job.id.uuidString,
            "--generation", String(job.generation),
            "--language", job.language.rawValue, "--preferred-languages", job.preferredLanguages.joined(separator: ",")
        ]
        try launch()
    }

    init(executableURL: URL, arguments: [String]) throws {
        process.executableURL = executableURL
        process.arguments = arguments
        try launch()
    }

    private func launch() throws {
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [weak self] _ in self?.signalExit() }
        capture(output.fileHandleForReading, isStandardOutput: true)
        capture(errors.fileHandleForReading, isStandardOutput: false)
        try process.run()
        PerfLog.current?.mark(.workerSpawned, newWorker: true)
    }

    deinit { process.terminationHandler = nil }

    func waitForExit(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.waitForExitBlocking(timeout: timeout))
            }
        }
    }

    func terminateAndReap() async -> DesktopWorkerTermination {
        if await waitForExit(timeout: 0) { return finishOutput() ? .alreadyExited : .unknown }
        process.terminate()
        if await waitForExit(timeout: 2) { return finishOutput() ? .terminated : .unknown }
        if process.processIdentifier > 0 { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        guard await waitForExit(timeout: 2) else { return .unknown }
        return finishOutput() ? .forced : .unknown
    }

    func checkedTranscript(for job: DesktopRuntimeJob) throws -> String {
        guard process.terminationStatus == 0 else { throw DesktopRuntimeError.nativeFailure }
        let lines = String(decoding: collectedOutput().stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard let resultLine = lines.last(where: { $0.hasPrefix("KLANGSCHRIFT_RESULT:") }),
              let data = Data(base64Encoded: String(resultLine.dropFirst("KLANGSCHRIFT_RESULT:".count))),
              let result = try? JSONDecoder().decode(DesktopWorkerResult.self, from: data),
              result.jobID == job.id.uuidString, result.generation == job.generation,
              result.modelID == job.modelID else { throw DesktopRuntimeError.nativeFailure }
        if result.status == "noSpeech", result.text.isEmpty { throw DesktopRuntimeError.noSpeech }
        guard (result.status == "text" || result.status == nil), !result.text.isEmpty else { throw DesktopRuntimeError.nativeFailure }
        return result.text
    }

    private func signalExit() {
        exitCondition.lock()
        exited = true
        exitCondition.broadcast()
        exitCondition.unlock()
    }

    private func waitForExitBlocking(timeout: TimeInterval) -> Bool {
        exitCondition.lock()
        defer { exitCondition.unlock() }
        if exited { return true }
        guard timeout > 0 else { return false }
        return exitCondition.wait(until: Date().addingTimeInterval(timeout)) || exited
    }

    private func capture(_ handle: FileHandle, isStandardOutput: Bool) {
        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.outputGroup.leave() }
            let data = handle.readDataToEndOfFile()
            self?.dataLock.lock()
            if isStandardOutput {
                self?.stdout = data
            } else {
                self?.stderr = data
            }
            self?.dataLock.unlock()
            try? handle.close()
        }
    }

    private func finishOutput() -> Bool {
        outputGroup.wait(timeout: .now() + 2) == .success
    }

    private func collectedOutput() -> (stdout: Data, stderr: Data) {
        dataLock.lock()
        defer { dataLock.unlock() }
        return (stdout, stderr)
    }

}
