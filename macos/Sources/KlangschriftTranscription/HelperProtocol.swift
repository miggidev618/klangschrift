import Foundation
import Darwin
import KlangschriftCore

public enum HelperProtocolError: Error, Equatable, Sendable { case invalidFrame, oversizedFrame, malformedJSON, wrongRequestID, wrongVersion, prematureEOF, outcomeUnknown, invalidSchema }
public enum HelperOperation: String, Codable, Sendable { case health, prepare, transcribe, shutdown }
public enum HelperResponseStatus: String, Codable, Sendable { case configured, prepared, misconfigured, silence, ok, shutdown, error }
public struct HelperRequest: Codable, Sendable { public let version: Int; public let id: String; public let op: HelperOperation; public let audio_path: String?; public let language: String?; public init(id: String, op: HelperOperation, audioPath: String? = nil, language: String? = nil) { version=1; self.id=id; self.op=op; self.audio_path=audioPath; self.language=language } }
public struct HelperResponse: Codable, Sendable { public let version: Int; public let id: String?; public let status: HelperResponseStatus; public let text: String?; public let code: String?; public init(version:Int,id:String?,status:HelperResponseStatus,text:String?=nil,code:String?=nil){self.version=version;self.id=id;self.status=status;self.text=text;self.code=code} }
public enum HelperFrame { public static let maximumBytes=1_048_576; public static func encode<T: Encodable>(_ v:T)throws->Data { let p=try JSONEncoder().encode(v); guard p.count>0 && p.count<=maximumBytes else { throw HelperProtocolError.oversizedFrame }; var n=UInt32(p.count).bigEndian; var d=Data(bytes:&n,count:4); d.append(p); return d }; public static func decode<T:Decodable>(_ d:Data,as:T.Type)throws->T { guard d.count>=4 else { throw HelperProtocolError.prematureEOF }; let n=d.prefix(4).withUnsafeBytes{$0.loadUnaligned(as:UInt32.self).bigEndian}; guard n>0 && n<=maximumBytes else {throw HelperProtocolError.oversizedFrame}; guard d.count==Int(n)+4 else {throw d.count<Int(n)+4 ? HelperProtocolError.prematureEOF:HelperProtocolError.invalidFrame}; guard let x=try? JSONDecoder().decode(T.self,from:d.dropFirst(4)) else {throw HelperProtocolError.malformedJSON}; return x } }
public protocol HelperTransport:Sendable { func exchange(_ request:Data)async throws->Data; func terminateAndReap()async -> HelperTerminationOutcome }
/// The only recoverable residual states for an owned private audio artifact.
public enum AudioArtifactCleanupState: String, Equatable, Sendable {
    case filePresent
    case fileRemovedDirectoryPending
}

public struct AudioArtifactCleanupFailure: Error, Equatable, Sendable {
    public let residualDirectory: URL
    public let state: AudioArtifactCleanupState
    public init(residualDirectory: URL, state: AudioArtifactCleanupState) {
        self.residualDirectory = residualDirectory
        self.state = state
    }
}
public struct OwnedAudioArtifact: Sendable {
    public let root: URL; public let directory: URL; public let file: URL
    private let rootDevice, rootInode, directoryDevice, directoryInode, fileDevice, fileInode: UInt64
    public init(root: URL, directory: URL, file: URL) throws {
        let r = root.standardizedFileURL, d = directory.standardizedFileURL, f = file.standardizedFileURL
        var rs = stat(), ds = stat(), fs = stat()
        guard lstat(r.path, &rs) == 0, lstat(d.path, &ds) == 0, lstat(f.path, &fs) == 0,
              (rs.st_mode & S_IFMT) == S_IFDIR, (ds.st_mode & S_IFMT) == S_IFDIR, (fs.st_mode & S_IFMT) == S_IFREG,
              rs.st_uid == getuid(), ds.st_uid == getuid(), fs.st_uid == getuid(),
              (rs.st_mode & 0o022) == 0, (ds.st_mode & 0o077) == 0, (fs.st_mode & 0o077) == 0,
              d.deletingLastPathComponent().path == r.path, f.deletingLastPathComponent().path == d.path else { throw HelperProtocolError.invalidSchema }
        self.root = r; self.directory = d; self.file = f
        rootDevice = UInt64(rs.st_dev); rootInode = rs.st_ino; directoryDevice = UInt64(ds.st_dev); directoryInode = ds.st_ino; fileDevice = UInt64(fs.st_dev); fileInode = fs.st_ino
    }
    private func filePresentFailure() -> AudioArtifactCleanupFailure { .init(residualDirectory: directory, state: .filePresent) }
    private func directoryPendingFailure() -> AudioArtifactCleanupFailure { .init(residualDirectory: directory, state: .fileRemovedDirectoryPending) }

    private func validateRootAndDirectory() -> Bool {
        var rs = stat(), ds = stat()
        return lstat(root.path, &rs) == 0 && lstat(directory.path, &ds) == 0
            && UInt64(rs.st_dev) == rootDevice && rs.st_ino == rootInode
            && UInt64(ds.st_dev) == directoryDevice && ds.st_ino == directoryInode
            && (rs.st_mode & S_IFMT) == S_IFDIR && (ds.st_mode & S_IFMT) == S_IFDIR
            && rs.st_uid == getuid() && ds.st_uid == getuid()
            && (rs.st_mode & 0o022) == 0 && (ds.st_mode & 0o077) == 0
            && directory.deletingLastPathComponent().path == root.path
    }

