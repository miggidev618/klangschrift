import CryptoKit
import Darwin
import Foundation
import KlangschriftSQLiteShim
import SQLite3

private let SQLITE_TRANSIENT_KS = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The on-disk format version. This is deliberately not used as cryptographic AAD.
public enum DatabaseSchema {
    /// Version 3 adds encrypted, content-free lifetime dictation aggregates.
    /// The registry below is the sole authority for advancing this number.
    public static let currentVersion: Int32 = 3
}

public enum DatabaseFailure: Error, Equatable, Sendable {
    case invalidPath
    case insecurePath
    case missingKey
    case invalidKey
    case wrongKeyOrTampered
    case futureSchema(Int32)
    case migrationBlocked
    case integrityCheckFailed
    case sqlite(code: Int32)
    case invalidHistoryInput
    case conflict
    case notFound
    case confirmationRequired
    case injectedFault
    case resourceLimit
    case closed
}

public enum TranscriptStatus: String, Sendable, CaseIterable { case success, failed, cancelled }
public enum InsertionStatus: String, Sendable, CaseIterable { case notAttempted = "not_attempted", inserted, copied, failed }
public enum HistoryRetention: Sendable, Equatable { case forever, days7, days14, days30, days90, none }
public struct HistoryMetadata: Sendable, Equatable {
    public let createdAtMs: Int64; public let durationMs: Int64; public let transcriptionStatus: TranscriptStatus; public let insertionStatus: InsertionStatus
    public init(createdAtMs: Int64, durationMs: Int64, transcriptionStatus: TranscriptStatus = .success, insertionStatus: InsertionStatus = .notAttempted) {
        self.createdAtMs = createdAtMs; self.durationMs = durationMs; self.transcriptionStatus = transcriptionStatus; self.insertionStatus = insertionStatus
    }
}
public struct HistoryEntry: Sendable, Equatable {
    public let id: UUID; public let text: String; public let language: String?; public let targetBundleID: String?; public let metadata: HistoryMetadata
    public let updatedAtMs: Int64; public let revision: Int64; public let pinnedAtMs: Int64?
}
public struct HistoryPreview: Sendable, Equatable { public let id: UUID; public let text: String; public let createdAtMs: Int64; public let durationMs: Int64; public let transcriptionStatus: TranscriptStatus; public let insertionStatus: InsertionStatus; public let revision: Int64; public let pinnedAtMs: Int64? }
public struct HistoryCursor: Sendable, Equatable { public let createdAtMs: Int64; public let id: UUID; public init(createdAtMs: Int64, id: UUID) { self.createdAtMs = createdAtMs; self.id = id } }
public struct HistoryPage: Sendable, Equatable { public let entries: [HistoryPreview]; public let next: HistoryCursor? }
/// An opaque, single-use capability issued by one `EncryptedSQLiteStore` instance.
/// It has no public initializer: callers can retain it for Undo, but cannot forge one.
public struct DeletionBatch: Sendable, Equatable { public let id: UUID; public let undoUntilMs: Int64; fileprivate let token: UUID; fileprivate init(id: UUID, undoUntilMs: Int64, token: UUID) { self.id = id; self.undoUntilMs = undoUntilMs; self.token = token } }
public struct ClearHistoryConfirmation: Sendable, Equatable { fileprivate let token: UUID; fileprivate init(_ token: UUID) { self.token = token } }
/// One-time capability for an explicit destructive full local-data reset.
/// It is intentionally separate from `ClearHistoryConfirmation`.
public struct ResetAllLocalAppDataConfirmation: Sendable, Equatable { fileprivate let token: UUID; fileprivate init(_ token: UUID) { self.token = token } }
public struct RetentionScheduleState: Sendable, Equatable { public let lastSuccessMs: Int64?; public let nextDueMs: Int64?; public init(lastSuccessMs: Int64?, nextDueMs: Int64?) { self.lastSuccessMs = lastSuccessMs; self.nextDueMs = nextDueMs } }
public struct DictationStatisticsSnapshot: Sendable, Equatable {
    public let totalDictations: Int64
    public let totalWords: Int64
    public let totalRecordedMilliseconds: Int64
    public let currentStreakDays: Int64
    public let longestStreakDays: Int64
    public let lastDayIdentifier: Int64?
    public let trackingStartedAtMs: Int64
    public let revision: Int64

    public init(
        totalDictations: Int64,
        totalWords: Int64,
        totalRecordedMilliseconds: Int64,
        currentStreakDays: Int64,
        longestStreakDays: Int64,
        lastDayIdentifier: Int64?,
        trackingStartedAtMs: Int64,
        revision: Int64
    ) {
        self.totalDictations = totalDictations
        self.totalWords = totalWords
        self.totalRecordedMilliseconds = totalRecordedMilliseconds
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
        self.lastDayIdentifier = lastDayIdentifier
        self.trackingStartedAtMs = trackingStartedAtMs
        self.revision = revision
    }
}
/// Issued only after its store closes its SQLite handle. Callers cannot forge it.
public struct InactiveStoreLease: Sendable, Equatable { fileprivate let databaseURL: URL; fileprivate let identity: BoundFileIdentity; fileprivate let token: UUID; fileprivate init(databaseURL: URL, identity: BoundFileIdentity, token: UUID) { self.databaseURL = databaseURL; self.identity = identity; self.token = token } }
public enum HistoryFaultPoint: Sendable { case beforeCommit, afterCommitBeforeIndex, beforeIndexRebuild }
/// Bounded synthetic storage failure seam. It is opt-in and used only by
/// isolated tests; production composition leaves it nil. This is not an OS
/// disk-full probe: it models SQLite's `SQLITE_FULL` after the history INSERT
/// has executed inside the already-open transaction and before commit.
public enum StorageFaultPoint: Sendable, Equatable { case sqliteFullAfterHistoryInsert }

/// A small injected clock keeps expiry behaviour deterministic without exposing time overrides in public mutators.
public protocol HistoryClock: Sendable { func nowMilliseconds() -> Int64 }
public struct SystemHistoryClock: HistoryClock {
    public init() {}
    public func nowMilliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }
}
/// Deterministic mutable clock for tests and harnesses. Production composition uses `SystemHistoryClock`.
public final class TestHistoryClock: HistoryClock, @unchecked Sendable {
    private let lock = NSLock(); private var value: Int64
    public init(nowMilliseconds: Int64) { self.value = nowMilliseconds }
    public func nowMilliseconds() -> Int64 { lock.lock(); defer { lock.unlock() }; return value }
    public func setNowMilliseconds(_ newValue: Int64) { lock.lock(); value = newValue; lock.unlock() }
}

public protocol DatabaseKeyProvider: Sendable {
    func loadRootKey() throws -> Data
    /// Existing encrypted stores must never trigger implicit key creation.
    /// Providers that do not create keys may retain the legacy one-argument
    /// implementation through the default below.
    func loadRootKey(creatingIfMissing: Bool) throws -> Data
}

public extension DatabaseKeyProvider {
    func loadRootKey(creatingIfMissing: Bool) throws -> Data {
        try loadRootKey()
    }
}

/// Test-only provider. Production composition must supply a Keychain-backed provider outside this package.
public struct InMemoryDatabaseKeyProvider: DatabaseKeyProvider {
    private let key: Data
    public init(key: Data) { self.key = key }
    public func loadRootKey() throws -> Data {
        guard key.count == 32 else { throw DatabaseFailure.invalidKey }
        return key
    }
}

/// Explicit inert production seam: it performs no Keychain access by itself.
public struct UnavailableProductionKeyProvider: DatabaseKeyProvider {
    public init() {}
    public func loadRootKey() throws -> Data { throw DatabaseFailure.missingKey }
}

public enum EncryptionDomain: String, Sendable, CaseIterable {
    case history = "Klangschrift.SQLite.History.v1"
    case dictionary = "Klangschrift.SQLite.Dictionary.v1"
    case settings = "Klangschrift.SQLite.Settings.v1"
    case statistics = "Klangschrift.SQLite.Statistics.v1"
}

public struct DomainFieldCipher: Sendable {
    private let cipher: FieldCipher
    public init(rootKey: Data, domain: EncryptionDomain) throws {
        guard rootKey.count == 32 else { throw DatabaseFailure.invalidKey }
        let root = SymmetricKey(data: rootKey)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: Data("Klangschrift.SQLite.Root.v1".utf8),
            info: Data(domain.rawValue.utf8),
            outputByteCount: 32
        )
        self.cipher = try FieldCipher(keyData: derived.withUnsafeBytes { Data($0) })
    }
    public func seal(_ data: Data, aad: PersistenceAAD) throws -> EncryptedBlob {
        try cipher.seal(data, aad: aad.encoded())
    }
    public func open(_ blob: EncryptedBlob, aad: PersistenceAAD) throws -> Data {
        do { return try cipher.open(blob, aad: aad.encoded()) }
        catch { throw DatabaseFailure.wrongKeyOrTampered }
    }
}

