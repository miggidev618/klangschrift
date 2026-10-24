import Foundation
import AVFoundation
import CoreAudio
import KlangschriftCore

public struct AudioInputDevice: Sendable, Equatable, Hashable {
    public let uid: String; public let displayName: String; public let isDefault: Bool
    public init(uid: String, displayName: String, isDefault: Bool) { self.uid = uid; self.displayName = displayName; self.isDefault = isDefault }
}

/// Device discovery is a read-only CoreAudio operation. Permission prompting is
/// deliberately absent; the UI owns any future TCC education flow.
public protocol AudioDeviceCataloging: Sendable { func devices() -> [AudioInputDevice] }
public struct CoreAudioDeviceCatalog: AudioDeviceCataloging {
    public init() {}
    public func devices() -> [AudioInputDevice] {
        let list = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return list.map { AudioInputDevice(uid: $0.uniqueID, displayName: $0.localizedName, isDefault: $0.uniqueID == defaultID) }
    }
}

public enum AudioDeviceEvent: Sendable, Equatable { case changed([AudioInputDevice]), lost(uid: String) }
public protocol AudioDeviceObserving: Sendable { func setHandler(_ handler: @escaping @Sendable (AudioDeviceEvent) -> Void) }
public protocol AudioDeviceLossHandling: AnyObject, Sendable { @discardableResult func handleDeviceLoss(uid: String) -> Bool }
/// Coordinator wiring with weak ownership: device changes are informational,
/// only an explicit disconnect is forwarded to the active capture service.
public final class AudioDeviceLossBridge: @unchecked Sendable {
    private let observer: any AudioDeviceObserving; private weak var handler: (any AudioDeviceLossHandling)?
    public init(observer: any AudioDeviceObserving, handler: any AudioDeviceLossHandling) { self.observer = observer; self.handler = handler; observer.setHandler { [weak self] event in if case .lost(let uid) = event { _ = self?.handler?.handleDeviceLoss(uid: uid) } } }
}
/// Read-only hot-plug observer; ownership of device selection remains in the
/// coordinator/state machine, so this observer never switches devices itself.
public final class CoreAudioDeviceObserver: AudioDeviceObserving, @unchecked Sendable {
    private let catalog: any AudioDeviceCataloging; private let lock = NSLock(); private var handler: (@Sendable (AudioDeviceEvent) -> Void)?; private var tokens: [NSObjectProtocol] = []
    public init(catalog: any AudioDeviceCataloging) {
        self.catalog = catalog
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil) { [weak self] _ in self?.emitChange() })
        tokens.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            guard let self else { return }; if let device = notification.object as? AVCaptureDevice { self.emit(.lost(uid: device.uniqueID)) }; self.emitChange()
        })
    }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    public func setHandler(_ handler: @escaping @Sendable (AudioDeviceEvent) -> Void) { lock.lock(); self.handler = handler; lock.unlock() }
    private func emit(_ event: AudioDeviceEvent) { lock.lock(); let current = handler; lock.unlock(); current?(event) }
    private func emitChange() { emit(.changed(catalog.devices())) }
}

public struct PCM16Frame: Sendable, Equatable { public let sampleRate: Int; public let channels: Int; public let samples: [Int16]; public init(sampleRate: Int, channels: Int, samples: [Int16]) { self.sampleRate = sampleRate; self.channels = channels; self.samples = samples } }
public struct CanonicalPCM16: Sendable, Equatable { public static let sampleRate = 16_000; public let samples: [Int16]; public init(samples: [Int16]) { self.samples = samples }
    /// Downmixes equal-weight channels then deterministic nearest-point resamples.
    public static func convert(_ input: PCM16Frame) throws -> CanonicalPCM16 {
        guard input.sampleRate >= 8_000, input.sampleRate <= 192_000, input.channels > 0, input.channels <= 8, input.samples.count <= SampleBufferPCMExtractor.maximumBytes / 2, input.samples.count % input.channels == 0 else { throw DictationError.unavailable("invalid pcm") }
        let frames = input.samples.count / input.channels
        let mono: [Int16] = (0..<frames).map { frame in
            let sum = (0..<input.channels).reduce(Int32(0)) { $0 + Int32(input.samples[frame * input.channels + $1]) }
            return Int16(clamping: sum / Int32(input.channels))
        }
        let scaled = Int64(frames).multipliedReportingOverflow(by: Int64(sampleRate)); guard !scaled.overflow else { throw DictationError.unavailable("pcm too large") }
        let outputCount = Int((scaled.partialValue + Int64(input.sampleRate) - 1) / Int64(input.sampleRate))
        guard outputCount > 0 else { return CanonicalPCM16(samples: []) }
        return CanonicalPCM16(samples: (0..<outputCount).map { index in mono[min(frames - 1, Int((Int64(index) * Int64(input.sampleRate)) / Int64(sampleRate)))] })
    }
}

