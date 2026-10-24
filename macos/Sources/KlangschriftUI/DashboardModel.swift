import KlangschriftPresentation
import Foundation
import Combine
import KlangschriftDesignSystem
import KlangschriftCore

public enum DashboardRoute: String, CaseIterable, Identifiable, Sendable { case overview, models, history, dictionary, settings
    public var id: String { rawValue }
    public var title: String { switch self { case .overview: L("Diktieren"); case .models: L("Modelle"); case .history: L("Verlauf"); case .dictionary: L("Wörterbuch"); case .settings: L("Einstellungen") } }
    public var symbol: String { switch self { case .overview: "mic"; case .models: "cpu"; case .history: "clock.arrow.circlepath"; case .dictionary: "text.book.closed"; case .settings: "gearshape" } }
}
public enum DashboardLoadState: Equatable, Sendable { case idle, loading, content, empty, failed(String) }
public struct DashboardStatistics: Equatable, Sendable {
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

    public var averageWordsPerMinute: Double {
        guard totalRecordedMilliseconds > 0, totalWords > 0 else { return 0 }
        return Double(totalWords) * 60_000 / Double(totalRecordedMilliseconds)
    }
}
public enum DashboardStatisticsFormatter {
    public static func words(_ value: Int64) -> String {
        "\(value) \(value == 1 ? L("Wort") : L("Wörter"))"
    }
    public static func dictations(_ value: Int64) -> String {
        "\(value) \(value == 1 ? L("Diktat") : L("Diktate"))"
    }
    public static func days(_ value: Int64) -> String {
        "\(value) \(value == 1 ? L("Tag") : L("Tage"))"
    }
    public static func duration(milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        guard seconds > 0 else { return L("0 Sekunden") }
        let units: [(Int64, String, String)] = [
            (86_400, L("Tag"), L("Tage")),
            (3_600, L("Stunde"), L("Stunden")),
            (60, L("Minute"), L("Minuten")),
            (1, L("Sekunde"), L("Sekunden"))
        ]
        var remainder = seconds
        var parts: [String] = []
        for (size, singular, plural) in units {
            let count = remainder / size
            guard count > 0 else { continue }
            parts.append("\(count) \(count == 1 ? singular : plural)")
            remainder %= size
            if parts.count == 2 { break }
        }
        return parts.joined(separator: " ")
    }
    public static func averageWordsPerMinute(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        return value.formatted(
            .number.locale(AppLocalization.locale).precision(.fractionLength(0))
        )
    }
    public static func trackingDate(milliseconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.locale
        formatter.timeZone = .gmt
        formatter.dateStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000))
    }
}
public struct DashboardTranscript: Identifiable, Equatable, Sendable { public let id: UUID; public var text: String; public let createdAt: Date; public let targetApp: String; public let durationSeconds: Int; public var pinned: Bool; public let revision: Int64; public init(id: UUID = UUID(), text: String, createdAt: Date, targetApp: String, durationSeconds: Int, pinned: Bool = false, revision: Int64 = 0) { self.id = id; self.text = text; self.createdAt = createdAt; self.targetApp = targetApp; self.durationSeconds = durationSeconds; self.pinned = pinned; self.revision = revision } }
public enum DashboardDictionaryKind: String, Codable, Equatable, Sendable { case recognitionHint, replacement }
public enum DashboardDictionaryMatchMode: String, Codable, Equatable, Sendable { case literal, wholeWord }
public struct DashboardDictionaryItem: Identifiable, Equatable, Sendable { public let id: UUID; public var kind: DashboardDictionaryKind; public var source: String; public var replacement: String; public var recognitionHint: String?; public var enabled: Bool; public var matchMode: DashboardDictionaryMatchMode; public var caseSensitive: Bool; public var sortOrder: Int64; public let revision: Int64; public init(id: UUID = UUID(), kind: DashboardDictionaryKind = .replacement, source: String, replacement: String, recognitionHint: String? = nil, enabled: Bool = true, matchMode: DashboardDictionaryMatchMode = .literal, caseSensitive: Bool = false, sortOrder: Int64 = 0, revision: Int64 = 0) { self.id = id; self.kind = kind; self.source = source; self.replacement = replacement; self.recognitionHint = recognitionHint; self.enabled = enabled; self.matchMode = matchMode; self.caseSensitive = caseSensitive; self.sortOrder = sortOrder; self.revision = revision } }
public enum DashboardAppearance: String, CaseIterable, Sendable { case system, light, dark
    public var title: String { switch self { case .system: L("System"); case .light: L("Hell"); case .dark: L("Dunkel") } }
}
public enum DashboardLanguage: String, CaseIterable, Sendable { case automatic, de, en, fr, es, it, pt, nl
    public var title: String { switch self { case .automatic: L("Automatisch"); case .de: L("Deutsch"); case .en: L("Englisch"); case .fr: L("Französisch"); case .es: L("Spanisch"); case .it: L("Italienisch"); case .pt: L("Portugiesisch"); case .nl: L("Niederländisch") } }
}
public enum DashboardRetention: String, CaseIterable, Sendable { case forever, days7, days14, days30, days90, none
    public var title: String { switch self { case .forever: L("Dauerhaft"); case .days7: L("7 Tage"); case .days14: L("14 Tage"); case .days30: L("30 Tage"); case .days90: L("90 Tage"); case .none: L("Keine Speicherung") } }
}
public enum DashboardPreferencesFeedback: Equatable, Sendable { case idle, saving, saved, failed(String) }
public struct DashboardPreferences: Equatable, Sendable {
    public var historyEnabled = true
    public var floatingControlEnabled = true
    public var launchAtLoginDesired = false
    public var appearance: DashboardAppearance = .system
    public var language: DashboardLanguage = .automatic
    public var retention: DashboardRetention = .forever
    public var shortcut: ShortcutDraft?
    public var revision: Int64 = 0
    public init() {}
}
public enum FakeDashboardPreferencesConflict: Equatable, Sendable { case never, once, always }
public enum DashboardIntentError: Error, Equatable, Sendable { case unavailable, validation }
@MainActor public protocol DashboardHistoryIntent { func fetch(query: String) async throws -> [DashboardTranscript]; func delete(ids: Set<UUID>) async throws; func deleteOlderThan(cutoffMilliseconds: Int64) async throws -> Bool; func clearAllTranscripts() async throws; func undoDelete() async throws }
@MainActor public protocol DashboardStatisticsIntent { func statistics() async throws -> DashboardStatistics }
@MainActor public protocol DashboardDictionaryIntent { func fetch() async throws -> [DashboardDictionaryItem]; func save(_ item: DashboardDictionaryItem) async throws; func setEnabled(id: UUID, enabled: Bool) async throws; func move(id: UUID, before: UUID?) async throws; func delete(id: UUID) async throws }
@MainActor public protocol DashboardPreferencesIntent { func fetch() async throws -> DashboardPreferences; func save(_ preferences: DashboardPreferences) async throws -> DashboardPreferences }
@MainActor public protocol DashboardClipboardWriting: AnyObject { func write(_ text: String) -> Bool }
@MainActor public final class UnavailableDashboardStatisticsIntent: DashboardStatisticsIntent {
    public init() {}
    public func statistics() async throws -> DashboardStatistics { throw DashboardIntentError.unavailable }
}
@MainActor public final class FakeDashboardStatisticsIntent: DashboardStatisticsIntent {
    public var value: DashboardStatistics
    public var error: Error?
    public private(set) var fetches = 0
    public init(statistics: DashboardStatistics) { value = statistics }
    public func statistics() async throws -> DashboardStatistics {
        fetches += 1
        if let error { throw error }
        return value
    }
}
@MainActor public final class FakeDashboardClipboardWriter: DashboardClipboardWriting { public private(set) var writes: [String] = []; public var succeeds = true; public init() {}; public func write(_ text: String) -> Bool { guard succeeds else { return false }; writes.append(text); return true } }
@MainActor public final class FakeDashboardHistoryIntent: DashboardHistoryIntent { public var entries: [DashboardTranscript]; public var delayNanoseconds: UInt64 = 0; public var error: Error?; public private(set) var fetches = 0; private var deleted: [DashboardTranscript] = []; public init(entries: [DashboardTranscript] = DashboardDemo.content) { self.entries = entries }; public func fetch(query: String) async throws -> [DashboardTranscript] { fetches += 1; if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }; if let error { throw error }; return query.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(query) } }; public func delete(ids: Set<UUID>) async throws { deleted=entries.filter{ids.contains($0.id)}; entries.removeAll{ids.contains($0.id)} }; public func deleteOlderThan(cutoffMilliseconds: Int64) async throws -> Bool { deleted=entries.filter{Int64($0.createdAt.timeIntervalSince1970 * 1_000) < cutoffMilliseconds}; entries.removeAll{Int64($0.createdAt.timeIntervalSince1970 * 1_000) < cutoffMilliseconds}; return !deleted.isEmpty }; public func clearAllTranscripts() async throws { deleted=entries; entries=[] }; public func undoDelete() async throws { entries.append(contentsOf:deleted); deleted=[] } }
@MainActor public final class FakeDashboardDictionaryIntent: DashboardDictionaryIntent { public var entries: [DashboardDictionaryItem]; public var error: Error?; public init(entries: [DashboardDictionaryItem] = DashboardDemo.dictionary) { self.entries = entries }; public func fetch() async throws -> [DashboardDictionaryItem] { if let error { throw error }; return entries }; public func save(_ item: DashboardDictionaryItem) async throws { guard !item.source.isEmpty else { throw DashboardIntentError.validation }; if let i=entries.firstIndex(where:{$0.id==item.id}) { entries[i]=item } else { entries.append(item) } }; public func setEnabled(id: UUID, enabled: Bool) async throws { guard let i = entries.firstIndex(where: { $0.id == id }) else { throw DashboardIntentError.validation }; entries[i].enabled = enabled }; public func move(id: UUID, before: UUID?) async throws { guard let i=entries.firstIndex(where:{$0.id==id}) else { throw DashboardIntentError.validation }; let value=entries.remove(at:i); if let before, let target=entries.firstIndex(where:{$0.id==before}) { entries.insert(value,at:target) } else { entries.append(value) } }; public func delete(id: UUID) async throws { entries.removeAll{$0.id==id} } }
@MainActor public final class FakeDashboardPreferencesIntent: DashboardPreferencesIntent {
    public var preferences: DashboardPreferences
    public var error: Error?
    public var delayNanoseconds: UInt64 = 0
    public var conflict: FakeDashboardPreferencesConflict = .never
    public var saves = 0
    public private(set) var saveAttempts = 0
    public private(set) var saveSnapshots: [DashboardPreferences] = []
    public private(set) var maximumConcurrentSaves = 0
    private var concurrentSaves = 0
    private var didEmitConflict = false
    public init(preferences: DashboardPreferences = .init()) { self.preferences = preferences }
    public func fetch() async throws -> DashboardPreferences { if let error { throw error }; return preferences }
    public func save(_ preferences: DashboardPreferences) async throws -> DashboardPreferences {
        saveAttempts += 1
        saveSnapshots.append(preferences)
        concurrentSaves += 1
        maximumConcurrentSaves = max(maximumConcurrentSaves, concurrentSaves)
        defer { concurrentSaves -= 1 }
        if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds) }
        if let error { throw error }
        if conflict == .always || (conflict == .once && !didEmitConflict) {
            didEmitConflict = true
            throw DashboardIntentError.validation
        }
        guard preferences.revision == self.preferences.revision else { throw DashboardIntentError.validation }
        var committed = preferences
        committed.revision &+= 1
        self.preferences = committed
        saves += 1
        return committed
    }
}
public struct DashboardHistoryUndoNotice: Equatable, Sendable {
    public let id: UUID
    public let expiresAt: Date
    public init(id: UUID = UUID(), expiresAt: Date = .now.addingTimeInterval(8)) { self.id = id; self.expiresAt = expiresAt }
}
@MainActor public final class DashboardViewModel: ObservableObject { @Published public var route: DashboardRoute = .overview; @Published public var statisticsState: DashboardLoadState = .idle; @Published public var historyState: DashboardLoadState = .idle; @Published public var dictionaryState: DashboardLoadState = .idle; @Published public var preferencesState: DashboardLoadState = .idle; @Published public var preferencesFeedback: DashboardPreferencesFeedback = .idle; @Published public var shortcutValidation: ShortcutValidation?; @Published public private(set) var shortcutCaptureGeneration: UInt64?; @Published public private(set) var shortcutCaptureFailure: String?; @Published public private(set) var shortcutCaptureRecoveryIssue: ShortcutCaptureRecoveryIssue?; @Published public private(set) var statistics: DashboardStatistics?; @Published public var history: [DashboardTranscript] = []; @Published public var dictionary: [DashboardDictionaryItem] = []; @Published public var dictionarySearch = ""; @Published public var dictionaryDraft: DashboardDictionaryItem?; @Published public var selectedDictionaryForDeletion: DashboardDictionaryItem?; @Published public var showDictionaryDelete = false; @Published public var preferences = DashboardPreferences(); @Published public var searchText = ""; @Published public var selectedHistory = Set<UUID>(); @Published public var showDeleteConfirmation = false; @Published public var showHistoryCopyFailure = false; @Published public var showClearAllConfirmation = false; @Published public var pendingDeleteRangeDays: Int?; @Published public var requestSearchFocus = false
    @Published public private(set) var historyContentRevision: UInt64 = 0
    @Published public private(set) var historyUndoNotice: DashboardHistoryUndoNotice?
    @Published public var dictionaryEditError: String?
    @Published public private(set) var preferencesSavedAt: Date?
    @Published public private(set) var preferredDictationLanguages: [String] = []
    private var lastPersistedPreferences = DashboardPreferences()
    private let languagePreferencesDefaults: UserDefaults
    @Published public private(set) var appLanguage: AppLanguage = .system
    @Published public private(set) var launchAtLoginStatus: LaunchAtLoginStatus = .unavailable
    @Published public private(set) var launchAtLoginError: String?
    @Published public private(set) var isUpdatingLaunchAtLogin = false
    private var launchAtLoginRetryTarget: Bool?
    private let launchAtLoginService: any LaunchAtLoginService
    private let appLanguageStore: AppLanguageStore
    private let statisticsIntent: any DashboardStatisticsIntent; private let historyIntent: any DashboardHistoryIntent; private let dictionaryIntent: any DashboardDictionaryIntent; private let preferencesIntent: any DashboardPreferencesIntent; private let shortcutIntent: any ShortcutSetupIntent; private let clipboard: any DashboardClipboardWriting; private var statisticsRequestID = UUID(); private var historyRequestID = UUID(); private var preferencesSaveQueued = false; private var preferencesSaveTask: Task<Void, Never>?; private var preferencesGeneration: UInt64 = 0; private var committedPreferencesGeneration: UInt64 = 0
    public init(statistics: any DashboardStatisticsIntent = UnavailableDashboardStatisticsIntent(), history: any DashboardHistoryIntent = FakeDashboardHistoryIntent(), dictionary: any DashboardDictionaryIntent = FakeDashboardDictionaryIntent(), preferences: any DashboardPreferencesIntent = FakeDashboardPreferencesIntent(), shortcut: any ShortcutSetupIntent = FakeShortcutSetupIntent(), clipboard: any DashboardClipboardWriting = FakeDashboardClipboardWriter(), appLanguageStore: AppLanguageStore? = nil, languagePreferencesDefaults: UserDefaults = .standard, launchAtLogin: any LaunchAtLoginService = UnavailableLaunchAtLoginService()) { self.languagePreferencesDefaults = languagePreferencesDefaults; preferredDictationLanguages = PreferredDictationLanguages.load(from: languagePreferencesDefaults); self.launchAtLoginService = launchAtLogin; let languageStore = appLanguageStore ?? AppLanguageStore(); self.appLanguageStore = languageStore; appLanguage = languageStore.language; statisticsIntent = statistics; historyIntent = history; dictionaryIntent = dictionary; preferencesIntent = preferences; shortcutIntent = shortcut; self.clipboard = clipboard }
    public func load() async { refreshLaunchAtLoginStatus(); await refreshStatistics(); await refreshHistory(reusingSnapshot: true); await refreshDictionary(); preferencesState = .loading; do { preferences = try await preferencesIntent.fetch(); lastPersistedPreferences = preferences; preferencesState = .content; refreshLaunchAtLoginStatus() } catch { preferencesState = .failed(L("Einstellungen konnten nicht geladen werden.")) } }
    public func refreshStatistics() async { let request = UUID(); statisticsRequestID = request; statisticsState = .loading; do { let value = try await statisticsIntent.statistics(); guard request == statisticsRequestID else { return }; statistics = value; statisticsState = value.totalDictations == 0 ? .empty : .content } catch { guard request == statisticsRequestID else { return }; statisticsState = .failed(L("Statistiken konnten nicht geladen werden.")) } }
    public func refreshDictionary() async { dictionaryState = .loading; do { dictionary = try await dictionaryIntent.fetch(); dictionaryState = dictionary.isEmpty ? .empty : .content } catch { dictionaryState = .failed(L("Das Wörterbuch konnte nicht geladen werden.")) } }
    @Published public private(set) var isHistoryMutationInFlight = false
    private var unfilteredSnapshot: [DashboardTranscript]?
    private var unfilteredRead: (id: UUID, task: Task<[DashboardTranscript], Error>)?
    private func invalidateHistorySnapshot() {
        unfilteredSnapshot = nil
        unfilteredRead = nil
        historyRequestID = UUID()
    }
    private func unfilteredHistory() async throws -> [DashboardTranscript] {
        if let unfilteredSnapshot { return unfilteredSnapshot }
        let read: (id: UUID, task: Task<[DashboardTranscript], Error>)
        if let pending = unfilteredRead { read = pending }
        else {
            read = (UUID(), Task { try await historyIntent.fetch(query: "") })
            unfilteredRead = read
        }
        do {
            let values = try await read.task.value
            if unfilteredRead?.id == read.id { unfilteredSnapshot = values; unfilteredRead = nil }
            return values
        } catch {
            if unfilteredRead?.id == read.id { unfilteredRead = nil }
            throw error
        }
    }
    public func refreshHistory(reusingSnapshot: Bool = false) async {
        // Explicit refreshes start a fresh read. Initial load/commit refreshes
        // share the current generation's pending read or snapshot with Home.
        if !reusingSnapshot, searchText.isEmpty { invalidateHistorySnapshot() }
        let request = UUID(); historyRequestID = request; historyState = .loading
        let query = searchText
        do {
            let values = try await (query.isEmpty ? unfilteredHistory() : historyIntent.fetch(query: query))
            guard request == historyRequestID else { return }
            history = values; historyState = values.isEmpty ? .empty : .content
        } catch {
            guard request == historyRequestID else { return }
            historyState = .failed(L("Der Verlauf konnte nicht geladen werden. Bitte erneut versuchen."))
        }
    }
    private func historyMutationDidCommit() {
        invalidateHistorySnapshot()
        historyContentRevision &+= 1
    }
    /// Home and an empty history search share one snapshot per content generation.
    public func historyDidChange() async { historyMutationDidCommit(); await refreshHistory(reusingSnapshot: true) }
    /// Content-free production completion hooks call this after a completed
    /// dictation generation. No transcript, audio or path crosses this seam.
    public func statisticsDidChange() async { await refreshStatistics() }
    /// Does not mutate the history page's query, results or selection.
    public func recentHistory(limit: Int = 3) async throws -> [DashboardTranscript] {
        guard limit > 0 else { return [] }
        return Array(try await unfilteredHistory().sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
    public func dismissHistoryUndoNotice(id: UUID) {
        guard historyUndoNotice?.id == id else { return }
        historyUndoNotice = nil
    }
    private func showHistoryUndoNotice(_ notice: DashboardHistoryUndoNotice) {
        // Never revive a stale UI affordance after a slow operation/refresh.
        historyUndoNotice = notice.expiresAt > .now ? notice : nil
    }
    public func copyHistory(_ item: DashboardTranscript) { showHistoryCopyFailure = !clipboard.write(item.text) }
    public func undoDelete() async {
        guard !isHistoryMutationInFlight else { return }
        isHistoryMutationInFlight = true
        do {
            try await historyIntent.undoDelete()
            historyUndoNotice = nil; historyMutationDidCommit()
        } catch {
            historyState = .failed(L("Die Löschung konnte nicht rückgängig gemacht werden."))
            isHistoryMutationInFlight = false
            return
        }
        isHistoryMutationInFlight = false
        await refreshHistory(reusingSnapshot: true)
    }
    public func toggleDictionary(_ item: DashboardDictionaryItem) async { do { try await dictionaryIntent.setEnabled(id: item.id, enabled: !item.enabled); await refreshDictionary() } catch { dictionaryState = .failed(L("Der Wörterbucheintrag konnte nicht geändert werden.")) } }
    public func saveDictionary(_ item: DashboardDictionaryItem) async {
        dictionaryEditError = nil
        do { try await dictionaryIntent.save(item); await refreshDictionary() }
        catch { dictionaryEditError = L("Der Wörterbucheintrag konnte nicht gespeichert werden. Bitte versuche es erneut.") }
    }
    public var filteredDictionary: [DashboardDictionaryItem] { dictionarySearch.isEmpty ? dictionary : dictionary.filter { $0.source.localizedCaseInsensitiveContains(dictionarySearch) || $0.replacement.localizedCaseInsensitiveContains(dictionarySearch) } }
    public func moveDictionary(_ item: DashboardDictionaryItem, up: Bool) async { guard let index=dictionary.firstIndex(where:{$0.id==item.id}) else{return}; let target=up ? index-1 : index+1; guard dictionary.indices.contains(target) else{return}; let neighbor = up ? dictionary[target] : (target+1 < dictionary.count ? dictionary[target+1] : nil); do { try await dictionaryIntent.move(id:item.id,before:neighbor?.id); await refreshDictionary() } catch { dictionaryState = .failed(L("Die Reihenfolge konnte nicht geändert werden.")) } }
    public func deleteSelectedDictionary() async { guard let item=selectedDictionaryForDeletion else{return}; do { try await dictionaryIntent.delete(id:item.id); selectedDictionaryForDeletion=nil; await refreshDictionary() } catch { dictionaryState = .failed(L("Der Wörterbucheintrag konnte nicht gelöscht werden.")) } }
    public func beginShortcutCapture() async {
        guard shortcutCaptureGeneration == nil else { cancelShortcutCapture(); return }
        preferencesFeedback = .idle
        shortcutCaptureFailure = nil
        shortcutCaptureRecoveryIssue = nil
        let generation: UInt64
        do {
            generation = try shortcutIntent.beginCapture()
        } catch {
            let message = Self.shortcutCaptureStartFailureMessage(for: error)
            shortcutCaptureFailure = message
            shortcutCaptureRecoveryIssue = Self.shortcutCaptureRecoveryIssue(for: error)
            preferencesFeedback = .failed(message)
            return
        }
        shortcutCaptureGeneration = generation
        do {
            let captured = try await shortcutIntent.waitForCapture(generation: generation)
            guard shortcutCaptureGeneration == generation else { return }
            let validation = try await shortcutIntent.validate(captured)
            guard shortcutCaptureGeneration == generation else { return }
            shortcutCaptureGeneration = nil
            shortcutValidation = validation
            guard validation == .valid || validation == .warningUnverifiable else {
                preferencesFeedback = .failed(L("Dieser Shortcut ist durch macOS oder eine andere Belegung blockiert."))
                return
            }
            preferences.shortcut = captured
            markPreferencesChanged()
        } catch {
            guard shortcutCaptureGeneration == generation else { return }
            shortcutCaptureGeneration = nil
            shortcutValidation = nil
            preferencesFeedback = .failed(L("Der Shortcut wurde nicht erkannt. Bitte erneut aufnehmen."))
        }
    }
    private static func shortcutCaptureStartFailureMessage(for error: Error) -> String {
        switch error {
        case ServiceContractError.unavailable("input-monitoring"):
            return L("Die Shortcut-Aufnahme benötigt Eingabeüberwachung. Prüfe Klangschrift in den macOS-Einstellungen.")
        case ServiceContractError.unavailable("event-tap"):
            return L("Die macOS-Tastenerfassung ist für die Shortcut-Aufnahme nicht verfügbar.")
        default:
            return L("Die Shortcut-Aufnahme konnte nicht gestartet werden.")
        }
    }
    private static func shortcutCaptureRecoveryIssue(for error: Error) -> ShortcutCaptureRecoveryIssue? {
        switch error {
        case ServiceContractError.unavailable("input-monitoring"): .inputMonitoring
        case ServiceContractError.unavailable("event-tap"): .eventTapUnavailable
        default: nil
        }
    }
    public func cancelShortcutCapture() { shortcutCaptureFailure = nil; shortcutCaptureRecoveryIssue = nil; guard let generation = shortcutCaptureGeneration else { return }; shortcutIntent.cancelCapture(generation: generation); shortcutCaptureGeneration = nil }
    /// Explicit product choices reuse the same validator and persistence path as
    /// captured shortcuts; they do not manufacture a separate hotkey contract.
    public func chooseShortcut(_ draft: ShortcutDraft) async {
        if shortcutCaptureGeneration != nil { cancelShortcutCapture() }
        shortcutCaptureFailure = nil
        shortcutCaptureRecoveryIssue = nil
        do {
            let validation = try await shortcutIntent.validate(draft)
            shortcutValidation = validation
            guard validation == .valid || validation == .warningUnverifiable else {
                preferencesFeedback = .failed(L("Dieser Shortcut ist durch macOS oder eine andere Belegung blockiert."))
                return
            }
            preferences.shortcut = draft
            markPreferencesChanged()
        } catch { preferencesFeedback = .failed(L("Der Shortcut konnte nicht geprüft werden.")) }
    }
    public var shortcutModeIsFixedToPushToTalk: Bool {
        guard let shortcut = preferences.shortcut else { return false }
        return shortcut.keyCode == 61 && shortcut.modifiers == 2 && shortcut.fnProfile == .disabled
    }
    public func setShortcutMode(_ mode: ShortcutDraftMode) {
        guard var shortcut = preferences.shortcut else { return }
        guard !shortcutModeIsFixedToPushToTalk || mode == .pushToTalk else { return }
        shortcut.typedMode = mode
        // Persisted descriptive metadata stays stable; UI uses typedMode for its label.
        shortcut.mode = switch mode { case .pushToTalk: "Halten"; case .toggle: "Umschalten"; case .reinsert: "Erneut einfügen" }
        preferences.shortcut = shortcut
        shortcutValidation = nil
        markPreferencesChanged()
    }
    @discardableResult public func savePreferences() async -> Bool {
        let generation = markPreferencesChanged()
        await waitForPendingPreferencesSave()
        return committedPreferencesGeneration >= generation
    }
    /// Read-only reconciliation: never override a user's macOS approval choice.
    public func refreshLaunchAtLoginStatus() { launchAtLoginStatus = launchAtLoginService.status }
    public var launchAtLoginNeedsRetry: Bool {
        if launchAtLoginError != nil { return true }
        return preferences.launchAtLoginDesired
            ? launchAtLoginStatus != .enabled && launchAtLoginStatus != .requiresApproval
            : launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }
    public func openLoginItemSettings() { launchAtLoginService.openSystemSettings() }
    public func retryLaunchAtLogin() async {
        await setLaunchAtLoginDesired(launchAtLoginRetryTarget ?? preferences.launchAtLoginDesired)
    }
    public func setLaunchAtLoginDesired(_ desired: Bool) async {
        guard !isUpdatingLaunchAtLogin else { return }
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }
        launchAtLoginError = nil
        // Keep the user's target even when persistence rolls the switch back.
        // A new explicit choice replaces it; only success clears it.
        launchAtLoginRetryTarget = desired
        let previous = preferences.launchAtLoginDesired
        preferences.launchAtLoginDesired = desired
        // Persist intent first. A failed save must never change system registration.
        guard await savePreferences() else {
            preferences.launchAtLoginDesired = previous
            launchAtLoginError = L("Anmeldestart wurde nicht gespeichert. Bitte erneut versuchen.")
            refreshLaunchAtLoginStatus()
            return
        }
        do {
            refreshLaunchAtLoginStatus()
            if desired {
                if launchAtLoginStatus != .enabled && launchAtLoginStatus != .requiresApproval {
                    try launchAtLoginService.register()
                }
            } else if launchAtLoginStatus != .notRegistered {
                try await launchAtLoginService.unregister()
            }
            launchAtLoginRetryTarget = nil
        } catch {
            launchAtLoginError = String(format: L("Anmeldestart konnte nicht geändert werden: %@"), error.localizedDescription)
        }
        refreshLaunchAtLoginStatus()
    }
    public func setHistoryEnabled(_ enabled: Bool) { guard preferences.historyEnabled != enabled else { return }; preferences.historyEnabled = enabled; markPreferencesChanged() }
    public func setRetention(_ retention: DashboardRetention) { guard preferences.retention != retention else { return }; preferences.retention = retention; markPreferencesChanged() }
    public func setLanguage(_ language: DashboardLanguage) { guard preferences.language != language else { return }; preferences.language = language; markPreferencesChanged() }
    public func setPreferredDictationLanguage(_ code: String, enabled: Bool) {
        guard PreferredDictationLanguages.supported.contains(code) else { return }
        var next = preferredDictationLanguages
        if enabled { if !next.contains(code) { next.append(code) } }
        else { guard next.count > 1 else { return }; next.removeAll { $0 == code } }
        guard next != preferredDictationLanguages else { return }
        PreferredDictationLanguages.save(next, to: languagePreferencesDefaults)
        preferredDictationLanguages = next
        // This independent UserDefaults write cannot confirm a pending or failed DB save.
        guard preferencesSaveTask == nil, !preferencesSaveQueued else { return }
        switch preferencesFeedback {
        case .saving, .failed: return
        case .idle, .saved: break
        }
        preferencesSavedAt = .now
        preferencesFeedback = .saved
    }
    public func showsSavedFeedback(at date: Date) -> Bool {
        guard preferencesFeedback == .saved, let preferencesSavedAt else { return false }
        return (0..<2).contains(date.timeIntervalSince(preferencesSavedAt))
    }
    public func setAppLanguage(_ language: AppLanguage) { guard appLanguage != language else { return }; appLanguageStore.setLanguage(language); appLanguage = language }
    public func setAppearance(_ appearance: DashboardAppearance) { guard preferences.appearance != appearance else { return }; preferences.appearance = appearance; markPreferencesChanged() }
    public func setFloatingControlPreference(_ enabled: Bool) { guard preferences.floatingControlEnabled != enabled else { return }; preferences.floatingControlEnabled = enabled; markPreferencesChanged() }
    public func retryPreferencesSave() { markPreferencesChanged() }
    public func waitForPendingPreferencesSave() async { while let task = preferencesSaveTask { await task.value } }
    @discardableResult public func setFloatingControlEnabled(_ enabled: Bool) async -> Bool {
        let previous = preferences.floatingControlEnabled
        preferences.floatingControlEnabled = enabled
        let generation = markPreferencesChanged()
        await waitForPendingPreferencesSave()
        let committed = committedPreferencesGeneration >= generation
        if !committed, preferences.floatingControlEnabled == enabled { preferences.floatingControlEnabled = previous }
        return committed && preferences.floatingControlEnabled == enabled
    }
    @discardableResult private func markPreferencesChanged() -> UInt64 {
        preferencesGeneration &+= 1
        preferencesSaveQueued = true
        preferencesSavedAt = nil
        preferencesFeedback = .saving
        guard preferencesSaveTask == nil else { return preferencesGeneration }
        preferencesSaveTask = Task { [weak self] in await self?.runPreferencesSaveLoop() }
        return preferencesGeneration
    }
    private func runPreferencesSaveLoop() async {
        while preferencesSaveQueued {
            preferencesSaveQueued = false
            let draft = preferences
            let generation = preferencesGeneration
            preferencesSavedAt = nil
            preferencesFeedback = .saving
            if let shortcut = draft.shortcut {
                do {
                    let validation = try await shortcutIntent.validate(shortcut)
                    shortcutValidation = validation
                    guard validation == .valid || validation == .warningUnverifiable else {
                        if preferencesGeneration != generation { continue }
                        preferencesFeedback = .failed(L("Dieser Shortcut ist durch macOS oder eine andere Belegung blockiert."))
                        break
                    }
                } catch {
                    if preferencesGeneration != generation { continue }
                    preferencesFeedback = .failed(L("Der Shortcut konnte nicht geprüft werden."))
                    break
                }
            }
            do {
                let committed = try await preferencesIntent.save(draft)
                committedPreferencesGeneration = max(committedPreferencesGeneration, generation)
                if preferencesGeneration == generation { preferences = committed }
                else { preferences.revision = committed.revision }
                preferencesState = .content
                var previous = lastPersistedPreferences
                previous.revision = committed.revision
                let changed = previous != committed
                lastPersistedPreferences = committed
                preferencesFeedback = preferencesSaveQueued ? .saving : .saved
                preferencesSavedAt = !preferencesSaveQueued && changed ? .now : nil
                // The existing settings adapter has completed its retention
                // handoff before returning; no additional sweep is started.
                await historyDidChange()
            } catch {
                preferencesSaveQueued = false
                preferencesFeedback = .failed(L("Die Einstellungen wurden nicht gespeichert."))
                break
            }
        }
        preferencesSaveTask = nil
    }
    public func requestDelete() { guard !isHistoryMutationInFlight, !selectedHistory.isEmpty else { return }; showDeleteConfirmation = true }
    public func deleteSelection() async {
        let ids = selectedHistory
        guard !ids.isEmpty else { return }
        guard !isHistoryMutationInFlight else { return }
        isHistoryMutationInFlight = true
        let notice = DashboardHistoryUndoNotice()
        do {
            try await historyIntent.delete(ids: ids)
            showHistoryUndoNotice(notice); historyMutationDidCommit()
            selectedHistory = []
        } catch {
            historyState = .failed(L("Die Auswahl wurde nicht gelöscht. Bitte erneut versuchen."))
            isHistoryMutationInFlight = false
            return
        }
        isHistoryMutationInFlight = false
        await refreshHistory(reusingSnapshot: true)
    }
    public func requestClearAll() { guard !isHistoryMutationInFlight, historyState == .content && !history.isEmpty else { return }; showClearAllConfirmation = true }
    public func requestDeleteRange(days: Int) {
        guard !isHistoryMutationInFlight, days == 7 || days == 30, historyState == .content && !history.isEmpty else { return }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1_000) - Int64(days) * 86_400_000
        guard history.contains(where: { Int64($0.createdAt.timeIntervalSince1970 * 1_000) < cutoff }) else { return }
        pendingDeleteRangeDays = days
    }
    public func clearAllConfirmed() async {
        guard !isHistoryMutationInFlight else { return }
        isHistoryMutationInFlight = true
        showClearAllConfirmation = false
        do {
            try await historyIntent.clearAllTranscripts()
            historyUndoNotice = nil; historyMutationDidCommit()
            selectedHistory = []
        } catch {
            historyState = .failed(L("Der Verlauf konnte nicht vollständig gelöscht werden. Bitte erneut versuchen."))
            isHistoryMutationInFlight = false
            return
        }
        isHistoryMutationInFlight = false
        await refreshHistory(reusingSnapshot: true)
    }
    public func confirmDeleteRange() async {
        guard !isHistoryMutationInFlight, let days = pendingDeleteRangeDays else { return }
        pendingDeleteRangeDays = nil
        isHistoryMutationInFlight = true
        let cutoff = Int64(Date().timeIntervalSince1970 * 1_000) - Int64(days) * 86_400_000
        let notice = DashboardHistoryUndoNotice()
        do {
            let batchCreated = try await historyIntent.deleteOlderThan(cutoffMilliseconds: cutoff)
            historyUndoNotice = nil
            if batchCreated { showHistoryUndoNotice(notice) }
            historyMutationDidCommit()
            if batchCreated {
                selectedHistory.subtract(history.filter { Int64($0.createdAt.timeIntervalSince1970 * 1_000) < cutoff }.map(\.id))
            }
        } catch {
            historyState = .failed(L("Die älteren Transkripte konnten nicht gelöscht werden. Bitte erneut versuchen."))
            isHistoryMutationInFlight = false
            return
        }
        isHistoryMutationInFlight = false
        await refreshHistory(reusingSnapshot: true)
    }
    public func selectShortcut(_ number: Int) { let routes: [DashboardRoute] = [.overview, .models, .history, .dictionary, .settings]; guard routes.indices.contains(number - 1) else { return }; route = routes[number - 1] }
    public func focusHistorySearch() { route = .history; requestSearchFocus = true }
}
public enum DashboardDemo { public static let content = [DashboardTranscript(text: L("Bitte die Notizen für morgen priorisieren."), createdAt: .now.addingTimeInterval(-240), targetApp: "Notizen", durationSeconds: 6, pinned: true), DashboardTranscript(text: L("Der Entwurf ist lokal gespeichert."), createdAt: .now.addingTimeInterval(-4_200), targetApp: "Mail", durationSeconds: 4)]; public static let dictionary = [DashboardDictionaryItem(source: "Klangschrift", replacement: "Klangschrift"), DashboardDictionaryItem(source: "Beispielname", replacement: "Beispielname", enabled: false)] }
