import Foundation
import KlangschriftCore
import KlangschriftHotkeys
import KlangschriftAudio
import KlangschriftTranscription

/// App-layer contracts deliberately contain neither transcript nor audio logging APIs.
public protocol DictationMonotonicClock: Sendable { func nowNanoseconds() -> UInt64 }
public protocol DictationAudio: Sendable {
    func armPreRoll() async throws
    func armPreRoll(session: DictationSessionID) async throws
    func disarmPreRoll(session: DictationSessionID) async
    func disarmPreRoll() async
    func start(session: DictationSessionID, mode: RecordingMode) async throws -> URL
    func stop(session: DictationSessionID) async throws -> URL
    func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult
    func interrupt(session: DictationSessionID) async -> Bool
    func stopCapture(session: DictationSessionID) async
    func cancelAndCleanup() async
    func cancelAndCleanup(session: DictationSessionID) async
}
public extension DictationAudio {
    func armPreRoll(session: DictationSessionID) async throws { try await armPreRoll() }
    func disarmPreRoll(session: DictationSessionID) async { await disarmPreRoll() }
    func stopResult(session: DictationSessionID) async throws -> AudioCaptureResult { .init(url: try await stop(session: session)) }
    func interrupt(session: DictationSessionID) async -> Bool { false }
}
public protocol LocalTranscribing: Sendable {
    func transcribe(audio: URL, session: DictationSessionID, language: String?) async throws -> String
    func cancelAndReap() async
    func cancelAndReap(session: DictationSessionID) async
    /// The coordinator may remove its session-owned artifact only after this
    /// reports a confirmed reader/process end.  Unknown is fail-closed.
    func cancelAndReapOutcome(session: DictationSessionID) async -> HelperTerminationOutcome
}
public extension LocalTranscribing {
    func cancelAndReapOutcome(session: DictationSessionID) async -> HelperTerminationOutcome {
        await cancelAndReap(session: session)
        return .reaped
    }
}
public protocol DictionaryTransforming: Sendable { func transform(_ text: String) async throws -> String }
public struct DictationPreferences: Sendable, Equatable {
    public let historyEnabled: Bool; public let retentionEnabled: Bool; public let language: String?
    public init(historyEnabled: Bool = true, retentionEnabled: Bool = true, language: String? = nil) { self.historyEnabled = historyEnabled; self.retentionEnabled = retentionEnabled; self.language = language }
}
public protocol DictationSettings: Sendable { func current() async -> DictationPreferences }
public enum AppInsertionOutcome: Sendable, Equatable { case notAttempted, inserted, copiedForRecovery, failed }
public protocol CurrentCursorInserting: Sendable {
    /// Required session boundary: P5 captures focus exactly before recording.
    func beginRecording(session: DictationSessionID) async -> Bool
    func clearRecording(session: DictationSessionID) async
    func insertAfterFocusRevalidation(_ text: String) async -> AppInsertionOutcome
}
/// AP05's local overview draft receives a completed, session-owned result
/// before insertion/history policy runs. It is neither history nor clipboard.
public protocol InterruptedTextCopying: Sendable { func copy(_ text: String, session: DictationSessionID) async -> Bool }
public struct NoopInterruptedTextCopier: InterruptedTextCopying { public init() {}; public func copy(_ text: String, session: DictationSessionID) async -> Bool { false } }
public protocol DictationDraftPresenting: Sendable {
    func beginDraft(session: DictationSessionID) async
    func publishDraft(_ text: String, session: DictationSessionID) async
}
public extension DictationDraftPresenting {
    func beginDraft(session: DictationSessionID) async {}
}
public struct NoopDictationDraftPresenter: DictationDraftPresenting {
    public init() {}
    public func publishDraft(_ text: String, session: DictationSessionID) async {}
}
public protocol DictationHistory: Sendable {
    func save(session: DictationSessionID, text: String, durationMs: Int64, status: AppInsertionOutcome) async throws
    func updateInsertion(session: DictationSessionID, status: AppInsertionOutcome) async throws
    func markIncompleteSessionsFailed() async
}
public protocol DictationStatistics: Sendable {
    func record(wordCount: Int64, recordedMilliseconds: Int64) async throws
}
/// Explicit inert dependency for tests or intentionally statistics-free tools.
/// Production composition must inject its encrypted repository adapter.
public struct NoopDictationStatistics: DictationStatistics {
    public init() {}
    public func record(wordCount: Int64, recordedMilliseconds: Int64) async throws {}
}
public enum DictationActionFailure: String, Sendable, Equatable { case audioStart, audioDevice, audioPreference, microphone, audioStop, transcription, readerUnknown }
public struct DictationUIStateMetadata: Sendable, Equatable { public let sessionID: DictationSessionID?; public let generation: UInt64; public let failure: DictationActionFailure?; public init(sessionID: DictationSessionID?, generation: UInt64, failure: DictationActionFailure? = nil) { self.sessionID = sessionID; self.generation = generation; self.failure = failure } }
public protocol DictationUIState: Sendable { func showAudioCompletion(_ reason: AudioCaptureCompletionReason, metadata: DictationUIStateMetadata) async; func show(_ state: DictationCoordinator.State) async; func show(_ state: DictationCoordinator.State, metadata: DictationUIStateMetadata) async }
public extension DictationUIState {
    func showAudioCompletion(_ reason: AudioCaptureCompletionReason, metadata: DictationUIStateMetadata) async {}
    func show(_ state: DictationCoordinator.State, metadata: DictationUIStateMetadata) async { await show(state) }
}
public protocol DictationDiagnostics: Sendable { func record(code: String) }
/// The P2 owner calls this only after a coordinator terminal transition.
public protocol DictationHotkeyCompleting: Sendable { func completeProcessing() async }
public enum LocalTranscriptionFailure: Error, Sendable, Equatable { case outcomeUnknown, timeout, failed }