/// Chunk-invariant nearest-point resampler. Output index is mapped against the
/// absolute input-frame timeline, so arbitrary callback partitioning cannot
/// accumulate per-buffer rounding drift.
public struct StreamingPCM16Converter: Sendable {
    private var sourceRate: Int?; private var sourceChannels: Int?; private var totalFrames: Int64 = 0; private var nextOutput: Int64 = 0
    public init() {}
    public mutating func reset() { sourceRate = nil; sourceChannels = nil; totalFrames = 0; nextOutput = 0 }
    public mutating func append(_ input: PCM16Frame) throws -> CanonicalPCM16 {
        guard input.sampleRate >= 8_000, input.sampleRate <= 192_000, input.channels > 0, input.channels <= 8, input.samples.count <= SampleBufferPCMExtractor.maximumBytes / 2, input.samples.count % input.channels == 0 else { throw DictationError.unavailable("invalid pcm") }
        if let rate = sourceRate, rate != input.sampleRate || sourceChannels != input.channels { throw DictationError.unavailable("pcm format changed") }
        sourceRate = input.sampleRate; sourceChannels = input.channels
        let frames = input.samples.count / input.channels, start = totalFrames, end = start + Int64(frames)
        let mono: [Int16] = (0..<frames).map { frame in Int16(clamping: (0..<input.channels).reduce(Int32(0)) { $0 + Int32(input.samples[frame * input.channels + $1]) } / Int32(input.channels)) }
        var output: [Int16] = []
        while true {
            let product = nextOutput.multipliedReportingOverflow(by: Int64(input.sampleRate)); guard !product.overflow else { throw DictationError.unavailable("pcm too large") }
            let source = product.partialValue / Int64(CanonicalPCM16.sampleRate)
            guard source < end else { break }
            guard source >= start else { throw DictationError.unavailable("resample ordering") }
            output.append(mono[Int(source - start)]); nextOutput += 1
        }
        totalFrames = end; return CanonicalPCM16(samples: output)
    }
}

public struct AudioEnergy: Sendable, Equatable { public let rms: Double; public init(samples: [Int16]) { guard !samples.isEmpty else { rms = 0; return }; let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }; rms = (sum / Double(samples.count)).squareRoot() / 32768.0 } }
public struct VoiceSegment: Sendable, Equatable { public let range: Range<Int>; public init(range: Range<Int>) { self.range = range } }
public struct VoiceActivityDetector: Sendable {
    public let threshold: Double; public let frameSamples: Int
    public init(threshold: Double = 0.003, frameSamples: Int = 320) { self.threshold = threshold; self.frameSamples = frameSamples }
    public func segments(in pcm: CanonicalPCM16) -> [VoiceSegment] {
        guard frameSamples > 0 else { return [] }; var output: [VoiceSegment] = []; var open: Int?
        for start in stride(from: 0, to: pcm.samples.count, by: frameSamples) {
            let end = min(start + frameSamples, pcm.samples.count), active = AudioEnergy(samples: Array(pcm.samples[start..<end])).rms >= threshold
            if active && open == nil { open = start }
            if !active, let initial = open { output.append(VoiceSegment(range: initial..<start)); open = nil }
        }
        if let initial = open { output.append(VoiceSegment(range: initial..<pcm.samples.count)) }
        return output
    }
    public func trimmed(_ pcm: CanonicalPCM16) -> CanonicalPCM16 { guard let first = segments(in: pcm).first, let last = segments(in: pcm).last else { return CanonicalPCM16(samples: []) }; return CanonicalPCM16(samples: Array(pcm.samples[first.range.lowerBound..<last.range.upperBound])) }
}

