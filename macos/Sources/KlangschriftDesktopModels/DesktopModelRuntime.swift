import KlangschriftCore
import CryptoKit
import Foundation
import KlangschriftDesktopModelCatalog

/// AP04's app-local, immutable download contract.  It never discovers model
/// metadata at runtime: every byte, path, URL and digest is fixed beforehand.
public struct DesktopModelSourceFile: Sendable, Codable, Equatable, Hashable {
    public let relativePath: String
    public let url: URL
    public let bytes: Int
    public let sha256: String

    public init(relativePath: String, url: URL, bytes: Int, sha256: String) {
        self.relativePath = relativePath
        self.url = url
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct DesktopModelInstallManifest: Sendable, Codable, Equatable {
    public let modelID: String
    public let revision: String
    public let totalBytes: Int
    public let sourceFiles: [DesktopModelSourceFile]
    /// Exact checked-in activation document bytes. This must hash to the AP03
    /// artifact manifest digest; semantic JSON regeneration is not accepted.
    public let activationManifest: Data
    public let expectedManifestSHA256: String

    public init(modelID: String, revision: String, totalBytes: Int, sourceFiles: [DesktopModelSourceFile], activationManifest: Data, expectedManifestSHA256: String) {
        self.modelID = modelID
        self.revision = revision
        self.totalBytes = totalBytes
        self.sourceFiles = sourceFiles
        self.activationManifest = activationManifest
        self.expectedManifestSHA256 = expectedManifestSHA256
    }

    public func validateDefinition() throws {
        guard !modelID.isEmpty, !revision.isEmpty, totalBytes > 0, !sourceFiles.isEmpty,
              expectedManifestSHA256.count == 64, !activationManifest.isEmpty,
              Self.sha256(activationManifest) == expectedManifestSHA256 else { throw DesktopModelInstallError.invalidManifest }
        var names = Set<String>()
        var sum = 0
        for file in sourceFiles {
            guard Self.safeRelativePath(file.relativePath), names.insert(file.relativePath).inserted,
                  file.url.scheme?.lowercased() == "https", file.url.host != nil,
                  file.bytes > 0, file.sha256.count == 64 else { throw DesktopModelInstallError.invalidManifest }
            let (next, overflow) = sum.addingReportingOverflow(file.bytes)
            guard !overflow else { throw DesktopModelInstallError.invalidManifest }
            sum = next
        }
        guard sum == totalBytes else { throw DesktopModelInstallError.invalidManifest }
    }

    public var activationDirectoryName: String { "\(modelID)-\(revision)" }

    private static func safeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Decodes AP04's checked-in source manifest. The caller supplies the packaged
/// URL; no code path derives this data from iOS, a user cache, or the network.
public enum DesktopModelInstallCatalog {
    public static func manifests(from sourceURL: URL) throws -> [String: DesktopModelInstallManifest] {
        let records = try JSONDecoder().decode([SourceRecord].self, from: Data(contentsOf: sourceURL))
        let catalogue = Dictionary(uniqueKeysWithValues: DesktopModelCatalog.referenceModels.map { ($0.id, $0) })
        guard records.count == 22, Set(records.map(\.modelID)) == Set(catalogue.keys) else { throw DesktopModelInstallError.invalidManifest }
        var output: [String: DesktopModelInstallManifest] = [:]
        for record in records {
            guard let model = catalogue[record.modelID], record.revision == model.artifact.revision,
                  record.totalBytes == model.artifact.totalBytes, output[record.modelID] == nil else { throw DesktopModelInstallError.invalidManifest }
            let manifest = DesktopModelInstallManifest(
                modelID: record.modelID,
                revision: record.revision,
                totalBytes: record.totalBytes,
                sourceFiles: record.sourceFiles.map { .init(relativePath: $0.name, url: $0.url, bytes: $0.bytes, sha256: $0.sha256) },
                activationManifest: record.activationManifest,
                expectedManifestSHA256: model.artifact.manifestSHA256
            )
            try manifest.validateDefinition()
            output[record.modelID] = manifest
        }
        return output
    }

    private struct SourceRecord: Decodable {
        let modelID: String
        let revision: String
        let totalBytes: Int
        let sourceFiles: [SourceFile]
        let activationManifest: Data
        enum CodingKeys: String, CodingKey {
            case modelID = "model_id", revision, totalBytes = "total_bytes", sourceFiles = "source_files"
            case activationManifest = "activation_manifest_base64"
        }
    }

    private struct SourceFile: Decodable { let name: String; let url: URL; let bytes: Int; let sha256: String }
}

public enum DesktopModelInstallError: Error, Sendable, Equatable {
    case invalidManifest
    case insufficientSpace
    case downloadFailed
    case hashMismatch
    case byteCountMismatch
    case activationFailed
    case notInstalled
}

/// Presentation-safe installer progress. Byte counts are observed from the
/// staging files after transport returns; callers must not infer a percentage
/// until both counts are non-zero.
public enum DesktopModelInstallationPhase: String, Sendable, Equatable {
    case downloading
    case verifying
    case activating
}

public struct DesktopModelInstallationProgress: Sendable, Equatable {
    public let modelID: String
    public let phase: DesktopModelInstallationPhase
    public let completedBytes: Int
    public let totalBytes: Int
    public let completedFiles: Int
    public let totalFiles: Int

    public init(modelID: String, phase: DesktopModelInstallationPhase, completedBytes: Int, totalBytes: Int, completedFiles: Int, totalFiles: Int) {
        self.modelID = modelID
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
    }
}

/// A testable transport. Production is intentionally invoked only by an
/// explicit installer action; preload and transcription have no transport.
public protocol DesktopModelDownloadTransport: Sendable {
    func download(_ source: DesktopModelSourceFile, to destination: URL) async throws
}

public struct HTTPSDesktopModelDownloadTransport: DesktopModelDownloadTransport {
    public init() {}

    public func download(_ source: DesktopModelSourceFile, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: source.url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              response.url?.scheme?.lowercased() == "https" else { throw DesktopModelInstallError.downloadFailed }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

/// The installer owns only its versioned product directories.  It never scans,
/// overwrites, or deletes legacy MLX or user model locations.
public actor DesktopModelInstaller {
    public let root: URL
    private let transport: any DesktopModelDownloadTransport
    private let fileManager: FileManager

    public init(root: URL, transport: any DesktopModelDownloadTransport = HTTPSDesktopModelDownloadTransport(), fileManager: FileManager = .default) {
        self.root = root
        self.transport = transport
        self.fileManager = fileManager
    }

    public func destination(for manifest: DesktopModelInstallManifest) -> URL {
        root.appendingPathComponent(manifest.activationDirectoryName, isDirectory: true)
    }

    public func isInstalled(_ manifest: DesktopModelInstallManifest) -> Bool {
        (try? validateInstalled(manifest)) != nil
    }

    /// Creates a private bounded staging directory, verifies each fixed file,
    /// writes the deterministic activation manifest, then atomically moves it
    /// into a new versioned destination. Existing destinations are preserved.
    @discardableResult
    public func install(_ manifest: DesktopModelInstallManifest) async throws -> URL {
        try await install(manifest) { _ in }
    }

    /// Reports only fixed manifest counts and locally observed staging-file
    /// sizes. It never exposes source URLs or staging paths to presentation.
    @discardableResult
    public func install(
        _ manifest: DesktopModelInstallManifest,
        progress: @escaping @Sendable (DesktopModelInstallationProgress) async -> Void
    ) async throws -> URL {
        try manifest.validateDefinition()
        if isInstalled(manifest) { return destination(for: manifest) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try ensureFreeSpace(requiredBytes: manifest.totalBytes)
        let stagingParent = root.appendingPathComponent(".desktop-model-staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingParent, withIntermediateDirectories: true)
        let staging = stagingParent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var completedBytes = 0
            let totalFiles = manifest.sourceFiles.count
            for (index, source) in manifest.sourceFiles.enumerated() {
                try Task.checkCancellation()
                await progress(.init(modelID: manifest.modelID, phase: .downloading, completedBytes: completedBytes, totalBytes: manifest.totalBytes, completedFiles: index, totalFiles: totalFiles))
                let target = staging.appendingPathComponent(source.relativePath)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await transport.download(source, to: target)
                try Task.checkCancellation()
                let observedBytes = (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                completedBytes += observedBytes
                await progress(.init(modelID: manifest.modelID, phase: .verifying, completedBytes: completedBytes, totalBytes: manifest.totalBytes, completedFiles: index + 1, totalFiles: totalFiles))
                try verify(source, at: target)
            }
            await progress(.init(modelID: manifest.modelID, phase: .activating, completedBytes: completedBytes, totalBytes: manifest.totalBytes, completedFiles: totalFiles, totalFiles: totalFiles))
            try manifest.activationManifest.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try validateInstalled(manifest, directory: staging)
            let target = destination(for: manifest)
            guard !fileManager.fileExists(atPath: target.path) else {
                if isInstalled(manifest) { try? fileManager.removeItem(at: staging); return target }
                throw DesktopModelInstallError.activationFailed
            }
            try Task.checkCancellation()
            try fileManager.moveItem(at: staging, to: target)
            try validateInstalled(manifest, directory: target)
            return target
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func validateInstalled(_ manifest: DesktopModelInstallManifest) throws {
        try validateInstalled(manifest, directory: destination(for: manifest))
    }

    private func validateInstalled(_ manifest: DesktopModelInstallManifest, directory: URL) throws {
        try manifest.validateDefinition()
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL), Self.sha256(data) == manifest.expectedManifestSHA256 else {
            throw DesktopModelInstallError.notInstalled
        }
        var total = 0
        for source in manifest.sourceFiles {
            let file = directory.appendingPathComponent(source.relativePath)
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == source.bytes else {
                throw DesktopModelInstallError.byteCountMismatch
            }
            guard try Self.hash(of: file) == source.sha256 else { throw DesktopModelInstallError.hashMismatch }
            total += size
        }
        guard total == manifest.totalBytes else { throw DesktopModelInstallError.byteCountMismatch }
    }

    private func ensureFreeSpace(requiredBytes: Int) throws {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values.volumeAvailableCapacityForImportantUsage, free >= Int64(requiredBytes) else {
            throw DesktopModelInstallError.insufficientSpace
        }
    }

    private func verify(_ source: DesktopModelSourceFile, at url: URL) throws {
        guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == source.bytes else { throw DesktopModelInstallError.byteCountMismatch }
        guard try Self.hash(of: url) == source.sha256 else { throw DesktopModelInstallError.hashMismatch }
    }

    private static func hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Additive preference payload. It deliberately does not replace the legacy
/// MLX selection, so existing Large-v3/Turbo settings remain untouched.
public struct DesktopModelSettings: Codable, Sendable, Equatable {
    public var selectedModelID: String?
    public var favoriteModelIDs: [String]

    public init(selectedModelID: String? = nil, favoriteModelIDs: [String] = []) {
        self.selectedModelID = selectedModelID
        self.favoriteModelIDs = Array(NSOrderedSet(array: favoriteModelIDs).compactMap { $0 as? String }.prefix(2))
    }

    public mutating func select(_ id: String) { selectedModelID = id }
    public mutating func setFavorites(_ ids: [String]) { favoriteModelIDs = Array(NSOrderedSet(array: ids).compactMap { $0 as? String }.prefix(2)) }

    /// A selected installed model is the desktop default. Legacy MLX choices
    /// remain in their own preferences payload and are never overwritten.
    public var defaultModelID: String? { selectedModelID }
}

public struct DesktopModelListItem: Sendable, Equatable, Identifiable {
    public let model: DesktopModel
    public let installed: Bool
    public let isFavorite: Bool
    public let isSelected: Bool
    public var id: String { model.id }
}

public enum DesktopModelList {
    public static func items(language: String? = nil, installedOnly: Bool, settings: DesktopModelSettings, installed: Set<String>) -> [DesktopModelListItem] {
        DesktopModelCatalog.referenceModels.filter { model in
            (!installedOnly || installed.contains(model.id)) && (language == nil || language == "Alle Sprachen" || model.language == language || model.language == "Mehrsprachig")
        }.map { model in
            .init(model: model, installed: installed.contains(model.id), isFavorite: settings.favoriteModelIDs.contains(model.id), isSelected: settings.selectedModelID == model.id)
        }
    }
}

/// Same bounded language set as runtime settings/helper (A6). Automatic is an
/// explicit per-job value, never mutable resident-worker state.
public enum DesktopDictationLanguage: String, Codable, CaseIterable, Sendable {
    case automatic = "auto"
    case de, en, fr, es, it, pt, nl
    public var whisperCode: String? { self == .automatic ? nil : rawValue }
}

public enum RecognitionHintPrompt {
    public static let maximumEntries = 20
    public static let maximumUTF8Bytes = 512
    public static let maximumEntryUTF8Bytes = 96
    public static let maximumWhisperPromptTokens = 96
    public static func make(_ values: [String]) -> String? {
        var unique = Set<String>(), accepted: [String] = [], bytes = 0
        for value in values {
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.utf8.count <= maximumEntryUTF8Bytes, unique.insert(term).inserted else { continue }
            let nextBytes = bytes + (accepted.isEmpty ? 0 : 2) + term.utf8.count
            guard nextBytes <= maximumUTF8Bytes else { break }
            accepted.append(term); bytes = nextBytes
            if accepted.count == maximumEntries { break }
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: ", ")
    }
}

public struct DesktopRuntimeJob: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let generation: UInt64
    public let modelID: String
    public let language: DesktopDictationLanguage
    public let preferredLanguages: [String]
    public let recognitionHintPrompt: String?
    public init(id: UUID = UUID(), generation: UInt64, modelID: String, language: DesktopDictationLanguage = .automatic, preferredLanguages: [String] = PreferredDictationLanguages.defaults, recognitionHintPrompt: String? = nil) {
        self.id = id; self.generation = generation; self.modelID = modelID; self.language = language; self.preferredLanguages = PreferredDictationLanguages.normalized(preferredLanguages)
        let prompt = recognitionHintPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recognitionHintPrompt = (prompt?.isEmpty == false && (prompt?.utf8.count ?? 0) <= RecognitionHintPrompt.maximumUTF8Bytes) ? prompt : nil
    }
}

public enum DesktopRuntimeError: Error, Sendable, Equatable { case unavailable; case unsuitableOS; case cancelled; case staleResult; case nativeFailure; case noSpeech; case reapUnconfirmed }

/// Redacted native preparation evidence for a failed product demand. It is
/// deliberately finite: no SDK text, file path, audio data or transcript can
/// cross the worker boundary through this value.
public enum DesktopNativeFailureStage: String, Sendable, Equatable {
    case fluidPrepareStarted
    case fluidSDKPhase
    case fluidModelsLoaded
    case fluidManagerCreated
    case workerStartup
}

public enum DesktopNativeReadyFailure: String, Sendable, Equatable {
    case deadline
    case outputClosed
    case unexpectedReadyMessage
}

public enum DesktopNativeReapStatus: String, Sendable, Equatable {
    case confirmed
    case unknown
}

public struct DesktopNativeFailureDiagnostic: Sendable, Equatable {
    public let stage: DesktopNativeFailureStage?
    public let readyFailure: DesktopNativeReadyFailure
    public let reap: DesktopNativeReapStatus

    public init(stage: DesktopNativeFailureStage?, readyFailure: DesktopNativeReadyFailure, reap: DesktopNativeReapStatus) {
        self.stage = stage
        self.readyFailure = readyFailure
        self.reap = reap
    }
}

public enum DesktopResidentState: Sendable, Equatable { case cold, preparing, warm, failed, quarantined }

/// Exact cancellation knowledge at the model-file boundary. Only the two
/// `*ReaderEnded` cases permit a caller to release its WAV: an admission has
/// no reader yet, and `readerEndUnknown` retains the quarantined native owner.
/// A normal successful transcription returns only after that file read ended;
/// it does not imply that its resident worker exited.
public enum DesktopModelDemandCancellationOutcome: Sendable, Equatable {
    case idle
    case admissionPending
    case prepareReaderEnded
    case transcriptionReaderEnded
    case readerEndUnknown
}

/// Interactive preparation always uses the ordinary bounded product deadline.
/// The separate Phonon first-prepare purpose is admitted only before any audio
/// demand and is further narrowed by the native worker's fixed manifest and
/// runtime/compute contract.
public enum DesktopRuntimePreparePurpose: Sendable, Equatable {
    case interactive
    case phononFirstPrepare
}

public struct DesktopModelRuntimeStats: Sendable, Equatable {
    public private(set) var coldPrepareMilliseconds: [UInt64] = []
    public private(set) var warmInferenceMilliseconds: [UInt64] = []
    public private(set) var coldInferenceMilliseconds: [UInt64] = []

    mutating func recordPrepare(_ milliseconds: UInt64) { coldPrepareMilliseconds.append(milliseconds) }
    mutating func recordInference(_ milliseconds: UInt64, warm: Bool) {
        if warm { warmInferenceMilliseconds.append(milliseconds) } else { coldInferenceMilliseconds.append(milliseconds) }
    }
}

/// Native adapters must own their SDK object off MainActor and may only return
/// after `cancelAndReap` has made continued native work impossible. A `false`
/// return is an unknown reap: callers must quarantine that model and must not
/// create a replacement worker which could still overlap the original task.
public protocol DesktopNativeModel: Sendable {
    func prepare() async throws
    func prepare(for purpose: DesktopRuntimePreparePurpose) async throws
    func transcribe(audioFile: URL, job: DesktopRuntimeJob) async throws -> String
    func cancelAndReap(job: DesktopRuntimeJob) async -> Bool
    func unload() async -> Bool
    func workerIdentity() async -> UUID?
    func requiresWorkerIdentity() async -> Bool
    func nativeFailureDiagnostic() async -> DesktopNativeFailureDiagnostic?
}

public extension DesktopNativeModel {
    func prepare(for purpose: DesktopRuntimePreparePurpose) async throws { try await prepare() }
    func workerIdentity() async -> UUID? { nil }
    func requiresWorkerIdentity() async -> Bool { false }
    func nativeFailureDiagnostic() async -> DesktopNativeFailureDiagnostic? { nil }
}

public actor DesktopRuntimeCoordinator {
    public typealias Factory = @Sendable (String) async throws -> any DesktopNativeModel
    private let factory: Factory
    private var generation: UInt64 = 0
    private var active: DesktopRuntimeJob?
    private var residents: [String: any DesktopNativeModel] = [:]
    private var recency: [String] = []
    private var residentStates: [String: DesktopResidentState] = [:]
    private var residentAttemptIDs: [String: UUID] = [:]
    private var residentWorkerIDs: [String: UUID] = [:]
    private var prepareEpochs: [String: UInt64] = [:]
    /// An admission is reserved before the factory's first await.  It counts
    /// toward the two-resident budget and makes duplicate same-ID demands wait
    /// for the very same attempt instead of constructing a second model.
    private var admissions: [String: UUID] = [:]
    /// Set before any cancel/unload await.  It is an admission and publication
    /// barrier until that specific teardown has a confirmed outcome.
    private var tearingDown: Set<String> = []
    /// Public prepare has no transcription job, but it is still a cancellable
    /// product demand.  Reserve it before `resident` can suspend.
    private var activePrepareDemand: (modelID: String, token: UUID, purpose: DesktopRuntimePreparePurpose)?
    /// The no-audio first-purpose admission exists before the scheduler's
    /// preload-cancellation await. Different Phonon IDs are deliberately
    /// serialised; identical calls join this same reservation and cannot
    /// overwrite its cancellation ownership.
    private var firstPurposeReservation: (modelID: String, token: UUID, joins: Int)?
    private var firstPurposeJoinWaiters: [UUID: (minimum: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var stats: [String: DesktopModelRuntimeStats] = [:]
    private var preloadingModelID: String?
    /// A preload teardown is owned by its concrete resident attempt, not just
    /// `preloadingModelID`.  Concurrent demands await this exact task; a
    /// false result deliberately remains as an unknown-owner barrier.
    private var preloadTeardown: (modelID: String, attempt: UUID?, task: Task<Bool, Never>, waiterCount: Int)?
    private var preloadTeardownWaiters: [UUID: (minimum: Int, continuation: CheckedContinuation<Void, Error>)] = [:]
    private var terminalDraining = false
    private var demandReap: (job: DesktopRuntimeJob, task: Task<Bool, Never>)?
    private var nativeFailureDiagnostics: [String: DesktopNativeFailureDiagnostic] = [:]

    public init(factory: @escaping Factory) { self.factory = factory }
    public func residentModelIDs() -> Set<String> { Set(residents.keys) }
    public func residentState(for modelID: String) -> DesktopResidentState { residentStates[modelID] ?? .cold }
    public func statistics(for modelID: String) -> DesktopModelRuntimeStats { stats[modelID] ?? .init() }
    public func nativeFailureDiagnostic(for modelID: String) -> DesktopNativeFailureDiagnostic? { nativeFailureDiagnostics[modelID] }

    /// Capture this before a recording begins. The caller must pass the same
    /// value to `transcribe`; later settings writes cannot change its model.
    public func makeJob(modelID: String, language: DesktopDictationLanguage = .automatic, preferredLanguages: [String] = PreferredDictationLanguages.defaults, recognitionHintPrompt: String? = nil) -> DesktopRuntimeJob {
        generation &+= 1
        return DesktopRuntimeJob(generation: generation, modelID: modelID, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: recognitionHintPrompt)
    }

    public func prepare(modelID: String) async throws {
        try await prepare(modelID: modelID, purpose: .interactive)
    }

    /// A purpose is captured before the first suspension. It may not be
    /// silently inherited by a later audio job or a replacement admission.
    public func prepare(modelID: String, purpose: DesktopRuntimePreparePurpose) async throws {
        let reservation: UUID?
        if purpose == .phononFirstPrepare {
            reservation = try reservePhononFirstPrepare(modelID: modelID)
        } else {
            reservation = nil
        }
        try await prepare(modelID: modelID, purpose: purpose, reservation: reservation)
    }

    /// This reservation is synchronous actor state: callers use it before
    /// awaiting a preload cancellation, so a concurrent selection, demand,
    /// cancel or pressure event can revoke it even before a native model exists.
    public func reservePhononFirstPrepare(modelID: String) throws -> UUID {
        if let reservation = firstPurposeReservation {
            guard reservation.modelID == modelID else { throw DesktopRuntimeError.unavailable }
            firstPurposeReservation = (reservation.modelID, reservation.token, reservation.joins + 1)
            resumeFirstPurposeJoinWaiters()
            return reservation.token
        }
        guard activePrepareDemand == nil else { throw DesktopRuntimeError.unavailable }
        let token = UUID()
        firstPurposeReservation = (modelID, token, 1)
        return token
    }

    /// Test-only observation seam for a public ProductService-triggered
    /// attempt. It exposes no worker, path, audio or SDK state.
    public func firstPurposeReservationJoinCount() -> Int { firstPurposeReservation?.joins ?? 0 }

    /// Test-only synchronization for public ProductService race coverage. The
    /// timeout is a bounded watchdog, never an ownership or join mechanism.
    public func waitForFirstPurposeReservationJoinCount(atLeast minimum: Int, timeout: Duration) async throws {
        guard firstPurposeReservationJoinCount() < minimum else { return }
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            if firstPurposeReservationJoinCount() >= minimum {
                continuation.resume()
                return
            }
            firstPurposeJoinWaiters[waiterID] = (minimum, continuation)
            Task {
                try? await Task.sleep(for: timeout)
                self.expireFirstPurposeJoinWaiter(waiterID)
            }
        }
    }

    /// Test-only observation of the shared preload teardown dependency. It
    /// proves that concurrent ProductService calls reached the same reap task;
    /// the timeout is only bounded test cleanup.
    public func waitForPreloadTeardownWaiterCount(atLeast minimum: Int, timeout: Duration) async throws {
        guard (preloadTeardown?.waiterCount ?? 0) < minimum else { return }
        let waiterID = UUID()
        try await withCheckedThrowingContinuation { continuation in
            if (preloadTeardown?.waiterCount ?? 0) >= minimum {
                continuation.resume()
                return
            }
            preloadTeardownWaiters[waiterID] = (minimum, continuation)
            Task {
                try? await Task.sleep(for: timeout)
                self.expirePreloadTeardownWaiter(waiterID)
            }
        }
    }

    func isCurrentPhononFirstPrepare(modelID: String, token: UUID) -> Bool {
        firstPurposeReservation?.modelID == modelID && firstPurposeReservation?.token == token
    }

    func prepare(modelID: String, purpose: DesktopRuntimePreparePurpose, reservation: UUID?) async throws {
        let token: UUID
        if purpose == .phononFirstPrepare {
            guard let reservation else { throw DesktopRuntimeError.cancelled }
            token = reservation
            guard isCurrentPhononFirstPrepare(modelID: modelID, token: token) else { throw DesktopRuntimeError.cancelled }
        } else {
            token = UUID()
        }
        defer {
            if purpose == .phononFirstPrepare {
                releaseFirstPurposeReservation(modelID: modelID, token: token)
            } else if activePrepareDemand?.modelID == modelID, activePrepareDemand?.token == token {
                activePrepareDemand = nil
            }
        }
        activePrepareDemand = (modelID, token, purpose)
        let model = try await resident(for: modelID, protected: [])
        guard purpose != .phononFirstPrepare || isCurrentPhononFirstPrepare(modelID: modelID, token: token) else {
            throw DesktopRuntimeError.cancelled
        }
        try await prepare(model, modelID: modelID, purpose: purpose, firstPurposeToken: reservation)
    }

    /// Background preload is explicitly separate from demand. A caller must
    /// cancel it before starting an interactive demand so a non-cooperative
    /// native SDK is reaped instead of competing with dictation.
    public func preload(modelID: String) async throws {
        guard active == nil, preloadingModelID == nil else { throw DesktopRuntimeError.unavailable }
        let model = try await resident(for: modelID, protected: [])
        preloadingModelID = modelID
        do {
            try Task.checkCancellation()
            try await prepare(model, modelID: modelID, purpose: .interactive)
            guard preloadingModelID == modelID, !Task.isCancelled else {
                let attempt = residentAttemptIDs[modelID]
                tearingDown.insert(modelID)
                guard await model.cancelAndReap(job: DesktopRuntimeJob(generation: generation, modelID: modelID)) else {
                    residentStates[modelID] = .quarantined
                    throw DesktopRuntimeError.reapUnconfirmed
                }
                if residentAttemptIDs[modelID] == attempt { removeResident(modelID) }
                tearingDown.remove(modelID)
                throw DesktopRuntimeError.cancelled
            }
            preloadingModelID = nil
        } catch {
            if preloadingModelID == modelID {
                preloadingModelID = nil
                let attempt = residentAttemptIDs[modelID]
                tearingDown.insert(modelID)
                if !(await model.cancelAndReap(job: DesktopRuntimeJob(generation: generation, modelID: modelID))) {
                    residentStates[modelID] = .quarantined
                    throw DesktopRuntimeError.reapUnconfirmed
                }
                if residentAttemptIDs[modelID] == attempt { removeResident(modelID) }
                tearingDown.remove(modelID)
            }
            throw error
        }
    }

    @discardableResult
    public func cancelPreload() async -> Bool {
        if let teardown = preloadTeardown {
            let joined = (teardown.modelID, teardown.attempt, teardown.task, teardown.waiterCount + 1)
            preloadTeardown = joined
            resumePreloadTeardownWaiters()
            return await awaitPreloadTeardown(joined)
        }
        guard let id = preloadingModelID, let model = residents[id] else { return true }
        preloadingModelID = nil
        prepareEpochs[id] = (prepareEpochs[id] ?? 0) &+ 1
        let attempt = residentAttemptIDs[id]
        let teardownGeneration = generation
        tearingDown.insert(id)
        let teardown = (modelID: id, attempt: attempt, task: Task {
            await model.cancelAndReap(job: DesktopRuntimeJob(generation: teardownGeneration, modelID: id))
        }, waiterCount: 1)
        preloadTeardown = teardown
        return await awaitPreloadTeardown(teardown)
    }

    private func awaitPreloadTeardown(_ teardown: (modelID: String, attempt: UUID?, task: Task<Bool, Never>, waiterCount: Int)) async -> Bool {
        let confirmed = await teardown.task.value
        guard let active = preloadTeardown,
              active.modelID == teardown.modelID, active.attempt == teardown.attempt else {
            return confirmed
        }
        if confirmed {
            preloadTeardown = nil
            if residentAttemptIDs[teardown.modelID] == teardown.attempt {
                removeResident(teardown.modelID)
            }
            tearingDown.remove(teardown.modelID)
        } else {
            // Keep the completed false task as the barrier for all future
            // waiters. It represents an owner whose teardown was not
            // confirmed, rather than an absent preload.
            residentStates[teardown.modelID] = .quarantined
        }
        return confirmed
    }

    public func beginTerminalDrain() {
        terminalDraining = true
        for id in admissions.keys { tearingDown.insert(id) }
    }
    /// Unlike memory pressure, terminal drain visits every concrete owner.
    public func drainAllResidents() async -> Bool {
        for id in residents.keys.sorted() {
            guard let model = residents[id] else { continue }
            if tearingDown.contains(id) || residentStates[id] == .quarantined { continue }
            let attempt = residentAttemptIDs[id]
            prepareEpochs[id] = (prepareEpochs[id] ?? 0) &+ 1
            tearingDown.insert(id)
            if await model.unload() {
                if residentAttemptIDs[id] == attempt { removeResident(id) }
                tearingDown.remove(id)
            } else { residentStates[id] = .quarantined }
        }
        return residents.isEmpty && admissions.isEmpty && active == nil && preloadTeardown == nil
    }

    /// Releases the least-recent inactive resident and returns only after its
    /// native worker has acknowledged unload/reap.
    @discardableResult
    public func releaseInactiveResident(excluding protected: Set<String> = []) async -> String? {
        guard let id = recency.first(where: {
            !protected.contains($0) && active?.modelID != $0 && preloadingModelID != $0 &&
            !tearingDown.contains($0) && residentStates[$0] != .quarantined
        }),
              let model = residents[id] else { return nil }
        prepareEpochs[id] = (prepareEpochs[id] ?? 0) &+ 1
        let attempt = residentAttemptIDs[id]
        tearingDown.insert(id)
        guard await model.unload() else {
            residentStates[id] = .quarantined
            return nil
        }
        if residentAttemptIDs[id] == attempt { removeResident(id) }
        tearingDown.remove(id)
        return id
    }

    /// Selection is captured synchronously into the returned job before the
    /// first await; late completions can never publish into a newer generation.
    public func transcribe(modelID: String, audioFile: URL, language: DesktopDictationLanguage = .automatic, preferredLanguages: [String] = PreferredDictationLanguages.defaults, recognitionHintPrompt: String? = nil) async throws -> String {
        let job = makeJob(modelID: modelID, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: recognitionHintPrompt)
        return try await transcribe(job: job, audioFile: audioFile)
    }

    public func transcribe(job: DesktopRuntimeJob, audioFile: URL) async throws -> String {
        guard job.generation == generation else { throw DesktopRuntimeError.staleResult }
        guard active == nil else { throw DesktopRuntimeError.unavailable }
        active = job
        do {
            let model = try await resident(for: job.modelID, protected: [job.modelID])
            // A job can be cancelled while the factory is suspended.  The
            // admission must not turn into a native prepare merely because its
            // model arrived after that cancellation.
            guard active == job, generation == job.generation, !Task.isCancelled else { throw DesktopRuntimeError.staleResult }
            let wasWarm = residentStates[job.modelID] == .warm
            try await prepare(model, modelID: job.modelID, purpose: .interactive)
            guard active == job, generation == job.generation, !Task.isCancelled else { throw DesktopRuntimeError.staleResult }
            let start = DispatchTime.now().uptimeNanoseconds
            let text = try await model.transcribe(audioFile: audioFile, job: job)
            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            var modelStats = stats[job.modelID] ?? .init()
            modelStats.recordInference(elapsed, warm: wasWarm)
            stats[job.modelID] = modelStats
            guard active == job, generation == job.generation, !Task.isCancelled else { throw DesktopRuntimeError.staleResult }
            active = nil
            return text
        } catch {
            // A thrown inference/prepare is not a reader-end receipt. Preserve
            // the concrete job until cancelAndReap confirms its owner ended.
            if active == job, job.generation == generation, (error as? DesktopRuntimeError) == .noSpeech { active = nil }
            throw error
        }
    }

    public func cancel(_ job: DesktopRuntimeJob) async -> DesktopModelDemandCancellationOutcome {
        guard active == job else { return .idle }
        if let reap = demandReap, reap.job == job {
            return await reap.task.value ? .transcriptionReaderEnded : .readerEndUnknown
        }
        generation &+= 1
        if let model = residents[job.modelID] {
            prepareEpochs[job.modelID] = (prepareEpochs[job.modelID] ?? 0) &+ 1
            let attempt = residentAttemptIDs[job.modelID]
            tearingDown.insert(job.modelID)
            let task = Task { await model.cancelAndReap(job: job) }
            demandReap = (job, task)
            let confirmed = await task.value
            demandReap = nil
            if confirmed {
                if active == job { active = nil }
                if residentAttemptIDs[job.modelID] == attempt { removeResident(job.modelID) }
                tearingDown.remove(job.modelID)
                return .transcriptionReaderEnded
            } else {
                residentStates[job.modelID] = .quarantined
                return .readerEndUnknown
            }
        } else if admissions[job.modelID] != nil {
            active = nil
            // There is no native owner yet, but its factory may already be
            // suspended.  Invalidate and reserve the admission before that
            // await returns; `resident` will dispose its late owner under the
            // same teardown barrier rather than allowing a replacement.
            prepareEpochs[job.modelID] = (prepareEpochs[job.modelID] ?? 0) &+ 1
            tearingDown.insert(job.modelID)
            return .admissionPending
        }
        return .idle
    }

    /// Product demand cancellation has no implicit retry. The current job is
    /// invalidated before its worker is reaped, so a late native completion
    /// cannot change the resident state or publish text.
    public func cancelActiveDemand() async -> DesktopModelDemandCancellationOutcome {
        if let active { return await cancel(active) }
        guard let pending = activePrepareDemand else { return .idle }
        return await cancelPrepareDemand(pending)
    }

    /// Selection, memory pressure and an interactive demand may preempt only
    /// the explicit no-audio first-prepare purpose. An active transcription
    /// continues to use the regular cancellation contract.
    /// Returns the real reader-end outcome when this explicit no-audio
    /// preparation owns the current demand. Callers that only preempt work may
    /// ignore it; the public demand-cancel path must preserve it.
    public func cancelPhononFirstPrepare() async -> DesktopModelDemandCancellationOutcome {
        let reservation = firstPurposeReservation
        firstPurposeReservation = nil
        guard let pending = activePrepareDemand,
              pending.purpose == .phononFirstPrepare,
              reservation == nil || pending.token == reservation?.token else { return .idle }
        return await cancelPrepareDemand(pending)
    }

    private func cancelPrepareDemand(_ pending: (modelID: String, token: UUID, purpose: DesktopRuntimePreparePurpose)) async -> DesktopModelDemandCancellationOutcome {
        guard activePrepareDemand?.modelID == pending.modelID, activePrepareDemand?.token == pending.token else { return .idle }
        activePrepareDemand = nil
        prepareEpochs[pending.modelID] = (prepareEpochs[pending.modelID] ?? 0) &+ 1
        tearingDown.insert(pending.modelID)
        // A factory admission has no native owner yet.  Leave its reservation
        // in place so an S2 cannot race a late S1 factory return; S1 clears the
        // barrier itself after observing its invalidated token.
        guard let model = residents[pending.modelID] else { return .admissionPending }
        let attempt = residentAttemptIDs[pending.modelID]
        if await model.cancelAndReap(job: DesktopRuntimeJob(generation: generation, modelID: pending.modelID)) {
            if residentAttemptIDs[pending.modelID] == attempt { removeResident(pending.modelID) }
            tearingDown.remove(pending.modelID)
            return .prepareReaderEnded
        } else {
            residentStates[pending.modelID] = .quarantined
            return .readerEndUnknown
        }
    }

    /// Demand is always the caller of this method; it is never invoked by a
    /// background preload. At most two fully resident models survive.
    private func resident(for modelID: String, protected protectedIDs: Set<String>) async throws -> any DesktopNativeModel {
        guard !terminalDraining else { throw DesktopRuntimeError.unavailable }
        while admissions[modelID] != nil {
            guard !tearingDown.contains(modelID) else { throw DesktopRuntimeError.cancelled }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !tearingDown.contains(modelID) else { throw DesktopRuntimeError.cancelled }
        if let resident = residents[modelID] {
            guard residentStates[modelID] != .quarantined else { throw DesktopRuntimeError.reapUnconfirmed }
            touch(modelID)
            return resident
        }
        while residents.count + admissions.count >= 2 {
            guard let evicted = recency.first(where: {
                !protectedIDs.contains($0) && active?.modelID != $0 &&
                !tearingDown.contains($0) && residentStates[$0] != .quarantined
            }), let model = residents[evicted] else { throw DesktopRuntimeError.unavailable }
            let attempt = residentAttemptIDs[evicted]
            tearingDown.insert(evicted)
            guard await model.unload() else {
                residentStates[evicted] = .quarantined
                throw DesktopRuntimeError.reapUnconfirmed
            }
            if residentAttemptIDs[evicted] == attempt { removeResident(evicted) }
            tearingDown.remove(evicted)
        }
        guard !terminalDraining else { throw DesktopRuntimeError.unavailable }
        let admission = UUID()
        admissions[modelID] = admission
        residentStates[modelID] = .preparing
        let model: any DesktopNativeModel
        do { model = try await factory(modelID) }
        catch {
            if admissions[modelID] == admission { admissions.removeValue(forKey: modelID); residentStates[modelID] = .cold; tearingDown.remove(modelID) }
            throw error
        }
        guard admissions[modelID] == admission, !tearingDown.contains(modelID), !terminalDraining else {
            // A cancelled factory can still have constructed a native owner.
            // Keep both the owner and its admission reserved across unload so
            // no S2 can overlap it.  A false result is an unknown reap and
            // deliberately retains the quarantine/owner rather than silently
            // clearing capacity or starting a replacement.
            guard admissions[modelID] == admission else {
                _ = await model.unload()
                throw DesktopRuntimeError.cancelled
            }
            let attempt = UUID()
            residents[modelID] = model
            residentAttemptIDs[modelID] = attempt
            residentStates[modelID] = .preparing
            let confirmed = await model.unload()
            guard admissions[modelID] == admission, residentAttemptIDs[modelID] == attempt else {
                throw DesktopRuntimeError.cancelled
            }
            if confirmed {
                admissions.removeValue(forKey: modelID)
                removeResident(modelID)
                tearingDown.remove(modelID)
            } else {
                residentStates[modelID] = .quarantined
            }
            throw confirmed ? DesktopRuntimeError.cancelled : DesktopRuntimeError.reapUnconfirmed
        }
        admissions.removeValue(forKey: modelID)
        residents[modelID] = model
        residentStates[modelID] = .cold
        residentAttemptIDs[modelID] = UUID()
        prepareEpochs[modelID] = 0
        touch(modelID)
        return model
    }

    private func prepare(_ model: any DesktopNativeModel, modelID: String, purpose: DesktopRuntimePreparePurpose, firstPurposeToken: UUID? = nil) async throws {
        guard purpose != .phononFirstPrepare || (firstPurposeToken != nil && isCurrentPhononFirstPrepare(modelID: modelID, token: firstPurposeToken!)) else {
            throw DesktopRuntimeError.cancelled
        }
        let perfStart = DispatchTime.now().uptimeNanoseconds
        guard !tearingDown.contains(modelID) else { throw DesktopRuntimeError.cancelled }
        guard residentStates[modelID] != .warm else { PerfLog.current?.mark(.modelReady, coldLoad: false, durationMilliseconds: 0); return }
        guard residentStates[modelID] != .quarantined else { throw DesktopRuntimeError.reapUnconfirmed }
        if residentStates[modelID] == .preparing {
            let observedEpoch = prepareEpochs[modelID] ?? 0
            while residentStates[modelID] == .preparing, prepareEpochs[modelID] == observedEpoch { try await Task.sleep(for: .milliseconds(1)) }
            guard prepareEpochs[modelID] == observedEpoch, residentStates[modelID] == .warm else { throw DesktopRuntimeError.cancelled }
            PerfLog.current?.mark(.modelReady, coldLoad: true, durationMilliseconds: (DispatchTime.now().uptimeNanoseconds - perfStart) / 1_000_000)
            return
        }
        guard let residentAttemptID = residentAttemptIDs[modelID] else { throw DesktopRuntimeError.unavailable }
        let epoch = (prepareEpochs[modelID] ?? 0) &+ 1
        prepareEpochs[modelID] = epoch
        nativeFailureDiagnostics.removeValue(forKey: modelID)
        residentStates[modelID] = .preparing
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await model.prepare(for: purpose)
            guard purpose != .phononFirstPrepare || (firstPurposeToken != nil && isCurrentPhononFirstPrepare(modelID: modelID, token: firstPurposeToken!)) else {
                throw DesktopRuntimeError.cancelled
            }
            guard residentAttemptIDs[modelID] == residentAttemptID, prepareEpochs[modelID] == epoch,
                  residentStates[modelID] == .preparing, !tearingDown.contains(modelID) else { throw DesktopRuntimeError.cancelled }
            let workerID = await model.workerIdentity()
            let requiresWorkerID = await model.requiresWorkerIdentity()
            guard residentAttemptIDs[modelID] == residentAttemptID, prepareEpochs[modelID] == epoch,
                  residentStates[modelID] == .preparing, !tearingDown.contains(modelID),
                  !requiresWorkerID || workerID != nil else { throw DesktopRuntimeError.cancelled }
            if requiresWorkerID, let workerID {
                // The worker port is asynchronous. Bind a positive identity
                // and immediately reconfirm it before READY is published, so
                // a changed/missing worker cannot inherit this attempt.
                guard await model.workerIdentity() == workerID,
                      residentAttemptIDs[modelID] == residentAttemptID,
                      prepareEpochs[modelID] == epoch, !tearingDown.contains(modelID) else {
                    throw DesktopRuntimeError.cancelled
                }
                residentWorkerIDs[modelID] = workerID
            }
            let elapsed = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            var modelStats = stats[modelID] ?? .init()
            modelStats.recordPrepare(elapsed)
            stats[modelID] = modelStats
            residentStates[modelID] = .warm
            PerfLog.current?.mark(.modelReady, coldLoad: true, durationMilliseconds: (DispatchTime.now().uptimeNanoseconds - perfStart) / 1_000_000)
        } catch {
            if residentAttemptIDs[modelID] == residentAttemptID, prepareEpochs[modelID] == epoch {
                if (error as? DesktopRuntimeError) == .nativeFailure {
                    nativeFailureDiagnostics[modelID] = await model.nativeFailureDiagnostic()
                }
                residentStates[modelID] = (error as? DesktopRuntimeError) == .nativeFailure ? .failed : .cold
            }
            throw error
        }
    }

    private func touch(_ id: String) { recency.removeAll { $0 == id }; recency.append(id) }
    private func resumeFirstPurposeJoinWaiters() {
        let current = firstPurposeReservationJoinCount()
        let ready = firstPurposeJoinWaiters.filter { $0.value.minimum <= current }
        for (waiterID, waiter) in ready {
            firstPurposeJoinWaiters.removeValue(forKey: waiterID)
            waiter.continuation.resume()
        }
    }
    private func expireFirstPurposeJoinWaiter(_ waiterID: UUID) {
        firstPurposeJoinWaiters.removeValue(forKey: waiterID)?.continuation.resume(throwing: DesktopRuntimeError.cancelled)
    }
    private func resumePreloadTeardownWaiters() {
        let current = preloadTeardown?.waiterCount ?? 0
        let ready = preloadTeardownWaiters.filter { $0.value.minimum <= current }
        for (waiterID, waiter) in ready {
            preloadTeardownWaiters.removeValue(forKey: waiterID)
            waiter.continuation.resume()
        }
    }
    private func expirePreloadTeardownWaiter(_ waiterID: UUID) {
        preloadTeardownWaiters.removeValue(forKey: waiterID)?.continuation.resume(throwing: DesktopRuntimeError.cancelled)
    }
    private func releaseFirstPurposeReservation(modelID: String, token: UUID) {
        guard let reservation = firstPurposeReservation,
              reservation.modelID == modelID, reservation.token == token else { return }
        if reservation.joins > 1 {
            firstPurposeReservation = (modelID, token, reservation.joins - 1)
        } else {
            firstPurposeReservation = nil
            if activePrepareDemand?.modelID == modelID, activePrepareDemand?.token == token {
                activePrepareDemand = nil
            }
        }
    }
    private func removeResident(_ id: String) {
        residents.removeValue(forKey: id)
        residentAttemptIDs.removeValue(forKey: id)
        residentWorkerIDs.removeValue(forKey: id)
        prepareEpochs.removeValue(forKey: id)
        recency.removeAll { $0 == id }
        residentStates[id] = .cold
    }
}

/// Serial policy layer for app-start preload and interactive demand. The
/// caller supplies installer-validated IDs and measured resident costs; absent
/// costs fail closed for optional favourite preloads rather than inventing RAM
/// requirements. No path here owns a downloader, microphone or iOS lifecycle.
public actor DesktopResidentScheduler {
    private let coordinator: DesktopRuntimeCoordinator
    private var settings: DesktopModelSettings
    private var installed: Set<String>
    private var residentCosts: [String: Int]
    private var memoryBudgetBytes: Int
    private var preloadTask: Task<Void, Never>?

    public init(coordinator: DesktopRuntimeCoordinator, settings: DesktopModelSettings = .init(), installed: Set<String> = [], residentCosts: [String: Int] = [:], memoryBudgetBytes: Int = 0) {
        self.coordinator = coordinator
        self.settings = settings
        self.installed = installed
        self.residentCosts = residentCosts
        self.memoryBudgetBytes = memoryBudgetBytes
    }

    public func update(settings: DesktopModelSettings, installed: Set<String>, residentCosts: [String: Int], memoryBudgetBytes: Int) async {
        let selectionChanged = self.settings.selectedModelID != settings.selectedModelID
        self.settings = settings
        self.installed = installed
        self.residentCosts = residentCosts
        self.memoryBudgetBytes = memoryBudgetBytes
        if selectionChanged { _ = await coordinator.cancelPhononFirstPrepare() }
    }

    public func currentSettings() -> DesktopModelSettings { settings }
    public func installedModelIDs() -> Set<String> { installed }

    /// Selected model is always tried first at app start. The optional second
    /// preload is the highest-priority installed favourite that fits a caller-
    /// supplied RAM budget. All execution remains local.
    public func appStarted() async {
        guard let selected = settings.defaultModelID, installed.contains(selected) else { return }
        let favourite = settings.favoriteModelIDs.first(where: { $0 != selected && installed.contains($0) && fitsBudget(selected: selected, candidate: $0) })
        preloadTask?.cancel()
        _ = await coordinator.cancelPhononFirstPrepare()
        guard await coordinator.cancelPreload() else { return }
        let coordinator = coordinator
        preloadTask = Task { [weak self] in
            do {
                try await coordinator.preload(modelID: selected)
                try Task.checkCancellation()
                if let favourite { try await coordinator.preload(modelID: favourite) }
            } catch { }
            guard !Task.isCancelled else { return }
            await self?.clearCompletedPreload()
        }
    }

    public func demandPrepare(modelID: String) async throws {
        preloadTask?.cancel()
        preloadTask = nil
        _ = await coordinator.cancelPhononFirstPrepare()
        guard await coordinator.cancelPreload() else { throw DesktopRuntimeError.reapUnconfirmed }
        guard installed.contains(modelID) else { throw DesktopRuntimeError.unavailable }
        try await coordinator.prepare(modelID: modelID)
    }

    /// Explicit legacy selection clears only the additive desktop preference.
    /// A selected preload must have a confirmed reap before product code may
    /// persist an empty selection; an unknown native owner remains a hard
    /// error, never an implicit legacy fallback.
    public func clearSelectedDesktopDemand() async throws {
        preloadTask?.cancel()
        preloadTask = nil
        _ = await coordinator.cancelPhononFirstPrepare()
        guard await coordinator.cancelPreload() else { throw DesktopRuntimeError.reapUnconfirmed }
    }

    /// Explicit, no-audio first preparation. This is deliberately not called
    /// by app-start preload: a caller must ask for the exact Phonon purpose.
    public func preparePhononFirstUse(modelID: String) async throws {
        let reservation = try await coordinator.reservePhononFirstPrepare(modelID: modelID)
        preloadTask?.cancel()
        preloadTask = nil
        guard await coordinator.cancelPreload() else { throw DesktopRuntimeError.reapUnconfirmed }
        guard await coordinator.isCurrentPhononFirstPrepare(modelID: modelID, token: reservation) else {
            throw DesktopRuntimeError.cancelled
        }
        guard installed.contains(modelID) else { throw DesktopRuntimeError.unavailable }
        try await coordinator.prepare(modelID: modelID, purpose: .phononFirstPrepare, reservation: reservation)
    }

    public func transcribe(modelID: String, audioFile: URL, language: DesktopDictationLanguage = .automatic, preferredLanguages: [String] = PreferredDictationLanguages.defaults, recognitionHintPrompt: String? = nil) async throws -> String {
        preloadTask?.cancel()
        preloadTask = nil
        _ = await coordinator.cancelPhononFirstPrepare()
        guard await coordinator.cancelPreload() else { throw DesktopRuntimeError.reapUnconfirmed }
        guard installed.contains(modelID) else { throw DesktopRuntimeError.unavailable }
        return try await coordinator.transcribe(modelID: modelID, audioFile: audioFile, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: recognitionHintPrompt)
    }

    public func terminalDrain() async -> Bool {
        await coordinator.beginTerminalDrain()
        _ = await cancelDemand()
        return await coordinator.drainAllResidents()
    }

    public func memoryPressure() async {
        preloadTask?.cancel()
        preloadTask = nil
        _ = await coordinator.cancelPhononFirstPrepare()
        await coordinator.cancelPreload()
        _ = await coordinator.releaseInactiveResident(excluding: [])
    }

    public func cancelDemand() async -> DesktopModelDemandCancellationOutcome {
        preloadTask?.cancel()
        preloadTask = nil
        let firstPrepareOutcome = await coordinator.cancelPhononFirstPrepare()
        await coordinator.cancelPreload()
        let activeOutcome = await coordinator.cancelActiveDemand()
        return firstPrepareOutcome == .idle ? activeOutcome : firstPrepareOutcome
    }

    public func firstPurposeReservationJoinCount() async -> Int {
        await coordinator.firstPurposeReservationJoinCount()
    }

    public func waitForFirstPurposeReservationJoinCount(atLeast minimum: Int, timeout: Duration) async throws {
        try await coordinator.waitForFirstPurposeReservationJoinCount(atLeast: minimum, timeout: timeout)
    }

    public func waitForPreloadTeardownWaiterCount(atLeast minimum: Int, timeout: Duration) async throws {
        try await coordinator.waitForPreloadTeardownWaiterCount(atLeast: minimum, timeout: timeout)
    }

    private func clearCompletedPreload() { preloadTask = nil }

    private func fitsBudget(selected: String, candidate: String) -> Bool {
        guard memoryBudgetBytes > 0, let selectedCost = residentCosts[selected], let candidateCost = residentCosts[candidate] else { return false }
        let (sum, overflow) = selectedCost.addingReportingOverflow(candidateCost)
        return !overflow && sum <= memoryBudgetBytes
    }
}
