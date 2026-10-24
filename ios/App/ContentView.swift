import SwiftUI
import UIKit

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var text = ""
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isStarting = false
    @Published var isPreparingModel = false
    @Published var error: String?
    @Published var seconds = 0
    @Published var microphoneLevel = 0.0
    @Published private(set) var selectedModel: DictationModelID
    @Published private(set) var preparedModelID: DictationModelID? = nil
    @Published private(set) var preparedModels: Set<DictationModelID> = []
    @Published private(set) var installedModels: Set<DictationModelID> = []
    @Published private(set) var downloads: [DictationModelID: DictationModelInstallState] = [:]
    @Published var favorites = KeyboardModelFavorites()
    @Published var preparedFavorites: Set<DictationModelID> = []
    @Published var statsRevision = 0
    private let installer = DictationModelInstaller()
    private var downloadTask: Task<Void, Never>?
    @Published private(set) var history: [TranscriptEntry]
    @Published private(set) var spellings: [PersonalSpelling]

    private let recorder = AudioRecorder()
    private let completion = MainDictationCompletion()
    private var pendingInterruptedText: String?
    private var processingBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    let transcriber = LocalTranscriptionService()
    private var recordingModelID: DictationModelID?
    private var modelPin: UUID?
    private var automaticStop: Task<Void, Never>?
    private var progressPolling: Task<Void, Never>?
    private var startGeneration = 0
    private let startPolicy = MainDictationStartPolicy()
    private var startTask: Task<Void, Never>?
    private var awaitingMicrophonePermission = false
    var keyboardIsBusy: () -> Bool = { false }
    private lazy var preloader = ForegroundModelPreloader(service: transcriber,
        installed: { FileManager.default.fileExists(atPath: DictationModelStorage.directory(for: $0).appendingPathComponent("manifest.json").path) },
        quiet: { [weak self] in
            guard let self else { return false }
            return !self.isStarting && !self.isRecording && !self.isTranscribing && !self.isPreparingModel && !self.keyboardIsBusy()
        }, changed: { [weak self] in await self?.syncPreparedStatus() })
    private func configurePreloader() {
        preloader.configure(models: favorites.models.compactMap { DictationModelID(rawValue: $0.id) }, revision: favorites.revision, selected: selectedModel)
    }
    func preloadVisible() { configurePreloader(); preloader.surfaceVisible(foreground: UIApplication.shared.applicationState == .active) }
    func preloadQuietPhase() { preloader.quietPhase() }
    func preloadActive() {
        preloader.becameActive()
        if let pendingInterruptedText {
            UIPasteboard.general.string = pendingInterruptedText
            self.pendingInterruptedText = nil
        }
    }
    func preloadInactive() { preloader.inactive() }
    func preloadBackground() { preloader.background() }
    func preloadDemand(_ models: Set<DictationModelID>) -> () -> Void {
        let claim = preloader.demand(models)
        return { [weak self] in self?.preloader.release(claim) }
    }

    private var historyLoadError: String?
    private var spellingsLoadError: String?

    init() {
        let baseReady = DictationModelStorage.isInstalled(.whisperBaseCoreML)
        DictationModelSelection.migrateIfReady(whisperBaseInstalled: baseReady)
        DictationLanguage.migrateLegacyValue()
        selectedModel = DictationModelSelection.selected()
        favorites = (try? KeyboardModelFavoritesStore()?.read()) ?? KeyboardModelFavorites()
        do { history = try TranscriptPersistence.loadHistory() }
        catch { history = []; historyLoadError = error.localizedDescription }
        do { spellings = try TranscriptPersistence.loadSpellings() }
        catch { spellings = []; spellingsLoadError = error.localizedDescription }
        recorder.onInterruption = { [weak self] in self?.recordingInterrupted() }
    }

    var recordingLabel: String {
        if isPreparingModel { return L("Preparing model …", "Modell wird vorbereitet …") }
        if isStarting { return L("Preparing microphone …", "Mikrofon wird vorbereitet …") }
        if isRecording { return L("Recording", "Aufnahme läuft") }
        if isTranscribing { return L("Creating text …", "Text wird erstellt …") }
        return L("Ready to dictate", "Bereit für ein Diktat")
    }

    func toggle() {
        if isRecording { finish() } else { begin() }
    }

    func begin() {
        guard !isStarting, !isPreparingModel, !isRecording, !isTranscribing,
              let attempt = startPolicy.reserve(modelID: selectedModel,
                foreground: UIApplication.shared.applicationState == .active, keyboardBusy: keyboardIsBusy()) else { return }
        let releasePreload = preloadDemand([attempt.modelID])
        isStarting = true; error = nil; startGeneration += 1
        let generation = startGeneration
        recordingModelID = attempt.modelID
        startTask = Task { [weak self] in
            guard let self else { return }
            var recordingAccepted = false
            defer {
                releasePreload()
                if !recordingAccepted { Task { await transcriber.releasePin(attempt.token) } }
                startPolicy.finish(attempt)
                if generation == startGeneration {
                    startTask = nil; isStarting = false; isPreparingModel = false; awaitingMicrophonePermission = false
                    if !recordingAccepted { recordingModelID = nil; if modelPin == attempt.token { modelPin = nil } }
                }
            }
            let allowed = {
                generation == self.startGeneration && !Task.isCancelled &&
                UIApplication.shared.applicationState == .active && !self.keyboardIsBusy()
            }
            do {
                let ready = try await startPolicy.prepareAndPin(attempt, allowed: allowed,
                    prepared: { await self.transcriber.preparedModels() },
                    prepare: { model in
                        guard allowed() else { throw CancellationError() }
                        self.isPreparingModel = true
                        defer { if generation == self.startGeneration { self.isPreparingModel = false } }
                        try await self.transcriber.prepare(modelID: model, origin: .mainDictation)
                    }, pin: { model, token in try await self.transcriber.requirePrepared(modelID: model, pin: token) },
                    release: { await self.transcriber.releasePin($0) })
                guard ready, startPolicy.valid(attempt, allowed: allowed) else { return }
                preparedModels = await transcriber.preparedModels()
                guard startPolicy.valid(attempt, allowed: allowed) else { return }
                installedModels.insert(attempt.modelID)
                modelPin = attempt.token
                awaitingMicrophonePermission = true
                let permitted = await recorder.requestPermission()
                if generation == startGeneration { awaitingMicrophonePermission = false }
                guard startPolicy.valid(attempt, allowed: allowed) else { return }
                guard permitted else { throw AudioRecorderError.microphoneDenied }
                try recorder.start()
                recordingAccepted = true
                isRecording = true; seconds = 0; microphoneLevel = 0
                startProgressPolling()
                automaticStop = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(LocalTranscriber.maximumRecordingSeconds))
                    guard !Task.isCancelled, let self, self.isRecording else { return }
                    self.finish()
                }
            } catch {
                guard generation == startGeneration, !Task.isCancelled else { return }
                if error is CancellationError { return }
                let ns = error as NSError
                let missing: Bool
                if case LocalTranscriberError.modelMissing = error { missing = true } else { missing = false }
                if missing || (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError) {
                    self.error = L("Download this model in Manage models first.", "Das Modell ist lokal nicht verfügbar. Öffne Modelle verwalten und installiere es vollständig.")
                } else { self.error = error.localizedDescription }
                preparedModels = await transcriber.preparedModels()
            }
        }
    }

    func cancelPendingStart() {
        guard isStarting else { return }
        startGeneration += 1; startPolicy.invalidate(); startTask?.cancel(); startTask = nil
        isStarting = false; isPreparingModel = false; awaitingMicrophonePermission = false; recordingModelID = nil
        if let pin = modelPin { Task { await transcriber.releasePin(pin) }; modelPin = nil }
    }

    func foregroundWillResign() {
        // The system permission sheet may temporarily deactivate this foreground app.
        if isStarting && !awaitingMicrophonePermission { cancelPendingStart() }
        recordingInterrupted()
    }

    func syncPreparedStatus() async {
        let cached = await transcriber.preparedModels()
        preparedModels = cached; preparedFavorites = cached
    }

    func finish(interrupted: Bool = false) {
        guard isRecording else { return }
        stopTimers()
        do {
            guard let recording = try completion.begin(interrupted: interrupted, stop: { try recorder.stop() }) else { return }
            beginProcessingTime()
            isRecording = false
            microphoneLevel = 0
            isTranscribing = true
            let capturedModelID = recordingModelID ?? selectedModel
            let capturedPin = modelPin
            Task { [weak self] in
                defer {
                    try? FileManager.default.removeItem(at: recording)
                    if let capturedPin { Task { await self?.transcriber.releasePin(capturedPin) } }
                }
                guard let self else { return }
                do {
                    text = try await completion.complete(recording: recording, transcribe: { recording in
                        let literal = try await self.transcriber.transcribe(recording: recording, modelID: capturedModelID)
                        return LiteralWordReplacement.apply(literal, spellings: self.spellings)
                    }, save: { self.appendHistory($0) }, copy: { result in
                        if UIApplication.shared.applicationState == .active { UIPasteboard.general.string = result }
                        else { self.pendingInterruptedText = result }
                    })
                } catch {
                    self.error = error.localizedDescription
                }
                self.endProcessingTime()
                self.isTranscribing = false
                self.recordingModelID = nil
                if modelPin == capturedPin { modelPin = nil }
            }
        } catch {
            if let pin = modelPin { Task { await transcriber.releasePin(pin) }; modelPin = nil }
            isRecording = false
            microphoneLevel = 0
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        cancelPendingStart()
        startPolicy.invalidate()
        startGeneration += 1
        stopTimers()
        recorder.cancel()
        isRecording = false
        isStarting = false
        seconds = 0
        microphoneLevel = 0
        recordingModelID = nil
        if let pin = modelPin { Task { await transcriber.releasePin(pin) }; modelPin = nil }
    }

    func useHistory(_ entry: TranscriptEntry) { text = entry.text }

    func receiveKeyboardTranscript(_ result: String) {
        text = result
        appendHistory(result)
    }

    func openHistory() {
        if let historyLoadError { error = historyLoadError }
    }

    func openSettings() {
        refreshModels()
        if let spellingsLoadError { error = spellingsLoadError }
    }

    func refreshModels() {
        Task { [weak self] in
            let installed = await Task.detached { Set(DictationModelID.allCases.filter { DictationModelStorage.isInstalled($0) }) }.value
            guard let self else { return }
            installedModels = installed
            migrateModelPreferencesIfQuiet()
            statsRevision += 1
        }
    }

    var visibleModels: [DictationModelID] {
        DictationModelSelection.visibleModels(whisperBaseInstalled: installedModels.contains(.whisperBaseCoreML))
    }
    private func migrateModelPreferencesIfQuiet() {
        guard !isRecording, !isStarting, !isTranscribing, !isPreparingModel, !keyboardIsBusy() else { return }
        let baseReady = installedModels.contains(.whisperBaseCoreML)
        DictationModelSelection.migrateIfReady(whisperBaseInstalled: baseReady)
        do {
            let store = KeyboardModelFavoritesStore()
            try store?.migrateIfReady(whisperBaseInstalled: baseReady)
            favorites = try store?.read() ?? KeyboardModelFavorites()
        } catch { self.error = error.localizedDescription }
        selectedModel = DictationModelSelection.selected(isInstalled: { self.installedModels.contains($0) })
        configurePreloader()
    }

    func setFavorite(slot: Int, rawID: String) -> Bool {
        guard !isRecording, !isStarting, !isTranscribing, !isPreparingModel,
              let store = KeyboardModelFavoritesStore() else { return false }
        do {
            var next = try store.read()
            var favorite: KeyboardModelFavorite?
            if !rawID.isEmpty {
                guard let id = DictationModelID(rawValue: rawID), visibleModels.contains(id), installedModels.contains(id) else { return false }
                let descriptor = DictationModelDescriptor.descriptor(for: id)
                let language = ["English": "EN", "Deutsch": "DE", "Spanisch": "ES", "Arabisch": "AR", "Japanisch": "JA", "Mandarin": "ZH", "Tagalog": "TL", "Vietnamesisch": "VI", "Mehrsprachig": "Multi"][descriptor.language] ?? descriptor.language
                var shortModel = descriptor.title.replacingOccurrences(of: "Moonshine ", with: "")
                if shortModel.hasSuffix(" " + language) { shortModel = String(shortModel.dropLast(language.count + 1)) }
                favorite = KeyboardModelFavorite(id: rawID, title: descriptor.title, shortTitle: "\(language) · \(shortModel)")
            }
            if slot == 0 { next.first = favorite } else { next.second = favorite }
            guard next.valid else { error = L("Choose two different models.", "Wähle zwei unterschiedliche Modelle."); return false }
            next.revision = UUID(); try store.save(next); favorites = next; preparedFavorites = []; configurePreloader()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func prepareFavorites() {
        guard !isRecording, !isStarting, !isTranscribing, !isPreparingModel, !favorites.models.isEmpty else { return }
        let captured = favorites
        let releasePreload = preloadDemand(Set(captured.models.compactMap { DictationModelID(rawValue: $0.id) }))
        isPreparingModel = true; preparedFavorites = []; error = nil
        Task {
            defer { releasePreload(); isPreparingModel = false }
            for model in captured.models {
                do {
                    guard let id = DictationModelID(rawValue: model.id), installedModels.contains(id) else { throw LocalTranscriberError.modelMissing }
                    try await transcriber.prepare(modelID: id)
                    guard (try KeyboardModelFavoritesStore()?.read())?.revision == captured.revision else { return }
                    await syncPreparedStatus()
                } catch { self.error = "\(model.title): \(error.localizedDescription)"; return }
            }
        }
    }

    func memoryPressure() {
        preloader.memoryWarning()
        preparedModelID = nil; preparedModels = []; preparedFavorites = []
    }

    func selectModel(_ model: DictationModelID) {
        guard !isRecording, !isStarting, !isPreparingModel, !isTranscribing,
              preparedModels.contains(model), installedModels.contains(model) else { return }
        Task {
            do {
                try await transcriber.requirePrepared(modelID: model)
                guard !isRecording, !isStarting, !isPreparingModel, !isTranscribing else { return }
                DictationModelSelection.select(model); selectedModel = model; configurePreloader()
                await syncPreparedStatus()
            } catch { await syncPreparedStatus(); self.error = L("Prepare this model again before choosing it as default.", "Bereite dieses Modell erneut vor, bevor du es als Standard auswählst.") }
        }
    }

    func loadModel(_ model: DictationModelID) {
        guard downloadTask == nil else { return }
        downloads[model] = .downloading(received: 0, total: DictationModelDescriptor.descriptor(for: model).bundleBytes)
        error = nil
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let result = await installer.install(model) { [weak self] state in
                Task { @MainActor in
                    guard let self, case .downloading = self.downloads[model] else { return }
                    self.downloads[model] = state
                }
            }
            downloads[model] = result
            if result == .installed { installedModels.insert(model); migrateModelPreferencesIfQuiet() }
            if result == .failed { error = await installer.lastError ?? L("Couldn’t download the model. Please try again.", "Das Modell konnte nicht geladen werden. Bitte erneut versuchen.") }
            downloadTask = nil
        }
    }

    func cancelDownload(_ model: DictationModelID) {
        downloadTask?.cancel()
        Task { await installer.cancel(model) }
    }

    func prepareSelectedModel() { prepareModel(selectedModel) }

    func prepareModel(_ modelID: DictationModelID) {
        guard !isRecording && !isStarting && !isPreparingModel && !isTranscribing else { return }
        let releasePreload = preloadDemand([modelID])
        isPreparingModel = true
        preparedModelID = nil
        error = nil
        Task { [weak self] in
            guard let self else { releasePreload(); return }
            defer { releasePreload() }
            do {
                try await transcriber.prepare(modelID: modelID)
                preparedModelID = modelID
                await syncPreparedStatus()
                installedModels.insert(modelID)
            } catch {
                self.error = error.localizedDescription
            }
            self.isPreparingModel = false
            statsRevision += 1
        }
    }

    func removeHistory(at offsets: IndexSet) {
        guard historyLoadError == nil else { error = historyLoadError; return }
        history.remove(atOffsets: offsets)
        TranscriptPersistence.saveHistory(history)
    }

    func addSpelling(heard: String, preferred: String) {
        if let spellingsLoadError { error = spellingsLoadError; return }
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !preferred.isEmpty else { return }
        spellings.append(PersonalSpelling(heard: heard, preferred: preferred))
        TranscriptPersistence.saveSpellings(spellings)
    }

    func removeSpellings(at offsets: IndexSet) {
        guard spellingsLoadError == nil else { error = spellingsLoadError; return }
        spellings.remove(atOffsets: offsets)
        TranscriptPersistence.saveSpellings(spellings)
    }

    private func appendHistory(_ text: String) {
        guard historyLoadError == nil else { return }
        history = TranscriptHistory.appending(TranscriptEntry(text: text), to: history)
        TranscriptPersistence.saveHistory(history)
    }

    func recordingInterrupted() {
        if isRecording { finish(interrupted: true) }
        else if isTranscribing { completion.interrupted() }
    }

    private func beginProcessingTime() {
        guard processingBackgroundTask == .invalid else { return }
        processingBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Klangschrift-Teilaufnahme") { [weak self] in
            // Do not delete or cancel the owned audio/job when iOS suspends us.
            // Its continuation finishes when execution resumes in the foreground.
            self?.endProcessingTime()
        }
    }
    private func endProcessingTime() {
        guard processingBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(processingBackgroundTask)
        processingBackgroundTask = .invalid
    }

    private func startProgressPolling() {
        progressPolling?.cancel()
        progressPolling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, let self, self.isRecording else { return }
                let progress = self.recorder.progress
                self.seconds = min(Int(progress.seconds.rounded(.down)), Int(LocalTranscriber.maximumRecordingSeconds))
                self.microphoneLevel = progress.level
            }
        }
    }

    private func stopTimers() {
        automaticStop?.cancel()
        automaticStop = nil
        progressPolling?.cancel()
        progressPolling = nil
    }
}

