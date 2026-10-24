import Foundation
import FluidAudio
import SherpaOnnxC

/// All native access is serialized on a dedicated worker and the app-wide FIFO gate.
final class SherpaLocalTranscriber: @unchecked Sendable {
    private let worker = DispatchQueue(label: "Klangschrift.Sherpa", qos: .userInitiated)
    private let directory: URL
    private let modelID: DictationModelID
    private var recognizer: OpaquePointer?
    private var verified = false
    init(modelID: DictationModelID, resourceRoot: URL?) {
        self.modelID = modelID
        directory = resourceRoot.map { $0.appendingPathComponent(DictationModelDescriptor.descriptor(for: modelID).bundleDirectory) } ?? DictationModelStorage.directory(for: modelID)
    }
    deinit { if let recognizer { SherpaOnnxDestroyOnlineRecognizer(recognizer) } }
    func prepare(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        try await execute { _ = try self.load(operationID: operationID, permit: permit, observer: observer) }
    }
    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String {
        try await execute {
            let recognizer = try self.load(operationID: operationID, observer: observer)
            let samples = try runTranscriptionStage(operationID: operationID, modelID: self.modelID, stage: .audioLoad, observer: observer) {
                let samples = try AudioConverter(sampleRate: 16_000).resampleAudioFile(recording)
                guard !samples.isEmpty else { throw LocalTranscriberError.emptyAudio }
                return samples
            }
            return try runTranscriptionStage(operationID: operationID, modelID: self.modelID, stage: .generate, observer: observer) {
                guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else { throw LocalTranscriberError.modelMissing }
                defer { SherpaOnnxDestroyOnlineStream(stream) }
                samples.withUnsafeBufferPointer { buffer in
                    for start in stride(from: 0, to: samples.count, by: 3_200) {
                        let count = min(3_200, samples.count - start)
                        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, buffer.baseAddress!.advanced(by: start), Int32(count))
                        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
                    }
                }
                // Native streaming decoder needs finite silence to flush its final features.
                let tail = [Float](repeating: 0, count: 8_000)
                tail.withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, $0.baseAddress!, Int32($0.count)) }
                SherpaOnnxOnlineStreamInputFinished(stream)
                while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 { SherpaOnnxDecodeOnlineStream(recognizer, stream) }
                guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { throw LocalTranscriberError.noSpeech }
                defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
                guard let text = result.pointee.text else { throw LocalTranscriberError.noSpeech }
                return try validatedTranscriptionText(String(cString: text))
            }
        }
    }
    private func load(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) throws -> OpaquePointer {
        try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .verify, cacheHit: verified, observer: observer) {
            try permit?.check()
            if !verified { try DictationModelManifest.validate(modelID, directory: directory); verified = true }
        }
        return try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .modelLoad, cacheHit: recognizer != nil, observer: observer) {
            if let recognizer { return recognizer }
            try permit?.check()
            let values = ["encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.int8.onnx", "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt"].map { directory.appendingPathComponent($0).path } + ["cpu", "greedy_search"]
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
            guard let loaded = SherpaOnnxCreateOnlineRecognizer(&config) else { throw LocalTranscriberError.modelMissing }
            recognizer = loaded
            return loaded
        }
    }
    private func execute<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result { try body() }) }
        }
        try Task.checkCancellation()
        return value
    }
}
