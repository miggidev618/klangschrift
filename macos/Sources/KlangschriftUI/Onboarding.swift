import KlangschriftPresentation
import Combine
import Foundation
import SwiftUI
import KlangschriftDesignSystem

public enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome, microphone, accessibility, inputMonitoring, shortcut, testDictation, privacy
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .welcome: L("Willkommen")
        case .microphone: L("Mikrofon")
        case .accessibility: L("Bedienungshilfen")
        case .inputMonitoring: L("Eingabeüberwachung")
        case .shortcut: L("Shortcut wählen")
        case .testDictation: L("Testdiktat")
        case .privacy: L("Datenschutz & Verlauf")
        }
    }
}

public enum PermissionKind: String, CaseIterable, Identifiable, Sendable { case microphone, accessibility, inputMonitoring; public var id: String { rawValue } }
public enum Authorization: String, CaseIterable, Sendable { case unknown, granted, denied, restricted, unavailable }
public enum PermissionDetailCode: String, CaseIterable, Sendable { case none, notDetermined, deniedByUser, restrictedBySystem, unavailableOnDevice, settingsUnavailable }
public enum OnboardingFailureCode: String, CaseIterable, Sendable { case permissionUnavailable, microphoneTestFailed, shortcutBlocked, testFailed, saveFailed, completionRequirementsChanged }
/// A short microphone probe proves only that one audio frame reached the app.
/// It deliberately says nothing about model availability or transcription.
public enum MicrophoneTestFailure: String, CaseIterable, Equatable, Sendable, Error {
    case alreadyRunning
    case invalidConfiguration
    case noAudioFrameBeforeTimeout
    case captureCouldNotStart
    case invalidAudioLevel
    case cancelled
}
public enum MicrophoneTestState: Equatable, Sendable {
    case idle
    case running
    case succeeded(level: Float?)
    case failed(MicrophoneTestFailure)
}
public struct PermissionStatus: Equatable, Sendable {
    public let kind: PermissionKind; public let authorization: Authorization; public let checkedGeneration: UInt64; public let canRequest: Bool; public let settingsAvailable: Bool; public let detailCode: PermissionDetailCode
    public init(kind: PermissionKind, authorization: Authorization = .unknown, checkedGeneration: UInt64 = 0, canRequest: Bool = false, settingsAvailable: Bool = true, detailCode: PermissionDetailCode = .none) { self.kind = kind; self.authorization = authorization; self.checkedGeneration = checkedGeneration; self.canRequest = canRequest; self.settingsAvailable = settingsAvailable; self.detailCode = detailCode }
}
public struct PermissionSnapshot: Equatable, Sendable { public let statuses: [PermissionKind: PermissionStatus]; public let generation: UInt64; public init(statuses: [PermissionKind: PermissionStatus], generation: UInt64) { self.statuses = statuses; self.generation = generation }; public subscript(_ kind: PermissionKind) -> PermissionStatus { statuses[kind] ?? .init(kind: kind) } }
public struct PermissionTestResult: Equatable, Sendable {
    public let passed: Bool
    public let detailCode: OnboardingFailureCode?
    public let level: Float?
    public let failure: MicrophoneTestFailure?
    public init(passed: Bool, detailCode: OnboardingFailureCode? = nil, level: Float? = nil, failure: MicrophoneTestFailure? = nil) {
        self.passed = passed
        self.detailCode = detailCode
        self.level = level
        self.failure = failure
    }
}
public enum ShortcutValidation: Equatable, Sendable { case valid, blockedExactConflict, blockedReservation, warningUnverifiable }
public enum ShortcutDraftMode: String, CaseIterable, Sendable { case pushToTalk, toggle, reinsert }
public enum ShortcutDraftFnProfile: String, CaseIterable, Sendable { case disabled, functionModifier, globeQualified }
/// The onboarding layer stores only an abstract key/modifier description. Raw
/// keyboard device IDs and event signatures are intentionally not representable.
public struct ShortcutDraft: Equatable, Sendable {
    public var display: String; public var mode: String; public var usesFn: Bool
    public var keyCode: UInt16?; public var modifiers: UInt64; public var typedMode: ShortcutDraftMode; public var fnProfile: ShortcutDraftFnProfile
    public init(display: String = "Fn", mode: String = L("Halten"), usesFn: Bool = true, keyCode: UInt16? = 63, modifiers: UInt64 = 1 << 4, typedMode: ShortcutDraftMode = .pushToTalk, fnProfile: ShortcutDraftFnProfile? = nil) {
        self.display = display; self.mode = mode; self.usesFn = usesFn; self.keyCode = keyCode; self.modifiers = modifiers; self.typedMode = typedMode; self.fnProfile = fnProfile ?? (usesFn ? .functionModifier : .disabled)
    }
}
public struct TestDictationResult: Equatable, Sendable { public let preview: String; public init?(preview: String) { guard !preview.isEmpty, preview.utf8.count <= 4_096 else { return nil }; self.preview = preview } }
public enum TestDictationPhase: Equatable, Sendable { case idle, recording, processing }
public enum OnboardingLanguage: String, CaseIterable, Sendable { case automatic, german, english, french, spanish, italian, portuguese, dutch
    public var title: String { switch self { case .automatic: L("Automatisch"); case .german: L("Deutsch"); case .english: L("Englisch"); case .french: L("Französisch"); case .spanish: L("Spanisch"); case .italian: L("Italienisch"); case .portuguese: L("Portugiesisch"); case .dutch: L("Niederländisch") } }
    public var transcriptionCode: String? { switch self { case .automatic: nil; case .german: "de"; case .english: "en"; case .french: "fr"; case .spanish: "es"; case .italian: "it"; case .portuguese: "pt"; case .dutch: "nl" } }
}
public enum HistoryRetention: String, CaseIterable, Sendable { case forever, days7, days14, days30, days90, none }
public struct PrivacyDraft: Equatable, Sendable { public var historyEnabled: Bool; public var retention: HistoryRetention; public init(historyEnabled: Bool = true, retention: HistoryRetention = .forever) { self.historyEnabled = historyEnabled; self.retention = retention } }
public struct CompletionDraft: Equatable, Sendable { public let shortcut: ShortcutDraft; public let privacy: PrivacyDraft; public init(shortcut: ShortcutDraft, privacy: PrivacyDraft) { self.shortcut = shortcut; self.privacy = privacy } }
public enum OnboardingError: Error, Equatable, Sendable { case permissionUnavailable, microphoneTestFailed, shortcutBlocked, testFailed, saveFailed, completionRequirementsChanged
    public var code: OnboardingFailureCode { switch self { case .permissionUnavailable: .permissionUnavailable; case .microphoneTestFailed: .microphoneTestFailed; case .shortcutBlocked: .shortcutBlocked; case .testFailed: .testFailed; case .saveFailed: .saveFailed; case .completionRequirementsChanged: .completionRequirementsChanged } }
}
public enum OnboardingExit: Equatable, Sendable { case deferredPermission(PermissionKind), later }
public enum OnboardingMode: Equatable, Sendable { case initialSetup, permissionRecovery }

