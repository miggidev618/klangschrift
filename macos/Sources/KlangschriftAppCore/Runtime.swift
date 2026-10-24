import Foundation
import Darwin
import KlangschriftCore
import KlangschriftTranscription
import KlangschriftPersistence

public enum RuntimeReadiness: Sendable, Equatable { case unprepared, preparing, ready, unavailable(code: String), shuttingDown, stopped }
public protocol ModelReadinessProviding: Sendable { func status() async -> RuntimeReadiness; func prepareIfNeeded() async -> RuntimeReadiness; func shutdown() async -> HelperTerminationOutcome }
public enum RuntimeTranscriptionFailure: Error, Sendable, Equatable { case unavailable(String), outcomeUnknown, silence }
public protocol RuntimeDiagnosticsRecording: Sendable { func record(code: String) }
public struct NoopRuntimeDiagnostics: RuntimeDiagnosticsRecording { public init() {} ; public func record(code: String) {} }
/// Test-only observation point immediately after a transcription session has
/// been admitted to the actor.  It carries an opaque session identifier only;
/// it never observes audio paths, text, or helper payloads.
@_spi(KlangschriftTesting) public protocol RuntimeTranscriptionAdmissionObserving: Sendable {
    func didRegisterTranscription(session: DictationSessionID) async
}

private enum RuntimeCode { static let invalidConfiguration = "runtime_invalid_configuration"; static let helperUnavailable = "runtime_helper_unavailable"; static let outcomeUnknown = "runtime_outcome_unknown"; static let artifactRejected = "runtime_artifact_rejected"; static let stopped = "runtime_stopped" }

/// Closed settings projection for the P4 helper protocol. Device selection is
/// deliberately absent: it belongs solely to the P3 audio service.
public enum RuntimeSettingsMapping {
    public static func helperLanguage(_ language: SettingsLanguage) throws -> String? {
        switch language {
        case .automatic: return nil
        case .de: return "de"
        case .en: return "en"
        case .fr: return "fr"
        case .es: return "es"
        case .it: return "it"
        case .pt: return "pt"
        case .nl: return "nl"
        }
    }
    public static func validate(model: LocalModelProfile) throws {
        try validate(modelIdentifier: model.rawValue)
    }
    fileprivate static func validate(modelIdentifier: String) throws {
        guard LocalModelProfile(rawValue: modelIdentifier) != nil else { throw ServiceContractError.invalidConfiguration("runtime_unsupported_model") }
    }
}
public struct RuntimeSettingsProjection: Sendable, Equatable {
    public let model: LocalModelProfile; public let language: SettingsLanguage
    private let modelIdentifier: String
    public init(model: LocalModelProfile = .whisperLargeV3, language: SettingsLanguage = .automatic) { self.model=model; self.language=language; self.modelIdentifier=model.rawValue }
    @_spi(KlangschriftTesting) public static func unsupportedModelForTesting(language: SettingsLanguage = .automatic) -> Self { Self(model: .whisperLargeV3, language: language, modelIdentifier: "unsupported-test-model") }
    private init(model: LocalModelProfile, language: SettingsLanguage, modelIdentifier: String) { self.model=model; self.language=language; self.modelIdentifier=modelIdentifier }
    public func validate() throws { try RuntimeSettingsMapping.validate(modelIdentifier: modelIdentifier); _ = try RuntimeSettingsMapping.helperLanguage(language) }
}

