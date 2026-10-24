import CryptoKit
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import FluidAudio

enum LocalTranscriberError: LocalizedError { case modelMissing, emptyAudio, noSpeech; var errorDescription: String? { switch self { case .modelMissing: "Das lokale Sprachmodell fehlt oder ist beschädigt."; case .emptyAudio: "Die Aufnahme enthält keinen verwertbaren Ton."; case .noSpeech: "Keine Sprache erkannt." } } }

public enum LocalTranscriptionStage: String, Sendable { case verify, audioLoad = "audio_load", modelLoad = "model_load", generate }
public enum LocalTranscriptionStageOutcome: String, Sendable { case started, completed, failed }
public struct LocalTranscriptionStageEvent: Sendable {
    public let operationID: UUID
    public let modelID: DictationModelID
    public let stage: LocalTranscriptionStage
    public let outcome: LocalTranscriptionStageOutcome
    public let durationMS: UInt64?
    public let errorCode: String?
    public let cacheHit: Bool
    public init(operationID: UUID, modelID: DictationModelID = .phonon2CoreML, stage: LocalTranscriptionStage, outcome: LocalTranscriptionStageOutcome, durationMS: UInt64?, errorCode: String?, cacheHit: Bool) {
        self.operationID = operationID; self.modelID = modelID; self.stage = stage; self.outcome = outcome
        self.durationMS = durationMS; self.errorCode = errorCode; self.cacheHit = cacheHit
    }
}

func runTranscriptionStage<T>(operationID: UUID, modelID: DictationModelID = .phonon2CoreML, stage: LocalTranscriptionStage, cacheHit: Bool = false, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)? = nil, _ body: () throws -> T) throws -> T {
    observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .started, durationMS: nil, errorCode: nil, cacheHit: cacheHit))
    let start = DispatchTime.now().uptimeNanoseconds
    do {
        let value = try body()
        observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .completed, durationMS: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, errorCode: nil, cacheHit: cacheHit))
        return value
    } catch {
        let code: String
        switch error {
        case LocalTranscriberError.modelMissing: code = "model_missing"
        case LocalTranscriberError.emptyAudio: code = "empty_audio"
        case LocalTranscriberError.noSpeech: code = "no_speech"
        default: code = "runtime_failure"
        }
        observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .failed, durationMS: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, errorCode: code, cacheHit: cacheHit))
        throw error
    }
}