@MainActor public protocol PermissionStatusIntent { func refresh() async throws -> PermissionSnapshot; func requestAuthorization(for kind: PermissionKind) async throws -> PermissionSnapshot; func openSettings(for kind: PermissionKind) }
@MainActor public protocol MicrophoneTestIntent { func run() async throws -> PermissionTestResult }
@MainActor public protocol ShortcutSetupIntent { func beginCapture() throws -> UInt64; func waitForCapture(generation: UInt64) async throws -> ShortcutDraft; func cancelCapture(generation: UInt64); func validate(_ draft: ShortcutDraft) async throws -> ShortcutValidation }
/// Narrow lifecycle hook used by the composition when its onboarding shell is
/// torn down during a temporary shortcut capture.
@MainActor public protocol PrefoundationShortcutCaptureLifecycle: ShortcutSetupIntent { func cancelActiveCapture() }
public enum TestDictationAutomaticReason: Sendable, Equatable {
    case maximumDuration, callbackLoss, interrupted
    public var message: String { switch self {
    case .maximumDuration: L("Aufnahme nach 30 Minuten automatisch beendet.")
    case .callbackLoss: L("Mikrofon hat ausgesetzt – Testvorschau erstellt.")
    case .interrupted: L("Aufnahme unterbrochen – Testvorschau erstellt.")
    } }
}
public enum TestDictationAutomaticEvent: Sendable {
    case processing(session: UUID, reason: TestDictationAutomaticReason)
    case finished(session: UUID, reason: TestDictationAutomaticReason, result: TestDictationResult?)
}
@MainActor public protocol TestDictationIntent {
    func start(language: OnboardingLanguage) async throws
    func stopAndTranscribe() async throws -> TestDictationResult
    func cancel() async
    func setAutomaticHandler(_ handler: @escaping @MainActor @Sendable (TestDictationAutomaticEvent) -> Void)
}
public extension TestDictationIntent { func setAutomaticHandler(_ handler: @escaping @MainActor @Sendable (TestDictationAutomaticEvent) -> Void) {} }
/// Root's composition seam for the normal visible record → text → explicit-copy
/// path. This contract intentionally requires microphone and a usable model
/// only: Input Monitoring belongs to global hotkeys and Accessibility belongs
/// to insertion into another app. A caller may always decline the final copy.
public struct ManualDictationCopyContract: Equatable, Sendable {
    public let requiresMicrophone: Bool
    public let requiresUsableModel: Bool
    public let requiresInputMonitoring: Bool
    public let requiresAccessibility: Bool
    public let copyRequiresExplicitUserAction: Bool
    public init(requiresMicrophone: Bool = true, requiresUsableModel: Bool = true, requiresInputMonitoring: Bool = false, requiresAccessibility: Bool = false, copyRequiresExplicitUserAction: Bool = true) {
        self.requiresMicrophone = requiresMicrophone
        self.requiresUsableModel = requiresUsableModel
        self.requiresInputMonitoring = requiresInputMonitoring
        self.requiresAccessibility = requiresAccessibility
        self.copyRequiresExplicitUserAction = copyRequiresExplicitUserAction
    }
    public static let manualOnly = Self()
}
/// Product result for the normal manual-dictation route. The 100,000-byte
/// ceiling mirrors the existing persisted product-text validation; its compact
/// preview mirrors the existing 280-character history presentation. Unlike
/// `TestDictationResult`, this is suitable for a normal, potentially long
/// dictation result and carries the complete text for explicit copy.
public struct ManualDictationResult: Equatable, Sendable {
    public static let maximumTextBytes = 100_000
    public static let maximumPreviewCharacters = 280
    public let text: String
    public let preview: String
    public init?(text: String) {
        guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes else { return nil }
        self.text = text
        self.preview = String(text.prefix(Self.maximumPreviewCharacters))
    }
}
@MainActor public protocol ManualDictationCopyIntent {
    var contract: ManualDictationCopyContract { get }
    func startManualDictation(language: OnboardingLanguage) async throws
    func stopManualDictation() async throws -> ManualDictationResult
    func copyLatestManualDraft() async throws
}
@MainActor public protocol CompletionIntent { func load() async throws -> CompletionDraft?; func save(_ draft: CompletionDraft) async throws }

