import AVFoundation
import Foundation

enum RecordingPolicy {
    static let maximumSeconds: TimeInterval = 600

    static func shouldPreserveInterruptedAudio(seconds: TimeInterval, writeFailed: Bool) -> Bool {
        !writeFailed && seconds.isFinite && seconds >= 0.5
    }

    static func showsEndingSoon(elapsedSeconds: Int) -> Bool {
        let remaining = Int(maximumSeconds) - elapsedSeconds
        return remaining > 0 && remaining <= 30
    }

    static func clock(_ seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// Progress follows written frames, so silence is valid audio. Only missing frames time out.
    struct CaptureWatchdog {
        private var clipStartedAt: Date?
        private var frames: AVAudioFramePosition = 0
        private var lastProgressAt: Date?

        mutating func stalled(capturedFrames: AVAudioFramePosition, startedAt: Date, now: Date) -> Bool {
            if clipStartedAt != startedAt {
                clipStartedAt = startedAt; frames = 0; lastProgressAt = startedAt
            }
            if capturedFrames > frames {
                frames = capturedFrames; lastProgressAt = now
            }
            return now.timeIntervalSince(lastProgressAt ?? startedAt) >= 3
        }
    }

    static func allowedFrames(captured: AVAudioFramePosition, incoming: AVAudioFrameCount, sampleRate: Double) -> AVAudioFrameCount {
        let maximum = AVAudioFramePosition((maximumSeconds * sampleRate).rounded(.down))
        guard captured < maximum else { return 0 }
        return AVAudioFrameCount(min(AVAudioFramePosition(incoming), maximum - captured))
    }
}

/// Retry only lock contention, preserving the caller-owned clip until the operation settles.
@MainActor
enum BridgeTransactionRetry {
    static func run(
        operation: () throws -> Bool,
        wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Bool {
        for attempt in 0...5 {
            try Task.checkCancellation()
            do { return try operation() }
            catch KeyboardBridgeError.busy {
                guard attempt < 5 else { throw KeyboardBridgeError.busy }
                try await wait(.milliseconds(100))
            }
        }
        return false
    }
}

/// One completion owner for normal stops and overlapping lifecycle interruptions.
@MainActor
final class MainDictationCompletion {
    private(set) var processing = false
    private var copyRequired = false

    func begin(interrupted: Bool, stop: () throws -> URL) throws -> URL? {
        guard !processing else { if interrupted { copyRequired = true }; return nil }
        let recording = try stop()
        processing = true; copyRequired = interrupted
        return recording
    }

    func interrupted() { if processing { copyRequired = true } }

    func complete(recording: URL, transcribe: (URL) async throws -> String,
                  save: (String) -> Void, copy: (String) -> Void) async throws -> String {
        defer { processing = false; copyRequired = false }
        let text = try await transcribe(recording)
        save(text)
        if copyRequired { copy(text) }
        return text
    }
}
