import Foundation
import Darwin

/// Best-effort, metadata-only trace for a user-authorized local device diagnosis.
/// It intentionally never writes dictation text, audio paths, or surrounding app context.
enum KeyboardBridgeDiagnostics {
    private static let filename = "Library/keyboard-events.jsonl"

    static func record(_ event: String, sessionID: UUID? = nil, requestID: UUID? = nil, documentMatches: Bool? = nil, phase: KeyboardBridgePhase? = nil, fullAccess: Bool? = nil, storeAvailable: Bool? = nil, capturedFrames: Int64? = nil, receivedBuffers: Int? = nil, recordedSeconds: Int? = nil, level: Double? = nil, operationID: UUID? = nil, modelID: String? = nil, stage: String? = nil, outcome: String? = nil, durationMS: UInt64? = nil, appIsActive: Bool? = nil, tokenValid: Bool? = nil, cacheHit: Bool? = nil, code: String? = nil) {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: KeyboardBridgeStore.groupID) else { return }
        let url = root.appendingPathComponent(filename)
        let lockURL = root.appendingPathComponent("Library/keyboard-events.lock")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(descriptor, LOCK_UN) }
            var item: [String: Any] = ["at": ISO8601DateFormatter().string(from: .now), "event": event]
            if let sessionID { item["session"] = sessionID.uuidString }
            if let requestID { item["request"] = requestID.uuidString }
            if let documentMatches { item["document_matches"] = documentMatches }
            if let phase { item["phase"] = phase.rawValue }
            if let fullAccess { item["full_access"] = fullAccess }
            if let storeAvailable { item["store_available"] = storeAvailable }
            if let capturedFrames { item["captured_frames"] = capturedFrames }
            if let receivedBuffers { item["received_buffers"] = receivedBuffers }
            if let recordedSeconds { item["recorded_seconds"] = recordedSeconds }
            if let level { item["level"] = level }
            if let operationID { item["operation"] = operationID.uuidString }
            if let modelID { item["model"] = modelID }
            if let stage { item["stage"] = stage }
            if let outcome { item["outcome"] = outcome }
            if let durationMS { item["duration_ms"] = durationMS }
            if let appIsActive { item["app_is_active"] = appIsActive }
            if let tokenValid { item["token_valid"] = tokenValid }
            if let cacheHit { item["cache_hit"] = cacheHit }
            if let code { item["code"] = code }
            let line = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys]) + Data([0x0A])
            let old = (try? Data(contentsOf: url)) ?? Data()
            let bounded = old.split(separator: 0x0A, omittingEmptySubsequences: true).suffix(127).reduce(into: Data()) { $0.append(contentsOf: $1); $0.append(0x0A) }
            try (bounded + line).write(to: url, options: .atomic)
        } catch { /* Diagnostics never affect dictation. */ }
    }
}

enum KeyboardBridgeCommand: String, Codable, Sendable { case start, stop, cancel }
enum KeyboardBridgePhase: String, Codable, Sendable { case queued, recording, transcribing, ready, failed }

struct KeyboardBridgeRequest: Codable, Equatable, Sendable {
    let id: UUID
    let nonce: UUID
    var documentID: UUID
    var command: KeyboardBridgeCommand = .start
    var phase: KeyboardBridgePhase = .queued
    var seconds = 0
    var level = 0.0
    var levelSampleSequence: Int64?
    var text: String?
    var error: String?
    var consumed = false
    var processingStartedAt: Date?
    var modelID: String?
    var favoritesRevision: UUID?
    var warmAudioEpoch: UUID?
    var warmRequestedAt: Date?
    var warmPresenceInstanceID: UUID?
    func matchesModelSelection(_ other: KeyboardBridgeRequest?) -> Bool {
        other?.modelID == modelID && other?.favoritesRevision == favoritesRevision
    }
}

enum KeyboardAudioReadiness {
    static let idleTimeout: TimeInterval = 300
    static let presenceTimeout: TimeInterval = 5
    static let returnGrace: TimeInterval = 30

    static func shouldShutDown(engineReady: Bool, restartRequired: Bool, idleDeadline: Date?, returnGraceDeadline: Date?, lastPresenceAt: Date?, now: Date) -> Bool {
        if !engineReady || restartRequired || idleDeadline.map({ now >= $0 }) == true { return true }
        if returnGraceDeadline.map({ now < $0 }) == true { return false }
        return lastPresenceAt.map { now.timeIntervalSince($0) >= presenceTimeout } ?? true
    }
}

