import AVFoundation
import Foundation

enum AudioRecorderError: LocalizedError {
    case microphoneDenied, alreadyRecording, noRecording, noAudioCaptured, invalidInputFormat, recordingTooLong, interrupted, writeFailed
    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Mikrofonzugriff wurde nicht erlaubt."
        case .alreadyRecording: "Eine Aufnahme läuft bereits."
        case .noRecording: "Es läuft keine Aufnahme."
        case .noAudioCaptured: "Es wurde kein Ton aufgenommen. Bitte Mikrofon und Eingabe prüfen."
        case .invalidInputFormat: "Das Mikrofon liefert kein verwendbares Audioformat."
        case .recordingTooLong: "Die Aufnahme darf für diesen Test höchstens 5 Minuten dauern."
        case .interrupted: "Die Aufnahme wurde unterbrochen und nicht transkribiert."
        case .writeFailed: "Die Aufnahme konnte nicht vollständig gespeichert werden."
        }
    }
}

struct RecordingProgress: Equatable, Sendable {
    let capturedFrames: AVAudioFramePosition
    let sampleRate: Double
    let level: Double

    var seconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(capturedFrames) / sampleRate
    }
}

enum AudioMeter {
    static func rms(samples: UnsafePointer<Float>?, count: Int) -> Double {
        guard let samples, count > 0 else { return 0 }
        var squareSum = 0.0
        for index in 0..<count {
            let sample = Double(samples[index])
            squareSum += sample * sample
        }
        return sqrt(squareSum / Double(count))
    }

    static func normalizedLevel(samples: UnsafePointer<Float>?, count: Int) -> Double {
        // RMS is derived from the just-recorded PCM buffer; no synthetic idle value.
        min(1, rms(samples: samples, count: count) * 6)
    }
}

#if os(iOS)
final class AudioRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var outputFile: AVAudioFile?
    private var recordingURL: URL?
    private var capturedFrames: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var level: Double = 0
    private var writeFailure = false
    private var tapInstalled = false
    private var lifecycle: RecordingLifecycle = .idle
    private var interruptionObserver: NSObjectProtocol?
    var onInterruption: (() -> Void)?

    var isRecording: Bool { withLock { lifecycle == .recording } }
    var progress: RecordingProgress {
        withLock { RecordingProgress(capturedFrames: capturedFrames, sampleRate: sampleRate, level: level) }
    }

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
    }

    func start() throws {
        try withLock { try lifecycle.begin() }
        let session = AVAudioSession.sharedInstance()
        var sessionActive = false
        do {
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true)
            sessionActive = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
                  !format.settings.isEmpty else { throw AudioRecorderError.invalidInputFormat }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("klangschrift-\(UUID().uuidString).caf")
            let file = try AVAudioFile(forWriting: destination, settings: format.settings)
            withLock {
                outputFile = file; recordingURL = destination; capturedFrames = 0; sampleRate = format.sampleRate; level = 0; writeFailure = false
            }
            installInterruptionObserver(session)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in self?.write(buffer, sampleRate: format.sampleRate) }
            withLock { tapInstalled = true }
            engine.prepare()
            try engine.start()
            withLock { lifecycle.started() }
        } catch {
            shutdown(deleteRecording: true, deactivateSession: sessionActive)
            throw error
        }
    }

    func stop() throws -> URL {
        let snapshot = shutdown(deleteRecording: false, deactivateSession: true)
        guard let url = snapshot.url else { throw AudioRecorderError.noRecording }
        if snapshot.writeFailed { try? FileManager.default.removeItem(at: url); throw AudioRecorderError.writeFailed }
        if snapshot.capturedFrames == 0 { try? FileManager.default.removeItem(at: url); throw AudioRecorderError.noAudioCaptured }
        return url
    }

    func cancel() { _ = shutdown(deleteRecording: true, deactivateSession: true) }
    deinit { _ = shutdown(deleteRecording: true, deactivateSession: false) }

    private func installInterruptionObserver(_ session: AVAudioSession) {
        removeInterruptionObserver()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
            guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            // The owner closes and transcribes the partial file through normal stop().
            // Never delete it before the completion pipeline can take ownership.
            self?.onInterruption?()
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, sampleRate: Double) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard lifecycle == .recording, let outputFile, !writeFailure else { return }
        let allowed = RecordingPolicy.allowedFrames(captured: capturedFrames, incoming: buffer.frameLength, sampleRate: sampleRate)
        guard allowed > 0 else { return }
        let originalLength = buffer.frameLength; buffer.frameLength = allowed
        if let samples = buffer.floatChannelData?.pointee {
            level = AudioMeter.normalizedLevel(samples: samples, count: Int(allowed))
        } else {
            level = 0
        }
        do { try outputFile.write(from: buffer); capturedFrames += AVAudioFramePosition(allowed) }
        catch { writeFailure = true }
        buffer.frameLength = originalLength
    }

    private struct Snapshot { let url: URL?; let writeFailed: Bool; let tapInstalled: Bool; let capturedFrames: AVAudioFramePosition }
    @discardableResult private func shutdown(deleteRecording: Bool, deactivateSession: Bool) -> Snapshot {
        let snapshot: Snapshot = withLock {
            let value = Snapshot(url: recordingURL, writeFailed: writeFailure, tapInstalled: tapInstalled, capturedFrames: capturedFrames)
            outputFile = nil; recordingURL = nil; capturedFrames = 0; sampleRate = 0; level = 0; writeFailure = false; tapInstalled = false; lifecycle.reset()
            return value
        }
        if snapshot.tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        removeInterruptionObserver()
        if deactivateSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        if deleteRecording, let url = snapshot.url { try? FileManager.default.removeItem(at: url) }
        return snapshot
    }

    private func removeInterruptionObserver() { if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }; interruptionObserver = nil }
    private func withLock<T>(_ body: () throws -> T) rethrows -> T { stateLock.lock(); defer { stateLock.unlock() }; return try body() }
}
#else
final class AudioRecorder { var onInterruption: (() -> Void)?; var isRecording: Bool { false }; var progress: RecordingProgress { RecordingProgress(capturedFrames: 0, sampleRate: 0, level: 0) }; func requestPermission() async -> Bool { false }; func start() throws { throw AudioRecorderError.microphoneDenied }; func stop() throws -> URL { throw AudioRecorderError.noRecording }; func cancel() {} }
#endif