/// One-helper readiness owner. Initialisation is cold: a Process can be started
/// only by an explicit health/prepare request.
public actor ModelReadinessService: ModelReadinessProviding {
    /// A helper client is deliberately a *generation*, not a permanent
    /// process handle.  P4 correctly poisons a client after cancellation; an
    /// interactive runtime must therefore retire a confirmed-reaped generation
    /// before it can construct another one.
    private var client: HelperProcessClient?
    private let clientFactory: (@Sendable () throws -> HelperProcessClient)?
    private let diagnostics: any RuntimeDiagnosticsRecording
    private var value: RuntimeReadiness = .unprepared
    private var preparation: Task<RuntimeReadiness, Never>?
    private var shutdownTask: Task<HelperTerminationOutcome, Never>?
    private var terminalOutcome: HelperTerminationOutcome?
    private var generation: UInt64 = 0
    private var recoveryTask: Task<HelperTerminationOutcome, Never>?
    public init(client: HelperProcessClient, clientFactory: (@Sendable () throws -> HelperProcessClient)? = nil, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics()) {
        self.client = client; self.clientFactory = clientFactory; self.diagnostics = diagnostics
    }
    /// Factory-created runtimes remain genuinely cold: not even a client
    /// generation is constructed before prepare/transcribe asks for one.
    public init(clientFactory: @escaping @Sendable () throws -> HelperProcessClient, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics()) {
        self.client = nil; self.clientFactory = clientFactory; self.diagnostics = diagnostics
    }
    public func status() -> RuntimeReadiness { value }
    public func prepareIfNeeded() async -> RuntimeReadiness {
        switch value {
        case .ready: PerfLog.current?.mark(.modelReady, coldLoad: false, durationMilliseconds: 0); return value
        case .stopped, .shuttingDown: return value
        case .preparing:
            if let preparation {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = await preparation.value
                if result == .ready { PerfLog.current?.mark(.modelReady, coldLoad: true, durationMilliseconds: (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) }
                return result
            }
            value = .unavailable(code: RuntimeCode.helperUnavailable); return value
        case .unavailable:
            return value
        case .unprepared:
            guard let client = makeClientIfNeeded() else { return value }
            value = .preparing
            let expectedGeneration = generation
            let task = Task { [client, diagnostics] in
                do {
                    switch try await client.request(id: Self.requestID(), operation: .health) {
                    // `prepared` is the strong helper contract: the pinned
                    // local model is already materialized, not merely imported.
                    case .prepared: return RuntimeReadiness.ready
                    case .configured:
                        // The legacy wire status remains compatible, but the
                        // helper now returns it from prepare only after its
                        // pinned ModelHolder has evaluated local parameters.
                        return try await client.request(id: Self.requestID(), operation: .prepare) == .prepared ? .ready : .unavailable(code: RuntimeCode.helperUnavailable)
                    default: return .unavailable(code: RuntimeCode.helperUnavailable)
                    }
                } catch let failure as HelperClientFailure {
                    if case .operationAndTermination(_, .outcomeUnknown) = failure { diagnostics.record(code: RuntimeCode.outcomeUnknown); return .unavailable(code: RuntimeCode.outcomeUnknown) }
                    return .unavailable(code: RuntimeCode.helperUnavailable)
                } catch { return .unavailable(code: RuntimeCode.helperUnavailable) }
            }
            let perfStart = DispatchTime.now().uptimeNanoseconds
            preparation = task; let result = await task.value
            if result == .ready { PerfLog.current?.mark(.modelReady, coldLoad: true, durationMilliseconds: (DispatchTime.now().uptimeNanoseconds - perfStart) / 1_000_000) }
            // A stale callback must never make a successor generation ready.
            guard expectedGeneration == generation else { return value }
            if case .shuttingDown = value { return value }; if case .stopped = value { return value }
            preparation = nil; value = result
            if case .unavailable = result {
                let usable = await client.canStartFresh()
                guard expectedGeneration == generation else { return value }
                if !usable { _ = await cancelActiveGeneration() }
            }
            if case .unavailable = result { diagnostics.record(code: RuntimeCode.helperUnavailable) }
            return result
        }
    }
    /// This is explicit user-initiated recovery, not an automatic retry loop.
    public func retryOnce() async -> RuntimeReadiness { guard case .unavailable = value else { return await prepareIfNeeded() }; value = .unprepared; return await prepareIfNeeded() }
    public func shutdown() async -> HelperTerminationOutcome {
        if let shutdownTask { return await shutdownTask.value }
        if let terminalOutcome { return terminalOutcome }
        if case .stopped = value { return .none }
        // A session cancellation already owns the only reaper.  Terminal
        // shutdown joins it rather than starting a second reap.
        if let recoveryTask {
            let result = await recoveryTask.value
            value = .stopped
            terminalOutcome = result
            return result
        }
        value = .shuttingDown
        let client = self.client
        let task: Task<HelperTerminationOutcome, Never> = Task { [diagnostics] in
            guard let client else { return HelperTerminationOutcome.none }
            let result = await client.cancelOrTimeout()
            if result == .outcomeUnknown { diagnostics.record(code: RuntimeCode.outcomeUnknown) }
            return result
        }
        shutdownTask = task; let result = await task.value; value = .stopped; terminalOutcome = result; return result
    }
    /// Retires only the currently active generation.  A confirmed reap makes
    /// the runtime cold again; the next explicit prepare/transcribe may create
    /// one successor.  An unknown reap is fail-closed because the old helper
    /// might still be alive.
    fileprivate func cancelActiveGeneration() async -> HelperTerminationOutcome {
        if let shutdownTask { return await shutdownTask.value }
        if let terminalOutcome { return terminalOutcome }
        if let recoveryTask { return await recoveryTask.value }
        if case .stopped = value { return .none }
        let expectedGeneration = generation
        value = .shuttingDown
        let oldClient = client
        let task: Task<HelperTerminationOutcome, Never> = Task { [diagnostics] in
            guard let oldClient else { return HelperTerminationOutcome.none }
            let result = await oldClient.cancelOrTimeout()
            if result == .outcomeUnknown { diagnostics.record(code: RuntimeCode.outcomeUnknown) }
            return result
        }
        recoveryTask = task
        let outcome = await task.value
        guard expectedGeneration == generation else { return outcome }
        recoveryTask = nil
        preparation = nil
        switch outcome {
        case .outcomeUnknown:
            value = .unavailable(code: RuntimeCode.outcomeUnknown)
        default:
            // No overlap: replacement is impossible until this awaited
            // reap has completed and the old client is discarded.
            client = nil
            generation &+= 1
            value = .unprepared
        }
        return outcome
    }
    fileprivate func requestTranscription(id: String, audioPath: String, language: String?) async throws -> HelperStatus {
        try await requirePrepared()
        guard case .ready = value, let client else { throw HelperProtocolError.outcomeUnknown }
        let expectedGeneration = generation
        let response: HelperStatus
        do { response = try await client.request(id: id, operation: .transcribe, audioPath: audioPath, language: language) }
        catch let failure as HelperClientFailure {
            if expectedGeneration == generation { _ = await cancelActiveGeneration() }
            throw failure
        }
        guard expectedGeneration == generation, case .ready = value else { throw HelperProtocolError.outcomeUnknown }
        return response
    }
    fileprivate func requirePrepared() async throws {
        let result = await prepareIfNeeded()
        guard result == .ready else { if case .unavailable(let code) = result { throw RuntimeTranscriptionFailure.unavailable(code) }; throw RuntimeTranscriptionFailure.unavailable(RuntimeCode.stopped) }
    }
    private func makeClientIfNeeded() -> HelperProcessClient? {
        if let client { return client }
        guard let clientFactory else { value = .unavailable(code: RuntimeCode.helperUnavailable); return nil }
        do {
            let client = try clientFactory()
            self.client = client
            return client
        } catch {
            value = .unavailable(code: RuntimeCode.helperUnavailable)
            diagnostics.record(code: RuntimeCode.helperUnavailable)
            return nil
        }
    }
    private static func requestID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
}

/// AppCore never deletes temporary files. P3 owns artifact creation, cleanup
/// and recovery; this adapter only validates the supplied local WAV path.
public actor RuntimeLocalTranscriber: LocalTranscribing {
    private let readiness: ModelReadinessService; private let audioRoot: URL; private let diagnostics: any RuntimeDiagnosticsRecording
    private let admissionObserver: (any RuntimeTranscriptionAdmissionObserving)?
    private var activeSession: DictationSessionID?; private var pendingSessions: [DictationSessionID: UUID] = [:]; private var reapOutcomes: [DictationSessionID: HelperTerminationOutcome] = [:]; private var revokedBeforeAdmission: Set<DictationSessionID> = []; private var revocationOrder: [DictationSessionID] = []; private var stopped = false; private var transcribing = false; private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []
    private static let revocationCapacity = 128
    public init(client: HelperProcessClient, readiness: ModelReadinessService, audioRoot: URL, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics()) { self.init(readiness: readiness, audioRoot: audioRoot, diagnostics: diagnostics, admissionObserver: nil) }
    public init(readiness: ModelReadinessService, audioRoot: URL, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics()) { self.init(readiness: readiness, audioRoot: audioRoot, diagnostics: diagnostics, admissionObserver: nil) }
    @_spi(KlangschriftTesting) public init(client: HelperProcessClient, readiness: ModelReadinessService, audioRoot: URL, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics(), testingAdmissionObserver: any RuntimeTranscriptionAdmissionObserving) { self.init(readiness: readiness, audioRoot: audioRoot, diagnostics: diagnostics, admissionObserver: testingAdmissionObserver) }
    @_spi(KlangschriftTesting) public init(readiness: ModelReadinessService, audioRoot: URL, diagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics(), testingAdmissionObserver: any RuntimeTranscriptionAdmissionObserving) { self.init(readiness: readiness, audioRoot: audioRoot, diagnostics: diagnostics, admissionObserver: testingAdmissionObserver) }
    private init(readiness: ModelReadinessService, audioRoot: URL, diagnostics: any RuntimeDiagnosticsRecording, admissionObserver: (any RuntimeTranscriptionAdmissionObserving)?) { self.readiness = readiness; self.audioRoot = audioRoot.standardizedFileURL; self.diagnostics = diagnostics; self.admissionObserver = admissionObserver }
    public func transcribe(audio: URL, session: DictationSessionID, language: String?) async throws -> String {
        guard !stopped else { throw LocalTranscriptionFailure.outcomeUnknown }
        guard isOwnedAudioPath(audio), isSupportedLanguage(language) else { diagnostics.record(code: RuntimeCode.artifactRejected); throw RuntimeTranscriptionFailure.unavailable(RuntimeCode.artifactRejected) }
        // Cancellation can arrive before this async call gets an actor turn.
        // Consume its bounded tombstone before installing any pending work so
        // that an old cancel can never reap an unrelated active generation.
        guard revokedBeforeAdmission.remove(session) == nil else {
            // Keep the FIFO and set in lockstep so a later UUID reuse cannot
            // let eviction erase a newer tombstone.
            revocationOrder.removeAll { $0 == session }
            throw LocalTranscriptionFailure.outcomeUnknown
        }
        let token = UUID(); pendingSessions[session] = token
        defer { if pendingSessions[session] == token { pendingSessions[session] = nil } }
        await admissionObserver?.didRegisterTranscription(session: session)
        PerfLog.current?.selectModel(catalogID: nil)
        do { try await readiness.requirePrepared() }
        catch {
            if case RuntimeTranscriptionFailure.unavailable(RuntimeCode.outcomeUnknown) = error { reapOutcomes[session] = .outcomeUnknown }
            // Prepare receives no WAV path; a confirmed failure has no audio reader.
            throw error
        }
        guard isLive(session, token) else { throw LocalTranscriptionFailure.outcomeUnknown }
        await acquireTranscription(); defer { releaseTranscription() }
        guard isLive(session, token) else { throw LocalTranscriptionFailure.outcomeUnknown }
        activeSession = session; defer { if activeSession == session { activeSession = nil } }
        do {
            switch try await readiness.requestTranscription(id: session.rawValue.uuidString.replacingOccurrences(of: "-", with: ""), audioPath: audio.standardizedFileURL.path, language: helperLanguage(language)) {
            case .ok(let text) where !(text ?? "").isEmpty: return text!
            case .silence: throw RuntimeTranscriptionFailure.silence
            default: throw LocalTranscriptionFailure.failed
            }
        } catch let failure as HelperClientFailure {
            if case .operationAndTermination(_, .outcomeUnknown) = failure { reapOutcomes[session] = .outcomeUnknown; diagnostics.record(code: RuntimeCode.outcomeUnknown); throw LocalTranscriptionFailure.outcomeUnknown }
            if case .operationAndTermination(_, let termination) = failure { reapOutcomes[session] = termination }
            throw LocalTranscriptionFailure.failed
        } catch let failure as HelperProtocolError where failure == .outcomeUnknown { reapOutcomes[session] = .outcomeUnknown; diagnostics.record(code: RuntimeCode.outcomeUnknown); throw LocalTranscriptionFailure.outcomeUnknown }
        catch { throw LocalTranscriptionFailure.failed }
    }
    public func cancelAndReap() async { _ = await stopIfNeeded() }
    public func cancelAndReap(session: DictationSessionID) async { _ = await cancelAndReapOutcome(session: session) }
    public func cancelAndReapOutcome(session: DictationSessionID) async -> HelperTerminationOutcome {
        if let known = reapOutcomes[session] { return known }
        guard pendingSessions[session] != nil || activeSession == session else {
            // Unknown session cancellation is deliberately a local revocation,
            // never a request to reap the process currently serving another
            // session. UUID session IDs make a bounded FIFO sufficient here.
            if !stopped { recordPreAdmissionRevocation(session) }
            return .none
        }
        // A queued session owns no helper request yet. Revoking only its token
        // leaves the active/replacement session and its one shared helper live.
        guard activeSession == session || activeSession == nil && !transcribing else { pendingSessions[session] = nil; return .none }
        pendingSessions[session] = nil; activeSession = nil
        // Session cancellation is recoverable.  It only retires the current
        // generation once P4 confirms reaping; terminal shutdown remains a
        // separate, permanent operation.
        let outcome = await readiness.cancelActiveGeneration()
        reapOutcomes[session] = outcome
        return outcome
    }
    public func shutdown() async -> HelperTerminationOutcome { await stopIfNeeded() }
    private func stopIfNeeded() async -> HelperTerminationOutcome { stopped = true; activeSession = nil; pendingSessions.removeAll(); reapOutcomes.removeAll(); revokedBeforeAdmission.removeAll(); revocationOrder.removeAll(); return await readiness.shutdown() }
    private func recordPreAdmissionRevocation(_ session: DictationSessionID) {
        guard revokedBeforeAdmission.insert(session).inserted else { return }
        revocationOrder.append(session)
        if revocationOrder.count > Self.revocationCapacity {
            let evicted = revocationOrder.removeFirst()
            revokedBeforeAdmission.remove(evicted)
        }
    }
    private func isLive(_ session: DictationSessionID, _ token: UUID) -> Bool { !stopped && pendingSessions[session] == token }
    private static let supportedLanguageCodes: Set<String> = ["de", "en", "fr", "es", "it", "pt", "nl"]
    private func helperLanguage(_ value: String?) -> String? { value == "auto" ? nil : value }
    private func isSupportedLanguage(_ value: String?) -> Bool { value == nil || value == "auto" || Self.supportedLanguageCodes.contains(value!) }
    private func acquireTranscription() async { if !transcribing { transcribing = true; return }; await withCheckedContinuation { transcriptionWaiters.append($0) } }
    private func releaseTranscription() { if transcriptionWaiters.isEmpty { transcribing = false } else { transcriptionWaiters.removeFirst().resume() } }
    private func isOwnedAudioPath(_ url: URL) -> Bool {
        let file = url.standardizedFileURL, root = audioRoot.path.hasSuffix("/") ? audioRoot.path : audioRoot.path + "/"
        guard file.isFileURL, file.path.hasPrefix(root), file.path.hasSuffix(".wav"), file.resolvingSymlinksInPath() == file else { return false }
        var rootInfo = stat(), fileInfo = stat()
        return lstat(audioRoot.path, &rootInfo) == 0 && lstat(file.path, &fileInfo) == 0 && (rootInfo.st_mode & S_IFMT) == S_IFDIR && (fileInfo.st_mode & S_IFMT) == S_IFREG && rootInfo.st_uid == getuid() && fileInfo.st_uid == getuid() && (rootInfo.st_mode & 0o077) == 0 && (fileInfo.st_mode & 0o077) == 0
    }
}

public struct AppRuntime: Sendable {
    public let coordinator: DictationCoordinator; public let readiness: ModelReadinessService; private let transcriber: RuntimeLocalTranscriber; private let dictationTranscriber: any LocalTranscribing
    public init(coordinator: DictationCoordinator, readiness: ModelReadinessService, transcriber: RuntimeLocalTranscriber, dictationTranscriber: (any LocalTranscribing)? = nil) { self.coordinator = coordinator; self.readiness = readiness; self.transcriber = transcriber; self.dictationTranscriber = dictationTranscriber ?? transcriber }
    public func shutdown() async -> HelperTerminationOutcome { await transcriber.shutdown() }
    /// Narrow same-runtime handoff for an ephemeral onboarding test. It does
    /// not expose any persistence, dictionary, insertion, or process factory.
    public func sameRuntimeTranscriber() -> any LocalTranscribing { dictationTranscriber }
    @_spi(KlangschriftTesting) public func retireHelperGenerationForTesting() async -> HelperTerminationOutcome { await readiness.cancelActiveGeneration() }
}

/// Narrow pre-foundation owner for explicit onboarding tests. It contains only
/// helper readiness/transcription; persistence, dictionary and insertion are
/// intentionally absent from its API and construction.
public actor OwnedEphemeralRuntime: LocalTranscribing {
    private let readiness: ModelReadinessService; private let transcriber: RuntimeLocalTranscriber
    public init(readiness: ModelReadinessService, transcriber: RuntimeLocalTranscriber) { self.readiness = readiness; self.transcriber = transcriber }
    public func transcribe(audio: URL, session: DictationSessionID, language: String?) async throws -> String { try await transcriber.transcribe(audio: audio, session: session, language: language) }
    public func cancelAndReap() async { await transcriber.cancelAndReap() }
    public func cancelAndReap(session: DictationSessionID) async { await transcriber.cancelAndReap(session: session) }
    public func cancelAndReapOutcome(session: DictationSessionID) async -> HelperTerminationOutcome { await transcriber.cancelAndReapOutcome(session: session) }
    public func shutdown() async -> HelperTerminationOutcome { await transcriber.shutdown() }
}

public struct AppRuntimeDependencies: Sendable {
    public let decorateTranscriber: (@Sendable (any LocalTranscribing) -> any LocalTranscribing)?
    public let launch: HelperLaunchConfiguration; public let projection: RuntimeSettingsProjection; public let audio: any DictationAudio; public let dictionary: any DictionaryTransforming; public let history: any DictationHistory; public let statistics: any DictationStatistics; public let settings: any DictationSettings; public let insertion: any CurrentCursorInserting; public let draft: any DictationDraftPresenting; public let ui: any DictationUIState; public let diagnostics: any DictationDiagnostics; public let clock: any DictationMonotonicClock; public let runtimeDiagnostics: any RuntimeDiagnosticsRecording
    public init(launch: HelperLaunchConfiguration, projection: RuntimeSettingsProjection = .init(), audio: any DictationAudio, dictionary: any DictionaryTransforming, history: any DictationHistory, statistics: any DictationStatistics, settings: any DictationSettings, insertion: any CurrentCursorInserting, draft: any DictationDraftPresenting = NoopDictationDraftPresenter(), ui: any DictationUIState, diagnostics: any DictationDiagnostics, clock: any DictationMonotonicClock, runtimeDiagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics(), decorateTranscriber: (@Sendable (any LocalTranscribing) -> any LocalTranscribing)? = nil) { self.decorateTranscriber = decorateTranscriber; self.launch = launch; self.projection=projection; self.audio = audio; self.dictionary = dictionary; self.history = history; self.statistics = statistics; self.settings = settings; self.insertion = insertion; self.draft = draft; self.ui = ui; self.diagnostics = diagnostics; self.clock = clock; self.runtimeDiagnostics = runtimeDiagnostics }
}

public enum AppRuntimeFactory {
    /// Same launch identity checks and lazy client-generation rules as the
    /// full runtime, without constructing coordinator/persistence adapters.
    public static func makeEphemeral(launch: HelperLaunchConfiguration, runtimeDiagnostics: any RuntimeDiagnosticsRecording = NoopRuntimeDiagnostics()) throws -> OwnedEphemeralRuntime {
        guard launch.passesHelperPath, launch.extraArguments.isEmpty, isProductionConfiguration(launch), boundIdentity(of: launch) != nil else { throw ServiceContractError.invalidConfiguration(RuntimeCode.invalidConfiguration) }
        let identity = boundIdentity(of: launch)!
        let factory: @Sendable () throws -> HelperProcessClient = {
            guard isProductionConfiguration(launch), boundIdentity(of: launch) == identity else { throw ServiceContractError.invalidConfiguration(RuntimeCode.invalidConfiguration) }
            return HelperProcessClient(transport: ProcessHelperTransport(config: launch))
        }
        let readiness = ModelReadinessService(clientFactory: factory, diagnostics: runtimeDiagnostics)
        return OwnedEphemeralRuntime(readiness: readiness, transcriber: RuntimeLocalTranscriber(readiness: readiness, audioRoot: launch.audioRoot, diagnostics: runtimeDiagnostics))
    }
    /// Synchronous and cold: no helper Process is started by this method.
    public static func make(_ dependencies: AppRuntimeDependencies) throws -> AppRuntime { try make(dependencies, clientFactory: { HelperProcessClient(transport: ProcessHelperTransport(config: $0)) }) }
    /// Test seam: construction remains cold and accepts the same production
    /// configuration checks as the real factory before a client is made.
    public static func make(_ dependencies: AppRuntimeDependencies, clientFactory: @escaping @Sendable (HelperLaunchConfiguration) throws -> HelperProcessClient) throws -> AppRuntime {
        let launch = dependencies.launch
        try dependencies.projection.validate()
        guard launch.passesHelperPath, launch.extraArguments.isEmpty, isProductionConfiguration(launch) else { throw ServiceContractError.invalidConfiguration(RuntimeCode.invalidConfiguration) }
        guard let identity = boundIdentity(of: launch) else { throw ServiceContractError.invalidConfiguration(RuntimeCode.invalidConfiguration) }
        // Validate immediately before every client construction.  The captured
        // identity prevents a same-looking path from being swapped between the
        // cold factory call and any later helper generation.
        let replacementFactory: @Sendable () throws -> HelperProcessClient = {
            guard isProductionConfiguration(launch), boundIdentity(of: launch) == identity else {
                throw ServiceContractError.invalidConfiguration(RuntimeCode.invalidConfiguration)
            }
            return try clientFactory(launch)
        }
        let readiness = ModelReadinessService(clientFactory: replacementFactory, diagnostics: dependencies.runtimeDiagnostics)
        let transcriber = RuntimeLocalTranscriber(readiness: readiness, audioRoot: launch.audioRoot, diagnostics: dependencies.runtimeDiagnostics)
        let dictationTranscriber = dependencies.decorateTranscriber?(transcriber) ?? transcriber
        let coordinator = DictationCoordinator(clock: dependencies.clock, audio: dependencies.audio, helper: dictationTranscriber, dictionary: dependencies.dictionary, history: dependencies.history, statistics: dependencies.statistics, settings: dependencies.settings, insertion: dependencies.insertion, draft: dependencies.draft, ui: dependencies.ui, diagnostics: dependencies.diagnostics)
        return AppRuntime(coordinator: coordinator, readiness: readiness, transcriber: transcriber, dictationTranscriber: dictationTranscriber)
    }
    private static func isProductionConfiguration(_ value: HelperLaunchConfiguration) -> Bool {
        func hash(_ string: String) -> Bool { string.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }
        func python(_ url: URL) -> Bool { var s = stat(); return url.isFileURL && url.path.hasPrefix("/") && url.resolvingSymlinksInPath() == url.standardizedFileURL && lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == getuid() && (s.st_mode & 0o022) == 0 && access(url.path, X_OK) == 0 }
        func helper(_ url: URL) -> Bool { var s = stat(); return url.isFileURL && url.path.hasPrefix("/") && url.resolvingSymlinksInPath() == url.standardizedFileURL && lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG && s.st_uid == getuid() && (s.st_mode & 0o022) == 0 && access(url.path, R_OK) == 0 }
        func secureDirectory(_ url: URL, exact0700: Bool) -> Bool { var s = stat(); return url.isFileURL && url.path.hasPrefix("/") && url.resolvingSymlinksInPath() == url.standardizedFileURL && lstat(url.path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR && s.st_uid == getuid() && (exact0700 ? (s.st_mode & 0o777) == 0o700 : (s.st_mode & 0o022) == 0) }
        return python(value.python) && helper(value.helper) && secureDirectory(value.model, exact0700:false) && secureDirectory(value.audioRoot, exact0700:true) && hash(value.configHash) && hash(value.weightsHash)
    }
    private struct BoundLaunchIdentity: Sendable, Equatable {
        let python: Node; let helper: Node; let model: Node; let audio: Node
        struct Node: Sendable, Equatable { let device: UInt64; let inode: UInt64; let mode: UInt16; let uid: UInt32 }
    }
    private static func boundIdentity(of value: HelperLaunchConfiguration) -> BoundLaunchIdentity? {
        func node(_ url: URL) -> BoundLaunchIdentity.Node? {
            var s = stat()
            guard lstat(url.path, &s) == 0 else { return nil }
            return .init(device: UInt64(s.st_dev), inode: UInt64(s.st_ino), mode: UInt16(s.st_mode & 0o7777), uid: UInt32(s.st_uid))
        }
        guard let python = node(value.python), let helper = node(value.helper), let model = node(value.model), let audio = node(value.audioRoot) else { return nil }
        return .init(python: python, helper: helper, model: model, audio: audio)
    }
}
