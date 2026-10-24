import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security
import KlangschriftAppCore
import KlangschriftPersistence
import KlangschriftTranscription

/// Filesystem ownership is fixed to the app identity; callers cannot choose an
/// arbitrary root. Every directory is private to the current user (0700).
public struct AppPaths: Sendable, Equatable {
    public static let appIdentifier = "io.github.miggidev618.klangschrift"
    public let root: URL
    public let database: URL
    public let backups: URL
    public let recovery: URL
    public let audio: URL
    public let recoveryManifest: URL

    public init(applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)) throws {
        let support = try Self.bindSecureParent(applicationSupport)
        let root = support.url.appendingPathComponent(Self.appIdentifier, isDirectory: true)
        try Self.makePrivate(root, parent: support)
        let rootBinding = try Self.bindPrivateDirectory(root)
        for child in ["backups", "recovery", "audio"] { try Self.makePrivate(root.appendingPathComponent(child, isDirectory: true), parent: rootBinding) }
        try Self.requirePrivateDirectory(root)
        self.root = root
        database = root.appendingPathComponent("klangschrift.sqlite", isDirectory: false)
        backups = root.appendingPathComponent("backups", isDirectory: true)
        recovery = root.appendingPathComponent("recovery", isDirectory: true)
        audio = root.appendingPathComponent("audio", isDirectory: true)
        recoveryManifest = recovery.appendingPathComponent("store-recovery.json", isDirectory: false)
    }

    private struct DirectoryBinding: Sendable { let url: URL; let device: UInt64; let inode: UInt64 }
    /// Bind every existing canonical ancestor before the first mkdir. System
    /// parents may be root-owned, while user-owned parents may use normal macOS
    /// modes (for example 0755); none may be group/world writable or a symlink.
    private static func bindSecureParent(_ input: URL) throws -> DirectoryBinding {
        guard input.isFileURL, input.path.hasPrefix("/") else { throw AppFoundationFailure.insecurePath }
        var raw = stat()
        guard lstat(input.standardizedFileURL.path, &raw) == 0, (raw.st_mode & S_IFMT) == S_IFDIR else { throw AppFoundationFailure.insecurePath }
        guard let real = realpath(input.path, nil) else { throw AppFoundationFailure.insecurePath }
        defer { free(real) }
        let canonical = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        var cursor = canonical.path
        while true {
            var info = stat()
            guard lstat(cursor, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  (info.st_mode & 0o022) == 0, info.st_uid == getuid() || info.st_uid == 0 else { throw AppFoundationFailure.insecurePath }
            if cursor == "/" { break }
            cursor = URL(fileURLWithPath: cursor).deletingLastPathComponent().path
        }
        return .init(url: canonical, device: UInt64(raw.st_dev), inode: raw.st_ino)
    }
    private static func bindPrivateDirectory(_ url: URL) throws -> DirectoryBinding {
        try requirePrivateDirectory(url)
        var info = stat(); guard lstat(url.path, &info) == 0 else { throw AppFoundationFailure.insecurePath }
        return .init(url: url.standardizedFileURL, device: UInt64(info.st_dev), inode: info.st_ino)
    }
    private static func makePrivate(_ url: URL, parent: DirectoryBinding) throws {
        var parentInfo = stat()
        guard lstat(parent.url.path, &parentInfo) == 0, UInt64(parentInfo.st_dev) == parent.device, parentInfo.st_ino == parent.inode,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR else { throw AppFoundationFailure.insecurePath }
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(), (info.st_mode & 0o077) == 0 else { throw AppFoundationFailure.insecurePath }
            guard chmod(url.path, 0o700) == 0 else { throw AppFoundationFailure.insecurePath }
        } else {
            guard Darwin.errno == ENOENT else { throw AppFoundationFailure.insecurePath }
            guard mkdir(url.path, 0o700) == 0 else { throw AppFoundationFailure.insecurePath }
        }
        try requirePrivateDirectory(url)
        var verifiedParent = stat()
        guard lstat(parent.url.path, &verifiedParent) == 0, UInt64(verifiedParent.st_dev) == parent.device, verifiedParent.st_ino == parent.inode else { throw AppFoundationFailure.insecurePath }
    }
    private static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw AppFoundationFailure.insecurePath }
    }
}