public enum DatabaseOpenState: String, Sendable { case closed, pathValidated, opened, schemaChecked, bootstrapping, integrityChecked, ready, blocked }
public enum MigrationCrashPoint: Sendable { case afterSchemaCreate, beforeUserVersion, afterUserVersion }
/// Deterministic migration seams. Each seam is inside the migration transaction;
/// an injected failure must therefore reopen as either the old or new version.
public enum MigrationFaultPoint: Sendable { case afterBackup, afterDDL, afterLedger, beforeUserVersion, afterUserVersion, beforeCommit }
public enum DatabasePragmaProbe: String, Sendable, CaseIterable {
    case journalMode = "journal_mode", synchronous, foreignKeys = "foreign_keys", secureDelete = "secure_delete", trustedSchema = "trusted_schema", tempStore = "temp_store"
    public init(validating rawValue: String) throws {
        guard let probe = Self(rawValue: rawValue) else { throw DatabaseFailure.invalidPath }
        self = probe
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { if let handle { sqlite3_close_v2(handle) } }
}
private struct BoundFileIdentity: Equatable, Sendable { let device: UInt64; let inode: UInt64 }
private func boundIdentity(_ url: URL) throws -> BoundFileIdentity {
    var value = stat()
    guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG else { throw DatabaseFailure.insecurePath }
    return .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
}

/// A single actor-owned SQLite connection. It intentionally exposes only foundation probes in P6-01.
public actor EncryptedSQLiteStore {
    private struct SearchRecord: Sendable { let text: String; let createdAtMs: Int64; let byteCount: Int }
    private let databaseURL: URL
    private let rootKey: Data
    private let connection: SQLiteConnection
    private let boundDatabaseIdentity: BoundFileIdentity
    private(set) public var state: DatabaseOpenState = .closed
    private let migrationCrashPoint: MigrationCrashPoint?
    private let migrationFaultPoint: MigrationFaultPoint?
    private let storageFaultPoint: StorageFaultPoint?
    private let storageFaultObserver: (@Sendable (StorageFaultPoint) -> Void)?
    private let migrationBackupDirectory: URL?
    private let clock: any HistoryClock
    private let historySearchByteLimit: Int
    /// Volatile only: normalized text used to select candidates. SQLite never receives plaintext search terms.
    private var historySearchIndex: [UUID: SearchRecord] = [:]
    private var historyIndexDirty = false
    private var historySearchBytes = 0
    private var deletionCapabilities: [UUID: UUID] = [:]
    private var clearConfirmation: UUID?
    private var resetAllConfirmation: UUID?
    private var inactiveLeaseToken: UUID?
    private var dictionaryCache: [DictionaryEntry]?
    private var dictionaryCompiled: DictionaryTransformer.Compiled?
    private var dictionaryAdmissionBytes: Int?
    private var dictionaryStoredBytes: Int?
    private let dictionaryIndexByteLimit = 16 * 1024 * 1024
    private let preferencesRevisionNotifier: (@Sendable (Int64) -> Void)?
    /// Revisions become pending only after their transaction commits. This is
    /// intentionally actor-local: the notifier is a cache invalidation seam,
    /// not a durable side-effect or a delivery log.
    private var pendingPreferencesRevisionNotifications: [Int64] = []

    public init(databaseURL: URL, keyProvider: any DatabaseKeyProvider, migrationCrashPoint: MigrationCrashPoint? = nil, migrationFaultPoint: MigrationFaultPoint? = nil, migrationBackupDirectory: URL? = nil, clock: any HistoryClock = SystemHistoryClock(), historySearchByteLimit: Int = 128 * 1024 * 1024, preferencesRevisionNotifier: (@Sendable (Int64) -> Void)? = nil, storageFaultPoint: StorageFaultPoint? = nil, storageFaultObserver: (@Sendable (StorageFaultPoint) -> Void)? = nil) throws {
        self.databaseURL = try Self.validateDatabasePath(databaseURL)
        self.rootKey = try keyProvider.loadRootKey()
        guard rootKey.count == 32 else { throw DatabaseFailure.invalidKey }
        self.migrationCrashPoint = migrationCrashPoint
        self.migrationFaultPoint = migrationFaultPoint
        self.storageFaultPoint = storageFaultPoint
        self.storageFaultObserver = storageFaultObserver
        self.migrationBackupDirectory = migrationBackupDirectory
        self.clock = clock
        guard historySearchByteLimit > 0 else { throw DatabaseFailure.resourceLimit }
        self.historySearchByteLimit = historySearchByteLimit
        self.preferencesRevisionNotifier = preferencesRevisionNotifier
        self.state = .pathValidated
        let provenance = try Self.createEmptyFileIfNeeded(at: self.databaseURL)
        var db: OpaquePointer?
        try Self.validateExistingFileNoFollow(at: self.databaseURL)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | 0x01000000 // SQLITE_OPEN_NOFOLLOW
        let result = sqlite3_open_v2(self.databaseURL.path, &db, flags, nil)
        guard result == SQLITE_OK, let db else { if let db { sqlite3_close_v2(db) }; throw DatabaseFailure.sqlite(code: result) }
        self.connection = SQLiteConnection(db)
        try Self.validateExistingFileNoFollow(at: self.databaseURL)
        self.boundDatabaseIdentity = try boundIdentity(self.databaseURL)
        try Self.verifyHandleIdentity(db)
        self.state = .opened
        try Self.hardenFile(at: self.databaseURL)
        try Self.configure(db)
        try Self.bootstrapOrValidateExisting(
            db,
            provenance: provenance,
            rootKey: self.rootKey,
            trackingStartedAtMs: clock.nowMilliseconds(),
            crashPoint: migrationCrashPoint,
            migrationFault: migrationFaultPoint,
            databaseURL: self.databaseURL,
            migrationBackupDirectory: migrationBackupDirectory,
            state: &self.state
        )
        _ = try Self.readStatistics(db, rootKey: self.rootKey)
        try Self.verifyHandleIdentity(db)
        try Self.verifyIntegrity(db)
        self.state = .integrityChecked
        try Self.applyDefensiveMode(db)
        let initialIndex = try Self.readSearchIndex(db, rootKey: self.rootKey, byteLimit: historySearchByteLimit)
        self.historySearchIndex = initialIndex.index; self.historySearchBytes = initialIndex.bytes
        self.state = .ready
    }

    // MARK: - History (P6-02)

    public func saveHistory(text: String, language: String? = nil, targetBundleID: String? = nil, metadata: HistoryMetadata, retention: HistoryRetention = .forever, id: UUID = UUID(), cryptoVersion: UInt32 = 1, fault: HistoryFaultPoint? = nil) throws -> HistoryEntry? {
        guard retention != .none else { return nil }
        try Self.validateHistory(text: text, language: language, targetBundleID: targetBundleID, metadata: metadata, id: id, cryptoVersion: cryptoVersion)
        try ensureHistoryIndexReady()
        let normalized = Self.normalized(text), normalizedBytes = normalized.utf8.count
        guard Self.canAdd(historySearchBytes, normalizedBytes, limit: historySearchByteLimit) else { throw DatabaseFailure.resourceLimit }
        let now = clock.nowMilliseconds(); guard now >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        let entry = HistoryEntry(id: id, text: text, language: language, targetBundleID: targetBundleID, metadata: metadata, updatedAtMs: now, revision: 1, pinnedAtMs: nil)
        return try withVerifiedHandle { db in
          try Self.transaction(db) { db in
            let cipher = try Self.historyCiphers(rootKey: rootKey, entry: entry, cryptoVersion: cryptoVersion)
            try Self.run(db, "INSERT INTO history_entry(id,created_at_ms,updated_at_ms,duration_ms,transcription_status,insertion_status,revision,crypto_version,text_cipher,language_cipher,target_bundle_cipher) VALUES (?,?,?,?,?,?,?,?,?,?,?)") { s in
                try Self.bind(s, 1, id.uuidString); try Self.bind(s, 2, metadata.createdAtMs); try Self.bind(s, 3, now); try Self.bind(s, 4, metadata.durationMs); try Self.bind(s, 5, metadata.transcriptionStatus.rawValue); try Self.bind(s, 6, metadata.insertionStatus.rawValue); try Self.bind(s, 7, Int64(1)); try Self.bind(s, 8, Int64(cryptoVersion)); try Self.bind(s, 9, cipher.text); try Self.bind(s, 10, cipher.language); try Self.bind(s, 11, cipher.target)
            }
            if let storageFaultPoint {
                storageFaultObserver?(storageFaultPoint)
                if storageFaultPoint == .sqliteFullAfterHistoryInsert { throw DatabaseFailure.sqlite(code: SQLITE_FULL) }
            }
            if fault == .beforeCommit { throw DatabaseFailure.injectedFault }
          }
          if fault == .afterCommitBeforeIndex { historyIndexDirty = true; throw DatabaseFailure.injectedFault }
          historySearchIndex[id] = .init(text: normalized, createdAtMs: metadata.createdAtMs, byteCount: normalizedBytes); historySearchBytes += normalizedBytes
          return entry
        }
    }

    public func historyPage(limit: Int, after: HistoryCursor? = nil) throws -> HistoryPage {
        guard (1...200).contains(limit) else { throw DatabaseFailure.invalidHistoryInput }
        try ensureHistoryIndexReady()
        return try withVerifiedHandle { db in
          var entries: [HistoryPreview] = []
          try Self.query(db, "SELECT id,created_at_ms,duration_ms,transcription_status,insertion_status,revision,pinned_at_ms,text_cipher,crypto_version FROM history_entry WHERE deleted_at_ms IS NULL AND (? IS NULL OR created_at_ms < ? OR (created_at_ms = ? AND id < ?)) ORDER BY created_at_ms DESC,id DESC LIMIT ?") { s in
            if let after { try Self.bind(s, 1, after.createdAtMs); try Self.bind(s, 2, after.createdAtMs); try Self.bind(s, 3, after.createdAtMs); try Self.bind(s, 4, after.id.uuidString) } else { try Self.bindNull(s, 1); try Self.bindNull(s, 2); try Self.bindNull(s, 3); try Self.bindNull(s, 4) }; try Self.bind(s, 5, Int64(limit + 1))
          } row: { s in
            let id = try Self.uuid(s, 0), version = try Self.cryptoVersion(s, 8); let blob = Self.blob(s, 7)
            let text = try Self.decryptHistory(rootKey: rootKey, blob: blob, id: id, column: "text", version: version)
            entries.append(try Self.historyPreview(id: id, text: text, created: sqlite3_column_int64(s, 1), duration: sqlite3_column_int64(s, 2), transcription: try Self.status(s, 3), insertion: try Self.insertion(s, 4), revision: sqlite3_column_int64(s, 5), pinnedAt: Self.optionalInt(s, 6)))
          }
          let hasNext = entries.count > limit; if hasNext { entries.removeLast() }
          return HistoryPage(entries: entries, next: hasNext ? HistoryCursor(createdAtMs: entries.last!.createdAtMs, id: entries.last!.id) : nil)
        }
    }

    public func historyEntry(id: UUID) throws -> HistoryEntry? { try withVerifiedHandle { try Self.fetchHistory($0, rootKey: rootKey, id: id, activeOnly: true) } }

    public func editHistory(id: UUID, text: String, expectedRevision: Int64, fault: HistoryFaultPoint? = nil) throws -> HistoryEntry {
        guard Self.validText(text) else { throw DatabaseFailure.invalidHistoryInput }; guard let old = try historyEntry(id: id), old.revision == expectedRevision else { throw DatabaseFailure.conflict }
        try ensureHistoryIndexReady()
        let normalized = Self.normalized(text), normalizedBytes = normalized.utf8.count, oldBytes = historySearchIndex[id]?.byteCount ?? 0
        guard Self.canReplace(historySearchBytes, removing: oldBytes, adding: normalizedBytes, limit: historySearchByteLimit) else { throw DatabaseFailure.resourceLimit }
        let now = clock.nowMilliseconds(); guard now >= 0, let next = Self.checkedIncrement(old.revision) else { throw DatabaseFailure.invalidHistoryInput }; let version: UInt32 = 1
        let sealed = try Self.sealHistory(rootKey: rootKey, text: text, id: id, column: "text", version: version)
        try withVerifiedHandle { db in try Self.transaction(db) { db in
            try Self.run(db, "UPDATE history_entry SET text_cipher=?,updated_at_ms=?,revision=?,crypto_version=? WHERE id=? AND deleted_at_ms IS NULL AND revision=?") { s in try Self.bind(s, 1, sealed); try Self.bind(s, 2, now); try Self.bind(s, 3, next); try Self.bind(s, 4, Int64(version)); try Self.bind(s, 5, id.uuidString); try Self.bind(s, 6, expectedRevision) }
            guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict }; if fault == .beforeCommit { throw DatabaseFailure.injectedFault }
        } }
        if fault == .afterCommitBeforeIndex { historyIndexDirty = true; throw DatabaseFailure.injectedFault }; historySearchIndex[id] = .init(text: normalized, createdAtMs: old.metadata.createdAtMs, byteCount: normalizedBytes); historySearchBytes = historySearchBytes - oldBytes + normalizedBytes
        return HistoryEntry(id: id, text: text, language: old.language, targetBundleID: old.targetBundleID, metadata: old.metadata, updatedAtMs: now, revision: next, pinnedAtMs: old.pinnedAtMs)
    }

