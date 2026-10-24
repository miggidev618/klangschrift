import AVFoundation
import Foundation
import MoonshineVoice
import FluidAudio

/// Native state is confined to this private serial worker. Inference never runs on MainActor.
final class MoonshineLocalTranscriber: @unchecked Sendable {
    private let worker = DispatchQueue(label: "Klangschrift.Moonshine", qos: .userInitiated)
    private let directory: URL
    private let modelID: DictationModelID
    private var model: Transcriber?
    private var verified = false
    init(modelID: DictationModelID, resourceRoot: URL?) {
        self.modelID = modelID
        directory = resourceRoot.map { $0.appendingPathComponent(DictationModelDescriptor.descriptor(for: modelID).bundleDirectory) } ?? DictationModelStorage.directory(for: modelID)
    }
    func prepare(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws {
        try await execute { _ = try self.load(operationID: operationID, permit: permit, observer: observer); return () }
    }
    func transcribe(recording: URL, operationID: UUID, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) async throws -> String {
        try await execute {
            let current = try self.load(operationID: operationID, observer: observer)
            let samples = try runTranscriptionStage(operationID: operationID, modelID: self.modelID, stage: .audioLoad, observer: observer) {
                let samples = try RecordingAudioResampler.samples(from: recording)
                guard !samples.isEmpty else { throw LocalTranscriberError.emptyAudio }
                return samples
            }
            return try runTranscriptionStage(operationID: operationID, modelID: self.modelID, stage: .generate, observer: observer) {
                let result = try current.transcribeWithoutStreaming(audioData: samples, sampleRate: 16_000, flags: 0)
                let text = DictationTextSpacing.join(result.lines.map(\.text))
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalTranscriberError.noSpeech }
                return text
            }
        }
    }
    private func load(operationID: UUID, permit: ModelLoadPermit? = nil, observer: (@Sendable (LocalTranscriptionStageEvent) -> Void)?) throws -> Transcriber {
        try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .verify, cacheHit: verified, observer: observer) {
            try permit?.check()
            if !verified { try DictationModelManifest.validate(modelID, directory: directory); verified = true }
        }
        return try runTranscriptionStage(operationID: operationID, modelID: modelID, stage: .modelLoad, cacheHit: model != nil, observer: observer) {
            if let model { return model }
            try permit?.check()
            let loaded = try Transcriber(modelPath: directory.path, modelArch: try MoonshineModelProfile.architecture(for: modelID), options: MoonshineModelProfile.options(for: modelID))
            model = loaded; return loaded
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


enum MoonshineModelProfile {
    static func architecture(for id: DictationModelID) throws -> ModelArch {
        switch id {
        case .moonshineTinyStreamingDE, .moonshineTinyStreamingEN, .moonshineTinyStreamingAR, .moonshineTinyStreamingJA, .moonshineTinyStreamingZH, .moonshineTinyStreamingES, .moonshineTinyStreamingTL, .moonshineTinyStreamingVI: return .tinyStreaming
        case .moonshineSmallStreamingDE, .moonshineSmallStreamingEN, .moonshineSmallStreamingJA, .moonshineSmallStreamingES: return .smallStreaming
        case .moonshineMediumStreamingEN: return .mediumStreaming
        default: throw LocalTranscriberError.modelMissing
        }
    }
    static func options(for id: DictationModelID) -> [TranscriberOption] {
        var options = [TranscriberOption(name: "ort_providers", value: "CPU")]
        switch id {
        case .moonshineTinyStreamingAR, .moonshineTinyStreamingJA, .moonshineSmallStreamingJA, .moonshineTinyStreamingZH:
            options.append(.init(name: "max_tokens_per_second", value: "13.0"))
        default: break
        }
        return options
    }
}

/// Reads bounded input buffers through one converter, retaining its filter state across reads.
/// Only the final 16-kHz mono array is retained for the native model APIs.
enum RecordingAudioResampler {
    static func samples(from url: URL, chunkFrames: AVAudioFrameCount = 4096) throws -> [Float] {
        guard chunkFrames > 0 else { throw AudioConverterError.failedToCreateBuffer }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioConverterError.failedToCreateBuffer
        }
        var result: [Float] = []
        result.reserveCapacity(Int(ceil(Double(file.length) * 16_000 / format.sampleRate)))
        if format.sampleRate == 16_000 && format.channelCount == 1 {
            while file.framePosition < file.length {
                try Task.checkCancellation()
                try file.read(into: input, frameCount: min(chunkFrames, AVAudioFrameCount(min(Int64(chunkFrames), file.length - file.framePosition))))
                guard input.frameLength > 0 else { break }
                result.append(contentsOf: UnsafeBufferPointer(start: input.floatChannelData![0], count: Int(input.frameLength)))
            }
            return result
        }
        guard let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else {
            throw AudioConverterError.failedToCreateConverter
        }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        let source = Input(file: file, buffer: input)
        while true {
            try Task.checkCancellation()
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                source.read(requested: requested, status: status)
            }
            if let error = source.error { throw error }
            guard status != .error else { throw AudioConverterError.conversionFailed(error) }
            result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if status == .endOfStream { return result }
            guard output.frameLength > 0 else { throw AudioConverterError.conversionFailed(error) }
        }
    }

    /// AVAudioConverter calls its input block synchronously on the conversion worker.
    private final class Input: @unchecked Sendable {
        let file: AVAudioFile
        let buffer: AVAudioPCMBuffer
        var error: Error?
        init(file: AVAudioFile, buffer: AVAudioPCMBuffer) { self.file = file; self.buffer = buffer }
        func read(requested: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard error == nil, file.framePosition < file.length else { status.pointee = .endOfStream; return nil }
            do {
                let count = min(buffer.frameCapacity, requested)
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { status.pointee = .endOfStream; return nil }
                status.pointee = .haveData
                return buffer
            } catch {
                self.error = error; status.pointee = .endOfStream; return nil
            }
        }
    }
}