public enum RecordingMode: Sendable { case pushToTalk, toggle }
public enum AudioCaptureState: Sendable, Equatable { case idle, recording(session: DictationSessionID, deviceUID: String, startedAt: UInt64), finishing(session: DictationSessionID), recovering, failed(String) }
public enum AudioCaptureEvent: Sendable { case start(session: DictationSessionID, device: AudioInputDevice, mode: RecordingMode, now: UInt64), stop, cancel, timeout, finish, deviceLost(uid: String), deviceChanged(uid: String), failed(code: String), recovered }

public struct AudioCaptureStateMachine: Sendable {
    public private(set) var state: AudioCaptureState = .idle
    public init() {}
    public mutating func handle(_ event: AudioCaptureEvent) -> Bool {
        switch (state, event) {
        case (.idle, .start(let id, let device, _, let now)): state = .recording(session: id, deviceUID: device.uid, startedAt: now); return true
        case (.recording(let session, _, _), .finish): state = .finishing(session: session); return true
        case (.finishing, .stop), (.finishing, .cancel): state = .idle; return true
        case (.recording(_, let uid, _), .stop), (.recording(_, let uid, _), .cancel), (.recording(_, let uid, _), .timeout): state = .idle; _ = uid; return true
        case (.recording(_, let uid, _), .deviceLost(let lost)) where uid == lost: state = .recovering; return true
        case (.recording, .failed(let code)): state = .failed(code); return true
        case (.recording, .deviceChanged): return false // device changes are only legal between sessions
        case (.recovering, .recovered), (.failed, .recovered): state = .idle; return true
        default: return false
        }
    }
}

public enum WAVWriter {
    public static func validate(sampleCount: Int) throws {
        guard sampleCount >= 0 else { throw DictationError.unavailable("wav too large") }
        let payload = Int64(sampleCount) * Int64(MemoryLayout<Int16>.size), file = 36 + payload
        guard payload <= Int64(UInt32.max), file <= Int64(UInt32.max) else { throw DictationError.unavailable("wav too large") }
    }
    public static func data(for pcm: CanonicalPCM16) throws -> Data {
        try validate(sampleCount: pcm.samples.count); let payload = Int64(pcm.samples.count) * Int64(MemoryLayout<Int16>.size), file = 36 + payload
        let payloadBytes = Int(payload), fileBytes = Int(file)
        func u32(_ n: Int) -> [UInt8] { [UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)] }
        func u16(_ n: Int) -> [UInt8] { [UInt8(n & 0xff), UInt8((n >> 8) & 0xff)] }
        var out = Data("RIFF".utf8); out.append(contentsOf: u32(fileBytes)); out.append(Data("WAVEfmt ".utf8)); out.append(contentsOf: u32(16)); out.append(contentsOf: u16(1)); out.append(contentsOf: u16(1)); out.append(contentsOf: u32(CanonicalPCM16.sampleRate)); out.append(contentsOf: u32(CanonicalPCM16.sampleRate * 2)); out.append(contentsOf: u16(2)); out.append(contentsOf: u16(16)); out.append(Data("data".utf8)); out.append(contentsOf: u32(payloadBytes))
        for sample in pcm.samples { let value = UInt16(bitPattern: sample); out.append(UInt8(value & 0xff)); out.append(UInt8(value >> 8)) }
        return out
    }
}

public protocol PrivateAudioFileOperations: Sendable { func createDirectory(in parent: URL) throws -> URL; func write(_ data: Data, in directory: URL) throws -> URL; func removeDirectory(_ directory: URL) throws }
public struct SystemPrivateAudioFileOperations: PrivateAudioFileOperations { public init() {}; public func createDirectory(in parent: URL) throws -> URL { try PrivateTemporaryStorage.createDirectory(named: "audio", in: parent) }; public func write(_ data: Data, in directory: URL) throws -> URL { try PrivateTemporaryStorage.writeNew(data, named: "capture.wav", in: directory) }; public func removeDirectory(_ directory: URL) throws { try FileManager.default.removeItem(at: directory) } }
public struct PrivateAudioCleanupFailure: Error, Sendable, Equatable { public enum SafeCode: String, Sendable { case writeFailed, removeFailed }; public let primary: SafeCode; public let cleanup: SafeCode; public let residualDirectory: URL; public init(residualDirectory: URL) { self.primary = .writeFailed; self.cleanup = .removeFailed; self.residualDirectory = residualDirectory } }
public protocol AudioFileWriting: Sendable { func write(_ pcm: CanonicalPCM16, in parent: URL) throws -> URL }
public struct PrivateWAVFileWriter: AudioFileWriting {
    private let operations: any PrivateAudioFileOperations
    public init(operations: any PrivateAudioFileOperations = SystemPrivateAudioFileOperations()) { self.operations = operations }
    public func write(_ pcm: CanonicalPCM16, in parent: URL) throws -> URL {
        let directory = try operations.createDirectory(in: parent)
        do { return try operations.write(WAVWriter.data(for: pcm), in: directory) }
        catch { do { try operations.removeDirectory(directory) } catch { throw PrivateAudioCleanupFailure(residualDirectory: directory) }; throw error }
    }
    public func retryCleanup(_ failure: PrivateAudioCleanupFailure) throws { try operations.removeDirectory(failure.residualDirectory) }
}