    public func setPinned(id: UUID, pinned: Bool, expectedRevision: Int64) throws -> HistoryEntry {
        guard let old = try historyEntry(id: id), old.revision == expectedRevision else { throw DatabaseFailure.conflict }; let now = clock.nowMilliseconds(); guard now >= 0, let next = Self.checkedIncrement(old.revision) else { throw DatabaseFailure.invalidHistoryInput }
        try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "UPDATE history_entry SET pinned_at_ms=?,updated_at_ms=?,revision=? WHERE id=? AND deleted_at_ms IS NULL AND revision=?") { s in if pinned { try Self.bind(s, 1, now) } else { try Self.bindNull(s, 1) }; try Self.bind(s, 2, now); try Self.bind(s, 3, next); try Self.bind(s, 4, id.uuidString); try Self.bind(s, 5, expectedRevision) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict } } }
        return HistoryEntry(id: id, text: old.text, language: old.language, targetBundleID: old.targetBundleID, metadata: old.metadata, updatedAtMs: now, revision: next, pinnedAtMs: pinned ? now : nil)
    }

    public func updateInsertionStatus(id: UUID, status: InsertionStatus, expectedRevision: Int64) throws -> HistoryEntry {
        guard let old = try historyEntry(id: id), old.revision == expectedRevision else { throw DatabaseFailure.conflict }; let now = clock.nowMilliseconds(); guard now >= 0, let next = Self.checkedIncrement(old.revision) else { throw DatabaseFailure.invalidHistoryInput }
        try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "UPDATE history_entry SET insertion_status=?,updated_at_ms=?,revision=? WHERE id=? AND deleted_at_ms IS NULL AND revision=?") { s in try Self.bind(s, 1, status.rawValue); try Self.bind(s, 2, now); try Self.bind(s, 3, next); try Self.bind(s, 4, id.uuidString); try Self.bind(s, 5, expectedRevision) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict } } }
        return HistoryEntry(id: id, text: old.text, language: old.language, targetBundleID: old.targetBundleID, metadata: .init(createdAtMs: old.metadata.createdAtMs, durationMs: old.metadata.durationMs, transcriptionStatus: old.metadata.transcriptionStatus, insertionStatus: status), updatedAtMs: now, revision: next, pinnedAtMs: old.pinnedAtMs)
    }
    /// Startup recovery closes only rows whose insertion was never attempted.
    /// The transaction increments revisions so stale dashboard edits fail closed.
    public func markIncompleteHistoryFailed() throws -> Int {
        let now = clock.nowMilliseconds(); guard now >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        return try withVerifiedHandle { db in
            try Self.transaction(db) { db in
                try Self.run(db, "UPDATE history_entry SET transcription_status='failed',insertion_status='failed',updated_at_ms=?,revision=revision+1 WHERE deleted_at_ms IS NULL AND insertion_status='not_attempted'") { try Self.bind($0, 1, now) }
            }
            return Int(sqlite3_changes(db))
        }
    }

    public func softDelete(ids: [UUID], undoWindowMs: Int64 = 30_000) throws -> DeletionBatch {
        let effectiveNow = clock.nowMilliseconds()
        let addition = effectiveNow.addingReportingOverflow(undoWindowMs)
        guard !ids.isEmpty, ids.count <= 10_000, effectiveNow >= 0, (0...604_800_000).contains(undoWindowMs), !addition.overflow else { throw DatabaseFailure.invalidHistoryInput }
        let batch = DeletionBatch(id: UUID(), undoUntilMs: addition.partialValue, token: UUID()), requested = Set(ids)
        try withVerifiedHandle { db in try Self.transaction(db) { db in for id in requested { try Self.run(db, "UPDATE history_entry SET deleted_at_ms=?,purge_after_ms=?,deletion_batch_id=? WHERE id=? AND deleted_at_ms IS NULL") { s in try Self.bind(s, 1, effectiveNow); try Self.bind(s, 2, batch.undoUntilMs); try Self.bind(s, 3, batch.id.uuidString); try Self.bind(s, 4, id.uuidString) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.notFound } } } }
        deletionCapabilities[batch.id] = batch.token; for id in requested { if let removed = historySearchIndex.removeValue(forKey: id) { historySearchBytes -= removed.byteCount } }; return batch
    }

    public func softDeleteRange(olderThanCutoffMs cutoffMs: Int64, undoWindowMs: Int64 = 30_000) throws -> DeletionBatch {
        let effectiveNow = clock.nowMilliseconds()
        let addition = effectiveNow.addingReportingOverflow(undoWindowMs)
        guard effectiveNow >= 0, (0...604_800_000).contains(undoWindowMs), !addition.overflow else { throw DatabaseFailure.invalidHistoryInput }
        var ids: [UUID] = [], batch: DeletionBatch?
        try withVerifiedHandle { db in try Self.transaction(db) { db in
            try Self.query(db, "SELECT id FROM history_entry WHERE created_at_ms < ? AND deleted_at_ms IS NULL", bind: { try Self.bind($0, 1, cutoffMs) }) { s in ids.append(try Self.uuid(s, 0)) }
            guard !ids.isEmpty else { throw DatabaseFailure.notFound }
            let value = DeletionBatch(id: UUID(), undoUntilMs: addition.partialValue, token: UUID())
            try Self.run(db, "UPDATE history_entry SET deleted_at_ms=?,purge_after_ms=?,deletion_batch_id=? WHERE created_at_ms < ? AND deleted_at_ms IS NULL") { s in
                try Self.bind(s, 1, effectiveNow); try Self.bind(s, 2, value.undoUntilMs); try Self.bind(s, 3, value.id.uuidString); try Self.bind(s, 4, cutoffMs)
            }
            batch = value
        } }
        guard let batch else { throw DatabaseFailure.notFound }
        deletionCapabilities[batch.id] = batch.token; for id in ids { if let removed = historySearchIndex.removeValue(forKey: id) { historySearchBytes -= removed.byteCount } }
        return batch
    }

    var deletionCapabilityCount: Int { deletionCapabilities.count }

    public func undoDelete(_ batch: DeletionBatch, fault: HistoryFaultPoint? = nil) throws {
        let effectiveNow = clock.nowMilliseconds(); guard effectiveNow >= 0, deletionCapabilities[batch.id] == batch.token else { throw DatabaseFailure.conflict }
        try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "UPDATE history_entry SET deleted_at_ms=NULL,purge_after_ms=NULL,deletion_batch_id=NULL WHERE deletion_batch_id=? AND purge_after_ms>?") { s in try Self.bind(s, 1, batch.id.uuidString); try Self.bind(s, 2, effectiveNow) }; guard sqlite3_changes(db) > 0 else { throw DatabaseFailure.conflict } } }
        deletionCapabilities[batch.id] = nil
        try markDirtyAndRebuild(fault: fault)
    }

    public func purgeDue(fault: HistoryFaultPoint? = nil) throws -> Int {
        let effectiveNow = clock.nowMilliseconds(); guard effectiveNow >= 0 else { throw DatabaseFailure.invalidHistoryInput }; var count = 0
        try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "DELETE FROM history_entry WHERE deleted_at_ms IS NOT NULL AND purge_after_ms<=?") { try Self.bind($0, 1, effectiveNow) }; count = Int(sqlite3_changes(db)) } }
        try pruneDeletionCapabilities(); try markDirtyAndRebuild(fault: fault); return count
    }

    public func sweepRetention(_ retention: HistoryRetention, fault: HistoryFaultPoint? = nil) throws -> Int {
        let effectiveNow = clock.nowMilliseconds(); guard effectiveNow >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        let days: Int64? = switch retention { case .days7: 7; case .days14: 14; case .days30: 30; case .days90: 90; case .forever, .none: nil }
        guard let days else { return 0 }
        let offset = days * 86_400_000
        let difference = effectiveNow.subtractingReportingOverflow(offset); guard !difference.overflow else { throw DatabaseFailure.invalidHistoryInput }
        var count = 0; try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "DELETE FROM history_entry WHERE created_at_ms<?") { try Self.bind($0, 1, difference.partialValue) }; count = Int(sqlite3_changes(db)) } }; try pruneDeletionCapabilities(); try markDirtyAndRebuild(fault: fault); return count
    }

    public func makeClearHistoryConfirmation() -> ClearHistoryConfirmation { let value = UUID(); clearConfirmation = value; return ClearHistoryConfirmation(value) }
    public func clearAll(using confirmation: ClearHistoryConfirmation) throws {
        guard clearConfirmation == confirmation.token else { throw DatabaseFailure.confirmationRequired }; try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "DELETE FROM history_entry") { _ in } } }; clearConfirmation = nil; deletionCapabilities = [:]; historySearchIndex = [:]; historySearchBytes = 0; historyIndexDirty = false
    }

    public func makeResetAllLocalAppDataConfirmation() -> ResetAllLocalAppDataConfirmation { let value = UUID(); resetAllConfirmation = value; return .init(value) }
    /// Deletes user history, dictionary, preferences and scheduler state and
    /// resets lifetime aggregates in one transaction. The key anchor and
    /// migration ledger deliberately survive.
    public func resetAllLocalAppData(using confirmation: ResetAllLocalAppDataConfirmation) throws {
        guard resetAllConfirmation == confirmation.token else { throw DatabaseFailure.confirmationRequired }
        let trackingStartedAtMs = clock.nowMilliseconds()
        guard trackingStartedAtMs >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        try withVerifiedHandle { db in try Self.transaction(db) { db in
            try Self.run(db, "DELETE FROM history_entry") { _ in }
            try Self.run(db, "DELETE FROM dictionary_entry") { _ in }
            try Self.run(db, "DELETE FROM app_settings WHERE key='preferences.v1'") { _ in }
            try Self.run(db, "DELETE FROM retention_scheduler_state") { _ in }
            try Self.resetStatistics(db, rootKey: rootKey, trackingStartedAtMs: trackingStartedAtMs)
        } }
        resetAllConfirmation = nil; clearConfirmation = nil; deletionCapabilities = [:]; historySearchIndex = [:]; historySearchBytes = 0; historyIndexDirty = false; invalidateDictionaryCache(); pendingPreferencesRevisionNotifications.removeAll()
    }

    private static let retentionSchedulerAADID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    public func retentionScheduleState() throws -> RetentionScheduleState {
        try withVerifiedHandle { db in
            var output = RetentionScheduleState(lastSuccessMs: nil, nextDueMs: nil)
            try Self.query(db, "SELECT revision,crypto_version,state_cipher FROM retention_scheduler_state WHERE id=1", bind: { _ in }) { s in
                guard sqlite3_column_int64(s, 0) > 0 else { throw DatabaseFailure.wrongKeyOrTampered }
                let version = try Self.cryptoVersion(s, 1)
                let data = try DomainFieldCipher(rootKey: rootKey, domain: .settings).open(.init(bytes: Self.blob(s, 2)), aad: .init(cryptoVersion: version, table: "retention_scheduler_state", rowID: Self.retentionSchedulerAADID, column: "state"))
                guard data.count == 16 else { throw DatabaseFailure.wrongKeyOrTampered }
                let values = (Self.decodeBigEndianInt64(data, offset: 0), Self.decodeBigEndianInt64(data, offset: 8))
                guard values.0 >= -1, values.1 >= -1 else { throw DatabaseFailure.wrongKeyOrTampered }
                output = .init(lastSuccessMs: values.0 < 0 ? nil : values.0, nextDueMs: values.1 < 0 ? nil : values.1)
            }
            return output
        }
    }
    public func saveRetentionScheduleState(_ state: RetentionScheduleState) throws {
        guard state.lastSuccessMs ?? 0 >= 0, state.nextDueMs ?? 0 >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        var data = Data(); for value in [state.lastSuccessMs ?? -1, state.nextDueMs ?? -1] { var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
        let sealed = try DomainFieldCipher(rootKey: rootKey, domain: .settings).seal(data, aad: .init(cryptoVersion: 1, table: "retention_scheduler_state", rowID: Self.retentionSchedulerAADID, column: "state")).bytes
        try withVerifiedHandle { db in try Self.transaction(db) { db in
            try Self.run(db, "INSERT INTO retention_scheduler_state(id,revision,crypto_version,state_cipher) VALUES(1,1,1,?) ON CONFLICT(id) DO UPDATE SET revision=retention_scheduler_state.revision+1,crypto_version=1,state_cipher=excluded.state_cipher") { try Self.bind($0, 1, sealed) }
        } }
    }
    private static func decodeBigEndianInt64(_ data: Data, offset: Int) -> Int64 {
        var value: UInt64 = 0
        for byte in data[offset..<(offset + 8)] { value = (value << 8) | UInt64(byte) }
        return Int64(bitPattern: value)
    }

    // MARK: - Content-free lifetime statistics (schema v3)

    private static let statisticsAADID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    private static let statisticsPayloadMagic = Data("KSSTATV1".utf8)

    public func statisticsSnapshot() throws -> DictationStatisticsSnapshot {
        try withVerifiedHandle { try Self.readStatistics($0, rootKey: rootKey) }
    }

    public func recordDictationStatistics(
        wordCount: Int64,
        recordedMilliseconds: Int64,
        dayIdentifier: Int64
    ) throws -> DictationStatisticsSnapshot {
        guard wordCount >= 0,
              (0...86_400_000).contains(recordedMilliseconds),
              dayIdentifier >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        var result: DictationStatisticsSnapshot?
        try withVerifiedHandle { db in
            try Self.transaction(db) { db in
                let old = try Self.readStatistics(db, rootKey: rootKey)
                guard let totalDictations = Self.checkedAdd(old.totalDictations, 1),
                      let totalWords = Self.checkedAdd(old.totalWords, wordCount),
                      let totalRecorded = Self.checkedAdd(old.totalRecordedMilliseconds, recordedMilliseconds),
                      let revision = Self.checkedIncrement(old.revision) else {
                    throw DatabaseFailure.invalidHistoryInput
                }
                var currentStreak = old.currentStreakDays
                var longestStreak = old.longestStreakDays
                var lastDay = old.lastDayIdentifier
                if let previous = old.lastDayIdentifier {
                    if dayIdentifier > previous {
                        let following = previous.addingReportingOverflow(1)
                        if !following.overflow, dayIdentifier == following.partialValue {
                            guard let incremented = Self.checkedIncrement(currentStreak) else {
                                throw DatabaseFailure.invalidHistoryInput
                            }
                            currentStreak = incremented
                        } else {
                            currentStreak = 1
                        }
                        longestStreak = max(longestStreak, currentStreak)
                        lastDay = dayIdentifier
                    }
                } else {
                    currentStreak = 1
                    longestStreak = max(longestStreak, 1)
                    lastDay = dayIdentifier
                }
                let next = DictationStatisticsSnapshot(
                    totalDictations: totalDictations,
                    totalWords: totalWords,
                    totalRecordedMilliseconds: totalRecorded,
                    currentStreakDays: currentStreak,
                    longestStreakDays: longestStreak,
                    lastDayIdentifier: lastDay,
                    trackingStartedAtMs: old.trackingStartedAtMs,
                    revision: revision
                )
                guard Self.validStatistics(next) else { throw DatabaseFailure.invalidHistoryInput }
                let sealed = try Self.sealStatistics(next, rootKey: rootKey)
                try Self.run(
                    db,
                    "UPDATE dictation_statistics SET revision=?,crypto_version=1,payload_cipher=? WHERE id=1 AND revision=?"
                ) { statement in
                    try Self.bind(statement, 1, revision)
                    try Self.bind(statement, 2, sealed)
                    try Self.bind(statement, 3, old.revision)
                }
                guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict }
                result = next
            }
        }
        guard let result else { throw DatabaseFailure.wrongKeyOrTampered }
        return result
    }

    private static func checkedAdd(_ left: Int64, _ right: Int64) -> Int64? {
        let value = left.addingReportingOverflow(right)
        return value.overflow ? nil : value.partialValue
    }

    private static func initialStatistics(trackingStartedAtMs: Int64, revision: Int64 = 1) throws -> DictationStatisticsSnapshot {
        let value = DictationStatisticsSnapshot(
            totalDictations: 0,
            totalWords: 0,
            totalRecordedMilliseconds: 0,
            currentStreakDays: 0,
            longestStreakDays: 0,
            lastDayIdentifier: nil,
            trackingStartedAtMs: trackingStartedAtMs,
            revision: revision
        )
        guard validStatistics(value) else { throw DatabaseFailure.invalidHistoryInput }
        return value
    }

    private static func insertInitialStatistics(
        _ db: OpaquePointer,
        rootKey: Data,
        trackingStartedAtMs: Int64
    ) throws {
        let value = try initialStatistics(trackingStartedAtMs: trackingStartedAtMs)
        let sealed = try sealStatistics(value, rootKey: rootKey)
        try run(
            db,
            "INSERT INTO dictation_statistics(id,revision,crypto_version,payload_cipher) VALUES(1,1,1,?)"
        ) { try bind($0, 1, sealed) }
    }

    private static func resetStatistics(
        _ db: OpaquePointer,
        rootKey: Data,
        trackingStartedAtMs: Int64
    ) throws {
        let old = try readStatistics(db, rootKey: rootKey)
        guard let revision = checkedIncrement(old.revision) else { throw DatabaseFailure.invalidHistoryInput }
        let value = try initialStatistics(trackingStartedAtMs: trackingStartedAtMs, revision: revision)
        let sealed = try sealStatistics(value, rootKey: rootKey)
        try run(
            db,
            "UPDATE dictation_statistics SET revision=?,crypto_version=1,payload_cipher=? WHERE id=1 AND revision=?"
        ) { statement in
            try bind(statement, 1, revision)
            try bind(statement, 2, sealed)
            try bind(statement, 3, old.revision)
        }
        guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict }
    }

    private static func readStatistics(
        _ db: OpaquePointer?,
        rootKey: Data
    ) throws -> DictationStatisticsSnapshot {
        var rowCount = 0
        var output: DictationStatisticsSnapshot?
        try query(
            db,
            "SELECT id,revision,crypto_version,payload_cipher FROM dictation_statistics ORDER BY id",
            bind: { _ in }
        ) { statement in
            rowCount += 1
            let id = sqlite3_column_int64(statement, 0)
            let revision = sqlite3_column_int64(statement, 1)
            let version = try cryptoVersion(statement, 2)
            guard id == 1, revision > 0 else { throw DatabaseFailure.wrongKeyOrTampered }
            let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .statistics)
            let clear = try cipher.open(
                .init(bytes: blob(statement, 3)),
                aad: statisticsAAD(cryptoVersion: version, revision: revision)
            )
            let decoded = try decodeStatistics(clear)
            guard decoded.revision == revision, validStatistics(decoded) else {
                throw DatabaseFailure.wrongKeyOrTampered
            }
            output = decoded
        }
        guard rowCount == 1, let output else { throw DatabaseFailure.wrongKeyOrTampered }
        return output
    }

    private static func sealStatistics(
        _ value: DictationStatisticsSnapshot,
        rootKey: Data
    ) throws -> Data {
        let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .statistics)
        return try cipher.seal(
            encodeStatistics(value),
            aad: statisticsAAD(cryptoVersion: 1, revision: value.revision)
        ).bytes
    }

    private static func statisticsAAD(cryptoVersion: UInt32, revision: Int64) -> PersistenceAAD {
        .init(
            cryptoVersion: cryptoVersion,
            table: "dictation_statistics",
            rowID: statisticsAADID,
            column: "payload_cipher/revision/\(revision)"
        )
    }

    private static func encodeStatistics(_ value: DictationStatisticsSnapshot) -> Data {
        var data = statisticsPayloadMagic
        let fields = [
            value.totalDictations,
            value.totalWords,
            value.totalRecordedMilliseconds,
            value.currentStreakDays,
            value.longestStreakDays,
            value.lastDayIdentifier ?? -1,
            value.trackingStartedAtMs,
            value.revision
        ]
        for field in fields {
            var bigEndian = field.bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func decodeStatistics(_ data: Data) throws -> DictationStatisticsSnapshot {
        let fieldCount = 8
        guard data.count == statisticsPayloadMagic.count + fieldCount * 8,
              data.prefix(statisticsPayloadMagic.count) == statisticsPayloadMagic else {
            throw DatabaseFailure.wrongKeyOrTampered
        }
        let offset = statisticsPayloadMagic.count
        let fields = (0..<fieldCount).map { decodeBigEndianInt64(data, offset: offset + $0 * 8) }
        return .init(
            totalDictations: fields[0],
            totalWords: fields[1],
            totalRecordedMilliseconds: fields[2],
            currentStreakDays: fields[3],
            longestStreakDays: fields[4],
            lastDayIdentifier: fields[5] == -1 ? nil : fields[5],
            trackingStartedAtMs: fields[6],
            revision: fields[7]
        )
    }

    private static func validStatistics(_ value: DictationStatisticsSnapshot) -> Bool {
        guard value.totalDictations >= 0,
              value.totalWords >= 0,
              value.totalRecordedMilliseconds >= 0,
              value.currentStreakDays >= 0,
              value.longestStreakDays >= value.currentStreakDays,
              value.trackingStartedAtMs >= 0,
              value.revision > 0,
              value.lastDayIdentifier.map({ $0 >= 0 }) ?? true else { return false }
        if value.totalDictations == 0 {
            return value.totalWords == 0 && value.totalRecordedMilliseconds == 0 &&
                value.currentStreakDays == 0 && value.longestStreakDays == 0 &&
                value.lastDayIdentifier == nil
        }
        return value.currentStreakDays > 0 && value.longestStreakDays > 0 &&
            value.lastDayIdentifier != nil
    }

    public func searchHistory(_ query: String, limit: Int = 100) throws -> [HistoryPreview] {
        guard limit > 0 && limit <= 200, query.utf8.count <= 4_096 else { throw DatabaseFailure.invalidHistoryInput }; let needle = Self.normalized(query); guard !needle.isEmpty else { return [] }
        try ensureHistoryIndexReady()
        return try withVerifiedHandle { _ in
        var result: [HistoryPreview] = []
        // The RAM index narrows candidates before decrypt-confirm. A bounded overfetch
        // keeps common broad queries from decrypting an unbounded history in one search.
        let candidates = historySearchIndex.filter({ $0.value.text.contains(needle) }).sorted { a, b in a.value.createdAtMs == b.value.createdAtMs ? a.key.uuidString > b.key.uuidString : a.value.createdAtMs > b.value.createdAtMs }.prefix(min(historySearchIndex.count, max(limit * 4, 400))).map(\.key)
        for id in candidates { if let entry = try historyEntry(id: id), Self.normalized(entry.text).contains(needle) { result.append(.init(id: entry.id, text: Self.preview(entry.text), createdAtMs: entry.metadata.createdAtMs, durationMs: entry.metadata.durationMs, transcriptionStatus: entry.metadata.transcriptionStatus, insertionStatus: entry.metadata.insertionStatus, revision: entry.revision, pinnedAtMs: entry.pinnedAtMs)) } }
        return Array(result.sorted { $0.createdAtMs == $1.createdAtMs ? $0.id.uuidString > $1.id.uuidString : $0.createdAtMs > $1.createdAtMs }.prefix(limit))
        }
    }

    public func rebuildHistorySearchIndex(fault: HistoryFaultPoint? = nil) throws { try withVerifiedHandle { db in if fault == .beforeIndexRebuild { throw DatabaseFailure.injectedFault }; let rebuilt = try Self.readSearchIndex(db, rootKey: rootKey, byteLimit: historySearchByteLimit); historySearchIndex = rebuilt.index; historySearchBytes = rebuilt.bytes; historyIndexDirty = false } }
    private func markDirtyAndRebuild(fault: HistoryFaultPoint? = nil) throws { historyIndexDirty = true; try rebuildHistorySearchIndex(fault: fault) }
    private func pruneDeletionCapabilities() throws { try withVerifiedHandle { db in var live = Set<UUID>(); try Self.query(db, "SELECT DISTINCT deletion_batch_id FROM history_entry WHERE deletion_batch_id IS NOT NULL", bind: { _ in }) { s in if let raw = sqlite3_column_text(s, 0), let id = UUID(uuidString: String(cString: raw)) { live.insert(id) } else { throw DatabaseFailure.wrongKeyOrTampered } }; deletionCapabilities = deletionCapabilities.filter { live.contains($0.key) } } }
    private func ensureHistoryIndexReady() throws { try withVerifiedHandle { _ in if historyIndexDirty { try rebuildHistorySearchIndex() } } }
    private func withVerifiedHandle<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard connection.handle != nil else { throw DatabaseFailure.closed }
        try Self.verifyHandleIdentity(connection.handle); guard try boundIdentity(databaseURL) == boundDatabaseIdentity else { throw DatabaseFailure.insecurePath }
        do { let result = try body(connection.handle!); try Self.verifyHandleIdentity(connection.handle); return result }
        catch { _ = try? Self.verifyHandleIdentity(connection.handle); throw error }
    }
    private static func validText(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 100_000 && String(data: Data(value.utf8), encoding: .utf8) != nil }
    private static func validateHistory(text: String, language: String?, targetBundleID: String?, metadata: HistoryMetadata, id: UUID, cryptoVersion: UInt32) throws {
        guard validText(text), language.map({ !$0.isEmpty && $0.utf8.count <= 64 }) ?? true, targetBundleID.map({ !$0.isEmpty && $0.utf8.count <= 255 }) ?? true, metadata.createdAtMs >= 0, metadata.durationMs >= 0, metadata.durationMs <= 24 * 60 * 60 * 1_000, cryptoVersion == 1, id.uuidString.count == 36 else { throw DatabaseFailure.invalidHistoryInput }
    }
    private static func normalized(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping }
    private static func preview(_ value: String) -> String { String(value.prefix(280)) }
    private static func historyCiphers(rootKey: Data, entry: HistoryEntry, cryptoVersion: UInt32) throws -> (text: Data, language: Data?, target: Data?) {
        (try sealHistory(rootKey: rootKey, text: entry.text, id: entry.id, column: "text", version: cryptoVersion), try entry.language.map { try sealHistory(rootKey: rootKey, text: $0, id: entry.id, column: "language", version: cryptoVersion) }, try entry.targetBundleID.map { try sealHistory(rootKey: rootKey, text: $0, id: entry.id, column: "target_bundle", version: cryptoVersion) })
    }
    private static func sealHistory(rootKey: Data, text: String, id: UUID, column: String, version: UInt32) throws -> Data { try DomainFieldCipher(rootKey: rootKey, domain: .history).seal(Data(text.utf8), aad: .init(cryptoVersion: version, table: "history_entry", rowID: id, column: column)).bytes }
    private static func decryptHistory(rootKey: Data, blob: Data, id: UUID, column: String, version: UInt32) throws -> String { let data = try DomainFieldCipher(rootKey: rootKey, domain: .history).open(.init(bytes: blob), aad: .init(cryptoVersion: version, table: "history_entry", rowID: id, column: column)); guard let string = String(data: data, encoding: .utf8) else { throw DatabaseFailure.wrongKeyOrTampered }; return string }
    private static func checkedIncrement(_ value: Int64) -> Int64? { let result = value.addingReportingOverflow(1); return result.overflow ? nil : result.partialValue }
    private static func historyPreview(id: UUID, text: String, created: Int64, duration: Int64, transcription: TranscriptStatus, insertion: InsertionStatus, revision: Int64, pinnedAt: Int64?) throws -> HistoryPreview {
        guard created >= 0, duration >= 0, duration <= 86_400_000, revision > 0,
              pinnedAt.map({ $0 >= created }) ?? true else { throw DatabaseFailure.wrongKeyOrTampered }
        return .init(id: id, text: preview(text), createdAtMs: created, durationMs: duration, transcriptionStatus: transcription, insertionStatus: insertion, revision: revision, pinnedAtMs: pinnedAt)
    }
    private static func canAdd(_ current: Int, _ adding: Int, limit: Int) -> Bool { adding >= 0 && current >= 0 && adding <= limit && current <= limit - adding }
    private static func canReplace(_ current: Int, removing: Int, adding: Int, limit: Int) -> Bool { removing >= 0 && current >= removing && canAdd(current - removing, adding, limit: limit) }
    private static func readSearchIndex(_ db: OpaquePointer?, rootKey: Data, byteLimit: Int) throws -> (index: [UUID: SearchRecord], bytes: Int) {
        var index: [UUID: SearchRecord] = [:], bytes = 0
        try query(db, "SELECT id,text_cipher,crypto_version,created_at_ms FROM history_entry WHERE deleted_at_ms IS NULL", bind: { _ in }) { s in
            let id = try uuid(s, 0); let text = try decryptHistory(rootKey: rootKey, blob: blob(s, 1), id: id, column: "text", version: try cryptoVersion(s, 2)); let created = sqlite3_column_int64(s, 3)
            let normalizedText = normalized(text), count = normalizedText.utf8.count
            guard created >= 0, canAdd(bytes, count, limit: byteLimit) else { throw DatabaseFailure.resourceLimit }
            bytes += count; index[id] = .init(text: normalizedText, createdAtMs: created, byteCount: count)
        }
        return (index, bytes)
    }
    private static func fetchHistory(_ db: OpaquePointer?, rootKey: Data, id: UUID, activeOnly: Bool) throws -> HistoryEntry? {
        let sql = "SELECT created_at_ms,updated_at_ms,duration_ms,transcription_status,insertion_status,pinned_at_ms,revision,crypto_version,text_cipher,language_cipher,target_bundle_cipher FROM history_entry WHERE id=?" + (activeOnly ? " AND deleted_at_ms IS NULL" : "")
        var entry: HistoryEntry?; try query(db, sql, bind: { try bind($0, 1, id.uuidString) }, row: { s in let version = try cryptoVersion(s, 7); let created = sqlite3_column_int64(s, 0), updated = sqlite3_column_int64(s, 1), duration = sqlite3_column_int64(s, 2), revision = sqlite3_column_int64(s, 6); guard created >= 0, updated >= created, duration >= 0, duration <= 86_400_000, revision > 0, Self.optionalInt(s, 5).map({ $0 >= created }) ?? true else { throw DatabaseFailure.wrongKeyOrTampered }; let text = try decryptHistory(rootKey: rootKey, blob: blob(s, 8), id: id, column: "text", version: version); let language = try optionalBlob(s, 9).map { try decryptHistory(rootKey: rootKey, blob: $0, id: id, column: "language", version: version) }; let target = try optionalBlob(s, 10).map { try decryptHistory(rootKey: rootKey, blob: $0, id: id, column: "target_bundle", version: version) }; entry = .init(id: id, text: text, language: language, targetBundleID: target, metadata: .init(createdAtMs: created, durationMs: duration, transcriptionStatus: try status(s, 3), insertionStatus: try insertion(s, 4)), updatedAtMs: updated, revision: revision, pinnedAtMs: optionalInt(s, 5)) }); return entry
    }
    private static func status(_ s: OpaquePointer, _ column: Int32) throws -> TranscriptStatus { guard let raw = sqlite3_column_text(s, column), let value = TranscriptStatus(rawValue: String(cString: raw)) else { throw DatabaseFailure.wrongKeyOrTampered }; return value }
    private static func insertion(_ s: OpaquePointer, _ column: Int32) throws -> InsertionStatus { guard let raw = sqlite3_column_text(s, column), let value = InsertionStatus(rawValue: String(cString: raw)) else { throw DatabaseFailure.wrongKeyOrTampered }; return value }
    /// IDs are stored in Foundation's uppercase canonical UUID spelling. Accepting another
    /// spelling would let a tampered SQLite row alias an existing logical UUID while its
    /// ciphertext still authenticates against that UUID's byte value.
    private static func uuid(_ s: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let raw = sqlite3_column_text(s, column) else { throw DatabaseFailure.wrongKeyOrTampered }
        let persisted = String(cString: raw)
        guard let id = UUID(uuidString: persisted), persisted == id.uuidString else { throw DatabaseFailure.wrongKeyOrTampered }
        return id
    }
    private static func cryptoVersion(_ s: OpaquePointer, _ column: Int32) throws -> UInt32 { let value = sqlite3_column_int64(s, column); guard value == 1 else { throw DatabaseFailure.wrongKeyOrTampered }; return 1 }
    private static func blob(_ s: OpaquePointer, _ column: Int32) -> Data { let count = Int(sqlite3_column_bytes(s, column)); guard let base = sqlite3_column_blob(s, column), count > 0 else { return Data() }; return Data(bytes: base, count: count) }
    private static func optionalBlob(_ s: OpaquePointer, _ column: Int32) -> Data? { sqlite3_column_type(s, column) == SQLITE_NULL ? nil : blob(s, column) }
    private static func optionalInt(_ s: OpaquePointer, _ column: Int32) -> Int64? { sqlite3_column_type(s, column) == SQLITE_NULL ? nil : sqlite3_column_int64(s, column) }
    private static func transaction(_ db: OpaquePointer?, _ body: (OpaquePointer) throws -> Void) throws { guard let db else { throw DatabaseFailure.sqlite(code: SQLITE_MISUSE) }; try verifyHandleIdentity(db); try execute(db, "BEGIN IMMEDIATE"); do { try body(db); try verifyHandleIdentity(db); try execute(db, "COMMIT") } catch { _ = try? execute(db, "ROLLBACK"); throw error } }
    private static func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) throws -> Void) throws { var s: OpaquePointer?; let result = sqlite3_prepare_v2(db, sql, -1, &s, nil); guard result == SQLITE_OK, let s else { throw DatabaseFailure.sqlite(code: result) }; defer { sqlite3_finalize(s) }; try bind(s); let stepped = sqlite3_step(s); guard stepped == SQLITE_DONE else { if stepped == SQLITE_CONSTRAINT { throw DatabaseFailure.conflict }; throw DatabaseFailure.sqlite(code: stepped) } }
    private static func query(_ db: OpaquePointer?, _ sql: String, bind: (OpaquePointer) throws -> Void, row: (OpaquePointer) throws -> Void) throws { guard let db else { throw DatabaseFailure.sqlite(code: SQLITE_MISUSE) }; var s: OpaquePointer?; let result = sqlite3_prepare_v2(db, sql, -1, &s, nil); guard result == SQLITE_OK, let s else { throw DatabaseFailure.sqlite(code: result) }; defer { sqlite3_finalize(s) }; try bind(s); while true { let stepped = sqlite3_step(s); if stepped == SQLITE_DONE { return }; guard stepped == SQLITE_ROW else { throw DatabaseFailure.sqlite(code: stepped) }; try row(s) } }
    private static func bind(_ s: OpaquePointer, _ index: Int32, _ value: String) throws { guard sqlite3_bind_text(s, index, value, -1, SQLITE_TRANSIENT_KS) == SQLITE_OK else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(sqlite3_db_handle(s))) } }
    private static func bind(_ s: OpaquePointer, _ index: Int32, _ value: Int64) throws { guard sqlite3_bind_int64(s, index, value) == SQLITE_OK else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(sqlite3_db_handle(s))) } }
    private static func bind(_ s: OpaquePointer, _ index: Int32, _ value: Data?) throws { guard let value else { return try bindNull(s, index) }; let result = value.withUnsafeBytes { sqlite3_bind_blob(s, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT_KS) }; guard result == SQLITE_OK else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(sqlite3_db_handle(s))) } }
    private static func bindNull(_ s: OpaquePointer, _ index: Int32) throws { guard sqlite3_bind_null(s, index) == SQLITE_OK else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(sqlite3_db_handle(s))) } }

    // MARK: - Dictionary (P6-03)
    public func saveDictionaryEntry(kind: DictionaryEntryKind, source: String, replacement: String = "", recognitionHint: String? = nil, enabled: Bool = true, matchMode: DictionaryMatchMode = .literal, caseSensitive: Bool = false, sortOrder: Int64 = 0, id: UUID = UUID()) throws -> DictionaryEntry {
        guard !source.isEmpty, source.utf8.count <= 4_096, replacement.utf8.count <= 4_096, recognitionHint.map({ !$0.isEmpty && $0.utf8.count <= 4_096 }) ?? true,
              !source.utf8.contains(0), !replacement.utf8.contains(0), !(recognitionHint?.utf8.contains(0) ?? false),
              (kind == .replacement ? !replacement.isEmpty : (replacement.isEmpty && recognitionHint != nil)), sortOrder >= 0 else { throw DatabaseFailure.invalidHistoryInput }
        let entry = DictionaryEntry(id: id, kind: kind, source: source, replacement: replacement, recognitionHint: recognitionHint, enabled: enabled, matchMode: matchMode, caseSensitive: caseSensitive, sortOrder: sortOrder, revision: 1)
        let admitted = try admitDictionary(entry, replacing: nil)
        return try withVerifiedHandle { db in
            let count = Int(try Self.scalar(db, sql: "SELECT count(*) FROM dictionary_entry;") ?? "-1") ?? -1
            guard count >= 0 && count < 10_000 else { throw DatabaseFailure.resourceLimit }
            let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .dictionary)
            func seal(_ value: String, _ column: String) throws -> Data { try cipher.seal(Data(value.utf8), aad: .init(cryptoVersion: 1, table: "dictionary_entry", rowID: id, column: column)).bytes }
            try Self.transaction(db) { db in try Self.run(db, "INSERT INTO dictionary_entry(id,kind,enabled,match_mode,case_sensitive,sort_order,revision,crypto_version,source_cipher,replacement_cipher,recognition_hint_cipher) VALUES(?,?,?,?,?,?,?,?,?,?,?)") { s in try Self.bind(s, 1, id.uuidString); try Self.bind(s, 2, kind.rawValue); try Self.bind(s, 3, enabled ? 1 : 0); try Self.bind(s, 4, matchMode.rawValue); try Self.bind(s, 5, caseSensitive ? 1 : 0); try Self.bind(s, 6, sortOrder); try Self.bind(s, 7, 1); try Self.bind(s, 8, 1); try Self.bind(s, 9, seal(source, "source")); try Self.bind(s, 10, seal(replacement, "replacement")); try Self.bind(s, 11, try recognitionHint.map { try seal($0, "recognition_hint") }) } }
            dictionaryCache = admitted.entries; dictionaryAdmissionBytes = admitted.bytes; dictionaryStoredBytes = admitted.storedBytes; dictionaryCompiled = nil
            return entry
        }
    }
    public func dictionaryEntries() throws -> [DictionaryEntry] { try withVerifiedHandle { db in var result: [DictionaryEntry] = [], materializedBytes = 0; try Self.query(db, "SELECT id,kind,enabled,match_mode,case_sensitive,sort_order,revision,crypto_version,source_cipher,replacement_cipher,recognition_hint_cipher FROM dictionary_entry ORDER BY sort_order,id", bind: { _ in }) { s in
        let id = try Self.uuid(s, 0), version = try Self.cryptoVersion(s, 7), revision = sqlite3_column_int64(s, 6), order = sqlite3_column_int64(s, 5), enabled = sqlite3_column_int64(s, 2), sensitive = sqlite3_column_int64(s, 4)
        guard revision > 0, order >= 0, (enabled == 0 || enabled == 1), (sensitive == 0 || sensitive == 1), let kindRaw = sqlite3_column_text(s, 1), let kind = DictionaryEntryKind(rawValue: String(cString: kindRaw)), let matchRaw = sqlite3_column_text(s, 3), let match = DictionaryMatchMode(rawValue: String(cString: matchRaw)) else { throw DatabaseFailure.wrongKeyOrTampered }
        let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .dictionary); func open(_ blob: Data, _ column: String) throws -> String { let data = try cipher.open(.init(bytes: blob), aad: .init(cryptoVersion: version, table: "dictionary_entry", rowID: id, column: column)); guard let value = String(data: data, encoding: .utf8) else { throw DatabaseFailure.wrongKeyOrTampered }; return value }
        let source = try open(Self.blob(s, 8), "source"), replacement = try open(Self.blob(s, 9), "replacement"), hint = try Self.optionalBlob(s, 10).map { try open($0, "recognition_hint") }
        materializedBytes += source.utf8.count + replacement.utf8.count + (hint?.utf8.count ?? 0)
        guard materializedBytes <= dictionaryIndexByteLimit, !source.isEmpty, (kind == .replacement || (replacement.isEmpty && hint != nil)) else { throw DatabaseFailure.resourceLimit }; result.append(.init(id: id, kind: kind, source: source, replacement: replacement, recognitionHint: hint, enabled: enabled == 1, matchMode: match, caseSensitive: sensitive == 1, sortOrder: order, revision: revision)) }; return result } }
    public func transformDictionary(_ text: String, maximumOutputBytes: Int = DictionaryTransformer.maximumOutputBytes) throws -> String {
        let entries: [DictionaryEntry]
        if let dictionaryCache { entries = dictionaryCache } else { let loaded = try dictionaryEntries(); let bytes = loaded.reduce(0) { $0 + $1.source.utf8.count + $1.replacement.utf8.count + ($1.recognitionHint?.utf8.count ?? 0) }; guard bytes <= dictionaryIndexByteLimit else { throw DatabaseFailure.resourceLimit }; dictionaryCache = loaded; dictionaryStoredBytes = bytes; dictionaryAdmissionBytes = DictionaryTransformer.admissionBytes(loaded); entries = loaded }
        if dictionaryCompiled == nil { let compiled = DictionaryTransformer.compile(entries); guard compiled.estimatedBytes <= dictionaryIndexByteLimit else { throw DatabaseFailure.resourceLimit }; dictionaryCompiled = compiled }
        return try DictionaryTransformer.apply(text, compiled: dictionaryCompiled!, maximumOutputBytes: maximumOutputBytes)
    }
    public func createDictionaryEntry(_ draft: DictionaryDraft, id: UUID = UUID()) throws -> DictionaryEntry {
        try saveDictionaryEntry(kind: draft.kind, source: draft.source, replacement: draft.replacement, recognitionHint: draft.recognitionHint, enabled: draft.enabled, matchMode: draft.matchMode, caseSensitive: draft.caseSensitive, sortOrder: draft.sortOrder, id: id)
    }
    public func dictionaryEntry(id: UUID) throws -> DictionaryEntry? { try dictionaryEntries().first { $0.id == id } }
    public func dictionaryPage(limit: Int, after: DictionaryCursor? = nil) throws -> DictionaryPage {
        guard (1...200).contains(limit) else { throw DatabaseFailure.invalidHistoryInput }
        let values = try dictionaryEntries().filter { guard let after else { return true }; return $0.sortOrder > after.sortOrder || ($0.sortOrder == after.sortOrder && $0.id.uuidString > after.id.uuidString) }
        let slice = Array(values.prefix(limit + 1)), hasNext = slice.count > limit, page = hasNext ? Array(slice.dropLast()) : slice
        return .init(entries: page, next: hasNext ? .init(sortOrder: page.last!.sortOrder, id: page.last!.id) : nil)
    }
    public func searchDictionary(_ query: String, limit: Int = 100) throws -> [DictionaryEntry] {
        guard (1...200).contains(limit), !query.isEmpty, query.utf8.count <= 4_096 else { throw DatabaseFailure.invalidHistoryInput }
        let needle = query.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
        return Array(try dictionaryEntries().filter { $0.source.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping.contains(needle) || $0.replacement.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping.contains(needle) || ($0.recognitionHint?.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping.contains(needle) ?? false) }.prefix(limit))
    }
    public func updateDictionaryEntry(id: UUID, draft: DictionaryDraft, expectedRevision: Int64, fault: HistoryFaultPoint? = nil) throws -> DictionaryEntry {
        guard let old = try dictionaryEntry(id: id), old.revision == expectedRevision, expectedRevision > 0 else { throw DatabaseFailure.conflict }
        let next = expectedRevision.addingReportingOverflow(1); guard !next.overflow else { throw DatabaseFailure.invalidHistoryInput }
        _ = try validateDictionaryDraft(draft)
        let prospective = DictionaryEntry(id: id, kind: draft.kind, source: draft.source, replacement: draft.replacement, recognitionHint: draft.recognitionHint, enabled: draft.enabled, matchMode: draft.matchMode, caseSensitive: draft.caseSensitive, sortOrder: draft.sortOrder, revision: next.partialValue)
        let admitted = try admitDictionary(prospective, replacing: id)
        let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .dictionary)
        func seal(_ value: String, _ column: String) throws -> Data { try cipher.seal(Data(value.utf8), aad: .init(cryptoVersion: 1, table: "dictionary_entry", rowID: id, column: column)).bytes }
        try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "UPDATE dictionary_entry SET kind=?,enabled=?,match_mode=?,case_sensitive=?,sort_order=?,revision=?,crypto_version=1,source_cipher=?,replacement_cipher=?,recognition_hint_cipher=? WHERE id=? AND revision=?") { s in try Self.bind(s,1,draft.kind.rawValue); try Self.bind(s,2,draft.enabled ? 1:0); try Self.bind(s,3,draft.matchMode.rawValue); try Self.bind(s,4,draft.caseSensitive ? 1:0); try Self.bind(s,5,draft.sortOrder); try Self.bind(s,6,next.partialValue); try Self.bind(s,7,seal(draft.source,"source")); try Self.bind(s,8,seal(draft.replacement,"replacement")); try Self.bind(s,9,try draft.recognitionHint.map { try seal($0,"recognition_hint") }); try Self.bind(s,10,id.uuidString); try Self.bind(s,11,expectedRevision) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict }; if fault == .beforeCommit { throw DatabaseFailure.injectedFault } } }
        if fault == .afterCommitBeforeIndex { invalidateDictionaryCache(); throw DatabaseFailure.injectedFault }
        dictionaryCache = admitted.entries; dictionaryAdmissionBytes = admitted.bytes; dictionaryStoredBytes = admitted.storedBytes; dictionaryCompiled = nil; return prospective
    }
    public func setDictionaryEnabled(id: UUID, enabled: Bool, expectedRevision: Int64) throws -> DictionaryEntry { guard let old = try dictionaryEntry(id: id) else { throw DatabaseFailure.notFound }; return try updateDictionaryEntry(id: id, draft: .init(kind: old.kind, source: old.source, replacement: old.replacement, recognitionHint: old.recognitionHint, enabled: enabled, matchMode: old.matchMode, caseSensitive: old.caseSensitive, sortOrder: old.sortOrder), expectedRevision: expectedRevision) }
    public func reorderDictionary(activeIDs: [UUID]) throws {
        let active = try dictionaryEntries().filter(\.enabled), requested = Set(activeIDs)
        guard activeIDs.count == active.count, requested.count == activeIDs.count, requested == Set(active.map(\.id)) else { throw DatabaseFailure.invalidHistoryInput }
        try withVerifiedHandle { db in try Self.transaction(db) { db in for (offset,id) in activeIDs.enumerated() { try Self.run(db, "UPDATE dictionary_entry SET sort_order=?,revision=revision+1 WHERE id=? AND enabled=1 AND revision < 9223372036854775807") { s in try Self.bind(s,1,Int64(offset)); try Self.bind(s,2,id.uuidString) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict } } } }; invalidateDictionaryCache()
    }
    public func deleteDictionaryEntry(id: UUID, expectedRevision: Int64) throws { try withVerifiedHandle { db in try Self.transaction(db) { db in try Self.run(db, "DELETE FROM dictionary_entry WHERE id=? AND revision=?") { s in try Self.bind(s,1,id.uuidString); try Self.bind(s,2,expectedRevision) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict } } }; invalidateDictionaryCache() }
    public func activeRecognitionHints(limit: Int = 100) throws -> [String] {
        guard (1...200).contains(limit) else { throw DatabaseFailure.invalidHistoryInput }
        return Array(try dictionaryEntries().filter { $0.enabled && $0.kind == .recognitionHint }.compactMap { entry in
            let source = entry.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return nil }
            let context = entry.recognitionHint?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let context, !context.isEmpty, context != source else { return source }
            return "\(source) (\(context))"
        }.prefix(limit))
    }
    private func validateDictionaryDraft(_ draft: DictionaryDraft) throws -> Void { guard !draft.source.isEmpty, (draft.kind == .replacement ? !draft.replacement.isEmpty : (draft.replacement.isEmpty && draft.recognitionHint != nil)), draft.source.utf8.count <= 4_096, draft.replacement.utf8.count <= 4_096, draft.recognitionHint.map({ !$0.isEmpty && $0.utf8.count <= 4_096 && !$0.utf8.contains(0) }) ?? true, draft.sortOrder >= 0, !draft.source.utf8.contains(0), !draft.replacement.utf8.contains(0) else { throw DatabaseFailure.invalidHistoryInput } }
    private func invalidateDictionaryCache() { dictionaryCache = nil; dictionaryCompiled = nil; dictionaryAdmissionBytes = nil; dictionaryStoredBytes = nil }
    /// Admission is checked before the SQL transaction, so a successful commit can
    /// always rebuild the same bounded matcher after a cache fault or restart.
    private func admitDictionary(_ entry: DictionaryEntry, replacing id: UUID?) throws -> (entries: [DictionaryEntry], bytes: Int, storedBytes: Int) {
        var entries: [DictionaryEntry]
        let existingBytes: Int, existingStoredBytes: Int
        if let dictionaryCache { entries = dictionaryCache; existingBytes = dictionaryAdmissionBytes ?? DictionaryTransformer.admissionBytes(entries); existingStoredBytes = dictionaryStoredBytes ?? entries.reduce(0) { $0 + $1.source.utf8.count + $1.replacement.utf8.count + ($1.recognitionHint?.utf8.count ?? 0) } }
        else { entries = try dictionaryEntries(); existingBytes = DictionaryTransformer.admissionBytes(entries); existingStoredBytes = entries.reduce(0) { $0 + $1.source.utf8.count + $1.replacement.utf8.count + ($1.recognitionHint?.utf8.count ?? 0) } }
        var projectedBytes = existingBytes
        var projectedStoredBytes = existingStoredBytes
        if let id, let old = entries.first(where: { $0.id == id }) {
            let (subtracted, underflow) = projectedBytes.subtractingReportingOverflow(DictionaryTransformer.admissionBytes(for: old))
            guard !underflow else { throw DatabaseFailure.wrongKeyOrTampered }; projectedBytes = subtracted
            let oldStored = old.source.utf8.count + old.replacement.utf8.count + (old.recognitionHint?.utf8.count ?? 0)
            let (stored, storedUnderflow) = projectedStoredBytes.subtractingReportingOverflow(oldStored)
            guard !storedUnderflow else { throw DatabaseFailure.wrongKeyOrTampered }; projectedStoredBytes = stored
            entries.removeAll { $0.id == id }
        }
        entries.append(entry)
        let entryStored = entry.source.utf8.count + entry.replacement.utf8.count + (entry.recognitionHint?.utf8.count ?? 0)
        let (stored, storedOverflow) = projectedStoredBytes.addingReportingOverflow(entryStored)
        let (total, overflow) = projectedBytes.addingReportingOverflow(DictionaryTransformer.admissionBytes(for: entry))
        guard !overflow, !storedOverflow, stored <= dictionaryIndexByteLimit, total <= dictionaryIndexByteLimit else { throw DatabaseFailure.resourceLimit }
        return (entries, total, stored)
    }

    // MARK: - Settings (P6-04)
    private static let preferencesKey = "preferences.v1"
    private static let preferencesAADID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    public func preferences() throws -> PreferencesRecord {
        try withVerifiedHandle { db in
            var found: PreferencesRecord?
            try Self.query(db, "SELECT revision,crypto_version,public_payload,sensitive_payload_cipher FROM app_settings WHERE key='preferences.v1'", bind: { _ in }) { s in
                let revision = sqlite3_column_int64(s, 0), version = try Self.cryptoVersion(s, 1)
                guard revision > 0, Self.blob(s, 2) == Data("v1".utf8) else { throw DatabaseFailure.wrongKeyOrTampered }
                let cipher = try DomainFieldCipher(rootKey: rootKey, domain: .settings)
                let clear = try cipher.open(.init(bytes: Self.blob(s, 3)), aad: .init(cryptoVersion: version, table: "app_settings", rowID: Self.preferencesAADID, column: "sensitive_payload"))
                let snapshot = try StrictPreferencesJSON.decode(clear); try Self.validatePreferences(snapshot)
                found = .init(snapshot: snapshot, revision: revision)
            }
            return found ?? .init(snapshot: .init(), revision: 0)
        }
    }
    public func savePreferences(_ snapshot: PreferencesSnapshot, expectedRevision: Int64, fault: SettingsFaultPoint? = nil) throws -> PreferencesSaveResult {
        try Self.validatePreferences(snapshot)
        let old = try preferences(); guard old.revision == expectedRevision else { throw DatabaseFailure.conflict }
        let next = expectedRevision.addingReportingOverflow(1); guard !next.overflow else { throw DatabaseFailure.invalidHistoryInput }
        let clear = try StrictPreferencesJSON.encode(snapshot), cipher = try DomainFieldCipher(rootKey: rootKey, domain: .settings)
        let sealed = try cipher.seal(clear, aad: .init(cryptoVersion: 1, table: "app_settings", rowID: Self.preferencesAADID, column: "sensitive_payload")).bytes
        try withVerifiedHandle { db in try Self.transaction(db) { db in
            if expectedRevision == 0 { try Self.run(db, "INSERT INTO app_settings(key,revision,crypto_version,public_payload,sensitive_payload_cipher) VALUES('preferences.v1',1,1,?,?)") { try Self.bind($0,1,Data("v1".utf8)); try Self.bind($0,2,sealed) } }
            else { try Self.run(db, "UPDATE app_settings SET revision=?,crypto_version=1,public_payload=?,sensitive_payload_cipher=? WHERE key='preferences.v1' AND revision=?") { try Self.bind($0,1,next.partialValue); try Self.bind($0,2,Data("v1".utf8)); try Self.bind($0,3,sealed); try Self.bind($0,4,expectedRevision) }; guard sqlite3_changes(db) == 1 else { throw DatabaseFailure.conflict } }
            if fault == .beforeCommit { throw DatabaseFailure.injectedFault }
        } }
        pendingPreferencesRevisionNotifications.append(next.partialValue)
        if fault == .afterCommitBeforeNotify { throw DatabaseFailure.injectedFault }
        _ = flushPendingPreferencesRevisionNotifications()
        return .init(record: .init(snapshot: snapshot, revision: next.partialValue), previousRetention: old.snapshot.retention, newRetention: snapshot.retention, revision: next.partialValue)
    }
    /// Delivers each committed, not-yet-delivered revision exactly once to the
    /// injected content-free invalidation callback. It is safe after a fault;
    /// no settings row is written or re-saved by reconciliation.
    @discardableResult public func flushPendingPreferencesRevisionNotifications() -> [Int64] {
        guard let preferencesRevisionNotifier else { pendingPreferencesRevisionNotifications.removeAll(); return [] }
        let pending = pendingPreferencesRevisionNotifications
        pendingPreferencesRevisionNotifications.removeAll(keepingCapacity: true)
        for revision in pending { preferencesRevisionNotifier(revision) }
        return pending
    }
    private static func validatePreferences(_ value: PreferencesSnapshot) throws {
        let physical = value.shortcuts.map { "\($0.keyCode):\($0.modifiers)" }
        guard value.selectedInputDeviceUID.map({ !$0.utf8.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }) ?? true, value.shortcuts.count <= 8, Set(physical).count == physical.count, value.shortcuts.allSatisfy({ $0.keyCode <= 0x7f && ($0.modifiers != 0 || $0.fnGlobeProfile != .disabled) && $0.modifiers & ~UInt64(0x1f) == 0 }) else { throw DatabaseFailure.invalidHistoryInput }
    }

    public func pragmaValue(_ probe: DatabasePragmaProbe) throws -> String {
        try withVerifiedHandle { db in guard let value = try Self.scalar(db, sql: "PRAGMA \(probe.rawValue);") else { throw DatabaseFailure.migrationBlocked }; return value }
    }

    public func openState() -> DatabaseOpenState { state }
    /// Serial actor isolation ensures all earlier operations complete before the
    /// SQLite handle is closed. Every later operation fails with `.closed`.
    public func closeForRecovery() throws -> InactiveStoreLease {
        guard connection.handle != nil else { throw DatabaseFailure.closed }
        try Self.verifyHandleIdentity(connection.handle); guard try boundIdentity(databaseURL) == boundDatabaseIdentity else { throw DatabaseFailure.insecurePath }
        guard let handle = connection.handle, sqlite3_close_v2(handle) == SQLITE_OK else { throw DatabaseFailure.sqlite(code: SQLITE_BUSY) }
        connection.handle = nil; state = .closed
        let token = UUID(); inactiveLeaseToken = token
        return .init(databaseURL: databaseURL, identity: boundDatabaseIdentity, token: token)
    }

    public func schemaVersion() throws -> Int32 { try withVerifiedHandle { db in Int32(try Self.scalar(db, sql: "PRAGMA user_version;") ?? "-1") ?? -1 } }

    public func encryptForHistory(_ text: String, rowID: UUID, column: String = "text", cryptoVersion: UInt32 = 1) throws -> EncryptedBlob {
        try withVerifiedHandle { _ in try DomainFieldCipher(rootKey: rootKey, domain: .history).seal(Data(text.utf8), aad: .init(cryptoVersion: cryptoVersion, table: "history_entry", rowID: rowID, column: column)) }
    }

    public func decryptHistory(_ blob: EncryptedBlob, rowID: UUID, column: String = "text", cryptoVersion: UInt32 = 1) throws -> String {
        try withVerifiedHandle { _ in let data = try DomainFieldCipher(rootKey: rootKey, domain: .history).open(blob, aad: .init(cryptoVersion: cryptoVersion, table: "history_entry", rowID: rowID, column: column)); guard let value = String(data: data, encoding: .utf8) else { throw DatabaseFailure.wrongKeyOrTampered }; return value }
    }

    /// Private, 0600 SQLite online backup for migration/recovery callers. No automatic backups are deleted.
    public func createBackup(at backupURL: URL) throws {
        try Self.verifyHandleIdentity(connection.handle)
        guard try boundIdentity(databaseURL) == boundDatabaseIdentity else { throw DatabaseFailure.insecurePath }
        let target = try Self.validateBackupPath(backupURL)
        _ = try Self.createEmptyFileIfNeeded(at: target)
        var targetDB: OpaquePointer?
        try Self.validateExistingFileNoFollow(at: target)
        let targetIdentity = try boundIdentity(target)
        let opened = sqlite3_open_v2(target.path, &targetDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | 0x01000000, nil)
        guard opened == SQLITE_OK, let targetDB else { if let targetDB { sqlite3_close_v2(targetDB) }; throw DatabaseFailure.sqlite(code: opened) }
        defer { sqlite3_close_v2(targetDB) }
        try Self.verifyHandleIdentity(targetDB)
        try Self.verifyHandleIdentity(connection.handle)
        let backup = sqlite3_backup_init(targetDB, "main", connection.handle, "main")
        guard let backup else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(targetDB)) }
        let stepped = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard (stepped == SQLITE_DONE || stepped == SQLITE_OK), finished == SQLITE_OK else { throw DatabaseFailure.sqlite(code: finished == SQLITE_OK ? stepped : finished) }
        try Self.verifyHandleIdentity(connection.handle); try Self.verifyHandleIdentity(targetDB)
        guard try boundIdentity(databaseURL) == boundDatabaseIdentity, try boundIdentity(target) == targetIdentity else { throw DatabaseFailure.insecurePath }
        try Self.hardenFile(at: target)
        try Self.verifyIntegrity(targetDB)
        try Self.verifyHandleIdentity(targetDB)
    }

    /// Creates a migration backup with an unguessable generated filename inside
    /// a caller-supplied, private directory. The returned file is never
    /// overwritten or auto-deleted by the store.
    public func createMigrationBackup(in directory: URL) throws -> URL {
        try withVerifiedHandle { db in try Self.createGeneratedBackup(source: db, sourceURL: databaseURL, rootKey: rootKey, in: directory) }
    }

    private static func createGeneratedBackup(source: OpaquePointer, sourceURL: URL, rootKey: Data, in directory: URL) throws -> URL {
        let privateDirectory = try validatePrivateDirectory(directory)
        let target = privateDirectory.appendingPathComponent("Klangschrift-migration-\(UUID().uuidString).sqlite")
        _ = try createEmptyFileIfNeeded(at: target)
        var targetDB: OpaquePointer?
        try validateExistingFileNoFollow(at: target)
        let opened = sqlite3_open_v2(target.path, &targetDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | 0x01000000, nil)
        guard opened == SQLITE_OK, let targetDB else { if let targetDB { sqlite3_close_v2(targetDB) }; throw DatabaseFailure.sqlite(code: opened) }
        defer { sqlite3_close_v2(targetDB) }
        let sourceIdentity = try boundIdentity(sourceURL), targetIdentity = try boundIdentity(target)
        try verifyHandleIdentity(source); try verifyHandleIdentity(targetDB)
        guard let backup = sqlite3_backup_init(targetDB, "main", source, "main") else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(targetDB)) }
        let stepped = sqlite3_backup_step(backup, -1), finished = sqlite3_backup_finish(backup)
        guard (stepped == SQLITE_DONE || stepped == SQLITE_OK), finished == SQLITE_OK else { throw DatabaseFailure.sqlite(code: finished == SQLITE_OK ? stepped : finished) }
        try verifyHandleIdentity(source); try verifyHandleIdentity(targetDB)
        guard try boundIdentity(sourceURL) == sourceIdentity, try boundIdentity(target) == targetIdentity else { throw DatabaseFailure.insecurePath }
        try hardenFile(at: target); try validateExistingFileNoFollow(at: target); try verifyIntegrity(targetDB)
        try validateExistingKeyCheck(targetDB, rootKey: rootKey)
        return target
    }

    fileprivate static func validateDatabasePath(_ input: URL) throws -> URL {
        guard input.isFileURL, input.path.hasPrefix("/") else { throw DatabaseFailure.invalidPath }
        var rawParent = stat()
        let rawParentPath = input.deletingLastPathComponent().path
        guard lstat(rawParentPath, &rawParent) == 0, (rawParent.st_mode & S_IFMT) == S_IFDIR,
              (rawParent.st_mode & S_IFMT) != S_IFLNK else { throw DatabaseFailure.insecurePath }
        let path = try canonicalDatabaseURL(input)
        let parent = path.deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == getuid(), (parentInfo.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath }
        var item = stat()
        if lstat(path.path, &item) == 0 {
            guard (item.st_mode & S_IFMT) == S_IFREG, item.st_uid == getuid(), (item.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath }
        } else if errno != ENOENT { throw DatabaseFailure.insecurePath }
        return path
    }

    /// A read-only, no-follow probe for the startup key decision. It accepts
    /// only a validated existing regular database; it never creates a file.
    public static func existingDatabase(at input: URL) throws -> Bool {
        let url = try validateDatabasePath(input)
        var item = stat()
        if lstat(url.path, &item) == 0 {
            try validateExistingFileNoFollow(at: url)
            return true
        }
        guard errno == ENOENT else { throw DatabaseFailure.insecurePath }
        return false
    }

    private static func canonicalDatabaseURL(_ input: URL) throws -> URL {
        let parent = input.deletingLastPathComponent().path
        guard let resolved = realpath(parent, nil) else { throw DatabaseFailure.invalidPath }
        defer { free(resolved) }
        let canonicalParent = String(cString: resolved)
        guard canonicalParent.hasPrefix("/") else { throw DatabaseFailure.invalidPath }
        return URL(fileURLWithPath: canonicalParent, isDirectory: true).appendingPathComponent(input.lastPathComponent)
    }

    private static func validateBackupPath(_ input: URL) throws -> URL {
        let path = try validateDatabasePath(input)
        guard !FileManager.default.fileExists(atPath: path.path) else { throw DatabaseFailure.invalidPath }
        return path
    }

    fileprivate static func validatePrivateDirectory(_ input: URL) throws -> URL {
        guard input.isFileURL, input.path.hasPrefix("/") else { throw DatabaseFailure.invalidPath }
        guard let resolved = realpath(input.path, nil) else { throw DatabaseFailure.insecurePath }
        defer { free(resolved) }
        let url = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        var item = stat()
        guard lstat(url.path, &item) == 0, (item.st_mode & S_IFMT) == S_IFDIR, item.st_uid == getuid(), (item.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath }
        return url
    }

    fileprivate static func hardenFile(at url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG, value.st_uid == getuid() else { throw DatabaseFailure.insecurePath }
        guard chmod(url.path, 0o600) == 0 else { throw DatabaseFailure.insecurePath }
        guard lstat(url.path, &value) == 0, (value.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath }
    }

    fileprivate static func validateExistingFileNoFollow(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw DatabaseFailure.insecurePath }
        defer { close(descriptor) }
        var descriptorInfo = stat(), pathInfo = stat()
        guard fstat(descriptor, &descriptorInfo) == 0, lstat(url.path, &pathInfo) == 0,
              (descriptorInfo.st_mode & S_IFMT) == S_IFREG, pathInfo.st_ino == descriptorInfo.st_ino,
              pathInfo.st_dev == descriptorInfo.st_dev, pathInfo.st_uid == getuid(), (pathInfo.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath }
    }

    fileprivate enum FileProvenance { case newEmpty, existing }
    fileprivate static func createEmptyFileIfNeeded(at url: URL) throws -> FileProvenance {
        var item = stat()
        if lstat(url.path, &item) == 0 { return .existing }
        guard errno == ENOENT else { throw DatabaseFailure.insecurePath }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DatabaseFailure.insecurePath }
        guard close(descriptor) == 0 else { throw DatabaseFailure.insecurePath }
        try hardenFile(at: url)
        return .newEmpty
    }

    private static func configure(_ db: OpaquePointer) throws {
        try execute(db, "PRAGMA journal_mode=DELETE;")
        try execute(db, "PRAGMA synchronous=FULL;")
        try execute(db, "PRAGMA foreign_keys=ON;")
        try execute(db, "PRAGMA secure_delete=ON;")
        try execute(db, "PRAGMA trusted_schema=OFF;")
        try execute(db, "PRAGMA temp_store=MEMORY;")
        guard try scalar(db, sql: "PRAGMA journal_mode;")?.lowercased() == "delete",
              try scalar(db, sql: "PRAGMA synchronous;") == "2",
              try scalar(db, sql: "PRAGMA foreign_keys;") == "1",
              try scalar(db, sql: "PRAGMA secure_delete;") == "1",
              try scalar(db, sql: "PRAGMA trusted_schema;") == "0",
              try scalar(db, sql: "PRAGMA temp_store;") == "2" else { throw DatabaseFailure.migrationBlocked }
    }

    private static func applyDefensiveMode(_ db: OpaquePointer) throws {
        guard klangschrift_sqlite_enable_defensive(db) == SQLITE_OK else { throw DatabaseFailure.migrationBlocked }
    }

    fileprivate static func verifyHandleIdentity(_ db: OpaquePointer?) throws {
        guard let db, klangschrift_sqlite_handle_has_not_moved(db) == SQLITE_OK else { throw DatabaseFailure.insecurePath }
    }

    private struct MigrationStep: Sendable { let from: Int32; let to: Int32; let id: String; let sql: String; let checksum: String }
    private static let v1LedgerChecksum = sha256("Klangschrift.migration.baseline.v1")
    private static let v2SQL = """
    CREATE TABLE retention_scheduler_state (
      id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
      revision INTEGER NOT NULL CHECK(revision > 0),
      crypto_version INTEGER NOT NULL CHECK(crypto_version = 1),
      state_cipher BLOB NOT NULL
    );
    """
    private static let v3SQL = """
    CREATE TABLE dictation_statistics (
      id INTEGER PRIMARY KEY NOT NULL CHECK(id = 1),
      revision INTEGER NOT NULL CHECK(revision > 0),
      crypto_version INTEGER NOT NULL CHECK(crypto_version = 1),
      payload_cipher BLOB NOT NULL
    );
    """
    private static let migrations: [MigrationStep] = [
        .init(from: 1, to: 2, id: "v1_to_v2_retention_scheduler", sql: v2SQL, checksum: sha256(v2SQL)),
        .init(from: 2, to: 3, id: "v2_to_v3_dictation_statistics", sql: v3SQL, checksum: sha256(v3SQL))
    ]

    private static func bootstrapOrValidateExisting(
        _ db: OpaquePointer,
        provenance: FileProvenance,
        rootKey: Data,
        trackingStartedAtMs: Int64,
        crashPoint: MigrationCrashPoint?,
        migrationFault: MigrationFaultPoint?,
        databaseURL: URL,
        migrationBackupDirectory: URL?,
        state: inout DatabaseOpenState
    ) throws {
        let current = Int32(try scalar(db, sql: "PRAGMA user_version;") ?? "-1") ?? -1
        guard current <= DatabaseSchema.currentVersion else { state = .blocked; throw DatabaseFailure.futureSchema(current) }
        state = .schemaChecked
        if provenance == .newEmpty {
            guard current == 0 else { state = .blocked; throw DatabaseFailure.migrationBlocked }
            try execute(db, "BEGIN IMMEDIATE;")
            do {
                state = .bootstrapping
                try execute(db, schemaV1)
                if crashPoint == .afterSchemaCreate { throw DatabaseFailure.migrationBlocked }
                try insertKeyCheck(db, rootKey: rootKey)
                try applyMigration(
                    db,
                    migrations[0],
                    rootKey: rootKey,
                    trackingStartedAtMs: trackingStartedAtMs,
                    appliedAt: 0,
                    fault: migrationFault
                )
                try applyMigration(
                    db,
                    migrations[1],
                    rootKey: rootKey,
                    trackingStartedAtMs: trackingStartedAtMs,
                    appliedAt: 0,
                    fault: migrationFault
                )
                if crashPoint == .beforeUserVersion { throw DatabaseFailure.migrationBlocked }
                if migrationFault == .beforeUserVersion { throw DatabaseFailure.injectedFault }
                try execute(db, "PRAGMA user_version=3;")
                if crashPoint == .afterUserVersion { throw DatabaseFailure.migrationBlocked }
                if migrationFault == .afterUserVersion { throw DatabaseFailure.injectedFault }
                try execute(db, "COMMIT;")
            } catch { _ = try? execute(db, "ROLLBACK;"); state = .blocked; throw error }
            return
        }
        // A failed first bootstrap leaves an existing empty/schema-0 file. It
        // is not a legacy database and must fail closed without querying tables
        // that do not exist.
        guard current >= 1 else { state = .blocked; throw DatabaseFailure.migrationBlocked }
        try validateExistingKeyCheck(db, rootKey: rootKey)
        if current == DatabaseSchema.currentVersion {
            try validateLedger(db, version: current)
            try validateV3Schema(db)
            return
        }
        switch current {
        case 1:
            try validateV1Schema(db)
            try validateEmptyLedger(db)
        case 2:
            try validateV2Schema(db)
            try validateLedger(db, version: 2)
        default:
            state = .blocked
            throw DatabaseFailure.migrationBlocked
        }
        guard let migrationBackupDirectory else { state = .blocked; throw DatabaseFailure.migrationBlocked }
        _ = try createGeneratedBackup(source: db, sourceURL: databaseURL, rootKey: rootKey, in: migrationBackupDirectory)
        if migrationFault == .afterBackup { throw DatabaseFailure.injectedFault }
        try execute(db, "BEGIN IMMEDIATE;")
        do {
            state = .bootstrapping
            for step in migrations where step.from >= current {
                try applyMigration(
                    db,
                    step,
                    rootKey: rootKey,
                    trackingStartedAtMs: trackingStartedAtMs,
                    appliedAt: 0,
                    fault: migrationFault
                )
            }
            if migrationFault == .beforeUserVersion { throw DatabaseFailure.injectedFault }
            try execute(db, "PRAGMA user_version=3;")
            if migrationFault == .afterUserVersion { throw DatabaseFailure.injectedFault }
            if migrationFault == .beforeCommit { throw DatabaseFailure.injectedFault }
            try execute(db, "COMMIT;")
        } catch { _ = try? execute(db, "ROLLBACK;"); state = .blocked; throw error }
        try validateLedger(db, version: 3)
        try validateV3Schema(db)
    }

    private static func applyMigration(
        _ db: OpaquePointer,
        _ step: MigrationStep,
        rootKey: Data,
        trackingStartedAtMs: Int64,
        appliedAt: Int64,
        fault: MigrationFaultPoint?
    ) throws {
        try execute(db, step.sql)
        if fault == .afterDDL { throw DatabaseFailure.injectedFault }
        if step.to == 3 {
            try insertInitialStatistics(
                db,
                rootKey: rootKey,
                trackingStartedAtMs: trackingStartedAtMs
            )
        }
        // Version 1 gets a ledger baseline only when it is advanced. This keeps
        // the historic v1 format distinguishable and its migration auditable.
        if step.from == 1 {
            try run(db, "INSERT INTO migration_ledger(version,applied_at_ms,checksum) VALUES(?,?,?)") { s in
                try bind(s, 1, Int64(1)); try bind(s, 2, appliedAt); try bind(s, 3, v1LedgerChecksum)
            }
        }
        try run(db, "INSERT INTO migration_ledger(version,applied_at_ms,checksum) VALUES(?,?,?)") { s in
            try bind(s, 1, Int64(step.to)); try bind(s, 2, appliedAt); try bind(s, 3, step.checksum)
        }
        if fault == .afterLedger { throw DatabaseFailure.injectedFault }
    }

    private static func validateEmptyLedger(_ db: OpaquePointer) throws {
        guard try scalar(db, sql: "SELECT COUNT(*) FROM migration_ledger;") == "0" else { throw DatabaseFailure.migrationBlocked }
    }
    private static func validateLedger(_ db: OpaquePointer, version: Int32) throws {
        guard version == 2 || version == 3 else { throw DatabaseFailure.migrationBlocked }
        var rows: [(Int64, String)] = []
        try query(db, "SELECT version,checksum FROM migration_ledger ORDER BY version", bind: { _ in }) { s in
            guard let text = sqlite3_column_text(s, 1) else { throw DatabaseFailure.migrationBlocked }
            rows.append((sqlite3_column_int64(s, 0), String(cString: text)))
        }
        let allExpected: [(Int64, String)] = [
            (1, v1LedgerChecksum),
            (2, migrations[0].checksum),
            (3, migrations[1].checksum)
        ]
        let expected = Array(allExpected.prefix(Int(version)))
        guard rows.count == expected.count, zip(rows, expected).allSatisfy({ $0.0.0 == $0.1.0 && $0.0.1 == $0.1.1 }) else { throw DatabaseFailure.migrationBlocked }
    }
    private static func validateV1Schema(_ db: OpaquePointer) throws {
        // An exact structural fingerprint, not merely a table-presence check.
        let expected = ["table:app_settings", "table:dictionary_entry", "table:history_entry", "table:migration_ledger"]
        var actual: [(String, String)] = []
        try query(db, "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name", bind: { _ in }) { s in
            guard let t = sqlite3_column_text(s, 0), let n = sqlite3_column_text(s, 1), let sql = sqlite3_column_text(s, 2) else { throw DatabaseFailure.migrationBlocked }
            actual.append(("\(String(cString: t)):\(String(cString: n))", String(cString: sql)))
        }
        guard actual.map(\.0).sorted() == expected, actual.allSatisfy({ !$0.1.isEmpty }) else { throw DatabaseFailure.migrationBlocked }
        // Existing V1 was authored from schemaV1. Compare canonical DDL with
        // whitespace collapsed so SQLite's retained formatting cannot weaken it.
        let expectedDDL = canonicalDDL(schemaV1)
        let actualDDL = canonicalDDL(actual.map(\.1).joined(separator: ";"))
        guard SHA256.hash(data: Data(expectedDDL.utf8)) == SHA256.hash(data: Data(actualDDL.utf8)) else { throw DatabaseFailure.migrationBlocked }
    }
    private static func validateV2Schema(_ db: OpaquePointer) throws {
        let expected = ["table:app_settings", "table:dictionary_entry", "table:history_entry", "table:migration_ledger", "table:retention_scheduler_state"]
        var actual: [(String, String)] = []
        try query(db, "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name", bind: { _ in }) { s in
            guard let t = sqlite3_column_text(s, 0), let n = sqlite3_column_text(s, 1), let sql = sqlite3_column_text(s, 2) else { throw DatabaseFailure.migrationBlocked }
            actual.append(("\(String(cString: t)):\(String(cString: n))", String(cString: sql)))
        }
        guard actual.map(\.0).sorted() == expected else { throw DatabaseFailure.migrationBlocked }
        let expectedDDL = canonicalDDL(schemaV1 + v2SQL), actualDDL = canonicalDDL(actual.map(\.1).joined(separator: ";"))
        guard SHA256.hash(data: Data(expectedDDL.utf8)) == SHA256.hash(data: Data(actualDDL.utf8)) else { throw DatabaseFailure.migrationBlocked }
    }
    private static func validateV3Schema(_ db: OpaquePointer) throws {
        let expected = [
            "table:app_settings",
            "table:dictation_statistics",
            "table:dictionary_entry",
            "table:history_entry",
            "table:migration_ledger",
            "table:retention_scheduler_state"
        ]
        var actual: [(String, String)] = []
        try query(db, "SELECT type,name,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name", bind: { _ in }) { s in
            guard let type = sqlite3_column_text(s, 0),
                  let name = sqlite3_column_text(s, 1),
                  let sql = sqlite3_column_text(s, 2) else { throw DatabaseFailure.migrationBlocked }
            actual.append(("\(String(cString: type)):\(String(cString: name))", String(cString: sql)))
        }
        guard actual.map(\.0).sorted() == expected else { throw DatabaseFailure.migrationBlocked }
        let expectedDDL = canonicalDDL(schemaV1 + v2SQL + v3SQL)
        let actualDDL = canonicalDDL(actual.map(\.1).joined(separator: ";"))
        guard SHA256.hash(data: Data(expectedDDL.utf8)) == SHA256.hash(data: Data(actualDDL.utf8)) else {
            throw DatabaseFailure.migrationBlocked
        }
    }
    private static func canonicalDDL(_ sql: String) -> String {
        sql.split(separator: ";").map { part in
            part.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").replacingOccurrences(of: "if not exists ", with: "")
        }.filter { !$0.isEmpty }.sorted().joined(separator: ";")
    }
    private static func sha256(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    private static func validateExistingKeyCheck(_ db: OpaquePointer, rootKey: Data) throws {
        let keyID = "00000000-0000-0000-0000-000000000006"
        guard let row = try keyCheckRow(db), row.version > 0, row.version <= Int64(UInt32.max), row.version == 1,
              let data = Data(hexString: row.ciphertext) else { throw DatabaseFailure.wrongKeyOrTampered }
        let aad = PersistenceAAD(cryptoVersion: UInt32(row.version), table: "app_settings", rowID: UUID(uuidString: keyID)!, column: "sensitive_payload")
        _ = try DomainFieldCipher(rootKey: rootKey, domain: .settings).open(EncryptedBlob(bytes: data), aad: aad)
    }
    private static func insertKeyCheck(_ db: OpaquePointer, rootKey: Data) throws {
        let keyID = "00000000-0000-0000-0000-000000000006"
        let aad = PersistenceAAD(cryptoVersion: 1, table: "app_settings", rowID: UUID(uuidString: keyID)!, column: "sensitive_payload")
        let blob = try DomainFieldCipher(rootKey: rootKey, domain: .settings).seal(Data("key-check-v1".utf8), aad: aad)
        let hex = blob.bytes.map { String(format: "%02x", $0) }.joined()
        try execute(db, "INSERT INTO app_settings(key, revision, crypto_version, public_payload, sensitive_payload_cipher) VALUES ('__key_check', 1, 1, x'', x'\(hex)');")
    }

    private static func keyCheckRow(_ db: OpaquePointer) throws -> (version: Int64, ciphertext: String)? {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT crypto_version, hex(sensitive_payload_cipher) FROM app_settings WHERE key='__key_check';", -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw DatabaseFailure.sqlite(code: prepared) }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW || stepped == SQLITE_DONE else { throw DatabaseFailure.sqlite(code: stepped) }
        guard stepped == SQLITE_ROW, let cipher = sqlite3_column_text(statement, 1) else { return nil }
        return (sqlite3_column_int64(statement, 0), String(cString: cipher))
    }

    private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS history_entry (
      id TEXT PRIMARY KEY NOT NULL,
      created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
      updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
      duration_ms INTEGER NOT NULL CHECK(duration_ms >= 0 AND duration_ms <= 86400000),
      transcription_status TEXT NOT NULL CHECK(transcription_status IN ('success','failed','cancelled')),
      insertion_status TEXT NOT NULL CHECK(insertion_status IN ('not_attempted','inserted','copied','failed')),
      pinned_at_ms INTEGER,
      deleted_at_ms INTEGER,
      purge_after_ms INTEGER,
      deletion_batch_id TEXT,
      revision INTEGER NOT NULL DEFAULT 1 CHECK(revision > 0),
      crypto_version INTEGER NOT NULL CHECK(crypto_version = 1),
      text_cipher BLOB NOT NULL,
      language_cipher BLOB,
      target_bundle_cipher BLOB
    );
    CREATE TABLE IF NOT EXISTS dictionary_entry (
      id TEXT PRIMARY KEY NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('recognitionHint','replacement')),
      enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
      match_mode TEXT NOT NULL,
      case_sensitive INTEGER NOT NULL DEFAULT 0 CHECK(case_sensitive IN (0,1)),
      sort_order INTEGER NOT NULL,
      revision INTEGER NOT NULL DEFAULT 1,
      crypto_version INTEGER NOT NULL CHECK(crypto_version = 1),
      source_cipher BLOB NOT NULL,
      replacement_cipher BLOB NOT NULL,
      recognition_hint_cipher BLOB
    );
    CREATE TABLE IF NOT EXISTS app_settings (
      key TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL DEFAULT 1,
      crypto_version INTEGER NOT NULL CHECK(crypto_version > 0),
      public_payload BLOB NOT NULL,
      sensitive_payload_cipher BLOB
    );
    CREATE TABLE IF NOT EXISTS migration_ledger (
      version INTEGER PRIMARY KEY NOT NULL,
      applied_at_ms INTEGER NOT NULL,
      checksum TEXT NOT NULL
    );
    """

    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if let error { sqlite3_free(error) }
        guard result == SQLITE_OK else { throw DatabaseFailure.sqlite(code: result) }
    }
    private static func scalar(_ db: OpaquePointer?, sql: String) throws -> String? {
        guard let db else { throw DatabaseFailure.sqlite(code: SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw DatabaseFailure.sqlite(code: prepared) }
        defer { sqlite3_finalize(statement) }
        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW || stepped == SQLITE_DONE else { throw DatabaseFailure.sqlite(code: stepped) }
        guard stepped == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
    private static func verifyIntegrity(_ db: OpaquePointer) throws {
        guard try scalar(db, sql: "PRAGMA integrity_check;")?.lowercased() == "ok" else { throw DatabaseFailure.integrityCheckFailed }
    }
}

public enum RecoveryPhase: String, Codable, Sendable { case prepared, staged, validated, swapped, verified, ambiguous }
public enum RecoveryFaultPoint: Sendable { case beforeSwap, afterSwapBeforeVerification }
public struct RecoveryResult: Sendable, Equatable { public let phase: RecoveryPhase; public let preservedPreviousStoreURL: URL; public let stagingURL: URL }
private struct DurableRecoveryManifest: Codable { let phase: RecoveryPhase; let activeName: String; let stagingName: String; let activeDevice: UInt64; let activeInode: UInt64; let stagingDevice: UInt64; let stagingInode: UInt64 }
/// Recovery operates only while the application has no live store actor. It
/// never receives an actor reference, so it cannot replace an open database.
/// The caller owns lifecycle exclusion before invoking this coordinator.
public actor InactiveStoreRecoveryCoordinator {
    private let fault: RecoveryFaultPoint?
    private let beforeCopyHook: (@Sendable (URL, URL) throws -> Void)?
    public init(fault: RecoveryFaultPoint? = nil, beforeCopyHook: (@Sendable (URL, URL) throws -> Void)? = nil) { self.fault = fault; self.beforeCopyHook = beforeCopyHook }
    public func restore(backupURL: URL, lease: InactiveStoreLease, keyProvider: any DatabaseKeyProvider, stagingDirectory: URL, crashManifestURL: URL? = nil) throws -> RecoveryResult {
        let active = try EncryptedSQLiteStore.validateDatabasePath(lease.databaseURL)
        let backup = try EncryptedSQLiteStore.validateDatabasePath(backupURL)
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: active)
        guard try boundIdentity(active) == lease.identity else { throw DatabaseFailure.insecurePath }
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: backup)
        let directory = try EncryptedSQLiteStore.validatePrivateDirectory(stagingDirectory)
        guard directory.path == active.deletingLastPathComponent().path else { throw DatabaseFailure.insecurePath }
        let staging = directory.appendingPathComponent("Klangschrift-recovery-stage-\(UUID().uuidString).sqlite")
        _ = try EncryptedSQLiteStore.createEmptyFileIfNeeded(at: staging)
        try writeManifest(.prepared, active: active, staging: staging, to: crashManifestURL)
        // Validate the source with a fresh connection before writing any swap
        // candidate. The key anchor is encrypted and binds this validation to
        // the supplied local key.
        _ = try EncryptedSQLiteStore(databaseURL: backup, keyProvider: keyProvider)
        try beforeCopyHook?(backup, staging)
        try copySQLite(from: backup, to: staging)
        try EncryptedSQLiteStore.hardenFile(at: staging)
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: staging)
        try writeManifest(.staged, active: active, staging: staging, to: crashManifestURL)
        _ = try EncryptedSQLiteStore(databaseURL: staging, keyProvider: keyProvider)
        try writeManifest(.validated, active: active, staging: staging, to: crashManifestURL)
        if fault == .beforeSwap { throw DatabaseFailure.injectedFault }
        guard klangschrift_swap_paths(staging.path, active.path) == 0 else { throw DatabaseFailure.insecurePath }
        try writeManifest(.swapped, active: active, staging: staging, to: crashManifestURL)
        do {
            if fault == .afterSwapBeforeVerification { throw DatabaseFailure.injectedFault }
            _ = try EncryptedSQLiteStore(databaseURL: active, keyProvider: keyProvider)
            try writeManifest(.verified, active: active, staging: staging, to: crashManifestURL)
            // The old live database is now at `staging`; retain it for manual
            // inspection. The original recovery backup is untouched.
            return .init(phase: .verified, preservedPreviousStoreURL: staging, stagingURL: staging)
        } catch {
            try? writeManifest(.ambiguous, active: active, staging: staging, to: crashManifestURL)
            // Do not swap back automatically: after an interrupted filesystem
            // operation, preserve both names for deliberate human recovery.
            throw error
        }
    }
    private func copySQLite(from source: URL, to target: URL) throws {
        let canonicalSource = try EncryptedSQLiteStore.validateDatabasePath(source)
        let canonicalTarget = try EncryptedSQLiteStore.validateDatabasePath(target)
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: canonicalSource)
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: canonicalTarget)
        let sourceIdentity = try boundIdentity(canonicalSource), targetIdentity = try boundIdentity(canonicalTarget)
        var input: OpaquePointer?, output: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | 0x01000000
        let r1 = sqlite3_open_v2(canonicalSource.path, &input, flags, nil)
        guard r1 == SQLITE_OK, let input else { if let input { sqlite3_close_v2(input) }; throw DatabaseFailure.sqlite(code: r1) }
        defer { sqlite3_close_v2(input) }
        let r2 = sqlite3_open_v2(canonicalTarget.path, &output, flags, nil)
        guard r2 == SQLITE_OK, let output else { if let output { sqlite3_close_v2(output) }; throw DatabaseFailure.sqlite(code: r2) }
        defer { sqlite3_close_v2(output) }
        try EncryptedSQLiteStore.verifyHandleIdentity(input); try EncryptedSQLiteStore.verifyHandleIdentity(output)
        guard try boundIdentity(canonicalSource) == sourceIdentity, try boundIdentity(canonicalTarget) == targetIdentity else { throw DatabaseFailure.insecurePath }
        guard let operation = sqlite3_backup_init(output, "main", input, "main") else { throw DatabaseFailure.sqlite(code: sqlite3_errcode(output)) }
        let stepped = sqlite3_backup_step(operation, -1), finished = sqlite3_backup_finish(operation)
        guard (stepped == SQLITE_DONE || stepped == SQLITE_OK), finished == SQLITE_OK else { throw DatabaseFailure.sqlite(code: finished == SQLITE_OK ? stepped : finished) }
        try EncryptedSQLiteStore.verifyHandleIdentity(input); try EncryptedSQLiteStore.verifyHandleIdentity(output)
        guard try boundIdentity(canonicalSource) == sourceIdentity, try boundIdentity(canonicalTarget) == targetIdentity else { throw DatabaseFailure.insecurePath }
    }
    /// Startup calls this before opening a recovered store. It never deletes a
    /// candidate. Identity fields describe the names as observed when that
    /// phase was written; they are never cross-mapped after a swap.
    public func resolveStartupManifest(at url: URL, directory: URL) throws -> RecoveryPhase {
        let parent = try EncryptedSQLiteStore.validatePrivateDirectory(directory)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(DurableRecoveryManifest.self, from: data)
        guard !manifest.activeName.contains("/"), !manifest.stagingName.contains("/") else { throw DatabaseFailure.insecurePath }
        let active = parent.appendingPathComponent(manifest.activeName), staging = parent.appendingPathComponent(manifest.stagingName)
        let activeID = try? boundIdentity(active), stagingID = try? boundIdentity(staging)
        guard activeID?.device == manifest.activeDevice, activeID?.inode == manifest.activeInode,
              stagingID?.device == manifest.stagingDevice, stagingID?.inode == manifest.stagingInode else { return .ambiguous }
        // A completed atomic swap without post-swap verification is safe to
        // surface as swapped, but never auto-deletes the retained old store.
        return manifest.phase == .ambiguous ? .ambiguous : manifest.phase
    }
    /// Deterministic test seam for the durable manifest format. It cannot swap
    /// files and accepts only already-validated private regular files.
    public func writeManifestFixture(_ phase: RecoveryPhase, active: URL, staging: URL, to url: URL) throws {
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: active)
        try EncryptedSQLiteStore.validateExistingFileNoFollow(at: staging)
        try writeManifest(phase, active: active, staging: staging, to: url)
    }
    private func writeManifest(_ phase: RecoveryPhase, active: URL, staging: URL, to url: URL?) throws {
        guard let url else { return }
        let parent = try EncryptedSQLiteStore.validatePrivateDirectory(url.deletingLastPathComponent())
        let path = parent.appendingPathComponent(url.lastPathComponent)
        var item = stat()
        if lstat(path.path, &item) == 0 { guard (item.st_mode & S_IFMT) == S_IFREG, item.st_uid == getuid(), (item.st_mode & 0o077) == 0 else { throw DatabaseFailure.insecurePath } }
        else if errno != ENOENT { throw DatabaseFailure.insecurePath }
        // Record the actual identity at each phase boundary. In particular,
        // `.swapped` and `.verified` are written after the atomic name swap,
        // so their active/staging fields intentionally bind the post-swap
        // names rather than a logical pre-swap role.
        let activeIdentity = try boundIdentity(active), stagingIdentity = try boundIdentity(staging)
        let manifest = DurableRecoveryManifest(phase: phase, activeName: active.lastPathComponent, stagingName: staging.lastPathComponent, activeDevice: activeIdentity.device, activeInode: activeIdentity.inode, stagingDevice: stagingIdentity.device, stagingInode: stagingIdentity.inode)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: path, options: [.atomic])
        guard chmod(path.path, 0o600) == 0 else { throw DatabaseFailure.insecurePath }
    }
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(); bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self = bytes
    }
}
