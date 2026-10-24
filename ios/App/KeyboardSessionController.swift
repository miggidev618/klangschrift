import AVFoundation
import SwiftUI

@MainActor
final class KeyboardSessionController: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var audioReady = false
    @Published private(set) var starting = false
    @Published private(set) var recording = false
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var microphoneLevel = 0.0
    @Published private(set) var keyboardPhase: KeyboardBridgePhase?
    @Published private(set) var processingElapsedSeconds = 0
    @Published var error: String?
    var onTranscript: ((String) -> Void)?
    private let audio = SessionAudioRecorder()
    private let transcriber: LocalTranscriptionService
    private var store: KeyboardBridgeStore?
    private var sessionID: UUID?
    private var recordingID: UUID?
    private var processingID: UUID?
    private var generation = 0 // Job generation: audio-only shutdown never changes it.
    private var audioEpoch: UUID?
    private var audioStartedAt: Date?
    private var idleDeadline: Date?
    private var returnGraceDeadline: Date?
    private var lastPresenceAt: Date?
    private var warmPreparation: Task<Void, Never>?
    private var warmPreparationID: UUID?
    private var polling: Task<Void, Never>?
    private var inference: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var recordingStartedAt: Date?
    private var lastCaptureTraceSecond = -1
    private var captureWatchdog = RecordingPolicy.CaptureWatchdog()
    private var modelPin: UUID?
    private var preparedModelIDs: Set<DictationModelID> = []
    private var preparedRevision: UUID?
    private var cacheStatusGeneration = 0
    private var cacheStatusTask: Task<Void, Never>?
    private var jobModelID: DictationModelID?

    init(transcriber: LocalTranscriptionService) {
        self.transcriber = transcriber
        audio.onInterruption = { [weak self] in
            self?.handleMicrophoneInterruption()

        }
    }

    var onModelDemand: (Set<DictationModelID>) -> (() -> Void) = { _ in {} }
    /// Set by the host while it owns the storage-maintenance critical section.
    /// A handoff received in that window must not start a fresh model worker.
    var storageMaintenanceActive: () -> Bool = { false }

    func favoritesChanged() {
        guard !recording, !starting, processingID == nil else { return }
        shutDownAudio(); preparedModelIDs = []; preparedRevision = nil
    }

    func memoryPressure() {
        cacheStatusGeneration += 1; preparedModelIDs = []
        Task { await transcriber.handleMemoryPressure(); refreshPreparedLease() }
    }

    private func favoritePair(for request: KeyboardBridgeRequest) throws -> (DictationModelID, KeyboardModelFavorites?) {
        guard let raw = request.modelID else {
            guard request.favoritesRevision == nil else { throw LocalTranscriberError.modelMissing }
            return (DictationModelSelection.selected(), nil)
        }
        guard let model = DictationModelID(rawValue: raw), let favorites = try KeyboardModelFavoritesStore()?.read(),
              favorites.matches(modelID: raw, revision: request.favoritesRevision), favorites.models.allSatisfy({ DictationModelID(rawValue: $0.id) != nil }) else {
            throw LocalTranscriberError.modelMissing
        }
        return (model, favorites)
    }

    private func validateFavoriteRevision(_ request: KeyboardBridgeRequest) throws {
        if request.modelID != nil { _ = try favoritePair(for: request) }
    }

    private func releaseModelPin() {
        guard let pin = modelPin else { return }
        modelPin = nil
        Task { await transcriber.releasePin(pin) }
    }

    private func refreshPreparedLease() {
        guard cacheStatusTask == nil else { return }
        let cacheGeneration = cacheStatusGeneration
        cacheStatusTask = Task { [weak self] in
            guard let self else { return }
            defer { cacheStatusTask = nil }
            let prepared = await transcriber.preparedModels()
            guard audioReady, cacheGeneration == cacheStatusGeneration else { return }
            preparedModelIDs = prepared
            if let favorites = try? KeyboardModelFavoritesStore()?.read() {
                if let preparedRevision, preparedRevision != favorites.revision {
                    if recordingID == nil, processingID == nil, !starting { invalidateAudio() }
                    return
                }
            }
        }
    }

    func activate(handoff: KeyboardHandoff? = nil) async {
        guard !storageMaintenanceActive() else { return }
        guard let bridge = KeyboardBridgeStore() else { error = KeyboardBridgeError.unavailable.localizedDescription; return }
        var activationGeneration: Int?
        do {
            guard let prepared = try bridge.read(), let request = prepared.request,
                  let handoff, handoff.matches(prepared) else {
                error = "Starte das Diktat über die Klangschrift-Tastatur in deiner Nachricht."
                return
            }
            KeyboardBridgeDiagnostics.record("host_activation_started", sessionID: prepared.sessionID, requestID: request.id, phase: request.phase)
            keyboardPhase = request.phase
            if recordingID != nil || processingID != nil || starting {
                if sessionID == prepared.sessionID {
                    try? bridge.transaction { $0?.request?.error = nil }
                    return
                }
                error = "Beende zuerst das laufende Diktat."
                return
            }
            if audioReady {
                guard request.phase == .queued else { return }
                // A cold foreground retry can replace only an idle engine, not a job/draft.
                shutDownAudio()
            }
            guard request.phase == .queued, request.command == .start else {
                if request.phase == .transcribing, inference == nil, processingID == nil,
                   try bridge.failInterruptedProcessing(handoff) {
                    store = bridge; sessionID = prepared.sessionID
                    keyboardPhase = .failed
                    error = request.error ?? "Die Verarbeitung wurde unterbrochen. Bitte erneut diktieren."
                }
                return
            }
            store = bridge; sessionID = prepared.sessionID
            starting = true; error = nil; generation += 1
            let attempt = generation
            activationGeneration = attempt
            let (capturedModel, favorites) = try favoritePair(for: request)
            let releasePreload = onModelDemand(Set((favorites?.models.compactMap { DictationModelID(rawValue: $0.id) } ?? []) + [capturedModel]))
            defer { releasePreload() }
            jobModelID = capturedModel
            let queuedHeartbeat = Task { @MainActor in
                while !Task.isCancelled {
                    try? bridge.transaction { current in
                        guard let state = current, handoff.matches(state), state.request?.phase == .queued else { return }
                        current?.heartbeat = .now
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { queuedHeartbeat.cancel() }
            // URL delivery can precede scene activation. Start audio only in foreground.
            let deadline = Date().addingTimeInterval(5)
            while UIApplication.shared.applicationState != .active && Date() < deadline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard attempt == generation, !Task.isCancelled,
                  UIApplication.shared.applicationState == .active else { starting = false; return }
            let pair = favorites?.models ?? []
            for item in pair {
                guard attempt == generation, !Task.isCancelled, UIApplication.shared.applicationState == .active else { starting = false; return }
                do { try await transcriber.prepare(modelID: DictationModelID(rawValue: item.id)!, origin: .keyboard) }
                catch { throw NSError(domain: "Klangschrift", code: 27, userInfo: [NSLocalizedDescriptionKey: "\(item.title): \(error.localizedDescription)"]) }
                try validateFavoriteRevision(request)
            }
            if pair.isEmpty { try await transcriber.prepare(modelID: capturedModel, origin: .keyboard) }
            preparedModelIDs = await transcriber.preparedModels()
            preparedRevision = favorites?.revision
            try validateFavoriteRevision(request)
            guard attempt == generation, !Task.isCancelled, UIApplication.shared.applicationState == .active,
                  let stillQueued = try bridge.read(), handoff.matches(stillQueued),
                  request.matchesModelSelection(stillQueued.request), stillQueued.request?.phase == .queued, stillQueued.request?.command == .start else { starting = false; return }
            let permitted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard attempt == generation else { return }
            guard permitted else {
                store = bridge; sessionID = prepared.sessionID; starting = false
                error = AudioRecorderError.microphoneDenied.localizedDescription
                fail(requestID: request.id, message: error!)
                return
            }
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
                  let fresh = try bridge.read(), handoff.matches(fresh), request.matchesModelSelection(fresh.request), fresh.request?.phase == .queued, fresh.request?.command == .start else { starting = false; return }
            store = bridge; sessionID = fresh.sessionID
            // Capture before audio starts. Settings changes during this session only apply to its next dictation.
            try await transcriber.requirePrepared(modelID: capturedModel, pin: request.id)
            guard attempt == generation, !Task.isCancelled, UIApplication.shared.applicationState == .active else { await transcriber.releasePin(request.id); starting = false; return }
            modelPin = request.id
            try validateFavoriteRevision(request)
            guard attempt == generation, !Task.isCancelled, UIApplication.shared.applicationState == .active else { releaseModelPin(); starting = false; return }
            try audio.activate()
            try audio.startClip()
            audioReady = true; audioEpoch = UUID(); audioStartedAt = .now; idleDeadline = nil
            returnGraceDeadline = Date().addingTimeInterval(KeyboardAudioReadiness.returnGrace); lastPresenceAt = nil
            let accepted = try bridge.transaction { current -> Bool in
                guard let state = current, handoff.matches(state), request.matchesModelSelection(state.request), state.request?.phase == .queued, state.request?.command == .start else { return false }
                current?.request?.phase = .recording
                current?.heartbeat = .now
                return true
            }
            guard accepted else { shutDownAudio(); starting = false; return }
            try bridge.publishAudioLease(sessionID: fresh.sessionID, epoch: audioEpoch!, preparedModelIDs: preparedModelIDs.map(\.rawValue), favoritesRevision: preparedRevision)
            recordingID = request.id; recording = true; active = true; starting = false
            keyboardPhase = .recording
            recordingStartedAt = .now; lastCaptureTraceSecond = -1
            let initialProgress = audio.progress
            KeyboardBridgeDiagnostics.record("host_recording", sessionID: fresh.sessionID, requestID: request.id, phase: .recording, capturedFrames: Int64(initialProgress.capturedFrames), receivedBuffers: audio.receivedBufferCount, recordedSeconds: Int(initialProgress.seconds), level: initialProgress.level)
            remainingSeconds = Int(RecordingPolicy.maximumSeconds)
            startPolling()
        } catch {
            guard let activationGeneration else { self.error = error.localizedDescription; return }
            guard activationGeneration == generation else { return }
            shutDownAudio(); starting = false; recording = false
            if let handoff, let state = try? bridge.read(), handoff.matches(state) {
                fail(requestID: handoff.requestID, message: error.localizedDescription)
            }
            self.error = error.localizedDescription
        }
    }

    func stop() {
        guard let store, let state = try? store.read(), let request = state.request, recordingID == request.id else { return }
        let progress = audio.progress
        KeyboardBridgeDiagnostics.record("host_stop", sessionID: state.sessionID, requestID: request.id, phase: request.phase, capturedFrames: Int64(progress.capturedFrames), receivedBuffers: audio.receivedBufferCount, recordedSeconds: Int(progress.seconds), level: progress.level)
        finish(request: request, session: state)
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func beginProcessingTime(requestID: UUID) {
        endBackgroundTime()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Klangschrift-Transkription") { [weak self] in
            guard let self else { return }
            // Keep the native job/file for resumption; audio readiness has its own lease.
            try? self.store?.transaction { current in
                guard current?.sessionID == self.sessionID, current?.request?.id == requestID,
                      current?.request?.phase == .transcribing else { return }
                current?.request?.error = "Öffne Klangschrift, um die Verarbeitung fortzusetzen."
            }
            self.endBackgroundTime()
        }
    }

    func end() {
        generation += 1
        polling?.cancel(); polling = nil
        warmPreparation?.cancel(); warmPreparation = nil; warmPreparationID = nil
        inference?.cancel(); inference = nil
        shutDownAudio(); endBackgroundTime()
        if let store, let sessionID {
            try? store.transaction { if $0?.sessionID == sessionID { $0 = nil } }
        }
        releaseModelPin()
        store = nil; sessionID = nil; recordingID = nil; processingID = nil; jobModelID = nil; recordingStartedAt = nil; lastCaptureTraceSecond = -1
        active = false; starting = false; recording = false; remainingSeconds = 0; microphoneLevel = 0; keyboardPhase = nil; processingElapsedSeconds = 0
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(self.recording ? 100 : 300))
                guard !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    /// Audio lifetime is independent of native transcription and the ready draft.
    private func shutDownAudio() {
        if processingID == nil { releaseModelPin() }
        if let store, let sessionID, let epoch = audioEpoch { try? store.clearAudioLease(sessionID: sessionID, epoch: epoch) }
        audio.end(); audioReady = false; audioEpoch = nil; audioStartedAt = nil
        idleDeadline = nil; returnGraceDeadline = nil; lastPresenceAt = nil
        if recording { recording = false; recordingID = nil; recordingStartedAt = nil }
        microphoneLevel = 0
        active = processingID != nil
        if processingID == nil, warmPreparation == nil { polling?.cancel(); polling = nil }
    }

    private func handleMicrophoneInterruption() {
        if let recordingID, let state = try? store?.read(), state.sessionID == sessionID {
            failCapture(requestID: recordingID, session: state, progress: audio.progress)
        } else { invalidateAudio() }
    }

    private func invalidateAudio() {
        let clipID = recordingID
        shutDownAudio()
        warmPreparation?.cancel(); warmPreparation = nil; warmPreparationID = nil; starting = false
        if processingID == nil { polling?.cancel(); polling = nil }
        if let clipID {
            fail(requestID: clipID, message: "Die Audioverbindung wurde unterbrochen. Starte das Diktat erneut.")
            error = "Die Audioverbindung wurde unterbrochen. Starte das Diktat erneut."
        }
        // A finished clip/native job/result is deliberately untouched.
    }

    private func acceptWarm(_ request: KeyboardBridgeRequest, state: KeyboardBridgeState, epoch: UUID) {
        guard audioReady, audio.ready, audioEpoch == epoch, recordingID == nil, processingID == nil,
              request.command == .start, let started = request.warmRequestedAt,
              Date().timeIntervalSince(started) < 5,
              let presence = state.keyboardPresence, presence.sessionID == state.sessionID,
              presence.instanceID == request.warmPresenceInstanceID, presence.fresh(at: .now) else { return }
        starting = true; warmPreparationID = request.id
        generation += 1
        let capturedModel: DictationModelID
        do { capturedModel = try favoritePair(for: request).0 }
        catch { starting = false; warmPreparationID = nil; shutDownAudio(); fail(requestID: request.id, message: "Favorit geändert. Bitte in Klangschrift vorbereiten."); return }
        let token = generation
        let handoff = KeyboardHandoff(sessionID: state.sessionID, request: request)
        warmPreparation = Task { [weak self] in
            guard let self else { return }
            defer {
                if recordingID != request.id, processingID != request.id {
                    Task { await transcriber.releasePin(request.id) }
                    if modelPin == request.id { modelPin = nil }
                }
                if warmPreparationID == request.id {
                    warmPreparation = nil; warmPreparationID = nil; starting = false
                    if !audioReady, processingID == nil { polling?.cancel(); polling = nil }
                }
            }
            do {
                try await transcriber.requirePrepared(modelID: capturedModel, pin: request.id)
                try validateFavoriteRevision(request)
                guard !Task.isCancelled, generation == token, audioReady, audioEpoch == epoch,
                      let fresh = try store?.read(), handoff.matches(fresh),
                      request.matchesModelSelection(fresh.request), fresh.request?.phase == .queued, fresh.request?.command == .start,
                      let presence = fresh.keyboardPresence, presence.sessionID == fresh.sessionID,
                      presence.instanceID == request.warmPresenceInstanceID, presence.fresh(at: .now),
                      Date().timeIntervalSince(started) < 5 else { return }
                modelPin = request.id
                try validateFavoriteRevision(request)
                try audio.startClip()
                let accepted = try store?.acknowledgeWarmRecording(handoff, epoch: epoch) ?? false
                guard accepted else { audio.cancelClip(); return }
                jobModelID = capturedModel; recordingID = request.id; recording = true; active = true
                keyboardPhase = .recording; recordingStartedAt = .now; lastCaptureTraceSecond = -1
                remainingSeconds = Int(RecordingPolicy.maximumSeconds); idleDeadline = nil; error = nil
            } catch {
                guard generation == token, audioEpoch == epoch, warmPreparationID == request.id else { return }
                shutDownAudio()
                fail(requestID: request.id, message: error.localizedDescription)
            }
        }
    }

    private func poll() {
        guard let store, let sessionID else { return }
        do {
            guard var state = try store.read(), state.sessionID == sessionID else { shutDownAudio(); return }
            guard Date() < state.expiresAt else { shutDownAudio(); return }
            if audioReady {
                let now = Date()
                if let presence = state.keyboardPresence, presence.sessionID == sessionID, presence.fresh(at: now) {
                    lastPresenceAt = presence.heartbeat
                    if audioStartedAt.map({ presence.heartbeat > $0 }) == true { returnGraceDeadline = nil }
                }
                if recordingID != nil, !audio.ready {
                    handleMicrophoneInterruption()
                    return
                }
                if KeyboardAudioReadiness.shouldShutDown(engineReady: audio.ready, restartRequired: state.audioRestartRequired == true, idleDeadline: idleDeadline, returnGraceDeadline: returnGraceDeadline, lastPresenceAt: lastPresenceAt, now: now) { invalidateAudio() }
                else if let epoch = audioEpoch {
                    refreshPreparedLease()
                    try store.publishAudioLease(sessionID: sessionID, epoch: epoch, preparedModelIDs: preparedModelIDs.map(\.rawValue), favoritesRevision: preparedRevision)
                }
            }
            let progress = audio.progress
            if recording, let activeRecordingID = recordingID {
                remainingSeconds = max(0, Int(RecordingPolicy.maximumSeconds) - Int(progress.seconds))
                microphoneLevel = progress.level
                let elapsedSecond = Int(progress.seconds)
                if elapsedSecond != lastCaptureTraceSecond, elapsedSecond % 3 == 0 {
                    lastCaptureTraceSecond = elapsedSecond
                    KeyboardBridgeDiagnostics.record("host_capture_checkpoint", sessionID: sessionID, requestID: activeRecordingID, phase: .recording, capturedFrames: Int64(progress.capturedFrames), receivedBuffers: audio.receivedBufferCount, recordedSeconds: elapsedSecond, level: progress.level)
                }
                if audio.captureWriteFailed || (recordingStartedAt.map { captureWatchdog.stalled(capturedFrames: progress.capturedFrames, startedAt: $0, now: .now) } == true) {
                    failCapture(requestID: activeRecordingID, session: state, progress: progress)
                    return
                }
            }
            try store.transaction { current in
                guard current?.sessionID == sessionID else { return }
                current?.heartbeat = .now
                if let request = current?.request, request.id == recordingID {
                    current?.request?.seconds = min(Int(RecordingPolicy.maximumSeconds), Int(progress.seconds))
                    current?.request?.level = progress.level
                    current?.request?.levelSampleSequence = Int64(progress.capturedFrames)
                }
            }
            // Refresh commands after the transaction; a keyboard write may have intervened.
            guard let fresh = try store.read(), fresh.sessionID == sessionID else { return }
            state = fresh
            guard let request = state.request else {
                if recordingID != nil { invalidateAudio() }
                return
            }
            keyboardPhase = request.phase
            if request.phase == .transcribing, let started = request.processingStartedAt {
                processingElapsedSeconds = max(0, Int(Date().timeIntervalSince(started)))
            }
            if request.command == .cancel {
                generation += 1; inference?.cancel(); inference = nil
                warmPreparation?.cancel(); warmPreparation = nil; warmPreparationID = nil
                audio.cancelClip(); endBackgroundTime(); recording = false
                releaseModelPin(); recordingID = nil; processingID = nil; jobModelID = nil; recordingStartedAt = nil
                active = audioReady; idleDeadline = Date().addingTimeInterval(KeyboardAudioReadiness.idleTimeout)
                try store.transaction { if $0?.sessionID == sessionID, $0?.request?.id == request.id { $0?.request = nil } }
                return
            }
            if request.phase == .queued, let epoch = request.warmAudioEpoch, warmPreparation == nil {
                acceptWarm(request, state: state, epoch: epoch)
                return
            }
            if recordingID == request.id,
               request.command == .stop || audio.progress.seconds >= RecordingPolicy.maximumSeconds {
                finish(request: request, session: state)
            }
        } catch KeyboardBridgeError.busy {
            // Another process has a short transaction; retry on the next tick.
        } catch {
            invalidateAudio(); self.error = error.localizedDescription
        }
    }

    private func finish(request: KeyboardBridgeRequest, session: KeyboardBridgeState, interruptionNotice: String? = nil) {
        guard let store else { return }
        var pendingFile: URL?
        do {
            let progress = audio.progress
            KeyboardBridgeDiagnostics.record("host_capture_summary", sessionID: session.sessionID, requestID: request.id, phase: request.phase, capturedFrames: Int64(progress.capturedFrames), receivedBuffers: audio.receivedBufferCount, recordedSeconds: Int(progress.seconds), level: progress.level)
            let recording = try audio.finishClip()
            // The closed clip is immutable; idle callback buffers are discarded.
            idleDeadline = nil
            self.recording = false
            self.microphoneLevel = 0
            beginProcessingTime(requestID: request.id)
            pendingFile = recording
            recordingID = nil; processingID = request.id
            recordingStartedAt = nil
            let token = generation
            let operationID = UUID()
            let capturedModelID = jobModelID ?? DictationModelSelection.defaultModel
            inference = Task { [weak self] in
                defer { try? FileManager.default.removeItem(at: recording) }
                guard let self else { return }
                do {
                    let accepted = try await BridgeTransactionRetry.run(operation: {
                        guard !Task.isCancelled, generation == token, processingID == request.id else { return false }
                        return try store.transaction { current -> Bool in
                            guard let state = current, state.sessionID == session.sessionID,
                                  Date() < state.expiresAt, let item = state.request,
                                  item.id == request.id, item.nonce == request.nonce,
                                  !item.consumed, item.command != .cancel else { return false }
                            current?.request?.command = .stop
                            current?.request?.phase = .transcribing
                            current?.request?.processingStartedAt = .now
                            return true
                        }
                    })
                    guard accepted else {
                        if generation == token {
                            releaseModelPin(); processingID = nil; inference = nil; active = audioReady; endBackgroundTime()
                            idleDeadline = Date().addingTimeInterval(KeyboardAudioReadiness.idleTimeout)
                            if !audioReady { polling?.cancel(); polling = nil }
                        }
                        return
                    }
                    keyboardPhase = .transcribing; processingElapsedSeconds = 0
                    let raw = try await transcriber.transcribe(recording: recording, modelID: capturedModelID, operationID: operationID, origin: .keyboard) { event in
                        KeyboardBridgeDiagnostics.record("host_transcription_stage", sessionID: session.sessionID, requestID: request.id, phase: .transcribing, operationID: event.operationID, modelID: event.modelID.rawValue, stage: event.stage.rawValue, outcome: event.outcome.rawValue, durationMS: event.durationMS, cacheHit: event.cacheHit, code: event.errorCode)
                    }
                    guard !Task.isCancelled, generation == token,
                          processingID == request.id else { return }
                    let spellings = (try? TranscriptPersistence.loadSpellings()) ?? []
                    let text = LiteralWordReplacement.apply(raw, spellings: spellings)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        fail(requestID: request.id, message: "Keine Sprache erkannt. Bitte erneut diktieren.")
                        releaseModelPin(); processingID = nil; inference = nil; active = audioReady
                        idleDeadline = Date().addingTimeInterval(KeyboardAudioReadiness.idleTimeout); endBackgroundTime()
                        return
                    }
                    let published = try await BridgeTransactionRetry.run(operation: {
                        guard !Task.isCancelled, generation == token, processingID == request.id else { return false }
                        return try store.transaction { current -> Bool in
                            guard let state = current, state.sessionID == session.sessionID,
                                  Date() < state.expiresAt, let item = state.request,
                                  item.id == request.id, item.nonce == request.nonce,
                                  item.command == .stop, !item.consumed else { return false }
                            current?.request?.text = text
                            current?.request?.error = interruptionNotice
                            current?.request?.phase = .ready
                            return true
                        }
                    })
                    guard !Task.isCancelled, generation == token, processingID == request.id else { return }
                    if published { onTranscript?(text) }
                    if published { keyboardPhase = .ready; KeyboardBridgeDiagnostics.record("host_ready", sessionID: session.sessionID, requestID: request.id, phase: .ready, operationID: operationID) }
                    if !published {
                        keyboardPhase = .failed
                        error = "Die Verarbeitung konnte nicht abgeschlossen werden. Bitte erneut diktieren."
                    }
                } catch {
                    if generation == token { fail(requestID: request.id, message: error.localizedDescription) }
                }
                if generation == token {
                    releaseModelPin()
                    jobModelID = nil
                    processingID = nil; inference = nil; active = audioReady
                    idleDeadline = Date().addingTimeInterval(KeyboardAudioReadiness.idleTimeout); endBackgroundTime()
                    if !audioReady { polling?.cancel(); polling = nil }
                }
            }
        } catch {
            if let pendingFile { try? FileManager.default.removeItem(at: pendingFile) }
            shutDownAudio(); self.recording = false; self.microphoneLevel = 0; active = false; endBackgroundTime()
            polling?.cancel(); polling = nil
            releaseModelPin(); recordingID = nil; processingID = nil
            recordingStartedAt = nil
            fail(requestID: request.id, message: error.localizedDescription)
        }
    }

    private func failCapture(requestID: UUID?, session: KeyboardBridgeState, progress: RecordingProgress) {
        guard let requestID else { return }
        let writeFailed = audio.captureWriteFailed
        KeyboardBridgeDiagnostics.record(writeFailed ? "host_capture_write_failed" : "host_capture_timeout", sessionID: session.sessionID, requestID: requestID, phase: .recording, capturedFrames: Int64(progress.capturedFrames), receivedBuffers: audio.receivedBufferCount, recordedSeconds: Int(progress.seconds), level: progress.level)
        if RecordingPolicy.shouldPreserveInterruptedAudio(seconds: progress.seconds, writeFailed: writeFailed),
           let request = session.request, request.id == requestID, request.command != .cancel {
            // Close the clip before end() cancels capture. Preserve the job/model pin and once-only target checks.
            finish(request: request, session: session, interruptionNotice: L("Recording stopped early. Your text was saved.", "Aufnahme vorzeitig beendet. Dein Text wurde gerettet."))
            shutDownAudio()
            return
        }
        shutDownAudio()
        recording = false; active = false; microphoneLevel = 0
        polling?.cancel(); polling = nil; recordingID = nil; recordingStartedAt = nil
        endBackgroundTime()
        fail(requestID: requestID, message: writeFailed ? AudioRecorderError.writeFailed.localizedDescription : L("No audio received. Please try again.", "Kein Ton empfangen. Bitte erneut diktieren."))
    }

    private func fail(requestID: UUID, message: String) {
        try? store?.transaction { current in
            guard current?.sessionID == sessionID, current?.request?.id == requestID else { return }
            current?.request?.phase = .failed
            current?.request?.text = nil
            current?.request?.error = message
        }
        keyboardPhase = .failed
    }

}