public final class LocalTranscriber {
    public static let maximumRecordingSeconds: TimeInterval = RecordingPolicy.maximumSeconds
    public static let inferenceChunkSeconds: TimeInterval = 30
    private let modelDirectory: URL
    private var model: ParakeetModel?
    private var verified = false
    public init(modelDirectory: URL) { self.modelDirectory = modelDirectory }
    public func transcribe(recording: URL, operationID: UUID = UUID(), observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)? = nil) throws -> String {
        try runTranscriptionStage(operationID: operationID, stage: .verify, cacheHit: verified, observer: observer) { try verifyManifestOnce() }
        do {
            // Swift tasks can inherit their own default stream; pin the actual
            // model/audio operations to CPU even when called from a background actor.
            return try Device.withDefaultDevice(.cpu) {
                try withError { error in
                    let (_, audio) = try runTranscriptionStage(operationID: operationID, stage: .audioLoad, observer: observer) {
                        let audio = try loadAudioArray(from: recording, sampleRate: 16_000)
                        try error.check()
                        guard audio.1.size > 0 else { throw LocalTranscriberError.emptyAudio }
                        return audio
                    }
                    let loaded = try runTranscriptionStage(operationID: operationID, stage: .modelLoad, cacheHit: model != nil, observer: observer) {
                        let loaded = try loadModel()
                        try error.check()
                        return loaded
                    }
                    return try runTranscriptionStage(operationID: operationID, stage: .generate, observer: observer) {
                        let output = loaded.generate(audio: audio, generationParameters: STTGenerateParameters(chunkDuration: Float(Self.inferenceChunkSeconds)))
                        try error.check()
                        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw LocalTranscriberError.noSpeech }
                        return text
                    }
                }
            }
        } catch {
            model = nil // A failed MLX evaluation must not leave a partial cached model.
            throw error
        }
    }
    // CPU BF16 Q4 multiplication is substantially slower on the tested Mac.
    // Float32 changes floating parameters/activations; packed Q4 weights stay packed.
    private func loadModel() throws -> ParakeetModel { if let model { return model }; let loaded = try ParakeetModel.fromDirectory(modelDirectory, computeDType: .float32); model = loaded; return loaded }
    private func verifyManifestOnce() throws {
        guard !verified else { return }
        struct Manifest: Decodable { let model_id, revision, model_sha256, config_sha256: String; let model_bytes, config_bytes: Int }
        let modelURL = modelDirectory.appendingPathComponent("model.safetensors"), configURL = modelDirectory.appendingPathComponent("config.json")
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json"))), manifest.model_id == "animaslabs/parakeet-tdt-0.6b-v3-mlx-4bit", manifest.revision == "65247a0a9e735426eba06056a9535f7e67dcbbb9", manifest.model_sha256 == "db98d5e6f4b1ca1d830825f6b79543cbfe0074e65da6fa9262498f603c3c01e6", manifest.config_sha256 == "b3d8d187357db42e32bd8bd50840c7d028cdd4d29841d63400af482f5095f4b0", (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == manifest.model_bytes, (try? configURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) == manifest.config_bytes else { throw LocalTranscriberError.modelMissing }
        func hex(_ url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var digest = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { digest.update(data: chunk) }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard try hex(modelURL) == manifest.model_sha256, try hex(configURL) == manifest.config_sha256 else { throw LocalTranscriberError.modelMissing }
        verified = true
    }
}
/// MLX's synchronous native evaluation runs on a dedicated serial worker,
/// rather than blocking Swift's cooperative actor executor. All model access
/// is confined to that worker; cancelled callers discard late results.
/// One serial service is shared by the app and keyboard host. A job receives its
/// selected model ID before any asynchronous work begins; changing Settings therefore
/// affects only the following dictation. At most one compiled CoreML model stays live.
actor ModelJobGate {
    private var jobInProgress = false
    private var waitingJobs: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !jobInProgress {
            jobInProgress = true
            return
        }
        await withCheckedContinuation { continuation in waitingJobs.append(continuation) }
    }

    func release() {
        if waitingJobs.isEmpty {
            jobInProgress = false
        } else {
            waitingJobs.removeFirst().resume()
        }
    }
}