public enum AppFoundationFailure: Error, Sendable, Equatable {
    case insecurePath, missingKey, invalidKey, keychainLocked, keychainDenied, keychainCancelled, keychainStatus(Int32), keychainInteractionReadStatus(Int32), keychainInteractionDisableStatus(Int32), keychainInteractionRestoreStatus(Int32), modelUnavailable, modelIntegrity, recoveryAmbiguous, invalidConfiguration
}

/// Keychain implementation is used only by production composition. Tests pass
/// an injected provider and must never instantiate or call this type.
/// App-integration spelling of the persistence key seam. The narrower protocol
/// prevents composition from accepting an unrelated data source by accident.
public protocol DatabaseKeyProviding: DatabaseKeyProvider {}

/// The existing-store route never creates a key. It lets composition choose a
/// noninteractive startup probe or pass through an explicit user action later.
public enum ExistingDatabaseKeyAccess: Sendable, Equatable {
    case noninteractiveProbe
    case explicitUserAccess
}

/// Foundation owns this bridge so AppAdapters can adopt it later without
/// making AppIntegration depend on AppAdapters.
public protocol ExistingDatabaseKeyProviding: DatabaseKeyProviding {
    func loadExistingRootKey(access: ExistingDatabaseKeyAccess) throws -> Data
}

enum LegacyKeychainInteractionRead: Sendable, Equatable { case allowed(Bool), status(Int32) }
enum LegacyKeychainInteractionWrite: Sendable, Equatable { case success, status(Int32) }
protocol LegacyKeychainInteractionControlling: Sendable {
    func currentUserInteractionAllowed() -> LegacyKeychainInteractionRead
    func setUserInteractionAllowed(_ allowed: Bool) -> LegacyKeychainInteractionWrite
}

private struct SystemLegacyKeychainInteractionController: LegacyKeychainInteractionControlling {
    func currentUserInteractionAllowed() -> LegacyKeychainInteractionRead {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return status == errSecSuccess ? .allowed(allowed.boolValue) : .status(Int32(status))
    }
    func setUserInteractionAllowed(_ allowed: Bool) -> LegacyKeychainInteractionWrite {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        return status == errSecSuccess ? .success : .status(Int32(status))
    }
}

public struct KeychainDatabaseKeyProvider: ExistingDatabaseKeyProviding {
    public static let service = "io.github.miggidev618.klangschrift.database-key"
    public static let account = "root-key-v1"
    private static let legacyInteractionLock = NSLock()
    private let existingKeyQuery: (@Sendable (ExistingDatabaseKeyAccess) throws -> Data?)?
    private let legacyInteraction: any LegacyKeychainInteractionControlling

    public init() {
        existingKeyQuery = nil
        legacyInteraction = SystemLegacyKeychainInteractionController()
    }
    init(existingKeyQuery: @escaping @Sendable (ExistingDatabaseKeyAccess) throws -> Data?, legacyInteraction: any LegacyKeychainInteractionControlling) {
        self.existingKeyQuery = existingKeyQuery
        self.legacyInteraction = legacyInteraction
    }
    public func loadRootKey() throws -> Data { try loadRootKey(creatingIfMissing: true) }
    public func loadRootKey(creatingIfMissing: Bool) throws -> Data {
        if !creatingIfMissing { return try loadExistingRootKey(access: .noninteractiveProbe) }
        if let key = try noninteractiveExistingKeyQuery() { return key }
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw AppFoundationFailure.keychainStatus(Int32(randomStatus)) }
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account, kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecSuccess { return bytes }
        // A concurrent first launch may have inserted it. Read once; never log.
        if addStatus == errSecDuplicateItem { return try loadExistingRootKey(access: .noninteractiveProbe) }
        throw Self.failure(for: addStatus)
    }
    public func loadExistingRootKey(access: ExistingDatabaseKeyAccess) throws -> Data {
        let key: Data?
        if access == .noninteractiveProbe {
            key = try noninteractiveExistingKeyQuery()
        } else {
            key = try copiedRootKey(access: access)
        }
        guard let key else { throw AppFoundationFailure.missingKey }
        return key
    }
    private func noninteractiveExistingKeyQuery() throws -> Data? {
        Self.legacyInteractionLock.lock()
        defer { Self.legacyInteractionLock.unlock() }
        let previous: Bool
        switch legacyInteraction.currentUserInteractionAllowed() {
        case let .allowed(value): previous = value
        case let .status(status): throw AppFoundationFailure.keychainInteractionReadStatus(status)
        }
        switch legacyInteraction.setUserInteractionAllowed(false) {
        case .success: break
        case let .status(status): throw AppFoundationFailure.keychainInteractionDisableStatus(status)
        }
        let result: Result<Data?, Error>
        do { result = .success(try copiedRootKey(access: .noninteractiveProbe)) }
        catch { result = .failure(error) }
        switch legacyInteraction.setUserInteractionAllowed(previous) {
        case .success: break
        case let .status(status): throw AppFoundationFailure.keychainInteractionRestoreStatus(status)
        }
        return try result.get()
    }
    private func copiedRootKey(access: ExistingDatabaseKeyAccess) throws -> Data? {
        if let existingKeyQuery { return try existingKeyQuery(access) }
        let authenticationContext = LAContext()
        if access == .noninteractiveProbe { authenticationContext.interactionNotAllowed = true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: Self.account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: authenticationContext]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            guard data.count == 32 else { throw AppFoundationFailure.invalidKey }
            return data
        }
        if status == errSecItemNotFound { return nil }
        throw Self.failure(for: status)
    }
    private static func failure(for status: OSStatus) -> AppFoundationFailure {
        switch status {
        case errSecInteractionNotAllowed: .keychainLocked
        case errSecAuthFailed: .keychainDenied
        case errSecUserCanceled: .keychainCancelled
        default: .keychainStatus(Int32(status))
        }
    }
}