/// Informational completion reasons; consumers must stop/process retained PCM,
/// rather than routing these through the destructive cancellation path.
public enum AudioCaptureCompletionReason: Sendable, Equatable { case maximumDuration, callbackLoss, interrupted, interruptedCopied, lockedCopied }
public struct AudioCaptureResult: Sendable {
    public let url: URL
    public let completionReason: AudioCaptureCompletionReason?
    public let sampleCount: Int
    public init(url: URL, completionReason: AudioCaptureCompletionReason? = nil, sampleCount: Int = 0) { self.url = url; self.completionReason = completionReason; self.sampleCount = sampleCount }
}
public enum PCMExtractionStatus: Sendable, Equatable { case accepted, rejected(String), capacityExceeded, completed(AudioCaptureCompletionReason) }
public protocol SampleBufferPCMExtracting: Sendable { func extract(_ sampleBuffer: CMSampleBuffer) throws -> PCM16Frame }
public struct PCM16Layout: Sendable { public let sampleRate: Int; public let channels: Int; public let bytesPerFrame: Int; public let framesPerPacket: Int; public let bytesPerPacket: Int; public let signed: Bool; public let bigEndian: Bool; public let floatingPoint: Bool; public let nonInterleaved: Bool; public init(sampleRate: Int, channels: Int, bytesPerFrame: Int, framesPerPacket: Int = 1, bytesPerPacket: Int, signed: Bool, bigEndian: Bool, floatingPoint: Bool, nonInterleaved: Bool) { self.sampleRate = sampleRate; self.channels = channels; self.bytesPerFrame = bytesPerFrame; self.framesPerPacket = framesPerPacket; self.bytesPerPacket = bytesPerPacket; self.signed = signed; self.bigEndian = bigEndian; self.floatingPoint = floatingPoint; self.nonInterleaved = nonInterleaved } }
public enum StrictPCM16Decoder {
    public static func decode(layout: PCM16Layout, bytes: Data) throws -> PCM16Frame {
        guard layout.sampleRate >= 8_000, layout.sampleRate <= 192_000, layout.channels > 0, layout.channels <= 8, layout.signed, !layout.bigEndian, !layout.floatingPoint, !layout.nonInterleaved, layout.bytesPerFrame == layout.channels * 2, layout.framesPerPacket == 1, layout.bytesPerPacket == layout.bytesPerFrame, bytes.count <= SampleBufferPCMExtractor.maximumBytes, bytes.count % layout.bytesPerFrame == 0 else { throw DictationError.unavailable("unsupported pcm") }
        var samples: [Int16] = []; samples.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) { let lo = UInt16(bytes[index]), hi = UInt16(bytes[index + 1]); samples.append(Int16(bitPattern: lo | (hi << 8))) }
        return PCM16Frame(sampleRate: layout.sampleRate, channels: layout.channels, samples: samples)
    }
}
/// Strict production extractor: unsupported formats are rejected before any
/// samples are retained. It accepts only bounded, interleaved signed-16 PCM.
public struct SampleBufferPCMExtractor: SampleBufferPCMExtracting {
    public static let maximumBytes = 4 * 1024 * 1024
    public init() {}
    public static func verifySessionStarted(_ isRunning: Bool) throws { guard isRunning else { throw DictationError.unavailable("audio session did not start") } }
    public func extract(_ sampleBuffer: CMSampleBuffer) throws -> PCM16Frame {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { throw DictationError.unavailable("missing audio format") }
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 16, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { throw DictationError.unavailable("unsupported pcm") }
        let length = CMBlockBufferGetDataLength(block)
        guard length >= 0, length <= Self.maximumBytes else { throw DictationError.unavailable("invalid pcm bytes") }
        var bytes = Data(count: length); let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr else { throw DictationError.unavailable("pcm read") }
        let flags = asbd.mFormatFlags
        return try StrictPCM16Decoder.decode(layout: .init(sampleRate: Int(asbd.mSampleRate), channels: Int(asbd.mChannelsPerFrame), bytesPerFrame: Int(asbd.mBytesPerFrame), framesPerPacket: Int(asbd.mFramesPerPacket), bytesPerPacket: Int(asbd.mBytesPerPacket), signed: (flags & kAudioFormatFlagIsSignedInteger) != 0, bigEndian: (flags & kAudioFormatFlagIsBigEndian) != 0, floatingPoint: (flags & kAudioFormatFlagIsFloat) != 0, nonInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) != 0), bytes: bytes)
    }
}

