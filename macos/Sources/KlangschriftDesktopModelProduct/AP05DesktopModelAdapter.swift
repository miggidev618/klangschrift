import KlangschriftCore
import Foundation
import KlangschriftDesktopModelCatalog
import KlangschriftDesktopModels
import KlangschriftUI

/// The composition owner may invalidate product work without learning worker,
/// audio or manifest details. Pressure uses the same service owner.
public protocol AP05DesktopModelLifecycleControlling: Sendable {
    func invalidateAndDrain() async
    func memoryPressure() async
}

/// Narrow audio-file port for the root-owned production dictation caller.
/// It reuses AP05's selected-model service and lifecycle; it does not own an
/// audio capture, model runtime, cache or downloader.
public protocol DesktopModelTranscribing: Sendable {
    /// Throws after lifecycle invalidation; it never disguises invalidation as
    /// an absent desktop selection. A `nil` is only the separate desktop
    /// preference being unset, so root may choose its pre-existing legacy path.
    func selectedModelID() async throws -> String?
    /// Explicitly returns to the pre-existing legacy standard by clearing only
    /// the additive desktop selection. Throws on invalidation or unconfirmed
    /// desktop preload teardown; it never silently falls back.
    func selectLegacyStandard() async throws
    func transcriptionAction() async -> DesktopModelTranscriptionAction
    func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String]) async throws -> String
    func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String
    func cancelDemand() async -> DesktopModelDemandCancellationOutcome
}

public extension DesktopModelTranscribing {
    func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String {
        try await transcribeSelected(audioFile: audioFile, language: language, preferredLanguages: preferredLanguages)
    }
    func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage) async throws -> String {
        try await transcribeSelected(audioFile: audioFile, language: language, preferredLanguages: PreferredDictationLanguages.defaults)
    }
    /// Existing callers without a language explicitly request automatic detection.
    func transcribeSelected(audioFile: URL) async throws -> String {
        try await transcribeSelected(audioFile: audioFile, language: .automatic)
    }
}

/// The legacy standard is not an AP04 catalogue model. Its local availability
/// is validated by Foundation before the composition owner opts it into this
/// adapter's presentation.
public enum AP05DesktopModelAdapterError: Error, Sendable, Equatable, LocalizedError {
    case legacyStandardUnavailable
    case legacyStandardOperationUnsupported

    public var errorDescription: String? {
        switch self {
        case .legacyStandardUnavailable:
            return "Der lokale Legacy-Standard ist nicht verfügbar."
        case .legacyStandardOperationUnsupported:
            return "Der Legacy-Standard kann nicht installiert, vorbereitet oder als Favorit verwaltet werden."
        }
    }
}

