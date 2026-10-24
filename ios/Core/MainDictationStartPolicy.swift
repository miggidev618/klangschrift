import Foundation

/// One explicit foreground start intent. No microphone, persistence, or network APIs.
@MainActor final class MainDictationStartPolicy {
    struct Attempt: Equatable, Sendable {
        let token: UUID
        let modelID: DictationModelID
    }
    private(set) var active: Attempt?
    func reserve(modelID: DictationModelID, foreground: Bool, keyboardBusy: Bool) -> Attempt? {
        guard active == nil, foreground, !keyboardBusy else { return nil }
        let attempt = Attempt(token: UUID(), modelID: modelID)
        active = attempt
        return attempt
    }
    func invalidate() { active = nil }
    func finish(_ attempt: Attempt) { if active == attempt { active = nil } }
    func valid(_ attempt: Attempt, allowed: () -> Bool) -> Bool { active == attempt && !Task.isCancelled && allowed() }

    /// A cache miss or one intervening eviction may prepare; both remain foreground-only.
    func prepareAndPin(_ attempt: Attempt, allowed: () -> Bool,
                       prepared: () async -> Set<DictationModelID>,
                       prepare: (DictationModelID) async throws -> Void,
                       pin: (DictationModelID, UUID) async throws -> Void,
                       release: (UUID) async -> Void) async throws -> Bool {
        guard valid(attempt, allowed: allowed) else { return false }
        let cached = await prepared()
        guard valid(attempt, allowed: allowed) else { return false }
        if !cached.contains(attempt.modelID) {
            try await prepare(attempt.modelID)
            guard valid(attempt, allowed: allowed) else { return false }
        }
        do { try await pin(attempt.modelID, attempt.token) }
        catch LocalTranscriberError.modelMissing {
            guard valid(attempt, allowed: allowed) else { return false }
            try await prepare(attempt.modelID)
            guard valid(attempt, allowed: allowed) else { return false }
            try await pin(attempt.modelID, attempt.token)
        }
        guard valid(attempt, allowed: allowed) else { await release(attempt.token); return false }
        return true
    }
}