struct ContentView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @State private var selectedTab = 0
    @State private var keyboardHandoff: KeyboardHandoff?
    @StateObject private var viewModel: RecorderViewModel
    @StateObject private var keyboardSession: KeyboardSessionController

    init() {
        let model = RecorderViewModel()
        let session = KeyboardSessionController(transcriber: model.transcriber)
        session.onModelDemand = { [weak model] ids in model?.preloadDemand(ids) ?? {} }
        session.onTranscript = { [weak model] in model?.receiveKeyboardTranscript($0) }
        model.keyboardIsBusy = { [weak session] in
            guard let session else { return false }
            return session.active || session.starting || session.recording || session.audioReady || session.keyboardPhase == .transcribing
        }
        _viewModel = StateObject(wrappedValue: model)
        _keyboardSession = StateObject(wrappedValue: session)
    }

    @ViewBuilder var body: some View {
#if DEBUG
        if let screen = ProcessInfo.processInfo.arguments.dropFirst().first(where: { $0 == "history-calendar" || $0 == "brand" }),
           ProcessInfo.processInfo.arguments.contains("-ksShot") {
            ScreenQAHarness(screen: screen)
        } else {
            appBody
        }
#else
        appBody
#endif
    }

    @ViewBuilder private var appBody: some View {
        let _ = appLanguageCode
        ZStack {
        TabView(selection: $selectedTab) {
            DictationView(viewModel: viewModel, keyboardSession: keyboardSession)
                .tabItem { Label(L("Dictation", "Diktat"), systemImage: "mic") }
                .tag(0)
            HistoryView(viewModel: viewModel)
                .tabItem { Label(L("History", "Verlauf"), systemImage: "clock") }
                .tag(1)
            SettingsView(viewModel: viewModel, keyboardSession: keyboardSession)
                .tabItem { Label(L("Settings", "Einstellungen"), systemImage: "gearshape") }
                .tag(2)
        }
        .tint(KlangColor.accent)
        .foregroundStyle(KlangColor.ink)
        .background(KlangColor.canvas)
        .disabled(keyboardHandoff != nil)
        .accessibilityHidden(keyboardHandoff != nil)
        if let keyboardHandoff {
            KeyboardHandoffView(session: keyboardSession, onClose: {
                keyboardSession.end()
                self.keyboardHandoff = nil
            })
            .transition(.opacity)
        }
        }
        .alert("Klangschrift", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: { Text(viewModel.error.map(localizedAppMessage) ?? "") }
        .alert(L("Keyboard", "Tastatur"), isPresented: Binding(get: { keyboardSession.error != nil }, set: { if !$0 { keyboardSession.error = nil } })) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: { Text(keyboardSession.error.map(localizedAppMessage) ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            viewModel.memoryPressure(); keyboardSession.memoryPressure()
        }
        .onOpenURL { url in
            guard let handoff = KeyboardHandoff(url: url) else { return }
            let bridgeState = (try? KeyboardBridgeStore()?.read()) ?? nil
            KeyboardBridgeDiagnostics.record("host_foreground_entry", sessionID: handoff.sessionID, requestID: handoff.requestID, phase: bridgeState?.request?.phase, appIsActive: UIApplication.shared.applicationState == .active, tokenValid: bridgeState.map { handoff.matches($0) } ?? false)
            selectedTab = 0
            guard !viewModel.isRecording, !viewModel.isStarting, !viewModel.isTranscribing else {
                keyboardSession.error = L("Finish the current dictation first.", "Beende zuerst das laufende Diktat.")
                return
            }
            keyboardHandoff = handoff
            Task { await keyboardSession.activate(handoff: handoff) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            viewModel.preloadInactive(); viewModel.foregroundWillResign()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            viewModel.preloadBackground(); viewModel.cancelPendingStart(); viewModel.recordingInterrupted()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            viewModel.recordingInterrupted()
        }
        .onChange(of: keyboardSession.starting) { _, starting in
            if !starting { Task { await viewModel.syncPreparedStatus() } }
        }
        .onChange(of: keyboardSession.audioReady) { _, _ in Task { await viewModel.syncPreparedStatus() } }
        .onAppear { activateFromShortcut() }
        .task { await Task.yield(); viewModel.preloadVisible() }
        .onReceive(NotificationCenter.default.publisher(for: .keyboardActivationRequested)) { _ in activateFromShortcut() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in viewModel.preloadActive(); activateFromShortcut() }
        .onChange(of: viewModel.isPreparingModel) { _, value in if !value { viewModel.preloadQuietPhase() } }
        .onChange(of: viewModel.isStarting) { _, value in if !value { viewModel.preloadQuietPhase() } }
        .onChange(of: viewModel.isRecording) { _, value in if !value { viewModel.preloadQuietPhase() } }
        .onChange(of: viewModel.isTranscribing) { _, value in if !value { viewModel.preloadQuietPhase() } }
        .onChange(of: keyboardSession.active) { _, value in if !value { viewModel.preloadQuietPhase() } }
    }

    private func activateFromShortcut() {
        guard UIApplication.shared.applicationState == .active,
              UserDefaults.standard.double(forKey: "klangschrift.keyboardActivationTime") > 0 else { return }
        let requestedAt = UserDefaults.standard.double(forKey: "klangschrift.keyboardActivationTime")
        UserDefaults.standard.removeObject(forKey: "klangschrift.keyboardActivationTime")
        let age = Date().timeIntervalSince1970 - requestedAt
        guard age >= 0, age < 60 else { return }
        guard !viewModel.isRecording, !viewModel.isStarting, !viewModel.isTranscribing else {
            keyboardSession.error = L("Finish the current dictation first.", "Beende zuerst das laufende Diktat.")
            return
        }
        if let store = KeyboardBridgeStore(), let state = try? store.read(), let request = state.request {
            Task { await keyboardSession.activate(handoff: KeyboardHandoff(sessionID: state.sessionID, request: request)) }
        }
    }
}

#if DEBUG
/// Explicit simulator-only opt-in for visual QA; it is not reachable in a
/// release build or from the app's navigation.
private struct ScreenQAHarness: View {
    let screen: String
    private let calendar = Calendar.current
    private var markedDays: Set<Date> {
        let today = calendar.startOfDay(for: Date())
        return Set([today, calendar.date(byAdding: .day, value: -4, to: today)!, calendar.date(byAdding: .day, value: -17, to: today)!])
    }
    var body: some View {
        Group {
            if screen == "history-calendar" {
                NavigationStack { HistoryCalendarPicker(markedDays: markedDays) { _ in } }
            } else {
                ZStack {
                    KlangColor.canvas.ignoresSafeArea()
                    VStack(spacing: 16) {
                        MusicNoteMark().frame(width: 96, height: 96)
                        Text("Klangschrift").font(.title.weight(.bold)).foregroundStyle(KlangColor.ink)
                        Text("You speak. It writes.").foregroundStyle(KlangColor.secondary)
                    }
                }
            }
        }
        .tint(KlangColor.accent)
        .preferredColorScheme(nil)
    }
}
#endif

private struct DictationView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var keyboardSession: KeyboardSessionController
    @AppStorage(DictationLanguage.defaultsKey) private var dictationLanguage = DictationLanguage.german.rawValue

    private var actionTitle: String {
        viewModel.isRecording ? L("Stop recording", "Aufnahme stoppen") : viewModel.isPreparingModel ? L("Preparing …", "Wird vorbereitet …") : viewModel.isTranscribing ? L("Creating text …", "Text wird erstellt …") : viewModel.isStarting ? L("Preparing …", "Wird vorbereitet …") : L("Dictate", "Diktieren")
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 14) {
                        MusicNoteMark().frame(width: 48, height: 54)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klangschrift").font(.system(size: 30, weight: .bold))
                            Text(verbatim: "You speak. It writes.").font(.subheadline).foregroundStyle(KlangColor.secondary)
                        }
                    }.accessibilityElement(children: .combine)
                    Text(viewModel.recordingLabel).font(.subheadline).foregroundStyle(KlangColor.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    VStack(spacing: 20) {
                        NavigationLink {
                            ModelManagementView(viewModel: viewModel, keyboardSession: keyboardSession)
                        } label: {
                            HStack {
                                Text(DictationModelDescriptor.descriptor(for: viewModel.selectedModel).title).font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }.frame(minHeight: 44).foregroundStyle(KlangColor.secondary)
                        }
                        Button {
                            if viewModel.isRecording { viewModel.finish() }
                            else { viewModel.begin() }
                        } label: {
                            VStack(spacing: 12) {
                                if viewModel.isPreparingModel || viewModel.isTranscribing || viewModel.isStarting { ProgressView().tint(KlangColor.onAction) }
                                else { Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill").font(.system(size: 48, weight: .medium)) }
                                Text(actionTitle).font(.headline)
                            }.frame(width: 176, height: 176)
                        }
                        .buttonStyle(.plain).foregroundStyle(viewModel.isRecording ? Color.white : KlangColor.onAction)
                        .background(viewModel.isRecording ? Color(uiColor: KlangPalette.stopAction) : KlangColor.action, in: Circle())
                        .accessibilityLabel(actionTitle)
                        .disabled(viewModel.isStarting || viewModel.isPreparingModel || viewModel.isTranscribing || keyboardSession.active || keyboardSession.starting)
                        if viewModel.isRecording {
                            LevelBars(level: viewModel.microphoneLevel, color: KlangColor.accent).frame(height: 30)
                            Text("\(RecordingPolicy.clock(viewModel.seconds)) / \(RecordingPolicy.clock(Int(RecordingPolicy.maximumSeconds)))").font(.caption.monospacedDigit()).foregroundStyle(KlangColor.secondary)
                            if RecordingPolicy.showsEndingSoon(elapsedSeconds: viewModel.seconds) {
                                Text(L("30 seconds left", "Noch 30 Sekunden")).font(.caption).foregroundStyle(KlangColor.accent)
                            }
                            Button(L("Cancel", "Abbrechen"), action: viewModel.cancel).frame(minHeight: 44).foregroundStyle(KlangColor.secondary)
                        } else if viewModel.isStarting {
                            Button(L("Cancel", "Abbrechen"), action: viewModel.cancelPendingStart).frame(minHeight: 44).foregroundStyle(KlangColor.secondary)
                        }
                    }.padding(18).klangCard()
                    if !viewModel.installedModels.contains(.whisperBaseCoreML) && dictationLanguage != DictationLanguage.english.rawValue {
                        BaseRecommendation(viewModel: viewModel, dictationLanguage: DictationLanguage(rawValue: dictationLanguage)).padding(18).klangCard()
                    }
                    if !viewModel.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.history.first != nil || viewModel.isTranscribing {
                        let latest = viewModel.text.isEmpty ? (viewModel.history.first?.text ?? "") : viewModel.text
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(L("Latest", "Zuletzt")).font(.headline)
                                Spacer()
                                Button { UIPasteboard.general.string = latest } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }
                                    .accessibilityLabel(L("Copy", "Kopieren")).disabled(viewModel.isTranscribing || latest.isEmpty)
                                ShareLink(item: latest) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                                    .accessibilityLabel(L("Share", "Teilen")).disabled(viewModel.isTranscribing || latest.isEmpty)
                            }
                            if viewModel.text.isEmpty { Text(latest).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            else { TextEditor(text: $viewModel.text).frame(minHeight: 120).scrollContentBackground(.hidden).disabled(viewModel.isTranscribing) }
                        }.padding(18).klangCard()
                    }
                }.padding(20)
            }.background(KlangColor.canvas).toolbar(.hidden, for: .navigationBar)
            .onAppear { viewModel.refreshModels() }
        }
    }
}