struct KeyboardAudioLease: Codable, Equatable, Sendable {
    let sessionID: UUID
    let epoch: UUID
    var expiresAt: Date
    var preparedModelIDs: [String]?
    var favoritesRevision: UUID?
}
struct KeyboardPresenceLease: Codable, Equatable, Sendable {
    let sessionID: UUID
    let instanceID: UUID
    var heartbeat: Date
    func fresh(at now: Date) -> Bool { now.timeIntervalSince(heartbeat) >= -5 && now.timeIntervalSince(heartbeat) < 5 }
}

struct KeyboardBridgeState: Codable, Equatable, Sendable {
    // RecordingPolicy is not part of the lightweight keyboard target. Keep the mirrored
    // recording limit covered by P4BRecordingReliabilityTests.
    static let maximumRecordingSeconds: TimeInterval = 600
    static let maximumLifetime: TimeInterval = maximumRecordingSeconds + 600
    static let heartbeatTimeout: TimeInterval = 5
    static let queuedTimeout: TimeInterval = 60
    let sessionID: UUID
    let nonce: UUID
    var expiresAt: Date
    var heartbeat: Date
    var request: KeyboardBridgeRequest?
    var audioSessionLease: KeyboardAudioLease?
    var keyboardPresence: KeyboardPresenceLease?
    var audioRestartRequired: Bool?

    init(now: Date = .now) {
        sessionID = UUID(); nonce = UUID()
        expiresAt = now.addingTimeInterval(Self.maximumLifetime)
        heartbeat = now
    }

    func hasPendingCancellation(at now: Date) -> Bool {
        guard let request, request.command == .cancel, !request.consumed else { return false }
        if let lease = audioSessionLease, lease.sessionID == sessionID, now < lease.expiresAt,
           lease.expiresAt.timeIntervalSince(now) <= 2 { return true }
        return request.phase != .ready && request.phase != .failed &&
            now.timeIntervalSince(heartbeat) >= -Self.heartbeatTimeout && now.timeIntervalSince(heartbeat) < Self.heartbeatTimeout
    }

    func usable(at now: Date) -> Bool {
        guard now < expiresAt else { return false }
        if request?.phase == .queued { return now.timeIntervalSince(heartbeat) >= -Self.heartbeatTimeout && now.timeIntervalSince(heartbeat) < Self.queuedTimeout }
        // Finished drafts and native jobs survive audio shutdown or host suspension.
        if request?.phase == .ready || request?.phase == .failed || request?.phase == .transcribing { return true }
        return now.timeIntervalSince(heartbeat) < Self.heartbeatTimeout && now.timeIntervalSince(heartbeat) >= -Self.heartbeatTimeout
    }
}

struct KeyboardHandoff: Equatable, Sendable {
    let sessionID: UUID
    let requestID: UUID
    let nonce: UUID
    let documentID: UUID

    var url: URL {
        var components = URLComponents()
        components.scheme = "klangschrift"; components.host = "dictate"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID.uuidString), URLQueryItem(name: "request", value: requestID.uuidString), URLQueryItem(name: "nonce", value: nonce.uuidString), URLQueryItem(name: "document", value: documentID.uuidString)]
        return components.url!
    }

    init(sessionID: UUID, request: KeyboardBridgeRequest) {
        self.sessionID = sessionID; requestID = request.id; nonce = request.nonce; documentID = request.documentID
    }

    init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.scheme == "klangschrift", c.host == "dictate", c.path.isEmpty, c.fragment == nil, c.user == nil, c.password == nil, c.port == nil,
              let items = c.queryItems, items.count == 4, Set(items.map(\.name)) == Set(["session", "request", "nonce", "document"]) else { return nil }
        func id(_ name: String) -> UUID? { items.first(where: { $0.name == name })?.value.flatMap(UUID.init(uuidString:)) }
        guard let session = id("session"), let request = id("request"), let nonce = id("nonce"), let document = id("document") else { return nil }
        sessionID = session; requestID = request; self.nonce = nonce; documentID = document
    }

    func matches(_ state: KeyboardBridgeState, now: Date = .now) -> Bool {
        guard now < state.expiresAt, state.sessionID == sessionID, let request = state.request else { return false }
        if request.phase == .queued && (now.timeIntervalSince(state.heartbeat) < -5 || now.timeIntervalSince(state.heartbeat) >= KeyboardBridgeState.queuedTimeout) { return false }
        return request.id == requestID && request.nonce == nonce && request.documentID == documentID && request.command != .cancel && !request.consumed
    }
}

