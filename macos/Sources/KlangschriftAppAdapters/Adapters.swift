import Foundation
import KlangschriftCore
import KlangschriftAppCore
import KlangschriftAudio
import KlangschriftHotkeys
import KlangschriftPersistence
import KlangschriftPresentation
import KlangschriftTextInsertion
import KlangschriftUI

/// This target deliberately contains narrow wiring only. The dashboard's
/// explicit copy button's platform gateway is composition-owned; adapters do
/// not own UI-framework pasteboard access or prompt for permission.
fileprivate enum AdapterPreflight {
    fileprivate static func require(_ checks: [ServiceAvailability]) throws {
        guard !checks.isEmpty else { throw ServiceContractError.invalidConfiguration("adapter_preflight_empty") }
        for check in checks { if case let .unavailable(code) = check { throw ServiceContractError.unavailable(code) } }
    }
}

public protocol HotkeyEventSource: Sendable { func install() throws; func uninstall(); func nextActions(for event: HotkeyPlatformEvent) -> [HotkeyAction]; func completeProcessing() }
public extension HotkeyEventSource { func completeProcessing() {} }
public actor HotkeyCoordinatorBridge: DictationHotkeyCompleting {
    private let source: any HotkeyEventSource; private let preflight: any EventTapPreflightChecking; private let coordinator: DictationCoordinator; private var installed = false
    public init(source: any HotkeyEventSource, preflight: any EventTapPreflightChecking, coordinator: DictationCoordinator) { self.source = source; self.preflight = preflight; self.coordinator = coordinator }
    public func install() throws { try AdapterPreflight.require([preflight.availability()]); guard !installed else { return }; try source.install(); installed = true }
    public func uninstall() { guard installed else { return }; source.uninstall(); installed = false }
    public func receive(_ event: HotkeyPlatformEvent) async { guard installed else { return }; await coordinator.consume(source.nextActions(for: event)) }
    public func completeProcessing() async { source.completeProcessing() }
}

/// P3 remains the owner of actual capture and file deletion. The bridge tracks
/// one coordinator session and refuses stop/cleanup that cannot belong to it.
public protocol CoordinatorAudioService: Sendable {
    func armPreRoll() async throws; func disarmPreRoll() async
    func armPreRoll(session: DictationSessionID) async throws
    func start(session: DictationSessionID, mode: RecordingMode) async throws -> URL
    func stop(session: DictationSessionID) async throws -> URL
    func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult
    func interrupt(session: DictationSessionID) async -> Bool
    func stopCapture(session: DictationSessionID) async
    func cleanup(session: DictationSessionID) async
}
public extension CoordinatorAudioService {
    func armPreRoll(session: DictationSessionID) async throws { try await armPreRoll() }
    func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult { .init(url: try await stop(session: session)) }
    func interrupt(session: DictationSessionID) async -> Bool { false }
}
public protocol AudioTerminalRouting: Sendable { func isBound() async -> Bool; func routeTerminal(session: DictationSessionID) async; func routeCompletion(session: DictationSessionID, reason: AudioCaptureCompletionReason) async
    func registerOwner(session: DictationSessionID, terminal: @escaping @Sendable () async -> Void, completion: @escaping @Sendable (AudioCaptureCompletionReason) async -> Void) async -> Bool
    func removeOwner(session: DictationSessionID) async
}
public extension AudioTerminalRouting {
    func registerOwner(session: DictationSessionID, terminal: @escaping @Sendable () async -> Void, completion: @escaping @Sendable (AudioCaptureCompletionReason) async -> Void) async -> Bool { false }
    func removeOwner(session: DictationSessionID) async {}

