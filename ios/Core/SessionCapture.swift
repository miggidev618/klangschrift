import AVFoundation
import Foundation

/// The audio callback accesses only this lock-protected object, never UI state.
final class SessionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var url: URL?
    private var frames: AVAudioFramePosition = 0
    private var rate = 0.0
    private var level = 0.0
    private var failed = false
    private var bufferCount = 0

    var receivedBufferCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bufferCount
    }

    var writeFailed: Bool {
        lock.lock(); defer { lock.unlock() }
        return failed
    }

    var progress: RecordingProgress {
        lock.lock(); defer { lock.unlock() }
        return RecordingProgress(capturedFrames: frames, sampleRate: rate, level: level)
    }

    func start(format: AVAudioFormat) throws {
        lock.lock(); defer { lock.unlock() }
        guard file == nil else { throw AudioRecorderError.alreadyRecording }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("klangschrift-keyboard-\(UUID().uuidString).caf")
        let output = try AVAudioFile(forWriting: destination, settings: format.settings)
        file = output; url = destination; rate = format.sampleRate; frames = 0; level = 0; failed = false; bufferCount = 0
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        bufferCount += 1
        guard let file, !failed else { return } // No file exists while idle.
        let allowed = RecordingPolicy.allowedFrames(captured: frames, incoming: buffer.frameLength, sampleRate: rate)
        guard allowed > 0 else { return }
        let original = buffer.frameLength
        buffer.frameLength = allowed
        defer { buffer.frameLength = original }
        level = AudioMeter.normalizedLevel(samples: buffer.floatChannelData?.pointee, count: Int(allowed))
        do { try file.write(from: buffer); frames += AVAudioFramePosition(allowed) }
        catch { failed = true }
    }

    func finish() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let destination = url else { throw AudioRecorderError.noRecording }
        let count = frames, writeFailed = failed
        reset()
        if writeFailed || count == 0 {
            try? FileManager.default.removeItem(at: destination)
            throw writeFailed ? AudioRecorderError.writeFailed : AudioRecorderError.noAudioCaptured
        }
        return destination
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        let destination = url
        reset()
        if let destination { try? FileManager.default.removeItem(at: destination) }
    }

    private func reset() { file = nil; url = nil; frames = 0; rate = 0; level = 0; failed = false }
}
