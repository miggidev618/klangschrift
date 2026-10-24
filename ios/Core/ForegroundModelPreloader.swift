import Foundation

/// UI lifecycle coordination only. No microphone, download, or catalogue-refresh capability.
@MainActor final class ForegroundModelPreloader {
    struct DemandClaim {
        let permit: ModelLoadPermit?
        let token: UUID?
    }
    private let service: LocalTranscriptionService
    private let installed: (DictationModelID) -> Bool
    private let quiet: () -> Bool
    private let changed: () async -> Void
    private var visible = false
    private var foreground = false
    private var consumedEpoch = false
    private var disabled = false
    private var pending = false
    private var revision: UUID?
    private var pair: [DictationModelID] = []
    private var selected: DictationModelID = .phonon2CoreML
    private var permit: ModelLoadPermit?
    private var pass: Task<Void, Never>?
    init(service: LocalTranscriptionService, installed: @escaping (DictationModelID) -> Bool,
         quiet: @escaping () -> Bool, changed: @escaping () async -> Void = {}) {
        self.service = service; self.installed = installed; self.quiet = quiet; self.changed = changed
    }
    func configure(models: [DictationModelID], revision: UUID, selected: DictationModelID) {
        self.selected = selected
        guard self.revision != revision else { return }
        self.revision = revision; pair = Array(models.prefix(2)); permit?.invalidate()
        if visible && foreground && !disabled { consumedEpoch = false; pending = true; schedule() }
    }
    func surfaceVisible(foreground: Bool) {
        visible = true
        if foreground { becameActive() }
    }
    /// Only a real background transition opens another epoch. Permission callbacks stay coalesced.
    func becameActive() {
        foreground = true
        guard !consumedEpoch else { return }
        pending = true; schedule()
    }
    func inactive() { foreground = false; pending = false; permit?.invalidate() }
    func background() { inactive(); consumedEpoch = false }
    func memoryWarning() { disabled = true; pending = false; permit?.invalidate() }
    /// Atomically claims an in-flight same-model result BEFORE any async cache read/invalidating stop.
    func demand(_ models: Set<DictationModelID>) -> DemandClaim {
        consumedEpoch = true; pending = false
        let token = permit?.claim(models)
        return DemandClaim(permit: permit, token: token)
    }
    func release(_ claim: DemandClaim) {
        if let token = claim.token { claim.permit?.release(token) }
        Task { await service.discardInvalidAutomaticResidents() }
    }
    private func schedule() {
        guard visible, foreground, !disabled, !consumedEpoch, pending, quiet() else { return }
        guard pass == nil else { return }
        consumedEpoch = true; pending = false
        let target = pair
        let order = target.contains(selected) ? [selected] + target.filter { $0 != selected } : target
        let permit = ModelLoadPermit(); self.permit = permit
        pass = Task { [weak self] in
            // Let the visible view commit before beginning any local work.
            await Task.yield()
            guard let self else { return }
            for id in order {
                guard permit.isValid, self.foreground, !self.disabled, self.quiet() else { break }
                guard self.installed(id) else { continue }
                let prepared = await self.service.preparedModels()
                guard permit.isValid, self.foreground, self.quiet() else { break }
                if prepared.contains(id) { continue }
                do { try await self.service.prepare(modelID: id, origin: .automatic, permit: permit, preserving: Set(target)) }
                catch { /* Automatic failures are numeric metrics only; explicit actions retain their errors. */ }
                await self.changed()
            }
            self.pass = nil
            if self.permit === permit { self.permit = nil }
            await self.service.discardInvalidAutomaticResidents()
            await self.changed()
            self.schedule()
        }
    }
    /// No automatic retry/refill after demand; used only to finish a deferred fresh revision/epoch.
    func quietPhase() { schedule() }
    func waitUntilIdle() async { while let current = pass { await current.value } }
}