private struct HistoryView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    @State private var query = ""
    @State private var scrollTarget: Date?
    @State private var scrollRequestID = UUID()
    private var entries: [TranscriptEntry] {
        viewModel.history.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
    }
    private var days: [Date] { TranscriptHistoryCalendar.dictationDays(in: entries) }
    private var allDictationDays: [Date] { TranscriptHistoryCalendar.dictationDays(in: viewModel.history) }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return L("Today", "Heute") }
        if Calendar.current.isDateInYesterday(day) { return L("Yesterday", "Gestern") }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(days, id: \.self) { day in
                        Section(dayTitle(day)) {
                            ForEach(entries.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: day) }) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    Button { viewModel.useHistory(entry) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(entry.text).font(.body).lineLimit(5).foregroundStyle(KlangColor.ink)
                                            Text(entry.createdAt, style: .time).font(.caption).foregroundStyle(KlangColor.secondary)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                    Button { UIPasteboard.general.string = entry.text } label: { Image(systemName: "doc.on.doc").frame(width: 44, height: 44) }
                                        .buttonStyle(.borderless).accessibilityLabel(L("Copy dictation", "Diktat kopieren"))
                                }.padding(.vertical, 6)
                                .swipeActions { Button(role: .destructive) {
                                    if let index = viewModel.history.firstIndex(where: { $0.id == entry.id }) { viewModel.removeHistory(at: IndexSet(integer: index)) }
                                } label: { Label(L("Delete", "Löschen"), systemImage: "trash") } }
                            }.listRowBackground(Color(uiColor: KlangPalette.surface))
                        }
                        .id(day)
                    }
                }
                .onChange(of: scrollRequestID) { _, _ in
                    guard let target = scrollTarget else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                }
            }
            .overlay {
                if viewModel.history.isEmpty {
                    VStack(spacing: 16) {
                        MusicNoteMark().frame(width: 64, height: 64)
                        Text(L("Your dictations appear here.", "Deine Diktate erscheinen hier.")).foregroundStyle(KlangColor.secondary)
                    }.padding(24)
                } else if entries.isEmpty { Text(L("No matching dictations.", "Keine passenden Diktate.")).foregroundStyle(KlangColor.secondary) }
            }
            .searchable(text: $query, prompt: L("Search dictations", "Diktate suchen"))
            .scrollContentBackground(.hidden).background(KlangColor.canvas)
            .navigationTitle(L("History", "Verlauf")).navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        HistoryCalendarPicker(markedDays: Set(allDictationDays)) { day in
                            query = ""
                            scrollTarget = day
                            scrollRequestID = UUID()
                        }
                    } label: { Label(L("Jump to …", "Springe zu …"), systemImage: "calendar") }
                    .accessibilityLabel(L("Jump to …", "Springe zu …"))
                }
            }
            .onAppear { viewModel.openHistory() }
        }
    }
}