@MainActor public final class FakePermissionStatusIntent: PermissionStatusIntent {
    public var snapshot: PermissionSnapshot; public var refreshes = 0; public var requests: [PermissionKind] = []; public var settings: [PermissionKind] = []; public var error: Error?
    public init(snapshot: PermissionSnapshot = .init(statuses: [:], generation: 0)) { self.snapshot = snapshot }
    public func refresh() async throws -> PermissionSnapshot { refreshes += 1; if let error { throw error }; return snapshot }
    public func requestAuthorization(for kind: PermissionKind) async throws -> PermissionSnapshot { requests.append(kind); if let error { throw error }; return snapshot }
    public func openSettings(for kind: PermissionKind) { settings.append(kind) }
}
@MainActor public final class FakeMicrophoneTestIntent: MicrophoneTestIntent { public var result = PermissionTestResult(passed: true); public var calls = 0; public var error: Error?; public init() {} ; public func run() async throws -> PermissionTestResult { calls += 1; if let error { throw error }; return result } }
@MainActor public final class FakeShortcutSetupIntent: ShortcutSetupIntent { public var result: ShortcutValidation = .valid; public var calls = 0; public var error: Error?; private var generation: UInt64 = 0; public var captured = ShortcutDraft(display: "⌥B", mode: "Halten", usesFn: false, keyCode: 11, modifiers: 2); public init() {} ; public func beginCapture() throws -> UInt64 { generation &+= 1; return generation }; public func waitForCapture(generation: UInt64) async throws -> ShortcutDraft { guard generation == self.generation else { throw CancellationError() }; return captured }; public func cancelCapture(generation: UInt64) { if generation == self.generation { self.generation &+= 1 } }; public func validate(_ draft: ShortcutDraft) async throws -> ShortcutValidation { calls += 1; if let error { throw error }; return result } }
@MainActor public final class FakeTestDictationIntent: TestDictationIntent {
    public var result = TestDictationResult(preview: L("Dies ist nur eine Testvorschau."))!
    public var calls = 0; public var stops = 0; public var cancellations = 0
    public var languages: [OnboardingLanguage] = []; public var error: Error?
    private var recording = false
    public init() {}
    public func start(language: OnboardingLanguage) async throws { calls += 1; languages.append(language); if let error { throw error }; guard !recording else { throw CancellationError() }; recording = true }
    public func stopAndTranscribe() async throws -> TestDictationResult { guard recording else { throw CancellationError() }; recording = false; stops += 1; if let error { throw error }; return result }
    public func cancel() async { cancellations += 1; recording = false }
}
@MainActor public final class FakeCompletionIntent: CompletionIntent { public var value: CompletionDraft?; public var loads = 0; public var saves = 0; public var error: Error?; public init(value: CompletionDraft? = nil) { self.value = value }; public func load() async throws -> CompletionDraft? { loads += 1; if let error { throw error }; return value }; public func save(_ draft: CompletionDraft) async throws { saves += 1; if let error { throw error }; value = draft } }

@MainActor public final class OnboardingRouter: ObservableObject {
    @Published public private(set) var showsDashboard = false
    @Published public private(set) var showsLockedDashboard = false
    public let dashboard: DashboardViewModel?; public let onboarding: OnboardingViewModel
    private let completion: any CompletionIntent
    public init(dashboard: DashboardViewModel? = nil, permissions: any PermissionStatusIntent = FakePermissionStatusIntent(), microphone: any MicrophoneTestIntent = FakeMicrophoneTestIntent(), shortcut: any ShortcutSetupIntent = FakeShortcutSetupIntent(), testDictation: any TestDictationIntent = FakeTestDictationIntent(), completion: any CompletionIntent = FakeCompletionIntent()) {
        self.dashboard = dashboard; self.completion = completion
        onboarding = OnboardingViewModel(permissions: permissions, microphone: microphone, shortcut: shortcut, testDictation: testDictation, completion: completion)
        onboarding.onDashboardExit = { [weak self] _ in self?.showsLockedDashboard = true }
        onboarding.onFinishedToDashboard = { [weak self] in self?.showsDashboard = true }
    }
    public func loadCompletion() async { do { showsDashboard = try await completion.load() != nil; showsLockedDashboard = false } catch { showsDashboard = false } }
    public func showDashboard() { showsDashboard = true; showsLockedDashboard = false }
    public func resumeOnboarding() { showsLockedDashboard = false }
    /// The pre-foundation composition calls this after draining its ephemeral
    /// runner and before it opens encrypted persistence.
    public func clearEphemeralPreview() { onboarding.clearEphemeralPreview() }
}