    // Legacy/test routers have no processing endpoint. Never fall back to a
    // destructive cancellation for retained PCM. Production binds completion.
    func routeCompletion(session: DictationSessionID, reason: AudioCaptureCompletionReason) async { preconditionFailure("Audio completion route not implemented") }
}
/// The live recorder lease is deliberately injectable so the adapter can prove
/// that a cancellation which lands while acquisition is suspended cannot open
/// capture after the lease continuation resumes.
public protocol RecordingArbitrating: Sendable {
    func acquireLive() async -> UUID?
    func release(_ token: UUID) async
}
/// Composition creates this before the coordinator, then binds it exactly once
/// to the coordinator-owned terminal action. It intentionally has no fallback.
public actor BindableAudioTerminalRouter: AudioTerminalRouting {
    private struct Owner: Sendable { let terminal: @Sendable () async -> Void; let completion: @Sendable (AudioCaptureCompletionReason) async -> Void }
    private var owners: [DictationSessionID: Owner] = [:]
    public func registerOwner(session: DictationSessionID, terminal: @escaping @Sendable () async -> Void, completion: @escaping @Sendable (AudioCaptureCompletionReason) async -> Void) -> Bool {
        guard owners[session] == nil else { return false }
        owners[session] = Owner(terminal: terminal, completion: completion); return true
    }
    public func removeOwner(session: DictationSessionID) { owners.removeValue(forKey: session) }
    private var route: (@Sendable (DictationSessionID) async -> Void)?
    private var completion: (@Sendable (DictationSessionID, AudioCaptureCompletionReason) async -> Void)?
    public init() {}
    public func bindCompletion(_ completion: @escaping @Sendable (DictationSessionID, AudioCaptureCompletionReason) async -> Void) -> Bool { guard self.completion == nil else { return false }; self.completion = completion; return true }
    public func routeCompletion(session: DictationSessionID, reason: AudioCaptureCompletionReason) async { if let owner = owners[session] { await owner.completion(reason); return }; guard let completion else { preconditionFailure("Audio completion route not bound") }; await completion(session, reason) }
    public func bind(_ route: @escaping @Sendable (DictationSessionID) async -> Void) -> Bool { guard self.route == nil else { return false }; self.route = route; return true }
    public func isBound() -> Bool { route != nil && completion != nil }
    public func routeTerminal(session: DictationSessionID) async { if let owner = owners[session] { await owner.terminal(); return }; guard let route else { return }; await route(session) }
}
public actor AudioCoordinatorAdapter: DictationAudio {
    private let service: any CoordinatorAudioService; private let terminal: any AudioTerminalRouting; private let recordingArbiter: any RecordingArbitrating; private var active: DictationSessionID?; private var starting: DictationSessionID?; private var lease: UUID?
    private var preRollSession: DictationSessionID?
    public init(service: any CoordinatorAudioService, terminal: any AudioTerminalRouting, recordingArbiter: any RecordingArbitrating = EphemeralDictationArbiter()) { self.service = service; self.terminal = terminal; self.recordingArbiter = recordingArbiter }
    public func registerEphemeralOwner(session: DictationSessionID, terminalHandler: @escaping @Sendable () async -> Void, completionHandler: @escaping @Sendable (AudioCaptureCompletionReason) async -> Void) async -> Bool {
        await terminal.registerOwner(session: session, terminal: terminalHandler, completion: completionHandler)
    }
    public func armPreRoll() async throws { try await service.armPreRoll() }
    public func disarmPreRoll() async { if let preRollSession { await disarmPreRoll(session: preRollSession) } else { await service.disarmPreRoll() } }
    public func armPreRoll(session: DictationSessionID) async throws {
        _ = try await startOwned(session: session, mode: .pushToTalk, preRoll: true)
    }
    public func disarmPreRoll(session: DictationSessionID) async {
        await stopCapture(session: session)
        await cancelAndCleanup(session: session)
    }
    public func start(session: DictationSessionID, mode: RecordingMode) async throws -> URL {
        if active == session, preRollSession == session {
            preRollSession = nil
            do { return try await service.start(session: session, mode: mode) }
            catch { await disarmPreRoll(session: session); throw error }
        }
        guard let artifact = try await startOwned(session: session, mode: mode, preRoll: false) else { throw DictationCoordinatorError.cancelled }
        return artifact
    }
    private func startOwned(session: DictationSessionID, mode: RecordingMode, preRoll: Bool) async throws -> URL? {
        guard active == nil, starting == nil else { throw DictationCoordinatorError.busy }
        // Reserve before *every* await. A terminal cancel can invalidate this
        // token while isBound/arbiter/preferences are suspended, so no later
        // continuation is permitted to reach the capture backend.
        starting = session
        guard await terminal.isBound(), starting == session else { if preRollSession == session { preRollSession = nil }; if starting == session { starting = nil }; throw DictationCoordinatorError.cancelled }
        guard let nextLease = await recordingArbiter.acquireLive() else { if preRollSession == session { preRollSession = nil }; if starting == session { starting = nil }; throw DictationCoordinatorError.cancelled }
        // An acquire continuation can return after this session was cancelled.
        // Return only that just-acquired lease before observing any newer state.
        guard starting == session else { await recordingArbiter.release(nextLease); throw DictationCoordinatorError.cancelled }
        active = session; starting = nil; lease = nextLease
        do {
            if preRoll {
                preRollSession = session
                try await service.armPreRoll(session: session)
                guard active == session else { throw DictationCoordinatorError.cancelled }
                return nil
            }
            return try await service.start(session: session, mode: mode)
        }
        catch {
            guard active == session else { throw DictationCoordinatorError.cancelled }
            active = nil; preRollSession = nil; lease = nil; await recordingArbiter.release(nextLease); throw error
        }
    }
    public func stop(session: DictationSessionID) async throws -> URL { try await stopResult(session: session).url }
    public func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult {
        guard active == session else { throw DictationCoordinatorError.cancelled }
        let result = try await service.stopResult(session: session)
        guard active == session else { throw DictationCoordinatorError.cancelled }
        return result
    }
    public func interrupt(session: DictationSessionID) async -> Bool {
        guard active == session else { return false }
        let retained = await service.interrupt(session: session)
        return active == session && retained
    }
    public func stopCapture(session: DictationSessionID) async {
        // This is the first coordinator cancel step, before helper reaping.
        // It must also invalidate a reserved start that is suspended in an
        // earlier await, otherwise that continuation may open capture while
        // the coordinator is waiting for the reader to reap.
        if preRollSession == session { preRollSession = nil }; if starting == session { starting = nil }
        guard active == session else { return }
        await service.stopCapture(session: session)
    }
    public func cancelAndCleanup() async { if starting != nil { starting = nil }; guard let active else { return }; self.active = nil; preRollSession = nil; let lease = self.lease; self.lease = nil; await service.cleanup(session: active); await terminal.removeOwner(session: active); if let lease { await recordingArbiter.release(lease) } }
    public func cancelAndCleanup(session: DictationSessionID) async { if preRollSession == session { preRollSession = nil }; if starting == session { starting = nil }; guard active == session else { await terminal.removeOwner(session: session); return }; active = nil; let lease = self.lease; self.lease = nil; await service.cleanup(session: session); await terminal.removeOwner(session: session); if let lease { await recordingArbiter.release(lease) } }
    public func deviceLost() async { await terminalCancel() }
    public func timeout() async { await terminalCancel() }
    private func terminalCancel() async { guard let active else { return }; self.active = nil; preRollSession = nil; let lease = self.lease; self.lease = nil; await service.cleanup(session: active); await terminal.removeOwner(session: active); if let lease { await recordingArbiter.release(lease) }; await terminal.routeTerminal(session: active) }
}