/// AP05's one-way presentation adapter. The AP04 service remains the sole
/// owner of installation, selection, favourites and no-audio first preparation.
/// This actor neither exposes worker diagnostics nor creates an audio job.
public actor AP05DesktopModelProductAdapter: AP05ModelPresenting, AP05DesktopModelLifecycleControlling, DesktopModelTranscribing {
    public static let legacyStandardModelID = "legacy-mlx-standard"
    private let service: DesktopModelProductService
    private let legacyStandardAvailable: Bool
    private var startup: Task<Void, Never>?
    private var invalidated = false
    private var startupJoinCount = 0
    private var startupJoinWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    /// `legacyStandardAvailable` is false by default. Root may set it only
    /// after Foundation has validated the pre-existing local legacy standard.
    public init(service: DesktopModelProductService, legacyStandardAvailable: Bool = false) {
        self.service = service
        self.legacyStandardAvailable = legacyStandardAvailable
    }

    public func cards(language: String?, installedOnly: Bool) async -> [AP05ModelCard] {
        await startIfNeeded()
        guard !invalidated else { return [] }
        let items = await service.modelItems(language: language, installedOnly: installedOnly)
        var result: [AP05ModelCard] = []
        result.reserveCapacity(items.count)
        for item in items {
            let stats = await service.statistics(for: item.id)
            result.append(AP05ModelCard(
                id: item.id,
                title: item.model.title,
                language: item.model.language,
                description: Self.description(for: item.model),
                downloadBytes: item.model.artifact.totalBytes,
                installed: item.installed,
                selected: item.isSelected,
                favorite: item.isFavorite,
                coldPrepareMilliseconds: stats.coldPrepareMilliseconds.last,
                warmInferenceMilliseconds: stats.warmInferenceMilliseconds.last,
                actionMessage: await service.actionMessage(for: item.id),
                supportsNoAudioFirstPrepare: item.model.id == "phonon2-coreml" || item.model.id == "phonon2-compact-coreml"
            ))
        }
        if legacyStandardAvailable {
            result.append(Self.legacyStandardCard(selected: await service.selectedModelID() == nil))
        }
        return result
    }

    public func select(modelID: String) async throws {
        try await ensureStarted()
        try Task.checkCancellation()
        guard modelID != Self.legacyStandardModelID else {
            guard legacyStandardAvailable else { throw AP05DesktopModelAdapterError.legacyStandardUnavailable }
            try await service.selectLegacyStandard()
            return
        }
        try await service.selectDefault(modelID: modelID)
    }
    public func install(modelID: String) async throws {
        try await ensureStarted()
        try Task.checkCancellation()
        try rejectLegacyStandardOperation(modelID)
        try await service.install(modelID: modelID)
    }
    public func installationStatus() async throws -> AP05ModelInstallationStatus {
        try await ensureStarted()
        switch await service.currentInstallationStatus() {
        case .idle: return .idle
        case .running(let progress):
            let phase: AP05ModelInstallationPhase
            switch progress.phase {
            case .downloading: phase = .downloading
            case .verifying: phase = .verifying
            case .activating: phase = .activating
            }
            return .running(.init(modelID: progress.modelID, phase: phase, completedBytes: progress.completedBytes, totalBytes: progress.totalBytes, completedFiles: progress.completedFiles, totalFiles: progress.totalFiles))
        case .cancelling(let modelID): return .cancelling(modelID: modelID)
        case .cancelled(let modelID): return .cancelled(modelID: modelID)
        case .failed(let modelID, let message): return .failed(modelID: modelID, message: message)
        }
    }
    public func cancelInstall(modelID: String) async throws -> Bool { try await ensureStarted(); return await service.cancelInstall(modelID: modelID) }
    public func prepareNoAudioFirstUse(modelID: String) async throws {
        try await ensureStarted()
        try Task.checkCancellation()
        try rejectLegacyStandardOperation(modelID)
        try await service.preparePhononFirstUse(modelID: modelID)
    }
    public func setFavorite(modelID: String, enabled: Bool) async throws {
        try await ensureStarted()
        try rejectLegacyStandardOperation(modelID)
        var ids = await service.currentSettings().favoriteModelIDs
        if enabled { if !ids.contains(modelID) { ids.append(modelID) } }
        else { ids.removeAll { $0 == modelID } }
        try await service.setFavorites(ids)
    }

    public func transcriptionAction() async -> DesktopModelTranscriptionAction {
        await startIfNeeded()
        guard !invalidated else {
            return .selectModel(message: "Die Modellauswahl ist nicht mehr verfügbar.")
        }
        return await service.transcriptionAction()
    }

    public func selectedModelID() async throws -> String? {
        try await ensureStarted()
        try Task.checkCancellation()
        return await service.selectedModelID()
    }

    public func selectLegacyStandard() async throws {
        try await ensureStarted()
        try Task.checkCancellation()
        try await service.selectLegacyStandard()
    }

    /// The service snapshots the selected ID before its first await. The
    /// adapter then checks cancellation and lifecycle after the await so a
    /// result completed after cancel/invalidation is never published upstream.
    public func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String], recognitionHintPrompt: String?) async throws -> String {
        try await ensureStarted()
        try Task.checkCancellation()
        let text = try await service.transcribeSelected(audioFile: audioFile, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: recognitionHintPrompt)
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        return text
    }
    public func transcribeSelected(audioFile: URL, language: DesktopDictationLanguage, preferredLanguages: [String]) async throws -> String {
        try await transcribeSelected(audioFile: audioFile, language: language, preferredLanguages: preferredLanguages, recognitionHintPrompt: nil)
    }

    public func cancelDemand() async -> DesktopModelDemandCancellationOutcome {
        await service.cancelDemand()
    }

    public func invalidateAndDrain() async {
        invalidated = true
        await service.invalidateAndDrain()
    }

    public func memoryPressure() async { await service.memoryPressure() }

    private func startIfNeeded() async { _ = try? await ensureStarted() }
    private func ensureStarted() async throws {
        guard !invalidated else { throw CancellationError() }
        let shared: Task<Void, Never>
        if let startup {
            startupJoinCount += 1
            let waiters = startupJoinWaiters.filter { $0.key <= startupJoinCount }.map(\.value)
            startupJoinWaiters = startupJoinWaiters.filter { $0.key > startupJoinCount }
            for waiter in waiters { waiter.resume() }
            shared = startup
        }
        else {
            let service = service
            let task = Task { await service.start() }
            startup = task
            shared = task
        }
        await shared.value
        guard !invalidated else { throw CancellationError() }
    }
    /// Test synchronization for the actual adapter join point. It observes
    /// callers that reached the shared initialization barrier, not task timing.
    public func currentStartupJoinCount() -> Int { startupJoinCount }
    public func waitForStartupJoinCount(atLeast minimum: Int) async {
        guard startupJoinCount < minimum else { return }
        await withCheckedContinuation { startupJoinWaiters[minimum] = $0 }
    }
    private static func description(for model: DesktopModel) -> String {
        switch model.family {
        case .moonshineStreaming: return "Kompaktes lokales Streaming-Modell für \(model.language)."
        case .whisperKitCoreML: return "Lokales Core-ML-Modell mit Offline-Tokenizer für \(model.language)."
        case .sherpaZipformer: return "Lokales Zipformer-Streaming-Modell für \(model.language)."
        case .fluidAudioCoreML: return "Lokales Core-ML-Modell. Verfügbarkeit hängt von macOS \(model.minimumMacOS) oder neuer ab."
        }
    }

    private static func legacyStandardCard(selected: Bool) -> AP05ModelCard {
        .init(
            id: legacyStandardModelID,
            title: "Whisper Large-v3",
            language: "Mehrsprachig",
            description: "Bereits lokal verfügbar. Für Diktate in mehreren Sprachen.",
            downloadBytes: 0,
            installed: true,
            selected: selected,
            favorite: false,
            coldPrepareMilliseconds: nil,
            warmInferenceMilliseconds: nil,
            actionMessage: nil,
            supportsNoAudioFirstPrepare: false,
            supportsFavorites: false
        )
    }

    private func rejectLegacyStandardOperation(_ modelID: String) throws {
        guard modelID != Self.legacyStandardModelID else {
            throw AP05DesktopModelAdapterError.legacyStandardOperationUnsupported
        }
    }
}