public protocol AudioPermissionPreflightChecking: ServicePreflightChecking {}

public protocol AudioCaptureSessionControlling: AnyObject, Sendable { func configureAndStart(deviceUID: String, output: AVCaptureAudioDataOutput) throws; func stopAndReset() }
public protocol AudioSessionPrimitive: AnyObject, Sendable { func configureAndStartReportRunning(deviceUID: String, output: AVCaptureAudioDataOutput) throws -> Bool; func stopAndReset() }
public protocol AudioSessionStarting: Sendable { func startAndReportRunning(_ session: AVCaptureSession) -> Bool }
public struct AVAudioSessionStarter: AudioSessionStarting { public init() {}; public func startAndReportRunning(_ session: AVCaptureSession) -> Bool { session.startRunning(); return session.isRunning } }
public enum AudioSessionStartContract { public static func requireRunning(_ running: Bool) throws { guard running else { throw DictationError.unavailable("audio session did not start") } } }
public final class AVAudioSessionPrimitive: AudioSessionPrimitive, @unchecked Sendable {
    private let session = AVCaptureSession(); private var input: AVCaptureDeviceInput?; private let starter: any AudioSessionStarting
    public init(starter: any AudioSessionStarting = AVAudioSessionStarter()) { self.starter = starter }
    public func configureAndStartReportRunning(deviceUID: String, output: AVCaptureAudioDataOutput) throws -> Bool {
        guard let device = AVCaptureDevice(uniqueID: deviceUID) else { throw DictationError.unavailable("audio device") }
        session.beginConfiguration(); var committed = false
        defer { if !committed { session.commitConfiguration() } }
        let old = input; if let old { session.removeInput(old) }
        do {
            let created = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(created), session.outputs.contains(output) || session.canAddOutput(output) else { throw DictationError.unavailable("audio input") }
            session.addInput(created); if !session.outputs.contains(output) { session.addOutput(output) }
            input = created; session.commitConfiguration(); committed = true; return starter.startAndReportRunning(session)
        } catch {
            if let input { session.removeInput(input) }; input = nil
            if let old, session.canAddInput(old) { session.addInput(old); input = old }
            session.commitConfiguration(); committed = true; throw error
        }
    }
    public func stopAndReset() { session.stopRunning(); session.beginConfiguration(); if let input { session.removeInput(input) }; input = nil; session.commitConfiguration() }
}
/// Testable boundary: the primitive owns AVFoundation configuration; this
/// wrapper owns the fail-closed running contract and rollback policy.
public final class AVAudioCaptureSessionController: AudioCaptureSessionControlling, @unchecked Sendable {
    private let primitive: any AudioSessionPrimitive
    public init(primitive: any AudioSessionPrimitive = AVAudioSessionPrimitive()) { self.primitive = primitive }
    public func configureAndStart(deviceUID: String, output: AVCaptureAudioDataOutput) throws {
        do { try AudioSessionStartContract.requireRunning(primitive.configureAndStartReportRunning(deviceUID: deviceUID, output: output)) }
        catch { primitive.stopAndReset(); throw error }
    }
    public func stopAndReset() { primitive.stopAndReset() }
}