public actor RepositoryHistoryAdapter: DictationHistory {
    private let store: EncryptedSQLiteStore; private var entries: [DictationSessionID: (UUID, Int64)] = [:]; private let now: @Sendable () -> Int64; private let afterPersist: @Sendable (DictationSessionID) async -> Void
    public init(store: EncryptedSQLiteStore, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }, afterPersist: @escaping @Sendable (DictationSessionID) async -> Void = { _ in }) { self.store = store; self.now = now; self.afterPersist = afterPersist }
    public func save(session: DictationSessionID, text: String, durationMs: Int64, status: AppInsertionOutcome) async throws {
        let insertion = Self.map(status); let id = UUID()
        guard let saved = try await store.saveHistory(text: text, metadata: .init(createdAtMs: now(), durationMs: durationMs, insertionStatus: insertion), id: id) else { return }
        entries[session] = (saved.id, saved.revision)
        await afterPersist(session)
    }
    public func updateInsertion(session: DictationSessionID, status: AppInsertionOutcome) async throws { guard let value = entries[session] else { return }; let entry = try await store.updateInsertionStatus(id: value.0, status: Self.map(status), expectedRevision: value.1); entries[session] = (entry.id, entry.revision) }
    public func markIncompleteSessionsFailed() async { _ = try? await store.markIncompleteHistoryFailed(); entries.removeAll() }
    private static func map(_ value: AppInsertionOutcome) -> InsertionStatus { switch value { case .notAttempted: .notAttempted; case .inserted: .inserted; case .copiedForRecovery: .copied; case .failed: .failed } }
}