private struct HistoryCalendarPicker: View {
    let markedDays: Set<Date>
    let onSelect: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date
    private let calendar = Calendar.current

    init(markedDays: Set<Date>, onSelect: @escaping (Date) -> Void) {
        self.markedDays = markedDays
        self.onSelect = onSelect
        _month = State(initialValue: markedDays.sorted(by: >).first ?? Date())
    }

    private var days: [Date] { TranscriptHistoryCalendar.days(inMonthContaining: month, calendar: calendar) }
    private var leadingSlots: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }
    private var monthTitle: String { month.formatted(.dateTime.month(.wide).year().locale(AppLanguage.current.locale)) }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                Spacer()
                Text(monthTitle).font(.headline)
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 8) {
                ForEach(0..<leadingSlots, id: \.self) { _ in Color.clear.frame(height: 34) }
                ForEach(days, id: \.self) { day in
                    let marked = markedDays.contains(calendar.startOfDay(for: day))
                    Button {
                        onSelect(calendar.startOfDay(for: day)); dismiss()
                    } label: {
                        VStack(spacing: 2) {
                            Text(day.formatted(.dateTime.day())).font(.subheadline.weight(marked ? .semibold : .regular))
                            Circle().fill(marked ? KlangColor.accent : .clear).frame(width: 4, height: 4)
                        }.frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(marked ? KlangColor.ink : KlangColor.secondary)
                    .disabled(!marked)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityValue(marked ? L("Dictations available", "Diktate vorhanden") : L("No dictations", "Keine Diktate"))
                }
            }
            Spacer()
        }
        .padding(20)
        .background(KlangColor.canvas)
        .navigationTitle(L("Jump to …", "Springe zu …"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var keyboardSession: KeyboardSessionController
    @AppStorage(DictationLanguage.defaultsKey) private var dictationLanguage = DictationLanguage.german.rawValue
    @AppStorage(AppLanguage.defaultsKey, store: UserDefaults(suiteName: "group.io.github.miggidev618.klangschrift")) private var appLanguage = AppLanguage.english.rawValue
    @State private var heard = ""
    @State private var preferred = ""

    var body: some View {
        NavigationStack {
            List {
                Section(L("App language", "App-Sprache")) {
                    Picker(L("App language", "App-Sprache"), selection: $appLanguage) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
                Section(L("Dictation language", "Diktiersprache")) {
                    Picker(L("Language", "Sprache"), selection: $dictationLanguage) {
                        ForEach(DictationLanguage.allCases, id: \.rawValue) { Text(localizedModelLanguage($0.title)).tag($0.rawValue) }
                    }
                    Text(L("English models always write English.", "Englische Modelle schreiben immer Englisch.")).font(.footnote).foregroundStyle(KlangColor.secondary)
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
                if !viewModel.installedModels.contains(.whisperBaseCoreML) {
                    Section {
                        BaseRecommendation(viewModel: viewModel)
                    }.listRowBackground(Color(uiColor: KlangPalette.surface))
                }
                Section(L("Keyboard favorites", "Tastaturfavoriten")) {
                    ForEach(0..<2, id: \.self) { slot in
                        let favorite = slot == 0 ? viewModel.favorites.first : viewModel.favorites.second
                        let modelID = favorite.flatMap { DictationModelID(rawValue: $0.id) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("Favorite \(slot + 1)", "Favorit \(slot + 1)")).font(.caption.weight(.medium)).foregroundStyle(KlangColor.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Menu {
                                Button(L("Not selected", "Nicht ausgewählt")) {
                                    if viewModel.setFavorite(slot: slot, rawID: "") { keyboardSession.favoritesChanged() }
                                }
                                ForEach(viewModel.visibleModels.filter { viewModel.installedModels.contains($0) }) { model in
                                    let descriptor = DictationModelDescriptor.descriptor(for: model)
                                    Button("\(descriptor.title) · \(localizedModelLanguage(descriptor.language))") {
                                        if viewModel.setFavorite(slot: slot, rawID: model.rawValue) { keyboardSession.favoritesChanged() }
                                    }
                                }
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(favorite?.title ?? L("Not selected", "Nicht ausgewählt")).font(.body.weight(.semibold))
                                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }.accessibilityLabel(L("Choose favorite \(slot + 1): \(favorite?.title ?? L("Not selected", "Nicht ausgewählt"))", "Favorit \(slot + 1): \(favorite?.title ?? L("Not selected", "Nicht ausgewählt")) auswählen"))
                            if let modelID {
                                Text(localizedModelLanguage(DictationModelDescriptor.descriptor(for: modelID).language)).font(.caption).foregroundStyle(KlangColor.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(viewModel.preparedFavorites.contains(modelID) ? L("Prepared", "Vorbereitet") : L("Not prepared", "Nicht vorbereitet"))
                                    .font(.caption).foregroundStyle(KlangColor.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }.padding(.vertical, 6)
                    }
                    Button {
                        keyboardSession.favoritesChanged(); viewModel.prepareFavorites()
                    } label: {
                        Text(viewModel.favorites.models.count == 2 ? L("Prepare both", "Beide vorbereiten") : L("Prepare favorite", "Favorit vorbereiten"))
                            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    }.disabled(viewModel.favorites.models.isEmpty || viewModel.isPreparingModel)
                    Text(viewModel.isPreparingModel ? L("Preparing …", "Wird vorbereitet …") : viewModel.favorites.models.allSatisfy { model in
                        DictationModelID(rawValue: model.id).map { viewModel.preparedFavorites.contains($0) } ?? false
                    } && !viewModel.favorites.models.isEmpty ? L("Favorites prepared", "Favoriten vorbereitet") : L("Choose installed models and prepare them before dictating with the keyboard.", "Wähle installierte Modelle und bereite sie vor dem Tastaturdiktat vor."))
                        .font(.caption).foregroundStyle(KlangColor.secondary).fixedSize(horizontal: false, vertical: true)
                }.disabled(viewModel.isRecording || viewModel.isTranscribing || viewModel.isStarting || keyboardSession.recording || keyboardSession.starting || keyboardSession.keyboardPhase == .transcribing).listRowBackground(Color(uiColor: KlangPalette.surface))
                Section {
                    NavigationLink { ModelManagementView(viewModel: viewModel, keyboardSession: keyboardSession) } label: {
                        Label(L("Manage models", "Modelle verwalten"), systemImage: "square.stack")
                    }.frame(minHeight: 44)
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
                Section(L("Set up keyboard", "Tastatur einrichten")) {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    } label: {
                        Label(L("Open iOS Settings", "iOS-Einstellungen öffnen"), systemImage: "gearshape")
                    }
                    Text(L("Open Keyboards and allow Full Access.", "Dort Tastaturen öffnen und vollen Zugriff erlauben."))
                        .font(.footnote).foregroundStyle(KlangColor.secondary)
                    DisclosureGroup(L("Add keyboard", "Tastatur erstmals hinzufügen")) {
                        Text(L("Settings → General → Keyboard → Keyboards → Add New Keyboard.", "Einstellungen → Allgemein → Tastatur → Tastaturen → Tastatur hinzufügen."))
                        Text(L("Choose Klangschrift, then allow Full Access.", "Klangschrift auswählen und anschließend vollen Zugriff erlauben."))
                    }
                    .font(.footnote)
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
                Section(L("Your words", "Deine Wörter")) {
                    Text(L("These whole-word replacements correct text after recognition. For Whisper, preferred spellings are also sent as local recognition hints without a guarantee. Other models only use replacements after recognition.", "Diese Ganzwort-Ersetzungen korrigieren Text nach der Erkennung. Für Whisper werden gewünschte Schreibweisen zusätzlich als lokale Erkennungshinweise verwendet, ohne Garantie. Andere Modelle nutzen nur die Nachkorrektur.")).font(.footnote).foregroundStyle(KlangColor.secondary)
                    TextField(L("Heard", "Erkannt"), text: $heard)
                    TextField(L("Preferred", "Gewünscht"), text: $preferred)
                    Button(L("Add spelling", "Schreibweise hinzufügen")) {
                        viewModel.addSpelling(heard: heard, preferred: preferred)
                        heard = ""; preferred = ""
                    }
                    .disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(viewModel.spellings) { spelling in
                        HStack { Text(spelling.heard); Image(systemName: "arrow.right").foregroundStyle(KlangColor.secondary); Text(spelling.preferred) }
                    }
                    .onDelete(perform: viewModel.removeSpellings)
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
                Section(L("Privacy", "Lokal & Datenschutz")) {
                    Text(L("Recording and text processing stay on your iPhone.", "Aufnahme und Textverarbeitung laufen lokal auf deinem iPhone."))
                    Text(L("The microphone stays ready during a keyboard session. No sound is saved between dictations. It turns off after five idle minutes or shortly after hiding the keyboard.", "Das Mikrofon bleibt während der Tastatursitzung bereit. Außerhalb eines Diktats wird kein Ton gespeichert. Die Bereitschaft endet nach fünf Minuten ohne Diktat oder kurz nach dem Ausblenden der Tastatur."))
                        .font(.footnote).foregroundStyle(KlangColor.secondary)
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
            }
            .scrollContentBackground(.hidden).background(KlangColor.canvas).navigationTitle(L("Settings", "Einstellungen")).navigationBarTitleDisplayMode(.large)
            .safeAreaPadding(.bottom, 90)
            .onAppear { viewModel.openSettings() }
            .task {
                while !Task.isCancelled {
                    await viewModel.syncPreparedStatus()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

}

private struct ModelManagementView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var keyboardSession: KeyboardSessionController
    @State private var modelLanguage = "Alle Modelle"
    @State private var installedOnly = false
    private var modelLanguages: [String] {
        ["Alle Modelle", "Deutsch", "Englisch", "Spanisch", "Arabisch", "Japanisch", "Mandarin", "Tagalog", "Vietnamesisch"]
    }
    private var filteredModels: [DictationModelID] {
        viewModel.visibleModels.filter { model in
            let descriptor = DictationModelDescriptor.descriptor(for: model)
            return descriptor.matchesLanguageFilter(modelLanguage) && (!installedOnly || descriptor.isBundled || viewModel.installedModels.contains(model))
        }.sorted {
            if ($0 == viewModel.selectedModel) != ($1 == viewModel.selectedModel) { return $0 == viewModel.selectedModel }
            if ($0 == .whisperBaseCoreML) != ($1 == .whisperBaseCoreML) { return $0 == .whisperBaseCoreML }
            return DictationModelDescriptor.descriptor(for: $0).bundleBytes < DictationModelDescriptor.descriptor(for: $1).bundleBytes
        }
    }

    var body: some View {
        List {
            Section {
                Picker(L("Show models", "Modelle anzeigen"), selection: $modelLanguage) {
                    ForEach(modelLanguages, id: \.self) { Text(localizedModelLanguage($0)).tag($0) }
                }.pickerStyle(.menu)
                Toggle(L("Installed models only", "Nur installierte Modelle"), isOn: $installedOnly)
            }.listRowBackground(Color(uiColor: KlangPalette.surface))
            Section {
                if filteredModels.isEmpty {
                    Text(installedOnly ? L("No model installed for this language yet.", "Für diese Sprache ist noch kein Modell installiert.") : L("No models available for this language.", "Für diese Sprache sind keine Modelle verfügbar.")).foregroundStyle(KlangColor.secondary)
                }
                ForEach(filteredModels) { model in
                    let descriptor = DictationModelDescriptor.descriptor(for: model)
                    NavigationLink {
                        ModelDetailView(viewModel: viewModel, keyboardSession: keyboardSession, model: model)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(descriptor.title).font(.body.weight(.semibold))
                                    if model == .whisperBaseCoreML { Text(L("Recommended", "Empfohlen")).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(KlangColor.accent.opacity(0.12), in: Capsule()) }
                                }
                                ModelSpeedRating(model: model)
                                Text("\(localizedModelLanguage(descriptor.language)) · \(formattedBytes(descriptor.bundleBytes))").font(.caption).foregroundStyle(KlangColor.secondary)
                            }
                            Spacer()
                            if viewModel.selectedModel == model { Image(systemName: "checkmark.circle.fill").foregroundStyle(KlangColor.accent).accessibilityLabel(L("Default model", "Standardmodell")) }
                            else if viewModel.installedModels.contains(model) || descriptor.isBundled { Image(systemName: "checkmark.circle").foregroundStyle(KlangColor.secondary).accessibilityLabel(L("Installed", "Installiert")) }
                        }.padding(.vertical, 5)
                    }
                }
            }.listRowBackground(Color(uiColor: KlangPalette.surface))

        }.scrollContentBackground(.hidden).background(KlangColor.canvas)
        .navigationTitle(L("Manage models", "Modelle verwalten")).navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.refreshModels() }
    }
}

private struct ModelDetailView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    @ObservedObject var keyboardSession: KeyboardSessionController
    let model: DictationModelID
    private var descriptor: DictationModelDescriptor { .descriptor(for: model) }
    var body: some View {
        List {
            Section {
                Text(descriptor.title).font(.title3.weight(.semibold))
                Text(modelDescription(descriptor)).foregroundStyle(KlangColor.secondary)
                ModelSpeedRating(model: model)
                LabeledContent(L("Language", "Sprache"), value: localizedModelLanguage(descriptor.language))
                LabeledContent(L("Size", "Größe"), value: formattedBytes(descriptor.bundleBytes))
            }.listRowBackground(Color(uiColor: KlangPalette.surface))
            if DictationPerformanceStore.read(model).successfulJobs > 0 {
                Section(L("Measured on this iPhone", "Auf diesem iPhone gemessen")) {
                    let stats = DictationPerformanceStore.read(model)
                    LabeledContent(L("Dictations", "Diktate"), value: String(stats.successfulJobs))
                    LabeledContent(L("Average processing", "Verarbeitung im Mittel"), value: "\((Double(stats.totalMS) / 1000 / Double(stats.successfulJobs)).formatted(.number.precision(.fractionLength(2)).locale(AppLanguage.current.locale))) s")
                }.listRowBackground(Color(uiColor: KlangPalette.surface))
            }
            Section {
                        if case .downloading(let received, let total) = viewModel.downloads[model] {
                            ProgressView(value: Double(received), total: Double(total))
                            Text("\(formattedBytes(received)) / \(formattedBytes(total))").font(.caption)
                            Button(L("Cancel", "Abbrechen")) { viewModel.cancelDownload(model) }
                        } else if viewModel.installedModels.contains(model) || descriptor.isBundled {
                            Button(viewModel.preparedModels.contains(model) ? L("Prepare again", "Erneut vorbereiten") : L("Prepare", "Vorbereiten")) { viewModel.prepareModel(model) }
                                .disabled(viewModel.isPreparingModel || keyboardSession.active || keyboardSession.starting)
                            if viewModel.preparedModels.contains(model) && viewModel.selectedModel != model {
                                Button(L("Set as default", "Als Standard")) { viewModel.selectModel(model) }
                            }
                        } else {
                            Button(L("Download", "Laden")) { viewModel.loadModel(model) }.buttonStyle(.borderedProminent).foregroundStyle(KlangColor.onAction)
                        }

            }.buttonStyle(.borderless).listRowBackground(Color(uiColor: KlangPalette.surface))
        }.scrollContentBackground(.hidden).background(KlangColor.canvas)
        .navigationTitle(descriptor.title).navigationBarTitleDisplayMode(.inline)
    }
}

private func formattedBytes(_ value: Int) -> String {
    AppLanguage.current.formattedBytes(value)
}

private enum KlangColor {
    static let canvas = Color(uiColor: KlangPalette.canvas)
    static let accent = Color(uiColor: KlangPalette.accent)
    static let action = Color(uiColor: KlangPalette.action)
    static let stop = Color(uiColor: KlangPalette.error)
    static let ink = Color(uiColor: KlangPalette.ink)
    static let onAction = Color(uiColor: KlangPalette.onAction)
    static let secondary = Color(uiColor: KlangPalette.secondary)
}

private struct MusicNoteMark: View {
    var body: some View {
        Image("KlangschriftLogoOchre")
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

private struct ModelSpeedRating: View {
    let model: DictationModelID
    var body: some View {
        if let measurement = ModelReferenceMeasurement.measured(model) {
            VStack(alignment: .leading, spacing: 4) {
                rating(L("Accuracy", "Genauigkeit"), measurement.qualityStars)
                rating(L("Speed", "Tempo"), measurement.speedStars)
                Text(L("Mac reference · synthetic speech", "Mac-Referenz · synthetische Sprache"))
                    .font(.caption2)
            }.font(.caption).foregroundStyle(KlangColor.secondary)
        }
    }
    private func rating(_ label: String, _ stars: Int) -> some View {
        HStack(spacing: 3) {
            Text(label).padding(.trailing, 4)
            ForEach(0..<5) { index in Image(systemName: index < stars ? "star.fill" : "star") }
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(stars) " + L("of 5; Mac reference", "von 5; Mac-Referenz"))
    }
}

private struct LevelBars: View {
    let level: Double; let color: Color
    var body: some View {
        HStack(spacing: 4) { ForEach(0..<9, id: \.self) { i in
            Capsule().fill(color.opacity(Double(i) / 10 < max(0.12, level) ? 1 : 0.2)).frame(width: 5, height: CGFloat(8 + abs(4 - i) * 4))
        }}.frame(maxWidth: .infinity)
    }
}

private struct KeyboardHandoffView: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var session: KeyboardSessionController
    let onClose: () -> Void
    var body: some View {
        ZStack {
            KlangColor.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) { Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44) }
                        .accessibilityLabel(L("Cancel dictation", "Diktat abbrechen"))
                    Spacer()
                    HStack(spacing: 7) { MusicNoteMark().frame(width: 18, height: 21); Text("Klangschrift").font(.subheadline.weight(.semibold)) }
                }.padding(.horizontal, 20).padding(.top, 12)

                Spacer(minLength: 8)
                Text(headline)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center).padding(.horizontal, 20)
                Text(statusText)
                    .font(.body).foregroundStyle(statusColor).multilineTextAlignment(.center)
                    .padding(.horizontal, 30).padding(.top, 8)
                if session.recording || session.keyboardPhase == .ready {
                    TwoPhoneSwipeIllustration()
                        .frame(maxWidth: 330, maxHeight: 265)
                        .padding(.horizontal, 26).padding(.top, 12)
                        .accessibilityHidden(true)
                }
                if session.recording {
                    LevelBars(level: session.microphoneLevel, color: KlangColor.accent).frame(height: 28).padding(.horizontal, 60)
                    Text(L("\(session.remainingSeconds / 60):\(String(format: "%02d", session.remainingSeconds % 60)) remaining", "\(session.remainingSeconds / 60):\(String(format: "%02d", session.remainingSeconds % 60)) verbleibend"))
                        .font(.callout.monospacedDigit()).foregroundStyle(KlangColor.secondary)
                }
                Spacer(minLength: 8)
            }
        }
        .tint(KlangColor.accent)
        .overlay {
            if session.recording || session.keyboardPhase == .ready {
                GeometryReader { proxy in
                    let frame = KeyboardHandoffGuidanceGeometry.frame(container: proxy.size, safeAreaBottom: 0)
                    SwipeGuidance()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if session.starting || session.keyboardPhase == .transcribing {
                ProgressView().tint(KlangColor.accent).padding(.bottom, 22)
            } else if !(session.recording || session.keyboardPhase == .ready) {
                Button(L("Close", "Schließen"), action: onClose).buttonStyle(.borderedProminent).foregroundStyle(KlangColor.onAction).padding(.bottom, 22)
            }
        }
    }

    private var statusText: String {
        if let error = session.error { return localizedAppMessage(error) }
        if session.recording { return L("Recording. Swipe back to your message now.", "Die Aufnahme läuft. Wische jetzt zur Nachricht zurück.") }
        if session.keyboardPhase == .transcribing {
            return L("Please stay here until your text is ready.", "Bitte hier bleiben, bis dein Text fertig ist.") + "\n" +
                (session.audioReady ? L("The microphone stays ready between dictations.", "Das Mikrofon bleibt zwischen Diktaten bereit.") : L("The microphone is off.", "Das Mikrofon ist aus.")) +
                "\n\(session.processingElapsedSeconds / 60):\(String(format: "%02d", session.processingElapsedSeconds % 60))"
        }
        if session.keyboardPhase == .ready { return L("Text ready. Swipe back along the bottom.", "Text fertig. Jetzt unten zurückwischen.") }
        if session.starting { return L("Preparing. Please stay here.", "Modell wird lokal vorbereitet. Bitte hier bleiben.") }
        return L("Start a new dictation from the keyboard.", "Starte ein neues Diktat über die Tastatur.")
    }

    private var headline: String {
        if session.error != nil || session.keyboardPhase == .failed { return L("Dictation interrupted", "Diktat unterbrochen") }
        if session.keyboardPhase == .transcribing { return L("Creating text", "Text wird erstellt") }
        if session.keyboardPhase == .ready { return L("Text ready", "Text fertig") }
        if session.recording { return L("Swipe back and dictate", "Zurückwischen und diktieren") }
        if session.starting { return L("Preparing dictation", "Diktat wird vorbereitet") }
        return L("No dictation open", "Kein Diktat offen")
    }

    private var statusColor: Color { session.error == nil ? KlangColor.secondary : KlangColor.stop }
}

private struct TwoPhoneSwipeIllustration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var touchMoved = false
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let phoneWidth = min(size.width * 0.42, 132.0)
            let phoneHeight = phoneWidth * 1.86
            let y = max(8, (size.height - phoneHeight) / 2)
            let left = size.width * 0.10
            let right = size.width - left - phoneWidth
            ZStack {
                PhoneOutline(x: left, y: y, width: phoneWidth, height: phoneHeight, accent: false)
                PhoneOutline(x: right, y: y, width: phoneWidth, height: phoneHeight, accent: true)
                Image(systemName: "arrow.right").font(.title2.weight(.semibold)).foregroundStyle(KlangColor.accent)
                    .position(x: size.width / 2, y: size.height / 2)
                Image(systemName: "hand.point.right.fill").font(.title3).foregroundStyle(KlangColor.accent)
                    .position(x: left + phoneWidth * 0.50 + (reduceMotion ? 0 : (touchMoved ? phoneWidth * 0.18 : -phoneWidth * 0.12)), y: y + phoneHeight * 0.86)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { touchMoved = true }
        }
    }
}

private struct PhoneOutline: View {
    let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat; let accent: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous).fill(Color(uiColor: KlangPalette.surface))
            RoundedRectangle(cornerRadius: width * 0.16, style: .continuous).stroke(accent ? KlangColor.accent : Color(uiColor: KlangPalette.separator), lineWidth: 2)
            VStack(spacing: height * 0.08) {
                RoundedRectangle(cornerRadius: 3).fill(KlangColor.secondary.opacity(0.35)).frame(width: width * 0.30, height: 5)
                RoundedRectangle(cornerRadius: 10).fill(accent ? KlangColor.accent.opacity(0.12) : KlangColor.canvas).frame(width: width * 0.67, height: height * 0.33)
                Spacer()
                Capsule().fill(KlangColor.secondary.opacity(0.45)).frame(width: width * 0.34, height: 4).padding(.bottom, height * 0.07)
            }.padding(.top, height * 0.07)
        }.frame(width: width, height: height).position(x: x + width / 2, y: y + height / 2)
    }
}

private struct SwipeGuidance: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moved = false
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down")
                .foregroundStyle(KlangColor.accent).offset(y: reduceMotion ? 0 : (moved ? 3 : -1))
            Text(L("Swipe right at the very bottom", "Ganz unten nach rechts wischen"))
                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.82)
                .foregroundStyle(KlangColor.accent)
        }
        .frame(height: KeyboardHandoffGuidanceGeometry.height)
        .padding(.horizontal, 12)
        .background(KlangColor.accent.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Swipe right at the very bottom", "Ganz unten nach rechts wischen"))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) { moved = true }
        }
    }
}

