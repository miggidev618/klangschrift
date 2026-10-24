import Foundation
import Dispatch
import os

/// Content-free, session-local measurements. No transcript/path/UUID is accepted
/// by an event or emitted. Model IDs are translated through a frozen code table.
public enum PerfLog {
    @TaskLocal public static var current: PerfTrace?
}
/// Immutable values captured under the existing hotkey source lock.
public struct PerfInputTiming: Sendable {
    public let downAt: UInt64
    public let upAt: UInt64?
    public let stopAt: UInt64?
    public init(downAt: UInt64, upAt: UInt64? = nil, stopAt: UInt64? = nil) {
        self.downAt = downAt; self.upAt = upAt; self.stopAt = stopAt
    }
}
public final class PerfTrace: @unchecked Sendable {
    public enum Event: String, Sendable, CaseIterable {
        case hotkeyDown = "hotkey.down", hotkeyUp = "hotkey.up", stop = "hotkey.stop"
        case startRequested = "start.requested", focusCaptured = "focus.captured", listeningPresented = "listening.presented"
        case audioStartRequested = "audio.start.requested", audioServiceEntered = "audio.service.entered"
        case devicePreferenceReady = "device.preference.ready", captureStartRequested = "capture.start.requested", captureStartReturned = "capture.start.returned", audioFirstSample = "audio.first.sample"
        case recordingStarted = "recording.started", audioFinalized = "audio.finalized"
        case asrRequested = "asr.requested", modelReady = "model.ready", workerSpawned = "worker.spawned"
        case asrFinished = "asr.finished", insertionStarted = "insertion.started", insertionFinished = "insertion.finished"
        case total, asrRealtimeFactor
    }
    public enum Path: String, Sendable { case direct, paste, recovery, draft, uncertain, cancelled, unknown }
    public struct Record: Sendable {
        public let session: UInt64
        public let event: Event
        public let milliseconds: UInt64
        public let audioMilliseconds: UInt64?
        public let coldLoad: Bool?
        public let newWorker: Bool?
        public let modelCode: UInt8
        public let path: Path?
        public let realtimeFactor: Double?
        public var line: String {
            var fields = ["s=\(session)", event.rawValue, "ms=\(milliseconds)", "model=m\(modelCode)"]
            if let audioMilliseconds { fields.append("audio_ms=\(audioMilliseconds)") }
            if let coldLoad { fields.append("coldLoad=\(coldLoad ? 1 : 0)") }
            if let newWorker { fields.append("newWorker=\(newWorker ? 1 : 0)") }
            if let path { fields.append("path=\(path.rawValue)") }
            if let realtimeFactor { fields.append("factor=\(realtimeFactor)") }
            return fields.joined(separator: " ")
        }
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.withLock { value &+= 1; return value } }
    }
    private static let counter = Counter()
    private static let logger = Logger(subsystem: "io.github.miggidev618.klangschrift", category: "perf")
    // m0 unknown, m1 legacy; m2...m23 follow the desktop reference catalog.
    private static let models = ["phonon2-coreml", "phonon2-compact-coreml", "parakeet-v3-coreml", "parakeet-redux-coreml", "moonshine-tiny-streaming-de", "moonshine-tiny-streaming-en", "moonshine-tiny-streaming-ar", "moonshine-tiny-streaming-es", "moonshine-tiny-streaming-ja", "moonshine-tiny-streaming-tl", "moonshine-tiny-streaming-vi", "moonshine-tiny-streaming-zh", "moonshine-small-streaming-de", "moonshine-small-streaming-en", "moonshine-small-streaming-es", "moonshine-small-streaming-ja", "moonshine-medium-streaming-en", "whisper-tiny-coreml", "whisper-tiny-en-coreml", "whisper-base-coreml", "whisper-base-en-coreml", "sherpa-zipformer-en-int8"]
    public let number: UInt64
    private let lock = NSLock()
    private let clock: @Sendable () -> UInt64
    private let sink: @Sendable (Record) -> Void
    private let origin: UInt64
    private var stopAt: UInt64?, asrAt: UInt64?, audioMs: UInt64?
    private var modelCode: UInt8 = 0
    private var insertionFinished = false
    private var workerRecorded = false
    private var modelRecorded = false
    private var audioRecorded = false
    private var stopRecorded = false
    public init(originNanoseconds: UInt64? = nil, clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }, sink: (@Sendable (Record) -> Void)? = nil) {
        number = Self.counter.next(); self.clock = clock; self.sink = sink ?? { record in Self.logger.notice("\(record.line, privacy: .public)") }; origin = originNanoseconds ?? clock()
    }
    public func selectModel(catalogID: String?) {
        let code: UInt8 = catalogID == nil ? 1 : Self.models.firstIndex(of: catalogID!).map { UInt8($0 + 2) } ?? 0
        lock.withLock { modelCode = code }
    }
    public func mark(_ event: Event, audioMilliseconds: UInt64? = nil, coldLoad: Bool? = nil, newWorker: Bool? = nil, durationMilliseconds: UInt64? = nil, atNanoseconds: UInt64? = nil) {
        let now = atNanoseconds ?? clock()
        let records: [Record] = lock.withLock {
            if event == .stop { if stopRecorded { return [] }; stopRecorded = true }
            if event == .audioFinalized { if audioRecorded { return [] }; audioRecorded = true }
            if event == .modelReady { if modelRecorded { return [] }; modelRecorded = true }
            if event == .workerSpawned { if workerRecorded { return [] }; workerRecorded = true }
            if event == .hotkeyUp || event == .stop { if stopAt == nil { stopAt = now } }
            if event == .asrRequested { asrAt = now }
            if let audioMilliseconds { audioMs = audioMilliseconds }
            let elapsed = durationMilliseconds ?? Self.ms(event == .asrFinished ? (asrAt ?? origin) : origin, now)
            var result = [Record(session: number, event: event, milliseconds: elapsed, audioMilliseconds: audioMilliseconds, coldLoad: coldLoad, newWorker: newWorker, modelCode: modelCode, path: nil, realtimeFactor: nil)]
            if event == .asrFinished, let asrAt, let audioMs, audioMs > 0 {
                let ms = Self.ms(asrAt, now)
                result.append(Record(session: number, event: .asrRealtimeFactor, milliseconds: ms, audioMilliseconds: audioMs, coldLoad: nil, newWorker: nil, modelCode: modelCode, path: nil, realtimeFactor: Double(ms) / Double(audioMs)))
            }
            return result
        }
        records.forEach(sink)
    }
    public func finishInsertion(path: Path) {
        let now = clock()
        let records: [Record] = lock.withLock {
            guard !insertionFinished else { return [] }; insertionFinished = true
            var result = [Record(session: number, event: .insertionFinished, milliseconds: Self.ms(origin, now), audioMilliseconds: nil, coldLoad: nil, newWorker: nil, modelCode: modelCode, path: path, realtimeFactor: nil)]
            if let stopAt { result.append(Record(session: number, event: .total, milliseconds: Self.ms(stopAt, now), audioMilliseconds: audioMs, coldLoad: nil, newWorker: nil, modelCode: modelCode, path: path, realtimeFactor: nil)) }
            return result
        }
        records.forEach(sink)
    }
    private static func ms(_ start: UInt64, _ end: UInt64) -> UInt64 { end >= start ? (end - start) / 1_000_000 : 0 }
}