public protocol LocalDayIdentifierProviding: Sendable {
    func currentDayIdentifier() throws -> Int64
}

/// Consecutive local Gregorian day ordinals. Time zone and clock are injected
/// so streak boundaries are deterministic in tests and local in production.
public struct LocalGregorianDayIdentifierProvider: LocalDayIdentifierProviding {
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.now = now
    }

    public func currentDayIdentifier() throws -> Int64 {
        guard let ordinal = calendar.ordinality(of: .day, in: .era, for: now()),
              ordinal > 0,
              let result = Int64(exactly: ordinal) else {
            throw DatabaseFailure.invalidHistoryInput
        }
        return result
    }
}

public actor RepositoryStatisticsAdapter: DictationStatistics {
    private let store: EncryptedSQLiteStore
    private let dayIdentifier: any LocalDayIdentifierProviding

    public init(store: EncryptedSQLiteStore, dayIdentifier: any LocalDayIdentifierProviding) {
        self.store = store
        self.dayIdentifier = dayIdentifier
    }

    public func record(wordCount: Int64, recordedMilliseconds: Int64) async throws {
        let day = try dayIdentifier.currentDayIdentifier()
        _ = try await store.recordDictationStatistics(
            wordCount: wordCount,
            recordedMilliseconds: recordedMilliseconds,
            dayIdentifier: day
        )
    }
}

public actor RepositorySettingsAdapter: DictationSettings {
    private let store: EncryptedSQLiteStore
    public init(store: EncryptedSQLiteStore) { self.store = store }
    public func current() async -> DictationPreferences {
        guard let value = try? await store.preferences() else {
            return .init(historyEnabled: false, retentionEnabled: false)
        }
        let language = try? RuntimeSettingsMapping.helperLanguage(value.snapshot.language)
        return .init(
            historyEnabled: value.snapshot.historyEnabled,
            retentionEnabled: value.snapshot.retention != .none,
            language: language ?? nil
        )
    }
}
public actor RepositoryDictionaryAdapter: DictionaryTransforming {
    private let store: EncryptedSQLiteStore
    public init(store: EncryptedSQLiteStore) { self.store = store }
    public func transform(_ text: String) async throws -> String { try await store.transformDictionary(text) }
}

public actor InsertionCoordinatorAdapter: CurrentCursorInserting {
    private let service: TextInsertionService; private var lease: FocusLease?
    public init(service: TextInsertionService) { self.service = service }
    private var session: DictationSessionID?
    public func beginRecording(session: DictationSessionID) async -> Bool {
        guard self.session == nil else { InsertionLog.record(.step(.coordinatorStartRejected)); return false }
        // Reserve before suspension so cancellation can invalidate this start.
        self.session = session
        // A missing focus lease permits recording, but only a local recovery draft.
        let capturedLease = await service.beginRecording()
        guard self.session == session else { InsertionLog.record(.step(.coordinatorStartInvalidated)); return false }
        await service.beginRecoverySession(session.rawValue)
        guard self.session == session else { InsertionLog.record(.step(.coordinatorStartInvalidated)); return false }
        InsertionLog.record(.flag(.leaseAtStart, capturedLease != nil))
        lease = capturedLease
        return true
    }
    public func clearRecording(session: DictationSessionID) async { guard self.session == session else { return }; self.session = nil; lease = nil }
    public func insertAfterFocusRevalidation(_ text: String) async -> AppInsertionOutcome {
        InsertionLog.record(.flag(.sessionPresent, session != nil))
        InsertionLog.record(.flag(.leaseAtStart, lease != nil))
        guard session != nil else { InsertionLog.record(.step(.coordinatorInsertRejected)); return .failed }
        InsertionLog.record(.step(.coordinatorInsertStarted))
        defer { InsertionLog.record(.step(.coordinatorInsertFinished)) }
        let value = await service.insert(transcript: text, from: lease); self.lease = nil; session = nil
        let perfPath: PerfTrace.Path = switch value {
        case .insertedDirectly: .direct
        case .insertedByPaste, .insertedByPasteClipboardNotRestored: .paste
        case .copiedForRecovery: .recovery
        case .insertedUncertain: .uncertain
        case .cancelledNotProcessed: .cancelled
        case .recoveryUnavailable: .recovery
        }
        PerfLog.current?.finishInsertion(path: perfPath)
        switch value {
        case .insertedDirectly, .insertedByPaste, .insertedByPasteClipboardNotRestored: return AppInsertionOutcome.inserted
        // An uncertain mutation must never be persisted or presented as an
        // inserted result; it has no retry path.
        case .insertedUncertain: return AppInsertionOutcome.failed
        case .copiedForRecovery: return AppInsertionOutcome.copiedForRecovery
        case .cancelledNotProcessed, .recoveryUnavailable: return AppInsertionOutcome.failed
        }
    }
}