private extension View {
    func klangCard() -> some View { background(Color(uiColor: KlangPalette.surface)).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(uiColor: KlangPalette.separator).opacity(0.25))) }
}

private struct BaseRecommendation: View {
    @Environment(\.appLanguageCode) private var appLanguageCode
    @ObservedObject var viewModel: RecorderViewModel
    var dictationLanguage: DictationLanguage? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dictationLanguage {
                Text(dictationLanguage == .german
                     ? L("German needs Whisper Base", "Deutsch braucht Whisper Base")
                     : L("Other languages need Whisper Base", "Andere Sprachen brauchen Whisper Base"))
                    .font(.headline)
            }
            Text(L("Whisper Base · recommended · \(formattedBytes(DictationModelDescriptor.descriptor(for: .whisperBaseCoreML).bundleBytes))", "Whisper Base · empfohlen · \(formattedBytes(DictationModelDescriptor.descriptor(for: .whisperBaseCoreML).bundleBytes))"))
                .font(.subheadline.weight(.medium))
            if case .downloading(let received, let total) = viewModel.downloads[.whisperBaseCoreML] {
                ProgressView(value: Double(received), total: Double(max(1, total)))
                Text("\(formattedBytes(received)) / \(formattedBytes(total))").font(.caption)
                Button(L("Cancel", "Abbrechen")) { viewModel.cancelDownload(.whisperBaseCoreML) }
            } else {
                Button(L("Download", "Laden")) { viewModel.loadModel(.whisperBaseCoreML) }
                    .buttonStyle(.borderedProminent).foregroundStyle(KlangColor.onAction)
                    .disabled(viewModel.downloads.values.contains { if case .downloading = $0 { return true }; return false })
            }
        }.tint(KlangColor.accent)
    }
}