public enum DictationCoordinatorError: Error, Sendable, Equatable { case busy, cancelled, helperUnknown, failed }

/// The serial owner of a dictation generation. Every asynchronous completion is
/// checked against the active UUID before it can change state or insert text.
public actor DictationCoordinator {
    public enum State: String, Sendable, Equatable { case idle, prearming, listening, finalizing, transcribing, transforming, persisting, inserting, recovery, failed }
    private struct Session: Sendable {
        let id: DictationSessionID
        let generation: UInt64
        let mode: RecordingMode
        let manualDraftOnly: Bool
        let perf: PerfTrace
        var recordingStartedAt: UInt64?
        var audio: URL?
        var pendingPCMCompletion = false
        var insertionTask: Task<AppInsertionOutcome, Never>?
        var recoveryTask: Task<Bool, Never>?
        var historyOnly = false
        var completionReason: AudioCaptureCompletionReason?
    }
    private let clock: any DictationMonotonicClock
    private let audio: any DictationAudio
    private let helper: any LocalTranscribing
    private let dictionary: any DictionaryTransforming
    private let history: any DictationHistory
    private let statistics: any DictationStatistics
    private let settings: any DictationSettings
    private var interruptionCopy: any InterruptedTextCopying
    public func bindInterruptionCopy(_ copier: any InterruptedTextCopying) { interruptionCopy = copier }
    private let insertion: any CurrentCursorInserting
    private let draft: any DictationDraftPresenting
    private let ui: any DictationUIState
    private let diagnostics: any DictationDiagnostics
    private var hotkeyNeutralizer: (@Sendable (DictationSessionID) -> Void)?
    public func bindHotkeyNeutralizer(_ neutralize: @escaping @Sendable (DictationSessionID) -> Void) { hotkeyNeutralizer = neutralize }
    private let hotkeyCompletion: (any DictationHotkeyCompleting)?
    private var stateValue: State = .idle
    private var lastFailure: DictationActionFailure?
    private var current: Session?
    private var generation: UInt64 = 0
    private var prearmGeneration: UInt64?
    private var prearmedSession: (id: DictationSessionID, perf: PerfTrace)?
    private var prearmTask: Task<Void, Error>?
    private var tearingDown = false
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var pendingRecoveryCount = 0
    private var inputGeneration: UInt64 = 0
    private var cleanupBlockedByUnknownReap: Set<DictationSessionID> = []

    public init(clock: any DictationMonotonicClock, audio: any DictationAudio, helper: any LocalTranscribing, dictionary: any DictionaryTransforming, history: any DictationHistory, statistics: any DictationStatistics, settings: any DictationSettings, insertion: any CurrentCursorInserting, draft: any DictationDraftPresenting = NoopDictationDraftPresenter(), ui: any DictationUIState, diagnostics: any DictationDiagnostics, hotkeyCompletion: (any DictationHotkeyCompleting)? = nil, interruptionCopy: any InterruptedTextCopying = NoopInterruptedTextCopier()) {
        self.interruptionCopy = interruptionCopy
        self.clock = clock; self.audio = audio; self.helper = helper; self.dictionary = dictionary; self.history = history; self.statistics = statistics; self.settings = settings; self.insertion = insertion; self.draft = draft; self.ui = ui; self.diagnostics = diagnostics; self.hotkeyCompletion = hotkeyCompletion
    }
    public func state() -> State { stateValue }
    /// Adapter-only terminal path. The session check prevents a stale P3
    /// device event from cancelling a newer coordinator generation.
    public func cancelForAudioTerminal(session: DictationSessionID) async {
        if prearmedSession?.id == session { hotkeyNeutralizer?(session); await discardPreRoll(); return }
        guard current?.id == session, !tearingDown else { return }; await cancelCurrent()
    }
    /// A retained audio terminal may finish only its still-listening generation.
    public func finishForAudioTerminal(session: DictationSessionID, reason: AudioCaptureCompletionReason) async {
        guard current?.id == session, !tearingDown else { return }
        if reason == .interrupted || reason == .lockedCopied { current?.historyOnly = true; current?.insertionTask?.cancel() }
        let effectiveReason: AudioCaptureCompletionReason = current?.completionReason == .lockedCopied || reason == .lockedCopied ? .lockedCopied : current?.historyOnly == true ? .interrupted : reason
        current?.completionReason = effectiveReason
        guard stateValue == .listening else { return }
        inputGeneration &+= 1
        hotkeyNeutralizer?(session)
        current?.pendingPCMCompletion = true
        if current?.recordingStartedAt == nil { return }
        await stopAndProcess(completionReason: reason)
    }
    private func interruptCurrent() async {
        guard let session = current, !tearingDown else { return }
        current?.historyOnly = true
        if current?.completionReason != .lockedCopied { current?.completionReason = .interrupted }
        current?.insertionTask?.cancel()
        hotkeyNeutralizer?(session.id)
        let retained = await audio.interrupt(session: session.id)
        guard isCurrent(session), !tearingDown else { return }
        if !retained { await cancelCurrent() }
        else if stateValue == .listening {
            current?.pendingPCMCompletion = true
            if current?.recordingStartedAt != nil { await stopAndProcess(completionReason: .interrupted) }
        }
    }
    private func show(_ state: State) async { await ui.show(state, metadata: .init(sessionID: current?.id, generation: generation, failure: lastFailure)) }
    /// A restart recovery may race an in-process continuation in tests or an
    /// app lifecycle transition.  Invalidate its generation before awaiting
    /// cleanup, so no late stage can persist or insert.
    public func recoverAfterRestart() async {
        pendingRecoveryCount += 1
        while tearingDown {
            await withCheckedContinuation { teardownWaiters.append($0) }
        }
        // Recovery joins an existing teardown before becoming its next owner.
        // Keep starts excluded through recovery's own final UI/history awaits.
        tearingDown = true
        await discardPreRoll(publish: false)
        let active = current
        current = nil; generation &+= 1; stateValue = .idle
        if let active {
            await audio.stopCapture(session: active.id)
            await cleanupAfterReap(session: active.id)
            await insertion.clearRecording(session: active.id)
            await hotkeyCompletion?.completeProcessing()
        }
        await history.markIncompleteSessionsFailed(); await show(.idle)
        pendingRecoveryCount -= 1
        finishTeardown()
    }

    private func finishTeardown() {
        tearingDown = false
        let waiters = teardownWaiters; teardownWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// P2 actions are interpreted only here; actions from stale event callbacks are harmless once idle.
    public func consume(_ actions: [HotkeyAction], perf: PerfTrace? = nil, perfTiming: PerfInputTiming? = nil, isValid: @escaping @Sendable () -> Bool = { true }) async {
        guard isValid() else { return }
        let input = inputGeneration
        var measured = perf
        if let timing = perfTiming {
            if actions.contains(.armPreRoll) || actions.contains(.startPushToTalk) || actions.contains(.startToggle) || actions.contains(.startThenStopAndProcess) {
                measured = PerfTrace(originNanoseconds: timing.downAt)
                measured?.mark(.hotkeyDown, atNanoseconds: timing.downAt)
            }
            if let trace = current?.perf {
                if let up = timing.upAt { trace.mark(.hotkeyUp, atNanoseconds: up) }
                if let stop = timing.stopAt { trace.mark(.stop, atNanoseconds: stop) }
            }
        }
        for action in actions {
            guard inputGeneration == input, isValid() else { return }
            await consume(action, perf: measured, isValid: isValid)
        }
    }
    public func consume(_ action: HotkeyAction) async { await consume(action, perf: nil, isValid: { true }) }
    private func consume(_ action: HotkeyAction, perf: PerfTrace?, isValid: @escaping @Sendable () -> Bool) async {
        switch action {
        case .stopAndProcess, .maximumDurationReached, .cancelRecording, .resetInputTap: inputGeneration &+= 1
        default: break
        }
        // A P2 batch is delivered action-by-action.  Once a terminal cleanup
        // owns the coordinator, suppress every start/pre-roll presentation
        // action as well as its cleanup partner; otherwise a late
        // `showListening` or `disarmPreRoll` could visibly corrupt teardown.
        if tearingDown || pendingRecoveryCount > 0 {
            switch action {
            case .armPreRoll, .disarmPreRoll, .discardPreRoll, .showListening,
                 .startPushToTalk, .startToggle, .startThenStopAndProcess,
                 .stopAndProcess, .maximumDurationReached, .cancelRecording, .resetInputTap:
                return
            case .none: break
            }
        }
        switch action {
        case .armPreRoll:
            guard current == nil, prearmedSession == nil, !tearingDown, isValid() else { return }
            generation &+= 1; let armed = generation; prearmGeneration = armed
            let id = DictationSessionID(), trace = perf ?? PerfTrace()
            prearmedSession = (id, trace)
            let audio = self.audio
            let task = Task {
                guard !Task.isCancelled, isValid() else { throw CancellationError() }
                try await PerfLog.$current.withValue(trace) { try await audio.armPreRoll(session: id) }
            }
            prearmTask = task
            stateValue = .prearming; await show(.prearming)
            do { try await task.value } catch {
                guard current == nil, prearmGeneration == armed else { return }
                await failPrearm(code: "audio_arm", generation: armed)
            }
        case .disarmPreRoll, .discardPreRoll:
            guard current == nil else { return }
            await discardPreRoll()
        // P2 emits this before every start action.  Showing it here gives the
        // user visible microphone intent before the audio adapter is called.
        case .showListening: await show(.listening)
        case .startPushToTalk: await start(mode: .pushToTalk, immediatelyStop: false, perf: perf, isValid: isValid)
        case .startToggle: await start(mode: .toggle, immediatelyStop: false, perf: perf, isValid: isValid)
        case .startThenStopAndProcess: await start(mode: .pushToTalk, immediatelyStop: true, perf: perf, isValid: isValid)
        case .stopAndProcess:
            if current == nil, prearmedSession != nil { await start(mode: .pushToTalk, immediatelyStop: true, perf: perf, isValid: isValid) }
            else { await stopAndProcess() }
        case .maximumDurationReached:
            if let session = current { await finishForAudioTerminal(session: session.id, reason: .maximumDuration) }
        case .resetInputTap: if current == nil { await discardPreRoll() } else { await interruptCurrent() }
        case .cancelRecording: await cancelCurrent()
        case .none: break
        }
    }

    /// The visible recording button needs only audio permission. Its result
    /// remains a local draft; this route never captures a cursor or inserts.
    public func startManualDictation() async {
        await start(mode: .toggle, immediatelyStop: false, manualDraftOnly: true)
    }

    private func start(mode: RecordingMode, immediatelyStop: Bool, manualDraftOnly: Bool = false, perf: PerfTrace? = nil, isValid: @escaping @Sendable () -> Bool = { true }) async {
        guard current == nil, !tearingDown, pendingRecoveryCount == 0, isValid() else { return }
        lastFailure = nil
        let armed = prearmedSession, warming = prearmTask
        prearmedSession = nil; prearmTask = nil; prearmGeneration = nil
        generation &+= 1
        let session = Session(id: armed?.id ?? .init(), generation: generation, mode: mode, manualDraftOnly: manualDraftOnly, perf: armed?.perf ?? perf ?? PerfTrace(), recordingStartedAt: nil, audio: nil)
        current = session
        session.perf.mark(.startRequested)
        if manualDraftOnly {
            await draft.beginDraft(session: session.id)
            guard isCurrent(session), !Task.isCancelled else { return }
        } else {
            let captured = await insertion.beginRecording(session: session.id)
            guard isCurrent(session), !Task.isCancelled, isValid() else {
                if isCurrent(session) { await cancelCurrent() }; return
            }
            guard captured else { await fail(code: "insertion_focus"); return }
            session.perf.mark(.focusCaptured)
        }
        stateValue = .listening; await show(.listening)
        session.perf.mark(.listeningPresented)
        guard isCurrent(session), !Task.isCancelled, isValid() else {
            if isCurrent(session) { await cancelCurrent() }; return
        }
        do {
            try await warming?.value
            guard isCurrent(session), !Task.isCancelled, isValid() else {
                if isCurrent(session) { await cancelCurrent() }; return
            }
            session.perf.mark(.audioStartRequested)
            let artifact = try await PerfLog.$current.withValue(session.perf) {
                try await audio.start(session: session.id, mode: mode)
            }
            guard isCurrent(session) else { await cleanupAbandoned(session); return }
            session.perf.mark(.recordingStarted)
            current?.recordingStartedAt = clock.nowNanoseconds()
            current?.audio = artifact
            if immediatelyStop || current?.pendingPCMCompletion == true { await stopAndProcess(completionReason: current?.completionReason) }
        } catch {
            guard isCurrent(session) else { return }
            let failure: DictationActionFailure
            switch error {
            case DictationError.unavailable("audio_device"): failure = .audioDevice
            case DictationError.unavailable("audio_preference"): failure = .audioPreference
            case ServiceContractError.unavailable("microphone"): failure = .microphone
            default: failure = .audioStart
            }
            await fail(code: "audio_start", failure: failure)
        }
    }
    private func stopAndProcess(completionReason: AudioCaptureCompletionReason? = nil) async {
        guard let session = current else { return }
        session.perf.mark(.stop)
        // Key-up before audio start completes invalidates the reserved start.
        guard session.recordingStartedAt != nil else { if !session.pendingPCMCompletion { await cancelCurrent() }; return }
        guard stateValue == .listening else { return }
        stateValue = .finalizing; await show(.finalizing)
        guard isCurrent(session), stateValue == .finalizing, !Task.isCancelled else { return }
        do {
            let result = try await PerfLog.$current.withValue(session.perf) { try await audio.stopResult(session: session.id) }
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            if let reason = result.completionReason {
                if reason == .interrupted || reason == .lockedCopied { current?.historyOnly = true; current?.insertionTask?.cancel() }
                let effectiveReason: AudioCaptureCompletionReason = current?.completionReason == .lockedCopied || reason == .lockedCopied ? .lockedCopied : current?.historyOnly == true ? .interrupted : reason
                current?.completionReason = effectiveReason
            }
            let artifact = result.url
            let stoppedAt = clock.nowNanoseconds()
            guard isCurrent(session) else { await audio.cancelAndCleanup(session: session.id); return }
            guard let startedAt = current?.recordingStartedAt else { await fail(code: "duration_missing"); return }
            let durationMs = result.sampleCount > 0 ? Int64(result.sampleCount) * 1_000 / Int64(CanonicalPCM16.sampleRate) : Self.recordedMilliseconds(startedAt: startedAt, stoppedAt: stoppedAt)
            session.perf.mark(.audioFinalized, audioMilliseconds: UInt64(max(0, durationMs)))
            current?.audio = artifact
            await pipeline(session, artifact: artifact, durationMs: durationMs, completionReason: completionReason)
        } catch {
            guard isCurrent(session) else { await audio.cancelAndCleanup(session: session.id); return }
            await fail(code: "audio_stop")
        }
    }
    private func pipeline(_ session: Session, artifact: URL, durationMs: Int64, completionReason: AudioCaptureCompletionReason? = nil) async {
        stateValue = .transcribing; await show(.transcribing)
        let prefs = await settings.current()
        guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
        do {
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            session.perf.mark(.asrRequested)
            let transcript: String
            do {
                transcript = try await PerfLog.$current.withValue(session.perf) {
                    try await helper.transcribe(audio: artifact, session: session.id, language: prefs.language)
                }
            } catch { session.perf.mark(.asrFinished); throw error }
            session.perf.mark(.asrFinished)
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            stateValue = .transforming; await show(.transforming)
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            let text = try await dictionary.transform(transcript)
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            if current?.historyOnly != true { await draft.publishDraft(text, session: session.id) }
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            let splitCount = text.split(whereSeparator: { $0.isWhitespace }).count
            guard let wordCount = Int64(exactly: splitCount) else { await fail(code: "statistics_word_count"); return }
            stateValue = .persisting; await show(.persisting)
            do {
                try await statistics.record(wordCount: wordCount, recordedMilliseconds: durationMs)
            } catch {
                diagnostics.record(code: "statistics_write")
            }
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            var didSave = false
            if prefs.historyEnabled && prefs.retentionEnabled {
                try await history.save(session: session.id, text: text, durationMs: durationMs, status: (session.manualDraftOnly || current?.historyOnly == true) ? .notAttempted : .failed); didSave = true
            }
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            stateValue = .inserting; await show(.inserting)
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            // A per-session task propagates revocation to the mutation's
            // Task.isCancelled checks without cancelling transcription/recovery.
            let insertionTask = Task { [insertion] in
                (session.manualDraftOnly || self.current?.historyOnly == true) ? AppInsertionOutcome.notAttempted : await insertion.insertAfterFocusRevalidation(text)
            }
            current?.insertionTask = insertionTask
            session.perf.mark(.insertionStarted)
            let outcome = await insertionTask.value
            session.perf.finishInsertion(path: outcome == .notAttempted ? .draft : outcome == .copiedForRecovery ? .recovery : .unknown)
            guard isCurrent(session) else { await audio.cancelAndCleanup(session: session.id); return }
            if didSave { guard !Task.isCancelled else { await cleanupAbandoned(session); return }; try await history.updateInsertion(session: session.id, status: outcome) }
            guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            var notice = current?.completionReason ?? completionReason
            if current?.historyOnly == true {
                // Re-read policy after a late interruption/insertion await.
                let latest = await settings.current()
                guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
                if latest.historyEnabled && latest.retentionEnabled {
                    if !didSave {
                        try await history.save(session: session.id, text: text, durationMs: durationMs, status: .notAttempted)
                        guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
                        didSave = true
                    }
                } else {
                    await draft.publishDraft(text, session: session.id)
                    guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
                }
                // Safety interruptions always copy, including when history is enabled.
                let recoveryTask = Task { [interruptionCopy] in await interruptionCopy.copy(text, session: session.id) }
                current?.recoveryTask = recoveryTask
                let copied = await recoveryTask.value
                guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
                guard copied else { await fail(code: "interrupted_copy"); return }
                notice = current?.completionReason == .lockedCopied ? .lockedCopied : .interruptedCopied
            }
            if let reason = notice {
                await ui.showAudioCompletion(reason, metadata: .init(sessionID: session.id, generation: session.generation))
                guard isCurrent(session), !Task.isCancelled else { await cleanupAbandoned(session); return }
            }
            // Keep normal completion reserved through UI and lease cleanup.
            // A new take must not overlap the previous session's teardown.
            tearingDown = true
            stateValue = session.manualDraftOnly || current?.historyOnly == true || outcome == .inserted ? .idle : .recovery
            await show(stateValue)
            guard isCurrent(session) else { return }
            await insertion.clearRecording(session: session.id)
            guard isCurrent(session) else { return }
            await audio.cancelAndCleanup(session: session.id)
            guard isCurrent(session) else { return }
            hotkeyNeutralizer?(session.id)
            await hotkeyCompletion?.completeProcessing()
            guard isCurrent(session) else { return }
            current = nil
            if stateValue == .recovery { stateValue = .idle; await show(.idle) }
            guard generation == session.generation, current == nil else { return }
            finishTeardown()
        } catch is CancellationError { guard isCurrent(session) else { await cleanupAbandoned(session); return }; await cancelCurrent() }
        catch let error as LocalTranscriptionFailure where error == .outcomeUnknown {
            guard isCurrent(session) else { await cleanupAbandoned(session); return }
            diagnostics.record(code: "helper_outcome_unknown"); await fail(code: "helper_outcome_unknown")
        } catch {
            guard isCurrent(session) else { await cleanupAbandoned(session); return }
            await fail(code: "pipeline")
        }
    }
    private func cancelCurrent() async {
        guard !tearingDown else { return }
        guard let active = current else { await discardPreRoll(); return }
        active.insertionTask?.cancel(); active.recoveryTask?.cancel()
        current = nil; generation &+= 1; stateValue = .idle; tearingDown = true
        await audio.stopCapture(session: active.id); await cleanupAfterReap(session: active.id); await insertion.clearRecording(session: active.id); await show(.idle); await hotkeyCompletion?.completeProcessing(); finishTeardown()
    }
    private func cleanupAbandoned(_ session: Session) async {
        if isCurrent(session) { await cancelCurrent() }
        else { await audio.stopCapture(session: session.id); await cleanupAfterReap(session: session.id); await insertion.clearRecording(session: session.id) }
    }
    private func fail(code: String, failure: DictationActionFailure? = nil) async {
        guard let session = current, !tearingDown else { return }
        // Invalidate before any await: no start/prearm can share teardown.
        current = nil; generation &+= 1; tearingDown = true; stateValue = .failed
        lastFailure = failure ?? (code == "audio_stop" ? .audioStop : code == "helper_outcome_unknown" ? .readerUnknown : .transcription)
        diagnostics.record(code: code)
        await audio.stopCapture(session: session.id); await cleanupAfterReap(session: session.id); await insertion.clearRecording(session: session.id)
        await show(.failed); stateValue = .idle; await show(.idle); await hotkeyCompletion?.completeProcessing(); finishTeardown()
    }
    private func discardPreRoll(publish: Bool = true) async {
        guard let armed = prearmedSession else { return }
        prearmedSession = nil; prearmGeneration = nil
        prearmTask?.cancel(); prearmTask = nil; generation &+= 1
        await audio.disarmPreRoll(session: armed.id)
        if current == nil, prearmedSession == nil { stateValue = .idle; if publish { await show(.idle) } }
    }
    private func failPrearm(code: String, generation armed: UInt64) async {
        guard current == nil, prearmGeneration == armed, !tearingDown else { return }
        diagnostics.record(code: code)
        await discardPreRoll()
    }
    /// `cleanup` owns physical artifact deletion.  Do not call it if the
    /// helper reports an unknown reap: the old reader may still own the WAV.
    /// A later stale/error path rechecks the same session and can release only
    /// after an explicit future recovery path; it cannot bypass this gate.
    private func cleanupAfterReap(session: DictationSessionID) async {
        guard !cleanupBlockedByUnknownReap.contains(session) else { return }
        let outcome = await helper.cancelAndReapOutcome(session: session)
        guard outcome != .outcomeUnknown else {
            cleanupBlockedByUnknownReap.insert(session)
            return
        }
        cleanupBlockedByUnknownReap.remove(session)
        await audio.cancelAndCleanup(session: session)
    }
    private func isCurrent(_ session: Session) -> Bool { current?.id == session.id && current?.generation == session.generation }
    private static func recordedMilliseconds(startedAt: UInt64, stoppedAt: UInt64) -> Int64 {
        guard stoppedAt >= startedAt else { return 0 }
        let milliseconds = (stoppedAt - startedAt) / 1_000_000
        return Int64(min(milliseconds, UInt64(86_400_000)))
    }
}