public struct LocalModelPins: Sendable, Equatable {
    /// Placeholder pins keep explicit test callers source-compatible without
    /// introducing a user-home/cache fallback into a packaged product. The
    /// production factory always supplies `ProductionRuntimeLocations` pins
    /// rooted below app-owned Application Support.
    private static let explicitInstallRoot = URL(fileURLWithPath: "/__klangschrift_explicit_model_install_required__", isDirectory: true)
    public static let whisperLargeV3: Self = {
        let root = explicitInstallRoot.appendingPathComponent("models--mlx-community--whisper-large-v3-mlx", isDirectory: true)
        return .init(allowedSnapshot: root.appendingPathComponent("snapshots/49e6aa286ad60c14352c404340ded53710378a11", isDirectory: true), allowedBlobsRoot: root.appendingPathComponent("blobs", isDirectory: true), fileSHA256: [".gitattributes":"11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361", "README.md":"1194c9a3805b7c80adf0017e92c72db0bbb14ab64462eb64d548c1c532b7aa56", "config.json":"34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3", "weights.npz":"05ff791ce3630fae47e7c51004e9666204d786246ec07cac6110af768099b40d"])
    }()
    public static let whisperLargeV3Turbo: Self = {
        let root = explicitInstallRoot.appendingPathComponent("models--mlx-community--whisper-large-v3-turbo", isDirectory: true)
        return .init(allowedSnapshot: root.appendingPathComponent("snapshots/a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb", isDirectory: true), allowedBlobsRoot: root.appendingPathComponent("blobs", isDirectory: true), fileSHA256: [".gitattributes":"11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361", "README.md":"78f2d3dc65072211d957fc1b646c2d96e8e8f96dd45ceb2ac5f2643d0c5c05da", "config.json":"b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379", "weights.safetensors":"951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"])
    }()
    public let allowedSnapshot: URL
    public let allowedBlobsRoot: URL
    public let fileSHA256: [String: String]
    public var configSHA256: String { fileSHA256["config.json"]! }
    public var weightsSHA256: String {
        let candidates = ["weights.npz", "weights.safetensors"].compactMap { fileSHA256[$0] }
        guard candidates.count == 1, let weights = candidates.first else { fatalError("model pins must pin exactly one weights file") }
        return weights
    }
    /// Harness-only manifests may bind a private fixture root, but production
    /// always uses `whisperLargeV3` above.
    public init(allowedSnapshot: URL, allowedBlobsRoot: URL, fileSHA256: [String: String]) { self.allowedSnapshot = allowedSnapshot.standardizedFileURL; self.allowedBlobsRoot = allowedBlobsRoot.standardizedFileURL; self.fileSHA256 = fileSHA256 }
}

public struct ResolvedLocalModel: Sendable, Equatable {
    public let snapshot: URL; public let python: URL; public let helper: URL; public let pins: LocalModelPins
    public func launchConfiguration(audioRoot: URL, isolatedImportRoot: URL? = nil) throws -> HelperLaunchConfiguration { try .init(python: python, helper: helper, model: snapshot, audioRoot: audioRoot, isolatedImportRoot: isolatedImportRoot, configHash: pins.configSHA256, weightsHash: pins.weightsSHA256) }
}