/// Production AVCapture adapter. It is inert until `start` receives a positive
/// injected preflight. It never invokes the AVFoundation access-request API and serializes all session
/// work on one queue. The capture delegate feeds the pure converter above.
public final class AVAudioCaptureAdapter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AudioDeviceLossHandling, @unchecked Sendable {
    private let preflight: any AudioPermissionPreflightChecking; private let queue = DispatchQueue(label: "io.github.miggidev618.klangschrift.audio.capture"); private let eventQueue: DispatchQueue; private let backend: any AudioCaptureSessionControlling; private let extractor: any SampleBufferPCMExtracting; private let writer: any AudioFileWriting; private let output = AVCaptureAudioDataOutput(); private var stateMachine = AudioCaptureStateMachine(); private var converter = StreamingPCM16Converter(); private var pcm: [Int16] = []; private let maxDurationNanoseconds: UInt64; private let maximumCanonicalSamples: Int; private let callbackLossNanoseconds: UInt64; private var completionReason: AudioCaptureCompletionReason?; private var lastCallbackAt: UInt64?; private var levelHandler: (@Sendable (Double) -> Void)?; private var terminalHandler: (@Sendable (PCMExtractionStatus) -> Void)?
    // Capture-queue owned; TaskLocal is read before crossing the Dispatch boundary.
    private var preRollSession: DictationSessionID?
    public static let preRollMaximumSamples = CanonicalPCM16.sampleRate / 2
    private var firstSampleTrace: (session: DictationSessionID, trace: PerfTrace)?
    public init(preflight: any AudioPermissionPreflightChecking, backend: any AudioCaptureSessionControlling = AVAudioCaptureSessionController(), extractor: any SampleBufferPCMExtracting = SampleBufferPCMExtractor(), writer: any AudioFileWriting = PrivateWAVFileWriter(), maxDurationNanoseconds: UInt64 = 30 * 60 * 1_000_000_000, callbackLossNanoseconds: UInt64 = 2_000_000_000, eventQueue: DispatchQueue? = nil) {
        self.preflight = preflight; self.backend = backend; self.extractor = extractor; self.writer = writer; self.maxDurationNanoseconds = maxDurationNanoseconds; self.callbackLossNanoseconds = callbackLossNanoseconds; self.eventQueue = eventQueue ?? DispatchQueue(label: "io.github.miggidev618.klangschrift.audio.events"); self.maximumCanonicalSamples = Int(min(UInt64(Int.max), (maxDurationNanoseconds / 1_000_000_000) * UInt64(CanonicalPCM16.sampleRate))); super.init(); output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]; output.setSampleBufferDelegate(self, queue: queue)
    }
    public func setLevelHandler(_ handler: (@Sendable (Double) -> Void)?) { queue.sync { levelHandler = handler } }
    public func setTerminalHandler(_ handler: (@Sendable (PCMExtractionStatus) -> Void)?) { queue.sync { terminalHandler = handler } }
    /// Read-only permission observation for the owner that remains responsible
    /// after capture has stopped and inference is still running.  This never
    /// requests TCC access and does not touch the AVCapture session.
    public func permissionAvailability() -> ServiceAvailability { preflight.availability() }
    private func emitLevel(_ level: Double) { let callback = levelHandler; eventQueue.async { callback?(level) } }
    private func emitTerminal(_ status: PCMExtractionStatus) { let callback = terminalHandler; eventQueue.async { callback?(status) } }
    public func start(sessionID: DictationSessionID, device: AVCaptureDevice, mode: RecordingMode = .pushToTalk, now: UInt64, preRoll: Bool = false) throws {
        try start(sessionID: sessionID, device: .init(uid: device.uniqueID, displayName: device.localizedName, isDefault: false), mode: mode, now: now, preRoll: preRoll)
    }
    public func start(sessionID: DictationSessionID, device: AudioInputDevice, mode: RecordingMode = .pushToTalk, now: UInt64, preRoll: Bool = false) throws {
        guard case .ready = preflight.availability() else {
            queue.sync { if preRollSession == sessionID { failClosed("microphone") } }
            throw ServiceContractError.unavailable("microphone")
        }
        let startTrace = PerfLog.current
        let result: Result<Void, Error> = queue.sync { [self] in Result {
            if !preRoll, preRollSession == sessionID {
                if case .recording(let owner, let uid, _) = stateMachine.state, owner == sessionID, uid == device.uid {
                    preRollSession = nil
                    stateMachine = AudioCaptureStateMachine()
                    _ = stateMachine.handle(.start(session: sessionID, device: device, mode: mode, now: now))
                    return // Keep PCM, converter and the running backend; no second hardware start.
                }
                // A changed device cannot contribute pre-roll to the new selection.
                preRollSession = nil; backend.stopAndReset(); converter.reset(); pcm.removeAll(keepingCapacity: false)
                stateMachine = AudioCaptureStateMachine()
            }
            guard case .idle = stateMachine.state else { throw DictationError.busy(.recording) }
            do {
                try backend.configureAndStart(deviceUID: device.uid, output: output)
                converter.reset(); completionReason = nil; pcm.removeAll(keepingCapacity: false); lastCallbackAt = now
                guard stateMachine.handle(.start(session: sessionID, device: device, mode: mode, now: now)) else { throw DictationError.busy(.recording) }
                firstSampleTrace = startTrace.map { (sessionID, $0) }
                preRollSession = preRoll ? sessionID : nil
                if preRoll {
                    // Independent of gesture timers, UI or callbacks: never leave an unconfirmed mic armed.
                    queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: now) + 1) { [weak self] in
                        guard let self, self.preRollSession == sessionID else { return }
                        self.failClosed("pre-roll-expired")
                    }
                }
            } catch {
                preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset(); converter.reset()
                pcm.removeAll(keepingCapacity: false); lastCallbackAt = nil; stateMachine = AudioCaptureStateMachine(); throw error
            }
        } }
        try result.get()
    }

    public func stop(in parent: URL) throws -> URL { try stopResult(in: parent).url }
    public func stopResult(in parent: URL, session: DictationSessionID? = nil) throws -> AudioCaptureResult {
        let perf = PerfLog.current
        var measurement: (at: UInt64, audioMs: UInt64)?
        let result: Result<AudioCaptureResult, Error> = queue.sync { [self] in Result {
            guard preRollSession == nil else { throw DictationError.unavailable("unconfirmed pre-roll") }
            let owned: DictationSessionID
            switch stateMachine.state {
            case .recording(let id, _, _), .finishing(let id): owned = id
            default: throw DictationError.unavailable("not recording")
            }
            guard session == nil || session == owned else { throw DictationError.cancelled }
            defer { pcm.removeAll(keepingCapacity: false); converter.reset(); completionReason = nil; lastCallbackAt = nil }
            preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset()
            guard stateMachine.handle(.stop) else { throw DictationError.unavailable("not recording") }
            let artifact = try writer.write(CanonicalPCM16(samples: pcm), in: parent)
            measurement = (DispatchTime.now().uptimeNanoseconds, UInt64(pcm.count) * 1_000 / UInt64(CanonicalPCM16.sampleRate))
            return AudioCaptureResult(url: artifact, completionReason: completionReason, sampleCount: pcm.count)
        } }
        if let measurement { perf?.mark(.audioFinalized, audioMilliseconds: measurement.audioMs, atNanoseconds: measurement.at) }
        return try result.get()
    }
    /// Freeze a safety interruption without discarding already captured speech.
    @discardableResult public func interruptRetainingPCM(reason: AudioCaptureCompletionReason = .interrupted) -> Bool {
        queue.sync {
            guard !pcm.isEmpty else { return false }
            switch stateMachine.state {
            case .recording: finishRetainingPCM(reason)
            case .finishing: completionReason = reason; emitTerminal(.completed(reason))
            default: return false
            }
            return true
        }
    }
    public func abort(_ event: AudioCaptureEvent) { queue.sync { [self] in
        preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset(); _ = stateMachine.handle(event)
        // A terminal may already have moved the reducer to failed.  The
        // session owner is nevertheless allowed to cancel exactly once and
        // leave this adapter cold/startable for the following session.
        stateMachine = AudioCaptureStateMachine()
        pcm.removeAll(keepingCapacity: false); converter.reset(); completionReason = nil; lastCallbackAt = nil
    } }
    @discardableResult public func recoverAfterFailure() -> Bool { queue.sync { stateMachine.handle(.recovered) } }
    /// Coordinator watchdog; VAD never invokes this, so push-to-talk is only
    /// ended by its key lifecycle or explicit maximum-duration policy.
    @discardableResult public func enforceMaximumDuration(now: UInt64) -> Bool {
        queue.sync { [self] in
            guard case .recording(_, _, let startedAt) = stateMachine.state, now >= startedAt, now - startedAt >= maxDurationNanoseconds else { return false }
            finishRetainingPCM(.maximumDuration); return true
        }
    }
    /// Independent wall-clock health check.  Normal silence still delivers
    /// buffers and refreshes `lastCallbackAt`; only a complete callback loss
    /// finishes the owned session while retaining its PCM.  The backend is stopped in this call, before
    /// any asynchronous coordinator notification.
    @discardableResult public func enforceCaptureHealth(now: UInt64) -> Bool {
        queue.sync { [self] in
            guard case .recording(_, _, let startedAt) = stateMachine.state else { return false }
            guard case .ready = preflight.availability() else {
                preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset(); _ = stateMachine.handle(.failed(code: "microphone")); pcm.removeAll(keepingCapacity: false); converter.reset(); lastCallbackAt = nil; emitTerminal(.rejected("microphone")); return true
            }
            if now >= startedAt, now - startedAt >= maxDurationNanoseconds { finishRetainingPCM(.maximumDuration); return true }
            guard let lastCallbackAt, now >= lastCallbackAt, now - lastCallbackAt >= callbackLossNanoseconds else { return false }
            finishRetainingPCM(.callbackLoss); return true
        }
    }
    /// The service uses this exact monotonic deadline instead of a polling
    /// interval. It therefore checks a complete callback gap at
    /// last-buffer + grace while retaining a callback-independent max time.
    public func nextHealthDeadline() -> UInt64? {
        queue.sync {
            guard case .recording(_, _, let startedAt) = stateMachine.state else { return nil }
            let maximum = startedAt &+ maxDurationNanoseconds
            guard let lastCallbackAt else { return maximum }
            return min(maximum, lastCallbackAt &+ callbackLossNanoseconds)
        }
    }
    @discardableResult public func handleDeviceLoss(uid: String) -> Bool {
        queue.sync { [self] in let handled = stateMachine.handle(.deviceLost(uid: uid)); if handled { preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset(); pcm.removeAll(keepingCapacity: false); converter.reset(); lastCallbackAt = nil; emitTerminal(.rejected("device-lost")) }; return handled }
    }
    /// Ingestion seam shared by the sample-buffer delegate and deterministic
    /// tests. It converts before appending and emits only a normalized level.
    public func appendCapturedFrame(_ frame: PCM16Frame) {
        queue.async { [self] in ingest(frame) }
    }
    /// Runs only on the capture queue. Freeze ingestion before notifying the
    /// owner; stop(in:) can then materialize exactly one ordinary WAV artifact.
    private func finishRetainingPCM(_ reason: AudioCaptureCompletionReason) {
        if preRollSession != nil { failClosed("pre-roll-unconfirmed"); return }
        guard stateMachine.handle(.finish) else { return }
        preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset()
        converter.reset()
        completionReason = reason
        lastCallbackAt = nil
        emitTerminal(.completed(reason))
    }
    private func ingest(_ frame: PCM16Frame) {
        guard case .recording(let session, _, _) = stateMachine.state else { return }
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        lastCallbackAt = receivedAt
        guard let normalized = try? converter.append(frame) else { failClosed("pcm"); return }
        let remaining = maximumCanonicalSamples - pcm.count
        if preRollSession != nil {
            pcm.append(contentsOf: normalized.samples.suffix(Self.preRollMaximumSamples))
            if pcm.count > Self.preRollMaximumSamples { pcm.removeFirst(pcm.count - Self.preRollMaximumSamples) }
        } else { pcm.append(contentsOf: normalized.samples.prefix(remaining)) }
        if remaining > 0, !normalized.samples.isEmpty, let measurement = firstSampleTrace, measurement.session == session {
            firstSampleTrace = nil
            measurement.trace.mark(.audioFirstSample, atNanoseconds: receivedAt)
        }
        emitLevel(AudioEnergy(samples: normalized.samples).rms)
        if normalized.samples.count >= remaining { finishRetainingPCM(.maximumDuration) }
    }
    private func failClosed(_ code: String) { guard case .recording = stateMachine.state else { return }; preRollSession = nil; firstSampleTrace = nil; backend.stopAndReset(); _ = stateMachine.handle(.failed(code: code)); pcm.removeAll(keepingCapacity: false); converter.reset(); emitTerminal(.rejected(code)) }
    /// Synchronous test seam shares the exact delegate ingestion path while
    /// avoiding CMSampleBuffer/TCC construction.
    public func ingestForTesting(_ frame: PCM16Frame) { queue.sync { ingest(frame) } }
    public func safeDiagnosticsSnapshot() -> (state: AudioCaptureState, bufferedSamples: Int) { queue.sync { (stateMachine.state, pcm.count) } }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { do { try ingest(extractor.extract(sampleBuffer)) } catch { failClosed("sample-buffer") } }
}