    private func validateOwnedFile() -> Bool {
        var fs = stat()
        return lstat(file.path, &fs) == 0
            && UInt64(fs.st_dev) == fileDevice && fs.st_ino == fileInode
            && (fs.st_mode & S_IFMT) == S_IFREG && fs.st_uid == getuid()
            && (fs.st_mode & 0o077) == 0
            && file.deletingLastPathComponent().path == directory.path
    }

    public func cleanup() throws {
        guard validateRootAndDirectory(), validateOwnedFile() else { throw filePresentFailure() }
        guard unlink(file.path) == 0 else { throw filePresentFailure() }
        guard rmdir(directory.path) == 0 else { throw directoryPendingFailure() }
    }

    /// Retry never follows a replacement path or deletes unexpected contents.
    public func retryCleanup(_ failure: AudioArtifactCleanupFailure) throws {
        guard failure.residualDirectory == directory else { throw HelperProtocolError.invalidSchema }
        switch failure.state {
        case .filePresent:
            try cleanup()
        case .fileRemovedDirectoryPending:
            guard validateRootAndDirectory() else { throw directoryPendingFailure() }
            var fs = stat()
            guard lstat(file.path, &fs) != 0, Darwin.errno == ENOENT else { throw filePresentFailure() }
            guard rmdir(directory.path) == 0 else { throw directoryPendingFailure() }
        }
    }
}
public struct HelperLaunchConfiguration: Sendable {
    public let python: URL; public let helper: URL; public let model: URL; public let audioRoot: URL; public let isolatedImportRoot: URL?; public let configHash: String; public let weightsHash: String; public let extraArguments: [String]; public let passesHelperPath: Bool
    private struct Identity: Sendable, Equatable { let device: UInt64; let inode: UInt64; let uid: UInt32; let mode: UInt16 }
    private let identities: (python: Identity, helper: Identity, model: Identity, audio: Identity, imports: Identity?)?
    private static func secureDirectory(_ url: URL, exact0700: Bool = false) -> URL? {
        let value = url.standardizedFileURL
        guard value.isFileURL, value.path.hasPrefix("/"), !value.path.contains(":"), value.resolvingSymlinksInPath().path == value.path else { return nil }
        var info = stat()
        guard lstat(value.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & 0o022) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              !exact0700 || (info.st_mode & 0o777) == 0o700 else { return nil }
        return value
    }
    private static func securePython(_ url: URL) -> URL? {
        let value = url.standardizedFileURL
        guard value.isFileURL, value.path.hasPrefix("/"), value.resolvingSymlinksInPath().path == value.path else { return nil }
        var info = stat()
        guard lstat(value.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(value.path, X_OK) == 0 else { return nil }
        return value
    }
    /// The helper is a Python argument, not an executable. It must be a direct,
    /// owner-readable regular file so launch never follows a mutable symlink.
    private static func secureHelper(_ url: URL) -> URL? {
        let value = url.standardizedFileURL
        guard value.isFileURL, value.path.hasPrefix("/"), value.resolvingSymlinksInPath().path == value.path else { return nil }
        var info = stat()
        guard lstat(value.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(value.path, R_OK) == 0 else { return nil }
        return value
    }
    private static func identity(_ url: URL) -> Identity? { var info = stat(); guard lstat(url.path, &info) == 0 else { return nil }; return .init(device: UInt64(info.st_dev), inode: info.st_ino, uid: info.st_uid, mode: UInt16(info.st_mode & 0o7777)) }
    public init(python: URL, helper: URL, model: URL, audioRoot: URL, isolatedImportRoot: URL? = nil, configHash: String, weightsHash: String, extraArguments: [String] = [], passesHelperPath: Bool = true) throws {
        guard configHash.range(of:"^[a-f0-9]{64}$", options:.regularExpression) != nil, weightsHash.range(of:"^[a-f0-9]{64}$", options:.regularExpression) != nil else { throw HelperProtocolError.invalidSchema }
        if passesHelperPath {
            guard extraArguments.isEmpty, let p = Self.securePython(python), let h = Self.secureHelper(helper), let m = Self.secureDirectory(model), let a = Self.secureDirectory(audioRoot, exact0700:true) else { throw HelperProtocolError.invalidSchema }
            let imports: URL?
            if let isolatedImportRoot {
                guard let secure = Self.secureDirectory(isolatedImportRoot), let identity = Self.identity(secure) else { throw HelperProtocolError.invalidSchema }
                imports = secure
                guard let pi = Self.identity(p), let hi = Self.identity(h), let mi = Self.identity(m), let ai = Self.identity(a) else { throw HelperProtocolError.invalidSchema }
                self.python=p; self.helper=h; self.model=m; self.audioRoot=a; self.isolatedImportRoot=imports; identities = (pi, hi, mi, ai, identity)
            } else {
                guard let pi = Self.identity(p), let hi = Self.identity(h), let mi = Self.identity(m), let ai = Self.identity(a) else { throw HelperProtocolError.invalidSchema }
                self.python=p; self.helper=h; self.model=m; self.audioRoot=a; self.isolatedImportRoot=nil; identities = (pi, hi, mi, ai, nil)
            }
        } else {
            for path in [python, helper, model, audioRoot] { guard path.isFileURL && path.path.hasPrefix("/") else { throw HelperProtocolError.invalidSchema } }
            self.python=python.standardizedFileURL; self.helper=helper.standardizedFileURL; self.model=model.standardizedFileURL; self.audioRoot=audioRoot.standardizedFileURL; self.isolatedImportRoot=nil; identities = nil
        }
        self.configHash=configHash; self.weightsHash=weightsHash; self.extraArguments=extraArguments; self.passesHelperPath=passesHelperPath
    }
    /// Test-only stub factory: it deliberately permits a mode argument, unlike production launch configuration.
    public static func stub(executable: URL, root: URL, mode: String) throws -> Self { try Self(python: executable, helper: executable, model: root, audioRoot: root, configHash: String(repeating:"a", count:64), weightsHash: String(repeating:"b", count:64), extraArguments:[mode], passesHelperPath:false) }
    /// Rechecked immediately before Process.run. This rejects leaf replacement,
    /// symlink introduction and permission drift after configuration creation.
    fileprivate func remainsSafeToLaunch() -> Bool {
        guard passesHelperPath, let ids = identities,
              Self.securePython(python) != nil, Self.secureHelper(helper) != nil,
              Self.secureDirectory(model) != nil, Self.secureDirectory(audioRoot, exact0700: true) != nil,
              let pi = Self.identity(python), let hi = Self.identity(helper), let mi = Self.identity(model), let ai = Self.identity(audioRoot) else { return false }
        if let imports = isolatedImportRoot {
            guard let current = Self.secureDirectory(imports), let ii = Self.identity(current), ii == ids.imports else { return false }
        } else if ids.imports != nil { return false }
        return pi == ids.python && hi == ids.helper && mi == ids.model && ai == ids.audio
    }
}
/// Direct Process launch: no shell or PATH lookup. stderr is drained only to a
/// byte count; no stderr/audio/transcript/path bytes are retained.
public enum HelperTerminationOutcome: Sendable, Equatable { case none, graceful, forced, reaped, outcomeUnknown }
public final class ProcessHelperTransport: HelperTransport, @unchecked Sendable {
    deinit {
        lock.lock()
        let session: Session?
        switch lifecycle { case .running(let value): session = value; case .stopping(let value, _): session = value; default: session = nil }
        lock.unlock()
        // Best-effort fail-safe: explicit shutdown remains the normal contract.
        if let session {
            session.stop.signal(); session.inputFD.close()
            DispatchQueue.global(qos: .utility).async {
                _ = kill(session.process.processIdentifier, SIGTERM)
                if !session.exitLatch.wait(milliseconds: 150) { _ = kill(session.process.processIdentifier, SIGKILL); _ = session.exitLatch.wait(milliseconds: 2_000) }
                session.readers.wait()
                session.outputFD.close(); session.errorFD.close()
            }
        }
    }
    private final class PendingReply: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
        func finish(_ result: Result<Data, Error>) {
            lock.lock(); let value = continuation; continuation = nil; lock.unlock()
            guard let value else { return }
            switch result { case .success(let data): value.resume(returning: data); case .failure(let error): value.resume(throwing: error) }
        }
    }
    /// Harness-only rendezvous after ownership is installed and before stdin write.
    public final class TestWriteBarrier: @unchecked Sendable {
        private let installed = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        public init() {}
        public func waitUntilInstalled(timeout: DispatchTime = .now() + .seconds(2)) -> Bool { installed.wait(timeout: timeout) == .success }
        public func releaseWrite() { release.signal() }
        fileprivate func awaitWrite() { installed.signal(); _ = release.wait(timeout: .now() + .seconds(2)) }
    }
    /// Harness-only barrier proving that all termination callers share one stop.
    public final class TestStopBarrier: @unchecked Sendable {
        private let stopped = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        public init() {}
        public func waitUntilStopping(timeout: DispatchTime = .now() + .seconds(2)) -> Bool { stopped.wait(timeout: timeout) == .success }
        public func releaseReaper() { release.signal() }
        fileprivate func awaitReaper() { stopped.signal(); _ = release.wait(timeout: .now() + .seconds(2)) }
    }
    public final class TestReaderLeaveBarrier: @unchecked Sendable {
        private let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        public init() {}
        public func waitUntilReaderBlocked(timeout: DispatchTime = .now() + .seconds(3)) -> Bool { entered.wait(timeout: timeout) == .success }
        public func releaseReader() { release.signal() }
        fileprivate func awaitLeave() { entered.signal(); _ = release.wait(timeout: .now() + .seconds(5)) }
    }
    private final class ExitLatch: @unchecked Sendable {
        private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
        private var didExit = false
        func signal() { lock.lock(); guard !didExit else { lock.unlock(); return }; didExit = true; lock.unlock(); semaphore.signal() }
        func wait(milliseconds: Int) -> Bool {
            lock.lock(); if didExit { lock.unlock(); return true }; lock.unlock()
            return semaphore.wait(timeout: .now() + .milliseconds(milliseconds)) == .success
        }
    }
    private final class StopSignal: @unchecked Sendable { private let lock = NSLock(); private var stopped = false; func signal() { lock.lock(); stopped = true; lock.unlock() }; func isSet() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped } }
    private final class RawFD: @unchecked Sendable {
        private let lock = NSLock(); private var value: Int32
        init(_ value: Int32) { self.value = value }
        func descriptor() -> Int32 { lock.lock(); defer { lock.unlock() }; return value }
        func close() { lock.lock(); let fd = value; value = -1; lock.unlock(); if fd >= 0 { _ = Darwin.close(fd) } }
        deinit { close() }
    }
    private final class StopTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var result: HelperTerminationOutcome?
        private var waiters: [CheckedContinuation<HelperTerminationOutcome, Never>] = []
        func complete(_ value: HelperTerminationOutcome) {
            lock.lock(); guard result == nil else { lock.unlock(); return }
            result = value; let values = waiters; waiters.removeAll(); lock.unlock()
            values.forEach { $0.resume(returning: value) }
        }
        func wait() async -> HelperTerminationOutcome {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result { lock.unlock(); continuation.resume(returning: result) }
                else { waiters.append(continuation); lock.unlock() }
            }
        }
    }
    private final class Session: @unchecked Sendable {
        let process: Process
        let inputFD: RawFD
        let outputFD: RawFD
        let errorFD: RawFD
        let stop = StopSignal()
        let generation: UInt64
        let exitLatch: ExitLatch
        let readers = DispatchGroup()
        init(process: Process, inputFD: Int32, outputFD: Int32, errorFD: Int32, generation: UInt64, exitLatch: ExitLatch) {
            self.process = process; self.inputFD = RawFD(inputFD); self.outputFD = RawFD(outputFD); self.errorFD = RawFD(errorFD); self.generation = generation; self.exitLatch = exitLatch
        }
    }
    private enum Lifecycle {
        case idle
        case running(Session)
        case stopping(Session, StopTicket)
        case stopped(HelperTerminationOutcome)
    }
    private let config: HelperLaunchConfiguration
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "klangschrift.helper.writer")
    private let reader = DispatchQueue(label: "klangschrift.helper.reader")
    private let stderrReader = DispatchQueue(label: "klangschrift.helper.stderr")
    private let reaper = DispatchQueue(label: "klangschrift.helper.reaper")
    private var lifecycle: Lifecycle = .idle
    private var pending: (generation: UInt64, token: UInt64, reply: PendingReply)?
    private var nextToken: UInt64 = 0
    private var nextGeneration: UInt64 = 0
    private var activeWriteLeases = 0
    private var inputClosed = false
    private var poisoned = false
    public private(set) var stderrByteCount = 0
    private var spawnedPID: pid_t = 0
    private var outcome: HelperTerminationOutcome = .none

    private let testWriteBarrier: TestWriteBarrier?
    private let testStopBarrier: TestStopBarrier?
    private let testDuplicateFailureIndex: Int?
    private let testRollbackConfirmationFailure: Bool
    private let testReaderJoinTimeout: Bool
    private let testReaderLeaveBarrier: TestReaderLeaveBarrier?
    private let testLaunchBarrier: (@Sendable () -> Void)?
    private let testSiteIsolationOverride: Bool?
    private let testEnvironmentOverrides: [String: String]
    public init(config: HelperLaunchConfiguration, testWriteBarrier: TestWriteBarrier? = nil, testStopBarrier: TestStopBarrier? = nil, testDuplicateFailureIndex: Int? = nil, testRollbackConfirmationFailure: Bool = false, testReaderJoinTimeout: Bool = false, testReaderLeaveBarrier: TestReaderLeaveBarrier? = nil, testLaunchBarrier: (@Sendable () -> Void)? = nil, testSiteIsolationOverride: Bool? = nil, testEnvironmentOverrides: [String: String] = [:]) { self.config = config; self.testWriteBarrier = testWriteBarrier; self.testStopBarrier = testStopBarrier; self.testDuplicateFailureIndex = testDuplicateFailureIndex; self.testRollbackConfirmationFailure = testRollbackConfirmationFailure; self.testReaderJoinTimeout = testReaderJoinTimeout; self.testReaderLeaveBarrier = testReaderLeaveBarrier; self.testLaunchBarrier = testLaunchBarrier; self.testSiteIsolationOverride = testSiteIsolationOverride; self.testEnvironmentOverrides = testEnvironmentOverrides }

    public func diagnostics() -> (pid: pid_t, outcome: HelperTerminationOutcome, stderrBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (spawnedPID, outcome, stderrByteCount)
    }
    public func testOwnedFDs() -> (Int32, Int32, Int32) { lock.lock(); defer { lock.unlock() }; switch lifecycle { case .running(let s), .stopping(let s, _): return (s.inputFD.descriptor(), s.outputFD.descriptor(), s.errorFD.descriptor()); default: return (-1,-1,-1) } }
    /// Harness-only stale-reader seam. A callback from any old generation must
    /// be ignored after that session has stopped.
    public func testInjectStaleReaderFailure(generation: UInt64) { readerFailed(HelperProtocolError.prematureEOF, generation: generation) }

    private static func readExact(_ descriptor: Int32, _ count: Int, stop: StopSignal) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: min(8_192, count))
        while out.count < count {
            if stop.isSet() { throw HelperProtocolError.outcomeUnknown }
            var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let polled = Darwin.poll(&pollFD, 1, 50)
            if polled == 0 { continue }
            guard polled > 0, (pollFD.revents & Int16(POLLNVAL)) == 0 else { throw HelperProtocolError.prematureEOF }
            let requested = min(buffer.count, count - out.count)
            let readCount = Darwin.read(descriptor, &buffer, requested)
            if readCount > 0 { out.append(buffer, count: Int(readCount)); continue }
            if readCount == -1 && Darwin.errno == EINTR { continue }
            throw HelperProtocolError.prematureEOF
        }
        return out
    }

    /// Launch and publish atomically before either reader can observe the pipes.
    private func ensureLaunchedLocked(measurement: inout (at: UInt64, new: Bool)?) throws -> Session {
        if case .running(let session) = lifecycle { measurement = (DispatchTime.now().uptimeNanoseconds, false); return session }
        guard case .idle = lifecycle, !poisoned else { throw HelperProtocolError.outcomeUnknown }
        guard !config.passesHelperPath || config.remainsSafeToLaunch() else { throw HelperProtocolError.invalidSchema }
        testLaunchBarrier?()
        guard !config.passesHelperPath || config.remainsSafeToLaunch() else { throw HelperProtocolError.invalidSchema }
        let p = Process()
        p.executableURL = config.python
        let isolatesSite = testSiteIsolationOverride ?? (config.isolatedImportRoot != nil)
        p.arguments = (config.passesHelperPath ? (isolatesSite ? ["-S", config.helper.path] : [config.helper.path]) : []) + config.extraArguments
        var environment = ["HF_HUB_OFFLINE":"1", "TRANSFORMERS_OFFLINE":"1", "HF_HUB_DISABLE_TELEMETRY":"1", "PYTHONDONTWRITEBYTECODE":"1", "PYTHONNOUSERSITE":"1", "KLANGSCHRIFT_MODEL_PATH":config.model.path, "KLANGSCHRIFT_AUDIO_ROOT":config.audioRoot.path, "KLANGSCHRIFT_MODEL_CONFIG_SHA256":config.configHash, "KLANGSCHRIFT_MODEL_WEIGHTS_SHA256":config.weightsHash, "LANG":"C"]
        if let imports = config.isolatedImportRoot { environment["PYTHONPATH"] = imports.path }
        // Test-only negative control: proves the production -S contract with
        // actual site producers without changing the default launch surface.
        if testSiteIsolationOverride == false { environment.removeValue(forKey: "PYTHONNOUSERSITE") }
        testEnvironmentOverrides.forEach { environment[$0.key] = $0.value }
        p.environment = environment
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i; p.standardOutput = o; p.standardError = e
        let latch = ExitLatch()
        p.terminationHandler = { _ in latch.signal() }
        try p.run()
        measurement = (DispatchTime.now().uptimeNanoseconds, true)
        // Process retains the Pipe objects. Close the parent's unused ends
        // immediately, otherwise they keep stdout/stderr artificially open
        // and a reader can never observe EOF after the helper exits.
        // Duplicate the three parent endpoints and then close every FileHandle
        // owner exactly once. The session owns only these CLOEXEC raw FDs.
        spawnedPID = p.processIdentifier
        func duplicate(_ descriptor: Int32, _ index: Int) -> Int32 { testDuplicateFailureIndex == index ? -1 : fcntl(descriptor, F_DUPFD_CLOEXEC, 3) }
        let inputFD = duplicate(i.fileHandleForWriting.fileDescriptor, 1)
        let outputFD = duplicate(o.fileHandleForReading.fileDescriptor, 2)
        let errorFD = duplicate(e.fileHandleForReading.fileDescriptor, 3)
        guard inputFD >= 0, outputFD >= 0, errorFD >= 0 else {
            for descriptor in [inputFD, outputFD, errorFD] where descriptor >= 0 { _ = Darwin.close(descriptor) }
            p.terminate()
            let rollback: HelperTerminationOutcome
            if testRollbackConfirmationFailure { _ = kill(p.processIdentifier, SIGKILL); _ = latch.wait(milliseconds: 2_000); rollback = .outcomeUnknown }
            else if latch.wait(milliseconds: 150) { rollback = .graceful }
            else if kill(p.processIdentifier, SIGKILL) == 0, latch.wait(milliseconds: 2_000) { rollback = .forced }
            else { rollback = .outcomeUnknown }
            lifecycle = .stopped(rollback); outcome = rollback; throw HelperProtocolError.outcomeUnknown
        }
        i.fileHandleForReading.closeFile(); i.fileHandleForWriting.closeFile()
        o.fileHandleForReading.closeFile(); o.fileHandleForWriting.closeFile()
        e.fileHandleForReading.closeFile(); e.fileHandleForWriting.closeFile()
        nextGeneration &+= 1
        let session = Session(process: p, inputFD: inputFD, outputFD: outputFD, errorFD: errorFD, generation: nextGeneration, exitLatch: latch)
        lifecycle = .running(session); spawnedPID = p.processIdentifier; outcome = .none; inputClosed = false; activeWriteLeases = 0
        startStdoutReader(session)
        startStderrReader(session)
        return session
    }

    private func startStderrReader(_ session: Session) {
        session.readers.enter()
        let descriptor = session.errorFD.descriptor(), generation = session.generation, group = session.readers, stop = session.stop
        stderrReader.async { [weak self, descriptor, group] in
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                if stop.isSet() { return }
                var pollFD = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let polled = Darwin.poll(&pollFD, 1, 50)
                if polled == 0 { continue }; guard polled > 0 else { return }
                let readCount = Darwin.read(descriptor, &buffer, buffer.count)
                if readCount == 0 { return }
                if readCount == -1 && Darwin.errno == EINTR { continue }
                guard readCount > 0 else { return }
                // Hold a strong local only after the blocking read returned;
                // never leave a lock held if a weak transport disappears.
                guard let transport = self else { return }
                transport.lock.lock()
                if transport.isCurrentLocked(generation) { transport.stderrByteCount = min(65_536, transport.stderrByteCount + Int(readCount)) }
                transport.lock.unlock()
            }
        }
    }

    private func startStdoutReader(_ session: Session) {
        session.readers.enter()
        let descriptor = session.outputFD.descriptor(), generation = session.generation, group = session.readers, stop = session.stop
        let leaveBarrier = testReaderLeaveBarrier
        reader.async { [weak self, descriptor, group, leaveBarrier] in
            defer { leaveBarrier?.awaitLeave(); group.leave() }
            while true {
                do {
                    let header = try Self.readExact(descriptor, 4, stop: stop)
                    let count = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                    guard count > 0 && count <= UInt32(HelperFrame.maximumBytes) else { throw HelperProtocolError.oversizedFrame }
                    let payload = try Self.readExact(descriptor, Int(count), stop: stop)
                    var frame = header; frame.append(payload)
                    self?.deliver(frame, generation: generation)
                } catch {
                    self?.readerFailed(error, generation: generation)
                    return
                }
            }
        }
    }

    /// The only pending-continuation owner transfer. Call while `lock` is held.
    private func isCurrentLocked(_ generation: UInt64) -> Bool {
        switch lifecycle { case .running(let session): return session.generation == generation; case .stopping(let session, _): return session.generation == generation; default: return false }
    }
    private func takePendingLocked(generation: UInt64? = nil, token: UInt64? = nil) -> PendingReply? {
        guard let value = pending, generation == nil || value.generation == generation, token == nil || value.token == token else { return nil }
        pending = nil
        return value.reply
    }

    private func deliver(_ frame: Data, generation: UInt64) {
        lock.lock()
        guard case .running(let session) = lifecycle, session.generation == generation else { lock.unlock(); return }
        let continuation = takePendingLocked(generation: generation)
        if continuation == nil { poisoned = true }
        lock.unlock()
        if let continuation { continuation.finish(.success(frame)) }
        else { _ = requestStop(reason: HelperProtocolError.outcomeUnknown) }
    }

    private func readerFailed(_ failure: Error, generation: UInt64) {
        lock.lock()
        guard isCurrentLocked(generation) else { lock.unlock(); return }
        let continuation = takePendingLocked(generation: generation); poisoned = true
        lock.unlock()
        continuation?.finish(.failure(failure))
        _ = requestStop(reason: failure)
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        guard data.count <= HelperFrame.maximumBytes + 4 else { throw HelperProtocolError.oversizedFrame }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw HelperProtocolError.outcomeUnknown }
        let currentFlags = fcntl(descriptor, F_GETFL)
        guard currentFlags >= 0, fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else { throw HelperProtocolError.outcomeUnknown }
        defer { _ = fcntl(descriptor, F_SETFL, currentFlags) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw HelperProtocolError.invalidFrame }
            var offset = 0
            let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
            while offset < raw.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw HelperProtocolError.outcomeUnknown }
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written > 0 { offset += written; guard DispatchTime.now().uptimeNanoseconds < deadline else { throw HelperProtocolError.outcomeUnknown }; continue }
                if written == -1 && Darwin.errno == EINTR { continue }
                if written == -1 && (Darwin.errno == EAGAIN || Darwin.errno == EWOULDBLOCK) {
                    var pollFD = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { throw HelperProtocolError.outcomeUnknown }
                    let milliseconds = Int(min((deadline - now) / 1_000_000, 50))
                    let polled = Darwin.poll(&pollFD, 1, Int32(max(1, milliseconds)))
                    guard polled > 0, (pollFD.revents & (Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL))) == 0 else { throw HelperProtocolError.outcomeUnknown }
                    continue
                }
                throw HelperProtocolError.outcomeUnknown
            }
        }
    }

    public func exchange(_ request: Data) async throws -> Data {
        let perf = PerfLog.current
        return try await withCheckedThrowingContinuation { continuation in
            // Construct ownership before any asynchronous launch/write path.
            // Every route below can therefore finish this same idempotent box.
            let reply = PendingReply(continuation)
            writer.async { [weak self] in
                guard let self else { reply.finish(.failure(HelperProtocolError.outcomeUnknown)); return }
                var token: UInt64?
                var assigned: UInt64 = 0
                var measurement: (at: UInt64, new: Bool)?
                do {
                    self.lock.lock()
                    let session: Session
                    do {
                        session = try self.ensureLaunchedLocked(measurement: &measurement)
                        guard !self.poisoned, self.pending == nil, case .running(let current) = self.lifecycle, current === session else { throw HelperProtocolError.outcomeUnknown }
                        self.nextToken &+= 1
                        assigned = self.nextToken
                        token = assigned
                        self.pending = (session.generation, assigned, reply)
                        self.lock.unlock()
                    } catch {
                        self.lock.unlock()
                        throw error
                    }
                    if let measurement { perf?.mark(.workerSpawned, newWorker: measurement.new, atNanoseconds: measurement.at) }
                    self.testWriteBarrier?.awaitWrite()
                    // Cancellation can close stdin while a test barrier holds
                    // this writer. Re-check ownership before Foundation write,
                    // which otherwise raises an Objective-C pipe exception.
                    self.lock.lock()
                    guard case .running(let current) = self.lifecycle, current === session,
                          self.pending?.generation == session.generation, self.pending?.token == assigned else { self.lock.unlock(); throw HelperProtocolError.outcomeUnknown }
                    self.activeWriteLeases += 1
                    self.lock.unlock()
                    do { try self.writeAll(request, descriptor: session.inputFD.descriptor()) }
                    catch { self.releaseWriteLease(session); throw error }
                    self.releaseWriteLease(session)
                } catch {
                    self.lock.lock()
                    // A reader or cancellation may already own the continuation.
                    let waiting = token.flatMap { self.takePendingLocked(token: $0) }
                    self.poisoned = true
                    self.lock.unlock()
                    // Always finish the locally owned box. If cancellation or
                    // the reader won already, PendingReply makes this a no-op.
                    // `reply` is always available, including launch failure.
                    // If another route already completed it, finish is a no-op.
                    waiting?.finish(.failure(error))
                    reply.finish(.failure(error))
                    _ = self.requestStop(reason: error)
                }
            }
        }
    }

    private func requestStop(reason: Error) -> StopTicket? {
        lock.lock()
        switch lifecycle {
        case .stopping(_, let ticket): lock.unlock(); return ticket
        case .stopped: lock.unlock(); return nil
        case .idle:
            lifecycle = .stopped(.reaped); outcome = .reaped; lock.unlock(); return nil
        case .running(let session):
            let ticket = StopTicket(); lifecycle = .stopping(session, ticket); poisoned = true
            let waiting = takePendingLocked(generation: session.generation)
            lock.unlock()
            waiting?.finish(.failure(reason))
            // A writer lease keeps the raw input FD valid through its bounded
            // nonblocking write. The final lease release performs this close.
            closeInputIfReady(session)
            // The reaper is the explicit shutdown owner and deliberately
            // retains the transport until its bounded cleanup has completed.
            reaper.async { [self, session, ticket] in performReap(session: session, ticket: ticket) }
            return ticket
        }
    }

    private func performReap(session: Session, ticket: StopTicket) {
        testStopBarrier?.awaitReaper()
        session.stop.signal()
        var result: HelperTerminationOutcome
        if session.exitLatch.wait(milliseconds: 0) {
            result = .reaped
        } else {
            _ = kill(session.process.processIdentifier, SIGTERM)
            if session.exitLatch.wait(milliseconds: 150) { result = .graceful }
            else {
                _ = kill(session.process.processIdentifier, SIGKILL)
                result = session.exitLatch.wait(milliseconds: 2_000) ? .forced : .outcomeUnknown
            }
        }
        // After the child is known dead (or bounded reaping has failed), close
        // our read descriptors so the reader group cannot retain a pipe end.
        // Raw close avoids Foundation exceptions from cross-queue FileHandle use.
        let drained = !testReaderJoinTimeout && session.readers.wait(timeout: .now() + .seconds(2)) == .success
        if !drained { result = .outcomeUnknown }
        // Readers have stopped or their bounded join failed; RawFD owns each
        // close exactly once and no reader is cross-thread interrupted.
        if drained { session.outputFD.close(); session.errorFD.close() }
        else {
            // Preserve ownership until active polling readers have observed the
            // stop signal. Never reuse-close their descriptors cross-thread.
            reaper.async { [session] in session.readers.wait(); session.outputFD.close(); session.errorFD.close() }
        }
        lock.lock()
        if case .stopping(let current, let currentTicket) = lifecycle, current === session, currentTicket === ticket {
            lifecycle = .stopped(result); outcome = result
        }
        lock.unlock()
        ticket.complete(result)
    }

    private func releaseWriteLease(_ session: Session) {
        lock.lock(); activeWriteLeases -= 1; closeInputIfReadyLocked(session); lock.unlock()
    }
    private func closeInputIfReady(_ session: Session) { lock.lock(); closeInputIfReadyLocked(session); lock.unlock() }
    private func closeInputIfReadyLocked(_ session: Session) {
        guard !inputClosed, activeWriteLeases == 0 else { return }
        if case .stopping(let current, _) = lifecycle, current === session { inputClosed = true; session.inputFD.close() }
    }

    private func stoppedOutcome() -> HelperTerminationOutcome {
        lock.lock(); defer { lock.unlock() }
        if case .stopped(let value) = lifecycle { return value }
        return .outcomeUnknown
    }

    public func terminateAndReap() async -> HelperTerminationOutcome {
        if let ticket = requestStop(reason: HelperProtocolError.outcomeUnknown) { return await ticket.wait() }
        return stoppedOutcome()
    }
}
public enum HelperStatus:Sendable,Equatable {case configured,prepared,misconfigured,silence,ok(text:String?),shutdown}
public enum HelperClientFailure: Error, Equatable, Sendable { case operationAndTermination(operation: HelperProtocolError, termination: HelperTerminationOutcome) }
public struct HelperRequestDeadlines: Sendable {
    public let health: UInt64, prepare: UInt64, transcribe: UInt64, shutdown: UInt64
    public init(health: UInt64 = 30_000_000_000, prepare: UInt64 = 180_000_000_000, transcribe: UInt64 = 600_000_000_000, shutdown: UInt64 = 10_000_000_000) {
        self.health = health; self.prepare = prepare; self.transcribe = transcribe; self.shutdown = shutdown
    }
    func nanoseconds(for operation: HelperOperation) -> UInt64 {
        switch operation { case .health: health; case .prepare: prepare; case .transcribe: transcribe; case .shutdown: shutdown }
    }
}
public actor HelperProcessClient {
    private let transport: any HelperTransport; private var usable = true
    private var terminationTask: Task<HelperTerminationOutcome, Never>?
    private let deadlines: HelperRequestDeadlines
    public init(transport: any HelperTransport, deadlines: HelperRequestDeadlines = .init()) { self.transport = transport; self.deadlines = deadlines }
    public func request(id: String, operation: HelperOperation, audioPath: String? = nil, language: String? = nil) async throws -> HelperStatus {
        try await requestWithTimeout(id: id, operation: operation, nanoseconds: deadlines.nanoseconds(for: operation), audioPath: audioPath, language: language)
    }
    private func validate(id: String, language: String?) throws {
        guard usable else { throw HelperProtocolError.outcomeUnknown }
        guard id.range(of:"^[A-Za-z0-9_-]{1,64}$", options:.regularExpression) != nil,
              language == nil || ["auto", "de", "en", "fr", "es", "it", "pt", "nl"].contains(language!) else { throw HelperProtocolError.invalidSchema }
    }
    private func exchangeRequest(id: String, operation: HelperOperation, audioPath: String? = nil, language: String? = nil) async throws -> HelperStatus {
        guard usable else { throw HelperProtocolError.outcomeUnknown }
        guard id.range(of:"^[A-Za-z0-9_-]{1,64}$", options:.regularExpression) != nil,
              language == nil || ["auto", "de", "en", "fr", "es", "it", "pt", "nl"].contains(language!) else { throw HelperProtocolError.invalidSchema }
        do {
            let reply = try await transport.exchange(HelperFrame.encode(HelperRequest(id:id, op:operation, audioPath:audioPath, language:language)))
            let response = try HelperFrame.decode(reply, as:HelperResponse.self)
            guard response.version == 1, response.id == id, (response.text?.count ?? 0) <= 100_000 else { throw HelperProtocolError.invalidSchema }
            let status: HelperStatus
            switch (operation, response.status) {
            case (.health,.configured): status = .configured; case (.health,.prepared): status = .prepared; case (.health,.misconfigured): status = .misconfigured
            case (.prepare,.prepared): status = .prepared; case (.transcribe,.silence) where response.text == nil || response.text == "": status = .silence
            case (.transcribe,.ok) where !(response.text ?? "").isEmpty: status = .ok(text:response.text)
            case (.shutdown,.shutdown): status = .shutdown
            default: throw HelperProtocolError.invalidSchema
            }
            if operation == .shutdown {
                usable = false
                let outcome = await terminateOnce()
                if outcome == .outcomeUnknown { throw HelperClientFailure.operationAndTermination(operation:.outcomeUnknown, termination:outcome) }
            }
            return status
        } catch {
            usable = false
            let outcome = await terminateOnce()
            throw HelperClientFailure.operationAndTermination(operation: Self.code(error), termination: outcome)
        }
    }
    public func requestWithTimeout(id: String, operation: HelperOperation, nanoseconds: UInt64, audioPath: String? = nil, language: String? = nil) async throws -> HelperStatus {
        try validate(id: id, language: language)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(clamping: nanoseconds)))
        return try await withThrowingTaskGroup(of: HelperStatus.self) { group in
            group.addTask { try await self.exchangeRequest(id: id, operation: operation, audioPath: audioPath, language: language) }
            group.addTask { try await clock.sleep(until: deadline); throw HelperProtocolError.outcomeUnknown }
            defer { group.cancelAll() }
            do {
                guard let status = try await group.next(), clock.now < deadline else { throw HelperProtocolError.outcomeUnknown }
                return status
            } catch {
                group.cancelAll()
                let outcome = await cancelOrTimeout()
                throw HelperClientFailure.operationAndTermination(operation: Self.code(error), termination: outcome)
            }
        }
    }
    private func terminateOnce() async -> HelperTerminationOutcome {
        if let terminationTask { return await terminationTask.value }
        let task = Task { await transport.terminateAndReap() }
        terminationTask = task
        return await task.value
    }
    public func cancelOrTimeout() async -> HelperTerminationOutcome { usable = false; return await terminateOnce() }
    public func canStartFresh() -> Bool { usable }
    private static func code(_ error: Error) -> HelperProtocolError {
        if let code = error as? HelperProtocolError { return code }
        if case .operationAndTermination(let operation, _) = error as? HelperClientFailure { return operation }
        return .outcomeUnknown
    }
}
public struct TranscriptionJobOutcome: Equatable, Sendable {
    public enum Cleanup: Equatable, Sendable { case removed; case retryRequired(AudioArtifactCleanupFailure) }
    public let status: HelperStatus
    public let cleanup: Cleanup
    public init(status: HelperStatus, cleanup: Cleanup) { self.status=status; self.cleanup=cleanup }
}
/// The operation code is closed and content-free, so helper output can never
/// enter a cleanup diagnostic through this error path.
public enum TranscriptionJobFailure: Error, Equatable, Sendable {
    case operationAndCleanup(operation: HelperProtocolError, cleanup: AudioArtifactCleanupFailure)
    case operationAndTermination(operation: HelperProtocolError, termination: HelperTerminationOutcome)
    case operationTerminationAndCleanup(operation: HelperProtocolError, termination: HelperTerminationOutcome, cleanup: AudioArtifactCleanupFailure)
}
public struct TranscriptionJob: Sendable {
    public let artifact: OwnedAudioArtifact; public let client: HelperProcessClient
    public init(artifact: OwnedAudioArtifact, client: HelperProcessClient) { self.artifact = artifact; self.client = client }
    public func run(id: String, timeout: UInt64) async throws -> TranscriptionJobOutcome {
        let operation: Result<HelperStatus, Error>
        do { operation = .success(try await client.requestWithTimeout(id: id, operation: .transcribe, nanoseconds: timeout)) }
        catch { operation = .failure(error) }
        do { try artifact.cleanup() }
        catch let failure as AudioArtifactCleanupFailure {
            switch operation {
            case .success(let status): return TranscriptionJobOutcome(status: status, cleanup: .retryRequired(failure))
            case .failure(let error):
                if case .operationAndTermination(let operation, let termination) = error as? HelperClientFailure { throw TranscriptionJobFailure.operationTerminationAndCleanup(operation:operation, termination:termination, cleanup:failure) }
                throw TranscriptionJobFailure.operationAndCleanup(operation: Self.safeOperationCode(error), cleanup: failure)
            }
        }
        switch operation {
        case .success(let status): return TranscriptionJobOutcome(status: status, cleanup: .removed)
        case .failure(let error):
            if case .operationAndTermination(let operation, let termination) = error as? HelperClientFailure { throw TranscriptionJobFailure.operationAndTermination(operation:operation, termination:termination) }
            throw error
        }
    }
    private static func safeOperationCode(_ error: Error) -> HelperProtocolError { (error as? HelperProtocolError) ?? .outcomeUnknown }
}