/// Production paths are deliberately independent of a developer checkout.
/// Runtime and helper are supplied by the eventual app bundle; models are
/// explicitly installed below the app-owned support root. Tests keep passing
/// private fixtures. No lookup through PATH, Homebrew, or a Hugging Face cache
/// is permitted.
public enum ProductionRuntimeLocations {
    public static func bundledPython(bundle: Bundle = .main) throws -> URL {
        guard let resourceRoot = bundle.resourceURL else { throw AppFoundationFailure.modelUnavailable }
        let url = resourceRoot.appendingPathComponent("Runtime/Python.framework/Versions/3.14/bin/python3.14", isDirectory: false).standardizedFileURL
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains(":"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(url.path, X_OK) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    /// The production runtime uses `-S`; this is the sole approved import
    /// root supplied back to Python. It is intentionally absolute and bound
    /// to the same private app bundle as the Python executable.
    public static func bundledPythonImportRoot(bundle: Bundle = .main) throws -> URL {
        guard let resourceRoot = bundle.resourceURL else { throw AppFoundationFailure.modelUnavailable }
        let url = resourceRoot.appendingPathComponent("Runtime/Python.framework/Versions/3.14/lib/python3.14/site-packages", isDirectory: true).standardizedFileURL
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    public static func bundledHelper(bundle: Bundle = .main) throws -> URL {
        guard let helper = bundle.url(forResource: "klangschrift_mlx_helper", withExtension: "py", subdirectory: "Helper") else {
            throw AppFoundationFailure.modelUnavailable
        }
        let url = helper.standardizedFileURL; var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(url.path, R_OK) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    public static func legacyMLXPins(applicationSupport: URL, profile: LocalModelProfile) -> LocalModelPins {
        let (modelDirectory, revision, files): (String, String, [String: String])
        switch profile {
        case .whisperLargeV3:
            modelDirectory = "models--mlx-community--whisper-large-v3-mlx"
            revision = "49e6aa286ad60c14352c404340ded53710378a11"
            files = [".gitattributes":"11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361", "README.md":"1194c9a3805b7c80adf0017e92c72db0bbb14ab64462eb64d548c1c532b7aa56", "config.json":"34982ce6ae286095000f82ae9583b3431639e8b092bf60c961f203745e6500e3", "weights.npz":"05ff791ce3630fae47e7c51004e9666204d786246ec07cac6110af768099b40d"]
        case .whisperLargeV3Turbo:
            modelDirectory = "models--mlx-community--whisper-large-v3-turbo"
            revision = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
            files = [".gitattributes":"11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361", "README.md":"78f2d3dc65072211d957fc1b646c2d96e8e8f96dd45ceb2ac5f2643d0c5c05da", "config.json":"b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379", "weights.safetensors":"951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6"]
        }
        let root = applicationSupport
            .appendingPathComponent(AppPaths.appIdentifier, isDirectory: true)
            .appendingPathComponent("models/legacy-mlx-v1", isDirectory: true)
            .appendingPathComponent(modelDirectory, isDirectory: true)
        return .init(allowedSnapshot: root.appendingPathComponent("snapshots/\(revision)", isDirectory: true), allowedBlobsRoot: root.appendingPathComponent("blobs", isDirectory: true), fileSHA256: files)
    }

    /// Explicitly imports one already-present legacy MLX snapshot. There is
    /// no cache search, fallback download, replacement, or profile change:
    /// the caller supplies both source directories and the selected profile.
    /// Source entries must be direct regular files; the imported app-owned
    /// representation deliberately contains no Hugging Face symlinks.
    public static func importLegacyMLX(
        profile: LocalModelProfile,
        sourceSnapshot: URL,
        sourceBlobs: URL,
        applicationSupport: URL
    ) throws -> LocalModelPins {
        let destination = legacyMLXPins(applicationSupport: applicationSupport, profile: profile)
        let source = LocalModelPins(allowedSnapshot: sourceSnapshot, allowedBlobsRoot: sourceBlobs, fileSHA256: destination.fileSHA256)
        try LegacyMLXModelImporter().importNoReplace(source: source, destination: destination)
        return destination
    }
}

/// A conscious continuity action supplied by the update/onboarding surface.
/// It never names or scans a cache; the user-visible caller provides the
/// selected profile and the exact source snapshot/blob roots.
public struct LegacyMLXImportRequest: Sendable, Equatable {
    public let profile: LocalModelProfile
    public let sourceSnapshot: URL
    public let sourceBlobs: URL
    public let sourcePins: LocalModelPins?
    public init(profile: LocalModelProfile, sourceSnapshot: URL, sourceBlobs: URL, sourcePins: LocalModelPins? = nil) {
        self.profile = profile; self.sourceSnapshot = sourceSnapshot.standardizedFileURL; self.sourceBlobs = sourceBlobs.standardizedFileURL; self.sourcePins = sourcePins
    }
}

/// Deliberate launch action for continuity imports.  It accepts only an
/// explicit profile and the two exact, user-selected roots; it never derives a
/// source from HOME, a cache, or a model catalogue.
public enum LegacyMLXImportEntryError: Error, Sendable, Equatable { case incomplete, invalidProfile, relativeRoot }

public enum LegacyMLXImportEntry {
    private static func request(arguments: [String]) throws -> LegacyMLXImportRequest? {
        guard let marker = arguments.firstIndex(of: "--import-legacy-mlx") else { return nil }
        let values = arguments.dropFirst(marker + 1)
        guard values.count == 3 else { throw LegacyMLXImportEntryError.incomplete }
        guard let profile = LocalModelProfile(rawValue: String(values[values.startIndex])) else { throw LegacyMLXImportEntryError.invalidProfile }
        let rawSnapshot = String(values[values.index(after: values.startIndex)])
        let rawBlobs = String(values[values.index(values.startIndex, offsetBy: 2)])
        // Validate raw strings before URL(fileURLWithPath:) can resolve them
        // against CWD. The entry accepts exact absolute roots only.
        guard rawSnapshot.hasPrefix("/"), rawBlobs.hasPrefix("/") else { throw LegacyMLXImportEntryError.relativeRoot }
        let snapshot = URL(fileURLWithPath: rawSnapshot, isDirectory: true)
        let blobs = URL(fileURLWithPath: rawBlobs, isDirectory: true)
        return .init(profile: profile, sourceSnapshot: snapshot, sourceBlobs: blobs)
    }

    /// Called by the executable. Explicit malformed requests never fall
    /// through to the no-marker branch.
    public static func route<T>(arguments: [String], normal: () -> T, importing: (LegacyMLXImportRequest) -> T, rejected: (LegacyMLXImportEntryError) -> T) -> T {
        do {
            guard let request = try request(arguments: arguments) else { return normal() }
            return importing(request)
        } catch let error as LegacyMLXImportEntryError {
            return rejected(error)
        } catch {
            return rejected(.incomplete)
        }
    }
}

/// Narrow, explicit migration port for legacy MLX bytes. It never locates a
/// home/cache path itself and never replaces an existing app-owned model.
public struct LegacyMLXModelImporter: Sendable {
    public init() {}
    public func importNoReplace(source: LocalModelPins, destination: LocalModelPins) throws {
        guard source.fileSHA256 == destination.fileSHA256 else { throw AppFoundationFailure.modelIntegrity }
        let sourceSnapshot = try secureDirectory(source.allowedSnapshot)
        _ = try secureDirectory(source.allowedBlobsRoot)
        guard sourceSnapshot.lastPathComponent == destination.allowedSnapshot.lastPathComponent else { throw AppFoundationFailure.modelIntegrity }
        let modelRoot = destination.allowedSnapshot.deletingLastPathComponent().deletingLastPathComponent()
        let destinationParent = modelRoot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try secureDirectory(destinationParent)
        if FileManager.default.fileExists(atPath: modelRoot.path) {
            try verifyDirectFiles(snapshot: destination.allowedSnapshot, pins: destination)
            return
        }
        let stage = destinationParent.appendingPathComponent(".legacy-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("snapshots", isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: stage.appendingPathComponent("blobs", isDirectory: true), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let stagedSnapshot = stage.appendingPathComponent("snapshots", isDirectory: true).appendingPathComponent(sourceSnapshot.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: stagedSnapshot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for name in source.fileSHA256.keys.sorted() {
            let input = sourceSnapshot.appendingPathComponent(name, isDirectory: false)
            let output = stagedSnapshot.appendingPathComponent(name, isDirectory: false)
            let bytes = try readSourceFile(input, snapshot: sourceSnapshot, blobs: source.allowedBlobsRoot)
            guard sha256(bytes) == source.fileSHA256[name] else { throw AppFoundationFailure.modelIntegrity }
            try writeNewRegular(bytes, to: output)
        }
        try renameExclusive(stage, to: modelRoot)
        try verifyDirectFiles(snapshot: destination.allowedSnapshot, pins: destination)
    }

    private func secureDirectory(_ value: URL) throws -> URL {
        let url = value.standardizedFileURL; var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    private func verifyDirectFiles(snapshot: URL, pins: LocalModelPins) throws {
        let root = try secureDirectory(snapshot)
        let actual = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        guard actual == Set(pins.fileSHA256.keys) else { throw AppFoundationFailure.modelIntegrity }
        for name in pins.fileSHA256.keys {
            let bytes = try readRegularNoFollow(root.appendingPathComponent(name, isDirectory: false))
            guard sha256(bytes) == pins.fileSHA256[name] else { throw AppFoundationFailure.modelIntegrity }
        }
    }
    private func readRegularNoFollow(_ url: URL) throws -> Data {
        var before = stat()
        guard lstat(url.path, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_uid == getuid(), (before.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelIntegrity }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw AppFoundationFailure.modelIntegrity }
        defer { _ = close(fd) }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw AppFoundationFailure.modelIntegrity }
            if count == 0 { break }
            data.append(buffer, count: Int(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size else { throw AppFoundationFailure.modelIntegrity }
        return data
    }
    private func readSourceFile(_ url: URL, snapshot: URL, blobs: URL) throws -> Data {
        var link = stat()
        guard lstat(url.path, &link) == 0 else { throw AppFoundationFailure.modelIntegrity }
        if (link.st_mode & S_IFMT) == S_IFLNK {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            let prefix = blobs.standardizedFileURL.path.hasSuffix("/") ? blobs.path : blobs.path + "/"
            guard resolved.path.hasPrefix(prefix) else { throw AppFoundationFailure.modelIntegrity }
            return try readRegularNoFollow(resolved)
        }
        let prefix = snapshot.path.hasSuffix("/") ? snapshot.path : snapshot.path + "/"
        guard (link.st_mode & S_IFMT) == S_IFREG, url.standardizedFileURL.path.hasPrefix(prefix) else { throw AppFoundationFailure.modelIntegrity }
        return try readRegularNoFollow(url)
    }
    private func writeNewRegular(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AppFoundationFailure.modelUnavailable }
        defer { _ = close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw AppFoundationFailure.modelUnavailable }
                offset += count
            }
        }
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func renameExclusive(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL)) }
        }
        guard result == 0 else { throw AppFoundationFailure.modelUnavailable }
    }
}