public actor RuntimePresentationBridge: DictationUIState {
    private let sink: @Sendable (DictationPresentationState) async -> Void
    public init(sink: @escaping @Sendable (DictationPresentationState) async -> Void) { self.sink = sink }
    public func show(_ state: DictationCoordinator.State) async { await show(state, metadata: .init(sessionID: nil, generation: 0)) }
    public func show(_ state: DictationCoordinator.State, metadata: DictationUIStateMetadata) async {
        let phase: DictationPresentationPhase = switch state { case .idle: .idle; case .listening: .listening; case .failed: .error; case .recovery: .recoveryCopied; case .prearming, .finalizing, .transcribing, .transforming, .persisting, .inserting: .processing }
        await sink(.init(phase: phase, sessionID: metadata.sessionID?.rawValue, generation: metadata.generation, listeningStartedAt: phase == .listening ? Date() : nil, failure: metadata.failure.flatMap { DictationPresentationFailure(rawValue: $0.rawValue) }))
    }
}

@MainActor public final class DashboardRepositoryAdapters: DashboardStatisticsIntent, DashboardHistoryIntent, DashboardDictionaryIntent, DashboardPreferencesIntent {
    private let store: EncryptedSQLiteStore; private let retention: SettingsRetentionCoordinator; private let beforePreferencesSaveAttempt: @MainActor @Sendable (Int) async -> Void; private let afterPreferencesSave: @MainActor @Sendable () async -> Void; private var undo: DeletionBatch?
    public init(store: EncryptedSQLiteStore, retention: SettingsRetentionCoordinator = .init(), beforePreferencesSaveAttempt: @escaping @MainActor @Sendable (Int) async -> Void = { _ in }, afterPreferencesSave: @escaping @MainActor @Sendable () async -> Void = {}) { self.store = store; self.retention = retention; self.beforePreferencesSaveAttempt = beforePreferencesSaveAttempt; self.afterPreferencesSave = afterPreferencesSave }
    public func statistics() async throws -> DashboardStatistics {
        let snapshot = try await store.statisticsSnapshot()
        return .init(
            totalDictations: snapshot.totalDictations,
            totalWords: snapshot.totalWords,
            totalRecordedMilliseconds: snapshot.totalRecordedMilliseconds,
            currentStreakDays: snapshot.currentStreakDays,
            longestStreakDays: snapshot.longestStreakDays,
            lastDayIdentifier: snapshot.lastDayIdentifier,
            trackingStartedAtMs: snapshot.trackingStartedAtMs,
            revision: snapshot.revision
        )
    }
    public func fetch(query: String) async throws -> [DashboardTranscript] {
        var cursor: HistoryCursor?; var all: [HistoryPreview] = []
        repeat { let page = try await store.historyPage(limit: 200, after: cursor); all.append(contentsOf: page.entries); cursor = page.next } while cursor != nil
        return all.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }.map(Self.history)
    }
    public func delete(ids: Set<UUID>) async throws { undo = try await store.softDelete(ids: Array(ids)) }
    public func deleteOlderThan(cutoffMilliseconds: Int64) async throws -> Bool {
        do { undo = try await store.softDeleteRange(olderThanCutoffMs: cutoffMilliseconds); return true } catch DatabaseFailure.notFound { return false }
    }
    public func clearAllTranscripts() async throws { let confirmation = await store.makeClearHistoryConfirmation(); try await store.clearAll(using: confirmation); undo = nil }
    public func undoDelete() async throws { guard let undo else { throw DashboardIntentError.validation }; try await store.undoDelete(undo); self.undo = nil }
    public func fetch() async throws -> [DashboardDictionaryItem] { try await store.dictionaryEntries().map(Self.dictionary) }
    public func save(_ item: DashboardDictionaryItem) async throws { let draft = DictionaryDraft(kind: item.kind == .recognitionHint ? .recognitionHint : .replacement, source: item.source, replacement: item.replacement, recognitionHint: item.recognitionHint, enabled: item.enabled, matchMode: item.matchMode == .wholeWord ? .wholeWord : .literal, caseSensitive: item.caseSensitive, sortOrder: item.sortOrder); if item.revision == 0 { _ = try await store.createDictionaryEntry(draft, id: item.id) } else { _ = try await store.updateDictionaryEntry(id: item.id, draft: draft, expectedRevision: item.revision) } }
    public func setEnabled(id: UUID, enabled: Bool) async throws { guard let item = try await store.dictionaryEntry(id: id) else { throw DashboardIntentError.validation }; _ = try await store.updateDictionaryEntry(id: id, draft: .init(kind: item.kind, source: item.source, replacement: item.replacement, recognitionHint: item.recognitionHint, enabled: enabled, matchMode: item.matchMode, caseSensitive: item.caseSensitive, sortOrder: item.sortOrder), expectedRevision: item.revision) }
    public func move(id: UUID, before: UUID?) async throws { let entries = try await store.dictionaryEntries(); guard let moving = entries.first(where: { $0.id == id }), moving.enabled else { throw DashboardIntentError.validation }; guard before == nil || entries.contains(where: { $0.id == before && $0.enabled }) else { throw DashboardIntentError.validation }; var ids = entries.filter(\.enabled).map(\.id); guard let index = ids.firstIndex(of: id) else { throw DashboardIntentError.validation }; ids.remove(at: index); if let before, let target = ids.firstIndex(of: before) { ids.insert(id, at: target) } else { ids.append(id) }; try await store.reorderDictionary(activeIDs: ids) }
    public func delete(id: UUID) async throws { guard let item = try await store.dictionaryEntry(id: id) else { throw DashboardIntentError.validation }; try await store.deleteDictionaryEntry(id: id, expectedRevision: item.revision) }
    public func fetch() async throws -> DashboardPreferences { Self.preferences(try await store.preferences()) }
    public func save(_ preferences: DashboardPreferences) async throws -> DashboardPreferences {
        let current = try await store.preferences()
        let result: PreferencesSaveResult
        do {
            result = try await save(preferences, rebasedOn: current, attempt: 0)
        } catch DatabaseFailure.conflict {
            let refreshed = try await store.preferences()
            result = try await save(preferences, rebasedOn: refreshed, attempt: 1)
        }
        _ = await retention.applyCommitted(result, historyStore: store)
        await afterPreferencesSave()
        return Self.preferences(result.record)
    }
    private func save(_ preferences: DashboardPreferences, rebasedOn current: PreferencesRecord, attempt: Int) async throws -> PreferencesSaveResult {
        var snapshot = current.snapshot
        snapshot.historyEnabled = preferences.historyEnabled
        snapshot.floatingControlEnabled = preferences.floatingControlEnabled
        snapshot.launchAtLoginDesired = preferences.launchAtLoginDesired
        snapshot.appearance = AppearancePreference(rawValue: preferences.appearance.rawValue) ?? .system
        snapshot.language = SettingsLanguage(rawValue: preferences.language.rawValue) ?? .automatic
        snapshot.retention = Self.retentionValue(preferences.retention)
        if let shortcut = preferences.shortcut {
            guard let persisted = Self.persisted(shortcut) else { throw DashboardIntentError.validation }
            snapshot.shortcuts = [persisted]
        }
        await beforePreferencesSaveAttempt(attempt)
        let expectedRevision = attempt == 0 ? preferences.revision : current.revision
        return try await store.savePreferences(snapshot, expectedRevision: expectedRevision)
    }
    private static func history(_ p: HistoryPreview) -> DashboardTranscript { .init(id: p.id, text: p.text, createdAt: Date(timeIntervalSince1970: TimeInterval(p.createdAtMs) / 1_000), targetApp: "", durationSeconds: Int(p.durationMs / 1_000), pinned: p.pinnedAtMs != nil, revision: p.revision) }
    private static func history(_ e: HistoryEntry) -> DashboardTranscript { .init(id: e.id, text: e.text, createdAt: Date(timeIntervalSince1970: TimeInterval(e.metadata.createdAtMs) / 1_000), targetApp: e.targetBundleID ?? "", durationSeconds: Int(e.metadata.durationMs / 1_000), pinned: e.pinnedAtMs != nil, revision: e.revision) }
    private static func dictionary(_ e: DictionaryEntry) -> DashboardDictionaryItem { .init(id: e.id, kind: e.kind == .recognitionHint ? .recognitionHint : .replacement, source: e.source, replacement: e.replacement, recognitionHint: e.recognitionHint, enabled: e.enabled, matchMode: e.matchMode == .wholeWord ? .wholeWord : .literal, caseSensitive: e.caseSensitive, sortOrder: e.sortOrder, revision: e.revision) }
    private static func preferences(_ record: PreferencesRecord) -> DashboardPreferences {
        var view = DashboardPreferences()
        view.historyEnabled = record.snapshot.historyEnabled
        view.floatingControlEnabled = record.snapshot.floatingControlEnabled
        view.launchAtLoginDesired = record.snapshot.launchAtLoginDesired
        view.appearance = DashboardAppearance(rawValue: record.snapshot.appearance.rawValue) ?? .system
        view.language = DashboardLanguage(rawValue: record.snapshot.language.rawValue) ?? .automatic
        view.retention = retention(record.snapshot.retention)
        view.shortcut = record.snapshot.shortcuts.first.map(draft)
        view.revision = record.revision
        return view
    }
    private static func retention(_ value: HistoryRetentionCodable) -> DashboardRetention { switch value { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } }
    private static func retentionValue(_ value: DashboardRetention) -> HistoryRetentionCodable { switch value { case .forever: .forever; case .days7: .days7; case .days14: .days14; case .days30: .days30; case .days90: .days90; case .none: .none } }
    private static func persisted(_ value: ShortcutDraft) -> PersistedShortcut? {
        guard let keyCode = value.keyCode else { return nil }
        let mode: PersistedShortcutMode = switch value.typedMode { case .pushToTalk: .pushToTalk; case .toggle: .toggle; case .reinsert: .reinsert }
        let profile: PersistedFnGlobeProfile = switch value.fnProfile { case .disabled: .disabled; case .functionModifier: .functionModifier; case .globeQualified: .globeQualified }
        return .init(keyCode: keyCode, modifiers: value.modifiers, mode: mode, fnGlobeProfile: profile)
    }
    private static func draft(_ value: PersistedShortcut) -> ShortcutDraft {
        let mode: ShortcutDraftMode = switch value.mode { case .pushToTalk: .pushToTalk; case .toggle: .toggle; case .reinsert: .reinsert }
        let profile: ShortcutDraftFnProfile = switch value.fnGlobeProfile { case .disabled: .disabled; case .functionModifier: .functionModifier; case .globeQualified: .globeQualified }
        let display = value.keyCode == ShortcutDescriptor.functionKeyCode && profile == .functionModifier ? "Fn" : "Taste \(value.keyCode)"
        let modeDisplay = switch mode { case .pushToTalk: "Halten"; case .toggle: "Umschalten"; case .reinsert: "Erneut einfügen" }
        return .init(display: display, mode: modeDisplay, usesFn: profile != .disabled, keyCode: value.keyCode, modifiers: value.modifiers, typedMode: mode, fnProfile: profile)
    }
}

public struct AdapterCompositionRoot: Sendable {
    public init() {}
    /// Validates injected readiness only. Constructing this root cannot install,
    /// start, prompt, access Keychain, use network, or mutate system state.
    public func validate(checks: [ServiceAvailability]) throws { try AdapterPreflight.require(checks) }
}