public struct OnboardingRouterView: View {
    @ObservedObject private var router: OnboardingRouter
    public init(router: OnboardingRouter) { self.router = router }
    public var body: some View { Group { if router.showsDashboard, let dashboard = router.dashboard { DashboardRootView(model: dashboard) } else if router.showsLockedDashboard || router.showsDashboard { LockedDashboardView(resume: router.resumeOnboarding) } else { OnboardingRootView(model: router.onboarding) } }.task { await router.loadCompletion() } }
}

private struct LockedDashboardView: View { let resume: () -> Void; var body: some View { ContentUnavailableView(L("Einrichtung erforderlich"), systemImage: "lock", description: Text(L("Klangschrift bleibt gesperrt, bis die lokale Einrichtung abgeschlossen ist."))).overlay(alignment: .bottom) { Button(L("Einrichtung fortsetzen"), action: resume).padding() } } }

@MainActor public final class OnboardingViewModel: ObservableObject {
    @Published public private(set) var step: OnboardingStep = .welcome
    @Published public private(set) var flowID = UUID()
    @Published public private(set) var requestGeneration: UInt64 = 0
    @Published public private(set) var snapshot = PermissionSnapshot(statuses: [:], generation: 0)
    @Published public private(set) var microphoneTest: PermissionTestResult?
    @Published public private(set) var microphoneTestState: MicrophoneTestState = .idle
    @Published public private(set) var shortcutValidation: ShortcutValidation?
    @Published public private(set) var preview: TestDictationResult?
    @Published public private(set) var testDictationCompletionReason: TestDictationAutomaticReason?
    private var automaticTestCompleted = false
    private var pendingTestStart: UUID?
    private var testCallsInFlight = 0 { didSet { refreshBusy() } }
    private var testBusyToken: (UUID, UInt64, OnboardingStep)?
    private func beginTestCall(_ token: (UUID, UInt64, OnboardingStep)) { testCallsInFlight += 1; testBusyToken = token }
    private func endTestCall() {
        testCallsInFlight -= 1
        if let token = testBusyToken, current(token) { requestBusy = testDictationPhase == .processing }
    }
    private var testObservationGeneration: UInt64 = 0
    @Published public private(set) var testDictationPhase: TestDictationPhase = .idle
    @Published public var shortcut = ShortcutDraft()
    @Published public var language: OnboardingLanguage = .automatic
    @Published public var privacy = PrivacyDraft()
    @Published public private(set) var busy = false
    private var requestBusy = false { didSet { refreshBusy() } }
    private func refreshBusy() { busy = requestBusy || testCallsInFlight > 0 }
    @Published public private(set) var error: OnboardingError?
    @Published public private(set) var completed = false
    @Published public private(set) var skippedPermissions = Set<PermissionKind>()
    @Published public private(set) var warningAcknowledged = false
    @Published public private(set) var shortcutCaptureGeneration: UInt64?
    @Published public private(set) var mode: OnboardingMode = .initialSetup
    public var onDashboardExit: (OnboardingExit) -> Void = { _ in }
    public var onFinishedToDashboard: () -> Void = {}
    private let permissions: any PermissionStatusIntent; private let microphone: any MicrophoneTestIntent; private let shortcutIntent: any ShortcutSetupIntent; private let testDictation: any TestDictationIntent; private let completion: any CompletionIntent
    private var recoveryResume: (@MainActor () async -> Bool)?
    private var recoveryResumeStarted = false
    public init(permissions: any PermissionStatusIntent = FakePermissionStatusIntent(), microphone: any MicrophoneTestIntent = FakeMicrophoneTestIntent(), shortcut: any ShortcutSetupIntent = FakeShortcutSetupIntent(), testDictation: any TestDictationIntent = FakeTestDictationIntent(), completion: any CompletionIntent = FakeCompletionIntent()) { self.permissions = permissions; self.microphone = microphone; self.shortcutIntent = shortcut; self.testDictation = testDictation; self.completion = completion }
    public var isPermissionRecovery: Bool { mode == .permissionRecovery }
    public func configurePermissionRecovery(snapshot: PermissionSnapshot, resume: @escaping @MainActor () async -> Bool) {
        guard let missing = firstMissingPermission(in: snapshot) else { return }
        invalidate(newFlow: true)
        mode = .permissionRecovery
        self.snapshot = snapshot
        step = step(for: missing)
        error = .permissionUnavailable
        recoveryResume = resume
        recoveryResumeStarted = false
    }
    public func start() async { guard !isPermissionRecovery else { return }; invalidate(newFlow: true); await refreshPermissions() }
    public func refreshPermissions() async {
        guard !isPermissionRecovery || (!busy && !recoveryResumeStarted) else { return }
        let token = beginRequest()
        do {
            let next = try await permissions.refresh()
            guard current(token) else { return }
            snapshot = next
            if isPermissionRecovery { await applyRecoverySnapshot(next, token: token) }
            else { invalidateDownstreamForRevocation(); finishRequest(token) }
        } catch { fail(.permissionUnavailable, token) }
    }
    public func requestPermission(_ kind: PermissionKind) async {
        guard !isPermissionRecovery || (!busy && !recoveryResumeStarted) else { return }
        let token = beginRequest()
        do {
            let next = try await permissions.requestAuthorization(for: kind)
            guard current(token) else { return }
            snapshot = next
            if isPermissionRecovery { await applyRecoverySnapshot(next, token: token) }
            else { invalidateDownstreamForRevocation(); finishRequest(token) }
        } catch { fail(.permissionUnavailable, token) }
    }
    public func openSettings(_ kind: PermissionKind) { permissions.openSettings(for: kind) }
    public func runMicrophoneTest() async {
        guard !isPermissionRecovery, isGranted(.microphone) else { error = .permissionUnavailable; return }
        let token = beginRequest()
        microphoneTestState = .running
        do {
            let result = try await microphone.run()
            guard current(token) else { return }
            microphoneTest = result
            microphoneTestState = result.passed ? .succeeded(level: result.level) : .failed(result.failure ?? .captureCouldNotStart)
            error = result.passed ? nil : .microphoneTestFailed
            finishRequest(token)
        } catch {
            guard current(token) else { return }
            microphoneTestState = .failed(error is CancellationError ? .cancelled : .captureCouldNotStart)
            fail(.microphoneTestFailed, token)
        }
    }
    public func validateShortcut() async { let token = beginRequest(); do { let result = try await shortcutIntent.validate(shortcut); guard current(token) else { return }; shortcutValidation = result; warningAcknowledged = false; error = result == .valid || result == .warningUnverifiable ? nil : .shortcutBlocked; finishRequest(token) } catch { fail(.shortcutBlocked, token) } }
    public func beginShortcutCapture() async { guard !busy else { return }; do { let generation = try shortcutIntent.beginCapture(); shortcutCaptureGeneration = generation; let value = try await shortcutIntent.waitForCapture(generation: generation); guard shortcutCaptureGeneration == generation else { return }; shortcut = value; shortcutCaptureGeneration = nil; await validateShortcut() } catch { shortcutCaptureGeneration = nil; self.error = .shortcutBlocked } }
    public func cancelShortcutCapture() { guard let generation = shortcutCaptureGeneration else { return }; shortcutIntent.cancelCapture(generation: generation); shortcutCaptureGeneration = nil }
    public func acknowledgeShortcutWarning() { if shortcutValidation == .warningUnverifiable { warningAcknowledged = true; error = nil } }
    public func startTestDictation() async {
        guard testDictationPhase == .idle, !busy, testCallsInFlight == 0, isGranted(.microphone), microphoneTest?.passed == true else { error = .testFailed; return }
        preview = nil; testDictationCompletionReason = nil; automaticTestCompleted = false
        let token = beginRequest()
        let startID = UUID()
        pendingTestStart = startID
        beginTestCall(token)
        defer { if pendingTestStart == startID { pendingTestStart = nil }; endTestCall() }
        testObservationGeneration &+= 1
        let observation = testObservationGeneration
        testDictation.setAutomaticHandler { [weak self] event in
            guard let self, self.flowID == token.0, self.step == token.2, self.testObservationGeneration == observation else { return }
            self.automaticTestCompleted = true
            switch event {
            case .processing: self.testDictationPhase = .processing; self.requestBusy = true
            case .finished(_, let reason, let result):
                self.preview = result; self.testDictationCompletionReason = reason
                self.testDictationPhase = .idle; self.requestBusy = false; self.error = result == nil ? .testFailed : nil
            }
        }
        do {
            try await testDictation.start(language: language)
            guard current(token) else {
                // This call still owns the restart barrier. A successful late
                // start may have reopened capture after the earlier cancel.
                await testDictation.cancel()
                return
            }
            if !automaticTestCompleted { testDictationPhase = .recording; error = nil }
        } catch { guard current(token) else { return }; testDictationPhase = .idle; fail(.testFailed, token) }
    }
    public func stopTestDictation() async {
        guard testDictationPhase == .recording, !busy else { return }
        testDictationPhase = .processing; let token = beginRequest()
        beginTestCall(token); defer { endTestCall() }
        do {
            let result = try await testDictation.stopAndTranscribe()
            guard current(token) else { return }
            preview = result; testDictationPhase = .idle; error = nil
        } catch { guard current(token) else { return }; testDictationPhase = .idle; fail(.testFailed, token) }
    }
    public func next() async { guard !busy else { return }; if isPermissionRecovery { await refreshPermissions(); return }; error = nil; switch step {
        case .welcome: move(to: .microphone)
        case .microphone: guard isGranted(.microphone) else { error = .permissionUnavailable; return }; guard microphoneTest?.passed == true else { error = .microphoneTestFailed; return }; move(to: .accessibility)
        case .accessibility: guard isGranted(.accessibility) else { error = .permissionUnavailable; return }; move(to: .inputMonitoring)
        case .inputMonitoring: guard isGranted(.inputMonitoring) else { error = .permissionUnavailable; return }; move(to: .shortcut)
        case .shortcut: guard shortcutValidation == .valid || (shortcutValidation == .warningUnverifiable && warningAcknowledged) else { error = .shortcutBlocked; return }; move(to: .testDictation)
        case .testDictation: guard preview != nil else { error = .testFailed; return }; move(to: .privacy)
        case .privacy: await finish()
        }
    }
    public func back() { guard !isPermissionRecovery else { return }; if step == .testDictation { cancelTestDictation() }; guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { invalidate(newFlow: false); return }; preview = nil; move(to: previous) }
    public func clearEphemeralPreview() { cancelTestDictation(); preview = nil }
    public func skipPermission(_ kind: PermissionKind) { guard !isPermissionRecovery, kind != .microphone else { return }; skippedPermissions.insert(kind); invalidate(newFlow: false); completed = false; onDashboardExit(.deferredPermission(kind)) }
    public func skipToDashboard() { guard !isPermissionRecovery else { return }; invalidate(newFlow: false); completed = false; onDashboardExit(.later) }
    private func finish() async { guard !completed, !busy else { return }; let token = beginRequest(); do { let refreshed = try await permissions.refresh(); guard current(token) else { return }; snapshot = refreshed; guard strictCompletionRequirements else { error = .completionRequirementsChanged; requestBusy = false; return }; try await completion.save(.init(shortcut: shortcut, privacy: privacy)); guard current(token) else { return }; completed = true; finishRequest(token); onFinishedToDashboard() } catch { fail(.saveFailed, token) } }
    private func move(to next: OnboardingStep) { if next != .shortcut { cancelShortcutCapture() }; if step == .testDictation && next != .testDictation { cancelTestDictation() }; invalidate(newFlow: false); step = next; error = nil; if next.rawValue < OnboardingStep.testDictation.rawValue { preview = nil }; if next.rawValue < OnboardingStep.shortcut.rawValue { shortcutValidation = nil; warningAcknowledged = false }; if next.rawValue < OnboardingStep.microphone.rawValue { microphoneTest = nil; microphoneTestState = .idle } }
    private func invalidate(newFlow: Bool) { requestGeneration &+= 1; requestBusy = false; if newFlow { cancelTestDictation(); flowID = UUID(); completed = false; step = .welcome; preview = nil; microphoneTest = nil; microphoneTestState = .idle; shortcutValidation = nil; warningAcknowledged = false; skippedPermissions = [] } }
    private func beginRequest() -> (UUID, UInt64, OnboardingStep) { requestGeneration &+= 1; requestBusy = true; return (flowID, requestGeneration, step) }
    private func current(_ token: (UUID, UInt64, OnboardingStep)) -> Bool { token.0 == flowID && token.1 == requestGeneration && token.2 == step }
    private func finishRequest(_ token: (UUID, UInt64, OnboardingStep)) { guard current(token) else { return }; requestBusy = false }
    private func fail(_ value: OnboardingError, _ token: (UUID, UInt64, OnboardingStep)) { guard current(token) else { return }; error = value; requestBusy = false }
    private func isGranted(_ kind: PermissionKind) -> Bool { snapshot[kind].authorization == .granted }
    private func firstMissingPermission(in snapshot: PermissionSnapshot) -> PermissionKind? {
        [.microphone, .accessibility, .inputMonitoring].first { snapshot[$0].authorization != .granted }
    }
    private func step(for permission: PermissionKind) -> OnboardingStep {
        switch permission { case .microphone: .microphone; case .accessibility: .accessibility; case .inputMonitoring: .inputMonitoring }
    }
    private func applyRecoverySnapshot(_ snapshot: PermissionSnapshot, token: (UUID, UInt64, OnboardingStep)) async {
        if let missing = firstMissingPermission(in: snapshot) {
            finishRequest(token)
            step = step(for: missing)
            error = .permissionUnavailable
            return
        }
        guard let recoveryResume, !recoveryResumeStarted else { finishRequest(token); return }
        recoveryResumeStarted = true
        let resumed = await recoveryResume()
        guard current(token) else { return }
        if resumed {
            completed = true
            finishRequest(token)
        } else {
            leavePermissionRecovery()
        }
    }
    private func leavePermissionRecovery() {
        requestGeneration &+= 1
        flowID = UUID()
        requestBusy = false
        mode = .initialSetup
        recoveryResume = nil
        recoveryResumeStarted = false
        step = .welcome
        error = nil
    }
    private var strictCompletionRequirements: Bool { isGranted(.microphone) && isGranted(.accessibility) && isGranted(.inputMonitoring) && microphoneTest?.passed == true && (shortcutValidation == .valid || (shortcutValidation == .warningUnverifiable && warningAcknowledged)) && preview != nil && skippedPermissions.isEmpty }
    private func invalidateDownstreamForRevocation() {
        if !isGranted(.microphone) {
            cancelTestDictation(); microphoneTest = nil; microphoneTestState = .idle; preview = nil; completed = false
            if step.rawValue > OnboardingStep.microphone.rawValue { step = .microphone; requestBusy = false }
        } else if !isGranted(.accessibility) {
            cancelTestDictation(); preview = nil; completed = false
            if step.rawValue > OnboardingStep.accessibility.rawValue { step = .accessibility; requestBusy = false }
        } else if !isGranted(.inputMonitoring) {
            cancelTestDictation(); preview = nil; completed = false
            if step.rawValue > OnboardingStep.inputMonitoring.rawValue { step = .inputMonitoring; requestBusy = false }
        }
        if !isGranted(.accessibility) { skippedPermissions.remove(.accessibility) }
        if !isGranted(.inputMonitoring) { skippedPermissions.remove(.inputMonitoring) }
    }
    private func cancelTestDictation() {
        testObservationGeneration &+= 1; requestGeneration &+= 1
        testDictation.setAutomaticHandler { _ in }
        let token = (flowID, requestGeneration, step)
        testBusyToken = token
        guard testDictationPhase != .idle || pendingTestStart != nil else { requestBusy = false; return }
        testDictationPhase = .idle; requestBusy = false
        beginTestCall(token)
        Task { defer { endTestCall() }; await testDictation.cancel() }
    }
}