/// Shared geometry for the passive handoff cue. The SwiftUI bottom overlay
/// uses this exact frame to keep the cue compact in the Home Indicator zone.
enum KeyboardHandoffGuidanceGeometry {
    static let height: CGFloat = 26
    static let edgeClearance: CGFloat = 10

    static func frame(container: CGSize, safeAreaBottom _: CGFloat, horizontalInset: CGFloat = 16) -> CGRect {
        // The overlay explicitly ignores the container's bottom safe area, so
        // its full container coordinates are intentional for both inset cases.
        let height = min(Self.height, max(0, container.height - edgeClearance))
        return CGRect(
            x: min(max(0, horizontalInset), container.width / 2),
            y: max(0, container.height - edgeClearance - height),
            width: max(0, container.width - 2 * min(max(0, horizontalInset), container.width / 2)),
            height: height
        )
    }
}

enum KeyboardBridgeError: LocalizedError {
    case unavailable, unreadable, busy
    var errorDescription: String? {
        switch self {
        case .unavailable: "Die Tastatur ist noch nicht eingerichtet."
        case .unreadable: "Die Tastaturverbindung konnte nicht gelesen werden. Starte Klangschrift erneut."
        case .busy: "Die Tastaturverbindung ist gerade beschäftigt. Bitte erneut versuchen."
        }
    }
}

/// A stable sidecar lock serializes host/extension transactions across processes.
/// Only session metadata and the current draft text are shared, never audio/history.
final class KeyboardBridgeStore: @unchecked Sendable {
    static let groupID = "group.io.github.miggidev618.klangschrift"
    private let url: URL
    private let lockURL: URL
    private let localLock = NSLock()