/// Resolves exactly one caller-supplied local snapshot. It does not search the
/// home directory, invoke Python, run a helper, or download anything.
public struct LocalModelResolver: Sendable {
    public init() {}
    public func resolve(snapshot: URL, python: URL, helper: URL, pins: LocalModelPins = .whisperLargeV3) throws -> ResolvedLocalModel {
        guard snapshot.standardizedFileURL == pins.allowedSnapshot else { throw AppFoundationFailure.modelUnavailable }
        let model = try secureDirectory(snapshot), blobs = try secureDirectory(pins.allowedBlobsRoot)
        let p = try canonicalPython(python), h = try secureHelper(helper)
        let actual = try Set(FileManager.default.contentsOfDirectory(atPath: model.path))
        guard actual == Set(pins.fileSHA256.keys) else { throw AppFoundationFailure.modelIntegrity }
        for (name, expected) in pins.fileSHA256 {
            let file = model.appendingPathComponent(name)
            let resolved = try validatedModelFile(file, snapshot: model, blobs: blobs)
            guard try sha256(of: resolved) == expected else { throw AppFoundationFailure.modelIntegrity }
        }
        return .init(snapshot: model, python: p, helper: h, pins: pins)
    }
    private func secureDirectory(_ value: URL) throws -> URL {
        let url = value.standardizedFileURL; var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    private func validatedModelFile(_ file: URL, snapshot: URL, blobs: URL) throws -> URL {
        var link = stat(); guard lstat(file.path, &link) == 0 else { throw AppFoundationFailure.modelIntegrity }
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        guard lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelIntegrity }
        if (link.st_mode & S_IFMT) == S_IFLNK {
            let prefix = blobs.path.hasSuffix("/") ? blobs.path : blobs.path + "/"
            guard resolved.path.hasPrefix(prefix) else { throw AppFoundationFailure.modelIntegrity }
        } else {
            let prefix = snapshot.path.hasSuffix("/") ? snapshot.path : snapshot.path + "/"
            guard (link.st_mode & S_IFMT) == S_IFREG, resolved.path.hasPrefix(prefix) else { throw AppFoundationFailure.modelIntegrity }
        }
        return resolved
    }
    /// Python installations commonly expose a versioned executable through a
    /// symlink. Resolve it once, bind the real regular target, and pass only
    /// that canonical target to Process.
    private func canonicalPython(_ value: URL) throws -> URL {
        guard value.isFileURL, value.path.hasPrefix("/"), let real = realpath(value.path, nil) else { throw AppFoundationFailure.modelUnavailable }
        defer { free(real) }
        let url = URL(fileURLWithPath: String(cString: real)).standardizedFileURL; var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(url.path, X_OK) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    private func secureHelper(_ value: URL) throws -> URL {
        let url = value.standardizedFileURL; var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), url.resolvingSymlinksInPath() == url,
              lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0, access(url.path, R_OK) == 0 else { throw AppFoundationFailure.modelUnavailable }
        return url
    }
    private func sha256(of value: URL) throws -> String {
        let resolved = value.resolvingSymlinksInPath(); var info = stat()
        guard resolved.path.hasPrefix("/"), lstat(resolved.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), (info.st_mode & 0o022) == 0 else { throw AppFoundationFailure.modelUnavailable }
        let data: Data
        do { data = try Data(contentsOf: resolved, options: [.mappedIfSafe]) } catch { throw AppFoundationFailure.modelUnavailable }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol StartupRecoveryRecording: Sendable { func record(_ step: StartupStep) }
public enum StartupStep: String, Sendable, Equatable { case paths, key, manifestRecovery, store, preferences, projection, modelFallback, coldRuntime }
public struct NoopStartupRecoveryRecorder: StartupRecoveryRecording { public init() {} ; public func record(_ step: StartupStep) {} }

public struct StartupRecovery: Sendable {
    public init() {}
    /// Any unresolved/ambiguous manifest blocks opening. This foundation never
    /// auto-deletes, swaps or repairs a database at startup.
    public func validate(paths: AppPaths) async throws {
        guard FileManager.default.fileExists(atPath: paths.recoveryManifest.path) else { return }
        // Restore stages beside the active database under `paths.root`; the
        // manifest itself lives in the private recovery subdirectory.
        let phase = try await InactiveStoreRecoveryCoordinator().resolveStartupManifest(at: paths.recoveryManifest, directory: paths.root)
        guard phase == .verified else { throw AppFoundationFailure.recoveryAmbiguous }
    }
}

public struct ColdRuntimeConfiguration: Sendable { public let launch: HelperLaunchConfiguration; public let projection: RuntimeSettingsProjection }
/// Explicit-test configuration: validates the exact local model, helper and
/// private audio root, but deliberately never loads a database key or opens a
/// store. It is the only pre-foundation runtime input.
public struct EphemeralRuntimeConfiguration: Sendable { public let paths: AppPaths; public let launch: HelperLaunchConfiguration; public let projection: RuntimeSettingsProjection }
public enum EphemeralRuntimeConfigurationFactory {
    public static func make(applicationSupport: URL, snapshot: URL, python: URL, helper: URL, pins: LocalModelPins = .whisperLargeV3, isolatedImportRoot: URL? = nil) throws -> EphemeralRuntimeConfiguration {
        let paths = try AppPaths(applicationSupport: applicationSupport)
        let projection = RuntimeSettingsProjection(); try projection.validate()
        let model = try LocalModelResolver().resolve(snapshot: snapshot, python: python, helper: helper, pins: pins)
        return .init(paths: paths, launch: try model.launchConfiguration(audioRoot: paths.audio, isolatedImportRoot: isolatedImportRoot), projection: projection)
    }
}
public struct AppFoundation: Sendable {
    public let paths: AppPaths; public let store: EncryptedSQLiteStore; public let preferences: PreferencesRecord; public let model: ResolvedLocalModel; public let coldRuntime: ColdRuntimeConfiguration
}

/// Composition owns startup sequencing but deliberately does not construct a
/// helper client or call prepare. Runtime adapters and shutdown ownership are
/// deferred: future shutdown order is UI stop -> coordinator -> audio cleanup
/// -> helper reap -> store close, with every adapter awaiting its own result.
public enum AppFoundationComposition {
    /// The `pins` parameter remains the built-in entry for `whisperLargeV3` so
    /// existing harness fixtures keep binding their private roots; production
    /// callers pass the `.whisperLargeV3` default. An override replaces the
    /// whole mapping table.
    public static func effectivePins(model: LocalModelProfile, pins: LocalModelPins, override: [LocalModelProfile: LocalModelPins]?) throws -> LocalModelPins {
        if let override { guard let pinned = override[model] else { throw AppFoundationFailure.invalidConfiguration }; return pinned }
        switch model {
        case .whisperLargeV3: return pins
        case .whisperLargeV3Turbo: return .whisperLargeV3Turbo
        }
    }
    public static func bootstrap(applicationSupport: URL, keyProvider: any DatabaseKeyProviding, snapshot: URL, python: URL, helper: URL, pins: LocalModelPins = .whisperLargeV3, recorder: any StartupRecoveryRecording = NoopStartupRecoveryRecorder(), modelPinsOverride: [LocalModelProfile: LocalModelPins]? = nil, isolatedImportRoot: URL? = nil, legacyImport: LegacyMLXImportRequest? = nil, existingKeyAccess: ExistingDatabaseKeyAccess = .noninteractiveProbe) async throws -> AppFoundation {
        let paths = try AppPaths(applicationSupport: applicationSupport); recorder.record(.paths)
        if let legacyImport {
            guard let destination = modelPinsOverride?[legacyImport.profile] else { throw AppFoundationFailure.modelIntegrity }
            let source = legacyImport.sourcePins ?? .init(allowedSnapshot: legacyImport.sourceSnapshot, allowedBlobsRoot: legacyImport.sourceBlobs, fileSHA256: destination.fileSHA256)
            try LegacyMLXModelImporter().importNoReplace(source: source, destination: destination)
        }
        let key: Data
        let creatingKey = try !EncryptedSQLiteStore.existingDatabase(at: paths.database)
        if creatingKey {
            key = try keyProvider.loadRootKey(creatingIfMissing: true)
        } else if let existingProvider = keyProvider as? any ExistingDatabaseKeyProviding {
            key = try existingProvider.loadExistingRootKey(access: existingKeyAccess)
        } else {
            key = try keyProvider.loadRootKey(creatingIfMissing: false)
        }
        guard key.count == 32 else { throw AppFoundationFailure.invalidKey }; recorder.record(.key)
        try await StartupRecovery().validate(paths: paths); recorder.record(.manifestRecovery)
        let store: EncryptedSQLiteStore
        do { store = try EncryptedSQLiteStore(databaseURL: paths.database, keyProvider: InMemoryDatabaseKeyProvider(key: key), migrationBackupDirectory: paths.backups) } catch { throw error }
        recorder.record(.store)
        let preferences = try await store.preferences(); recorder.record(.preferences)
        let projection = RuntimeSettingsProjection(model: preferences.snapshot.model, language: preferences.snapshot.language); try projection.validate(); recorder.record(.projection)
        let effectivePins = try effectivePins(model: preferences.snapshot.model, pins: pins, override: modelPinsOverride)
        let model: ResolvedLocalModel
        do { model = try LocalModelResolver().resolve(snapshot: effectivePins.allowedSnapshot, python: python, helper: helper, pins: effectivePins) }
        catch {
            guard preferences.snapshot.model != LocalModelProfile.whisperLargeV3 else { throw error }
            let fallbackPins = try AppFoundationComposition.effectivePins(model: LocalModelProfile.whisperLargeV3, pins: pins, override: modelPinsOverride)
            model = try LocalModelResolver().resolve(snapshot: fallbackPins.allowedSnapshot, python: python, helper: helper, pins: fallbackPins)
            recorder.record(.modelFallback)
        }
        let launch = try model.launchConfiguration(audioRoot: paths.audio, isolatedImportRoot: isolatedImportRoot); recorder.record(.coldRuntime)
        return .init(paths: paths, store: store, preferences: preferences, model: model, coldRuntime: .init(launch: launch, projection: projection))
    }
}