public struct OnboardingRootView: View {
    @ObservedObject private var model: OnboardingViewModel; @Environment(\.accessibilityReduceMotion) private var reduceMotion; @Environment(\.scenePhase) private var scenePhase; @Environment(\.colorScheme) private var colorScheme; @FocusState private var headingFocused: Bool
    public init(model: OnboardingViewModel) { self.model = model }
    public var body: some View { VStack(alignment: .leading, spacing: 24) { Text(model.isPermissionRecovery ? L("Gespeicherte Einrichtung") : L("Schritt %@ von %@", String(describing: model.step.rawValue + 1), String(describing: OnboardingStep.allCases.count))).font(.caption).foregroundStyle(Color.semantic(.secondary, colorScheme)).accessibilityLabel(model.isPermissionRecovery ? L("Gespeicherte Einrichtung") : L("Schritt %@ von %@", String(describing: model.step.rawValue + 1), String(describing: OnboardingStep.allCases.count))); Text(verbatim: model.step.title).font(.system(.largeTitle, design: .rounded)).fontWeight(.semibold).accessibilityAddTraits(.isHeader).focused($headingFocused); stepBody; if let error = model.error { Text(errorCopy(error)).foregroundStyle(Color.semantic(.error, colorScheme)).accessibilityLabel(errorCopy(error)).accessibilityAddTraits(.isStaticText) }; HStack { if model.step != .welcome && !model.isPermissionRecovery { Button(L("Zurück")) { model.back() }.keyboardShortcut("[", modifiers: .command) }; Spacer(); Button(primaryTitle) { Task { await model.next() } }.buttonStyle(StudioProminentButtonStyle()).disabled(primaryDisabled).keyboardShortcut(.return, modifiers: []) } }.padding(32).frame(minWidth: 560, minHeight: 430).onAppear { headingFocused = true; Task { await model.start() } }.onChange(of: model.step) { _, _ in headingFocused = true }.onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.refreshPermissions() } } }.animation(reduceMotion ? nil : .easeOut(duration: KlangschriftToken.standardMotionSeconds), value: model.step) }
    @ViewBuilder private var stepBody: some View { switch model.step { case .welcome: VStack(alignment: .leading, spacing: 12) { Text(L("Deine Stimme bleibt auf diesem Mac.")).fixedSize(horizontal: false, vertical: true); Button(L("Einrichtung später fortsetzen")) { model.skipToDashboard() }.accessibilityHint(L("Öffnet das Dashboard ohne Abschluss der Einrichtung.")) }; case .microphone: permissionBody(.microphone, description: L("Klangschrift hört nur während sichtbarer Aufnahme."), test: true); case .accessibility: permissionBody(.accessibility, description: L("Für Einfügen in andere Apps. Manuelles Diktieren und Kopieren bleiben verfügbar."), test: false); case .inputMonitoring: permissionBody(.inputMonitoring, description: L("Kurzbefehle aktivieren – kein dauerhaftes Zuhören."), test: false); case .shortcut: VStack(alignment: .leading, spacing: 12) { Text(L("Shortcut wählen")); Text(verbatim: SettingsShortcutDisplay.name(model.shortcut)).accessibilityLabel(L("Aktueller Shortcut: %@", String(describing: model.shortcut.display))); Text(L("Fn verfügbar; Globe noch nicht verfügbar.")).foregroundStyle(Color.semantic(.secondary, colorScheme)); Button(model.shortcutCaptureGeneration == nil ? L("Shortcut aufnehmen") : L("Aufnahme abbrechen")) { if model.shortcutCaptureGeneration == nil { Task { await model.beginShortcutCapture() } } else { model.cancelShortcutCapture() } }; Button(L("Shortcut prüfen")) { Task { await model.validateShortcut() } }; if model.shortcutValidation == .warningUnverifiable { Button(L("Warnung verstanden")) { model.acknowledgeShortcutWarning() } } }; case .testDictation: VStack(alignment: .leading, spacing: 12) { Picker(L("Sprache"), selection: $model.language) { ForEach(OnboardingLanguage.allCases, id: \.self) { Text($0.title).tag($0) } }.accessibilityLabel(L("Sprache für das Testdiktat")).disabled(model.testDictationPhase != .idle); Button(testDictationButtonTitle) { Task { if model.testDictationPhase == .recording { await model.stopTestDictation() } else { await model.startTestDictation() } } }.disabled(model.testDictationPhase == .processing).accessibilityHint(testDictationButtonHint); if model.testDictationPhase == .recording { Label(L("Aufnahme läuft – jetzt sprechen."), systemImage: "record.circle.fill").foregroundStyle(Color.semantic(.listening, colorScheme)).accessibilityLabel(L("Aufnahme läuft. Jetzt sprechen.")) } else if model.testDictationPhase == .processing { Label(L("Wird lokal ausgewertet …"), systemImage: "waveform").foregroundStyle(Color.semantic(.processing, colorScheme)).accessibilityLabel(L("Testdiktat wird lokal ausgewertet.")) }; if let reason = model.testDictationCompletionReason, model.preview != nil { Text(reason.message).font(.caption) }; if let preview = model.preview { Text(L("Testvorschau — wird nicht gespeichert")).font(.headline); Text(verbatim: preview.preview).fixedSize(horizontal: false, vertical: true).accessibilityLabel(L("Testvorschau: %@", String(describing: preview.preview))) } }; case .privacy: VStack(alignment: .leading, spacing: 12) { Toggle(L("Verlauf lokal speichern"), isOn: $model.privacy.historyEnabled); Picker(L("Aufbewahrung"), selection: $model.privacy.retention) { Text(L("Dauerhaft")).tag(HistoryRetention.forever); Text(L("30 Tage")).tag(HistoryRetention.days30); Text(L("90 Tage")).tag(HistoryRetention.days90); Text(L("Keine Speicherung")).tag(HistoryRetention.none) } } } }
    @ViewBuilder private func permissionBody(_ kind: PermissionKind, description: String, test: Bool) -> some View { VStack(alignment: .leading, spacing: 12) { if model.isPermissionRecovery { Text(L("macOS muss die Rechte für diese App-Version erneut bestätigen. Deine gespeicherte Einrichtung bleibt erhalten.")).fixedSize(horizontal: false, vertical: true) }; Text(description).fixedSize(horizontal: false, vertical: true); let state = model.snapshot[kind]; Text(permissionCopy(state.authorization)).foregroundStyle(Color.semantic(PermissionDisplay.statusRole(state.authorization), colorScheme)).accessibilityValue(permissionCopy(state.authorization)).help(state.authorization == .restricted ? L("Durch macOS eingeschränkt") : permissionCopy(state.authorization)); if test { microphoneTestStatus }; HStack { Button(L("Zugriff erlauben")) { Task { await model.requestPermission(kind) } }.disabled(!state.canRequest); if state.settingsAvailable { Button(L("Systemeinstellungen öffnen")) { model.openSettings(kind) } }; if !model.isPermissionRecovery { if test { Button(L("Mikrofon testen")) { Task { await model.runMicrophoneTest() } }.disabled(state.authorization != .granted || model.microphoneTestState == .running) } else { Button(L("Vorerst überspringen")) { model.skipPermission(kind) } } } } } }
    @ViewBuilder private var microphoneTestStatus: some View {
        switch model.microphoneTestState {
        case .idle:
            Text(L("Mikrofontest noch nicht ausgeführt."))
        case .running:
            Label(L("Mikrofontest läuft – kurzer Pegelcheck …"), systemImage: "waveform")
        case .succeeded(let level):
            let value = level.map { String(format: "%.3f", locale: AppLocalization.locale, $0) } ?? L("nicht verfügbar")
            Text(L("Mikrofontest erfolgreich. Pegel: %@.", String(describing: value)))
        case .failed(let failure):
            Text(L("Mikrofontest fehlgeschlagen: %@", String(describing: microphoneFailureCopy(failure))))
        }
        Text(L("Prüft nur einen kurzen Audio-Frame, keine Diktat- oder Modellfunktion."))
            .font(.caption)
            .foregroundStyle(Color.semantic(.secondary, colorScheme))
    }
    private var primaryTitle: String { model.isPermissionRecovery ? L("Erneut prüfen") : (model.step == .privacy ? L("Einrichtung abschließen") : L("Weiter")) }
    private var primaryDisabled: Bool { model.busy || (model.step == .testDictation && model.testDictationPhase != .idle) }
    private var testDictationButtonTitle: String { switch model.testDictationPhase { case .idle: L("Aufnahme starten"); case .recording: L("Aufnahme beenden & auswerten"); case .processing: L("Wird ausgewertet …") } }
    private var testDictationButtonHint: String { model.testDictationPhase == .recording ? L("Beendet die Aufnahme und erstellt die lokale Testvorschau.") : L("Startet eine sichtbare lokale Testaufnahme.") }
    private func permissionCopy(_ state: Authorization) -> String { PermissionDisplay.status(state) }
    private func microphoneFailureCopy(_ failure: MicrophoneTestFailure) -> String { switch failure { case .alreadyRunning: L("Ein Test läuft bereits."); case .invalidConfiguration: L("Die Testdauer ist ungültig."); case .noAudioFrameBeforeTimeout: L("Innerhalb der Testdauer kam kein Audio-Frame an."); case .captureCouldNotStart: L("Die Audioaufnahme konnte nicht gestartet werden."); case .invalidAudioLevel: L("Der empfangene Pegel war ungültig."); case .cancelled: L("Der Mikrofontest wurde abgebrochen.") } }
    private func errorCopy(_ error: OnboardingError) -> String { switch error { case .permissionUnavailable: L("Der erforderliche Zugriff fehlt."); case .microphoneTestFailed: L("Der Mikrofontest war nicht erfolgreich."); case .shortcutBlocked: L("Dieser Shortcut kann nicht verwendet werden."); case .testFailed: L("Das Testdiktat konnte nicht abgeschlossen werden."); case .saveFailed: L("Die Einrichtung wurde nicht gespeichert. Bitte erneut versuchen."); case .completionRequirementsChanged: L("Ein erforderlicher Zugriff hat sich geändert. Bitte prüfe die Einrichtung erneut.") } }
}