public actor LocalTranscriptionService {
    private struct Entry { let identity = UUID(); let provider: any LocalResidentProvider; var prepared = false; var inferences: UInt64 = 0; var autoPermit: ModelLoadPermit? }
    private var activeDemands: [UUID: DictationModelID] = [:]
    private var residents: [DictationModelID: Entry] = [:]
    private var recent: [DictationModelID] = []
    private var activeModelID: DictationModelID?
    private var pins: [UUID: DictationModelID] = [:]
    private let measurementSink: (@Sendable (DictationModelID, ModelLoadSample) -> Void)?
    private let testFactory: (@Sendable (DictationModelID) -> any LocalResidentProvider)?
    private let jobGate = ModelJobGate()
    /// Test/CLI-only fixed asset root. Product callers leave this nil and resolve
    /// exclusively from the signed application bundle.
    private let resourceRoot: URL?

    public init(resourceRoot: URL? = nil) {
        self.resourceRoot = resourceRoot
        self.testFactory = nil
        self.measurementSink = nil
        ModelHub.offlineMode = true
    }

    /// Bounded internal injection for cache/gate tests; product callers cannot supply providers.
    init(factory: @escaping @Sendable (DictationModelID) -> any LocalResidentProvider, measurements: (@Sendable (DictationModelID, ModelLoadSample) -> Void)? = nil) {
        resourceRoot = nil; testFactory = factory; measurementSink = measurements
    }

    public func preparedModels() -> Set<DictationModelID> { Set(residents.filter { $0.value.prepared }.map(\.key)) }
    public func residentModels() -> Set<DictationModelID> { Set(residents.keys) }
    func pendingDemandModels() -> Set<DictationModelID> { Set(activeDemands.values) }

    /// Storage maintenance may evict only a fully idle cache. Callers must not
    /// remove model or cache files while a resident is demanded, pinned, or active.
    public func releaseResidentsForStorageMaintenance() -> Bool {
        guard activeModelID == nil, activeDemands.isEmpty, pins.isEmpty else { return false }
        residents.removeAll(); recent.removeAll()
        return true
    }

    /// Actor reentrancy may deliver this during an awaited job. Its provider is pinned.
    public func handleMemoryPressure() {
        for id in Array(residents.keys) where id != activeModelID && !pins.values.contains(id) && !activeDemands.values.contains(id) && residents[id]?.autoPermit?.hasDemand(for: id) != true { residents[id] = nil; recent.removeAll { $0 == id } }
    }

    /// Warm microphone sessions may only reuse an already loaded provider.
    public func requirePrepared(modelID: DictationModelID, pin: UUID? = nil) async throws {
        let demand = UUID(); activeDemands[demand] = modelID
        defer { activeDemands[demand] = nil; discardInvalidAutomaticResidents() }
        await jobGate.acquire()
        defer { Task { await jobGate.release() } }
        try Task.checkCancellation()
        guard residents[modelID]?.prepared == true else { throw LocalTranscriberError.modelMissing }
        residents[modelID]?.autoPermit = nil
        if let pin { pins[pin] = modelID }
    }

    public func releasePin(_ token: UUID) { pins[token] = nil; discardInvalidAutomaticResidents() }
    public func discardInvalidAutomaticResidents() {
        for (id, entry) in residents {
            guard let permit = entry.autoPermit, !permit.isValid, !permit.hasDemand(for: id),
                  id != activeModelID, !pins.values.contains(id), !activeDemands.values.contains(id) else { continue }
            residents[id] = nil; recent.removeAll { $0 == id }
        }
    }

    public func transcribe(recording: URL, modelID: DictationModelID = DictationModelSelection.selected(), operationID: UUID = UUID(), origin: ModelLoadOrigin = .mainDictation, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)? = nil) async throws -> String {
        let demand = UUID(); activeDemands[demand] = modelID
        defer { activeDemands[demand] = nil; discardInvalidAutomaticResidents() }
        let start = DispatchTime.now().uptimeNanoseconds
        await jobGate.acquire()
        let queueMS = elapsedMS(start)
        defer { Task { await jobGate.release() } }
        let measurements = JobMeasurements()
        var outcome: ModelOperationOutcome = .failed
        var identity: UUID?
        let ordinal = (residents[modelID]?.inferences ?? 0) + 1
        defer {
            if measurements.generateAttempted, residents[modelID]?.identity == identity { residents[modelID]?.inferences = ordinal }
            let sample = measurements.sample(origin: origin, outcome: outcome, inference: true, queueMS: queueMS, fullMS: elapsedMS(start), ordinal: ordinal)
            measurementSink?(modelID, sample)
            if resourceRoot == nil && testFactory == nil { ModelLoadMetricsStore.record(modelID, sample: sample) }
        }
        do {
            try Task.checkCancellation()
            let resident = try useResident(modelID: modelID)
            identity = residents[modelID]?.identity
            activeModelID = modelID
            defer { activeModelID = nil }
            let text = try await resident.transcribe(recording: recording, operationID: operationID) { event in measurements.observe(event); observer?(event) }
            try Task.checkCancellation()
            residents[modelID]?.prepared = true
            outcome = .completed
            if resourceRoot == nil && testFactory == nil { measurements.save(model: modelID, recording: recording, totalMS: elapsedMS(start)) }
            return text
        } catch { outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failed; throw error }
    }

    /// Local only. An invalidated speculative consumer never erases a resident claimed by demand.
    public func prepare(modelID: DictationModelID, operationID: UUID = UUID(), origin: ModelLoadOrigin = .manual, permit: ModelLoadPermit? = nil, preserving: Set<DictationModelID> = [], observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)? = nil) async throws {
        let demand = UUID()
        if origin != .automatic { activeDemands[demand] = modelID }
        defer { activeDemands[demand] = nil; discardInvalidAutomaticResidents() }
        let start = DispatchTime.now().uptimeNanoseconds
        await jobGate.acquire()
        let queueMS = elapsedMS(start)
        defer { Task { await jobGate.release() } }
        let measurements = JobMeasurements()
        var outcome: ModelOperationOutcome = .failed
        var identity: UUID?
        defer {
            if origin == .automatic, permit?.isValid == false, let identity,
               residents[modelID]?.identity == identity, residents[modelID]?.autoPermit === permit,
               !pins.values.contains(modelID), !activeDemands.values.contains(modelID), !permit!.hasDemand(for: modelID) {
                residents[modelID] = nil; recent.removeAll { $0 == modelID }
            }
            let sample = measurements.sample(origin: origin, outcome: outcome, inference: false, queueMS: queueMS, fullMS: elapsedMS(start), ordinal: 0)
            measurementSink?(modelID, sample)
            if resourceRoot == nil && testFactory == nil { ModelLoadMetricsStore.record(modelID, sample: sample) }
        }
        do {
            try Task.checkCancellation(); try permit?.check()
            let resident = try useResident(modelID: modelID, preserving: origin == .automatic ? preserving : [], automaticPermit: origin == .automatic ? permit : nil)
            identity = residents[modelID]?.identity
            activeModelID = modelID
            defer { activeModelID = nil }
            try await resident.prepare(operationID: operationID, permit: permit) { event in measurements.observe(event); observer?(event) }
            // The SDK returned successfully. Publish the truth before checking consumer intent.
            residents[modelID]?.prepared = true
            if resourceRoot == nil && testFactory == nil { measurements.savePreparation(model: modelID) }
            try permit?.check(); try Task.checkCancellation()
            residents[modelID]?.autoPermit = nil
            outcome = .completed
        } catch { outcome = error is CancellationError || Task.isCancelled ? .cancelled : .failed; throw error }
    }

    private func elapsedMS(_ start: UInt64) -> UInt64 { (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    private func useResident(modelID: DictationModelID, preserving: Set<DictationModelID> = [], automaticPermit: ModelLoadPermit? = nil) throws -> any LocalResidentProvider {
        recent.removeAll { $0 == modelID }; recent.append(modelID)
        if let entry = residents[modelID] { if automaticPermit == nil { residents[modelID]?.autoPermit = nil }; return entry.provider }
        if residents.count >= 2, let victim = recent.first(where: { residents[$0] != nil && $0 != activeModelID && !pins.values.contains($0) && (!preserving.contains($0) || residents[$0]?.prepared != true) }) {
            residents[victim] = nil; recent.removeAll { $0 == victim }
        }
        guard residents.count < 2 else { throw LocalTranscriberError.modelMissing }
        let provider: any LocalResidentProvider
        if let testFactory { provider = testFactory(modelID) }
        else {
            switch modelID {
            case .phonon2CoreML, .parakeetV3CoreML, .parakeetReduxCoreML, .phonon2CompactCoreML: provider = ResidentProvider.coreML(CoreMLLocalTranscriber(modelID: modelID, resourceRoot: resourceRoot))
            case .whisperTinyCoreML, .whisperTinyENCoreML, .whisperBaseCoreML, .whisperBaseENCoreML: provider = ResidentProvider.whisper(WhisperLocalTranscriber(modelID: modelID, resourceRoot: resourceRoot))
            case .sherpaZipformerEN: provider = ResidentProvider.sherpa(SherpaLocalTranscriber(modelID: modelID, resourceRoot: resourceRoot))
            default: provider = ResidentProvider.moonshine(MoonshineLocalTranscriber(modelID: modelID, resourceRoot: resourceRoot))
            }
        }
        residents[modelID] = Entry(provider: provider, autoPermit: automaticPermit)
        return provider
    }

}

protocol LocalResidentProvider: Sendable {
    func prepare(operationID: UUID, permit: ModelLoadPermit?, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws
    func prepare(operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws
    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String
}

extension LocalResidentProvider {
    func prepare(operationID: UUID, permit: ModelLoadPermit?, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        try permit?.check(); try await prepare(operationID: operationID, observer: observer)
    }
}

private enum ResidentProvider: LocalResidentProvider {
    case coreML(CoreMLLocalTranscriber), moonshine(MoonshineLocalTranscriber), whisper(WhisperLocalTranscriber), sherpa(SherpaLocalTranscriber)
    func prepare(operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        try await prepare(operationID: operationID, permit: nil, observer: observer)
    }
    func prepare(operationID: UUID, permit: ModelLoadPermit?, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        switch self {
        case .coreML(let provider): _ = try await provider.prepare(operationID: operationID, permit: permit, observer: observer)
        case .moonshine(let provider): try await provider.prepare(operationID: operationID, permit: permit, observer: observer)
        case .whisper(let provider): try await provider.prepare(operationID: operationID, permit: permit, observer: observer)
        case .sherpa(let provider): try await provider.prepare(operationID: operationID, permit: permit, observer: observer)
        }
    }
    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String {
        switch self {
        case .coreML(let provider): return try await provider.transcribe(recording: recording, operationID: operationID, observer: observer)
        case .moonshine(let provider): return try await provider.transcribe(recording: recording, operationID: operationID, observer: observer)
        case .whisper(let provider): return try await provider.transcribe(recording: recording, operationID: operationID, observer: observer)
        case .sherpa(let provider): return try await provider.transcribe(recording: recording, operationID: operationID, observer: observer)
        }
    }
}

private actor CoreMLLocalTranscriber {
    private let modelID: DictationModelID
    private let directory: URL
    private var manager: AsrManager?
    private var verified = false

    init(modelID: DictationModelID, resourceRoot: URL? = nil) {
        self.modelID = modelID
        let name = DictationModelDescriptor.descriptor(for: modelID).bundleDirectory
        self.directory = resourceRoot.map { $0.appendingPathComponent(name, isDirectory: true) } ?? DictationModelStorage.directory(for: modelID)
    }

    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String {
        let currentManager = try await prepare(operationID: operationID, observer: observer)
        return try await runAsyncTranscriptionStage(operationID: operationID, modelID: modelID, stage: .generate, observer: observer) {
            let layers = await currentManager.decoderLayerCount
            var state = TdtDecoderState.make(decoderLayers: layers)
            let result = try await currentManager.transcribe(recording, decoderState: &state)
            return try validatedTranscriptionText(result.text)
        }
    }

    func prepare(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> AsrManager {
        try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .verify, cacheHit: verified, observer: observer) {
            try permit?.check()
            guard !verified else { return }
            try DictationModelManifest.validate(modelID, directory: directory)
            verified = true
        }
        let currentManager: AsrManager
        if let manager {
            currentManager = manager
            observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: .modelLoad, outcome: .started, durationMS: nil, errorCode: nil, cacheHit: true))
            observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: .modelLoad, outcome: .completed, durationMS: 0, errorCode: nil, cacheHit: true))
        } else {
            currentManager = try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .modelLoad, observer: observer) {
                try permit?.check()
                let models = try AsrModels.loadLocal(from: directory, version: try CoreMLModelProfile.version(for: modelID), encoderComputeUnits: .cpuAndNeuralEngine)
                let loaded = AsrManager(models: models)
                manager = loaded
                return loaded
            }
        }
        return currentManager
    }

}