    init?(container: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)) {
        guard let container else { return nil }
        url = container.appendingPathComponent("keyboard-bridge.json")
        lockURL = container.appendingPathComponent("keyboard-bridge.lock")
    }

    @discardableResult
    func transaction<T>(_ body: (inout KeyboardBridgeState?) throws -> T) throws -> T {
        localLock.lock(); defer { localLock.unlock() }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw KeyboardBridgeError.unavailable }
        defer { close(descriptor) }
        // Nonblocking acquisition avoids freezing the keyboard/main UI.
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw KeyboardBridgeError.busy }
        defer { flock(descriptor, LOCK_UN) }
        var value = try readUnlocked()
        let result = try body(&value)
        if let value {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url) // Only our transient session file.
        }
        return result
    }

    func read() throws -> KeyboardBridgeState? {
        // Reading the atomic snapshot cannot see a partial write.
        localLock.lock(); defer { localLock.unlock() }
        return try readUnlocked()
    }

    private func readUnlocked() throws -> KeyboardBridgeState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 131_072,
              let state = try? JSONDecoder().decode(KeyboardBridgeState.self, from: data) else { throw KeyboardBridgeError.unreadable }
        return state
    }

    func start(documentID: UUID, now: Date = .now) throws -> (sessionID: UUID, request: KeyboardBridgeRequest) {
        try transaction { state in
            guard var current = state, current.usable(at: now) else { throw KeyboardBridgeError.unavailable }
            if let request = current.request, !request.consumed,
               request.phase != .failed { throw KeyboardBridgeError.busy }
            let request = KeyboardBridgeRequest(id: UUID(), nonce: UUID(), documentID: documentID)
            current.request = request; state = current
            return (current.sessionID, request)
        }
    }


    func setPresence(instanceID: UUID, sessionID: UUID, claim: Bool, now: Date = .now) throws {
        try transaction { state in
            guard state?.sessionID == sessionID, now < state!.expiresAt else { return }
            guard claim || state?.keyboardPresence?.instanceID == instanceID else { return }
            state?.keyboardPresence = KeyboardPresenceLease(sessionID: sessionID, instanceID: instanceID, heartbeat: now)
        }
    }

    func clearPresence(instanceID: UUID, sessionID: UUID) throws {
        try transaction { state in
            guard state?.sessionID == sessionID, state?.keyboardPresence?.instanceID == instanceID else { return }
            state?.keyboardPresence = nil
        }
    }

    func publishAudioLease(sessionID: UUID, epoch: UUID, preparedModelIDs: [String]? = nil, favoritesRevision: UUID? = nil, now: Date = .now) throws {
        try transaction { state in
            guard state?.sessionID == sessionID, now < state!.expiresAt, state?.audioRestartRequired != true else { return }
            state?.audioSessionLease = KeyboardAudioLease(sessionID: sessionID, epoch: epoch, expiresAt: now.addingTimeInterval(2), preparedModelIDs: preparedModelIDs, favoritesRevision: favoritesRevision)
        }
    }

    func clearAudioLease(sessionID: UUID, epoch: UUID) throws {
        try transaction { state in
            guard state?.sessionID == sessionID, state?.audioSessionLease?.epoch == epoch else { return }
            state?.audioSessionLease = nil
        }
    }

    /// No document rebinding or pending-job takeover. A warm request is a new clip.
    func startWarm(documentID: UUID, instanceID: UUID, modelID: String? = nil, favoritesRevision: UUID? = nil, now: Date = .now) throws -> KeyboardHandoff? {
        try transaction { state in
            guard var current = state, now < current.expiresAt, current.audioRestartRequired != true,
                  let lease = current.audioSessionLease, lease.sessionID == current.sessionID,
                  now < lease.expiresAt, lease.expiresAt.timeIntervalSince(now) <= 2,
                  let presence = current.keyboardPresence, presence.sessionID == current.sessionID,
                  presence.instanceID == instanceID, presence.fresh(at: now) else { return nil }
            if let modelID {
                guard lease.preparedModelIDs?.contains(modelID) == true, favoritesRevision != nil,
                      lease.favoritesRevision == favoritesRevision else { return nil }
            } else if favoritesRevision != nil { return nil }
            if let pending = current.request, !pending.consumed, pending.phase != .failed { return nil }
            var request = KeyboardBridgeRequest(id: UUID(), nonce: UUID(), documentID: documentID)
            request.modelID = modelID; request.favoritesRevision = favoritesRevision
            request.warmAudioEpoch = lease.epoch
            request.warmPresenceInstanceID = instanceID
            request.warmRequestedAt = now
            current.request = request
            current.expiresAt = now.addingTimeInterval(KeyboardBridgeState.maximumLifetime)
            current.heartbeat = now
            state = current
            return KeyboardHandoff(sessionID: current.sessionID, request: request)
        }
    }


    /// Called by the host only after a new clip file has actually opened.
    func acknowledgeWarmRecording(_ handoff: KeyboardHandoff, epoch: UUID, now: Date = .now) throws -> Bool {
        try transaction { state in
            guard let current = state, handoff.matches(current, now: now), current.audioRestartRequired != true,
                  let request = current.request, request.phase == .queued, request.command == .start,
                  request.warmAudioEpoch == epoch, let started = request.warmRequestedAt,
                  now.timeIntervalSince(started) >= 0, now.timeIntervalSince(started) < 5,
                  let lease = current.audioSessionLease, lease.sessionID == current.sessionID,
                  lease.epoch == epoch, now < lease.expiresAt, lease.expiresAt.timeIntervalSince(now) <= 2,
                  let presence = current.keyboardPresence, presence.sessionID == current.sessionID,
                  presence.instanceID == request.warmPresenceInstanceID, presence.fresh(at: now) else { return false }
            if let modelID = request.modelID {
                guard lease.preparedModelIDs?.contains(modelID) == true,
                      request.favoritesRevision != nil, lease.favoritesRevision == request.favoritesRevision else { return false }
            }
            state?.request?.phase = .recording; state?.heartbeat = now
            return true
        }
    }

    func expireWarmStart(_ handoff: KeyboardHandoff, now: Date = .now) throws -> Bool {
        try transaction { state in
            guard let current = state, handoff.matches(current, now: now), let request = current.request,
                  request.phase == .queued, request.command == .start, request.warmAudioEpoch != nil,
                  let started = request.warmRequestedAt, now.timeIntervalSince(started) >= 5 else { return false }
            state?.request?.phase = .failed
            state?.request?.command = .cancel
            state?.request?.error = "Die Aufnahmebereitschaft ist abgelaufen. Tippe erneut Tap to speak."
            state?.audioSessionLease = nil
            state?.audioRestartRequired = true
            return true
        }
    }

    /// Called only by the keyboard's explicit link activation, before opening the app.
    func prepareHandoff(documentID: UUID, modelID: String? = nil, favoritesRevision: UUID? = nil, now: Date = .now) throws -> KeyboardHandoff {
        try transaction { state in
            if let current = state, now < current.expiresAt, current.hasPendingCancellation(at: now) { throw KeyboardBridgeError.busy }
            if let current = state, now < current.expiresAt, let request = current.request,
               !request.consumed, request.command != .cancel, request.phase != .failed,
               current.usable(at: now) {
                guard request.documentID == documentID else { throw KeyboardBridgeError.busy }
                return KeyboardHandoff(sessionID: current.sessionID, request: request)
            }
            var current = KeyboardBridgeState(now: now)
            current.request = KeyboardBridgeRequest(id: UUID(), nonce: UUID(), documentID: documentID)
            current.request?.modelID = modelID; current.request?.favoritesRevision = favoritesRevision
            state = current
            return KeyboardHandoff(sessionID: current.sessionID, request: current.request!)
        }
    }

    /// Explicit host resumption proves that this process has no native job for this
    /// exact request. Never infer loss from a suspended host's heartbeat alone.
    func failInterruptedProcessing(_ handoff: KeyboardHandoff, now: Date = .now) throws -> Bool {
        try transaction { state in
            guard let current = state, handoff.matches(current, now: now),
                  current.request?.phase == .transcribing, current.request?.command == .stop else { return false }
            state?.request?.phase = .failed
            state?.request?.error = "Die Verarbeitung wurde unterbrochen. Bitte erneut diktieren."
            state?.request?.text = nil
            return true
        }
    }

    @discardableResult
    func command(_ command: KeyboardBridgeCommand, sessionID: UUID, requestID: UUID, nonce: UUID, documentID: UUID) throws -> Bool {
        try transaction { state in
            guard state?.sessionID == sessionID, state?.request?.id == requestID,
                  state?.request?.nonce == nonce, state?.request?.documentID == documentID else { return false }
            state?.request?.command = command
            if command == .cancel { state?.request?.text = nil }
            return true
        }
    }

    /// Automatic keyboard disappearance may cancel only a recording that has not been stopped.
    /// A stopped or finished request remains available for its local transcription/result.
    func cancelBeforeProcessing(sessionID: UUID, requestID: UUID, nonce: UUID, documentID: UUID, presenceInstanceID: UUID? = nil, now: Date = .now) throws -> Bool {
        try transaction { state in
            guard let current = state, now < current.expiresAt, current.sessionID == sessionID,
                  presenceInstanceID == nil || current.keyboardPresence?.instanceID == presenceInstanceID,
                  var request = current.request, request.id == requestID, request.nonce == nonce,
                  request.documentID == documentID, !request.consumed,
                  (request.phase == .queued || request.phase == .recording), request.command != .stop else { return false }
            request.command = .cancel
            request.text = nil
            state?.request = request
            return true
        }
    }

    func consume(sessionID: UUID, requestID: UUID, nonce: UUID, documentID: UUID, now: Date = .now) throws -> String? {
        try transaction { state in
            guard let current = state, current.usable(at: now), current.sessionID == sessionID,
                  let request = current.request, request.id == requestID, request.nonce == nonce,
                  request.documentID == documentID, request.command == .stop, request.phase == .ready,
                  !request.consumed, let text = request.text, !text.isEmpty else { return nil }
            state?.request?.consumed = true
            state?.request?.text = nil
            return text
        }
    }

    /// The user explicitly stops the live recording in the currently visible text field.
    /// This is an explicit user rebind, never a background or automatic rebind; a ready draft is never rebound here.
    func stopAndBindCurrentDocument(sessionID: UUID, requestID: UUID, nonce: UUID, currentDocumentID: UUID, now: Date = .now) throws -> Bool {
        try transaction { state in
            guard let current = state, current.usable(at: now), now < current.expiresAt,
                  current.sessionID == sessionID, var request = current.request,
                  request.id == requestID, request.nonce == nonce, request.phase == .recording,
                  request.command == .start, !request.consumed else { return false }
            request.documentID = currentDocumentID
            request.command = .stop
            state?.request = request
            return true
        }
    }

    /// A completed draft can change targets only after an explicit user tap. Binding and
    /// consumption are one atomic transaction so a result cannot be inserted twice.
    func bindCurrentDocumentAndConsume(sessionID: UUID, requestID: UUID, nonce: UUID, currentDocumentID: UUID, now: Date = .now) throws -> String? {
        try transaction { state in
            guard let current = state, current.usable(at: now), now < current.expiresAt,
                  current.sessionID == sessionID, var request = current.request,
                  request.id == requestID, request.nonce == nonce, request.phase == .ready,
                  request.command == .stop, !request.consumed, let text = request.text, !text.isEmpty else { return nil }
            request.documentID = currentDocumentID
            request.consumed = true
            request.text = nil
            state?.request = request
            return text
        }
    }
}
