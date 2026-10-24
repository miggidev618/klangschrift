import CryptoKit
import Foundation

public enum DictationModelInstallState: Sendable, Equatable { case idle, downloading(received: Int, total: Int), installed, cancelled, failed }
public struct DictationModelDownloadFile: Sendable, Codable { public let name: String; public let url: URL; public let bytes: Int; public let sha256: String }
public protocol DictationModelDownloadTransport: Sendable {
    func fetch(_ file: DictationModelDownloadFile, progress: @escaping @Sendable (Int) -> Void) async throws -> URL
}
public struct URLSessionModelTransport: DictationModelDownloadTransport {
    public init() {}
    public func fetch(_ file: DictationModelDownloadFile, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        let transfer = ModelFileTransfer(progress: progress)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await transfer.start(file.url)
        } onCancel: { transfer.cancel() }
    }
}
enum ModelDownloadHTTPSPolicy {
    static func acceptedRedirect(_ request: URLRequest) -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
    static func acceptsResponse(_ response: URLResponse?) -> Bool {
        response?.url?.scheme?.lowercased() == "https"
    }
}
private final class ModelFileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private let progress: @Sendable (Int) -> Void
    init(progress: @escaping @Sendable (Int) -> Void) { self.progress = progress }
    func start(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("Klangschrift/0.3 (iOS; offline model download)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: request); self.task = task; task.resume()
        }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress(Int(totalBytesWritten)) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(ModelDownloadHTTPSPolicy.acceptedRedirect(request))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard ModelDownloadHTTPSPolicy.acceptsResponse(downloadTask.response),
                  (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let saved = FileManager.default.temporaryDirectory.appendingPathComponent("klangschrift-download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: saved)
            lock.lock(); let wasCancelled = cancelled; lock.unlock()
            if wasCancelled { try? FileManager.default.removeItem(at: saved); finish(.failure(CancellationError())) }
            else { finish(.success(saved)) }
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if let error { finish(.failure(error)) } }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: result); session?.finishTasksAndInvalidate()
    }
}

/// A stage is private to one operation. Published models are never removed or replaced.
public actor DictationModelInstaller {
    private let transport: any DictationModelDownloadTransport
    private var operation: UUID?
    private var activeModel: DictationModelID?
    private var activeTask: Task<Void, Error>?
    public private(set) var lastError: String?
    public init(transport: any DictationModelDownloadTransport = URLSessionModelTransport()) { self.transport = transport }
    public func cancel(_ model: DictationModelID) { guard activeModel == model else { return }; activeTask?.cancel() }
    public func install(_ model: DictationModelID, progress: @escaping @Sendable (DictationModelInstallState) -> Void) async -> DictationModelInstallState {
        guard operation == nil, let entry = DictationModelCatalog.entry(model) else { return .failed }
        let id = UUID(); operation = id; activeModel = model; lastError = nil
        defer { activeTask = nil; operation = nil; activeModel = nil }
        let published = DictationModelStorage.directory(for: model)
        if FileManager.default.fileExists(atPath: published.path) {
            if DictationModelStorage.isInstalled(model) { progress(.installed); return .installed }
            lastError = "Das vorhandene Modell ist beschädigt. Es wurde nicht verändert."; progress(.failed); return .failed
        }
        let transport = transport
        let task = Task.detached {
            try await Self.stage(model: model, entry: entry, published: published, transport: transport, progress: progress)
        }
        activeTask = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            progress(.installed); return .installed
        } catch is CancellationError { progress(.cancelled); return .cancelled }
        catch {
            if task.isCancelled || (error as? URLError)?.code == .cancelled { progress(.cancelled); return .cancelled }
            lastError = error.localizedDescription; progress(.failed); return .failed
        }
    }
    static func exerciseFixture(files: [DictationModelDownloadFile], published: URL, transport: any DictationModelDownloadTransport) async throws {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        guard published.standardizedFileURL.path.hasPrefix(temporary), files.reduce(0, { $0 + $1.bytes }) <= 65_536 else { throw URLError(.badURL) }
        let entry = DictationModelCatalog.Entry(files: files, manifest: Data("{}".utf8))
        try await stage(model: .moonshineTinyStreamingDE, entry: entry, published: published, transport: transport, progress: { _ in }, fixture: true)
    }
    private static func stage(model: DictationModelID, entry: DictationModelCatalog.Entry, published: URL, transport: any DictationModelDownloadTransport, progress: @escaping @Sendable (DictationModelInstallState) -> Void, fixture: Bool = false) async throws {
        let fm = FileManager.default
        let root = published.deletingLastPathComponent()
        let stage = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stage) }
        try Task.checkCancellation()
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let total = entry.files.reduce(0) { $0 + $1.bytes }; var received = 0
        progress(.downloading(received: 0, total: total))
        for file in entry.files {
            guard validPath(file.name), file.url.scheme == "https", file.url.host != nil, file.bytes > 0 else { throw URLError(.badURL) }
            try Task.checkCancellation()
            let before = received
            let temporary = try await transport.fetch(file) { bytes in progress(.downloading(received: before + min(bytes, file.bytes), total: total)) }
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            let target = stage.appendingPathComponent(file.name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: temporary, to: target)
            guard try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == file.bytes, try hash(target) == file.sha256 else { throw LocalTranscriberError.modelMissing }
            received += file.bytes
            progress(.downloading(received: received, total: total))
        }
        try Task.checkCancellation()
        try entry.manifest.write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        if fixture {
            // Only the internal <=64 KiB temporary-directory harness reaches this.
            // Production always validates the immutable release manifest pin above.
            guard try Data(contentsOf: stage.appendingPathComponent("manifest.json")) == entry.manifest else { throw LocalTranscriberError.modelMissing }
        } else {
            try DictationModelManifest.validate(model, directory: stage)
        }
        try Task.checkCancellation()
        guard !fm.fileExists(atPath: published.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.moveItem(at: stage, to: published)
    }
    static func validPath(_ path: String) -> Bool { !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