func runAsyncTranscriptionStage<T: Sendable>(operationID: UUID, modelID: DictationModelID, stage: LocalTranscriptionStage, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?, body: @Sendable () async throws -> T) async throws -> T {
        observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .started, durationMS: nil, errorCode: nil, cacheHit: false))
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            let value = try await body()
            observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .completed, durationMS: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, errorCode: nil, cacheHit: false))
            return value
        } catch {
            observer?(LocalTranscriptionStageEvent(operationID: operationID, modelID: modelID, stage: stage, outcome: .failed, durationMS: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, errorCode: transcriptionErrorCode(error), cacheHit: false))
            throw error
        }
    }

func validatedTranscriptionText(_ output: String) throws -> String {
    let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw LocalTranscriberError.noSpeech }
    return text
}

func transcriptionErrorCode(_ error: Error) -> String {
    switch error {
    case LocalTranscriberError.modelMissing: return "model_missing"
    case LocalTranscriberError.emptyAudio: return "empty_audio"
    case LocalTranscriberError.noSpeech: return "no_speech"
    default: return "runtime_failure"
    }
}


enum CoreMLModelProfile {
    static func version(for id: DictationModelID) throws -> AsrModelVersion {
        switch id {
        case .phonon2CoreML, .phonon2CompactCoreML: return .phonon2
        case .parakeetV3CoreML: return .v3
        case .parakeetReduxCoreML: return .redux
        default: throw LocalTranscriberError.modelMissing
        }
    }
}