private func localizedModelLanguage(_ value: String) -> String {
    switch value {
    case "English", "Englisch": return L("English", "Englisch")
    case "Deutsch": return L("German", "Deutsch")
    case "Mehrsprachig": return L("Multilingual", "Mehrsprachig")
    case "Alle Modelle": return L("All models", "Alle Modelle")
    case "Automatisch", "Auto": return L("Auto", "Automatisch")
    case "Spanisch": return L("Spanish", "Spanisch")
    case "Arabisch": return L("Arabic", "Arabisch")
    case "Japanisch": return L("Japanese", "Japanisch")
    case "Mandarin": return L("Mandarin", "Mandarin")
    case "Tagalog": return L("Tagalog", "Tagalog")
    case "Vietnamesisch": return L("Vietnamese", "Vietnamesisch")
    default: return value
    }
}

private func modelDescription(_ descriptor: DictationModelDescriptor) -> String {
    descriptor.language == "English" ? L("For English dictation", "Für englische Diktate") :
        descriptor.language == "Deutsch" ? L("For German dictation", "Für deutsche Diktate") :
        L("For dictation in several languages", "Für Diktate in mehreren Sprachen")
}

// Keep the underlying error for diagnosis; present a short message in the app language.
private func localizedAppMessage(_ message: String) -> String {
    switch message {
    case "Mikrofonzugriff wurde nicht erlaubt.": return L("Allow microphone access in Settings to dictate.", "Erlaube den Mikrofonzugriff in den Einstellungen, um zu diktieren.")
    case "Eine Aufnahme läuft bereits.", "Beende zuerst das laufende Diktat.", "Finish the current dictation first.": return L("Finish the current dictation first.", "Beende zuerst das laufende Diktat.")
    case "Es läuft keine Aufnahme.", "Starte das Diktat über die Klangschrift-Tastatur in deiner Nachricht.": return L("Start a dictation from the Klangschrift keyboard in your message.", "Starte ein Diktat über die Klangschrift-Tastatur in deiner Nachricht.")
    case "Es wurde kein Ton aufgenommen. Bitte Mikrofon und Eingabe prüfen.": return L("No sound recorded. Check your microphone and try again.", "Kein Ton aufgenommen. Prüfe das Mikrofon und versuche es erneut.")
    case "Der lokale Verlauf konnte nicht gelesen werden. Bestehende Einträge wurden nicht verändert.": return L("Couldn’t open your history. Your entries are unchanged.", "Der Verlauf konnte nicht geöffnet werden. Deine Einträge bleiben erhalten.")
    case "Eigene Schreibweisen konnten nicht gelesen werden. Bestehende Einträge wurden nicht verändert.": return L("Couldn’t open your words. Your entries are unchanged.", "Deine Wörter konnten nicht geöffnet werden. Deine Einträge bleiben erhalten.")
    case "Wähle zwei unterschiedliche Modelle.", "Choose two different models.": return L("Choose two different models.", "Wähle zwei unterschiedliche Modelle.")
    case "Bereite dieses Modell erneut vor, bevor du es als Standard auswählst.", "Prepare this model again before choosing it as default.": return L("Prepare this model again before choosing it as default.", "Bereite dieses Modell erneut vor, bevor du es als Standard auswählst.")
    case "Das Modell ist lokal nicht verfügbar. Öffne Modelle verwalten und installiere es vollständig.", "Download this model in Manage models first.": return L("Download this model in Manage models first.", "Lade dieses Modell zuerst unter Modelle verwalten.")
    case "Das Modell konnte nicht geladen werden. Bitte erneut versuchen.", "Couldn’t download the model. Please try again.": return L("Couldn’t download the model. Please try again.", "Das Modell konnte nicht geladen werden. Bitte erneut versuchen.")
    default: return L("Couldn’t complete this action. Please try again.", "Die Aktion konnte nicht abgeschlossen werden. Bitte versuche es erneut.")
    }
}
